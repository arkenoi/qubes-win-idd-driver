#!/usr/bin/env python3
"""Per-window fast-path hit rate, FocusRaise off vs on.

    hit rate = pwskip / (pwskip + pwcap)

pwskip = per-window recaptures avoided because the window's screen bytes were provably
unchanged; pwcap = recaptures issued. Both from the QGAPERF record (PERF_RECORD_VERSION 3).

The QGAPERF parser is imported from instrumentation/analyze-perf.py so the record format
cannot drift. The guest is untrusted: its output is parsed as data only.

MISSING DATA FAILS. If a run carries no pwskip/pwcap fields the build predates the counters
and no rate exists - that is reported as missing, never as a zero, because a zero here would
read as "the fast path never fired" when the truth is "this build cannot say".
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
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        # Real format is "### PHASE-START <name> <ts>" - note the "###" prefix and the extra
        # padding in "PHASE-END  ". Four separate analyzers here assumed field 1 was the name
        # and silently found no bounds, reporting "no usable data" for runs whose data was
        # fine. Locate the keyword instead of indexing a guessed position.
        f = line.split()
        if "PHASE-START" in f:
            i, which = f.index("PHASE-START"), 0
        elif "PHASE-END" in f:
            i, which = f.index("PHASE-END"), 1
        else:
            continue
        if i + 1 >= len(f):
            continue
        name, ts = f[i + 1], f[-1]
        out.setdefault(name, [None, None])[which] = ts
    return {k: tuple(v) for k, v in out.items() if v[0] and v[1]}


def phase_stats(perf, bounds, phase):
    if phase not in bounds or not os.path.isfile(perf):
        return None
    since, until = bounds[phase]
    frames, _, _ = _ap.parse([perf])
    recs = [r for r in frames if since <= r["ts"] <= until]
    if not recs:
        return None
    # absent field != zero: a build without the counters must not report a 0 % hit rate
    if not any("pwskip" in r or "pwcap" in r for r in recs):
        return {"missing": True}
    skip = sum(r.get("pwskip", 0) for r in recs)
    cap = sum(r.get("pwcap", 0) for r in recs)
    considered = skip + cap
    return {
        "pwskip": skip,
        "pwcap": cap,
        "considered": considered,
        "hit": (skip / considered) if considered else None,
        "frames": sum(r.get("n", 0) for r in recs),
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


outdir = sys.argv[1] if len(sys.argv) > 1 else "."
pts = load(outdir)
good = [p for p in pts if p.get("valid")]
bad = [p for p in pts if not p.get("valid")]

print("=" * 78)
print("PER-WINDOW FAST-PATH HIT RATE - FocusRaise off vs on")
print("=" * 78)
print(f"  {len(good)} valid point(s), {len(bad)} failed")
for p in bad:
    print(f"    FAILED {p.get('cond')} rep{p.get('rep')}: {p.get('na', 'no records')}")
if not good:
    print("\nNo usable data. Missing data fails - no verdict.")
    sys.exit(1)

conds = [c for c in ("off", "on") if any(p["cond"] == c for p in good)]
by = {c: [p for p in good if p["cond"] == c] for c in conds}

missing = False
for phase in PHASES:
    rows = []
    for c in conds:
        ss = [p["phases"].get(phase) for p in by[c]]
        ss = [s for s in ss if s]
        if any(s.get("missing") for s in ss):
            missing = True
            continue
        ss = [s for s in ss if not s.get("missing")]
        if not ss:
            continue
        rows.append((c, len(ss), med([s["pwskip"] for s in ss]), med([s["pwcap"] for s in ss]),
                     med([s["considered"] for s in ss]),
                     med([s["hit"] for s in ss if s["hit"] is not None])))
    if not rows:
        continue
    print(f"\n-- {phase} --")
    print(f"{'FocusRaise':<12}{'reps':>6}{'pwskip':>10}{'pwcap':>10}{'considered':>12}{'hit rate':>11}")
    print("-" * 78)
    for c, n, sk, cp, co, hit in rows:
        h = f"{hit*100:.1f}%" if isinstance(hit, float) else "n/a"
        print(f"{c:<12}{n:>6}{sk if sk is not None else '-':>10}"
              f"{cp if cp is not None else '-':>10}{co if co is not None else '-':>12}{h:>11}")

if missing:
    print("\n!! Some runs carried no pwskip/pwcap fields: that build predates the counters.")
    print("   Reported as missing rather than as a 0 % rate.")

print("\n-- verdict --")
if len(conds) < 2:
    print("   Only one condition has data - no A/B comparison possible.")
    sys.exit(0)

for phase in PHASES:
    a = [p["phases"].get(phase) for p in by["off"]]
    b = [p["phases"].get(phase) for p in by["on"]]
    a = [s for s in a if s and not s.get("missing") and s.get("hit") is not None]
    b = [s for s in b if s and not s.get("missing") and s.get("hit") is not None]
    if not a or not b:
        continue
    lo, hi = med([s["hit"] for s in a]), med([s["hit"] for s in b])
    spread_a = (max(s["hit"] for s in a) - min(s["hit"] for s in a)) if len(a) > 1 else 0
    spread_b = (max(s["hit"] for s in b) - min(s["hit"] for s in b)) if len(b) > 1 else 0
    noise = max(spread_a, spread_b)
    delta = hi - lo
    # the difference has to clear the within-condition spread before it means anything
    verdict = "raises the hit rate" if delta > max(0.05, 2 * noise) else \
              ("lowers it" if delta < -max(0.05, 2 * noise) else "no material change")
    print(f"   {phase:<8}off {lo*100:5.1f}%  ->  on {hi*100:5.1f}%   "
          f"delta {delta*100:+5.1f} pp  (noise {noise*100:.1f} pp)   {verdict}")

print()
print("   A nil result is a result: SetForegroundWindow usually raises already, so the")
print("   focus raise may add nothing. That is worth knowing before anyone designs a")
print("   restack message for the protocol.")
