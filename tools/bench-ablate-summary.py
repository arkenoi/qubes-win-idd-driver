#!/usr/bin/env python3
"""Summarise an ablation run: drag CPU per configuration, against the `base` control.

A configuration is only reported as ACCOUNTING for cost when its range is disjoint from
base's - same rule as the stock comparison, for the same reason. Anything else is noise and
is printed as such, with the spread, so nobody reads a 2 % median shift as an explanation.
"""
import glob
import json
import os
import statistics
import sys


def main(outdir):
    vals, invalid = {}, []
    for path in sorted(glob.glob(os.path.join(outdir, "r*-*.json"))):
        tag = os.path.basename(path)[:-5]
        cfg = tag.split("-", 1)[1]
        o = json.load(open(path))
        if not o.get("valid"):
            invalid.append((tag, "; ".join(o.get("why", ["?"]))))
            continue
        d = o.get("phases", {}).get("drag", {}).get("pct_core")
        if d is not None:
            vals.setdefault(cfg, []).append(d)

    for t, why in invalid:
        print(f"INVALID {t}: {why}")
    if "base" not in vals or len(vals["base"]) < 2:
        print("no usable base control - NO ATTRIBUTION POSSIBLE")
        return 1

    base = sorted(vals["base"])
    bm = statistics.median(base)
    print(f"\n{'config':12s} {'drag %core (median)':>20s} {'n':>3s} {'vs base':>9s}  verdict")
    print(f"{'base':12s} {bm:20.3f} {len(base):3d} {'—':>9s}  control")
    for cfg in sorted(k for k in vals if k != "base"):
        v = sorted(vals[cfg])
        if len(v) < 2:
            print(f"{cfg:12s} {'n/a':>20s} {len(v):3d} {'':>9s}  too few valid repetitions")
            continue
        m = statistics.median(v)
        disjoint = (max(v) < min(base)) or (max(base) < min(v))
        spread = max((max(base) - min(base)) / bm * 100 if bm else 0,
                     (max(v) - min(v)) / m * 100 if m else 0)
        delta = (m - bm) / bm * 100 if bm else float("nan")
        if disjoint:
            verdict = ("ACCOUNTS for cost: turning it off is CHEAPER" if m < bm
                       else "turning it off is MORE expensive")
        else:
            verdict = f"inside noise (spread {spread:.0f}%) - explains nothing"
        print(f"{cfg:12s} {m:20.3f} {len(v):3d} {delta:+8.1f}%  {verdict}")

    print("\nper-repetition drag values:")
    for cfg in sorted(vals):
        print(f"  {cfg:12s} " + "  ".join(f"{x:.3f}" for x in sorted(vals[cfg])))
    json.dump({k: sorted(v) for k, v in vals.items()},
              open(os.path.join(outdir, "ablate.json"), "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
