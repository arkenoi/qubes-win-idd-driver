#!/usr/bin/env python3
"""Assemble the four-row benchmark table from per-rep rep.json files.

NO dom0 SCREENSHOT METRICS. Sampling dom0 is the slowest element in the whole path
(~5 s per full-desktop capture, and the per-window service is gated to a name list that
does not cover these guests), so it cannot resolve frame rate at all. Worse, a full-desktop
sampler reports ~100% changed frames on every side because the dom0 desktop itself changes
- two consecutive STATIC captures already produced different hashes. Frame rate is measured
IN-GUEST instead, where it needs no round-trip.

Reports MEDIANS across valid reps, and ONLY the metrics that both stock and our build can
actually produce. Every QGAPERF-derived figure is ours-only by construction - stock QWT 4.2.2
emits no per-frame instrumentation - so those are shown in a separate section and never as a
cross-side delta.

Refuses to invent data:
  * a rep whose hash was not verified is not counted;
  * a metric carrying an "na" is reported as n/a, never as 0;
  * a cell with fewer than MINREPS valid reps is flagged and its numbers marked provisional.
"""
import json, os, sys, statistics

MINREPS = int(os.environ.get("MINREPS", "3"))

CROSS = [
    ("idle_cpu_pct",       "idle gui-agent CPU (60s)",   "%of1core", 3),
    ("drag_cpu_pct",       "CPU during drag",            "%of1core", 3),
    ("scroll_cpu_pct",     "CPU during scroll",          "%of1core", 3),
    ("type_cpu_pct",       "CPU during typing",          "%of1core", 3),
    ("idle_ws_mb",         "idle working set",           "MB",       1),
    ("drag_ws_mb",         "peak working set (drag)",    "MB",       1),
    ("vm_cpu_idle",        "whole-VM CPU (idle)",        "vcpu-s/s", 3),
    ("vm_cpu_work",        "whole-VM CPU (workload)",    "vcpu-s/s", 3),
]
OURS_ONLY = [
    ("drag_tot_p50_us", "drag frame cost p50", "us", 0),
    ("drag_tot_p95_us", "drag frame cost p95", "us", 0),
    ("drag_fps",        "frames/s during drag", "fps", 1),
    ("drag_iwn",        "windows interrogated/frame", "", 1),
    ("drag_dr",         "dirty rects/frame", "", 1),
]

def load(outdir, side):
    reps = []
    if not os.path.isdir(outdir):
        return reps
    for name in sorted(os.listdir(outdir)):
        if not name.startswith(side + "-r"):
            continue
        f = os.path.join(outdir, name, "rep.json")
        if not os.path.isfile(f):
            continue
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if not d.get("valid", False):
            continue
        reps.append(d)
    return reps

def med_fps(outdir, side, mode):
    """Median rendered_fps across reps. In-guest measurement: no dom0 round-trip."""
    vals = []
    if not os.path.isdir(outdir):
        return "no data"
    for name in sorted(os.listdir(outdir)):
        if not name.startswith(side + "-r"):
            continue
        f = os.path.join(outdir, name, f"fps-{mode}.json")
        if not os.path.isfile(f):
            continue
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if "error" in d:
            return d["error"]
        v = d.get("rendered_fps")
        if isinstance(v, (int, float)):
            vals.append(float(v))
    return statistics.median(vals) if vals else "no data"

def med(reps, key):
    """Median of a metric, or a reason string. Never silently zero."""
    vals, na = [], None
    for d in reps:
        m = d.get("metrics", {}).get(key)
        if m is None:
            continue
        if "na" in m:
            na = m["na"]
            continue
        v = m.get("value")
        if v is None or isinstance(v, bool):
            continue
        try:
            vals.append(float(v))
        except (TypeError, ValueError):
            continue
    if vals:
        return statistics.median(vals)
    return na or "no data"

def fmt(v, digits):
    return f"{v:.{digits}f}" if isinstance(v, float) else "n/a"

ROWS = [
    ("stock  win10", sys.argv[1], "stock"),
    ("ours   win10", sys.argv[1], "ours"),
    ("stock  win11", sys.argv[2], "stock"),
    ("ours   win11", sys.argv[2], "ours"),
]

data, counts, hashes = {}, {}, {}
for label, outdir, side in ROWS:
    reps = load(outdir, side)
    data[label] = reps
    counts[label] = len(reps)
    hashes[label] = sorted({r.get("agent", {}).get("agent_hash", "?") for r in reps}) or ["?"]

print("=" * 96)
print("FOUR-ROW BENCHMARK MATRIX   medians across valid reps")
print("=" * 96)
print(f"{'row':<14}{'reps':>6}  agent")
for label, _, _ in ROWS:
    flag = "" if counts[label] >= MINREPS else f"  <-- FEWER THAN {MINREPS}: provisional"
    print(f"{label:<14}{counts[label]:>6}  {','.join(hashes[label])}{flag}")

print()
print("[CROSS-SIDE — comparable between stock and ours]")
print(f"{'metric':<30}{'unit':<10}" + "".join(f"{l:>16}" for l, _, _ in ROWS))
print("-" * 96)
for key, title, unit, digits in CROSS:
    cells = [med(data[l], key) for l, _, _ in ROWS]
    print(f"{title:<30}{unit:<10}" + "".join(f"{fmt(c, digits):>16}" for c in cells))
    for (l, _, _), c in zip(ROWS, cells):
        if isinstance(c, str):
            print(f"{'':<40}{l}: n/a — {c[:70]}")

# In-guest FPS: cross-side by construction (no QGAPERF, no dom0 sampling).
print()
print("[CROSS-SIDE — generic in-guest renderer, no instrumentation dependency]")
print(f"{'metric':<30}{'unit':<10}" + "".join(f"{l:>16}" for l, _, _ in ROWS))
print("-" * 96)
for mode, title in (("move", "rendered fps (moving rect)"), ("full", "rendered fps (full repaint)")):
    cells = [med_fps(outdir, side, mode) for _, outdir, side in ROWS]
    print(f"{title:<30}{'fps':<10}" + "".join(f"{fmt(c, 1):>16}" for c in cells))

print()
print("[OURS-ONLY — stock QWT emits no QGAPERF, so these are not comparisons]")
print(f"{'metric':<30}{'unit':<10}" + "".join(f"{l:>16}" for l, _, _ in ROWS))
print("-" * 96)
for key, title, unit, digits in OURS_ONLY:
    cells = [med(data[l], key) for l, _, _ in ROWS]
    print(f"{title:<30}{unit:<10}" + "".join(f"{fmt(c, digits):>16}" for c in cells))

print()
print("-- reading this table --")
print("  * medians across valid reps only; a rep is valid only if its agent hash was verified")
print("    against the build that cell is supposed to be running.")
print("  * n/a is a missing capability or missing data. It is never rendered as 0.")
print("  * OURS-ONLY rows exist only on instrumented builds; the stock columns there are")
print("    empty by construction, not because stock performed badly.")
short = [l for l, _, _ in ROWS if counts[l] < MINREPS]
if short:
    print()
    print(f"  VERDICT WITHHELD: {', '.join(short)} have fewer than {MINREPS} valid reps.")
