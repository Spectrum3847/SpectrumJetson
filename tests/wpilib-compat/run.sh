#!/usr/bin/env bash
# Does a WPILib release still match what the detector assumes? Run ON THE LAPTOP before building a
# Jetson release on a new WPILib (beta, release, ...). Reads allwpilib's source on GitHub; no Jetson.
#
# lib971apriltag.so links nothing of WPILib (detector/wpi_compat.h). It reads cscore's frames by
# address and creates WPILib's Java AprilTagDetection objects, so these must not change unnoticed:
#   1. WPI_RawFrame's fields (order, types): a change reads garbage frames, with no error at all
#   2. WPI_PIXFMT_MJPEG == 1
#   3. WPI_Now exists, returns int64_t, in nanoseconds (frame ages)
#   4. AprilTagDetection's package and its constructor
#      (String, int, int, float, double[], double, double, double[])
# Each is found by file name anywhere in the tag's tree, so a moved file still checks.
#
# Usage: tests/wpilib-compat/run.sh [tag]   (default v2027.0.0-alpha-8)
# Exit 0 if all match, 1 if anything changed (each named), 2 if GitHub couldn't be read.
set -uo pipefail
TAG=${1:-v2027.0.0-alpha-8}
cd "$(dirname "$0")" || exit 2
command -v gh >/dev/null || { echo "needs gh (GitHub CLI)" >&2; exit 2; }

tree=$(timeout 60 gh api "repos/wpilibsuite/allwpilib/git/trees/$TAG?recursive=1" --jq '.tree[].path') ||
  { echo "Can't read allwpilib $TAG from GitHub" >&2; exit 2; }
fetch() {  # fetch <file name> [path filter]: the first match's contents
  local path
  path=$(grep -E "/$1\$" <<<"$tree" | grep -E "${2:-.}" | grep -v -i test | head -1)
  [[ -n $path ]] || { echo "MISSING:$1"; return; }
  echo "PATH:$path"
  timeout 30 curl -sfL "https://raw.githubusercontent.com/wpilibsuite/allwpilib/$TAG/$path" || echo "UNREADABLE:$path"
}

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
fetch RawFrame.h 'native/include' >"$dir/rawframe"
fetch PixelFormat.h 'native/include' >"$dir/pixfmt"
fetch timestamp.h 'wpiutil/.*native/include' >"$dir/timestamp"
fetch AprilTagDetection.java 'src/main/java' >"$dir/detection"

python3 - "$TAG" "$dir" <<'PY'
import re, sys
tag, d = sys.argv[1], sys.argv[2]
fails = []

def load(name):
    t = open(f"{d}/{name}").read()
    if t.startswith(("MISSING:", "UNREADABLE:")):
        fails.append(f"{name}: {t.strip()}")
        return None, ""
    path, _, body = t.partition("\n")
    return path[5:], body

# 1. WPI_RawFrame: (type, name) in order, exactly as wpi_compat.h declares it.
want = [("uint8_t*", "data"), ("void(*)(void*,void*,size_t)", "freeFunc"), ("void*", "freeCbData"),
        ("size_t", "capacity"), ("size_t", "size"), ("int", "pixelFormat"), ("int", "width"),
        ("int", "height"), ("int", "stride"), ("int64_t", "timestamp"), ("int", "timestampSrc")]
path, body = load("rawframe")
if path:
    m = re.search(r"typedef struct WPI_RawFrame\s*{(.*?)}\s*WPI_RawFrame;", body, re.S)
    if not m:
        fails.append(f"{path}: no 'typedef struct WPI_RawFrame'")
    else:
        got = []
        for line in re.sub(r"//[^\n]*|/\*.*?\*/", "", m.group(1), flags=re.S).split(";"):
            line = " ".join(line.split())
            if not line:
                continue
            f = re.fullmatch(r"void \(\*(\w+)\)\((.*)\)", line)
            if f:
                args = ",".join(re.sub(r"\s*\w+$", "", a.strip()).replace(" ", "")
                                for a in f.group(2).split(","))
                got.append((f"void(*)({args})", f.group(1)))
            else:
                t, _, n = line.rpartition(" ")
                got.append((t.replace(" *", "*").replace(" ", ""), n.lstrip("*")))
        if got != want:
            fails.append(f"{path}: WPI_RawFrame fields changed\n    expected {want}\n    found    {got}")

# 2. MJPEG is the enum's second value, after UNKNOWN = 0.
path, body = load("pixfmt")
if path:
    m = re.search(r"enum WPI_PixelFormat\s*{(.*?)}", body, re.S)
    names = [re.sub(r"\s*=.*", "", e).strip()
             for e in re.sub(r"//[^\n]*", "", m.group(1) if m else "").split(",") if e.strip()]
    if names[:2] != ["WPI_PIXFMT_UNKNOWN", "WPI_PIXFMT_MJPEG"] or "WPI_PIXFMT_UNKNOWN = 0" not in body:
        fails.append(f"{path}: WPI_PIXFMT_MJPEG is no longer 1 (enum starts {names[:3]})")

# 3. int64_t WPI_Now(void), in nanoseconds.
path, body = load("timestamp")
if path:
    if not re.search(r"\bint64_t\s+WPI_Now\s*\(\s*void\s*\)", body):
        fails.append(f"{path}: no 'int64_t WPI_Now(void)'")
    doc = re.search(r"/\*\*((?:(?!\*/).)*?)\*/\s*int64_t\s+WPI_Now\s*\(", body, re.S)
    if not doc or "nanosecond" not in doc.group(1).lower():
        fails.append(f"{path}: WPI_Now's comment doesn't say nanoseconds (frame ages assume ns)")

# 4. AprilTagDetection's package and constructor.
path, body = load("detection")
if path:
    pkg = re.search(r"^package\s+([\w.]+);", body, re.M)
    if not pkg or pkg.group(1) != "org.wpilib.vision.apriltag":
        fails.append(f"{path}: package is {pkg.group(1) if pkg else '?'}, not org.wpilib.vision.apriltag "
                     "(GpuDetectorJNI.cc JNI_OnLoad looks it up by name)")
    want_args = ["String", "int", "int", "float", "double[]", "double", "double", "double[]"]
    ctors = [[" ".join(a.split()[:-1]) for a in m.group(1).split(",") if a.strip()]
             for m in re.finditer(r"\bAprilTagDetection\s*\(([^)]*)\)\s*{", body)]
    if want_args not in ctors:
        fails.append(f"{path}: no constructor ({', '.join(want_args)}); found {ctors}")

if fails:
    print(f"CHANGED in allwpilib {tag}: detector/wpi_compat.h and GpuDetectorJNI.cc need updating")
    for f in fails:
        print(" -", f)
    sys.exit(1)
print(f"OK: allwpilib {tag} matches what the detector assumes "
      "(WPI_RawFrame, MJPEG = 1, WPI_Now ns, AprilTagDetection)")
PY
