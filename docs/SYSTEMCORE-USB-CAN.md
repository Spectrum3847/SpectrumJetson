# USB CAN adapter on the SystemCore (can0)

Adapter: Jhoinrch "CAN FD Isolator RH02 PRO" (CANable 2.0 based). On the bench Pi 5 it enumerates as
`16d0:117e MCS CANable2 b158aa7 github.com/normaldotcom/canable2.git`, i.e. the **CANable 2.0 slcan firmware**:
a USB CDC-ACM serial port (`cdc_acm` -> `/dev/ttyACM0`), not `gs_usb`. The kernel (6.12.112-v8-16k) already ships
`slcan.ko`, `gs_usb.ko` and `slcand`/`candump`/`cansend`, so nothing is cross-built.

## What is installed

`scripts/systemcore/usb-can/install-usb-can.sh` (run with sudo on the device):

- `/etc/udev/rules.d/90-sc-usb-can.rules`: tty with 16d0:117e -> `/dev/canable` symlink, wants `sc-usb-can@canable.service`.
- `/etc/systemd/system/sc-usb-can@.service`: `slcand -o -c /dev/canable can0`, then bitrate, txqueuelen 1000, up.
  Bound to the device: unplug stops it, plug-in (or boot) starts it.
- `/opt/sc-usb-can/usb-can-up.sh`, `/etc/sc-usb-can.conf` (`IFACE=can0 BITRATE=1000000 TXQLEN=1000 UP=1`),
  `/etc/modules-load.d/sc-usb-can.conf` (`slcan`).

## Bring up / change rate

```
ip -details link show can0          # driver slcan, bitrate 1000000
sudo ip link set can0 down
sudo ip link set can0 type can bitrate 1000000   # slcan rates only: 10k..1M
sudo ip link set can0 up
candump can0 / cansend can0 123#DEADBEEF
```

**No CAN FD** with this firmware: Linux slcan is classic CAN only (mtu 16, no `dbitrate`/`fd on`). For FD, flash
the CANable 2.0 candleLight/gs_usb FD firmware (STM32G431 DFU via the boot jumper); `gs_usb` then gives a native
`canX` with `dbitrate`. Then replace this udev/slcand setup with a plain rename rule.

## SystemCore names

The SystemCore stack (WPILib HAL, `can_sender` kernel module, Limelight canbus services) uses `can_s0`..`can_s4`,
created by `can-bringup.service` (`/usr/local/sbin/diy-can-setup.sh`) as SPI-HAT netdevs or `vcan` placeholders.
`can0` is outside that set, so robot code does not see it; to make it a robot bus, set `IFACE=can_sX` in
`/etc/sc-usb-can.conf` after deleting that vcan placeholder (the `can_sender` module binds `can_s*` at its load time).
`iodaemon`'s "Failed to open USB device" is the SystemCore IO board, unrelated to this adapter.
