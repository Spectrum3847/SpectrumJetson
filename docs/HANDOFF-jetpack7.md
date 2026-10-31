# Handoff: moving the Jetson to JetPack 7.2.1 (2026-10-30)

Off-season, for the 2027 season (starts January, first event March). The old SSD gets erased.

## Why

- **The robot's alpha-8 PhotonLib can't read the 2026 Jetson's results.** `PhotonPipelineMetadata`'s
  hash changed (`ac0a45f6…` → `5231116d…`, and so `PhotonPipelineResult`, `4b2ff16a…` → `fd353b11…`):
  `captureTimestampMicros`/`publishTimestampMicros` became `…Nanos`, the values now in nanoseconds.
- **PhotonVision 2027 can't run on JetPack 6.** 39 of the 95 linuxarm64 native libraries in the
  `spectrum-2027` jar (wpiutil, ntcore, cscore, wpimath, wpinet, apriltag, OpenCV, mrcal…) need up to
  glibc 2.38 and `GLIBCXX_3.4.32`; JetPack 6 (Ubuntu 22.04) has 2.35 and 3.4.30. WPILib 2027 builds
  them on Debian 13. See [MAINTENANCE-2027.md](MAINTENANCE-2027.md).
- **JetPack 7.2.1 supports the Orin Nano**: Jetson Linux r39.2.1, Ubuntu 24.04 target (glibc 2.39),
  kernel 6.8, CUDA 13.2.2, cuDNN 9.20.0, TensorRT 10.16.2. Its Orin Nano install needs JetPack 6-era
  QSPI firmware already on the board, which ours has.

## Before erasing

Saved on the laptop (Windows side) in `~/jetson-backup-20261030/jetson-settings-and-backups.tgz`
(117 MB): `/data/settings` (PhotonVision's `photon.sqlite`, calibrations with images, field
calibration, `spectrum/field-map.json`, the Thriftiest firmware files), `~/swyft-backups`,
`~/thriftiest-backups`, `~/pv-backups`. The calibrations themselves are also in this repository,
[calibrations/](../calibrations/README.md) (SJ-TC01 1280x800; SJ-TC02 1280x800 and 320x240): import
them on PhotonVision's Cameras page after the move. Not saved: the scratch partition (8.4 GB: journals,
PhotonVision logs, Rewind recordings): pull with `jetson-pull.sh` / `rewind-pull.sh` if wanted.

## Flash (laptop booted into its Ubuntu 22.04)

NVIDIA's flash host is Ubuntu 22.04 or 20.04 (r39.2.1 quick start). WSL isn't supported (the Jetson
re-enumerates during the flash), and an SSD in an enclosure can't take the QSPI half.

1. `git fetch && git switch jetpack-7` (this branch: `config.env` now defaults to `L4T_VERSION=39.2.1`;
   `L4T_VERSION=36.5.2` for the old one).
2. `scripts/host/01-prepare-bsp.sh`: downloads `Jetson_Linux_R39.2.1_aarch64.tbz2` (1.29 GB) and
   `Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2` (2.02 GB) into `~/nvidia/r39.2.1`,
   extracts, runs `l4t_flash_prerequisites.sh`, `apply_binaries.sh` and `l4t_create_default_user.sh`.
   The last one isn't confirmed to exist in r39: if it's gone, the first-boot setup (oem-config)
   asks for the user instead.
3. Recovery mode (FC REC to GND, pins 9-10 on the button header; or `sudo reboot forced-recovery`),
   then `scripts/host/02-flash-nvme.sh`. It now stops before erasing if r36's layout files
   (`flash_l4t_t234_nvme.xml`, `flash_t234_qspi.xml`) aren't in the r39 BSP; NVIDIA's r39 quick start
   gives the Orin Nano `sudo ./l4t_initrd_flash.sh --erase-all jetson-orin-nano-devkit-super internal`.
   The `nvresizefs` edit for our 64 GiB system partition also stops if r39 changed that script.
4. First boot: select the NVMe in the UEFI menu if asked.

Done 2026-10-30 on the HP EX920 256 GB. The first try failed with the flash initrd unable to use the
SSD (`EMEM address decode error` from pcie4, then the NVMe admin queue timed out and `/dev/nvme0n1`
never appeared). That try had already written r39's QSPI firmware. Unplugging the power for ~10 s,
recovery mode again and a re-run flashed cleanly. If it fails like that: power cycle, don't debug.
r39 has no `nv-late-init.sh`; its cloud-init config already keeps the 64 GiB system partition from
growing, which `02-flash-nvme.sh` now checks. It booted straight from the NVMe, no UEFI menu.

## After the flash (expect work; everything below was written for JetPack 6)

In order, smallest unknowns first:
1. OS basics: `02-jetpack.sh` (JetPack, JDK 25, CUDA and Java paths), power mode MAXN SUPER, locked clocks, fan,
   `10-data-partition.sh`, read-only root, boot time, a reboot that doesn't hang.
2. Cameras and USB: our patched `uvcvideo` (payload cap, hardware timestamps) on kernel 6.8; the USB
   bandwidth caps; PhotonVision's USB recovery (port power toggle) on the new xHCI driver.
3. Upstream alpha-8 PhotonVision with the **CPU** AprilTag pipeline: proves the glibc problem is gone
   and that robot code on alpha-8 PhotonLib reads results (match the hashes above).
4. The CUDA detector (`detector/`, frc971 bos) on CUDA 13, made independent of WPILib as
   MAINTENANCE-2027.md plans (plain JNI, its own `WPI_RawFrame`, static AprilTag, explicit units).
5. NVJPG decoder (Jetson Multimedia API on JetPack 7). TensorRT 10.16 for object detection: deferred
   (2026-10-30), not needed yet.
6. The rest of `spectrum-2027` (Spectrum3847/photonvision, see its SPECTRUM.md): features 2-5 and
   7-14; watch the nine patches that assume microseconds.
