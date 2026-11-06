# A data area for the SystemCore / DIY SystemCore Pis (plan, 2026-11-06)

**Status: plan only.** Nothing has been changed on any Pi. The read-only check below was run on the bench Pi.
Execution waits until someone is at the bench who can replug and power-cycle.

**Goal.** As on the Jetson (`10-data-partition.sh`, `spectrum-data-fallback.sh`, `ro-root.sh`), everything
written while the robot runs goes to its own storage, so a power cut mid-write can't damage the system:
- PhotonVision's settings and logs;
- Rewind;
- the system journal;
- test data.

Several Pis (the bench Pi plus a couple more for small training robots, running the DIY SystemCore image in place
of real SystemCores) should get the same setup from one repeatable procedure.

## Summary

- **Not a partition: two ext4 filesystems at fixed offsets in the card's free space, attached as loop devices
  at boot.** A data partition (growing extended p4 and adding logical p7) gets deleted by LimelightOS itself:
  - its first-boot script `expandfs.sh` rewrites the extended partition to an exact size whenever p4 differs;
  - that happens at first boot, and again after every OTA into slot A (the new rootfs has no
    `/var/lib/partitions-expanded`).
  - The rewrite drops p7's entry. The data would stay on the card but become unreachable.
- The loop approach never touches the partition table, so there is no boot risk. It survives LimelightOS OTA
  updates, and it is identical on every Pi.
- **Re-imaging buys no better layout.** The layout is decided by LimelightOS's own image and `expandfs.sh`,
  not by us:
  - the image is 2.3 GB, with a packed p5 and a placeholder p6, and `expandfs` grows them to 7 GiB each;
  - all four MBR primary slots are taken;
  - a p7 added to the image is dropped at first boot.
- **Recommendation.** One scripted procedure for every Pi: the vendor image (DIY README), then
  `scripts/systemcore/sc-data.sh apply`.
  - On the bench Pi, apply it in place: same end state, no re-flash.
  - Re-image only when replacing a card. The bench card reports a 2014 manufacturing date; a new
    high-endurance card is worth it.

## What LimelightOS does (read from the bench Pi, `LIMELIGHTOS_SYSTEMCORE_BETA` beta18)

| Item | Finding |
|---|---|
| Card | 32 GB SD (61,407,232 sectors, OEM `0x534d`, dated 07/2014), MBR `0x9ccec994` |
| Partitions | p1 16 MiB vfat (`autoboot.txt`), p2/p3 64 MiB vfat (boot A/B: kernel `Image`, dtbs, `config.txt`, `cmdline.txt`), p4 extended 296960-29661183, p5 7 GiB ext4 rootfs A (root now), p6 7 GiB ext4 rootfs B. **~15.1 GiB free after p4** (it holds old data, no filesystem signature) |
| Boot | `autoboot.txt`: `tryboot_a_b=1`, `boot_partition=2`, `[tryboot] boot_partition=3`. p2's `cmdline.txt` has `root=/dev/mmcblk0p5`, p3's has `root=/dev/mmcblk0p6`. An update tries the other slot with tryboot and keeps it if it comes up |
| OTA (`limelight_updatemanager`, `.llupdate`) | Per `expandfs.sh`: "an OTA update overwrites the target slot wholesale (dd of a full rootfs image)", plus that slot's boot partition. **Nothing installed on the old slot survives** (PhotonVision in /opt, our units, /etc). Whether the updater copies any settings (team number, Wi-Fi) is not verified |
| `limelight_expandfs.service` -> `/usr/local/bin/expandfs.sh` | First boot (no `/var/lib/partitions-expanded`): grows p5 to 7 GiB and recreates p6 at p5 + 7 GiB + 1 MiB. "It never fills the disk". It checks the table (p4's exact size, p5/p6 start and size). When the check fails and root is p5, it **rewrites p4-p6 from a generated table**: p7 and the EBR chain are not carried over. After an OTA, the new slot's rootfs lacks the marker, so the check runs again |
| "Platform Persistent Storage Archival" | systemd's `systemd-pstore.service`: copies kernel crash records (ramoops, `reserve_mem` in cmdline) from `/sys/fs/pstore` to `/var/lib/systemd/pstore` after a crash. Small and rare; not a data store |
| Journal | `Storage=persistent`, `SyncIntervalSec=500ms`, `SystemMaxFiles=20`: **397 MB in `/var/log/journal` on the root fs, synced every 0.5 s**. The biggest steady writer to the system partition |
| Root fs | ext4 `rw,noatime`, fstab pass 1, max mount count -1, check interval 0 (fsck only when needed) |
| Tools | GNU bash, util-linux `sfdisk`, `blkid`, `blockdev`; e2fsprogs (`e2fsck`, `mkfs.ext4`). **busybox `losetup`** (no `--sizelimit`, no `--direct-io`). No `mkfs.f2fs`. Loop driver built in |
| Our writers today | PhotonVision `/opt/photonvision/photonvision_config` (6.8 MB: DB, logs, imgSaves), `/opt/photonvision/rewind`, sc-vision CSVs and test data in `/home/systemcore` (1.8 GB), journald |

## Options compared

| | (a) In place, partition (grow p4 + logical p7) | (b) Re-image with a data partition in the image | (c) **Loop areas at fixed offsets** (recommended; in place or after a re-image) |
|---|---|---|---|
| Partition-table change | yes, on the live boot disk | yes (we'd edit the image) | **none** |
| Survives first boot | yes (marker present) | **no**: `expandfs` rewrites p4-p6 and drops p7 | yes |
| Survives an OTA into slot A | **no**: the new rootfs has no marker, so `expandfs` rewrites the table | no | **yes** (`expandfs` never writes past p6's end) |
| Boot risk | low-medium (extended-partition rewrite on the boot disk) | low | **none** |
| Visible to partition tools | yes | yes | no: found by `blkid -p -O OFFSET` and by its label |
| Work per Pi | script | image build + flash | script (`sc-data.sh`) |

Making (a) or (b) stick would mean patching `expandfs.sh` in every image and after every OTA, or re-adding p7
from our own boot unit, which rewrites the boot disk's table at boot. Both are worse than (c).

## The layout (`sc-data.sh`)

Offsets are computed from the table: right after the last partition, 1 MiB aligned with 1 MiB gaps. They are
recorded in `/etc/spectrum-sc-data.conf` and are checked against each filesystem's label at every mount.

| Area | Bench Pi (computed by `check`) | Mount | Options | Holds |
|---|---|---|---|---|
| `SC_SETTINGS` | 1 GiB at 14,484 MiB | `/data/settings` | `noatime,sync,data=journal,errors=remount-ro` | PhotonVision's `photonvision_config` (database, calibrations, camera identities) |
| `SC_SCRATCH` | 14,474 MiB at 15,509 MiB (to the end of the card minus 1 MiB) | `/data/scratch` | `noatime,commit=5,errors=remount-ro` (data=ordered) | Rewind, PhotonVision's logs, the journal, test data (move `~/bench`, `~/fw` etc. there by hand) |

Bind mounts (as on the Jetson):
- `/data/settings/photonvision_config` -> `/opt/photonvision/photonvision_config`
- `/data/scratch/pv-logs` -> `/opt/photonvision/photonvision_config/logs`
- `/data/scratch/rewind` -> `/opt/photonvision/rewind`
- `/data/scratch/journal` -> `/var/log/journal`

**Filesystem choice.** ext4: `mkfs.ext4 -b 4096 -m 1 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0`, then
`tune2fs -c 0 -i 0`.
- f2fs is not an option: no tools on LimelightOS, and no clear power-loss advantage on SD.
- `data=journal,sync` on the settings area: the same choice as the Jetson's SPECTRUM_SETTINGS. Writes are rare
  and each one is durable at once.
- The scratch area keeps ordered mode and 5 s commits: video and logs are expendable, but metadata stays
  consistent.
- **Loop caveats:**
  - busybox `losetup` can't limit size, so each loop device runs to the end of the card. Each filesystem's
    size is fixed by mkfs: **never `resize2fs` them**.
  - Without direct I/O, writes pass through the card's page cache (double caching). Flushes still reach the
    card: an fsync on the loop device flushes the backing device.

**At boot** (`spectrum-sc-data.service`, `DefaultDependencies=no`, before `systemd-journal-flush`, local-fs,
PhotonVision and sc-vision), `attach.sh` runs:
1. Refuses an area that overlaps any partition.
2. Attaches the area at its offset and checks the label.
3. Runs `e2fsck -p` (fsck on every boot: fast when clean; repairs after a power cut).
4. Mounts it and makes the binds.
5. Records the result in `/run/spectrum-sc-data-status`.

**If an area is missing or damaged** (wrong label, unrepairable fsck, overlap):
- Nothing is formatted.
- Scratch missing: PhotonVision's logs and the journal go to RAM (tmpfs), and Rewind gets a 1 MB RAM folder, so
  it finds no space and doesn't record. The match still runs.
- Settings missing: PhotonVision uses the copy of `photonvision_config` on the system partition (the one under
  the bind), i.e. the settings as of `apply`.
  - Commit later changes back to the system partition with `sudo rsync -a /data/settings/photonvision_config/
    /opt/photonvision/photonvision_config.lastgood/`. This step is not automated yet; the Jetson's
    `--commit-settings` is the model.

## Dry run (read-only; run on the bench Pi 2026-11-06)

```bash
scp scripts/systemcore/sc-data.sh systemcore@172.26.0.1:/tmp/   # or the repo checkout on the Pi
ssh systemcore@172.26.0.1 sudo bash /tmp/sc-data.sh check
```
Output on the bench Pi:
```
disk /dev/mmcblk0: 29984 MiB, last partition ends at 14483 MiB
(p1-p6 as above)
root: /dev/mmcblk0p5   expandfs marker: present
SC_SETTINGS at 14484 MiB, 1024 MiB: signature:
SC_SCRATCH  at 15509 MiB, 14474 MiB: signature:
sizes to move: 6.8M photonvision_config, 8.0K rewind, 396.8M /var/log/journal
check: OK (apply would create only the missing filesystems)
```
`check` reads the table (`sfdisk -d`), the disk size, filesystem signatures at both offsets (`blkid -p -O`),
the expandfs marker and the sizes to move. It refuses on overlap, on a foreign signature, or with less than
4 GiB free. It writes nothing.

## Provisioning a Pi (repeatable; at the bench)

1. **Card.** A new high-endurance 32 GB or larger microSD. Flash the vendor image per DIYsystemcore README step
   2 (`limelightsystemcorebetacm5-limelightosr-2027.0.0-beta18`, Pi Imager "Use custom", no OS customization).
   CAN overlays: README step 3, or `install.sh auto` in step 5.
2. **First boot.**
   - Let `expandfs` finish: `systemctl status limelight_expandfs` shows success, and
     `/var/lib/partitions-expanded` exists. p5/p6 are then 7 GiB each.
   - Dashboard: team 3847, Wi-Fi (README step 4).
3. **DIY bring-up:** `cd ~/pi-setup && sudo ./install.sh auto`. Run `patch-vision-ports.sh` only if using
   Limelight's vision servers. Reboot.
4. **Data area:**
   - `sudo scripts/systemcore/sc-data.sh check`: must say OK.
   - `sudo scripts/systemcore/sc-data.sh apply --yes`: creates SC_SETTINGS/SC_SCRATCH (about 1-2 min for mkfs
     with eager init), installs and enables `spectrum-sc-data.service`, mounts, makes the binds, and copies the
     existing PhotonVision config and journal across. PhotonVision is stopped meanwhile; nothing is deleted.
   - `sudo reboot`, then `sudo sc-data.sh status`: all six mounts present, `boot: SC_SETTINGS:ok SC_SCRATCH:ok`.
5. **Vision:**
   - Install the PhotonVision fork and sc-vision (`sc/mjpeg-napa`: `scripts/systemcore/` install scripts). Their
     config now lands on SC_SETTINGS and their logs and Rewind on SC_SCRATCH.
   - Point sc-vision CSVs and test data at `/data/scratch/...`.
6. **Cameras:**
   - Give each one a serial: Thriftiest `thriftiest-fw.py rename` (stored in the camera's flash); Swyft via
     Swyft's tool on a laptop.
   - PhotonVision then knows each camera by serial, so its pipeline and calibration (in the database on
     SC_SETTINGS) follow the camera to any port and survive OTAs.
   - Calibrate once per camera and back up: `scp -r systemcore@PI:/data/settings/photonvision_config backups/PI/`.
7. **Power-cut test** (once per card type, someone present):
   - Pull power while Rewind records, three times.
   - Each boot comes up with `status` all ok.
   - `journalctl -b -u spectrum-sc-data` shows only fsck journal replays.
   - Root unaffected: `sudo tune2fs -l /dev/mmcblk0p5 | grep -i state` says clean after boot.

The bench Pi skips step 1-3 (already provisioned): steps 4-7 in place.

## After a LimelightOS / DIY image update

- **An OTA (`.llupdate`)** writes the other slot's rootfs and boot files and boots it. The new slot has no
  PhotonVision, no sc-vision, no `spectrum-sc-data.service` and no DIY CAN service.
  - The data areas themselves are untouched: they lie past p6's end, where `expandfs` and the updater never
    write.
  - After the update, re-run steps 3-5. `apply --yes` finds SC_SETTINGS/SC_SCRATCH by label and **reuses them**
    (it only creates what's missing), so the settings, calibrations and Rewind come back.
  - Re-check the DIY overlays (DIY README "Image updates").
- **A full re-flash of the card** writes the 2.3 GB image from sector 0. The areas at 14+ GiB are not
  overwritten by the image, and `expandfs` recreates the same table, so `apply --yes` usually finds them again.
  Don't rely on it: an imager may wipe the whole card. **Back up `/data/settings` first.**
- **A future LimelightOS that changes the layout** (bigger slots, its own data partition): at every boot,
  `attach.sh` refuses an area that overlaps a partition or carries a foreign label, and `check` and `apply`
  stop. The fix then is to re-run `check` and move the areas (copy off, remove, apply).

## Rollback

The partition table is never changed, so a rollback can't break booting.
- `sudo scripts/systemcore/sc-data.sh remove --yes`:
  - stops PhotonVision and sc-vision;
  - unmounts the binds (the journal goes back to the root fs first) and copies the PhotonVision config back to
    the system partition;
  - unmounts and detaches the areas;
  - disables and deletes the unit, `attach.sh` and the conf.
- The filesystems stay on the card; `apply --yes` reuses them.
- To also wipe them (only after a backup): attach with
  `L=$(sudo losetup -f); sudo losetup -o OFFSET $L /dev/mmcblk0; sudo wipefs -a $L; sudo losetup -d $L`, for
  each offset in `/etc/spectrum-sc-data.conf`.
- If the Pi ever failed to boot with the unit enabled: it can't block boot (it never fails, and the binds are
  plain mounts), but `sudo systemctl disable spectrum-sc-data` from the dashboard terminal turns it off.

## The real SystemCore (CM5, eMMC)

- **Storage.** `/dev/mmcblk0` is the CM5's eMMC (`/sys/block/mmcblk0/device/type` reads `MMC`, not `SD`). eMMC
  has power-loss protection and reliable cache flushes. SD cards can corrupt blocks they weren't writing when
  power drops mid-erase. A data area helps on both, but it can't make an SD card power-loss safe: use
  high-endurance or industrial cards on the Pis.
- **Image.** It runs the CM5 build of the same LimelightOS (the DIY Pis use exactly that image), so expect the
  same A/B layout and `expandfs`. Capacity may differ, and `check` computes from the device. Run `check` on a
  real SystemCore before applying.
- **Its own media.** It has USB ports, and WPILib's DataLog writes to a USB stick when one is present. Robot
  logs can stay on USB, separate from this.
- If FIRST or Limelight ship their own data partition later, use it instead.

## Open points

- Things to verify while applying:
  - busybox `losetup -a` output (`attach.sh` uses it only to reuse an existing loop device);
  - the unit's ordering against journald flush on LimelightOS;
  - whether an OTA carries anything in /etc or /home across.
- Limelight's own services may write to the root fs (update downloads, vision-server logs). Measure with
  `fatrace` or `iotop` during a match-length run before declaring the root write-free. A read-only root
  (Jetson `ro-root.sh`) is the next step after that.
