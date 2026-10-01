#!/usr/bin/env bash
# Builds and tests both versions of the library, and makes the drop-in zips.
#   ./build.sh            test both, then build/drop/*.zip in each build
#   ./build.sh wpilib2026 (or wpilib2027): just one
# Needs JDK 17 and JDK 25. It looks for them where the WPILib installers put them
# (~/wpilib/2026/jdk, ~/wpilib/2027/jdk), and in JAVA17_HOME / JAVA25_HOME.
set -euo pipefail
cd "$(dirname "$0")"
paths=()
for j in "${JAVA17_HOME:-}" "${JAVA25_HOME:-}" "$HOME/wpilib/2026/jdk" "$HOME/wpilib/2027/jdk" "$HOME/build/tools/jdk17"; do
  [[ -n $j && -x $j/bin/java ]] && paths+=("$j")
done
[[ ${#paths[@]} -gt 0 ]] || { echo "No JDK found: install WPILib 2026 and/or 2027, or set JAVA17_HOME / JAVA25_HOME" >&2; exit 1; }
# AdvantageKit's offline Maven repos (for compiling the AdvantageKit example), from GitHub.
deps=$HOME/.cache/spectrum-vision-deps
for v in v26.0.2 v27.0.0-alpha-4; do
  [[ -d $deps/akit-$v/maven_offline ]] && continue
  mkdir -p "$deps/akit-$v"
  echo "Downloading AdvantageKit $v (offline Maven repo, GitHub)"
  curl -fsSL -o "$deps/akit-$v.zip" "https://github.com/Mechanical-Advantage/AdvantageKit/releases/download/$v/maven_offline.zip"
  unzip -q -o "$deps/akit-$v.zip" -d "$deps/akit-$v" && rm "$deps/akit-$v.zip"
done
# PhotonLib's and WPILib 2027's desktop libraries need a newer C++ runtime than Ubuntu 22.04 has:
# the simulation tests get one in their own library folders (nothing system-wide changes).
tools/ubuntu2204-sim/get-libstdcxx.sh || echo "WARNING: couldn't get a newer libstdc++; the simulation tests will fail on this system"
# Gradle itself runs on the first JDK found (17 or newer).
export JAVA_HOME=${JAVA_HOME:-${paths[0]}}
csv=$(IFS=,; echo "${paths[*]}")
projects=("$@")
[[ ${#projects[@]} -gt 0 ]] || projects=(wpilib2026 wpilib2027)
tasks=()
for p in "${projects[@]}"; do tasks+=(":$p:test" ":$p:sourceDrop"); done
# The end-to-end simulation tests run on this machine's desktop libraries. On Ubuntu 22.04, the
# 2027 copies get tools/ubuntu2204-sim/glibc238_compat.py; on 24.04 and newer it changes nothing.
for p in "${projects[@]}"; do tasks+=(":$p:simTest"); done
exec ./gradlew --console=plain -Dorg.gradle.java.installations.paths="$csv" -Dorg.gradle.java.installations.auto-download=false "${tasks[@]}"
