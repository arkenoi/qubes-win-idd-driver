#!/usr/bin/env python3
"""Idle present rate: is the Windows 11 surplus ambient or workload-driven?

Reports frames per second with NO input at all. Run on both guests and compare:

  both near zero            -> the surplus is WORKLOAD-DRIVEN. Windows 11 repaints more per
                               unit of input. Shell/background tweaks are a dead end; the
                               chase belongs in DWM's composition behaviour.
  Win11 materially higher   -> the surplus is AMBIENT. Something repaints with nobody
                               touching the machine, and the 20 s workload measurement simply
                               contained that background rate. The target is then whatever
                               that something is, on the post-install tweak path.

`empty` matters as much as `frames`: frames arriving with no dirty rects are counted and
dropped by the agent already (g_SkippedFrames -> QGAPERF `skip`), so an idle rate made of
empty frames is not the same finding as one made of real repaints.

Parser imported from instrumentation/analyze-perf.py so the record format cannot drift. The
guest is untrusted; output is parsed as data only.
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

WORKLOAD_REF = {"win10": (259, 20.0), "win11": (488, 20.0)}


def bounds(path, phase="idle-pre"):
    lo = hi = None
    if not os.path.isfile(path):
        return None
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.split()
        if len(f) < 3 or f[1] != phase:
            continue
        if f[0] == "PHASE-START":
            lo = f[-1]
        elif f[0] == "PHASE-END":
            hi = f[-1]
    return (lo, hi) if lo and hi else None


def secs(ts):
    t = ts.split(".")
    return int(t[1][0:2]) * 3600 + int(t[1][2:4]) * 60 + int(t[1][4:6]) + int(t[2]) / 1000.0


outdir = sys.argv[1] if len(sys.argv) > 1 else "."
label = sys.argv[2] if len(sys.argv) > 2 else "?"

rows = []
failed = []
for name in sorted(os.listdir(outdir)):
    d = os.path.join(outdir, name)
    pj = os.path.join(d, "point.json")
    if not os.path.isfile(pj):
        continue
    p = json.load(open(pj))
    if not p.get("valid"):
        failed.append(p)
        continue
    b = bounds(os.path.join(d, "phases.txt"))
    if not b:
        failed.append({"rep": p.get("rep"), "na": "no idle-pre bounds"})
        continue
    frames, _, _ = _ap.parse([os.path.join(d, "perf.txt")])
    recs = [r for r in frames if b[0] <= r["ts"] <= b[1]]
    n = sum(r.get("n", 0) for r in recs)
    dur = secs(b[1]) - secs(b[0])
    rows.append({
        "rep": p.get("rep"),
        "frames": n,
        "dur": dur,
        "fps": (n / dur) if dur > 0 else 0.0,
        "empty": sum(r.get("skip", 0) for r in recs),
        "area": (sum(r.get("area", 0) for r in recs) / n) if n else 0,
    })

print("=" * 72)
print(f"IDLE PRESENT RATE - {label} (no input at all)")
print("=" * 72)
for f in failed:
    print(f"  FAILED rep{f.get('rep')}: {f.get('na', 'no records')}")
if not rows:
    print("\nNo usable data. Missing data fails - no verdict.")
    sys.exit(1)

print(f"{'rep':>4}{'secs':>8}{'frames':>9}{'fps':>8}{'empty':>8}{'area px':>11}")
print("-" * 72)
for r in rows:
    print(f"{r['rep']:>4}{r['dur']:>8.1f}{r['frames']:>9}{r['fps']:>8.2f}"
          f"{r['empty']:>8}{r['area']:>11.0f}")

fps = statistics.median([r["fps"] for r in rows])
empty = statistics.median([r["empty"] for r in rows])
print(f"\n  median idle rate: {fps:.2f} fps   (median empty frames: {empty:.0f})")

print("\n-- how to read this --")
for k, (fr, sec) in WORKLOAD_REF.items():
    print(f"   {k} workload reference: {fr} frames / {sec:.0f} s = {fr/sec:.1f} fps under input")
print(f"   this guest, idle:      {fps:.2f} fps")
if fps > 1.0:
    share = {k: (fps / (fr / sec)) for k, (fr, sec) in WORKLOAD_REF.items()}
    print("\n   Idle is NOT quiet. As a share of the workload rate that would be:")
    for k, v in share.items():
        print(f"     {v*100:5.1f}% of the {k} workload rate")
    print("   An ambient rate this high means the workload numbers partly measure background")
    print("   repaint, and the target is whatever produces it - not the input path.")
else:
    print("\n   Idle is quiet on this guest: the surplus is workload-driven here, so shell and")
    print("   background tweaks cannot be the fix. Compare against the other guest before")
    print("   concluding - one side alone settles nothing.")
if empty and empty > 0:
    print(f"\n   NOTE {empty:.0f} idle frames arrived with no dirty rects and were dropped. Those")
    print("   already cost almost nothing, so they must not be counted as overhead to remove.")
