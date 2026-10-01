#!/usr/bin/env bash
# Measure PhotonVision's Java heap and garbage-collection pauses. GC pauses stop the vision
# threads, so they show up as latency spikes. Run ON THE JETSON (uses sudo: the JVM runs as root).
# Usage: tests/jvm-check.sh [seconds]
set -euo pipefail
SECS=${1:-20}
BIN=${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-arm64}/bin
P=$(systemctl show photonvision -p MainPID --value)
[[ $P != 0 ]] || { echo "photonvision is not running" >&2; exit 1; }

echo "== JVM flags (heap size, collector)"
sudo "$BIN/jcmd" "$P" VM.flags | tr ' ' '\n' | grep -E "MaxHeapSize|InitialHeapSize|UseG1GC|UseParallelGC|UseSerialGC|UseZGC|MaxGCPauseMillis" || true
echo
echo "== Heap now"
sudo "$BIN/jcmd" "$P" GC.heap_info | head -6
echo
echo "== GC activity over ${SECS}s (jstat -gc, 1 s samples)"
sudo "$BIN/jstat" -gc "$P" 1000 "$((SECS + 1))" | awk '
  NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
  {
    ygc = $col["YGC"]; ygct = $col["YGCT"]; fgc = $col["FGC"]; fgct = $col["FGCT"]
    used = $col["S0U"] + $col["S1U"] + $col["EU"] + $col["OU"]
    if (NR == 2) { y0 = ygc; yt0 = ygct; f0 = fgc; ft0 = fgct }
    last_y = ygc; last_yt = ygct; last_f = fgc; last_ft = fgct; n = NR - 2
    if (used > maxused) maxused = used
    old = $col["OU"]; oldcap = $col["OC"]
  }
  END {
    dy = last_y - y0; dt = (last_yt - yt0) * 1000; df = last_f - f0; dft = (last_ft - ft0) * 1000
    printf "young GCs: %d in %d s (%.1f/s), total %.0f ms, avg %.1f ms per pause\n", dy, n, dy / n, dt, (dy ? dt / dy : 0)
    printf "full GCs:  %d (%.0f ms)\n", df, dft
    printf "peak heap used: %.0f MB; old gen %.0f of %.0f MB\n", maxused / 1024, old / 1024, oldcap / 1024
  }'
echo
echo "Process RSS: $(( $(awk '/VmRSS/ {print $2}' /proc/$P/status) / 1024 )) MB"
