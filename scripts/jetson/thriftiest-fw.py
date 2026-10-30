#!/usr/bin/env python3
"""Thriftiest Cam firmware and identity tool, run ON THE JETSON (sudo).

  sudo python3 thriftiest-fw.py list [--identity]          # every Thriftiest Cam: port, firmware (, name)
  sudo python3 thriftiest-fw.py check-image FILE.bin       # what a firmware file is (no camera needed)
  python3 thriftiest-fw.py diff A.bin B.bin               # bytes that differ between two images/dumps
  python3 thriftiest-fw.py variant [--json]                # which firmware each camera runs, while it streams
  sudo python3 thriftiest-fw.py dump --port 2.1 OUT.bin    # read the camera's flash (256 KiB)
  sudo python3 thriftiest-fw.py flash --port 2.1 FILE.bin --yes
  sudo python3 thriftiest-fw.py rename --port 2.1 --name TopLeft --serial TL1 --yes

The same protocol Thrifty Config (2027.0.0-beta.10) uses on macOS and Linux: the camera is a
SunplusIT SPCA2089D UVC bridge (USB 1bcf:28c5), and its 512 KiB SPI flash is read and written
through the vendor's UVC extension-unit controls. Writes go through ROM maintenance mode (the
camera re-enumerates as 1bcf:0b12). Same safety checks as Thrifty Config: the controller and
flash profiles must match, two full backup reads must agree, every erase and 1 KiB program is
read back, the whole flash is compared at the end, and on failure the touched sectors are put
back. A backup of the flash is saved first (--backup-dir). See docs/THRIFTIEST-CAM-FIRMWARE.md.

PhotonVision must be stopped first (its camera watchdog resets a camera that stops streaming);
scripts/host/thriftiest-flash.sh does that and starts it again after.
First used 2026-10-29 on both robot cameras: ~45 s each, and the camera left maintenance mode and
restarted by itself. Needs pyusb: sudo apt install python3-usb, or from a laptop (the Jetson has no
internet) scripts/host/thriftiest-flash.sh, which brings pyusb along.
"""
import argparse
import ctypes
import datetime
import glob
import json
import os
import sys
import time

VID = 0x1BCF
PID = 0x28C5            # application firmware
PID_MAINT = 0x0B12      # ROM maintenance mode ("SPCA2650 PC Camera")

XU_GUIDS = ["63610682-5070-49ab-b8cc-b3855e8d221d", "7d5a1d99-5b32-428b-8cad-671b8a65f37a"]
SEL = dict(REG_ADDR=0x02, REG_DATA=0x03, SPI_SLOT=0x07, SPI_CMD=0x08, DFU_ENABLE=0x09,
           ERASE_SECTOR=0x0D, FLASH_ADDR=0x0E, FLASH_DATA=0x0F, FLASH_TYPE=0x10, JEDEC_ID=0x17,
           MEM_ADDR=0x1A, MEM_DATA=0x1B)
EXPECTED_LEN = {0x02: 2, 0x03: 1, 0x0E: 4, 0x0F: 1024, 0x0D: 4}
SET_CUR, GET_CUR, GET_LEN = 0x01, 0x81, 0x85

FLASH_SIZE = 512 * 1024
NORMAL_READ_LIMIT = 256 * 1024
SECTOR, BLOCK = 4096, 1024
JEDEC = bytes([0x85, 0x60, 0x13])        # Puya P25Q40
SPI_COMMANDS = bytes([0x03, 0x0B, 0x05, 0x06, 0x04, 0x20, 0xD8, 0xC7, 0x02, 0xFF, 0xFF, 0x01])
REG = dict(CHIP_CLASS=0x20FF, CHIP_FLAGS=0x20D9, MAINTENANCE=0x20D8, SPI_CTRL=0x2020,
           SPI_BUSY=0x2021, SPI_CMD=0x2022, SPI_DISCARD=0x2023, SPI_RESULT=0x2024, SPI_CS=0x2025)
WRITABLE = {REG["MAINTENANCE"], REG["SPI_CTRL"], REG["SPI_CMD"], REG["SPI_CS"]}
MAINT_ENTER, MAINT_LEAVE = 0x5A, 0xA5   # leave value is unverified upstream: may need a replug

# Identity ("TONY" block at 0x2000): USB product name and serial number.
TONY, PRODUCT_RECORD, SERIAL_RECORD, PRODUCT_SLOT, SERIAL_SLOT, SLOT = 0x2000, 0x2046, 0x204C, 0x2100, 0x2140, 64
RUNTIME_DATA = (0x1F000, 0x20000)        # sector the camera rewrites itself


# Firmware variants we know, told apart by a few bytes (every one reports bcdDevice 0x0513). Checked
# in order, first match wins. "recovers": comes back from a USB drop or hub reset by itself
# (docs/THRIFTIEST-CAM-FIRMWARE.md, test log); the others stay wedged until replugged.
FIRMWARE = [
    {"name": "recovery+bwreport", "label": "5.13 usbrecov + bwreport (unofficial)", "recovers": True,
     "bytes": {0x15037: "0000", 0x1503D: "0000", 0x1A1D7: "240500"}},
    {"name": "usbrecov", "label": "5.13 usbrecov (unofficial)", "recovers": True,
     "bytes": {0x15037: "0000", 0x1503D: "0000", 0x1A1D7: "27099a"}},
    {"name": "published", "label": "5.13 published (Thrifty Bot)", "recovers": False,
     "bytes": {0x05985: "17", 0x15037: "701e", 0x1503D: "7018"}},
    {"name": "factory", "label": "5.13 factory (no gain)", "recovers": False,
     "bytes": {0x05985: "15", 0x15037: "701e", 0x1503D: "7018"}},
]
FIRMWARE_BLOCKS = sorted({a - a % 1024 for f in FIRMWARE for a in f["bytes"]})


def firmware_variant(read):
    """The FIRMWARE entry matching the flash, read(addr, n) giving its bytes; None if unknown."""
    for f in FIRMWARE:
        if all(read(a, len(h) // 2).hex() == h for a, h in f["bytes"].items()):
            return f
    return None


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


try:
    import usb.core
    import usb.util
except ImportError:
    usb = None


# ---- firmware image -------------------------------------------------------------------------

def image_version(image):
    """bcdDevice from the USB device descriptor inside the image ('5.13'), or None."""
    i = image.find(bytes([VID & 0xFF, VID >> 8, PID & 0xFF, PID >> 8]))
    if i < 0 or i + 6 > len(image):
        return None
    return bcd(image[i + 4] | image[i + 5] << 8)


def bcd(v):
    return "%x.%02x" % (v >> 8, v & 0xFF)


def validate_image(image):
    if len(image) < 32 * 1024:
        return "too small (%d bytes) to be a camera image" % len(image)
    if len(image) > FLASH_SIZE:
        return "larger than the camera's 512 KiB flash"
    if set(image) <= {0} or set(image) <= {0xFF}:
        return "blank"
    if image_version(image) is None:
        return "doesn't carry the Thriftiest Cam's USB identity (1bcf:28c5): built for another device"
    return None


def read_slot(img, slot, record):
    if img[record] != 0 or img[record + 2:record + 6] != bytes([0, 0x80, slot >> 8, slot & 0xFF]):
        raise ValueError("unsupported identity layout")
    n = img[slot]
    if n == 0:
        if any(img[slot:slot + SLOT]):
            raise ValueError("unrecognised inactive identity slot")
        return None
    if n < 4 or n > SLOT or n % 2 or img[slot + 1] != 3 or img[record + 1] != n:
        raise ValueError("invalid identity string")
    if any(img[slot + i + 1] for i in range(2, n, 2)) or any(img[slot + n:slot + SLOT]):
        raise ValueError("unsupported identity string")
    return bytes(img[slot + i] for i in range(2, n, 2)).decode("ascii")


def read_identity(img):
    if img[TONY:TONY + 4] != b"TONY":
        raise ValueError("no TONY identity block")
    return read_slot(img, PRODUCT_SLOT, PRODUCT_RECORD), read_slot(img, SERIAL_SLOT, SERIAL_RECORD)


def write_slot(img, slot, record, value):
    if not value or len(value) > 31 or not all(0x20 <= ord(c) <= 0x7E for c in value) or value.strip() != value:
        die("names and serials are 1-31 printable ASCII characters, no leading/trailing spaces")
    img[slot:slot + SLOT] = bytes(SLOT)
    n = 2 + 2 * len(value)
    img[slot], img[slot + 1], img[record + 1] = n, 3, n
    for i, c in enumerate(value):
        img[slot + 2 + 2 * i] = ord(c)


def with_identity(img, name, serial):
    out = bytearray(img)
    cur = read_identity(out)
    if name is not None and name != cur[0]:
        write_slot(out, PRODUCT_SLOT, PRODUCT_RECORD, name)
    if serial is not None and serial != cur[1]:
        write_slot(out, SERIAL_SLOT, SERIAL_RECORD, serial)
    read_identity(out)
    return out


def apply_image(baseline, image):
    """New firmware at offset 0 over the current flash; the tail and the stored name/serial kept."""
    cand = bytearray(baseline)
    cand[:len(image)] = image
    try:
        name, serial = read_identity(baseline)
        read_identity(cand)
    except ValueError:
        return cand
    if name is None and serial is None:
        return cand
    return with_identity(cand, name, serial)


# ---- USB ------------------------------------------------------------------------------------

def guid(b):
    h = lambda r: "".join("%02x" % b[i] for i in r)
    return "-".join([h([3, 2, 1, 0]), h([5, 4]), h([7, 6]), h([8, 9]), h(range(10, 16))])


def find_xu(dev):
    for intf in dev.get_active_configuration():
        if intf.bInterfaceClass != 0x0E or intf.bInterfaceSubClass != 0x01:
            continue
        extra, units, o = bytes(intf.extra_descriptors), {}, 0
        while o + 2 < len(extra) and extra[o] >= 3:
            n = extra[o]
            if extra[o + 1] == 0x24 and extra[o + 2] == 0x06 and n >= 24:
                units[guid(extra[o + 4:o + 20])] = extra[o + 3]
            o += n
        for g in XU_GUIDS:
            if g in units:
                return units[g], intf.bInterfaceNumber
    return None


def port_of(dev):
    return "%d-%s" % (dev.bus, ".".join(map(str, dev.port_numbers or ())))


def cameras(pid=None):
    found = []
    for p in ([pid] if pid else [PID, PID_MAINT]):
        found += list(usb.core.find(find_all=True, idVendor=VID, idProduct=p))
    return found


def find_camera(port, pid=None):
    """port: '2.1' (as PhotonVision and health-check.sh show it) or '1-2.1'."""
    m = [d for d in cameras(pid) if port_of(d) == port or port_of(d).split("-", 1)[1] == port]
    return m[0] if len(m) == 1 else None


class Session:
    def __init__(self, dev):
        self.dev = dev
        self.maint = dev.idProduct == PID_MAINT
        xu = find_xu(dev)
        if not xu:
            die("camera on %s has no SunplusIT extension unit" % port_of(dev))
        self.unit, self.intf = xu
        self.detached = False
        if dev.is_kernel_driver_active(self.intf):
            dev.detach_kernel_driver(self.intf)   # uvcvideo; re-attached in close()
            self.detached = True
        for sel, n in EXPECTED_LEN.items():
            if self.get_len(sel) != n:
                self.close()
                die("unexpected extension-unit control 0x%02x: not a supported camera" % sel)

    def ctrl(self, req, sel, data):
        rt = 0xA1 if req & 0x80 else 0x21
        return self.dev.ctrl_transfer(rt, req, sel << 8, self.unit << 8 | self.intf, data, timeout=5000)

    def get_len(self, sel):
        r = self.ctrl(GET_LEN, sel, 2)
        return r[0] | r[1] << 8

    def get(self, sel, n):
        r = bytes(self.ctrl(GET_CUR, sel, n))
        if len(r) != n:
            raise IOError("GET_CUR 0x%02x returned %d bytes, expected %d" % (sel, len(r), n))
        return r

    def set(self, sel, data):
        self.ctrl(SET_CUR, sel, bytes(data))

    def reg(self, addr):
        self.set(SEL["REG_ADDR"], [addr & 0xFF, addr >> 8])
        return self.get(SEL["REG_DATA"], 1)[0]

    def wreg(self, addr, value):
        assert addr in WRITABLE, hex(addr)
        self.set(SEL["REG_ADDR"], [addr & 0xFF, addr >> 8])
        self.set(SEL["REG_DATA"], [value])

    def mem(self, addr):
        prev = self.get(SEL["MEM_ADDR"], 4)
        try:
            self.set(SEL["MEM_ADDR"], (addr | 0x800000).to_bytes(4, "little"))
            return self.get(SEL["MEM_DATA"], 4)
        finally:
            self.set(SEL["MEM_ADDR"], prev)

    def read(self, addr, size, progress=False):
        limit = FLASH_SIZE if self.maint else NORMAL_READ_LIMIT
        assert addr % BLOCK == 0 and size % BLOCK == 0 and addr + size <= limit
        cursor = self.get(SEL["FLASH_ADDR"], 4)
        out = bytearray()
        try:
            for a in range(addr, addr + size, BLOCK):
                self.set(SEL["FLASH_ADDR"], a.to_bytes(4, "little"))
                out += self.get(SEL["FLASH_DATA"], BLOCK)
                if progress and (a - addr) % (32 * BLOCK) == 0:
                    print("\r  reading %3d%%" % (100 * (a - addr) // size), end="", flush=True)
        finally:
            self.set(SEL["FLASH_ADDR"], cursor)
        if progress:
            print("\r  reading 100%")
        return bytes(out)

    def erase(self, addr):
        assert self.maint and addr % SECTOR == 0 and addr + SECTOR <= FLASH_SIZE
        self.set(SEL["ERASE_SECTOR"], addr.to_bytes(4, "little"))
        time.sleep(0.5)

    def program(self, addr, block):
        assert self.maint and addr % BLOCK == 0 and len(block) == BLOCK and addr + BLOCK <= FLASH_SIZE
        self.set(SEL["FLASH_ADDR"], addr.to_bytes(4, "little"))
        self.set(SEL["FLASH_DATA"], block)
        time.sleep(0.05)

    def check_normal_profile(self):
        ok = (self.reg(REG["CHIP_CLASS"]) == 0x04 and not self.reg(REG["CHIP_FLAGS"]) & 0x80
              and self.mem(0x802000) == b"YNOT" and self.mem(0x802090)[3] == 0x03)
        if not ok:
            die("this camera doesn't match the validated Thriftiest Cam controller profile; not touching it")

    def check_maint_profile(self):
        cursor = self.get(SEL["SPI_SLOT"], 1)
        try:
            for slot, op in enumerate(SPI_COMMANDS, 1):
                self.set(SEL["SPI_SLOT"], [slot])
                if self.get(SEL["SPI_CMD"], 1)[0] != op:
                    die("unrecognised flash command profile; nothing written")
        finally:
            self.set(SEL["SPI_SLOT"], cursor)
        if (self.get(SEL["DFU_ENABLE"], 1)[0] != 0 or self.get(SEL["FLASH_TYPE"], 1)[0] != 0
                or self.get(SEL["JEDEC_ID"], 3) != JEDEC):
            die("the flash isn't the validated Puya P25Q40 profile; nothing written")

    def spi_idle(self):
        deadline = time.time() + 3
        while time.time() < deadline:
            if self.reg(REG["SPI_BUSY"]) == 0:
                return
            time.sleep(0.002)
        raise IOError("SPI controller did not become idle")

    def flash_status(self):
        self.wreg(REG["SPI_CTRL"], 0x80)
        self.wreg(REG["SPI_CS"], 0x00)
        try:
            self.wreg(REG["SPI_CMD"], 0x05)
            self.spi_idle()
            self.reg(REG["SPI_DISCARD"])
            self.spi_idle()
            return self.reg(REG["SPI_RESULT"])
        finally:
            self.wreg(REG["SPI_CS"], 0x02)

    def poke_maintenance(self, value):
        """Reset into (0x5A) or out of (0xA5) ROM maintenance mode; the device drops off the bus."""
        try:
            self.wreg(REG["MAINTENANCE"], value)
        except usb.core.USBError:
            pass

    def close(self):
        try:
            usb.util.dispose_resources(self.dev)
            if self.detached:
                self.dev.attach_kernel_driver(self.intf)
        except usb.core.USBError:
            pass


def wait_for(port, pid, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        d = find_camera(port, pid)
        if d:
            return d
        time.sleep(0.4)
    return None


# ---- write transaction ----------------------------------------------------------------------

def write_flash(port, make_candidate, backup_dir, label):
    """Normal mode -> maintenance -> verified sector rewrite -> back to normal, verified."""
    dev = find_camera(port, PID) or die("no Thriftiest Cam (application firmware) on port %s" % port)
    full_port = port_of(dev)
    s = Session(dev)
    try:
        print("Reading the camera (normal mode)…")
        normal = s.read(0, NORMAL_READ_LIMIT, progress=True)
        s.check_normal_profile()
        # Already there? Checked here, so a camera that needs nothing never enters maintenance mode.
        pad = bytes(FLASH_SIZE - NORMAL_READ_LIMIT)
        pre = bytes(make_candidate(normal + pad))
        if pre == normal + pad:
            print("Already up to date: nothing to write.")
            return
        print("Switching to maintenance mode…")
        s.poke_maintenance(MAINT_ENTER)
    finally:
        s.close()
    dev = wait_for(full_port, PID_MAINT, 20) or die("camera didn't come back in maintenance mode: replug it and retry")
    s = Session(dev)
    restored = False
    nothing = False
    try:
        s.check_maint_profile()
        print("Backing up the whole flash (twice)…")
        baseline = s.read(0, FLASH_SIZE, progress=True)
        if s.read(0, FLASH_SIZE) != baseline:
            die("two backup reads disagree; nothing written")
        if baseline[:NORMAL_READ_LIMIT] != normal:
            die("maintenance-mode read differs from the normal-mode read; nothing written")
        os.makedirs(backup_dir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        bpath = os.path.join(backup_dir, "thriftiest-%s-%s-%s.bin" % (full_port, stamp, label))
        with open(bpath, "wb") as f:
            f.write(baseline)
        print("Backup: " + bpath)

        cand = bytes(make_candidate(baseline))
        sectors = sorted({a - a % SECTOR for a in range(FLASH_SIZE) if baseline[a] != cand[a]})
        if not sectors:
            print("Already up to date: nothing to write. Restarting the camera…")
            s.poke_maintenance(MAINT_LEAVE)
            nothing = True
            return
        if s.flash_status() != 0:
            die("flash protection bits set; nothing written")
        print("Writing %d sector(s)…" % len(sectors))

        def rewrite(src):
            for i, sec in enumerate(sectors):
                print("\r  sector %d/%d" % (i + 1, len(sectors)), end="", flush=True)
                s.erase(sec)
                if s.read(sec, SECTOR) != b"\xff" * SECTOR:
                    raise IOError("sector 0x%x didn't erase" % sec)
                for a in range(sec, sec + SECTOR, BLOCK):
                    s.program(a, src[a:a + BLOCK])
                    if s.read(a, BLOCK) != src[a:a + BLOCK]:
                        raise IOError("block 0x%x didn't read back" % a)
            print()

        try:
            rewrite(cand)
            if s.read(0, FLASH_SIZE) != cand:
                raise IOError("full readback differs from the new image")
        except (IOError, usb.core.USBError) as e:
            print("\nWrite failed (%s); restoring the original…" % e)
            now = s.read(0, FLASH_SIZE)
            if now != cand and now != baseline:
                rewrite(baseline)
                restored = s.read(0, FLASH_SIZE) == baseline
                die("write failed; original %s. Keep the camera plugged in. Backup: %s"
                    % ("restored" if restored else "NOT restored", bpath))
            if now != cand:
                die("write failed before anything changed")
        print("Written and verified. Restarting the camera…")
        s.poke_maintenance(MAINT_LEAVE)
    finally:
        s.close()
        if nothing:
            wait_for(full_port, PID, 8) or print("The camera didn't restart on its own: replug it or power-cycle the robot.")
    dev = wait_for(full_port, PID, 8)
    if not dev:
        print("The camera didn't restart on its own: unplug it and plug it back in (same port) "
              "or power-cycle the robot. Waiting up to 2 minutes…")
        dev = wait_for(full_port, PID, 120) or die("camera didn't come back; the write itself was verified")
    s = Session(dev)
    try:
        got = s.read(0, NORMAL_READ_LIMIT)
    finally:
        s.close()
    lo, hi = RUNTIME_DATA
    if got[:lo] + got[hi:] != cand[:lo] + cand[hi:NORMAL_READ_LIMIT]:
        die("the restarted camera's contents differ from what was written. Backup: " + bpath)
    print("Done: firmware %s, verified after restart." % bcd(dev.bcdDevice))


# ---- commands -------------------------------------------------------------------------------

def cmd_list(a):
    cams = cameras()
    if not cams:
        print("No Thriftiest Cams (1bcf:28c5) found.")
    for d in sorted(cams, key=port_of):
        line = "%-8s firmware %s" % (port_of(d).split("-", 1)[1], bcd(d.bcdDevice))
        if d.idProduct == PID_MAINT:
            print(line + "  IN MAINTENANCE MODE (replug it, or re-run flash)")
            continue
        if not a.identity:
            print(line)
            continue
        try:
            s = Session(d)
            try:
                name, serial = read_identity(s.read(0, TONY + SECTOR))
            finally:
                s.close()
            line += "  stored name %s, serial %s" % (name or "(default)", serial or "(default)")
        except Exception as e:  # noqa: BLE001 — listing shouldn't stop at one odd camera
            line += "  (couldn't read identity: %s)" % e
        print(line)


def cmd_check_image(a):
    img = open(a.image, "rb").read()
    err = validate_image(img)
    v = firmware_variant(lambda addr, n: img[addr:addr + n])
    if a.json:
        print(json.dumps({"file": os.path.basename(a.image), "bytes": len(img), "version": image_version(img),
                          "variant": v["name"] if v else None, "label": v["label"] if v else None,
                          "recovers": bool(v and v["recovers"]), "error": err}))
        sys.exit(1 if err else 0)
    print("%s: %d bytes, firmware %s, %s" % (a.image, len(img), image_version(img) or "?",
                                            v["label"] if v else "unknown variant"))
    if err:
        die(err)


def cmd_dump(a):
    dev = find_camera(a.port) or die("no Thriftiest Cam on port " + a.port)
    s = Session(dev)
    try:
        data = s.read(0, FLASH_SIZE if s.maint else NORMAL_READ_LIMIT, progress=True)
    finally:
        s.close()
    open(a.out, "wb").write(data)
    print("Wrote %d bytes to %s" % (len(data), a.out))


def cmd_flash(a):
    img = open(a.image, "rb").read()
    err = validate_image(img)
    if err:
        die(a.image + ": " + err)
    if not a.yes:
        die("this rewrites the camera's firmware (%s): add --yes" % image_version(img))
    write_flash(a.port, lambda base: apply_image(base, img), a.backup_dir, "fw" + image_version(img))


def cmd_rename(a):
    if a.name is None and a.serial is None:
        die("give --name and/or --serial")
    if not a.yes:
        die("this rewrites the camera's stored name/serial: add --yes")
    write_flash(a.port, lambda base: with_identity(base, a.name, a.serial), a.backup_dir, "identity")


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
    for lo, hi in ranges:
        print("0x%05x-0x%05x %4d bytes  %s | %s" % (lo, hi, hi - lo + 1, x[lo:hi + 1][:16].hex(), y[lo:hi + 1][:16].hex()))
    print("%d byte(s) differ in %d range(s) over the first %d bytes (%s: %d bytes, %s: %d bytes)"
          % (len(diffs), len(ranges), n, a.a, len(x), a.b, len(y)))


# ---- firmware variant, read through uvcvideo -------------------------------------------------
# The vendor extension unit's flash-read controls also work through the video driver
# (UVCIOC_CTRL_QUERY on /dev/videoN), with the camera streaming: nothing is detached, so
# PhotonVision keeps running. Found 2026-10-29: two 1 KiB reads, no frame lost.

UVCIOC_CTRL_QUERY = 0xC0107521  # _IOWR('u', 0x21, struct uvc_xu_control_query), 64-bit


class _XuQuery(ctypes.Structure):
    _fields_ = [("unit", ctypes.c_uint8), ("selector", ctypes.c_uint8), ("query", ctypes.c_uint8),
                ("size", ctypes.c_uint16), ("data", ctypes.c_void_p)]


def _xu_unit_from_sysfs(usbdev):
    raw = open(os.path.join(usbdev, "descriptors"), "rb").read()
    o = 0
    while o + 2 < len(raw) and raw[o] >= 2:
        n = raw[o]
        if raw[o + 1] == 0x24 and raw[o + 2] == 0x06 and n >= 24 and guid(raw[o + 4:o + 20]) in XU_GUIDS:
            return raw[o + 3]
        o += n
    return None


def _uvc_query(fd, unit, sel, req, buf):
    import fcntl  # Linux only; check-image and diff run on a laptop too

    arr = (ctypes.c_uint8 * len(buf)).from_buffer(buf)
    fcntl.ioctl(fd, UVCIOC_CTRL_QUERY, _XuQuery(unit, sel, req, len(buf), ctypes.addressof(arr)))


def camera_variant(video, usbdev):
    """The FIRMWARE entry for the camera behind /dev/videoN, read while it streams; None if unknown."""
    unit = _xu_unit_from_sysfs(usbdev)
    if unit is None:
        raise IOError("no SunplusIT extension unit")
    fd = os.open(video, os.O_RDWR | os.O_NONBLOCK)
    try:
        cursor = bytearray(4)
        _uvc_query(fd, unit, SEL["FLASH_ADDR"], GET_CUR, cursor)
        blocks = {}
        try:
            for b in FIRMWARE_BLOCKS:
                _uvc_query(fd, unit, SEL["FLASH_ADDR"], SET_CUR, bytearray(b.to_bytes(4, "little")))
                data = bytearray(BLOCK)
                _uvc_query(fd, unit, SEL["FLASH_DATA"], GET_CUR, data)
                blocks[b] = bytes(data)
        finally:
            _uvc_query(fd, unit, SEL["FLASH_ADDR"], SET_CUR, cursor)
    finally:
        os.close(fd)
    return firmware_variant(lambda addr, n: blocks[addr - addr % BLOCK][addr % BLOCK:addr % BLOCK + n])


def cmd_variant(a):
    out = []
    for link in sorted(glob.glob("/dev/v4l/by-path/*-video-index0")):
        video = os.path.realpath(link)
        usbdev = os.path.realpath("/sys/class/video4linux/%s/device/.." % os.path.basename(video))
        try:
            vid, pid = (open(os.path.join(usbdev, f)).read().strip() for f in ("idVendor", "idProduct"))
        except OSError:
            continue
        if (int(vid, 16), int(pid, 16)) != (VID, PID):
            continue
        port = os.path.basename(usbdev)
        cam = {"port": port.split("-", 1)[1], "video": video,
               "serial": open(os.path.join(usbdev, "serial")).read().strip(),
               "version": bcd(int(open(os.path.join(usbdev, "bcdDevice")).read(), 16))}
        try:
            v = camera_variant(video, usbdev)
            cam.update(variant=v["name"] if v else None, label=v["label"] if v else "unknown firmware",
                       recovers=bool(v and v["recovers"]))
        except OSError as e:
            cam.update(variant=None, label="couldn't read (%s)" % e, recovers=False, error=str(e))
        out.append(cam)
    if a.json:
        print(json.dumps(out))
        return
    if not out:
        print("No Thriftiest Cams (1bcf:28c5) found.")
    for c in out:
        print("%-6s %-10s firmware %s, %s%s" % (c["port"], c["serial"], c["version"], c["label"],
                                               "" if c["recovers"] else "  (no USB recovery)"))


def default_backup_dir():
    """~/thriftiest-backups of the user who ran sudo, not root's."""
    user = os.environ.get("SUDO_USER")
    return os.path.join(os.path.expanduser("~" + user) if user else os.path.expanduser("~"), "thriftiest-backups")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("list")
    c.add_argument("--identity", action="store_true",
                   help="also read each camera's stored name/serial (drops it from PhotonVision for a moment)")
    c = sub.add_parser("check-image")
    c.add_argument("image")
    c.add_argument("--json", action="store_true")
    c = sub.add_parser("variant")
    c.add_argument("--json", action="store_true")
    c = sub.add_parser("diff")
    c.add_argument("a")
    c.add_argument("b")
    c = sub.add_parser("dump")
    c.add_argument("--port", required=True)
    c.add_argument("out")
    for name in ("flash", "rename"):
        c = sub.add_parser(name)
        c.add_argument("--port", required=True, help="USB port as health-check.sh shows it, e.g. 2.1")
        c.add_argument("--yes", action="store_true")
        c.add_argument("--backup-dir", default=default_backup_dir())
        if name == "flash":
            c.add_argument("image")
        else:
            c.add_argument("--name")
            c.add_argument("--serial")
    a = p.parse_args()
    if a.cmd not in ("check-image", "diff", "variant"):
        if usb is None:
            die("pyusb isn't installed: sudo apt install python3-usb")
        if os.geteuid() != 0:
            die("needs sudo (raw USB access)")
    # PhotonVision's camera watchdog (photonvision-81) resets the USB port of a camera that stops
    # streaming for 5 s while its USB device is still there: exactly what this tool does to it. A
    # reset mid-read broke a flash on 2026-10-29 (before anything was written); mid-write it could
    # leave the flash half-written. scripts/host/thriftiest-flash.sh stops it and starts it again.
    if a.cmd in ("dump", "flash", "rename") or (a.cmd == "list" and a.identity):
        if os.system("systemctl is-active --quiet photonvision") == 0:
            die("PhotonVision is running, and its camera watchdog would reset the camera mid-operation:"
                " sudo systemctl stop photonvision first (start it again after)")
    {"list": cmd_list, "check-image": cmd_check_image, "diff": cmd_diff, "variant": cmd_variant, "dump": cmd_dump,
     "flash": cmd_flash, "rename": cmd_rename}[a.cmd](a)


if __name__ == "__main__":
    main()
