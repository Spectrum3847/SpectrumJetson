#!/usr/bin/env python3
"""USB bandwidth report for the Jetson's cameras: what each camera reserves, what's failing, and how
to fix it. Run ON THE JETSON (no sudo needed; uses sudo -n for the kernel log if it can).

    scripts/jetson/usb-bandwidth.py          the report
    scripts/jetson/usb-bandwidth.py --json   the same, for scripts (health-check.sh)

Why cameras run out: a USB camera reserves isochronous bandwidth for the packet size of the
alternate setting it streams on, whatever it actually sends. The Jetson has one USB controller,
and every USB 2.0 port on it shares ONE budget: the four USB-A ports (one hub), the USB-C port, and
the M.2 Wi-Fi card's Bluetooth. Measured on 2026-09-24 with PhotonVision stopped: 6720 bytes per
125 us microframe fit (4 x 1280 on USB-A + 1600 on USB-C), 7400 didn't, whichever ports the cameras
were on. A camera that doesn't fit gets "Not enough bandwidth" from the kernel and never streams.

The fixes, in order:
  1. Cap cameras that have smaller alternate settings (our driver's payload_cap, set by
     11-uvcvideo-payload-cap.sh). At 1280 bytes (10 MB/s) an OV9281 at 1280x800 MJPEG still runs
     120 fps.
  2. Moving a camera to another port doesn't help. Lower the caps further, use fewer USB 2.0
     cameras, or use a USB 3 camera: those are on the USB 3 bus, which has its own budget.
  3. A camera with only one large alternate setting (the Razer Kiyo: 3 x 1020 bytes) can't be
     capped. It takes 3060 of the budget by itself.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SYS = Path("/sys/bus/usb/devices")
BUDGET = 6720  # bytes per microframe the Jetson's whole USB 2.0 side fit (7400 was refused)
CAP_DEFAULT = 1280
CAP_FILE = Path("/sys/module/uvcvideo/parameters/payload_cap")


def read(p: Path, default: str = "") -> str:
    try:
        return p.read_text().strip()
    except OSError:
        return default


def packet_bytes(w: int) -> int:
    """wMaxPacketSize -> bytes per microframe (size x transactions)."""
    return (w & 0x7FF) * (1 + ((w >> 11) & 3))


def alt_settings(dev: Path) -> dict[int, dict[int, int]]:
    """{interface: {alt: bytes per microframe of its isochronous IN endpoint}} from the raw descriptors."""
    try:
        d = (dev / "descriptors").read_bytes()
    except OSError:
        return {}
    out: dict[int, dict[int, int]] = {}
    i, intf, alt = 0, None, None
    while i + 2 <= len(d):
        n, t = d[i], d[i + 1]
        if n < 2:
            break
        if t == 4 and n >= 9:  # interface
            intf, alt = d[i + 2], d[i + 3]
            out.setdefault(intf, {}).setdefault(alt, 0)
        elif t == 5 and n >= 7 and intf is not None:  # endpoint
            attrs = d[i + 3]
            if attrs & 3 == 1 and d[i + 2] & 0x80:  # isochronous, IN
                w = d[i + 4] | (d[i + 5] << 8)
                out[intf][alt] = max(out[intf][alt], packet_bytes(w))
        i += n
    return out


def caps() -> dict[str, int]:
    """The driver's caps: "vid:pid" -> bytes for a camera model, "port" (e.g. "1-2.4") -> bytes for
    one camera (set on PhotonVision's Camera Matching page; wins over its model's; 0 = uncapped)."""
    out = {}
    for part in read(CAP_FILE).split(","):
        m = re.match(r"^([0-9a-fA-F]{4}):([0-9a-fA-F]{4}):(\d+)$", part.strip())
        if m:
            out[f"{m.group(1).lower()}:{m.group(2).lower()}"] = int(m.group(3))
        m = re.match(r"^(\d+-[\d.]+):(\d+)$", part.strip())
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def kernel_log() -> str:
    """The kernel's messages from the last 10 minutes."""
    text = ""
    for cmd in (["sudo", "-n", "journalctl", "-k", "--since", "-10 min", "-o", "cat", "--no-pager"],
                ["journalctl", "-k", "--since", "-10 min", "-o", "cat", "--no-pager"]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout:
                text = r.stdout
                break
        except (OSError, subprocess.TimeoutExpired):
            continue
    return text


def recent_failures(text: str) -> dict[str, int]:
    """USB port -> how many "Not enough bandwidth" lines the kernel logged in the last 10 minutes."""
    out: dict[str, int] = {}
    for m in re.finditer(r"usb (\d+-[\d.]+): Not enough bandwidth", text):
        out[m.group(1)] = out.get(m.group(1), 0) + 1
    return out


def connect_failures(text: str) -> dict[str, list[str]]:
    """USB port -> what went wrong when something was plugged in there: it couldn't be read or
    addressed (a bad cable or adapter, a plug not fully in, or not enough power), or over-current."""
    pats = [
        (r"usb (\d+-[\d.]+): device descriptor read/\S+, error (-?\d+)", "couldn't read its descriptor"),
        (r"usb (\d+-[\d.]+): device not accepting address \d+, error (-?\d+)", "didn't accept an address"),
        (r"usb (\d+-[\d.]+): Device not responding to setup address", "didn't respond"),
        (r"usb (\d+-[\d.]+)-port(\d+): unable to enumerate USB device", "couldn't be connected at all"),
        (r"usb (\d+-[\d.]+)-port(\d+): over-current", "over-current"),
    ]
    out: dict[str, list[str]] = {}
    for pat, what in pats:
        for m in re.finditer(pat, text):
            port = m.group(1) if "port" not in pat else f"{m.group(1)}.{m.group(2)}"
            lst = out.setdefault(port, [])
            if what not in lst:
                lst.append(what)
    return out


def video_nodes(dev: Path) -> list[str]:
    nodes = []
    for p in dev.glob("*:*/video4linux/video*"):
        nodes.append(p.name)
    return sorted(nodes, key=lambda s: int(s[5:]))


def photonvision_names() -> dict[str, str]:
    """USB port -> PhotonVision camera name, from the by-path links and PhotonVision's config (best effort)."""
    names: dict[str, str] = {}
    try:
        import sqlite3

        db = Path("/opt/photonvision/photonvision_config/photon.sqlite")
        if not db.exists() or not db.stat().st_mode & 0o004:
            return names
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        for (cfg,) in con.execute("select config_json from cameras"):
            c = json.loads(cfg)
            info = c.get("matchedCameraInfo") or {}
            ident = info.get("PVUsbCameraInfo", info).get("uniquePath") or ""
            if "/by-id/" in ident:
                # photonvision-86: known by its own serial, in whatever port it's in now
                if os.path.exists(ident):
                    video = os.path.basename(os.path.realpath(ident))
                    dev = os.path.realpath(f"/sys/class/video4linux/{video}/device")
                    names[os.path.basename(dev).split(":")[0].split("-", 1)[-1]] = c.get("nickname", "")
                continue
            m = re.search(r"usb-0:([\d.]+):1\.0-video", json.dumps(info))
            if m:
                names[m.group(1)] = c.get("nickname", "")
    except Exception:
        pass
    return names


def survey() -> dict:
    cap = caps()
    klog = kernel_log()
    fails = recent_failures(klog)
    connect = connect_failures(klog)
    pv = photonvision_names()
    cams = []
    for dev in sorted(SYS.iterdir()):
        if ":" in dev.name or not (dev / "idVendor").exists():
            continue
        alts = alt_settings(dev)
        # UVC: a video streaming interface (class 0x0e, subclass 2); UAC audio streaming (0x01, 2).
        streaming = []
        for intf_dir in dev.glob(f"{dev.name}:*"):
            cls, sub = read(intf_dir / "bInterfaceClass"), read(intf_dir / "bInterfaceSubClass")
            if (cls, sub) in (("0e", "02"), ("01", "02")):
                n = int(read(intf_dir / "bInterfaceNumber", "0"), 16)
                streaming.append((intf_dir, n, "video" if cls == "0e" else "audio"))
        if not any(k == "video" for _, _, k in streaming):
            continue
        vid, pid = read(dev / "idVendor"), read(dev / "idProduct")
        port = dev.name  # e.g. 1-2.4
        reserved = 0
        video_alts = {}
        for intf_dir, n, kind in streaming:
            cur = int(read(intf_dir / "bAlternateSetting", "0"))
            b = alts.get(n, {}).get(cur, 0)
            reserved += b
            if kind == "video":
                video_alts = {a: v for a, v in alts.get(n, {}).items() if a != 0}
        sizes = sorted(set(video_alts.values()))
        key = f"{vid}:{pid}"
        cams.append({
            "port": port,
            "bus": int(read(dev / "busnum", "0")),
            "speedMbps": int(float(read(dev / "speed", "0") or 0)),
            "id": key,
            "name": read(dev / "product") or key,
            "photonvision": pv.get(port.split("-", 1)[1], ""),
            "video": video_nodes(dev),
            "reservedBytes": reserved,
            "streaming": reserved > 0,
            "altBytes": sizes,
            "capped": cap.get(port, cap.get(key)) or None,
            "cappable": len(sizes) > 1 and sizes[0] <= CAP_DEFAULT,
            "bandwidthFailures": fails.get(port, 0),
        })
    buses: dict[int, dict] = {}
    for c in cams:
        b = buses.setdefault(c["bus"], {"bus": c["bus"], "cameras": [], "reservedBytes": 0})
        b["cameras"].append(c["port"])
        b["reservedBytes"] += c["reservedBytes"]
    present = {c["port"] for c in cams}
    advice = advise(cams, cap)
    for port, what in sorted(connect.items()):
        if port in present:
            continue
        if "over-current" in what:
            advice.append(f"USB port {port}: over-current: the device draws more than the port can give. Try it on "
                          "another port or a powered hub, and check the Jetson's power supply.")
        else:
            advice.append(f"USB port {port}: something plugged in there {', '.join(what)} (in the last 10 min). That's "
                          "usually the cable or adapter, or the plug not fully in; sometimes not enough power. Re-seat it, "
                          "or try another cable or port. A camera that worked until a USB hub reset is stuck instead: "
                          "replug it, or power-cycle the robot (a reboot doesn't cut USB power).")
    return {"budgetBytes": BUDGET, "payloadCap": read(CAP_FILE) or "(stock driver: no cap)", "cameras": cams,
            "buses": sorted(buses.values(), key=lambda b: b["bus"]), "connectFailures": connect, "advice": advice}


def alt_for(c: dict, cap_bytes: int) -> int:
    """The alternate setting the driver picks under a cap: the smallest one at least that big."""
    fitting = [b for b in c["altBytes"] if b >= cap_bytes]
    return min(fitting) if fitting else max(c["altBytes"] or [0])


def need_bytes(c: dict, cap: dict[str, int]) -> int:
    """What this camera will reserve when it streams: the setting its cap picks, or its largest."""
    return alt_for(c, c["capped"]) if c["capped"] else max(c["altBytes"] or [0])


def advise(cams: list[dict], cap: dict[str, int]) -> list[str]:
    out = []
    for bus in sorted({c["bus"] for c in cams}):
        on = [c for c in cams if c["bus"] == bus]
        failing = [c for c in on if c["bandwidthFailures"] and not c["streaming"]]
        want = sum(need_bytes(c, cap) for c in on if c["speedMbps"] >= 480)
        if not failing and want <= BUDGET:
            continue
        new_caps = [c for c in on if c["cappable"] and not c["capped"]]
        if new_caps:
            ids = sorted({c["id"] for c in new_caps})
            new = {c["id"]: alt_for(c, CAP_DEFAULT) for c in new_caps}
            full = ",".join(sorted(set([f"{k}:{v}" for k, v in cap.items()] + [f"{k}:{v}" for k, v in new.items()])))
            out.append(f"Cap {', '.join(c['photonvision'] or c['name'] for c in new_caps)} ({', '.join(ids)}): they have "
                       f"smaller alternate settings. Run: CAP={full} ~/SpectrumJetson/scripts/jetson/11-uvcvideo-payload-cap.sh --install "
                       "(reloads the camera driver; PhotonVision restarts)")
        # After capping what can be capped, is it still over?
        after = sum((alt_for(c, CAP_DEFAULT) if (c["cappable"] and not c["capped"]) else need_bytes(c, cap)) for c in on
                    if c["speedMbps"] >= 480)
        fixed = [c for c in on if not c["cappable"] and not c["capped"] and max(c["altBytes"] or [0]) > CAP_DEFAULT]
        for c in fixed:
            out.append(f"{c['photonvision'] or c['name']} ({c['id']}, USB port {c['port']}) only has "
                       f"{'/'.join(map(str, c['altBytes']))}-byte alternate settings "
                       f"(~{max(c['altBytes']) * 8 * 8000 // 1_000_000} Mbps) and can't be capped. Every USB 2.0 port "
                       "shares one budget, so another port doesn't help: use a camera that can be capped, or a USB 3 camera.")
        if after > BUDGET and not fixed:
            out.append(f"USB bus {bus}: {after} bytes per microframe wanted, about {BUDGET} available even with every "
                       "camera capped. Every USB 2.0 port (USB-A, USB-C, hubs) shares this, so moving cameras doesn't "
                       "help. Lower some caps (check their frame rate still holds), unplug a camera, or use a USB 3 "
                       "camera (separate bus).")
        for c in failing:
            if not any(c["port"] in a for a in out):
                out.append(f"{c['photonvision'] or c['name']} (USB port {c['port']}) is failing with \"Not enough bandwidth\" "
                           f"({c['bandwidthFailures']} times in 10 min).")
    return out


def main() -> int:
    s = survey()
    if "--json" in sys.argv:
        print(json.dumps(s, indent=2))
        return 0
    print(f"USB camera bandwidth (all the Jetson's USB 2.0 ports share about {BUDGET} bytes per 125 us microframe)")
    print(f"Driver cap: {s['payloadCap']}\n")
    for b in s["buses"]:
        print(f"Bus {b['bus']}: reserving {b['reservedBytes']} of ~{BUDGET} bytes per microframe")
        for c in [c for c in s["cameras"] if c["bus"] == b["bus"]]:
            state = ("streaming" if c["streaming"] else
                     f"NOT STREAMING ({c['bandwidthFailures']} bandwidth failures in 10 min)" if c["bandwidthFailures"] else "idle")
            capped = f"capped at {c['capped']}" if c["capped"] else ("cappable" if c["cappable"] else "can't be capped")
            label = f"{c['photonvision']} = " if c["photonvision"] else ""
            print(f"  port {c['port']:8s} {label}{c['name']} ({c['id']}): {c['reservedBytes']:5d} bytes now, {state}; "
                  f"alternate settings {min(c['altBytes'] or [0])}-{max(c['altBytes'] or [0])} bytes, {capped}")
        print()
    if s["advice"]:
        print("To fix:")
        for a in s["advice"]:
            print("  - " + a)
    else:
        print("Every camera fits, and nothing failed to connect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
