#!/usr/bin/env python3
"""Upstream watch: has anything we build on changed, and would our patches still apply?

Run by .github/workflows/upstream-watch.yml (weekly, or by hand). For each upstream it compares the
newest version with the one this repo pins, lists what's new (filtered to the paths we use), and for
the code we patch, tries every patch against the newest commit. Then it keeps one GitHub issue per
upstream (label upstream-watch): opened the first time there's something new, commented on only when
something newer appears (comments notify; edits don't), closed when we've caught up.

Locally, `upstream_watch.py --dry-run` prints the reports and touches no issues.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DRY = "--dry-run" in sys.argv
WORK = tempfile.mkdtemp(prefix="upstream-watch-")
GH_REPO = os.environ.get("GITHUB_REPOSITORY", "Spectrum3847/SpectrumJetson")
LABEL = "upstream-watch"


def sh(*cmd, cwd=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip()[-400:]}")
    return r


def pin(path, pattern):
    m = re.search(pattern, open(os.path.join(REPO, path)).read(), re.M)
    if not m:
        raise SystemExit(f"no pin matching {pattern!r} in {path}")
    return m.group(1)


def api(path):
    req = urllib.request.Request("https://api.github.com/" + path, headers={"Accept": "application/vnd.github+json"})
    if os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    return json.load(urllib.request.urlopen(req, timeout=30))


def clone(url, name):
    d = os.path.join(WORK, name)
    sh("git", "clone", "-q", "--filter=blob:none", "--no-checkout", url, d)
    return d


def commits(d, since, head, paths=()):
    out = sh("git", "log", "--format=%h %ad %s", "--date=short", f"{since}..{head}", "--", *paths, cwd=d).stdout
    return [l for l in out.splitlines() if l.strip()]


def try_patches(d, ref, patch_glob):
    """Apply our patches in order on ref; (applied, total, first failure or None)."""
    sh("git", "checkout", "-q", "-f", ref, cwd=d)
    patches = sorted(p for p in os.listdir(os.path.join(REPO, "patches")) if re.fullmatch(patch_glob, p))
    for i, p in enumerate(patches):
        r = sh("git", "apply", os.path.join(REPO, "patches", p), cwd=d, check=False)
        if r.returncode:
            err = (r.stderr.strip().splitlines() or ["?"])[0]
            return i, len(patches), f"{p}: {err}"
    return len(patches), len(patches), None


def version_key(tag):
    m = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-(alpha|beta|rc)-?(\d+))?", tag)
    if not m:
        return [-1]
    a, b, c, d, stage, n = m.groups()
    return [int(a), int(b), int(c or 0), int(d or 0), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(n or 0)]


def report_pv_main():
    sha = pin("scripts/host/03-build-photonvision-fork.sh", r"^UPSTREAM_SHA=([0-9a-f]+)")
    d = clone("https://github.com/PhotonVision/photonvision.git", "pv")
    head = sh("git", "rev-parse", "origin/HEAD", cwd=d).stdout.strip()
    new = commits(d, sha, head)
    if not new:
        return None
    ok, total, fail = try_patches(d, head, r"photonvision-2027-alpha7-migration\.patch")
    patches = (f"The migration patch applies to `{head[:8]}`." if not fail else
               f"**The migration patch doesn't apply** to `{head[:8]}`: `{fail}`.")
    return {
        "key": f"pvmain:{head}",
        "title": "Upstream: PhotonVision main (the alpha-7 base we build on)",
        "body": f"We pin `{sha[:8]}` (`scripts/host/03-build-photonvision-fork.sh`). {len(new)} new commit(s) on main:\n\n"
                + "\n".join(f"- {c}" for c in new[:40]) + ("\n- …" if len(new) > 40 else "")
                + f"\n\n{patches}\n\nTo update: change `UPSTREAM_SHA`, regenerate the migration patch, rebuild (`03-build-photonvision-fork.sh`), then run the test suites.",
    }


def report_photonvision():
    pinned = re.search(r"photonvision-00-upstream-(v[\d.]+)\.patch", " ".join(os.listdir(os.path.join(REPO, "patches")))).group(1)
    rels = api("repos/PhotonVision/photonvision/releases?per_page=40")
    newer = [r for r in rels if not r["draft"] and version_key(r["tag_name"]) > version_key(pinned)
             and r["tag_name"].startswith(pinned[:6])]          # same season (v2026.)
    nextyear = [r for r in rels if not r["draft"] and not r["tag_name"].startswith(pinned[:6])
                and version_key(r["tag_name"])[:1] > version_key(pinned)[:1]]
    if not newer and not nextyear:
        return None
    lines = []
    if newer:
        lines.append(f"**New {pinned[1:5]} releases** (we merge `{pinned}` in `patches/photonvision-00-upstream-{pinned}.patch`):")
        lines += [f"- [{r['tag_name']}]({r['html_url']}) ({r['published_at'][:10]})" for r in newer]
    if nextyear:
        lines.append("\n**Next season's releases** (check PhotonLib's message format against the robot's before using; README: \"don't upgrade the robot's PhotonLib past alpha-6\"):")
        lines += [f"- [{r['tag_name']}]({r['html_url']}) ({r['published_at'][:10]})" for r in nextyear[:10]]
    return {
        "key": "pv:" + ",".join(r["tag_name"] for r in newer + nextyear),
        "title": "Upstream: PhotonVision releases",
        "body": "\n".join(lines) + "\n\nTo take a release: regenerate patch 00 (the upstream merge) and rebuild; the 4143 fork may need the same merge.",
    }


def report_bos():
    sha = pin("scripts/jetson/07-build-bos-detector.sh", r"^BOS_SHA=([0-9a-f]+)")
    d = clone("https://github.com/frc971/bos.git", "bos")
    head = sh("git", "rev-parse", "origin/HEAD", cwd=d).stdout.strip()
    new = commits(d, sha, head, ["third_party/971apriltag"])
    if not new:
        return None
    ok, total, fail = try_patches(d, head, r"bos-\d+.*\.patch")
    patches = (f"All {total} `bos-*` patches apply to `{head[:8]}`." if not fail else
               f"**{ok} of {total} patches apply**; the first that doesn't is `{fail}`.")
    return {
        "key": f"bos:{head}",
        "title": "Upstream: frc971/bos (the CUDA AprilTag detector)",
        "body": f"We pin `{sha}` (`scripts/jetson/07-build-bos-detector.sh`). {len(new)} new commit(s) touching `third_party/971apriltag`:\n\n"
                + "\n".join(f"- {c}" for c in new[:40])
                + f"\n\n{patches}\n\nTo update: change `BOS_SHA`, rebuild on the Jetson, and compare detections with a Rewind replay (`tests/far-search/replay.sh`).",
    }


def report_aos():
    reviewed = pin("scripts/ci/upstream-pins.env", r"^AOS_REVIEWED=([0-9a-f]+)")
    d = clone("https://github.com/RealtimeRoboticsGroup/aos.git", "aos")
    head = sh("git", "rev-parse", "origin/HEAD", cwd=d).stdout.strip()
    paths = ["frc/orin", "frc/vision"]
    new = commits(d, reviewed, head, paths)
    if not new:
        return None
    return {
        "key": f"aos:{head}",
        "title": "Upstream: RealtimeRoboticsGroup/aos (where Austin develops the detector now)",
        "body": f"Last reviewed `{reviewed[:9]}` (`scripts/ci/upstream-pins.env`). {len(new)} new commit(s) in `frc/orin` and `frc/vision`:\n\n"
                + "\n".join(f"- [{c}](https://github.com/RealtimeRoboticsGroup/aos/commit/{c.split()[0]})" for c in new[:40])
                + "\n\nWe build from bos, not aos: these are for reading (detector fixes worth porting as a `bos-*` patch). "
                  f"Once reviewed, set `AOS_REVIEWED={head[:9]}`.",
    }


def report_allwpilib():
    pinned = pin("scripts/jetson/04-build-allwpilib.sh", r"^TAG=(v[\w.-]+)")
    tags = [t["name"] for t in api("repos/wpilibsuite/allwpilib/tags?per_page=100")]
    newer = sorted({t for t in tags if t.startswith(pinned[:6]) and version_key(t) > version_key(pinned)},
                   key=version_key)
    if not newer:
        return None
    return {
        "key": "allwpilib:" + ",".join(newer),
        "title": "Upstream: allwpilib (the detector's runtime libraries)",
        "body": f"We use `{pinned}`'s headers (`scripts/jetson/04-build-allwpilib.sh`). Newer tags this season: "
                + ", ".join(f"`{t}`" for t in newer)
                + "\n\nThe detector compiles against wpiutil's `RawFrame.h` and `PixelFormat.h` and links no WPILib library. They must match PhotonVision's `wpilibVersion`, so move both together.",
    }


def report_l4t():
    pinned = pin("config.env", r"^L4T_VERSION=([\d.]+)")
    major_minor = ".".join(pinned.split(".")[:2])  # 36.5
    try:
        html = urllib.request.urlopen("https://repo.download.nvidia.com/jetson/common/dists/", timeout=30).read().decode()
    except Exception as e:
        print(f"  couldn't reach NVIDIA's apt repo ({e}): L4T not checked this run")
        return "unchecked"
    found = sorted({m for m in re.findall(r"r(\d+\.\d+)/", html) if m.split(".")[0] == pinned.split(".")[0]},
                   key=lambda v: [int(x) for x in v.split(".")])
    newer = [v for v in found if [int(x) for x in v.split(".")] > [int(x) for x in major_minor.split(".")]]
    if not newer:
        return None
    return {
        "key": "l4t:" + ",".join(newer),
        "title": "Upstream: NVIDIA Jetson Linux (L4T / JetPack)",
        "body": f"We flash L4T `{pinned}` (`config.env`). NVIDIA's apt repo now has: " + ", ".join(f"`r{v}`" for v in newer)
                + "\n\nA new L4T means a new kernel: the camera driver patch, the prebuilt bundle and the flash all need redoing. Only worth it for a fix we need.",
    }


def gh(*args, input=None):
    """Runs gh against this repo; a failure raises (a failed "issue list" used to look like "no
    issue yet", and the next step opened a duplicate)."""
    r = subprocess.run(["gh", *args, "--repo", GH_REPO], capture_output=True, text=True, input=input)
    if r.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])} failed: {(r.stderr or r.stdout).strip()[:300]}")
    return r


def sync_issue(report, title):
    """Open, update, reopen or close this upstream's issue.

    One issue per upstream, found by title among open and closed ones. The marker in its body says
    what news it holds: the same news again changes nothing, so an issue someone closed by hand
    (read, nothing to take) stays closed until something newer appears."""
    found = json.loads(gh("issue", "list", "--label", LABEL, "--state", "all", "--json",
                          "number,title,body,state", "--limit", "100").stdout or "[]")
    mine = sorted((i for i in found if i["title"] == title), key=lambda i: i["number"], reverse=True)
    issue = mine[0] if mine else None
    is_open = issue is not None and issue["state"] == "OPEN"
    if report is None:
        if is_open:
            gh("issue", "close", str(issue["number"]), "--comment", "Caught up: nothing newer than what this repo pins.")
            print(f"  closed #{issue['number']}")
        return
    marker = f"<!-- upstream-watch {report['key']} -->"
    body = report["body"] + f"\n\n_Checked by `.github/workflows/upstream-watch.yml`._\n{marker}"
    if issue is None:
        r = gh("issue", "create", "--title", title, "--label", LABEL, "--body-file", "-", input=body)
        print(f"  opened {r.stdout.strip()}")
    elif marker in (issue["body"] or ""):
        print(f"  #{issue['number']} unchanged" + ("" if is_open else " (closed by hand: left closed)"))
    else:
        gh("issue", "edit", str(issue["number"]), "--body-file", "-", input=body)
        if not is_open:
            gh("issue", "reopen", str(issue["number"]))
        gh("issue", "comment", str(issue["number"]), "--body-file", "-", input="Something newer:\n\n" + report["body"])
        print(f"  updated #{issue['number']} (commented: something newer" + ("" if is_open else "; reopened") + ")")


def main():
    checks = [
        ("Upstream: PhotonVision main (the alpha-7 base we build on)", report_pv_main),
        ("Upstream: PhotonVision releases", report_photonvision),
        ("Upstream: frc971/bos (the CUDA AprilTag detector)", report_bos),
        ("Upstream: RealtimeRoboticsGroup/aos (where Austin develops the detector now)", report_aos),
        ("Upstream: allwpilib (the detector's runtime libraries)", report_allwpilib),
        ("Upstream: NVIDIA Jetson Linux (L4T / JetPack)", report_l4t),
    ]
    if not DRY:
        try:
            gh("label", "create", LABEL, "--color", "6A2FB8", "--description", "Something we build on has changed", "--force")
        except RuntimeError as e:
            print(f"label: {e}")
    failed = 0
    for title, check in checks:
        print(f"== {title}")
        try:
            report = check()
        except Exception as e:
            print(f"  check failed: {e}")
            failed += 1
            continue
        if report == "unchecked":
            continue  # leave its issue as it is
        print("  " + ("nothing new" if report is None else report["body"].replace("\n", "\n  ")))
        if not DRY:
            try:
                sync_issue(report, title)
            except Exception as e:
                print(f"  issue update failed: {e}")
                failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
