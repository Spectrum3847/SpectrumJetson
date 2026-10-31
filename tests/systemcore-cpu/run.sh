#!/usr/bin/env bash
# SystemCore CPU benchmark (see README.md here): MJPEG decode (colour+cvtColor, gray, half-res gray)
# and WPILib's CPU AprilTag detector (full res decimate 2 vs half res decimate 1, threads 1/2/4) on
# Rewind recordings, then tags found and corner differences against a reference detector CSV.
# Runs on whatever machine it's started on: the Jetson, the laptop, a SystemCore.
#
#   run.sh [options] DIR...       DIR: Rewind sessions (any tree of <session>/<camera>/*.mjpeg
#                                 with their .csv index), e.g. /opt/photonvision/rewind/regression
#     --jar JAR                   PhotonVision jar for this machine's architecture
#                                 (default /opt/photonvision/photonvision.jar)
#     --cores LIST                taskset CPU list (default: one core, the last). The thread
#                                 counts above 1 need as many cores to mean anything.
#     --frames N                  frames per camera (default 400)
#     --threads 1,2,4             detector thread counts
#     --ref DIR                   reference detections (detector-replay CSVs: <session>.csv), e.g.
#                                 a field-replay match's out/base, for compare.py
#     --out DIR                   results (default ./out-<host>-<time>)
#     --timeout S                 hard deadline (default 1800)
# Runs at nice 19. Writes OUT/summary.txt, OUT/compare.txt, OUT/<variant>/<session>.csv.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
JAR=/opt/photonvision/photonvision.jar
CORES=$(($(nproc) - 1))
FRAMES=400
THREADS=1,2,4
REF=""
OUT=""
TIMEOUT=1800
dirs=()
while (($#)); do
    case "$1" in
        --jar) JAR=$2; shift 2 ;;
        --cores) CORES=$2; shift 2 ;;
        --frames) FRAMES=$2; shift 2 ;;
        --threads) THREADS=$2; shift 2 ;;
        --ref) REF=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) dirs+=("$1"); shift ;;
    esac
done
((${#dirs[@]})) || { sed -n '2,20p' "$0"; exit 2; }
[[ -f $JAR ]] || { echo "no PhotonVision jar at $JAR (--jar)"; exit 2; }
OUT=${OUT:-$PWD/out-$(hostname)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/classes"
javac --release 17 -proc:none -cp "$JAR" -d "$OUT/classes" "$HERE/Bench.java" || exit 2
{
    echo "host $(hostname), cores $CORES, $(uname -m)"
    for c in $(echo "$CORES" | tr ',' ' '); do
        f=/sys/devices/system/cpu/cpu${c%%-*}/cpufreq
        [[ -r $f/scaling_cur_freq ]] && echo "cpu${c%%-*} clock now $(($(cat "$f/scaling_cur_freq") / 1000)) MHz, max $(($(cat "$f/scaling_max_freq") / 1000)) MHz"
    done
    echo "load: $(cat /proc/loadavg)"
} | tee "$OUT/machine.txt"
timeout -k 10 "$TIMEOUT" nice -n 19 taskset -c "$CORES" java -Xmx768m \
    -Dframes="$FRAMES" -Dthreads="$THREADS" -Dout="$OUT" \
    -cp "$JAR:$OUT/classes" Bench "${dirs[@]}" 2>&1 | grep -v "^\[" | tee "$OUT/bench.log"
rc=${PIPESTATUS[0]}
((rc == 124)) && { echo "TIMEOUT after ${TIMEOUT}s"; exit 1; }
((rc == 0)) || { echo "bench failed ($rc)"; exit 1; }
if [[ -n $REF ]]; then
    python3 "$HERE/compare.py" "$REF" "$OUT" | tee "$OUT/compare.txt"
fi
