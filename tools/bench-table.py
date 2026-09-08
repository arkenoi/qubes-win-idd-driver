#!/usr/bin/env python3
"""Render a stock-vs-ours run directory as the markdown table docs/BENCHMARKS.md carries.

The two 5-second idle windows are reported as SEPARATE rows, because they measure different
things and averaging them produced a misleading `idle` figure (the one the README quoted):

  idle-establish (harness phase `idle-pre`)  starts 700 ms after Notepad is created, moved
      and focused (instrumentation/drag-harness.ps1, the block before `Phase 'idle-pre'`). It
      measures WINDOW-ESTABLISHMENT cost: registering the window with the broker and delivering
      its first frames. That is higher on the per-window path by design, not idle burn.
  idle-settled   (harness phase `idle-post`)  starts 5 s after the last input with no new
      window: the true settled-idle cost, which is what "idle" is taken to mean.

The 2-second idle-mid windows are still not reported: at 250 ms sampling they carry ~7 samples
each, under the threshold where the rate means anything.

QUANTISATION. `pct_core` comes from `Get-Process .CPU` (bench-phase-cpu.py), a counter that
advances in 15.625 ms clock ticks; over the ~4.75 s of sampled wall inside a 5 s window one
tick is ~0.33 % of a core, so every idle value is a small integer multiple of ~0.33. Percentage
deltas between such values are not meaningful: the 2026-09-08 run read stock 0.328 vs ours
0.943 on idle-pre, which the disjoint-ranges rule would have printed as "+187.5 % REAL" - it
is 1 tick vs 2-3 ticks. Rows whose medians differ by fewer than MIN_TICKS_FOR_VERDICT ticks
therefore get no percentage and no verdict; the difference is printed in ticks instead.

Verdict rule is otherwise the summariser's: REAL only when the two sides' ranges are disjoint,
otherwise "inside noise" with the spread shown. Nothing here invents a verdict the data does
not carry.
"""
import glob
import json
import os
import statistics
import sys

# table label -> harness phase name. Order is the reading order of the table.
ROWS = {"idle-establish": "idle-pre",
        "idle-settled": "idle-post",
        "drag": "drag", "scroll": "scroll", "typing": "type"}

# One 15.625 ms CPU-time tick over ~4.75 s of sampled wall (19 samples at 250 ms). Measured
# values sit at 0.325-0.333 per tick across every run in instrumentation/bench-stock-vs-ours-*.
# Calibrated on the 5 s idle windows; the 10 s drag/scroll/type phases have a ~0.16 % tick, so
# there the guard is conservative (3 "ticks" here = ~6 real ones), never permissive.
TICK_PCT = 0.33
# With 3 repetitions, one tick of jitter on each side already separates the medians by 2
# ticks (stock 1,1,1 vs ours 2,3,3 is the real 2026-09-08 case), so under 3 ticks nothing is
# resolved.
MIN_TICKS_FOR_VERDICT = 3


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
    for label, phase in ROWS.items():
        vals = {"stock": [], "ours": []}
        for side, o in runs:
            v = o.get("phases", {}).get(phase, {}).get("pct_core")
            if v is not None:
                vals[side].append(v)
        st, ou = sorted(vals["stock"]), sorted(vals["ours"])
        if len(st) < 2 or len(ou) < 2:
            print(f"| {label} | n/a | n/a | | too few valid repetitions — NO VERDICT |")
            continue
        ms, mo = statistics.median(st), statistics.median(ou)
        detail[label] = {"stock": [round(x, 3) for x in st], "ours": [round(x, 3) for x in ou]}
        # See bench-summarise.py: an all-zero side is the CPU counter failing to resolve the
        # rate over a short quiet phase, not a measurement of no CPU. No verdict from it.
        if max(st) == 0 or max(ou) == 0:
            print(f"| {label} | {ms:.3f} | {mo:.3f} | | one side read 0.000 every repetition "
                  f"— below counter resolution, no verdict |")
            continue
        # Medians a couple of ticks apart: the counter's quantisation, not the build. A
        # percentage of 1 tick is meaningless, and "ranges disjoint" is satisfied by jitter.
        ticks = (mo - ms) / TICK_PCT
        if abs(ticks) < MIN_TICKS_FOR_VERDICT:
            print(f"| {label} | {ms:.3f} | {mo:.3f} | {ticks:+.1f} ticks | within counter "
                  f"quantisation (~{TICK_PCT} %/tick, < {MIN_TICKS_FOR_VERDICT} ticks apart) "
                  f"— no verdict |")
            continue
        disjoint = (max(st) < min(ou)) or (max(ou) < min(st))
        spread = max((max(st) - min(st)) / ms * 100 if ms else 0,
                     (max(ou) - min(ou)) / mo * 100 if mo else 0)
        delta = (mo - ms) / ms * 100 if ms else float("nan")
        verdict = (("**REAL** — ranges disjoint, ours " + ("worse" if mo > ms else "better"))
                   if disjoint else f"inside noise (spread {spread:.0f}%) — no verdict")
        print(f"| {label} | {ms:.3f} | {mo:.3f} | {delta:+.1f}% | {verdict} |")

    print("\nper-repetition values (% of one core), medians above are of these:\n")
    print("```")
    for label, d in detail.items():
        print(f"{label:14s} stock {d['stock']}")
        print(f"{label:14s} ours  {d['ours']}")
    print("```")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
