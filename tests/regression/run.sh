#!/usr/bin/env bash
# Detector regression check (regress.py): replays the corpus of recordings through the detector we
# build and compares every detection with the accepted ("golden") output. Run ON THE JETSON:
#   tests/regression/run.sh                      check every session (exit 1 on any change)
#   tests/regression/run.sh NAME...              check some
#   tests/regression/run.sh --bless [NAME...]    accept the current output, after reading the report
#   tests/regression/run.sh --add NAME DIR [--about TEXT]   add a Rewind session to the corpus
# Goldens and corpus.json are written into this checkout; copy them back to the laptop and commit:
#   rsync -a JETSON:SpectrumJetson/tests/regression/{corpus.json,golden} tests/regression/
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$HOME/build/bos-detector
JAVA=${JAVA:-/usr/lib/jvm/java-25-openjdk-arm64/bin/java}
if [[ -z ${REGRESSION_UNDER_TIMEOUT:-} ]]; then
  rc=0
  REGRESSION_UNDER_TIMEOUT=1 timeout --kill-after=20 1800 "$0" "$@" || rc=$?
  [[ $rc == 124 ]] && echo "TIMEOUT: the regression check didn't finish in 30 minutes" >&2
  exit "$rc"
fi

# The detector as built now (incremental: seconds when nothing changed).
if ! nice cmake --build "$BUILD" --target far_replay --parallel 3 >/tmp/regression-build.log 2>&1; then
  tail -20 /tmp/regression-build.log; echo "FAIL: far_replay didn't build" >&2; exit 2
fi
# Same detector as PhotonVision runs? (Warn only: the check is about the code being built.)
if ! cmp -s "$BUILD/lib971apriltag.so" /usr/lib/lib971apriltag.so; then
  echo "NOTE: /usr/lib/lib971apriltag.so isn't this build's; PhotonVision runs a different detector than the one checked here"
fi

case ${1:-} in
  --bless) shift; exec python3 "$HERE/regress.py" bless "$@" ;;
  --add)
    shift
    # Writing to the scratch partition: hold quiet mode off meanwhile (as robot code can).
    "$JAVA" -cp /opt/photonvision/photonvision.jar "$HERE/QuietOff.java" 600 >/tmp/quiet-off.log 2>&1 &
    hold=$!
    for _ in $(seq 30); do grep -q -E "holding|TIMEOUT" /tmp/quiet-off.log 2>/dev/null && break; sleep 1; done
    grep -q holding /tmp/quiet-off.log || echo "NOTE: couldn't hold quiet mode off (no robot connection?); trying anyway"
    python3 "$HERE/regress.py" add "$@"; rc=$?
    sync
    touch /tmp/quiet-off-stop; wait "$hold" 2>/dev/null
    exit $rc ;;
  *) exec python3 "$HERE/regress.py" check "$@" ;;
esac
