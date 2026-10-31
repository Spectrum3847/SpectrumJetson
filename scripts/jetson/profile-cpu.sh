#!/usr/bin/env bash
# Where does PhotonVision's CPU go? Records, all over the same window:
#   - CPU per thread (full Java names, so each camera's VisionRunner and decoder are separate)
#   - a Java + native CPU profile (async-profiler), as a flame graph and as top functions
#   - tegrastats (CPU per core, GPU, power, temperatures)
# Usage (on the Jetson): scripts/jetson/profile-cpu.sh [seconds=30] [label]
# Results: ~/profiles/<time>-<label>/ (summary.txt, flame.html, collapsed.txt, threads.csv, tegrastats.log)
# From the laptop: rsync -a jetson:profiles/ logs/profiles/
set -euo pipefail
SECS=${1:-30}
LABEL=${2:-run}
AP_VER=4.6
AP_SHA=e9e26d2aae0d2935a0a676342c2e4612076ef15f04788c82f965d408a6659fbb
AP=/opt/async-profiler-$AP_VER-linux-arm64/bin

if [[ ! -x $AP/asprof ]]; then
  echo "Installing async-profiler $AP_VER (one time)"
  t=$(mktemp)
  curl -fsSLo "$t" https://github.com/async-profiler/async-profiler/releases/download/v$AP_VER/async-profiler-$AP_VER-linux-arm64.tar.gz
  echo "$AP_SHA  $t" | sha256sum -c --quiet
  sudo tar -C /opt -xzf "$t"; rm -f "$t"
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
sudo "$AP/asprof" -d "$SECS" -e cpu -i 5ms -t -f /tmp/spectrum-profile.jfr "$PID" > /dev/null
sudo kill $TS 2>/dev/null || true
T1=$(date +%s.%N)
read -r _ STAT1 < <(awk '{print "x", $14+$15}' /proc/$PID/stat)
sudo jcmd "$PID" Thread.print > "$OUT/threads-end.txt" 2>/dev/null
sudo mv /tmp/spectrum-profile.jfr "$OUT/profile.jfr"; sudo chown "$USER:" "$OUT/profile.jfr"
"$AP/jfrconv" --cpu -t --simple -o collapsed "$OUT/profile.jfr" "$OUT/collapsed.txt" > /dev/null
"$AP/jfrconv" --cpu --simple --title "PhotonVision $LABEL" "$OUT/profile.jfr" "$OUT/flame.html" > /dev/null

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
                     ("nvjpg", r'NVJPG (\d+)%'), ("nvjpg1", r'NVJPG1 (\d+)%')):
        m = re.search(pat, line)
        if m: g[key].append(float(m.group(1)))
avg = lambda k: sum(g[k]) / len(g[k]) if g[k] else float('nan')
print(f"\nWhole Jetson: CPU {avg('cpu'):.0f}% avg of 6 cores, GPU {avg('gpu'):.0f}%, "
      f"power {avg('power')/1000:.1f} W, max temp {max(g['temp'] or [0]):.0f} C"
      + (f", NVJPG {avg('nvjpg'):.0f}%/{avg('nvjpg1'):.0f}%" if g['nvjpg'] else ""))

leaf, thread_leaf, tsum = collections.Counter(), collections.defaultdict(collections.Counter), collections.Counter()
for line in open(f"{out}/collapsed.txt"):
    stack, n = line.rstrip().rsplit(' ', 1); n = int(n)
    frames = stack.split(';')
    th = re.sub(r' tid=\d+\]$', ']', frames[0])
    th = re.sub(r'^\[(VisionRunner|SpectrumDecoder).*', r'[\1 (all cameras)]', th)
    f = frames[-1].rsplit('/', 1)[-1]
    leaf[f] += n; thread_leaf[th][f] += n; tsum[th] += n
alln = sum(leaf.values()) or 1
print("\nWhere the CPU time is spent (self time, % of profiled samples):")
for f, n in leaf.most_common(15): print(f"  {100*n/alln:5.1f}  {f[:90]}")
for th, tn in tsum.most_common(3):
    print(f"\n{th} {100*tn/alln:.0f}% of samples; its top functions:")
    for f, n in thread_leaf[th].most_common(8): print(f"  {100*n/tn:5.1f}  {f[:90]}")
print(f"\nFlame graph: {out}/flame.html  (frames ending _[k] are kernel time)")
EOF
