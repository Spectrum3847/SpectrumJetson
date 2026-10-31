#!/usr/bin/env bash
# Choose which GPU AprilTag detector library (libspectrum-gpu-apriltag.so) PhotonVision loads,
# and its runtime options.
# Run ON THE JETSON. Both builds have the same Java API.
#
# Usage: 08-select-detector.sh gpu|gpu-4143 [--mwbd N] [--jpeg nvjpg|turbo] [--mse N]
#                              [--edge N] [--gpu-connections N] [--gpu-level N] [--gpu-refine N]
#                              [--graphs 0|1] [--chain 0|1] [--far on|off] [--defaults] [--no-restart]
#        08-select-detector.sh --gpu-level list     (what each level does; changes nothing)
#   gpu       our GPU detector: Austin Schuh's CUDA AprilTag code from frc971/bos + our patches
#             (07-build-gpu-detector.sh). The one the robot uses.
#   gpu-4143  the older FRC-Team-4143/GpuDetectorJNI build + our patches (05-build-gpudetector.sh)
#   (Before 2026-10-31 these were "bos" and "4143"; both still work.)
#   --mwbd N         min_white_black_diff (gpu build only; default 20, the robot config: the detector
#                    is 30-40% faster than at the library default 5, docs/TECHNICAL.md)
#   --mse N          max_line_fit_mse (gpu build only; default 10). Lower (e.g. 2.5, upstream
#                    PhotonVision #2138) rejects tags cut off at the image edge; test range first.
#   --edge N         drop tags within N full-resolution pixels of the image edge, early in the GPU
#                    blob filter (gpu build only; default 0 = off; AOS uses 50 on corners).
#   --jpeg nvjpg     decode camera JPEGs on the NVJPG hardware engine (gpu build only; default
#                    turbo = libjpeg-turbo on the CPU). Check it first with tests/jpeg-hw/run.sh.
#                    For a quick A/B without a restart: echo turbo > /tmp/spectrum-jpeg-decoder
#   --gpu-connections N  CUDA_DEVICE_MAX_CONNECTIONS, the GPU's hardware work queues (default
#                    32; CUDA's own default is 8). With 4 cameras, runs with 32 had ~0.5 ms
#                    lower worst-frame detect times on average: likely but unproven, since the
#                    same setting varies 2 ms between restarts. No CPU or GPU cost.
#   --gpu-refine N   SPECTRUM_DETECTOR_GPU_REFINE, read at start (gpu build only; default 0 = the CPU
#                    path): 1 RefineEdges on the GPU (detector-15), 2 corners and RefineEdges in
#                    stage 3's graph (detector-16), 3 the decode in the graph too (detector-17).
#                    4 the decode in float (detector-18, if the build has it; not bit-identical).
#                    0 in /tmp/spectrum-detector-gpu-refine turns them off live.
#   --gpu-level N    the GPU offload ladder (docs/TECHNICAL.md, "GPU offload ladder"): one number for
#                    --gpu-refine, --graphs, --chain and --far, 5 = most work on the GPU, 0 = least.
#                    Step down when the GPU is the bottleneck (e.g. a TensorRT model). Individual
#                    flags given as well override the level's value. --gpu-level list prints it.
#   --graphs 0|1     SPECTRUM_DETECTOR_GRAPHS (detector-11 stage graphs; default 1). 0 also stops
#                    --gpu-refine 2-4 (they live in the graphs). Live: echo 0 > /tmp/spectrum-detector-graphs
#   --chain 0|1      SPECTRUM_DETECTOR_CHAIN (detector-13, one GPU wait a frame; default 1).
#                    Live: echo 0 > /tmp/spectrum-detector-chain
#   --far on|off     the far-tag search (a PhotonVision setting, Settings > Robot state; saved
#                    there, live, no restart). Set through localhost:5800/api/robotState when
#                    PhotonVision is up; not touched unless --far or --gpu-level is given.
# Options not given KEEP their current value from detector.conf (the old SPECTRUM_971_* names are
# read too), so `gpu --mwbd 20` changes only min_white_black_diff. --defaults starts from the
# defaults instead (mwbd 20, mse/edge/refine off, turbo JPEG, graphs+chain on, 32 connections),
# then applies the other flags. --gpu-level overrides the kept values it covers; explicit flags
# override the level. What changed is printed.
# (Fault injection for testing: echo N > /tmp/spectrum-detector-fault-every; rm it to stop.)
set -euo pipefail

# The GPU offload ladder: level -> "refine graphs chain far". Numbers per calibrated camera at
# 122 fps from graph_bench (TXMAN1 Q17, busy) and the live far-search A/B; docs/TECHNICAL.md.
level_settings() {
  case $1 in
    5) echo "4 1 1 on" ;;
    4) echo "2 1 1 on" ;;
    3) echo "0 1 1 on" ;;
    2) echo "0 1 1 off" ;;
    1) echo "0 1 0 off" ;;
    0) echo "0 0 0 off" ;;
    *) return 1 ;;
  esac
}
level_list() {
  cat <<'EOF2'
GPU offload ladder (08-select-detector.sh gpu --gpu-level N). Step DOWN one level at a time when
the GPU is the bottleneck (TensorRT object detection, ...). Per calibrated camera at 122 fps;
uncalibrated cameras run the CPU path at levels 3-5 alike. ~ = estimate.

 level  settings                         GPU per camera       CPU per camera        detect wall
 5      refine 4: corners, RefineEdges,  ~+160 us/frame       134 us/frame          1958 us
        float decode in stage 3's graph  (~+2% GPU) vs L3     (~2% of a core)       (= L4)
        (detector-18). Most GPU. RECOMMENDED once bench-confirmed.
 4      refine 2: corners + RefineEdges  ~+70 us/frame        426 us/frame          1949 us
        in the graph (detector-16).      (~+1% GPU) vs L3     (~5% of a core)       (best)
 3      refine 0: CPU corners, refine,   baseline             1045 us/frame         1975 us
        decode; graphs + chain on.                            (~13% of a core)
        Today's default.
 2      L3 + far search off.             frees the far search only while no camera has a good
                                         view: measured 19.4 -> 16.5% GPU (5 cameras), -0.4 W.
                                         Costs range (tags under ~20 px).
 1      L2 + chain off (detector-13).    frees ~no GPU (-1%); +160 us CPU and wall a frame.
 0      L1 + graphs off (detector-11).   frees ~no GPU; ~+0.3-0.5 ms CPU a frame (~67 CUDA calls).
        Levels 1 and 0 are for debugging only: they never help a busy GPU.

Levels 5/4 need a restart (read at start, recorded into the graphs); 0 in
/tmp/spectrum-detector-gpu-refine turns them off live. Graphs/chain: env at start, 0 in
/tmp/spectrum-detector-graphs or -chain turns them off live (re-read every 2 s). Far search: live.
Without detector-18 built, level 5 falls back to refine 3 (detector-17, double-precision decode:
2133 us wall, ~+340 us GPU); --gpu-level 5 --gpu-refine 3 forces that (bit-exact decode margins).
Not on the ladder: JPEG decode runs on the NVJPG engines, not the GPU (--jpeg nvjpg); --jpeg turbo
decodes on the CPU instead (~+0.16 cores per camera, measured 0.52 -> 0.85 cores for 2 cameras).
EOF2
}
for a in "$@"; do [[ $a == list ]] && { level_list; exit 0; }; done
# Writes on the read-only system (ro-root on) land in RAM and vanish at the next boot.
[[ $(findmnt -n -o FSTYPE /) != overlay ]] || { echo "The system partition is read-only (ro-root on): scripts/jetson/ro-root.sh off first." >&2; exit 1; }

which=${1:?usage: $0 gpu|gpu-4143 [--mwbd N] [--jpeg nvjpg|turbo] [--mse N] [--edge N] [--gpu-connections N] [--gpu-refine N] [--no-restart]}
shift
# Defaults (--defaults, or a fresh install). mwbd 20 is the robot config (JetPack 7 setup ran at
# 5 by leaving it out: detect 2.4 vs 1.6 ms).
D_mwbd=20; D_mse=""; D_edge=0; D_jpeg=turbo; D_connections=32; D_refine=0; D_graphs=1; D_chain=1
dropin=/etc/systemd/system/photonvision.service.d/detector.conf
old_dropin=/etc/systemd/system/photonvision.service.d/971.conf
# Current settings: detector.conf, else 971.conf (old names). Missing keys = defaults.
cur_get() {  # cur_get NAME -> value of Environment=SPECTRUM_DETECTOR_NAME (or the old 971 name)
  local f
  for f in "$dropin" "$old_dropin"; do
    [[ -f $f ]] || continue
    sed -n -e "s/^Environment=\(SPECTRUM_DETECTOR_\|SPECTRUM_971_\)\?$1=//p" "$f" | tail -n 1
    return
  done
}
C_mwbd=$(cur_get MIN_WHITE_BLACK_DIFF); C_mwbd=${C_mwbd:-$D_mwbd}
C_mse=$(cur_get MAX_LINE_FIT_MSE); C_mse=${C_mse:-$D_mse}
C_edge=$(cur_get EDGE_BORDER_PX); C_edge=${C_edge:-$D_edge}
C_refine=$(cur_get GPU_REFINE); C_refine=${C_refine:-$D_refine}
C_graphs=$(cur_get GRAPHS); C_graphs=${C_graphs:-$D_graphs}
C_chain=$(cur_get CHAIN); C_chain=${C_chain:-$D_chain}
C_jpeg=$(cur_get SPECTRUM_JPEG_DECODER); C_jpeg=${C_jpeg:-$D_jpeg}
C_connections=$(cur_get CUDA_DEVICE_MAX_CONNECTIONS); C_connections=${C_connections:-$D_connections}
mwbd=""; jpeg=""; mse=""; edge=""; connections=""; refine=""; level=""; graphs=""; chain=""; far=""
defaults=0
restart=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --mwbd) mwbd=$2; shift 2 ;;
    --mse) mse=$2; shift 2 ;;
    --defaults) defaults=1; shift ;;
    --edge) edge=$2; shift 2
            [[ $edge =~ ^[0-9]+$ ]] || { echo "--edge must be a whole number of pixels" >&2; exit 1; } ;;
    --jpeg) jpeg=$2; shift 2
            [[ $jpeg == nvjpg || $jpeg == turbo ]] || { echo "--jpeg must be nvjpg or turbo" >&2; exit 1; } ;;
    --gpu-connections) connections=$2; shift 2
            [[ $connections =~ ^[0-9]+$ && $connections -ge 1 && $connections -le 32 ]] ||
              { echo "--gpu-connections must be 1 to 32" >&2; exit 1; } ;;
    --gpu-refine) refine=$2; shift 2
            [[ $refine =~ ^[0-4]$ ]] || { echo "--gpu-refine must be 0 to 4" >&2; exit 1; } ;;
    --gpu-level) level=$2; shift 2
            level_settings "$level" > /dev/null || { echo "--gpu-level must be 0 to 5 (or list)" >&2; exit 1; } ;;
    --graphs) graphs=$2; shift 2
            [[ $graphs == [01] ]] || { echo "--graphs must be 0 or 1" >&2; exit 1; } ;;
    --chain) chain=$2; shift 2
            [[ $chain == [01] ]] || { echo "--chain must be 0 or 1" >&2; exit 1; } ;;
    --far) far=$2; shift 2
            [[ $far == on || $far == off ]] || { echo "--far must be on or off" >&2; exit 1; } ;;
    --no-restart) restart=0; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

# The level fills in whatever wasn't given explicitly.
if [[ -n $level ]]; then
  read -r l_refine l_graphs l_chain l_far <<< "$(level_settings "$level")"
  # level 5 is detector-18's float decode; a build without it gets detector-17's
  if [[ -z $refine && $l_refine == 4 ]] && ! grep -qa DecodeQuadsKernelF "$HOME/build/gpu-detector/libspectrum-gpu-apriltag.so" /usr/lib/libspectrum-gpu-apriltag.so 2>/dev/null; then
    l_refine=3; echo "level 5: no float decode (detector-18) built; using --gpu-refine 3 (detector-17)" >&2
  fi
  refine=${refine:-$l_refine}; graphs=${graphs:-$l_graphs}; chain=${chain:-$l_chain}; far=${far:-$l_far}
fi
# Not given (by a flag or the level): keep the current value, or the default with --defaults.
for k in mwbd mse edge jpeg connections refine graphs chain; do
  if [[ -z ${!k} ]]; then
    if ((defaults)); then src=D_$k; else src=C_$k; fi
    printf -v "$k" '%s' "${!src}"
  fi
done
if [[ $graphs == 0 && -n $refine && $refine -ge 2 ]]; then
  echo "Note: --gpu-refine $refine runs inside the stage graphs; with --graphs 0 it does nothing" >&2
fi
if [[ $refine == 4 && -f /usr/lib/libspectrum-gpu-apriltag.so ]] && ! grep -qa DecodeQuadsKernelF /usr/lib/libspectrum-gpu-apriltag.so; then
  echo "Note: the installed detector has no float decode (detector-18): 4 acts as 3 or less" >&2
fi

case $which in
  bos) echo "Note: \"bos\" is now called \"gpu\" (2026-10-31 rename)"; which=gpu ;;
  4143) echo "Note: \"4143\" is now called \"gpu-4143\" (2026-10-31 rename)"; which=gpu-4143 ;;
esac
case $which in
  gpu-4143) lib=$HOME/build/GpuDetectorJNI/build/lib971apriltag.so ;;
  gpu) lib=$HOME/build/gpu-detector/libspectrum-gpu-apriltag.so
       # Built before the rename (~/build/bos-detector/lib971apriltag.so): rerun 07 to move it.
       if [[ ! -f $lib && -f $HOME/build/bos-detector/lib971apriltag.so ]]; then
         lib=$HOME/build/bos-detector/lib971apriltag.so
       fi ;;
  *) echo "first argument must be gpu or gpu-4143" >&2; exit 1 ;;
esac
[[ -f $lib ]] || { echo "Missing $lib; build it first." >&2; exit 1; }

nvjpg=$(dirname "$lib")/libspectrumnvjpg.so
if [[ $jpeg == nvjpg && ( $which != gpu || ! -f $nvjpg ) ]]; then
  echo "--jpeg nvjpg needs the gpu build's libspectrumnvjpg.so (07-build-gpu-detector.sh)" >&2
  exit 1
fi

sudo install -m 755 "$lib" /usr/lib/libspectrum-gpu-apriltag.so
# The old name, for PhotonVision jars from before the 2026-10-31 rename (they load lib971apriltag).
sudo ln -sfn libspectrum-gpu-apriltag.so /usr/lib/lib971apriltag.so
if [[ $which == gpu && -f $nvjpg ]]; then
  sudo install -m 755 "$nvjpg" /usr/lib/libspectrumnvjpg.so
fi

# Rewritten whole each time (from the kept + changed values above), so settings under their old
# names (SPECTRUM_971_*, in 971.conf before the 2026-10-31 rename) become SPECTRUM_DETECTOR_* ones.
if [[ -f $old_dropin ]]; then
  echo "Replacing $old_dropin (old SPECTRUM_971_* names) with $dropin"
  sudo rm -f "$old_dropin"
fi
# Any other drop-in (a hand-made test one) with the old names: rename them in place.
for f in /etc/systemd/system/photonvision.service.d/*.conf; do
  if [[ -f $f ]] && grep -q 'SPECTRUM_971_' "$f"; then
    echo "Renaming SPECTRUM_971_* to SPECTRUM_DETECTOR_* in $f"
    sudo sed -i 's/SPECTRUM_971_/SPECTRUM_DETECTOR_/g' "$f"
  fi
done
env_lines="Environment=CUDA_DEVICE_MAX_CONNECTIONS=$connections"$'\n'
[[ -n $mwbd ]] && env_lines+="Environment=SPECTRUM_DETECTOR_MIN_WHITE_BLACK_DIFF=$mwbd"$'\n'
[[ -n $mse ]] && env_lines+="Environment=SPECTRUM_DETECTOR_MAX_LINE_FIT_MSE=$mse"$'\n'
[[ -n $edge && $edge != 0 ]] && env_lines+="Environment=SPECTRUM_DETECTOR_EDGE_BORDER_PX=$edge"$'\n'
[[ -n $refine && $refine != 0 ]] && env_lines+="Environment=SPECTRUM_DETECTOR_GPU_REFINE=$refine"$'\n'
[[ $graphs == 0 ]] && env_lines+="Environment=SPECTRUM_DETECTOR_GRAPHS=0"$'\n'
[[ $chain == 0 ]] && env_lines+="Environment=SPECTRUM_DETECTOR_CHAIN=0"$'\n'
[[ $jpeg == nvjpg ]] && env_lines+="Environment=SPECTRUM_JPEG_DECODER=nvjpg"$'\n'
changed=""
for k in mwbd mse edge jpeg connections refine graphs chain; do
  c=C_$k
  [[ ${!c} != "${!k}" ]] && changed+=" $k ${!c:-unset} -> ${!k:-unset};"
done
printf '[Service]\n%s' "$env_lines" | sudo tee "$dropin" >/dev/null
sudo systemctl daemon-reload

echo "Changed:${changed:- nothing (all settings kept)}"
echo "Selected $which detector${level:+, GPU level $level}${mwbd:+, min_white_black_diff $mwbd}${mse:+, max_line_fit_mse $mse}${edge:+, edge border $edge px}${jpeg:+, JPEG decoder $jpeg}${refine:+, GPU refine $refine}${graphs:+, graphs $graphs}${chain:+, chain $chain}, $connections GPU connections"
if [[ -n $level ]]; then
  level_list | awk -v l="$level" '/^$/ { on = 0 } $1 ~ /^[0-5]$/ { on = ($1 == l) } on' | sed 's/^/  /'
fi
# Far search: a PhotonVision setting (saved in its robot state), live through its API.
if [[ -n $far ]]; then
  v=$([[ $far == on ]] && echo true || echo false)
  if curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
       -d "{\"farSearch\": $v}" localhost:5800/api/robotState 2>/dev/null | grep -q 200; then
    echo "Far search $far (PhotonVision robot state; live)"
  else
    echo "Couldn't reach PhotonVision: set far search $far in Settings > Robot state" >&2
  fi
fi
if [[ $restart -eq 1 ]]; then
  sudo systemctl restart photonvision
fi
