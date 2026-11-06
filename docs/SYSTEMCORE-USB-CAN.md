# USB CAN adapter on the SystemCore (robot CAN bus 0 = can_s0)

Adapter: Jhoinrch "CAN FD Isolator RH02 PRO" (CANable 2.0 based). On the bench Pi 5 it enumerates as
`16d0:117e MCS CANable2 b158aa7 github.com/normaldotcom/canable2.git`, i.e. the **CANable 2.0 slcan firmware**:
a USB CDC-ACM serial port (`cdc_acm` -> `/dev/ttyACM0`), not `gs_usb`. The kernel (6.12.112-v8-16k) already ships
`slcan.ko`, `gs_usb.ko` and `slcand`/`candump`/`cansend`, so nothing is cross-built.

## What is installed

`scripts/systemcore/usb-can/install-usb-can.sh` (run with sudo on the device):

- `/etc/udev/rules.d/90-sc-usb-can.rules`: tty with 16d0:117e -> `/dev/canable` symlink, wants `sc-usb-can@canable.service`.
- `/etc/systemd/system/sc-usb-can@.service`: `slcand -o -c /dev/canable can_s0`, then bitrate, txqueuelen 1000, up.
- `/etc/systemd/system/can-bringup.service.d/usb-s0.conf`: with the adapter plugged in, `can-bringup.service` waits
  (up to 15 s) for the slcan `can_s0` before `diy-can-setup.sh` runs. That script only makes a vcan when the name is
  free, and loads `robot_heartbeat`/`can_sender` (which bind `can_s*` at load) after it, so the adapter is bus 0
  and `can_s1..can_s4` stay vcan. No adapter at boot: vcan `can_s0` as before.
  Bound to the device: unplug stops it, plug-in (or boot) starts it.
- `/opt/sc-usb-can/usb-can-up.sh`, `/etc/sc-usb-can.conf` (`IFACE=can_s0 BITRATE=1000000 TXQLEN=1000 UP=1`),
  `/etc/modules-load.d/sc-usb-can.conf` (`slcan`).

## Bring up / change rate

```
ip -details link show can_s0        # slcan, not vcan, bitrate 1000000
sudo ip link set can_s0 down
sudo ip link set can_s0 type can bitrate 1000000   # slcan rates only: 10k..1M
sudo ip link set can_s0 up
candump can_s0 / cansend can_s0 123#DEADBEEF
```

**No CAN FD** with this firmware: Linux slcan is classic CAN only (mtu 16, no `dbitrate`/`fd on`). For FD, flash
the CANable 2.0 candleLight/gs_usb FD firmware (STM32G431 DFU via the boot jumper); `gs_usb` then gives a native
`canX` with `dbitrate`. Then replace this udev/slcand setup with a plain rename rule.

## SystemCore names and caveats

The SystemCore stack (WPILib HAL, `can_sender`/`robot_heartbeat` kernel modules, Limelight canbus services) uses
`can_s0`..`can_s4`; HAL bus 0 = `can_s0`. The DIY-SC robot log line `[DIY-SC] alive ... can_s0 status=...` shows it.

- The swap happens at boot only. A live vcan `can_s0` is held by `can_sender`/`robot_heartbeat` (opened by system
  daemons), so the installer doesn't delete it; deleting a referenced netdev can hang in unregister_netdevice.
- Replug at runtime: slcand recreates `can_s0`, but `can_sender` bound the old device at load. Not yet verified
  whether unplug blocks or the heartbeat follows the new device; reboot after a replug until it is.
- `iodaemon`'s "Failed to open USB device" is the SystemCore IO board, unrelated to this adapter.

## Verified after reboot (bench, beta18, WPILib 2027 alpha 8, Phoenix 6 26.70.0-alpha-2)

- `can_s0` = slcan, 1 Mbps, up; `can_s1..s4` vcan. The robot's frames leave on it: `candump -n 12 can_s0` shows
  `02041D41` every 10 ms plus Phoenix `0004xxxx` frames (~186 frames/s TX), RX 0 with nothing else on the bus.
- `CANBus.getStatus()` in the DIYsystemcore-TestRobot prints `status=InvalidNetwork util=~216%` both with the
  vcan `can_s0` (before) and with the adapter (after): it is Phoenix 6's status query on a SystemCore bus in this
  alpha, not the interface. Use `talon.isConnected()` / RX counters as the health signal instead.
- slcan can't report the bus error state or the error counters: `ip -d link` always shows ERROR-ACTIVE, and REC/TEC
  are 0. Unacked frames aren't visible from Linux.
- Talons need a real bus: at least one powered device, plus 120 ohm at each end (the adapter's termination
  switch/jumper on, and the far device or a terminator on the other end). Without an ACKing node the adapter just
  retransmits and RX stays 0.
