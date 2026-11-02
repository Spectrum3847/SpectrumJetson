#!/usr/bin/env python3
"""Per-camera inventory and the per-camera-MODEL comparison for the bench session (run.sh).

    cameras.py inventory OUT REPO   writes OUT/cameras.tsv (one row per camera) and prints a summary
    cameras.py compare OUT          prints results.md's "Camera comparison" section (markdown)

Read-only: usb-bandwidth.py --json (USB port, model, video node, reserved bandwidth), PhotonVision's
GET /api/usb/bandwidth (camera name), the firmware tools' read-only listings (thriftiest-fw.py
variant --json, swyft-fw.py list --json; sudo -n), and v4l2-ctl --list-ctrls on each camera's node.
Nothing here sets a control.
"""

from __future__ import annotations

import collections
import json
import os
import re
import statistics
import subprocess
import sys
import urllib.request

COLS = ["port", "model", "product", "serial", "firmware", "video", "camera", "uniqueName", "exposure",
        "exposureMin", "exposureMax", "exposureCtrl", "gainMin", "gainMax", "reservedBytes", "capBytes", "altBytes"]
# Known models: (short name for the tables)
MODELS = {"1bcf:28c5": "Thriftiest Cam", "0bda:3035": "Swyft USB Camera"}


def run(cmd: list[str], timeout: int = 60) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def jload(s: str, default):
    try:
        return json.loads(s)
    except ValueError:
        return default


def sysread(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def ctrls(node: str) -> dict[str, dict[str, str]]:
    """v4l2-ctl --list-ctrls -> {name: {min, max, value, ...}} (read-only)."""
    out = {}
    for line in run(["v4l2-ctl", "-d", node, "--list-ctrls"], 10).splitlines():
        m = re.match(r"\s*(\w+) 0x[0-9a-f]+ \((\w+)\)\s*:(.*)", line)
        if m:
            out[m.group(1)] = dict(re.findall(r"(\w+)=(-?\w+)", m.group(3)))
    return out


def inventory(out: str, repo: str) -> None:
    bw = jload(run([sys.executable, f"{repo}/scripts/jetson/usb-bandwidth.py", "--json"], 30), {})
    try:
        with urllib.request.urlopen("http://localhost:5800/api/usb/bandwidth", timeout=5) as r:
            pv = {c.get("port"): c for c in json.load(r).get("cameras", [])}
    except Exception:
        pv = {}
    fw = {}
    for c in jload(run(["sudo", "-n", sys.executable, f"{repo}/scripts/jetson/thriftiest-fw.py", "variant", "--json"]), []):
        fw[c.get("port")] = "%s (%s)" % (c.get("label"), c.get("version"))
    for c in jload(run(["sudo", "-n", sys.executable, f"{repo}/scripts/jetson/swyft-fw.py", "list", "--json"]), []):
        fw[c.get("port")] = "boot loader" if c.get("bootLoader") else "revision %s" % c.get("revision")
    rows = []
    for c in bw.get("cameras", []):
        port = c["port"]  # 1-2.1
        short = port.split("-", 1)[-1]
        p = pv.get(port, {})
        node = ""
        for v in c.get("video", []):  # the capture node is the one with controls
            k = ctrls(f"/dev/{v}")
            if k:
                node = v
                break
        else:
            k = {}
        exp_name = next((n for n in k if re.match(r"exposure.*abs", n)), "")
        gain_name = next((n for n in k if n in ("gain", "analogue_gain")), "")
        e, g = k.get(exp_name, {}), k.get(gain_name, {})
        rows.append({
            "port": short, "model": c.get("id", "?"), "product": c.get("name", ""),
            "serial": sysread(f"/sys/bus/usb/devices/{port}/serial"), "firmware": fw.get(short, ""),
            "video": node, "camera": p.get("camera") or c.get("photonvision", ""), "uniqueName": p.get("uniqueName", ""),
            "exposure": e.get("value", ""), "exposureMin": e.get("min", ""), "exposureMax": e.get("max", ""),
            "exposureCtrl": exp_name, "gainMin": g.get("min", ""), "gainMax": g.get("max", ""),
            "reservedBytes": str(c.get("reservedBytes", "")), "capBytes": str(c.get("capped") or ""),
            "altBytes": ",".join(map(str, c.get("altBytes", []))),
        })
    with open(f"{out}/cameras.tsv", "w") as o:
        o.write("\t".join(COLS) + "\n")
        for r in rows:
            o.write("\t".join(r[k].replace("\t", " ") for k in COLS) + "\n")
    for r in rows:
        print(f"{r['camera'] or '?'} @{r['port']}: {r['model']} {r['product']} serial {r['serial'] or '?'}, "
              f"firmware {r['firmware'] or '?'}, /dev/{r['video'] or '?'}, exposure {r['exposure'] or '?'} "
              f"(min {r['exposureMin'] or '?'} max {r['exposureMax'] or '?'}), "
              f"gain {(r['gainMin'] + '-' + r['gainMax']) if r['gainMin'] else 'none'}, USB {r['reservedBytes']} B/microframe")


def num(s: str):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def fmt(vals, how="mean"):
    v = [x for x in vals if x is not None]
    if not v:
        return ""
    x = {"mean": statistics.mean, "max": max, "min": min}[how](v)
    return f"{x:.2f}".rstrip("0").rstrip(".")


def spread(vals) -> str:
    v = sorted({x for x in vals if x})
    return ", ".join(v) if v else ""


def compare(out: str) -> None:
    p = f"{out}/cameras.tsv"
    print("## Camera comparison (per model)\n")
    if not os.path.exists(p):
        print("(no camera inventory: run the inventory step)\n")
        return
    cams = [dict(zip(COLS, line.rstrip("\n").split("\t"))) for line in list(open(p))[1:] if line.strip()]
    model_of = lambda c: f"{MODELS.get(c['model'], c['product'] or c['model'])} ({c['model']})"
    by_name = {c["camera"]: c for c in cams if c["camera"]}
    by_port = {c["port"]: c for c in cams}
    models = collections.OrderedDict()
    for c in sorted(cams, key=model_of):
        models.setdefault(model_of(c), []).append(c)

    print("### Inventory\n")
    print("| model | camera | USB port | serial | firmware | node | exposure now | exposure min / max | gain min / max | USB B/microframe (cap) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for m, cs in models.items():
        for c in cs:
            print(f"| {m} | {c['camera'] or '?'} | {c['port']} | {c['serial'] or '?'} | {c['firmware'] or '?'} | "
                  f"{c['video'] or '?'} | {c['exposure'] or '?'} | {c['exposureMin'] or '?'} / {c['exposureMax'] or '?'} | "
                  f"{(c['gainMin'] + ' / ' + c['gainMax']) if c['gainMin'] else 'no gain control'} | "
                  f"{c['reservedBytes'] or '?'} ({c['capBytes'] or 'no cap'}) |")
    print("\nExposure is the raw V4L2 value (`exposure_time_absolute`: 100 us units on UVC, so 1 = 0.1 ms).\n")

    # measured rows: step, cond, round, camera, fps, med, p95, max, detect avg, detect max, tags/frame, detections, margin
    rows = [line.rstrip("\n").split("\t") for line in open(f"{out}/cams.tsv")] if os.path.exists(f"{out}/cams.tsv") else []
    camrows = collections.defaultdict(list)
    detrows = []
    for r in rows:
        if r[3].startswith("detector "):
            detrows.append(r)
            continue
        name = re.sub(r"^opencv_", "", r[3])
        c = by_name.get(name)
        camrows[model_of(c) if c else f"unknown ({name})"].append(r)
    single = len(models) == 1
    print("### Measured, per model (every step and condition pooled; per-condition rows are in the table above)\n")
    print("| model | cameras | windows | fps avg | latency median ms | p95 ms | max ms | detect avg ms | detect max ms | margin avg | USB B/microframe | min exposure (raw) | USB recovery s (median / worst) |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    rec = collections.defaultdict(list)
    if os.path.exists(f"{out}/usb-recovery.txt"):
        for line in open(f"{out}/usb-recovery.txt"):
            m = re.match(r"round \d+\s+(\w+)\s+([\d.]+)\s+(\S+)", line)
            if m and m.group(2) in by_port:
                rec[model_of(by_port[m.group(2)])].append(None if m.group(3) == "never" else float(m.group(3)))
    for m in list(models) + [k for k in camrows if k not in models]:
        cs = models.get(m, [])
        rr = camrows.get(m, [])
        col = lambda i: [num(r[i]) if i < len(r) else None for r in rr]
        d = detrows if single else []
        dcol = lambda i: [num(r[i]) if i < len(r) else None for r in d]
        rv = rec.get(m, [])
        rec_s = ""
        if rv:
            ok = [x for x in rv if x is not None]
            rec_s = f"{fmt([statistics.median(ok)]) if ok else '-'} / {'never' if None in rv else fmt(ok, 'max')}"
        print(f"| {m} | {len(cs)} | {len(rr)} | {fmt(col(4))} | {fmt(col(5))} | {fmt(col(6))} | {fmt(col(7), 'max')} | "
              f"{fmt(dcol(8)) if single else 'n/a'} | {fmt(dcol(9), 'max') if single else 'n/a'} | "
              f"{fmt(dcol(12)) if single else 'n/a'} | {spread(c['reservedBytes'] for c in cs)} | "
              f"{spread(c['exposureMin'] for c in cs)} | {rec_s or ('not run' if not rec else '-')} |")
    print()
    if not single and detrows:
        print("Detect time and decision margin: the detector's log lines (h0, h1, ...) don't say which camera they are,"
              " so with mixed models they can't be split by model; see the detector rows in the table above.\n")
    print("Per camera (all windows pooled):\n")
    print("| model | camera | port | windows | fps avg | latency median ms | p95 ms | max ms | USB recovery s (each drop) |")
    print("|---|---|---|---|---|---|---|---|---|")
    percam = collections.defaultdict(list)
    for r in rows:
        if not r[3].startswith("detector "):
            percam[re.sub(r"^opencv_", "", r[3])].append(r)
    for m, cs in models.items():
        for c in cs:
            rr = percam.get(c["camera"], [])
            col = lambda i: [num(r[i]) for r in rr]
            recs = []
            if os.path.exists(f"{out}/usb-recovery.txt"):
                recs = [f"{x.split()[2]} {x.split()[4]}" for x in open(f"{out}/usb-recovery.txt")
                        if len(x.split()) >= 5 and x.split()[3] == c["port"]]
            print(f"| {m} | {c['camera'] or '?'} | {c['port']} | {len(rr)} | {fmt(col(4))} | {fmt(col(5))} | "
                  f"{fmt(col(6))} | {fmt(col(7), 'max')} | {'; '.join(recs) or '-'} |")
    print("\nStatic jitter (stills step) is not computed here: the field-replay accuracy judge"
          " (tests/field-replay/accuracy) does that offline from the Rewind recordings.\n")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "inventory":
        inventory(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[1] == "compare":
        compare(sys.argv[2])
    else:
        sys.exit(__doc__)
