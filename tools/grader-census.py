#!/usr/bin/env python3
"""grader-census.py - which functions DECIDE a campaign's verdict, and which of them are tested?

WHY THIS EXISTS. On 2026-10-16 a pre-launch judgement kept answering "not yet" for a campaign whose
fix, gates and launcher were all green and all seen to fail. Bisecting the evidence showed why: four
separate instrument defects turned up in one afternoon - a clause-2 grader with no suite, a
release-goal clause that could go unmeasured and still pass, a procedure gate that did not cover the
wrappers calling the heavy path, and a permit that was not bound to a command. Each one was a reason
the next verdict could not be trusted, and four in an afternoon is evidence of a population, not of
bad luck.

So this counts the population instead of guessing at it. A campaign's verdict is the sum of its
GRADERS - the functions that call ok()/no() - and a grader nobody has exercised offline is a verdict
nobody has checked. This is the same rule the project already applies to gate suites ("count the
producers of every gate suite": 18 required, 12 had one).

    tools/grader-census.py                 report
    tools/grader-census.py --max-uncovered N   exit 1 if more than N graders have no suite
    tools/grader-census.py --json          machine-readable

IT NAMES, IT DOES NOT GUESS. "Covered" means some file under tools/tests/ mentions the function by
name - the weakest honest definition, deliberately: a stronger one would need a judgement about what
the test asserts, and overstating coverage is the failure mode here. A name that appears only in a
comment counts as covered, so the number this prints is a FLOOR on the problem, never a ceiling.
"""
import argparse
import json
import os
import re
import sys

HARNESSES = ["mgmt/harness/matrix.sh", "mgmt/harness/quick-upgrade.sh"]
TESTDIR = "tools/tests"
FUNC_RE = re.compile(r"^([a-z_][a-z0-9_]*)\(\)\s*\{")
GRADE_RE = re.compile(r'(^|\s)(ok|no)\s+"')


def graders(path):
    """{function: number of ok/no call sites} for one harness."""
    out, cur = {}, None
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for l in lines:
        m = FUNC_RE.match(l)
        if m:
            cur = m.group(1)
        if cur and GRADE_RE.search(l):
            out[cur] = out.get(cur, 0) + 1
    return out


def test_blobs():
    blobs = {}
    if not os.path.isdir(TESTDIR):
        return blobs
    for t in sorted(os.listdir(TESTDIR)):
        p = os.path.join(TESTDIR, t)
        if not os.path.isfile(p):
            continue
        try:
            blobs[t] = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
    return blobs


def census():
    blobs = test_blobs()
    rows = []
    for h in HARNESSES:
        for fn, n in graders(h).items():
            hits = sorted(t for t, b in blobs.items() if fn in b)
            rows.append({"harness": h, "grader": fn, "decisions": n, "suites": hits})
    rows.sort(key=lambda r: (-r["decisions"], r["grader"]))
    return rows


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-uncovered", type=int, default=None)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv[1:])
    rows = census()
    unc = [r for r in rows if not r["suites"]]
    dec_unc = sum(r["decisions"] for r in unc)
    dec_all = sum(r["decisions"] for r in rows)
    if a.json:
        print(json.dumps({"rows": rows, "uncovered": [r["grader"] for r in unc],
                          "decisions_total": dec_all, "decisions_uncovered": dec_unc}, indent=1))
    else:
        print("%-28s %-34s %9s  %s" % ("harness", "grader", "decisions", "offline suite"))
        for r in rows:
            print("%-28s %-34s %9d  %s" % (os.path.basename(r["harness"]), r["grader"],
                                           r["decisions"], ", ".join(r["suites"][:2]) or "-- NONE --"))
        print()
        print("%d grader(s), %d with no suite; %d of %d verdict decisions are made by an untested grader"
              % (len(rows), len(unc), dec_unc, dec_all))
        if unc:
            print("uncovered: %s" % " ".join(r["grader"] for r in unc))
    if a.max_uncovered is not None and len(unc) > a.max_uncovered:
        print("CENSUS: %d uncovered grader(s) exceeds the agreed ceiling of %d - cover one or move the "
              "ceiling in a commit" % (len(unc), a.max_uncovered), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
