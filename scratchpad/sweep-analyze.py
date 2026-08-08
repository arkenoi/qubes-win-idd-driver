#!/usr/bin/env python3
"""Desktop-size sweep: does guest cost scale with DESKTOP AREA?

Reads the point directories written by desktop-size-sweep.sh and answers the kill-first
question in DESIGN-nonoccluding-desktop.md - whether the non-occluding ("RDP-like") tiling
design's larger desktop would cost anything at a constant workload.

The QGAPERF parser is IMPORTED from instrumentation/analyze-perf.py rather than
reimplemented, so the record format cannot drift between the two.

BUILT-IN VALIDITY GATE. The harness keeps a fixed 800x600 window and a fixed drag radius, so
damaged area per frame must be CONSTANT across the sweep. The `area` column below is that
check: if it tracks desktop size, the workload changed with resolution and no scaling verdict
may be read from this run. The guest is untrusted; everything here is parsed as data.
"""
import importlib.util
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "analyze_perf", os.path.join(HERE, "..", "instrumentation", "analyze-perf.py"))
_ap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ap)

PHASES = ("drag", "scroll", "type")


def phase_bounds(path):
    """PHASE-START/PHASE-END markers -> {phase: (since, until)}. Timestamps are
    YYYYMMDD.HHMMSS.mmm, so lexicographic comparison is chronological."""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.split()
        if len(f) < 3:
            continue
        kind, name, ts = f[0], f[1], f[-1]
        if kind == "PHASE-START":
            out.setdefault(name, [None, None])[0] = ts
        elif kind == "PHASE-END":
            out.setdefault(name, [None, None])[1] = ts
    return {k: tuple(v) for k, v in out.items() if v[0] and v[1]}


def phase_stats(perf, bounds, phase):
    """Aggregate QGAPERF records inside one phase. Time fields are microsecond SUMS over
    `n` frames, so per-frame values divide by the summed n."""
    if phase not in bounds or not os.path.isfile(perf):
        return None
    since, until = bounds[phase]
    frames, _, _ = _ap.parse([perf])
    recs = [r for r in frames if since <= r["ts"] <= until]
    n = sum(r.get("n", 0) for r in recs)
    if n < 1:
        return None

    def per_frame(field):
        return sum(r.get(field, 0) for r in recs) / n

    # phase duration from the markers: HHMMSS.mmm within the same day
    def secs(ts):
        t = ts.split(".")
        return int(t[1][0:2]) * 3600 + int(t[1][2:4]) * 60 + int(t[1][4:6]) + int(t[2]) / 1000.0
    dur = secs(until) - secs(since)
    return {
        "frames": n,
        "fps": (n / dur) if dur > 0 else None,
        "acq_us": per_frame("acq"),
        "tot_us": per_frame("tot"),
        "snd_us": per_frame("snd"),
        "area": per_frame("area"),
    }


def load(outdir):
    pts = []
    if not os.path.isdir(outdir):
        print(f"no such sweep directory: {outdir}", file=sys.stderr)
        sys.exit(2)
    for name in sorted(os.listdir(outdir)):
        d = os.path.join(outdir, name)
        pj = os.path.join(d, "point.json")
        if not os.path.isfile(pj):
            continue
        try:
            p = json.load(open(pj))
        except Exception:
            continue
        if not p.get("valid"):
            pts.append(p)
            continue
        b = phase_bounds(os.path.join(d, "phases.txt"))
        p["phases"] = {ph: phase_stats(os.path.join(d, "perf.txt"), b, ph) for ph in PHASES}
        pts.append(p)
    return pts


def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return statistics.median(vals) if vals else None


def spread(vals):
    """max-min as a fraction of the median - the within-mode noise floor a cross-mode
    difference has to clear before it means anything."""
    vals = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if len(vals) < 2:
        return None
    m = statistics.median(vals)
    return (max(vals) - min(vals)) / m if m else None


def fmt(v, d=1):
    return f"{v:.{d}f}" if isinstance(v, float) else ("-" if v is None else str(v))


outdir = sys.argv[1] if len(sys.argv) > 1 else "."
pts = load(outdir)
good = [p for p in pts if p.get("valid")]
bad = [p for p in pts if not p.get("valid")]

print("=" * 92)
print("DESKTOP-SIZE SWEEP - does cost scale with desktop area?")
print("=" * 92)
print(f"  {len(good)} valid point(s), {len(bad)} failed")
for p in bad:
    print(f"    FAILED {p.get('mode')} rep{p.get('rep')}: {p.get('na', 'no QGAPERF records')}")
if not good:
    print("\nNo usable data. Missing data fails - no verdict is produced.")
    sys.exit(1)

modes = sorted({p["mode"] for p in good}, key=lambda m: int(m.split("x")[0]) * int(m.split("x")[1]))
by_mode = {m: [p for p in good if p["mode"] == m] for m in modes}

for phase in PHASES:
    rows = []
    for m in modes:
        ps = [p["phases"].get(phase) for p in by_mode[m]]
        ps = [x for x in ps if x]
        if not ps:
            continue
        rows.append((m, by_mode[m][0]["pixels"], len(ps),
                     med([x["fps"] for x in ps]), med([x["acq_us"] for x in ps]),
                     med([x["tot_us"] for x in ps]), med([x["area"] for x in ps]),
                     spread([x["tot_us"] for x in ps])))
    if not rows:
        continue
    print(f"\n-- {phase} --")
    print(f"{'mode':<12}{'Mpx':>7}{'reps':>6}{'fps':>8}{'acq us':>10}{'tot us':>10}{'area px':>11}{'tot spread':>12}")
    print("-" * 92)
    for m, px, n, fps, acq, tot, area, sp in rows:
        print(f"{m:<12}{px/1e6:>7.2f}{n:>6}{fmt(fps,1):>8}{fmt(acq,1):>10}{fmt(tot,1):>10}"
              f"{fmt(area,0):>11}{(fmt(sp*100,0)+'%') if sp is not None else '-':>12}")

    # validity gate: damaged area must NOT track desktop size
    areas = [r[6] for r in rows if r[6]]
    if len(areas) >= 2 and min(areas) > 0 and max(areas) / min(areas) > 1.5:
        print("  !! INVALID: damaged area tracks desktop size, so the workload was not held")
        print("     constant. No scaling verdict may be read from this phase.")

print("\n-- aggregate agent CPU over the whole measured run --")
print(f"{'mode':<12}{'Mpx':>7}{'cpu ms (median)':>18}{'spread':>10}")
print("-" * 92)
cpu_by_mode = {}
for m in modes:
    vals = [p.get("cpu_ms") for p in by_mode[m]]
    cpu_by_mode[m] = med(vals)
    print(f"{m:<12}{by_mode[m][0]['pixels']/1e6:>7.2f}{fmt(cpu_by_mode[m],0):>18}"
          f"{(fmt((spread(vals) or 0)*100,0)+'%'):>10}")

# --------------------------------------------------------------------- verdict --
print("\n-- verdict --")
sm, lg = modes[0], modes[-1]
px_ratio = by_mode[lg][0]["pixels"] / by_mode[sm][0]["pixels"]
print(f"   desktop area spans {px_ratio:.1f}x  ({sm} -> {lg})")

any_scaling = False
for phase in PHASES:
    a = [p["phases"].get(phase) for p in by_mode[sm]]
    b = [p["phases"].get(phase) for p in by_mode[lg]]
    a, b = [x for x in a if x], [x for x in b if x]
    if not a or not b:
        continue
    for field, name in (("acq_us", "acq"), ("tot_us", "tot"), ("fps", "fps")):
        lo, hi = med([x[field] for x in a]), med([x[field] for x in b])
        if not lo or not hi:
            continue
        ratio = hi / lo
        noise = max(spread([x[field] for x in a]) or 0, spread([x[field] for x in b]) or 0)
        verdict = "SCALES" if abs(ratio - 1) > max(0.25, 2 * noise) else "flat"
        if verdict == "SCALES":
            any_scaling = True
        print(f"   {phase:<7}{name:<5}{lo:9.1f} -> {hi:9.1f}   x{ratio:5.2f}"
              f"   (noise {noise*100:.0f}%)   {verdict}")

lo, hi = cpu_by_mode.get(sm), cpu_by_mode.get(lg)
if lo and hi:
    print(f"   {'cpu':<7}{'ms':<5}{lo:9.0f} -> {hi:9.0f}   x{hi/lo:5.2f}")
    if abs(hi / lo - 1) > 0.25:
        any_scaling = True

print()
if any_scaling:
    print("   => Cost DOES move with desktop area at a constant workload.")
    print("      Single-giant-desktop tiling is not viable as sketched; the non-occluding")
    print("      idea survives only in the multi-monitor form, or not at all.")
else:
    print("   => Cost is FLAT in desktop area at a constant workload.")
    print("      The allocation objection is bounded on CPU. Memory and grant-count still")
    print("      scale linearly by construction and are NOT tested here - experiment 3.")
