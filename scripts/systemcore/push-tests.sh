#!/usr/bin/env bash
# Copy the SystemCore test tooling (and the files it imports) to ~/builder/ on the SystemCore.
#   scripts/systemcore/push-tests.sh [HOST]     HOST default systemcore@172.26.0.1
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=${1:-systemcore@172.26.0.1}
tar -C "$REPO" -cf - tests/systemcore-latency tests/latency-breakdown/analyze.py tests/latency-breakdown/ktrace.py \
  scripts/systemcore | ssh "$HOST" 'mkdir -p ~/builder && tar -C ~/builder -xf - && chmod +x ~/builder/tests/systemcore-latency/*.sh'
echo "pushed to $HOST:~/builder"
