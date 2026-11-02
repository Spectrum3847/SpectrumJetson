#!/usr/bin/env bash
# Renamed 2026-10-31: the GPU detector build is now 07-build-gpu-detector.sh.
exec "$(dirname "$0")/07-build-gpu-detector.sh" "$@"
