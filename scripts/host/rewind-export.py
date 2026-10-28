#!/usr/bin/env python3
"""Turn a Rewind recording (copied from the Jetson with rewind-pull.sh) into videos.

Each camera's recording is its own MJPEG frames in 5 min segments (.mjpeg + .csv, docs/REWIND.md). This
writes one MJPEG .avi per camera, with no re-encoding and no dependencies (plain Python), which
VLC, mpv and most players open. The frame rate in the .avi is the recording's average; the exact
per-frame times (Jetson clock and robot clock) are in <camera>.frames.csv next to it, for lining
the video up with an AdvantageKit log.

With --mp4 and ffmpeg installed (sudo apt install ffmpeg), also writes an H.264 .mp4 per camera
(about 5-10x smaller, better for sharing and AdvantageScope), timed from the real frame times.

Usage: rewind-export.py <session folder> [--out DIR] [--mp4]
"""

import argparse
import csv
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

AVI_LIMIT = 1_900_000_000  # stay under the 2 GB RIFF limit; longer recordings get split


def read_frames(cam_dir):
    """Yield (segment path, offset, size, width, height, jetson_us, robot_us) for every frame."""
    for idx in sorted(cam_dir.glob("*.csv")):
        data = idx.with_suffix(".mjpeg")
        if not data.exists():
            continue
        length = data.stat().st_size
        with idx.open() as f:
            for row in csv.reader(line for line in f if not line.startswith("#")):
                if len(row) < 7:
                    continue
                off, size = int(row[1]), int(row[2])
                if off + size > length:  # the Jetson stopped mid-write
                    break
                yield data, off, size, int(row[3]), int(row[4]), int(row[5]), row[6]


class AviWriter:
    """Minimal AVI 1.0 (RIFF) writer for MJPEG frames: hdrl, movi, idx1."""

    def __init__(self, path, width, height, fps):
        self.f = open(path, "wb")
        self.w, self.h, self.fps = width, height, fps
        self.index = []
        self.max_frame = 0
        self._header()

    def _header(self):
        f = self.f
        f.write(b"RIFF\0\0\0\0AVI ")
        # hdrl LIST
        self.hdrl_start = f.tell()
        f.write(b"LIST\0\0\0\0hdrl")
        self.avih_pos = f.tell()
        f.write(b"avih" + struct.pack("<I", 56) + b"\0" * 56)
        f.write(b"LIST" + struct.pack("<I", 4 + 8 + 56 + 8 + 40) + b"strl")
        self.strh_pos = f.tell()
        f.write(b"strh" + struct.pack("<I", 56) + b"\0" * 56)
        f.write(b"strf" + struct.pack("<I", 40))
        f.write(struct.pack("<IiiHH4sIiiII", 40, self.w, self.h, 1, 24, b"MJPG",
                            self.w * self.h * 3, 0, 0, 0, 0))
        end = f.tell()
        f.seek(self.hdrl_start + 4)
        f.write(struct.pack("<I", end - self.hdrl_start - 8))
        f.seek(end)
        self.movi_start = f.tell()
        f.write(b"LIST\0\0\0\0movi")

    def add(self, jpeg):
        pos = self.f.tell() - (self.movi_start + 8)
        self.f.write(b"00dc" + struct.pack("<I", len(jpeg)) + jpeg)
        if len(jpeg) % 2:
            self.f.write(b"\0")
        self.index.append((pos, len(jpeg)))
        self.max_frame = max(self.max_frame, len(jpeg))

    def size(self):
        return self.f.tell()

    def close(self):
        f = self.f
        movi_end = f.tell()
        f.seek(self.movi_start + 4)
        f.write(struct.pack("<I", movi_end - self.movi_start - 8))
        f.seek(movi_end)
        f.write(b"idx1" + struct.pack("<I", 16 * len(self.index)))
        for pos, size in self.index:
            f.write(b"00dc" + struct.pack("<III", 0x10, pos, size))  # AVIIF_KEYFRAME
        end = f.tell()
        f.seek(4)
        f.write(struct.pack("<I", end - 8))
        n = len(self.index)
        us_per_frame = int(round(1e6 / self.fps))
        f.seek(self.avih_pos + 8)
        f.write(struct.pack("<IIIIIIIIII", us_per_frame, int(self.max_frame * self.fps), 0, 0x10, n, 0, 1,
                            self.max_frame, self.w, self.h) + b"\0" * 16)
        # strh: rate/scale = fps as a fraction (x1000 for non-integer rates)
        f.seek(self.strh_pos + 8)
        f.write(b"vids" + b"MJPG" + struct.pack("<IHHIIIIIIIIhhhh", 0, 0, 0, 0, 1000,
                                                int(round(self.fps * 1000)), 0, n, self.max_frame,
                                                0xFFFFFFFF, 0, 0, 0, self.w, self.h))
        f.close()


def export_camera(cam_dir, out_dir, mp4):
    frames = list(read_frames(cam_dir))
    if not frames:
        print(f"  {cam_dir.name}: no frames")
        return
    name = cam_dir.name
    t0, t1 = frames[0][5], frames[-1][5]
    fps = (len(frames) - 1) / ((t1 - t0) / 1e6) if t1 > t0 else 30.0
    w, h = frames[0][3], frames[0][4]

    # Exact per-frame times, for lining up with AdvantageKit logs.
    with open(out_dir / f"{name}.frames.csv", "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["frame", "video_s", "jetson_us", "robot_us", "robot_s"])
        for i, fr in enumerate(frames):
            robot = fr[6]
            wr.writerow([i, f"{(fr[5] - t0) / 1e6:.6f}", fr[5], robot,
                         f"{int(robot) / 1e6:.6f}" if robot else ""])

    part, avi, files = 0, None, []
    open_data = {}
    bad = 0
    for fr in frames:
        if avi is None or avi.size() > AVI_LIMIT:
            if avi:
                avi.close()
            part += 1
            p = out_dir / (f"{name}.avi" if part == 1 else f"{name}.part{part}.avi")
            avi = AviWriter(p, w, h, fps)
            files.append(p)
        data = open_data.get(fr[0])
        if data is None:
            for d in open_data.values():
                d.close()
            open_data = {fr[0]: open(fr[0], "rb")}
            data = open_data[fr[0]]
        data.seek(fr[1])
        jpeg = data.read(fr[2])
        if jpeg[:2] != b"\xff\xd8" or jpeg[-2:] != b"\xff\xd9":
            bad += 1  # not a complete JPEG (start and end markers)
        avi.add(jpeg)
    avi.close()
    for d in open_data.values():
        d.close()
    secs = (t1 - t0) / 1e6
    synced = "robot clock synced" if frames[0][6] else "no robot clock (not connected)"
    print(f"  {name}: {len(frames)} frames, {secs:.1f} s, {fps:.1f} fps avg, {w}x{h}, {synced}")
    if bad:
        print(f"    WARNING: {bad} of {len(frames)} frames are not complete JPEGs")
    for p in files:
        print(f"    {p}")

    if mp4:
        export_mp4(frames, out_dir / f"{name}.mp4")


def export_mp4(frames, path):
    """H.264 with the real frame times (ffmpeg concat demuxer with per-frame durations)."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("    (skipping .mp4: ffmpeg is not installed; sudo apt install ffmpeg)")
        return
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        lines = ["ffconcat version 1.0"]
        handles = {}
        for i, fr in enumerate(frames):
            if fr[0] not in handles:
                handles[fr[0]] = open(fr[0], "rb")
            src = handles[fr[0]]
            src.seek(fr[1])
            jpg = tmp / f"{i:07d}.jpg"
            jpg.write_bytes(src.read(fr[2]))
            dur = (frames[i + 1][5] - fr[5]) / 1e6 if i + 1 < len(frames) else 1 / 30
            lines += [f"file '{jpg.name}'", f"duration {dur:.6f}"]
        for hdl in handles.values():
            hdl.close()
        (tmp / "list.ffconcat").write_text("\n".join(lines) + "\n")
        cmd = [ffmpeg, "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i",
               str(tmp / "list.ffconcat"), "-vsync", "vfr", "-c:v", "libx264", "-preset", "veryfast",
               "-crf", "23", "-pix_fmt", "yuv420p", str(path)]
        r = subprocess.run(cmd)
        print(f"    {path}" if r.returncode == 0 else f"    ffmpeg failed ({r.returncode})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path, help="a session folder (contains <session>_session.json)")
    ap.add_argument("--out", type=Path, help="output folder (default: <session>/export)")
    ap.add_argument("--mp4", action="store_true", help="also write H.264 .mp4 files (needs ffmpeg)")
    a = ap.parse_args()
    if not a.session.is_dir():
        sys.exit(f"{a.session} is not a folder")
    out = a.out or a.session / "export"
    out.mkdir(parents=True, exist_ok=True)
    meta = a.session / f"{a.session.resolve().name}_session.json"
    if not meta.exists():
        meta = a.session / "session.json"  # before photonvision-75
    if meta.exists():
        m = json.loads(meta.read_text())
        print(f"{m.get('name')}: {m.get('reason')}, match '{m.get('match')}', label '{m.get('label')}'"
              f"{', ended: ' + m['endReason'] if m.get('endReason') else ''}")
    cams = [d for d in sorted(a.session.iterdir()) if d.is_dir() and d.name != "export"]
    for cam in cams:
        export_camera(cam, out, a.mp4)


if __name__ == "__main__":
    main()
