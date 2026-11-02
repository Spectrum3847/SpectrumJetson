#!/usr/bin/env bash
# re-time base vs variants on a few sessions, interleaved, full clocks, one job
set -u
cd ~/build/early-reject; BIN=build/detector-replay; D=/data/scratch/txman1/replay
SS="TXMAN1_Q17/sessions/0001_Q17_20261015-152820 TXMAN1_Q27/sessions/0008_Q27_20261015-152420 TXMAN1_Q32/sessions/0014_TXMAN1-Q32-r1_20261017-004240"
for r in 1 2; do for v in base s3 b4 s4; do
 case $v in base) o="";; s3) o="--early-reject 3";; s4) o="--early-reject 4";; b4) o="--early-reject 4 --early-mode border";; esac
 for s in $SS; do m=${s%%/*}; n=$(basename "$s"); dst=retime/r$r/$v/$m/$n; mkdir -p "$(dirname "$dst")"
  t=$(timeout 5 tegrastats --interval 1000 | head -1 | grep -o "tj@[0-9.]*")
  echo "$(date +%T) r$r $v $n $t"
  # shellcheck disable=SC2046,SC2086
  timeout -k 10 900 $BIN $D/$s --mwbd 20 --mse 10 --out $dst.det.csv --early-stats $dst.stats.csv $o $(cat $D/$s/calib.args) > $dst.log 2>&1 || echo FAIL
 done; done; done; echo RETIME DONE
