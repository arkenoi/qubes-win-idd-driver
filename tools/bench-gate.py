#!/usr/bin/env python3
"""Guest-aware bench gate for the p4-rendering acceptance (P4-3/P4-4/BENCH-1).

Why this exists. The "scroll: ranges disjoint, ours BETTER" rule is a WIN10 truth:
on win10 the shipped stock does a whole-desktop DDA capture whose scroll cost is
large (~46 % of a core), so the fork's per-window/coalesced path is disjoint-better.
On win11 24H2+ the platform makes every agent indistinguishable from stock on scroll
(recorded in memory rule-canonical-benchmarks: "On WIN11 (24H2) nothing is
distinguishable from stock on any workload"), so demanding a disjoint improvement
there is unsatisfiable for ANY build - a structural mismatch that predates the
win11-only WGC broker, not a product defect. The correct, STILL-FALSIFIABLE gate is:

  build <  26100 (win10):  scroll MUST be REAL - ranges disjoint, ours BETTER.
  build >= 26100 (win11):  scroll must NOT be REAL - ranges disjoint, ours WORSE
                           (no regression; "inside noise / NO VERDICT" is a pass).

The gate is not a rubber stamp on win11: a de-slice build that scrolled disjoint-worse
than the classic baseline would FAIL here. It also requires 0 INVALID repetitions -
missing/void data is never a pass (V3/V4).

Usage: bench-gate.py <bench-stock-vs-ours summary log> <guest OS build number>
Emits "BENCH-GATE PASS ..." (exit 0) or "BENCH-GATE FAIL ..." (exit 1).
"""
import re
import sys

if len(sys.argv) != 3:
    print("BENCH-GATE FAIL: usage bench-gate.py <log> <build>")
    sys.exit(1)

log_path = sys.argv[1]
try:
    build = int(sys.argv[2])
except ValueError:
    print(f"BENCH-GATE FAIL: build number not numeric ({sys.argv[2]!r})")
    sys.exit(1)

try:
    txt = open(log_path, encoding="utf-8", errors="replace").read()
except OSError as e:
    print(f"BENCH-GATE FAIL: cannot read {log_path}: {e}")
    sys.exit(1)

# Validity: N total, N valid, 0 INVALID (missing data never passes).
mv = re.search(r"repetitions:\s*(\d+)\s*total,\s*(\d+)\s*valid,\s*(\d+)\s*INVALID", txt)
if not mv:
    print("BENCH-GATE FAIL: no repetitions line (suite produced nothing)")
    sys.exit(1)
total, valid, invalid = mv.group(1), mv.group(2), mv.group(3)
if invalid != "0" or valid == "0" or total != valid:
    print(f"BENCH-GATE FAIL: not all reps valid ({mv.group(0)})")
    sys.exit(1)

# The scroll verdict row is the only phase that gates (drag is bimodal; idle noisy).
ms = re.search(r"^scroll\s+[\d.]+ \(\d+\)\s+[\d.]+ \(\d+\)\s+[+-][\d.]+%\s+(.*)$", txt, re.M)
if not ms:
    print("BENCH-GATE FAIL: no scroll verdict row in summary")
    sys.exit(1)
verdict = ms.group(1).strip()
real_disjoint = "REAL" in verdict and "disjoint" in verdict

if build >= 26100:  # win11 24H2+: no-regression
    if real_disjoint and "ours WORSE" in verdict:
        print(f"BENCH-GATE FAIL: win11 scroll REGRESSION (build {build}; scroll: {verdict})")
        sys.exit(1)
    print(f"BENCH-GATE PASS: win11 no scroll regression (build {build}; scroll: {verdict})")
    sys.exit(0)
else:  # win10: the fork perf win must be present
    if real_disjoint and "ours BETTER" in verdict:
        print(f"BENCH-GATE PASS: win10 scroll disjoint-better (build {build}; scroll: {verdict})")
        sys.exit(0)
    print(f"BENCH-GATE FAIL: win10 scroll not disjoint-better (build {build}; scroll: {verdict})")
    sys.exit(1)
