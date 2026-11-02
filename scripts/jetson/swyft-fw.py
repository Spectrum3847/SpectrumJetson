#!/usr/bin/env python3
"""Swyft USB Camera firmware tool, run ON THE JETSON (sudo).

  sudo python3 swyft-fw.py list [--json]                 # every Swyft: port, serial, chip status
  python3 swyft-fw.py check-image FILE.rfw              # what a firmware file is (no camera needed)
  python3 swyft-fw.py diff A.bin B.bin                  # bytes that differ between two images/dumps
  sudo python3 swyft-fw.py dump --port 2.4 OUT.bin      # read the camera's whole flash (128 KiB)
  sudo python3 swyft-fw.py flash --port 2.4 FILE.rfw [--serial SJ-SW01] --yes

The Swyft USB Camera (SR-CAMERA-OV9281-USBC-01, swyftrobotics.com) is a Realtek UVC bridge (USB
0bda:3035) with a 128 KiB SPI flash. Swyft's firmware download (LowExposureSWYFTUSBCameraSerial.zip:
LowExposureSWYFTUSBOV9281.rfw, minimum exposure 0.244 ms; SWYFTUSBOV9281.rfw, 3.91 ms) comes with a
Windows-only flasher, Realtek's CameraDump renamed. This does what that tool does, as captured from it
on 2026-10-30 (docs/SWYFT-CAMERA-FIRMWARE.md):

  1. Normal firmware, through the extension unit {1229a78c-47b4-4094-b0ce-db07386fb938} (selector 10:
     an 8-byte command, selector 11: its data): check the chip ("REALSIL"), write 1 to XDATA 0xFF92,
     then vendor request 0x01 (wIndex 7). The camera drops off USB and comes back as its boot loader,
     0bda:5842 "USB Boot".
  2. Boot loader, vendor requests to the device: set up the SPI controller, clear write protection,
     erase the chip, write 128 KiB in 4 KiB blocks, read it all back, write the 55 AA tag at 0x0FFE
     last (a flash cut off before it never boots), protect the flash again, and boot the new firmware.

A backup of the whole flash is saved first (--backup-dir), read twice and compared. PhotonVision must
be stopped (its camera watchdog resets a camera that stops streaming), and this detaches the video
driver from the camera's control interface while it talks to it. Needs pyusb (sudo apt install
python3-usb).
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:  # check-image and diff run on a laptop without pyusb
    usb = None

VID = 0x0BDA
PID = 0x3035        # Swyft's application firmware
PID_BOOT = 0x5842   # Realtek boot loader ("USB Boot")
XU_GUID = "1229a78c-47b4-4094-b0ce-db07386fb938"
CMD_SEL, DATA_SEL = 10, 11
SET_CUR, GET_CUR = 0x01, 0x81

FLASH_SIZE, BLOCK = 128 * 1024, 4096
TAG_ADDR, TAG = 0x0FFE, b"\x55\xaa"
CHIP_ID_ADDR, CHIP_ID = 0xFE21, b"\x10\x60"   # what Swyft's camera answers, both modes
BOOT_FLAG = 0xFF92                             # 1, then a reset: boot loader / boot the firmware
# SPI controller registers, and the values Swyft's tool sets around a write (2026-10-30 capture).
SPI_REGS = (0xFEA0, 0xFEA6, 0xFEA1, 0xFEA7)
SPI_WRITE = (0x81, 0x11, 0x0C, 0x0C)
SPI_AFTER = (0x81, 0x10, 0x0C, 0x08)
FLASH_UNPROTECT, FLASH_PROTECT = 0x00, 0x8C    # the flash status register

# Images we know (SHA-256 of the whole file). The serial number is part of the image (a USB string
# record at 0x1785), so a camera's dump only matches when it still has the image's serial.
IMAGES = {
    "84548d18312e6651c5e5a5a225fc4195318b2b6bfb6549d29a2f8f74b2c2fdb1":
        {"name": "low-exposure", "label": "Swyft low exposure (0.244 ms minimum)"},
    "06d95d4f45ec478eabaa7bf802143d51b841c2485f947fa01bd5e3149aac9be3":
        {"name": "stock", "label": "Swyft stock (3.91 ms minimum)"},
    # The stock image ships a placeholder serial entry; this is it with that taken out, which is how
    # describe() sees a stock camera given a serial of its own.
    "e0041d920e72b0960d4df4972e404615469202e34d833dd7a213e258d5c4034d":
        {"name": "stock", "label": "Swyft stock (3.91 ms minimum)"},
    # Read off the robot's Swyft (port 2.4) on 2026-10-30, as it came: neither download.
    "d8370e922342ce6428e1f03ecad232d4b17341925d30f57c588a41462bcece1f":
        {"name": "factory", "label": "Swyft factory, early 2026 (5 ms minimum)"},
}


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def validate_image(img):
    """Why an image isn't a Swyft firmware image, or None."""
    if len(img) != FLASH_SIZE:
        return "%d bytes, not %d" % (len(img), FLASH_SIZE)
    if img[0] != 0x02:
        return "doesn't start with the 8051 reset jump"
    if img[TAG_ADDR:TAG_ADDR + 2] != TAG:
        return "no 55 AA tag at 0x0FFE"
    if b"\x12\x01\x00\x02\xef\x02\x01\x40\xda\x0b\x35\x30" not in img:
        return "no 0bda:3035 USB device descriptor"
    return None


# The record table at 0xAE00 overrides the firmware's built-in USB strings: header 55 A5 92, total
# length (16-bit, header included), entry count; then entries [length, type, payload], where types
# 01/02/03 are the manufacturer, product and serial strings and the payload is a USB string
# descriptor with ASCII text (bLength, 03, text). Swyft's tool sets a serial by adding or replacing
# the type 03 entry: nothing else in the image changes (2026-10-30 capture, SJ-SW02).
TABLE, TABLE_MAGIC, TABLE_END = 0xAE00, b"\x55\xa5\x92", 0xB000
STR_SERIAL = 0x03


def read_table(img):
    """[(type, payload)] from the record table, or None if the image has none."""
    o = TABLE
    if len(img) < o + 6 or img[o:o + 3] != TABLE_MAGIC:
        return None
    total, count = img[o + 3] | img[o + 4] << 8, img[o + 5]
    if o + total > min(len(img), TABLE_END):
        return None
    entries, p = [], o + 6
    for _ in range(count):
        if p >= o + total:
            return None
        n = img[p]
        if n < 2 or p + n > o + total:
            return None
        entries.append((img[p + 1], bytes(img[p + 2:p + n])))
        p += n
    return entries if p == o + total else None


def with_table(img, entries):
    body = b"".join(bytes([len(p) + 2, t]) + p for t, p in entries)
    total = 6 + len(body)
    old = read_table(img)
    old_total = 6 + sum(len(p) + 2 for _, p in old)
    if TABLE + max(total, old_total) > TABLE_END or any(b != 0xFF for b in img[TABLE + old_total:TABLE + total]):
        raise ValueError("the record table has no room for that")
    out = bytearray(img)
    out[TABLE:TABLE + old_total] = b"\xff" * old_total
    out[TABLE:TABLE + total] = TABLE_MAGIC + bytes([total & 0xFF, total >> 8, len(entries)]) + body
    return bytes(out)


def serial_of(img):
    """The serial number the camera reports: the record table's, else the built-in one after "Generic"."""
    for t, p in read_table(img) or []:
        if t == STR_SERIAL and len(p) >= 2 and p[1] == 0x03:
            return p[2:p[0]].decode("ascii", "replace")
    i = img.find(b"\x09\x03Generic")
    if i < 0:
        return None
    j = i + 9
    if j + 2 > len(img) or img[j] < 2 or j + img[j] > len(img) or img[j + 1] != 0x03:
        return None
    return img[j + 2:j + img[j]].decode("ascii", "replace")


def with_serial(img, serial):
    """The image with this serial number, as Swyft's tool writes it."""
    if not serial or len(serial) > 32 or not all(c.isascii() and (c.isalnum() or c == "-") for c in serial):
        raise ValueError("serials are 1-32 letters, digits and dashes")
    entries = read_table(img)
    if entries is None:
        raise ValueError("this image has no record table at 0x%04X" % TABLE)
    record = (STR_SERIAL, bytes([len(serial) + 2, 0x03]) + serial.encode("ascii"))
    kept = [e for e in entries if e[0] != STR_SERIAL]
    return with_table(img, kept + [record])


def without_serial(img):
    """The image as published: the serial entry taken out (to tell which image a camera runs)."""
    entries = read_table(img)
    if not entries or not any(t == STR_SERIAL for t, _ in entries):
        return img
    return with_table(img, [e for e in entries if e[0] != STR_SERIAL])


def describe(img):
    return IMAGES.get(hashlib.sha256(img).hexdigest()) or IMAGES.get(hashlib.sha256(without_serial(img)).hexdigest())


def guid(b):
    h = lambda r: "".join("%02x" % b[i] for i in r)
    return "-".join([h([3, 2, 1, 0]), h([5, 4]), h([7, 6]), h([8, 9]), h(range(10, 16))])


def find_xu(dev):
    """(extension unit ID, control interface number) of Realtek's command unit."""
    for intf in dev.get_active_configuration():
        if intf.bInterfaceClass != 0x0E or intf.bInterfaceSubClass != 0x01:
            continue
        extra, o = bytes(intf.extra_descriptors), 0
        while o + 2 < len(extra) and extra[o] >= 3:
            n = extra[o]
            if extra[o + 1] == 0x24 and extra[o + 2] == 0x06 and n >= 24 and guid(extra[o + 4:o + 20]) == XU_GUID:
                return extra[o + 3], intf.bInterfaceNumber
            o += n
    return None


def port_of(dev):
    return "%d-%s" % (dev.bus, ".".join(map(str, dev.port_numbers or ())))


def cameras(pid=None):
    found = []
    for p in ([pid] if pid else [PID, PID_BOOT]):
        found += list(usb.core.find(find_all=True, idVendor=VID, idProduct=p))
    return found


def find_camera(port, pid=None):
    """port: '2.4' (as PhotonVision and health-check.sh show it) or '1-2.4'."""
    m = [d for d in cameras(pid) if port_of(d) == port or port_of(d).split("-", 1)[1] == port]
    return m[0] if len(m) == 1 else None


def wait_for(port, pid, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        d = find_camera(port, pid)
        if d:
            return d
        time.sleep(0.4)
    return None


class App:
    """The camera on its application firmware: commands through the extension unit."""

    def __init__(self, dev):
        self.dev = dev
        xu = find_xu(dev)
        if not xu:
            die("camera on %s has no Realtek command extension unit" % port_of(dev))
        self.unit, self.intf = xu
        self.detached = False
        if dev.is_kernel_driver_active(self.intf):
            dev.detach_kernel_driver(self.intf)   # uvcvideo; re-attached in close()
            self.detached = True

    def _xu(self, req, sel, data):
        rt = 0xA1 if req & 0x80 else 0x21
        return self.dev.ctrl_transfer(rt, req, sel << 8, self.unit << 8 | self.intf, data, timeout=5000)

    def command(self, op, addr=0, length=0):
        self._xu(SET_CUR, CMD_SEL, bytes([0x00, op, addr & 0xFF, addr >> 8, length & 0xFF, length >> 8, 0, 0]))

    def get(self, n):
        r = bytes(self._xu(GET_CUR, DATA_SEL, n))
        if len(r) != n:
            raise IOError("extension unit returned %d bytes, expected %d" % (len(r), n))
        return r

    def qualify(self):
        self.command(0xD0, 0, 8)
        return self.get(8)

    def status(self, page):
        self.command(0xCD, page, 8)
        return self.get(8)

    def read_xdata(self, addr, n):
        self.command(0xC2, addr, n)
        return self.get(n)

    def write_xdata(self, addr, data):
        self.command(0x82, addr, len(data))
        self._xu(SET_CUR, DATA_SEL, bytes(data))

    def check(self):
        if self.qualify() != b"REALSIL\x00":
            die("the camera didn't identify as Realtek (REALSIL); not touching it")
        if self.read_xdata(CHIP_ID_ADDR, 2) != CHIP_ID:
            die("unexpected Realtek chip (0x%04X isn't 10 60); not touching it" % CHIP_ID_ADDR)

    def enter_boot_loader(self):
        """Reboot into the boot loader (0bda:5842); the device drops off USB."""
        self.write_xdata(BOOT_FLAG, [0x01])
        try:
            self.dev.ctrl_transfer(0x40, 0x01, 0, 7, None, timeout=2000)
        except usb.core.USBError:
            pass

    def close(self):
        try:
            usb.util.dispose_resources(self.dev)
            if self.detached:
                self.dev.attach_kernel_driver(self.intf)
        except usb.core.USBError:
            pass


class Boot:
    """The boot loader: vendor requests to the device."""

    def __init__(self, dev):
        self.dev = dev
        self.saved = None

    def _in(self, req, value, index, n):
        r = bytes(self.dev.ctrl_transfer(0xC0, req, value, index, n, timeout=10000))
        if len(r) != n:
            raise IOError("vendor request 0x%02x returned %d bytes, expected %d" % (req, len(r), n))
        return r

    def _out(self, req, value, index, data=None):
        self.dev.ctrl_transfer(0x40, req, value, index, data, timeout=30000)

    def reg(self, addr, n=1):
        return self._in(0x25, 0, addr, n)

    def wreg(self, addr, value):
        self._out(0x24, 0, addr, bytes([value]))

    def check(self):
        if self._in(0x07, 3, 0, 8) != b"REALSIL\x00":
            die("the boot loader didn't identify as Realtek (REALSIL); nothing written")
        if self.reg(CHIP_ID_ADDR, 2) != CHIP_ID:
            die("unexpected Realtek chip in the boot loader; nothing written")

    def spi_setup(self):
        self.saved = [self.reg(a)[0] for a in SPI_REGS]
        for a, v in zip(SPI_REGS, SPI_WRITE):
            self.wreg(a, v)

    def spi_restore(self, values):
        for a, v in zip(SPI_REGS, values):
            self.wreg(a, v)

    def flash_status(self):
        return self._in(0x30, 0, 0, 1)[0]

    def set_flash_status(self, value):
        self._out(0x31, 0, 0, bytes([value]))

    def erase_chip(self):
        self._out(0x32, 0, 0)
        deadline = time.time() + 15
        while self.flash_status() & 0x01:      # write in progress
            if time.time() > deadline:
                raise IOError("chip erase didn't finish")
            time.sleep(0.05)

    @staticmethod
    def where(addr):
        """(wValue, wIndex) for a flash address: wValue << 8 | wIndex. The upper 64 KiB is wValue
        0x0100, as Swyft's tool sends it; wValue 0x0001 reads somewhere else."""
        return addr >> 8 & 0xFF00, addr & 0xFFFF

    def read(self, addr, size, progress=False):
        assert addr % 2 == 0 and addr + size <= FLASH_SIZE
        out = bytearray()
        for a in range(addr, addr + size, BLOCK):
            n = min(BLOCK, addr + size - a)
            out += self._in(0x2E, *self.where(a), n)
            if progress:
                print("\r  reading %3d%%" % (100 * (a - addr + n) // size), end="", flush=True)
        if progress:
            print()
        return bytes(out)

    def write(self, addr, data):
        self._out(0x2F, *self.where(addr), bytes(data))

    def boot_firmware(self):
        """Boot the firmware in flash; the device drops off USB."""
        try:
            self.wreg(BOOT_FLAG, 0x01)
            self._out(0x22, 0, 0)
        except usb.core.USBError:
            pass

    def close(self):
        try:
            usb.util.dispose_resources(self.dev)
        except usb.core.USBError:
            pass


def to_boot_loader(port):
    """The camera on this port, in its boot loader (rebooting it there if it's running its firmware)."""
    dev = find_camera(port)
    if not dev:
        die("no Swyft camera (0bda:3035, or its boot loader 0bda:5842) on port %s" % port)
    full_port = port_of(dev)
    if dev.idProduct == PID:
        app = App(dev)
        try:
            app.check()
            print("Rebooting the camera into its boot loader…")
            app.enter_boot_loader()
        finally:
            app.close()
    dev = wait_for(full_port, PID_BOOT, 20) or die("the camera didn't come back as its boot loader: replug it and retry")
    b = Boot(dev)
    b.check()
    return full_port, b


REPLUG = ("Now power-cycle the robot (main breaker; a Jetson reboot isn't enough), or unplug the camera and\n"
          "plug it back in: after the boot loader its video stays off (it enumerates and answers, but sends\n"
          "no frames) until it loses power, and the Jetson's USB hub can't switch a port's power (2026-10-30).")


def back_to_firmware(full_port, b):
    b.boot_firmware()
    b.close()
    dev = wait_for(full_port, PID, 20)
    if not dev:
        print("The camera didn't restart into its firmware: unplug it and plug it back in (same port).")
        return None
    print(REPLUG)
    return dev


def backup(b, backup_dir, full_port, label):
    print("Backing up the whole flash (twice)…")
    first = b.read(0, FLASH_SIZE, progress=True)
    if b.read(0, FLASH_SIZE) != first:
        die("two backup reads disagree; nothing written")
    os.makedirs(backup_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(backup_dir, "swyft-%s-%s-%s.bin" % (full_port, stamp, label))
    n = 1
    while True:
        try:
            f = open(path, "xb")   # never overwrite an earlier backup
            break
        except FileExistsError:
            n += 1
            path = os.path.join(backup_dir, "swyft-%s-%s-%s-%d.bin" % (full_port, stamp, label, n))
    with f:
        f.write(first)
        f.flush()
        os.fsync(f.fileno())   # on the disk before anything is erased: the robot loses power any time
    try:
        d = os.open(backup_dir, os.O_RDONLY)   # the new file's directory entry; Linux only
        try:
            os.fsync(d)
        finally:
            os.close(d)
    except OSError:
        pass
    print("Backup: " + path)
    return first, path


def write_image(b, image):
    """Erase, write and verify; the image's own tag (55 AA in a good image) goes last, so an
    interrupted write never boots."""
    tag = bytes(image[TAG_ADDR:TAG_ADDR + 2])
    held = bytearray(image)
    held[TAG_ADDR:TAG_ADDR + 2] = b"\xff\xff"
    b.set_flash_status(FLASH_UNPROTECT)
    if b.flash_status() != 0:
        raise IOError("the flash stayed write-protected (status 0x%02x)" % b.flash_status())
    print("Erasing…")
    b.erase_chip()
    if b.read(0, FLASH_SIZE) != b"\xff" * FLASH_SIZE:
        raise IOError("the flash didn't erase")
    for i, a in enumerate(range(0, FLASH_SIZE, BLOCK)):
        print("\r  writing %3d%%" % (100 * (i + 1) * BLOCK // FLASH_SIZE), end="", flush=True)
        b.write(a, held[a:a + BLOCK])
    print()
    if b.read(0, FLASH_SIZE) != bytes(held):
        raise IOError("the flash doesn't read back as written")
    if tag != b"\xff\xff":
        b.write(TAG_ADDR, tag)
        if b.read(TAG_ADDR, 2) != tag:
            raise IOError("the boot tag didn't read back")


def protect(b):
    """SPI controller back as Swyft's tool leaves it, and the flash write-protected."""
    b.spi_restore(SPI_AFTER)
    if b.flash_status() != FLASH_PROTECT:
        b.set_flash_status(FLASH_PROTECT)


# ---- commands -------------------------------------------------------------------------------

def cmd_list(a):
    cams, out = cameras(), []
    for d in sorted(cams, key=port_of):
        port = port_of(d).split("-", 1)[1]
        if d.idProduct == PID_BOOT:
            out.append({"port": port, "bootLoader": True, "serial": None, "revision": None})
            continue
        try:
            serial = usb.util.get_string(d, d.iSerialNumber)
        except (usb.core.USBError, ValueError):
            serial = None
        out.append({"port": port, "bootLoader": False, "serial": serial, "revision": "%04x" % d.bcdDevice})
    if a.json:
        print(json.dumps(out))
        return
    if not out:
        print("No Swyft cameras (0bda:3035) found.")
    for c in out:
        if c["bootLoader"]:
            print("%-8s IN THE BOOT LOADER (re-run flash, or replug it)" % c["port"])
        else:
            print("%-8s serial %-14s firmware revision %s" % (c["port"], c["serial"] or "?", c["revision"]))


def cmd_check_image(a):
    img = open(a.image, "rb").read()
    err = validate_image(img)
    known = describe(img)
    if a.json:
        print(json.dumps({"file": os.path.basename(a.image), "bytes": len(img), "serial": serial_of(img),
                          "image": known["name"] if known else None,
                          "label": known["label"] if known else None, "error": err}))
        sys.exit(1 if err else 0)
    print("%s: %d bytes, serial %s, %s" % (a.image, len(img), serial_of(img) or "?",
                                         known["label"] if known else "unknown image"))
    if err:
        die(err)


def cmd_diff(a):
    x, y = open(a.a, "rb").read(), open(a.b, "rb").read()
    n = min(len(x), len(y))
    diffs = [i for i in range(n) if x[i] != y[i]]
    ranges = []
    for i in diffs:
        if ranges and i <= ranges[-1][1] + 16:
            ranges[-1][1] = i
        else:
            ranges.append([i, i])
    for lo, hi in ranges[:200]:
        print("0x%05x-0x%05x %4d bytes  %s | %s" % (lo, hi, hi - lo + 1, x[lo:hi + 1][:16].hex(), y[lo:hi + 1][:16].hex()))
    print("%d byte(s) differ in %d range(s) over the first %d bytes (%s: %d bytes, %s: %d bytes)"
          % (len(diffs), len(ranges), n, a.a, len(x), a.b, len(y)))


def cmd_dump(a):
    full_port, b = to_boot_loader(a.port)
    try:
        b.spi_setup()
        try:
            data, bpath = backup(b, a.backup_dir, full_port, "dump")
        finally:
            b.spi_restore(b.saved)
    except BaseException:
        b.boot_firmware()
        b.close()
        raise
    print("Restarting the camera…")
    dev = back_to_firmware(full_port, b)
    if dev:
        print("Back on its firmware (revision %04x)." % dev.bcdDevice)
    # Written after the camera is back on its firmware, so a bad output path can't leave it in the
    # boot loader; the same bytes are already in the backup.
    try:
        with open(a.out, "wb") as f:
            f.write(data)
    except OSError as e:
        die("couldn't write %s (%s); the dump is in %s" % (a.out, e, bpath))
    print("Wrote %d bytes to %s (serial %s, %s)" % (len(data), a.out, serial_of(data) or "?",
                                                  (describe(data) or {"label": "unknown image"})["label"]))


def cmd_flash(a):
    img = open(a.image, "rb").read()
    err = validate_image(img)
    if err:
        die(a.image + ": " + err)
    if a.serial:
        try:
            img = with_serial(img, a.serial)
        except ValueError as e:
            die(str(e))
    if not a.yes:
        die("this rewrites the camera's firmware (%s): add --yes"
            % (describe(img) or {"label": "unknown image"})["label"])
    full_port, b = to_boot_loader(a.port)
    erased = False   # once the chip is erased, the camera stays in the boot loader on failure
    try:
        b.spi_setup()
        baseline, bpath = backup(b, a.backup_dir, full_port, (describe(img) or {"name": "image"})["name"])
        if baseline == img:
            print("Already up to date: nothing to write.")
            protect(b)   # a retry after a run that wrote but didn't protect
        else:
            try:
                erased = True
                write_image(b, img)
            except (IOError, usb.core.USBError) as e:
                print("\nWrite failed (%s); putting the original back…" % e)
                try:
                    write_image(b, baseline)
                    protect(b)
                    restored = True
                except (IOError, usb.core.USBError):
                    restored = False
                if restored:
                    back_to_firmware(full_port, b)
                    die("write failed; the original firmware is back (verified). Backup: " + bpath)
                die("write failed and the original is NOT back: the camera is in its boot loader. Keep it"
                    " plugged in and re-run flash (with the backup to restore it): " + bpath)
            print("Written and verified.")
            protect(b)
    except BaseException:
        if not erased:
            b.boot_firmware()   # nothing written: back to its own firmware
        b.close()
        raise
    print("Restarting the camera…")
    dev = back_to_firmware(full_port, b)
    if dev:
        print("Done: back on its firmware (revision %04x), serial %s." % (dev.bcdDevice, serial_of(img) or "?"))


def default_backup_dir():
    """~/swyft-backups of the user who ran sudo, not root's."""
    user = os.environ.get("SUDO_USER")
    return os.path.join(os.path.expanduser("~" + user) if user else os.path.expanduser("~"), "swyft-backups")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("list")
    c.add_argument("--json", action="store_true")
    c = sub.add_parser("check-image")
    c.add_argument("image")
    c.add_argument("--json", action="store_true")
    c = sub.add_parser("diff")
    c.add_argument("a")
    c.add_argument("b")
    for name in ("dump", "flash"):
        c = sub.add_parser(name)
        c.add_argument("--port", required=True, help="USB port as health-check.sh shows it, e.g. 2.4")
        c.add_argument("--backup-dir", default=default_backup_dir())
        if name == "dump":
            c.add_argument("out")
        else:
            c.add_argument("image")
            c.add_argument("--serial", help="serial number to write, e.g. SJ-SW01 (default: the image's)")
            c.add_argument("--yes", action="store_true")
    a = p.parse_args()
    if a.cmd not in ("check-image", "diff"):
        if usb is None:
            die("pyusb isn't installed: sudo apt install python3-usb")
        if os.geteuid() != 0:
            die("needs sudo (raw USB access)")
    # PhotonVision's camera watchdog resets the USB port of a camera that stops streaming, which
    # this does to it; and it would grab the camera as it comes back from the boot loader.
    if a.cmd in ("dump", "flash") and os.system("systemctl is-active --quiet photonvision") == 0:
        die("PhotonVision is running, and its camera watchdog would reset the camera mid-operation:"
            " sudo systemctl stop photonvision first (start it again after)")
    {"list": cmd_list, "check-image": cmd_check_image, "diff": cmd_diff, "dump": cmd_dump,
     "flash": cmd_flash}[a.cmd](a)


if __name__ == "__main__":
    main()
