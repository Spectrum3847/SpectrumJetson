#!/usr/bin/env python3
"""Detector regression check: a fixed corpus of recordings, replayed through the detector we build,
compared detection by detection with the output we last accepted ("golden"). Run ON THE JETSON,
through run.sh (which builds far_replay first and puts a deadline on everything).

  regress.py check [NAME...]       replay and compare (default: every session); exit 1 on any change
  regress.py bless [NAME...]       accept the current output as golden, after reading check's report
  regress.py add NAME DIR [--about TEXT]   copy a Rewind session into the corpus (run.sh holds quiet
                                   mode off while it copies), then bless it
  regress.py register NAME [--about TEXT]  record the checksum of a session already in the corpus

The corpus lives on the scratch partition at /opt/photonvision/rewind/regression (beside Rewind's
sessions, which Rewind's quota never touches), with a copy on the laptop. corpus.json records each
session's checksum, so a damaged or swapped recording shows as such instead of as a detector change.
Goldens are golden/NAME.csv.gz in the repo: far_replay's output (every camera of a session, merged
in recording order, far-tag search on as live), one row per detection.
"""
import argparse, csv, gzip, hashlib, io, json, os, shutil, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = Path(os.environ.get("SPECTRUM_REGRESSION_CORPUS", "/opt/photonvision/rewind/regression"))
FAR_REPLAY = Path(os.environ.get("FAR_REPLAY", Path.home() / "build/bos-detector/far_replay"))
MANIFEST = HERE / "corpus.json"
GOLDEN = HERE / "golden"
OUT = Path("/tmp/spectrum-regression")
TOL = 1e-3  # px and decision-margin units; replays are bit-for-bit repeatable, this is CSV rounding


def load_manifest():
    if MANIFEST.exists():
        return json.loads(MANIFEST.read_text())
    return {"detector_args": ["--mwbd", "20"], "sessions": {}}


def save_manifest(m):
    MANIFEST.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")


def tree_hash(d: Path):
    """sha256 over every file's path and contents, and the totals."""
    h, n, size = hashlib.sha256(), 0, 0
    for p in sorted(x for x in d.rglob("*") if x.is_file()):
        fh = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                fh.update(chunk)
        h.update(str(p.relative_to(d)).encode() + b"\0" + fh.digest())
        n += 1
        size += p.stat().st_size
    return h.hexdigest(), n, size


def calib_args(session: Path):
    """--calib CAMERA=fx,fy,cx,cy,k1..k6 for each camera with a lens calibration in session.json
    (folder names are the camera names with spaces as dashes, as Rewind writes them)."""
    try:
        meta = session / f"{session.resolve().name}_session.json"
        if not meta.exists():
            meta = session / "session.json"
        cams = json.loads(meta.read_text())["settings"]["cameras"]
    except (OSError, KeyError, ValueError):
        return []
    args = []
    for name, v in sorted(cams.items()):
        c = v.get("calibration") or {}
        d = c.get("distCoeffs") or []
        if not c.get("fx") or not (session / name.replace(" ", "-")).is_dir():
            continue
        vals = [c["fx"], c["fy"], c["cx"], c["cy"]] + list(d[:8]) + [0] * (8 - min(8, len(d)))
        args += ["--calib", "%s=%s" % (name.replace(" ", "-"), ",".join(repr(float(x)) for x in vals))]
    return args


def replay(name, m):
    session = CORPUS / name
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / (name + ".csv")
    cmd = [str(FAR_REPLAY), str(session), "--out", str(out)] + m["detector_args"] + calib_args(session)
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise RuntimeError("far_replay failed on %s (exit %d): %s" % (name, r.returncode, r.stderr[-800:]))
    return out, time.time() - t0, r.stdout


def rows(text):
    """{(camera, frame, id, source): (margin, side_px, corners...)} from far_replay's CSV."""
    rd = csv.DictReader(io.StringIO(text))
    out = {}
    for r in rd:
        key = (r["camera"], int(r["frame"]), int(r["id"]), r["source"])
        vals = [float(r["margin"]), float(r["side_px"])] + [float(r[k]) for k in
                ("x0", "y0", "x1", "y1", "x2", "y2", "x3", "y3")]
        out[key] = vals
    return out


def compare(name, golden_text, now_text):
    g, n = rows(golden_text), rows(now_text)
    lost = sorted(set(g) - set(n))
    found = sorted(set(n) - set(g))
    moved, worst = [], 0.0
    for k in set(g) & set(n):
        d = max(abs(a - b) for a, b in zip(g[k], n[k]))
        worst = max(worst, d)
        if d > TOL:
            moved.append((d, k))
    moved.sort(reverse=True)
    same = len(set(g) & set(n)) - len(moved)
    ok = not lost and not found and not moved
    print("  %s: %d detections, %s" % (name, len(g), "identical" if ok else
          "%d the same, %d moved (worst %.3f), %d lost, %d new" % (same, len(moved), worst, len(lost), len(found))))
    for label, items in (("lost", lost), ("new", found)):
        for k in items[:5]:
            print("    %s: camera %s frame %d tag %d (%s)" % (label, *k))
        if len(items) > 5:
            print("    ... %d more %s" % (len(items) - 5, label))
    for d, k in moved[:5]:
        print("    moved %.3f: camera %s frame %d tag %d (%s)" % (d, *k))
    # By tag id, so a lost far tag and a found near one don't cancel out in a glance.
    return ok


def check(names, m):
    bad = []
    for name in names:
        if name not in m["sessions"]:
            print("  %s: not in corpus.json (add it with: run.sh --add %s DIR)" % (name, name))
            bad.append(name)
            continue
        if not (CORPUS / name).is_dir():
            print("  %s: MISSING from %s (restore it from the laptop's ~/spectrum-regression-corpus)" % (name, CORPUS))
            bad.append(name)
            continue
        h, nfiles, size = tree_hash(CORPUS / name)
        if h != m["sessions"][name]["sha256"]:
            print("  %s: the recording itself changed (checksum), so this isn't a detector result; restore it" % name)
            bad.append(name)
            continue
        gpath = GOLDEN / (name + ".csv.gz")
        if not gpath.exists():
            print("  %s: no golden output yet (bless it)" % name)
            bad.append(name)
            continue
        out, secs, _ = replay(name, m)
        print("  %s replayed in %.0f s" % (name, secs))
        if not compare(name, gzip.decompress(gpath.read_bytes()).decode(), out.read_text()):
            bad.append(name)
    return bad


def bless(names, m):
    GOLDEN.mkdir(exist_ok=True)
    rev = subprocess.run(["cat", str(HERE.parent.parent / ".spectrum-commit")], capture_output=True, text=True).stdout.strip()
    for name in names:
        out, secs, summary = replay(name, m)
        text = out.read_text()
        # mtime 0: the same output gives the same .gz bytes, so git sees no change
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as z:
            z.write(text.encode())
        (GOLDEN / (name + ".csv.gz")).write_bytes(buf.getvalue())
        m["sessions"][name]["blessed"] = {"commit": rev or "unknown", "date": time.strftime("%Y-%m-%d"),
                                          "detections": max(0, text.count("\n") - 1)}
        print("  %s: blessed, %d detections (replay %.0f s)" % (name, m["sessions"][name]["blessed"]["detections"], secs))
    save_manifest(m)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "bless", "add", "register"])
    ap.add_argument("names", nargs="*")
    ap.add_argument("--about", default="")
    a = ap.parse_args()
    m = load_manifest()
    if not FAR_REPLAY.exists():
        sys.exit("No far_replay at %s (run.sh builds it)" % FAR_REPLAY)

    if a.cmd == "add":
        if len(a.names) != 2:
            sys.exit("usage: regress.py add NAME SESSION_DIR")
        name, src = a.names[0], Path(a.names[1])
        dst = CORPUS / name
        if dst.exists():
            sys.exit("%s is already in the corpus" % name)
        shutil.copytree(src, dst)
        for d in [x for x in dst.iterdir() if x.is_dir() and not any(x.iterdir())]:
            d.rmdir()  # a camera that recorded nothing
        h, nfiles, size = tree_hash(dst)
        m["sessions"][name] = {"about": a.about, "sha256": h, "files": nfiles, "bytes": size}
        save_manifest(m)
        bless([name], m)
        print("Copy it to the laptop too: rsync -a JETSON:%s/ ~/spectrum-regression-corpus/" % CORPUS)
        return

    if a.cmd == "register":
        for name in a.names:
            h, nfiles, size = tree_hash(CORPUS / name)
            m["sessions"].setdefault(name, {}).update({"sha256": h, "files": nfiles, "bytes": size})
            if a.about:
                m["sessions"][name]["about"] = a.about
            print("  %s: %d files, %.0f MB" % (name, nfiles, size / 1e6))
        save_manifest(m)
        return

    names = a.names or sorted(m["sessions"])
    if a.cmd == "bless":
        bless(names, m)
        return
    print("Detector regression: %d session(s), far_replay %s" % (len(names), " ".join(m["detector_args"])))
    bad = check(names, m)
    print("PASS: every detection the same as golden" if not bad else
          "CHANGED: %s. If the change is intended, bless it (run.sh --bless %s) and commit the goldens."
          % (", ".join(bad), " ".join(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
