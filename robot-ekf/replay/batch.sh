#!/usr/bin/env bash
# TagEkf replay over every TXMAN1 match with Orin video on robotlog.spectrum3847.org (14: Q17-Q34, r4-r20).
#   robot-ekf/replay/batch.sh [DATA]          (default ~/build/txman1-all; ~2.5 GB peak, the videos and logs deleted after use)
# Per match: fetch the recordings and the robot log (fetch_robotlog.py), export the log's odometry and Limelight
# MT1 poses (2026-FM-SystemCore tools/export_tagekf_events.py at FM_REF, read with git show), detect with the
# deployed and the -refit calibrations (detect.sh, Docker), then delete the video (KEEP_VIDEO=1 keeps it).
# Then the EKF replay per match and pooled for each calibration, into DATA/results/*.txt and one CSV.
# Steps already done are skipped (a match is done when its dets exist), so it resumes after an interruption.
# Env: MATCHES="Q17 Q24" (default: all), VARIANTS (comma list), FM_REPO, FM_REF, EXCLUDE (matches left out of the
# second, "clean" pool; default r13 r19: r13 lost orin-right after 34 s, r19 feeds no frames after ~262 s while its
# odometry runs off by tens of metres).
set -euo pipefail
shopt -s nullglob
HERE=$(cd "$(dirname "$0")" && pwd)
EKF=$(cd "$HERE/.." && pwd)
DATA=${1:-$HOME/build/txman1-all}
mkdir -p "$DATA/logs" "$DATA/fm-tools" "$DATA/results"
DATA=$(cd "$DATA" && pwd)
FM_REPO=${FM_REPO:-$EKF/../../2026-FM-SystemCore}
# tagekf-replay-tuner with the capture-time mount fix
FM_REF=${FM_REF:-aeca58c}
VARIANTS=${VARIANTS:-napa-newest,fit-newest,napa,fit,a-corners-8.0px,c-bearing-0.1,e-bearing-0.35-at-capture,e-bearing-0.5-at-capture}
PY=python3
command -v "$PY" >/dev/null 2>&1 && "$PY" -c '' 2>/dev/null || PY=python

for f in export_tagekf_events.py wpilog_summary.py; do
  [[ -s $DATA/fm-tools/$f ]] || git -C "$FM_REPO" show "$FM_REF:tools/$f" > "$DATA/fm-tools/$f"
done

read -r -a ALL <<< "${MATCHES:-$("$PY" -I "$HERE/fetch_robotlog.py" list | cut -d' ' -f1 | tr '\n' ' ')}"
for m in "${ALL[@]}"; do
  if compgen -G "$DATA/dets/$m-*.dets.csv" >/dev/null && compgen -G "$DATA/dets-refit/$m-*.dets.csv" >/dev/null; then
    echo "$m: detected already"
    continue
  fi
  "$PY" -I "$HERE/fetch_robotlog.py" fetch "$m" "$DATA"
  for log in "$DATA"/logs/txman1_"${m}"_*.wpilog; do
    [[ -s ${log%.wpilog}.tagekf.txt ]] || "$PY" -I "$DATA/fm-tools/export_tagekf_events.py" "$log"
  done
  ONLY=$m CAL='' "$HERE/detect.sh" docker "$DATA" "$DATA/dets" | tail -n 2
  ONLY=$m CAL=-refit "$HERE/detect.sh" docker "$DATA" "$DATA/dets-refit" | tail -n 2
  [[ ${KEEP_VIDEO:-0} == 1 ]] || rm -f "$DATA/$m"/*/*.mjpeg "$DATA"/logs/txman1_"${m}"_*.wpilog
done

LIST=$(IFS=,; echo "${ALL[*]}")
read -r -a EX <<< "${EXCLUDE:-r13 r19}"
CLEAN=$LIST
for x in "${EX[@]}"; do CLEAN=$(echo ",$CLEAN," | sed "s/,$x,/,/; s/^,//; s/,$//"); done
cd "$EKF"
rm -f "$DATA/results/replay.csv"
J=$(cygpath -m "$DATA" 2>/dev/null || echo "$DATA")  # Java on Windows needs C:/... paths
for cal in deployed refit; do
  if [[ $cal == refit ]]; then d=dets-refit c=-refit; else d=dets c=''; fi
  ./gradlew -q replay -Pargs="--dets $J/$d --logs $J/logs ${c:+--cal $c} --matches $LIST --variants $VARIANTS \
--per-match --csv $J/results/replay.csv --label $cal" | tee "$DATA/results/$cal.txt"
  ./gradlew -q replay -Pargs="--dets $J/$d --logs $J/logs ${c:+--cal $c} --matches $CLEAN --variants $VARIANTS --csv $J/results/replay.csv --label $cal-clean" > "$DATA/results/$cal-clean.txt"
done
"$PY" -I "$HERE/table.py" "$DATA/results/replay.csv" > "$DATA/results/tables.md"
echo "results: $DATA/results (replay.csv, deployed.txt, refit.txt, tables.md)"
