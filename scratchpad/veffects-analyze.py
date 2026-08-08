#!/usr/bin/env python3
"""Do Windows 11's desktop effects explain its extra presents?

Headline metric is the PRESENT COUNT - sum of QGAPERF `n` over each phase - not CPU. The
hypothesis is about how many frames Windows generates; CPU would confound that with how
expensive each frame is. Per-frame cost is printed alongside precisely so the two are not
conflated.

Reference point from the controlled Win10-vs-Win11 run (agent, display path and resolution
held constant): 259 frames on Windows 10 vs 488 on Windows 11 over 20 s, a 1.88x gap. If
effects account for it, `fast` should move the Windows 11 count a meaningful way toward 259.

The QGAPERF parser is imported from instrumentation/analyze-perf.py so the format cannot
drift. The guest is untrusted; its output is parsed as data only.
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
WIN10_REF, WIN11_REF, REF_SECS = 259, 488, 20.0


def phase_bounds(path):
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


def secs(ts):
    t = ts.split(".")
    return int(t[1][0:2]) * 3600 + int(t[1][2:4]) * 60 + int(t[1][4:6]) + int(t[2]) / 1000.0


def phase_stats(perf, bounds, phase):
    if phase not in bounds or not os.path.isfile(perf):
        return None
    since, until = bounds[phase]
    frames, _, _ = _ap.parse([perf])
    recs = [r for r in frames if since <= r["ts"] <= until]
    n = sum(r.get("n", 0) for r in recs)
    if n < 1:
        return None
    dur = secs(until) - secs(since)
    return {
        "frames": n,
        "fps": (n / dur) if dur > 0 else None,
        "tot_us": sum(r.get("tot", 0) for r in recs) / n,
        "area": sum(r.get("area", 0) for r in recs) / n,
        # skip = frames that arrived with NO dirty rects and were dropped (g_SkippedFrames).
        # This separates two causes of a high present count that would otherwise look alike:
        # cursor-only/empty presents show up here, real content repaints do not.
        "skip": sum(r.get("skip", 0) for r in recs),
        "dr": sum(r.get("dr", 0) for r in recs) / n,
        "dur": dur,
    }


def load(outdir):
    if not os.path.isdir(outdir):
        print(f"no such directory: {outdir}", file=sys.stderr)
        sys.exit(2)
    pts = []
    for name in sorted(os.listdir(outdir)):
        d = os.path.join(outdir, name)
        pj = os.path.join(d, "point.json")
        if not os.path.isfile(pj):
            continue
        try:
            p = json.load(open(pj))
        except Exception:
            continue
        if p.get("valid"):
            b = phase_bounds(os.path.join(d, "phases.txt"))
            p["phases"] = {ph: phase_stats(os.path.join(d, "perf.txt"), b, ph) for ph in PHASES}
        pts.append(p)
    return pts


def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return statistics.median(vals) if vals else None


def spread(vals):
    vals = [v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if len(vals) < 2:
        return 0.0
    m = statistics.median(vals)
    return ((max(vals) - min(vals)) / m) if m else 0.0


outdir = sys.argv[1] if len(sys.argv) > 1 else "."
pts = load(outdir)
good = [p for p in pts if p.get("valid")]
bad = [p for p in pts if not p.get("valid")]

print("=" * 84)
print("WINDOWS 11 DESKTOP EFFECTS vs PRESENT COUNT")
print("=" * 84)
print(f"  {len(good)} valid point(s), {len(bad)} failed")
for p in bad:
    print(f"    FAILED {p.get('cond')} rep{p.get('rep')}: {p.get('na', 'no records')}")
if not good:
    print("\nNo usable data. Missing data fails - no verdict.")
    sys.exit(1)

conds = [c for c in ("default", "fast") if any(p["cond"] == c for p in good)]
by = {c: [p for p in good if p["cond"] == c] for c in conds}

for phase in PHASES:
    rows = []
    for c in conds:
        ss = [p["phases"].get(phase) for p in by[c]]
        ss = [s for s in ss if s]
        if not ss:
            continue
        rows.append((c, len(ss), med([s["frames"] for s in ss]), med([s["fps"] for s in ss]),
                     med([s["tot_us"] for s in ss]), med([s["area"] for s in ss]),
                     spread([s["frames"] for s in ss]),
                     med([s["skip"] for s in ss]), med([s["dr"] for s in ss])))
    if not rows:
        continue
    print(f"\n-- {phase} --")
    print(f"{'effects':<12}{'reps':>6}{'frames':>9}{'fps':>8}{'empty':>8}{'dr/frame':>10}"
          f"{'tot us':>9}{'area px':>11}{'spread':>8}")
    print("-" * 84)
    for c, n, fr, fps, tot, area, sp, sk, dr in rows:
        f_fr = f"{fr:.0f}" if isinstance(fr, (int, float)) else "-"
        f_fps = f"{fps:.1f}" if isinstance(fps, (int, float)) else "-"
        f_tot = f"{tot:.0f}" if isinstance(tot, (int, float)) else "-"
        f_area = f"{area:.0f}" if isinstance(area, (int, float)) else "-"
        f_sk = f"{sk:.0f}" if isinstance(sk, (int, float)) else "-"
        f_dr = f"{dr:.2f}" if isinstance(dr, (int, float)) else "-"
        print(f"{c:<12}{n:>6}{f_fr:>9}{f_fps:>8}{f_sk:>8}{f_dr:>10}"
              f"{f_tot:>9}{f_area:>11}{sp*100:>7.0f}%")

    areas = [r[5] for r in rows if r[5]]
    if len(areas) >= 2 and min(areas) > 0 and max(areas) / min(areas) > 1.5:
        print("  !! damaged area differs across conditions - the workload was not held constant,")
        print("     so a frame-count difference cannot be attributed to the effects setting.")

print("\n-- verdict --")
if len(conds) < 2:
    print("   Only one condition has data - no A/B comparison possible.")
    sys.exit(0)

for phase in PHASES:
    a = [p["phases"].get(phase) for p in by["default"]]
    b = [p["phases"].get(phase) for p in by["fast"]]
    a, b = [s for s in a if s], [s for s in b if s]
    if not a or not b:
        continue
    lo, hi = med([s["frames"] for s in a]), med([s["frames"] for s in b])
    noise = max(spread([s["frames"] for s in a]), spread([s["frames"] for s in b]))
    if not lo:
        continue
    ratio = hi / lo
    verdict = ("effects account for presents" if ratio < 1 - max(0.10, 2 * noise)
               else "more presents with effects off" if ratio > 1 + max(0.10, 2 * noise)
               else "no material change")
    print(f"   {phase:<8}default {lo:6.0f}  ->  fast {hi:6.0f}   x{ratio:5.2f}"
          f"   (noise {noise*100:.0f}%)   {verdict}")

print()
print(f"   Reference, controlled Win10 vs Win11 over {REF_SECS:.0f} s: {WIN10_REF} vs {WIN11_REF}")
print(f"   frames (x{WIN11_REF/WIN10_REF:.2f}). Effects explain the gap only if 'fast' moves the")
print("   Windows 11 count a meaningful way toward the Windows 10 one.")
print()
print("   A nil result is a result: it rules out the cheapest explanation and points the")
print("   chase at DWM's composition cadence itself rather than at user-visible effects.")
print()
print("   READ 'empty' BEFORE CONCLUDING. It counts frames that arrived with no dirty rects")
print("   and were dropped. If the surplus presents were cursor-only they would land there")
print("   and already cost almost nothing - so a HIGH empty count means the frame total")
print("   overstates the real work and effects are not the story. The controlled run showed")
print("   dr=1 on the extra frames, i.e. real content repaints, which is what makes the")
print("   effects hypothesis worth testing at all.")
