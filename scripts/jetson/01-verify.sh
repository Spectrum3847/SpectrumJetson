#!/usr/bin/env bash
# Post-flash checks. Run ON THE JETSON after first boot.
# Verifies NVMe root, L4T version, and that MAXN SUPER exists, then enables it.
set -uo pipefail

# JetPack 7.2.1 (L4T r39.2.1); "R36 (release), REVISION: 5.2" for a JetPack 6 flash.
EXPECTED_L4T=${EXPECTED_L4T:-"R39 (release), REVISION: 2.1"}
MAXN_SUPER_ID=2
fail=0

check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

root_src=$(findmnt -no SOURCE /)
check "root filesystem on NVMe ($root_src)" '[[ $root_src == /dev/nvme0n1p1 ]]'
check "L4T release is $EXPECTED_L4T" 'grep -q "$EXPECTED_L4T" /etc/nv_tegra_release'
check "MAXN SUPER power mode available" 'grep -q "POWER_MODEL ID=$MAXN_SUPER_ID NAME=MAXN_SUPER" /etc/nvpmodel.conf'

echo
head -1 /etc/nv_tegra_release
sudo nvpmodel -q

if [[ $fail -ne 0 ]]; then
  echo
  echo "One or more checks failed. If MAXN SUPER is missing, the board was not flashed"
  echo "with the jetson-orin-nano-devkit-super config. Do not continue until fixed."
  exit 1
fi

echo
echo "==> Enabling MAXN SUPER (mode $MAXN_SUPER_ID) and max clocks"
# nvpmodel may ask to reboot when switching modes; answer as prompted.
# r39 asks to reboot for MAXN SUPER (answered no: the clocks already go to MAXN SUPER's). Its boot
# default is mode 1 (25 W), so nvpmodel.service then fails at every boot asking again: default to it.
echo no | sudo nvpmodel -m "$MAXN_SUPER_ID" || true
sudo sed -i "s/^< PM_CONFIG DEFAULT=[0-9]* >/< PM_CONFIG DEFAULT=$MAXN_SUPER_ID >/" /etc/nvpmodel.conf
sudo jetson_clocks
sudo nvpmodel -q

echo
echo "All checks passed. Next: scripts/jetson/02-jetpack.sh (installs nvidia-jetpack)"
echo "(the BSP flash does not include CUDA/cuDNN/TensorRT), then check 'nvcc --version'"
echo "with /usr/local/cuda/bin on PATH."
