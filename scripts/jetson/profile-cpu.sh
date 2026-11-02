#!/usr/bin/env bash
# Where does PhotonVision's CPU go? Records, all over the same window:
#   - CPU per thread (full Java names, so each camera's VisionRunner and decoder are separate)
#   - a CPU profile with Linux perf: top functions overall and per thread (Java names from the JIT map)
#   - tegrastats (CPU per core, GPU, power, temperatures)
# perf samples through the CPU's counters and never signals PhotonVision. Not async-profiler: its
# SIGPROF interrupted a cscore camera thread's select(), which cscore treats as fatal; the camera
# stopped until the USB recovery rebuilt it (2026-10-31).
# Usage (on the Jetson): scripts/jetson/profile-cpu.sh [seconds=30] [label]
# Results: ~/profiles/<time>-<label>/ (summary.txt, perf.script, threads.csv, tegrastats.log).
# perf.script opens in https://www.speedscope.app or the Firefox Profiler for a flame graph.
# From the laptop: rsync -a jetson:profiles/ logs/profiles/
set -euo pipefail
SECS=${1:-30}
LABEL=${2:-run}
KVER=$(uname -r | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+-([0-9]+)-tegra$/\1.0-\2/')
PERF=/usr/lib/linux-nvidia-tegra-tools-$KVER/perf
if [[ ! -x $PERF ]]; then
  echo "Installing perf for this kernel (one time)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "linux-nvidia-tegra-tools-$KVER" > /dev/null
fi

PID=$(systemctl show -p MainPID --value photonvision)
[[ $PID != 0 ]] || { echo "PhotonVision isn't running"; exit 1; }
OUT=~/profiles/$(date +%Y%m%d-%H%M%S)-$LABEL
mkdir -p "$OUT"
echo "Profiling PhotonVision (pid $PID) for ${SECS}s -> $OUT"

sudo jcmd "$PID" Thread.print > "$OUT/threads-start.txt" 2>/dev/null
read -r _ STAT0 < <(awk '{print "x", $14+$15}' /proc/$PID/stat)
T0=$(date +%s.%N)
sudo tegrastats --interval 1000 > "$OUT/tegrastats.log" & TS=$!
sudo timeout $((SECS + 30)) "$PERF" record -q -F 199 -p "$PID" -o /tmp/spectrum-perf.data -- sleep "$SECS" 2>/dev/null
sudo kill $TS 2>/dev/null || true
T1=$(date +%s.%N)
read -r _ STAT1 < <(awk '{print "x", $14+$15}' /proc/$PID/stat)
sudo jcmd "$PID" Thread.print > "$OUT/threads-end.txt" 2>/dev/null
# Names for JIT-compiled Java code (/tmp/perf-<pid>.map), read by perf script
sudo jcmd "$PID" Compiler.perfmap > /dev/null 2>&1 || true
sudo timeout 600 "$PERF" script -i /tmp/spectrum-perf.data -F tid,ip,sym,dso 2>/dev/null > "$OUT/perf.script"
sudo rm -f /tmp/spectrum-perf.data

python3 - "$OUT" "$T0" "$T1" "$STAT0" "$STAT1" "$(getconf CLK_TCK)" <<'EOF' | tee "$OUT/summary.txt"
import re, sys, collections
out, t0, t1, s0, s1, hz = sys.argv[1:]
wall = float(t1) - float(t0)
def cpu_ms(path):
    d = {}
    for line in open(path):
        m = re.match(r'"(.*)" .*?cpu=([\d.]+)ms .*?nid=(\d+)', line)
        if m: d[m.group(3)] = (m.group(1), float(m.group(2)))
    return d
a, b = cpu_ms(f"{out}/threads-start.txt"), cpu_ms(f"{out}/threads-end.txt")
rows = sorted(((b[k][1] - a.get(k, (0, 0))[1]) / wall / 10, b[k][0]) for k in b)
total = (int(s1) - int(s0)) / int(hz) / wall * 100
java = sum(r[0] for r in rows)
with open(f"{out}/threads.csv", "w") as f:
    f.write("pct_of_one_core,thread\n")
    for p, n in sorted(rows, reverse=True): f.write(f"{p:.2f},\"{n}\"\n")
print(f"PhotonVision CPU over {wall:.0f}s: {total:.0f}% of one core ({total/6:.1f}% of all 6)")
print(f"  Java threads {java:.0f}%, native-only threads (cscore, CUDA, NT) {total-java:.0f}%\n")
print("Busiest threads (% of one core):")
for p, n in sorted(rows, reverse=True)[:12]:
    if p >= 0.5: print(f"  {p:5.1f}  {n[:90]}")

g = collections.defaultdict(list)
for line in open(f"{out}/tegrastats.log"):
    m = re.search(r'CPU \[([^\]]*)\]', line)
    if m: g["cpu"].append(sum(int(x.split('%')[0]) for x in m.group(1).split(',') if '%' in x) / 6)
    for key, pat in (("gpu", r'GR3D_FREQ (\d+)%'), ("temp", r'tj@([\d.]+)C'), ("power", r'VDD_IN (\d+)mW'),
                     ("nvjpg", r'NVJPG0? (\d+)%'), ("nvjpg1", r'NVJPG1 (\d+)%')):
        m = re.search(pat, line)
        if m: g[key].append(float(m.group(1)))
avg = lambda k: sum(g[k]) / len(g[k]) if g[k] else float('nan')
print(f"\nWhole Jetson: CPU {avg('cpu'):.0f}% avg of 6 cores, GPU {avg('gpu'):.0f}%, "
      f"power {avg('power')/1000:.1f} W, max temp {max(g['temp'] or [0]):.0f} C"
      + (f", NVJPG {avg('nvjpg'):.0f}%/{avg('nvjpg1'):.0f}%" if g['nvjpg'] else ""))

names = {k: v[0] for k, v in b.items()}
leaf, thread_leaf, tsum = collections.Counter(), collections.defaultdict(collections.Counter), collections.Counter()
for line in open(f"{out}/perf.script", errors="replace"):
    # without call stacks, one sample a line: "  tid  address  symbol (dso)"
    m = re.match(r'\s*(\d+)\s+[0-9a-f]+\s+(.*?)\s*\((\S*)\)\s*$', line)
    if not m: continue
    tid, sym, dso = m.groups()
    if sym in ("[unknown]", ""): sym = dso.rsplit('/', 1)[-1] or "?"
    if dso.startswith("[kernel"): sym += " [k]"
    f = re.sub(r'\(.*', '', sym).strip()[:90]
    th = names.get(tid, f"native thread {tid}")
    th = re.sub(r'^(VisionRunner|SpectrumDecoder).*', r'\1 (all cameras)', th)
    leaf[f] += 1; thread_leaf[th][f] += 1; tsum[th] += 1
alln = sum(leaf.values()) or 1
print("\nWhere the CPU time is spent (self time, % of profiled samples):")
for f, n in leaf.most_common(15): print(f"  {100*n/alln:5.1f}  {f[:90]}")
for th, tn in tsum.most_common(5):
    print(f"\n{th} {100*tn/alln:.0f}% of samples; its top functions:")
    for f, n in thread_leaf[th].most_common(8): print(f"  {100*n/tn:5.1f}  {f[:90]}")
print(f"\nFlame graph: open {out}/perf.script in speedscope.app ([k] = kernel time)")
EOF
