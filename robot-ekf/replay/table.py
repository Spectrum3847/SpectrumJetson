#!/usr/bin/env python3
"""Markdown tables from batch.sh's replay.csv (TxmanReplay --csv): pooled per variant, then per match.

    python table.py DATA/results/replay.csv
"""

import csv
import sys

# (calibration, variant, short name) for the per-match table
MAIN = [
    ("deployed", "fit-newest", "robot before aeca58c, deployed cal"),
    ("refit", "fit-newest", "-refit"),
    ("refit", "fit", "-refit + mount at capture"),
    ("refit", "napa", "same, fit off"),
]


# pooled rows shown, in this order of variants per calibration
WANT = ("fit-newest", "napa-newest", "fit", "napa", "a-corners-8.0px", "c-bearing-0.1",
        "e-bearing-0.35-at-capture", "e-bearing-0.5-at-capture")


def order(match):
    return (match == "pooled", match[0], int(match[1:]) if match[1:].isdigit() else 0)


def main():
    rows = list(csv.DictReader(open(sys.argv[1], newline="")))
    by = {(r["cal"], r["variant"], r["match"]): r for r in rows}

    print("Pooled over every match (held-out and MT1 percentiles over all samples, NIS a mean, lost % of MT1")
    print("samples, relocalizations summed):\n")
    print("| calibration | variant | held-out p50 / p90 m | NIS | MT1 p50 / p90 m | lost % | heading deg | relocalizations |")
    print("|---|---|---|---|---|---|---|---|")
    for r in sorted(rows, key=lambda r: (r["cal"], WANT.index(r["variant"]) if r["variant"] in WANT else 99)):
        if r["match"] != "pooled" or r["variant"] not in WANT:
            continue
        print(
            f"| {r['cal']} | `{r['variant']}` | {float(r['ho_p50_m']):.3f} / {float(r['ho_p90_m']):.3f} "
            f"| {float(r['nis']):.2f} | {float(r['mt1_p50_m']):.3f} / {float(r['mt1_p90_m']):.3f} "
            f"| {float(r['lost_pct']):.1f} | {float(r['heading_deg']):.1f} | {r['relocalizations']} |"
        )

    matches = sorted({r["match"] for r in rows if r["cal"] in ("deployed", "refit")}, key=order)
    print("\nPer match: held-out p50 / p90 m, NIS, heading deg, lost %, relocalizations.\n")
    print("| match | held-out tags | " + " | ".join(name for _, _, name in MAIN) + " |")
    print("|---|---|" + "---|" * len(MAIN))
    for m in matches:
        cells = []
        n = ""
        for cal, var, _ in MAIN:
            r = by.get((cal, var, m))
            if r is None:
                cells.append("")
                continue
            n = r["held_out_tags"]
            cells.append(
                f"{float(r['ho_p50_m']):.3f} / {float(r['ho_p90_m']):.3f}, {float(r['nis']):.2f}, "
                f"{float(r['heading_deg']):.1f}deg, {float(r['lost_pct']):.1f}%, {r['relocalizations']}"
            )
        label = f"**{m}**" if m == "pooled" else m
        print(f"| {label} | {n} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
