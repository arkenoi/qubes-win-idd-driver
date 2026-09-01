#!/usr/bin/env python3
"""Summarise a stock-vs-ours run directory into a table and, where the data supports one, a
verdict.

THE VERDICT RULE, taken from what went wrong before. On 2026-08-09 this comparison produced
three numbers and only ONE of them meant anything: typing was +100 % with distributions that do
not overlap, while drag (-4.8 %) and scroll (+18 %) were smaller than the run-to-run spread and
proved nothing in either direction — yet the harness of the day tagged drag "beats stock". So:

  * a difference is only reported as REAL when the two sides' ranges are DISJOINT — every
    repetition of one side beats every repetition of the other;
  * otherwise it is "inside noise", explicitly with no verdict, and the spread is printed next
    to it so the reader can see why;
  * a phase with fewer than two valid repetitions per side gets no verdict at all.

Invalid repetitions are listed, never silently dropped and never coerced to zero.
"""
import glob
import json
import os
import statistics
import sys


def load(outdir):
    runs = []
    for path in sorted(glob.glob(os.path.join(outdir, "r*-*.json"))):
        tag = os.path.basename(path)[:-5]
        try:
            o = json.load(open(path))
        except Exception as e:                       # noqa: BLE001
            o = {"valid": False, "why": [f"unreadable: {e}"]}
        side = "ours" if tag.endswith("-ours") else "stock"
        runs.append((tag, side, o))
    return runs


def main(outdir):
    runs = load(outdir)
    if not runs:
        print("NO RUNS FOUND in", outdir)
        return 1

    valid = [(t, s, o) for t, s, o in runs if o.get("valid")]
    invalid = [(t, s, o) for t, s, o in runs if not o.get("valid")]

    print(f"repetitions: {len(runs)} total, {len(valid)} valid, {len(invalid)} INVALID")
    for t, s, o in invalid:
        print(f"  INVALID {t}: {'; '.join(o.get('why', ['(no reason recorded)']))}")
    if invalid:
        print("  (invalid repetitions carry no number and are excluded from every figure below)")

    hashes = {}
    for _, s, o in valid:
        hashes.setdefault(s, set()).add(o.get("bin_sha256"))
    print("\nbinaries actually measured (from the guest, per repetition):")
    for s, hs in sorted(hashes.items()):
        print(f"  {s:5s} {', '.join(sorted(x or '?' for x in hs))}"
              + ("   <-- MORE THAN ONE BINARY ON THIS SIDE, the comparison is void" if len(hs) > 1 else ""))

    phases = []
    for _, _, o in valid:
        for p in o.get("phases", {}):
            if p not in phases:
                phases.append(p)

    print(f"\n{'phase':12s} {'stock (n)':>18s} {'ours (n)':>18s} {'delta':>10s}  verdict")
    table = {}
    for p in phases:
        vals = {"stock": [], "ours": []}
        for _, s, o in valid:
            v = o.get("phases", {}).get(p, {}).get("pct_core")
            if v is not None:
                vals[s].append(v)
        st, ou = sorted(vals["stock"]), sorted(vals["ours"])
        if len(st) < 2 or len(ou) < 2:
            print(f"{p:12s} {'n/a':>18s} {'n/a':>18s} {'':>10s}  too few valid repetitions "
                  f"(stock n={len(st)}, ours n={len(ou)}) - NO VERDICT")
            continue
        ms, mo = statistics.median(st), statistics.median(ou)
        delta = (mo - ms) / ms * 100 if ms else float("nan")
        disjoint = (max(st) < min(ou)) or (max(ou) < min(st))
        spread = max(
            (max(st) - min(st)) / ms * 100 if ms else 0,
            (max(ou) - min(ou)) / mo * 100 if mo else 0)
        if disjoint:
            verdict = ("REAL - ranges disjoint, ours WORSE" if mo > ms
                       else "REAL - ranges disjoint, ours BETTER")
        else:
            verdict = f"inside noise (spread {spread:.0f}%) - NO VERDICT"
        print(f"{p:12s} {ms:12.3f} ({len(st)}) {mo:12.3f} ({len(ou)}) {delta:+9.1f}%  {verdict}")
        table[p] = {"stock_median": round(ms, 3), "ours_median": round(mo, 3),
                    "delta_pct": round(delta, 1), "stock": st, "ours": ou,
                    "disjoint": disjoint, "spread_pct": round(spread, 1), "verdict": verdict}

    print("\nper-repetition values (% of one core):")
    for p in phases:
        for s in ("stock", "ours"):
            vals = [(t, o["phases"][p]["pct_core"]) for t, ss, o in valid
                    if ss == s and o.get("phases", {}).get(p, {}).get("pct_core") is not None]
            if vals:
                print(f"  {p:12s} {s:5s} " + "  ".join(f"{t.split('-')[0]}={v:.3f}" for t, v in vals))

    json.dump(table, open(os.path.join(outdir, "summary.json"), "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
