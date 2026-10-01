#!/usr/bin/env bash
# Where does PhotonVision's CPU go? Run ON THE JETSON (uses sudo: the JVM runs as root).
# Measures each thread's CPU over a few seconds, then takes repeated Java stack samples (jstack)
# and reports, for the busiest threads, which Java method they were in. Native code (cscore
# decode, the CUDA detector) shows up as the Java method that called into it.
# Usage: tests/cpu-profile.sh [samples]   (default 40, ~0.25 s apart)
set -euo pipefail
N=${1:-40}
BIN=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}/bin
P=$(systemctl show photonvision -p MainPID --value)
[[ $P != 0 ]] || { echo "photonvision is not running" >&2; exit 1; }
sudo -v
OUT=$(mktemp -d)
echo "Sampling thread CPU for 5 s and $N stack dumps..."
python3 - "$P" > "$OUT/cpu.txt" <<'PY'
import os, sys, time
pid = sys.argv[1]; hz = os.sysconf("SC_CLK_TCK")
def snap():
    out = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            s = open(f"/proc/{pid}/task/{tid}/stat").read()
        except OSError:
            continue
        f = s[s.rindex(")") + 2:].split()
        out[tid] = (s[s.index("(") + 1:s.rindex(")")], int(f[11]) + int(f[12]))
    return out
a = snap(); time.sleep(5); b = snap()
for tid, (name, t) in b.items():
    if tid in a:
        print(tid, "%.1f" % ((t - a[tid][1]) / hz / 5 * 100), name.replace(" ", "_"))
PY
for i in $(seq 1 "$N"); do
  sudo "$BIN/jstack" "$P" > "$OUT/stack-$i.txt" 2>/dev/null || true
  sleep 0.25
done
python3 - "$OUT" <<'PY'
import collections, glob, re, sys
out = sys.argv[1]
cpu = {}
for line in open(f"{out}/cpu.txt"):
    tid, pct, name = line.split()
    cpu[int(tid)] = (float(pct), name)
# jstack: '"name" #N ... nid=0x1a2b ...' then frames '\tat pkg.Class.method(...)'
tops = collections.defaultdict(collections.Counter)
names = {}
for f in glob.glob(f"{out}/stack-*.txt"):
    cur = None
    for line in open(f):
        m = re.match(r'"(.*?)".*nid=(0x[0-9a-f]+)', line)
        if m:
            cur = int(m.group(2), 16); names[cur] = m.group(1); seen = 0
            continue
        m = re.match(r"\s+at (\S+)\(", line)
        if m and cur is not None and seen < 2:
            tops[cur][m.group(1) if seen == 0 else "  <- " + m.group(1)] += 1
            seen += 1
hot = sorted(cpu.items(), key=lambda kv: -kv[1][0])[:12]
total = sum(p for p, _ in cpu.values())
print(f"PhotonVision total CPU: {total:.0f}% (of 600%)\n")
for tid, (pct, comm) in hot:
    if pct < 2: break
    print(f"{pct:5.1f}%  tid {tid}  {names.get(tid, comm)}")
    for frame, n in tops[tid].most_common(6):
        print(f"         {n:3d}x  {frame}")
    if not tops[tid]:
        print("         (no Java frames: a native-only thread, e.g. OpenCV/CUDA/cscore workers)")
PY
rm -rf "$OUT"
