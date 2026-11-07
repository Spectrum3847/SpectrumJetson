#!/usr/bin/env python3
"""Fetch TXMAN1 Orin recordings and robot logs from robotlog.spectrum3847.org (public read API).

    python fetch_robotlog.py list                       # matches with Orin video: label, sessions, MB
    python fetch_robotlog.py fetch LABEL DATA [--no-video]

`fetch` writes DATA/<label>/<camera>/<session>_<camera>_NNNN.{mjpeg,csv} (the layout replay/detect.sh reads) and
DATA/logs/txman1_<label>_<log>.wpilog (the name TxmanReplay finds by `_<label>_`). Files already there with the
right size are skipped.

Pairing sessions with a log: every session records `robotOffsetUs` (robot clock minus Jetson clock), which is
fixed for one robot boot. A match with two robot logs (Q19: a reboot before the match) has two offsets. Sessions
are grouped by offset and the groups paired with the logs in boot order; only the pair whose log is the match's
own (its name has `txman1`, else the biggest) is fetched. Sessions with offset 0 (no time sync yet) join the
group of the session before them.
"""

import json
import sys
import urllib.request
from pathlib import Path

SITE = "https://robotlog.spectrum3847.org"
EVENT = "2026txman1"
CAMERAS = ("orin-left", "orin-right")


def get(url):
    # Cloudflare refuses Python's default user agent.
    req = urllib.request.Request(SITE + url, headers={"User-Agent": "SpectrumJetson-robot-ekf-replay"})
    return urllib.request.urlopen(req, timeout=120)


def matches():
    """TXMAN1 matches that have Orin video, keyed by short label (Q17, r4)."""
    out = {}
    for m in json.load(get("/api/v1/matches?team=8515"))["matches"]:
        if not any(f["name"].endswith(".mjpeg") for f in m["files"]):
            continue
        if m.get("tbaEventKey") != EVENT and not m["label"].startswith("TXMAN1"):
            continue
        out[m["label"].split()[-1]] = m
    return out


def session_of(name):
    """0005_Q19_20261015-152902_orin-left_0000.mjpeg -> 0005_Q19_20261015-152902"""
    for cam in CAMERAS:
        if "_" + cam + "_" in name:
            return name.split("_" + cam + "_")[0]
    if name.endswith("_session.json"):
        return name[: -len("_session.json")]
    return None


def pick(m):
    """The match's own log and the sessions recorded on its robot boot."""
    logs = [f for f in m["files"] if f["name"].endswith(".wpilog")]
    own = sorted(logs, key=lambda f: ("txman1" in f["name"], f["size"]))[-1]
    sessions = sorted({s for f in m["files"] if (s := session_of(f["name"]))})
    if len(logs) == 1:
        return own, sessions
    offsets = {}
    for f in m["files"]:
        if f["name"].endswith("_session.json"):
            offsets[session_of(f["name"])] = json.load(get(f["url"])).get("robotOffsetUs") or 0
    groups, last = {}, None
    for s in sessions:
        off = offsets.get(s, 0)
        if off == 0 and last is not None:
            key = last
        else:  # one boot's offset drifts by well under 5 s
            key = next((k for k in groups if k != 0 and abs(k - off) < 5e6), off)
        groups.setdefault(key, []).append(s)
        last = key
    # Robot boot in Jetson time is -offset; in Unix time it is the log's start minus its FPGA start.
    by_boot = [groups[k] for k in sorted(groups, key=lambda k: -k)]
    logs_by_boot = sorted(logs, key=lambda f: f["unixStartMs"] / 1000 - (f["fpgaStart"] or 0))
    if len(by_boot) != len(logs_by_boot):
        raise SystemExit(f"{m['label']}: {len(by_boot)} robot boots in the sessions but {len(logs)} logs")
    return own, by_boot[logs_by_boot.index(own)]


def download(f, dest):
    if dest.exists() and dest.stat().st_size == f["size"]:
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with get(f["url"]) as r, open(tmp, "wb") as o:
        while chunk := r.read(1 << 20):
            o.write(chunk)
    tmp.replace(dest)


def fetch(label, data, video=True):
    m = matches()[label]
    log, sessions = pick(m)
    stem = Path(log["name"]).stem
    dest = data / "logs" / f"txman1_{label}_{stem}.wpilog"
    if not dest.with_suffix(".tagekf.txt").exists():  # exported already: the log isn't needed again
        download(log, dest)
    n = 0
    for f in m["files"]:
        s = session_of(f["name"])
        if s not in sessions:
            continue
        cam = next((c for c in CAMERAS if "_" + c + "_" in f["name"]), None)
        if cam is None or not (f["name"].endswith(".csv") or (video and f["name"].endswith(".mjpeg"))):
            continue
        download(f, data / label / cam / f["name"])
        n += f["size"]
    print(f"{label}: log {log['name']}, sessions {' '.join(sessions)}, {n / 1e6:.0f} MB")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        for label, m in matches().items():
            mb = sum(f["size"] for f in m["files"] if f["name"].endswith(".mjpeg")) / 1e6
            print(label, f"{mb:.0f}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "fetch":
        fetch(sys.argv[2], Path(sys.argv[3]), "--no-video" not in sys.argv)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
