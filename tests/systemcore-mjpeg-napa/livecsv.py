#!/usr/bin/env python3
"""Per-frame view of a scmn_live --csv: stage histograms (1 ms bins) and the slowest frames.

  python3 livecsv.py LIVE.csv [--worst 5]
"""
import argparse
import collections
import csv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--worst", type=int, default=5)
    a = ap.parse_args()
    r = list(csv.DictReader(open(a.csv)))
    f = lambda x, k: float(x[k])  # noqa: E731
    stages = [("v4l2 -> first bytes seen", "v4l2_ms", "first_seen_ms"), ("first seen -> EOI seen", "first_seen_ms", "eoi_ms"),
              ("EOI seen -> pose (tail)", "eoi_ms", "pose_ms"), ("DQBUF -> pose", "dq_ms", "pose_ms")]
    for name, x, y in stages:
        h = collections.Counter(int(f(v, y) - f(v, x)) for v in r if f(v, x) > 0)
        print(f"{name:28s}", " ".join(f"{k}:{n}" for k, n in sorted(h.items())))
    print("streamed:", collections.Counter(v["streamed"] for v in r))
    for v in sorted(r, key=lambda v: f(v, "pose_ms") - f(v, "v4l2_ms"))[-a.worst:]:
        b = f(v, "v4l2_ms")
        print(f"seq {v['seq']}: first +{f(v, 'first_seen_ms') - b:.2f} eoi +{f(v, 'eoi_ms') - b:.2f} "
              f"dq +{f(v, 'dq_ms') - b:.2f} tags +{f(v, 'tags_ms') - b:.2f} pose +{f(v, 'pose_ms') - b:.2f} "
              f"cpu {f(v, 'cpu_ms'):.2f} streamed {v['streamed']} bytes {v['bytes']}")


if __name__ == "__main__":
    main()
