#!/usr/bin/env python3
"""Three-way Windows 11 comparison that separates the agent from the display path.

The four-row matrix could not attribute the Windows 11 CPU result, because its two Win11
rows differ in BOTH variables:

    stock win11  =  stock agent  +  Basic Display Adapter
    ours  win11  =  our agent    +  IddCx

This adds the third point - our agent on the BDA - so the two effects separate:

    ours-BDA close to stock      -> the cost is the IddCx display path
    ours-BDA still elevated      -> the cost is our agent on Windows 11
    ours-BDA between the two     -> both contribute; report both, claim neither alone

Usage: win11-compare.py <bm-win11-dir> <bm-win11-bda-dir>
"""
import json, os, statistics, sys

METRICS = [
    ("idle_cpu_pct",   "idle gui-agent CPU",  "%of1core", 3),
    ("drag_cpu_pct",   "CPU during drag",     "%of1core", 3),
    ("scroll_cpu_pct", "CPU during scroll",   "%of1core", 3),
    ("type_cpu_pct",   "CPU during typing",   "%of1core", 3),
    ("idle_ws_mb",     "idle working set",    "MB",       1),
    ("drag_ws_mb",     "peak working set",    "MB",       1),
]

def load(outdir, side):
    reps = []
    if not os.path.isdir(outdir):
        return reps
    for name in sorted(os.listdir(outdir)):
        if not name.startswith(side + "-r"):
            continue
        f = os.path.join(outdir, name, "rep.json")
        if os.path.isfile(f):
            try:
                d = json.load(open(f))
            except Exception:
                continue
            if d.get("valid"):
                reps.append(d)
    return reps

def med(reps, key):
    vals, na = [], None
    for d in reps:
        m = d.get("metrics", {}).get(key)
        if not m:
            continue
        if "na" in m:
            na = m["na"]; continue
        v = m.get("value")
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            vals.append(float(v))
    return statistics.median(vals) if vals else (na or "no data")

def fmt(v, d):
    return f"{v:.{d}f}" if isinstance(v, float) else "n/a"

idd_dir, bda_dir = sys.argv[1], sys.argv[2]
cols = [
    ("stock win11 (BDA)",   load(idd_dir, "stock")),
    ("ours win11 (IddCx)",  load(idd_dir, "ours")),
    ("ours win11 (BDA)",    load(bda_dir, "ours")),
]

print("=" * 84)
print("WINDOWS 11: separating the agent from the display path")
print("=" * 84)
for name, reps in cols:
    print(f"  {name:<22} {len(reps)} valid rep(s)")
print()
print(f"{'metric':<22}{'unit':<10}" + "".join(f"{n:>20}" for n, _ in cols))
print("-" * 84)
for key, title, unit, digits in METRICS:
    cells = [med(reps, key) for _, reps in cols]
    print(f"{title:<22}{unit:<10}" + "".join(f"{fmt(c, digits):>20}" for c in cells))

print()
print("-- interpretation --")
stock, idd, bda = (med(c[1], "drag_cpu_pct") for c in cols)
if all(isinstance(x, float) for x in (stock, idd, bda)):
    # Attribute only what the numbers support; if the third point does not separate them,
    # say so rather than picking the tidier story.
    d_display = idd - bda      # IddCx cost, holding the agent constant
    d_agent   = bda - stock    # our agent's cost, holding the display constant
    print(f"  drag CPU: stock={stock:.3f}  ours+BDA={bda:.3f}  ours+IddCx={idd:.3f}")
    print(f"  attributable to the IddCx path (ours: IddCx - BDA) : {d_display:+.3f}")
    print(f"  attributable to our agent      (ours BDA - stock)  : {d_agent:+.3f}")
    if abs(d_display) > abs(d_agent) * 2:
        print("  -> dominated by the DISPLAY PATH, not the agent.")
    elif abs(d_agent) > abs(d_display) * 2:
        print("  -> dominated by the AGENT, not the display path.")
    else:
        print("  -> BOTH contribute materially; neither explains it alone.")
else:
    print("  insufficient data to attribute - reporting no conclusion.")
