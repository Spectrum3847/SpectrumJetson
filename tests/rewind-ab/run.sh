#!/usr/bin/env bash
# Does Rewind recording cost the vision pipeline anything? Run ON THE JETSON (no sudo), with the
# cameras running. Alternates recording off / on (via the web API's bench switch) and measures,
# per phase:
#   - each detector's fps and detect time (from the "detector stats" lines),
#   - PhotonVision's total CPU and the Rewind threads' CPU (from /proc),
#   - SSD write rate (from /proc/diskstats).
# Usage: tests/rewind-ab/run.sh [seconds_per_phase] [rounds]   (defaults 30, 2)
set -euo pipefail
SECS=${1:-30}
ROUNDS=${2:-2}
API=http://localhost:5800/api/rewind
P=$(systemctl show photonvision -p MainPID --value)
[[ $P != 0 ]] || { echo "photonvision is not running" >&2; exit 1; }
DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || echo nvme0n1)
HZ=$(getconf CLK_TCK)

cpu_ticks() { awk '{print $14 + $15}' "/proc/$P/stat"; }
rewind_ticks() {
  local t=0
  for d in /proc/"$P"/task/*; do
    if grep -q '^Rewind-' "$d/comm" 2>/dev/null; then
      t=$((t + $(awk '{print $14 + $15}' "$d/stat")))
    fi
  done
  echo $t
}
api() { # POST a JSON body (or GET with none) to the Rewind API; prints the reply
  python3 - "$API" "${1:-}" <<'PY'
import sys, urllib.request
url, body = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, data=body.encode() if body else None,
                             headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(req, timeout=10).read().decode())
PY
}
sectors_written() { awk -v d="$DISK" '$3 == d {print $10}' /proc/diskstats; }

phase() { # $1 = off|on
  local on=$1
  api "{\"manual\": $([[ $on == on ]] && echo true || echo false)}" >/dev/null
  sleep 3 # let it settle (first frames, file creation)
  local c0 r0 s0 t0 c1 r1 s1 t1
  c0=$(cpu_ticks) r0=$(rewind_ticks) s0=$(sectors_written) t0=$(date +%s.%N)
  local since
  since=$(date '+%Y-%m-%d %H:%M:%S')
  sleep "$SECS"
  c1=$(cpu_ticks) r1=$(rewind_ticks) s1=$(sectors_written) t1=$(date +%s.%N)
  local el
  el=$(echo "$t1 - $t0" | bc -l)
  local stats
  stats=$(journalctl _PID="$P" --no-pager -o cat --since "$since" | grep -E '^(971|detector) stats' || true)
  printf "  recording %-3s " "$on"
  for h in $(grep -oE '^(971|detector) stats h[0-9]+' <<<"$stats" | awk '{print $3}' | sort -u); do
    awk -v h="$h" '$3 == h {
        for (i = 1; i <= NF; i++) { if ($i == "calls/s,") f += $(i-1); if ($i == "avg" && $(i-1) == "detect") d += $(i+1) }
        n++ }
      END { printf "%s %5.1f fps %4.2f ms | ", h, f / n, d / n }' <<<"$stats"
  done
  printf "PV CPU %5.1f%% | Rewind threads %4.1f%% | SSD %5.1f MB/s\n" \
    "$(echo "($c1 - $c0) / $HZ / $el * 100" | bc -l)" \
    "$(echo "($r1 - $r0) / $HZ / $el * 100" | bc -l)" \
    "$(echo "($s1 - $s0) * 512 / $el / 1000000" | bc -l)"
}

echo "Rewind A/B: $ROUNDS rounds of $SECS s off / $SECS s on (CPU % is of one core; 600% = all 6)"
for ((i = 1; i <= ROUNDS; i++)); do
  phase off
  phase on
done
api '{"manual": false}' >/dev/null
echo
api | python3 -c '
import json, sys
s = json.load(sys.stdin)
print("Last recording:", s["recent"][0]["name"] if s["recent"] else "none")
for c in s["cameras"]:
    kb = c["MB"] * 1000 / c["frames"] if c["frames"] else 0
    name, n, mb, prob = c["camera"], c["frames"], c["MB"], c["problem"]
    print(f"  {name}: {n} frames, {mb} MB ({kb:.0f} KB/frame) {prob}")
'
