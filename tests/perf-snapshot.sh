#!/usr/bin/env bash
# One-line performance snapshot of PhotonVision, for before/after comparisons. Run ON THE JETSON
# (no sudo). Over N seconds: each detector's fps and detect time ("detector stats" lines), PhotonVision's
# total CPU, and CPU split into the per-camera vision threads, OpenCV/native worker threads
# spawned from them, and everything else.
# Usage: tests/perf-snapshot.sh [seconds] [label]   (default 20)
set -euo pipefail
SECS=${1:-20}
LABEL=${2:-}
P=$(systemctl show photonvision -p MainPID --value)
[[ $P != 0 ]] || { echo "photonvision is not running" >&2; exit 1; }
since=$(date '+%Y-%m-%d %H:%M:%S')
P=$P SECS=$SECS python3 - <<'PY' > /tmp/perf-cpu.$$
import os, time
pid, secs = os.environ["P"], float(os.environ["SECS"]); hz = os.sysconf("SC_CLK_TCK")
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
a = snap(); time.sleep(secs); b = snap()
main = workers = other = 0.0
for tid, (name, t) in b.items():
    if tid not in a:
        continue
    pct = (t - a[tid][1]) / hz / secs * 100
    # Java names the camera threads "VisionRunner - <provider>"; native threads they start
    # (OpenCV's pool, CUDA) inherit the truncated name "VisionRunner - ".
    if name.startswith("VisionRunner") and pct > 50:
        main += pct
    elif name.startswith("VisionRunner"):
        workers += pct
    else:
        other += pct
print(f"{main + workers + other:.0f} {main:.0f} {workers:.0f} {other:.0f}")
PY
read -r total main workers other < /tmp/perf-cpu.$$
rm -f /tmp/perf-cpu.$$
cams=$(journalctl _PID="$P" --no-pager -o cat --since "$since" | grep -E '^(971|detector) stats' | awk '
  { for (i = 1; i <= NF; i++) { if ($i == "calls/s,") f[$3] += $(i-1); if ($i == "avg" && $(i-1) == "detect") d[$3] += $(i+1) }; n[$3]++ }
  END { for (h in n) printf "%s %.0f fps %.2f ms  ", h, f[h] / n[h], d[h] / n[h] }')
# Browser preview streams (PhotonVision's MJPEG servers, ports 1181-1190) cost CPU: count viewers.
viewers=$(ss -Htn state established '( sport >= :1181 and sport <= :1190 )' 2>/dev/null | wc -l)
printf "%-22s %s| CPU %s%% (camera threads %s%%, workers %s%%, other %s%%) | stream viewers %s\n" \
  "$LABEL" "$cams" "$total" "$main" "$workers" "$other" "$viewers"
