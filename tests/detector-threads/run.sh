#!/usr/bin/env bash
# Live A/B of the 971 detector's CPU threads per camera, without restarting PhotonVision. Run ON
# THE JETSON with tags in view (hold them steady: 10 s per segment, 2.5 min for 3 rounds), and with
# the dashboard closed: open camera streams cost CPU and detect time.
# Cycles /tmp/spectrum-detector-threads through CONFIGS: 3 s to settle (the library re-reads it every
# 2 s; stats lines cover 1 s), then 7 s measured. Prints a line per segment, so a tag that drops
# out of view shows at once, then a summary per thread count. Cameras at 1280x800 count as "tag
# cams", others as "no-tag cams": edit summarize() for another layout.
# Usage: tests/detector-threads/run.sh [rounds]   (default 3; results also in $OUT)
set -u
CONFIGS=(6 2 3 4 1)
ROUNDS=${1:-3}
OUT=/tmp/detector-threads-results.txt
SEG=/tmp/detector-threads-segments.txt
trap 'rm -f /tmp/spectrum-detector-threads' EXIT HUP INT TERM
P=$(systemctl show -p MainPID --value photonvision)
: > "$SEG"; : > "$SEG.cpu"
summarize() {  # stdin: "detector stats" lines. Prints: tag-cam avg, typical worst, worst, tags | other cams same
  awk 'function d(a, b) { return b ? a / b : 0 }
       { res=$4; for(i=1;i<=NF;i++){ if($i=="avg"&&$(i-1)=="detect") a=$(i+1);
           if($i=="max"&&$(i-3)=="avg") m=$(i+1); if($i=="tags/frame") t=$(i+1)+0 }
         g=(res ~ /1280x800/)?"T":"G"; sa[g]+=a; sm[g]+=m; st[g]+=t; n[g]++; if(m>mx[g]) mx[g]=m }
       END { printf "tag cams avg %.2f, typical worst %.2f, worst %.2f, %.2f tags/frame | no-tag cams avg %.2f, typical worst %.2f, worst %.2f",
               d(sa["T"],n["T"]), d(sm["T"],n["T"]), mx["T"], d(st["T"],n["T"]), d(sa["G"],n["G"]), d(sm["G"],n["G"]), mx["G"] }'
}
echo "start $(date +%H:%M:%S), PhotonVision pid $P, $ROUNDS rounds of ${CONFIGS[*]} threads"
for r in $(seq "$ROUNDS"); do
  for t in "${CONFIGS[@]}"; do
    echo "$t" > /tmp/spectrum-detector-threads
    sleep 3
    since=$(date "+%Y-%m-%d %H:%M:%S")
    read -r u0 s0 < <(sudo -n awk '{print $14, $15}' /proc/$P/stat)
    sleep 7
    read -r u1 s1 < <(sudo -n awk '{print $14, $15}' /proc/$P/stat)
    until=$(date "+%Y-%m-%d %H:%M:%S")
    cpu=$(echo "scale=2; ($u1+$s1-$u0-$s0)/100/7" | bc)
    lines=$(journalctl _PID="$P" --no-pager -o cat --since "$since" --until "$until" | grep -E '^(971|detector) stats')
    sed "s/^/$t /" <<<"$lines" >> "$SEG"
    echo "round $r, $t threads: CPU $cpu cores | $(summarize <<<"$lines")"
    echo "$t $cpu" >> "$SEG.cpu"
  done
done
rm -f /tmp/spectrum-detector-threads
{
  echo "== $(date +%H:%M:%S), $ROUNDS rounds, 7 s per segment; detect ms"
  for t in "${CONFIGS[@]}"; do
    cpu=$(awk -v t="$t" '$1==t {s+=$2; n++} END {printf "%.2f", n ? s/n : 0}' "$SEG.cpu")
    echo "$t threads: CPU $cpu cores | $(grep -E "^$t (971|detector) stats" "$SEG" | cut -d' ' -f2- | summarize)"
  done
} | tee -a "$OUT"
rm -f "$SEG.cpu"
echo "done; thread count back to the default"
