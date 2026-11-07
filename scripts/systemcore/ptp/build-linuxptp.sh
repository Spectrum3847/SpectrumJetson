#!/bin/sh
# Builds static arm64 linuxptp v4.4 (ptp4l, phc2sys, pmc, phc_ctl) into $1 (default ./bin) with Docker.
set -eu
out=${1:-bin}
mkdir -p "$out"
out=$(cd "$out" && pwd)
docker run --rm --platform linux/arm64 -v "$out":/out debian:bookworm sh -c '
  apt-get update -qq && apt-get install -y -qq build-essential git ca-certificates >/dev/null &&
  git clone -q --depth 1 -b v4.4 https://github.com/richardcochran/linuxptp /src && cd /src &&
  make -s EXTRA_LDFLAGS=-static ptp4l phc2sys pmc phc_ctl && cp ptp4l phc2sys pmc phc_ctl /out/'
