#!/usr/bin/env bash
# Will Spectrum's PhotonVision fork still merge, build and pass its tests on a newer upstream?
#
# Usage: check-upstream-rebase.sh [--build] [TARGET]
#   TARGET  an upstream tag, branch or commit. Default: the newest upstream release tag
#           (v20*), or upstream/main when that tag is already in spectrum-2027.
#   --build if the merge is clean, sync the merged tree to ~/build/spectrum-pv-rebasecheck on the
#           Jetson, build it there and run the tests Spectrum added. Never installs, never touches
#           the running PhotonVision or build-install.sh's ~/build/spectrum-pv.
#
# How: merge TARGET into a detached copy of spectrum-2027, in a scratch worktree. spectrum-2027
# has merge commits (feature branches), so `git rebase` would replay ~100 commits one by one, and
# `--rebase-merges` re-resolves every feature merge again; a merge answers the question we have
# ("does our end state still fit on top of the new upstream?") in one step with the same conflicts,
# each file at most once. The real update (SPECTRUM.md, "Updating to a new upstream release") still
# rebases once this says it's worth doing. Conflicting files are traced to our first-parent commits
# (feature commits and feature-branch merges) that changed them, and to SPECTRUM.md feature numbers
# through their "(photonvision-NN" patch numbers.
#
# Nothing here changes spectrum-2027, the other worktrees, or pushes anything. Exit: 0 clean (and
# built/tested with --build), 1 conflicts or build/test failure, 2 usage or setup error.
set -uo pipefail

FORK=${FORK:-$HOME/build/spectrum-pv}
BRANCH=${BRANCH:-spectrum-2027}
UPSTREAM_URL=https://github.com/PhotonVision/photonvision.git
SCRATCH=${SCRATCH:-${TMPDIR:-/tmp}/spectrum-rebasecheck}
WT=$SCRATCH/worktree
JDIR=build/spectrum-pv-rebasecheck
BUILD_TIMEOUT=${BUILD_TIMEOUT:-60m}

build=0; target=""
for a in "$@"; do
  case $a in
    --build) build=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) target=$a ;;
  esac
done

g() { git -C "$FORK" "$@"; }
die() { echo "ERROR: $*" >&2; exit 2; }

g rev-parse --verify -q "$BRANCH" >/dev/null || die "$FORK has no branch $BRANCH"

# 1. upstream: add it read-only if missing, fetch.
if ! g remote get-url upstream >/dev/null 2>&1; then
  g remote add upstream "$UPSTREAM_URL" || die "can't add upstream"
  g remote set-url --push upstream DISABLED   # read-only: we never push upstream
fi
echo "Fetching upstream..."
timeout 5m git -C "$FORK" fetch -q --tags upstream || die "fetch upstream failed (network?)"

if [[ -z $target ]]; then
  tag=$(g tag -l 'v20*' --sort=-v:refname | head -1)
  if [[ -n $tag ]] && ! g merge-base --is-ancestor "$tag" "$BRANCH"; then
    target=$tag
  else
    echo "Newest release tag ${tag:-(none)} is already in $BRANCH; checking upstream/main instead."
    target=upstream/main
  fi
fi
for t in "$target" "upstream/$target"; do
  sha=$(g rev-parse --verify -q "$t^{commit}") && { target=$t; break; }
done
[[ -n ${sha:-} ]] || die "no such target: $target"
ours=$(g rev-parse "$BRANCH")
base=$(g merge-base "$BRANCH" "$sha")
new=$(g rev-list --count "$base..$sha")
# Where our own commits start: the newest upstream/main commit in BRANCH.
fork=$(g merge-base "$BRANCH" upstream/main)

# 2. merge in a scratch worktree (detached, so no branch is moved).
mkdir -p "$SCRATCH"
if [[ -e $WT ]]; then g worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"; fi
g worktree prune
g worktree add -q --detach "$WT" "$ours" || die "worktree add failed"
w() { git -C "$WT" "$@"; }

# Feature number for each patch number, from SPECTRUM.md's feature table ("| N | ... | 01, 02 | ...").
declare -A feat
while IFS='|' read -r _ num _ pats _; do
  num=${num// /}; [[ $num =~ ^[0-9]+$ ]] || continue
  while read -r p; do feat[$((10#$p))]=${feat[$((10#$p))]:-$num}; done < <(grep -oE '[0-9]+' <<<"$pats")
done < <(w show "$ours:SPECTRUM.md" 2>/dev/null | grep -E '^\| [0-9]+ \|')

features_of() { # commit subject -> " [feature 5, 7]" from its photonvision-NN numbers
  local s=$1 list="" n f
  while read -r n; do
    f=${feat[$((10#$n))]:-}; [[ -n $f && " $list " != *" $f "* ]] && list+=" $f"
  done < <(grep -oE 'photonvision-[0-9]+(, [0-9]+)*' <<<"$s" | grep -oE '[0-9]+')
  [[ -n $list ]] && printf ' [feature%s]' "$(sed 's/ /, /g; s/^,//' <<<"$list")"
}

result=clean; conflicts=()
if [[ $new == 0 ]]; then
  result="nothing to merge ($target is already in $BRANCH)"
elif w -c user.name=rebasecheck -c user.email=rebasecheck@localhost merge -q --no-edit "$sha" >"$SCRATCH/merge.log" 2>&1; then
  result="clean ($new upstream commits)"
else
  mapfile -t conflicts < <(w diff --name-only --diff-filter=U)
  if (( ${#conflicts[@]} == 0 )); then result="merge failed (see $SCRATCH/merge.log)"
  else result="CONFLICTS in ${#conflicts[@]} files ($new upstream commits)"; fi
fi

report=$SCRATCH/report.txt
{
  echo "=== Upstream check: $BRANCH ($(g rev-parse --short "$ours")) + $target ($(g rev-parse --short "$sha"), $(g log -1 --format=%cs "$sha")) ==="
  echo "Merge: $result"
  for f in "${conflicts[@]}"; do
    echo "  $f"
    mine=$(g log --first-parent -m --format='%h %s' "$fork..$ours" -- "$f")
    [[ -n $mine ]] || mine="- (no Spectrum commit: upstream-side change only)"
    while read -r h s; do echo "      ours: $h $s$(features_of "$s")"; done <<<"$mine"
    g log --format='%h %s' -3 "$base..$sha" -- "$f" | while read -r h s; do echo "      upstream: $h $s"; done
  done
} | tee "$report"

# 3. build and test on the Jetson.
rc=0; [[ $result == CONFLICTS* || $result == "merge failed"* ]] && rc=1
if (( build )) && (( rc == 0 )); then
  cd "$(dirname "$0")/../.." || die "no SpectrumJetson"
  # shellcheck source=/dev/null
  source config.env || die "no config.env"
  ssh_=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$JETSON_USER@192.168.55.1")
  # The test classes our commits added, per gradle project.
  declare -A tests
  while read -r p; do
    mod=${p%%/*}; cls=$(basename "$p" .java)
    tests[$mod]+=" --tests *.$cls"
  done < <(w diff --name-only --diff-filter=A "$base" HEAD -- '*/src/test/*Test.java')
  tasks=""
  for mod in "${!tests[@]}"; do tasks+=" $mod:test${tests[$mod]}"; done
  echo "Syncing to the Jetson (~/$JDIR) and building (timeout $BUILD_TIMEOUT)..."
  "${ssh_[@]}" "mkdir -p ~/$JDIR" || die "Jetson not reachable over USB"
  rsync -a --delete --exclude node_modules --exclude '/build/' --exclude '*/build/' --exclude .gradle \
    --exclude photon-client/dist -e "ssh -i $KEY -o BatchMode=yes" "$WT/" "$JETSON_USER@192.168.55.1:$JDIR/" \
    || die "sync failed"
  if timeout "$BUILD_TIMEOUT" "${ssh_[@]}" "cd ~/$JDIR && export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-arm64 CXX=g++-14 CC=gcc-14 &&
      F='-PArchOverride=linuxarm64 -Ponlylinuxarm64 -x buildAndCopyUI --no-daemon' &&
      nice ./gradlew photon-targeting:jar photon-server:shadowJar$tasks \$F > /tmp/pv-rebasecheck.log 2>&1; rc=\$?;
      grep -E 'Test.*(PASSED|FAILED)|BUILD|What went wrong|error:' -A3 /tmp/pv-rebasecheck.log | grep -v STANDARD | tail -40; exit \$rc" \
      | tee -a "$report"; then
    echo "Build+tests: PASS" | tee -a "$report"
  else
    if [[ ${PIPESTATUS[0]} == 124 ]]; then echo "Build+tests: TIMEOUT after $BUILD_TIMEOUT" | tee -a "$report"
    else echo "Build+tests: FAIL (Jetson /tmp/pv-rebasecheck.log)" | tee -a "$report"; fi
    rc=1
  fi
elif (( build )); then
  echo "Build+tests: skipped (merge not clean)" | tee -a "$report"
else
  echo "Build+tests: not run (add --build)" | tee -a "$report"
fi
echo "Scratch worktree: $WT (merge result left there; report $report)"
exit $rc
