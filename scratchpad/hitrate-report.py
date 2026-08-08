#!/usr/bin/env python3
"""Per-window fast-path hit rate AND why it refuses, from benchmark rep data.

    hitrate-report.py <dir-with-ours-r*-subdirs>

Needs no separate VM run: the benchmark reps already collect QGAPERF. The previous
measurement of this reported a bare 0.0 % hit rate, which was true but useless - it could not
say whether a guard always refused or whether content genuinely changed every frame. It was
the former (PwScreenUnchanged required g_ZOrderValid, which CollectZOrder deliberately leaves
FALSE unless a popup is on screen). The refusal columns exist so that cannot recur.

Only `content-changed` means "this present carried a real repaint". Every other reason is the
check declining to look, and each points at a different repair:

    no-fb        no framebuffer/pitch          -> the screen is not available at all here
    no-zorder    ordering unknown              -> should now be unreachable (the fix removed it)
    offscreen    window not wholly on screen   -> bounds or geometry problem
    occluded     something stacked above       -> genuine occlusion, ordering was available
    not-fg       not the foreground window     -> order-free path: only the active window qualifies
    overlap      another visible window overlaps-> order-free path was too conservative here
    first-seen   no previous hash yet          -> unavoidable, once per window

A build predating the counters is reported as MISSING, never as zero.
"""
import importlib.util
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "analyze_perf", os.path.join(HERE, "..", "instrumentation", "analyze-perf.py"))
_ap = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ap)

REASONS = [
    ("pwnofb", "no-fb"), ("pwnoz", "no-zorder"), ("pwoff", "offscreen"),
    ("pwocc", "occluded"), ("pwnofg", "not-fg"), ("pwovl", "overlap"),
    ("pwfirst", "first-seen"), ("pwchg", "content-changed"),
]

root = sys.argv[1] if len(sys.argv) > 1 else "."
reps = sorted(glob.glob(os.path.join(root, "ours-r*")))
if not reps:
    print(f"no rep directories under {root}", file=sys.stderr)
    sys.exit(2)

print("=" * 78)
print("PER-WINDOW FAST PATH: hit rate and refusal causes")
print("=" * 78)
print(f"{'rep':<10}{'frames':>9}{'pwskip':>9}{'pwcap':>9}{'considered':>12}{'hit rate':>11}")
print("-" * 78)

TS = TC = 0
totals = {k: 0 for k, _ in REASONS}
have_counters = False
have_reasons = False
for rep in reps:
    perf = os.path.join(rep, "perf.txt")
    if not os.path.isfile(perf):
        print(f"{os.path.basename(rep):<10}{'no perf.txt':>50}")
        continue
    frames, _, _ = _ap.parse([perf])
    if any("pwskip" in r or "pwcap" in r for r in frames):
        have_counters = True
    if any(k in r for r in frames for k, _ in REASONS[:6]):
        have_reasons = True
    n = sum(r.get("n", 0) for r in frames)
    sk = sum(r.get("pwskip", 0) for r in frames)
    cp = sum(r.get("pwcap", 0) for r in frames)
    con = sk + cp
    TS += sk
    TC += cp
    for k, _ in REASONS:
        totals[k] += sum(r.get(k, 0) for r in frames)
    hit = f"{sk/con*100:.1f}%" if con else "n/a"
    print(f"{os.path.basename(rep):<10}{n:>9}{sk:>9}{cp:>9}{con:>12}{hit:>11}")

con = TS + TC
print("-" * 78)
print(f"{'ALL':<10}{'':>9}{TS:>9}{TC:>9}{con:>12}"
      f"{(f'{TS/con*100:.1f}%' if con else 'n/a'):>11}")

if not have_counters:
    print("\nMISSING: this build carries no pwskip/pwcap. No hit rate exists - not a zero.")
    sys.exit(1)

print("\n-- why it refused --")
if not have_reasons:
    print("   MISSING: this build carries no refusal counters (PERF_RECORD_VERSION < 4).")
    print("   The hit rate above is real, but its cause cannot be attributed. Not a zero.")
    sys.exit(0)

tot_r = sum(totals.values())
print(f"{'reason':<18}{'count':>10}{'share':>9}")
print("-" * 78)
for k, name in REASONS:
    v = totals[k]
    share = f"{v/tot_r*100:.1f}%" if tot_r else "-"
    print(f"{name:<18}{v:>10}{share:>9}")

print("\n-- reading --")
real = totals["pwchg"]
declined = tot_r - real - totals["pwfirst"]
if tot_r == 0:
    print("   No refusals recorded at all.")
elif real and real / tot_r > 0.6:
    print(f"   {real/tot_r*100:.0f}% of refusals are content-changed: the window's pixels really")
    print("   did change on those presents. To that extent the presents are NOT redundant, and")
    print("   coalescing cannot remove them - the lever is elsewhere.")
elif declined and declined / tot_r > 0.6:
    print(f"   {declined/tot_r*100:.0f}% of refusals are the check DECLINING TO LOOK, not evidence")
    print("   about redundancy. Whichever reason dominates above is the next thing to fix; the")
    print("   coalescing premise remains untested until that share is small.")
else:
    print("   Mixed. Read the dominant reason above before drawing any conclusion.")
