#!/usr/bin/env python3
"""Render a stock-vs-ours run directory as the markdown table docs/BENCHMARKS.md carries.

Pools the two 5-second idle windows (idle-pre, idle-post) into one `idle` row so the output
lines up with the historical table's four workloads. The 2-second idle-mid windows are
deliberately NOT pooled in: at 250 ms sampling they carry ~7 samples each, which is under the
threshold where the rate means anything, and averaging them in would launder that.

Verdict rule is the summariser's: REAL only when the two sides' ranges are disjoint, otherwise
"inside noise" with the spread shown. Nothing here invents a verdict the data does not carry.
"""
import glob
import json
import os
import statistics
import sys

POOLED = {"idle": ["idle-pre", "idle-post"],
          "drag": ["drag"], "scroll": ["scroll"], "typing": ["type"]}


def main(outdir):
    runs = []
    for path in sorted(glob.glob(os.path.join(outdir, "r*-*.json"))):
        o = json.load(open(path))
        if not o.get("valid"):
            continue
        side = "ours" if path.endswith("-ours.json") else "stock"
        runs.append((side, o))

    print(f"| workload | stock 4.2.2 | ours | delta | verdict |")
    print(f"|---|---:|---:|---:|---|")
    detail = {}
    for label, phases in POOLED.items():
        vals = {"stock": [], "ours": []}
        for side, o in runs:
            got = [o["phases"][p]["pct_core"] for p in phases
                   if p in o.get("phases", {}) and o["phases"][p].get("pct_core") is not None]
            if len(got) == len(phases):
                vals[side].append(statistics.mean(got))
        st, ou = sorted(vals["stock"]), sorted(vals["ours"])
        if len(st) < 2 or len(ou) < 2:
            print(f"| {label} | n/a | n/a | | too few valid repetitions — NO VERDICT |")
            continue
        ms, mo = statistics.median(st), statistics.median(ou)
        disjoint = (max(st) < min(ou)) or (max(ou) < min(st))
        spread = max((max(st) - min(st)) / ms * 100 if ms else 0,
                     (max(ou) - min(ou)) / mo * 100 if mo else 0)
        delta = (mo - ms) / ms * 100 if ms else float("nan")
        verdict = (("**REAL** — ranges disjoint, ours " + ("worse" if mo > ms else "better"))
                   if disjoint else f"inside noise (spread {spread:.0f}%) — no verdict")
        print(f"| {label} | {ms:.3f} | {mo:.3f} | {delta:+.1f}% | {verdict} |")
        detail[label] = {"stock": [round(x, 3) for x in st], "ours": [round(x, 3) for x in ou]}

    print("\nper-repetition values (% of one core), medians above are of these:\n")
    print("```")
    for label, d in detail.items():
        print(f"{label:8s} stock {d['stock']}")
        print(f"{label:8s} ours  {d['ours']}")
    print("```")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
