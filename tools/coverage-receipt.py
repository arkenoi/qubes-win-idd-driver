#!/usr/bin/env python3
"""coverage-receipt.py - the coverage receipt the release-cut gate reads, DERIVED from what actually ran, with
PRODUCT-FAIL and INSTRUMENT-FAIL told apart (PLAN-acceptance-optimization section 6; docs/ADR-acceptance.md section 4).

    tools/coverage-receipt.py --out <receipt.json> --campaign <dir> --cells "<cell> ..." [--feature <name>=<rc>]...
                              [--package-verify-rc <n>] [--package-run <id>] [--built-from <sha>] [--range <b>..<h>]

WHY. tools/release-acceptance.sh used to write the receipt from the INTENDED cell list, whatever happened - a receipt
is a record, not an intention - and a suite that could not measure the product (an INVALID-* cell, a feature test
exiting 2) was recorded exactly like one that measured it and failed. Section 6: instrument-fail is not a product
regression, the suite is UNCOVERED, and the gate refuses the cut.

HOW A CELL IS CLASSED, from the campaign's cell-group outputs (<dir>/*.out, the files record-acceptance.sh reads):
  * the lines `PASS  <LABEL>: ...` / `FAIL  <LABEL>: ...` (optional [hh:mm:ss] prefix, optional ` boot N`), where a
    cell `win10-clean` is labelled `WIN10-clean` by matrix.sh;
  * a FAIL line carrying one of mgmt/harness/verdict-lib.sh's ungraded tokens (INVALID, INSTRUMENT, INCONCLUSIVE,
    BLOCKED, SKIPPED) is an instrument-class line; any other FAIL line names the product;
  * no verdict line at all, or a group without the `=== MATRIX: N passed, M failed ===` footer -> not run.
  cell class:  any product FAIL line -> product-fail;  FAIL lines all instrument-class -> instrument-fail;
               only PASS lines -> pass;  nothing -> not-run.
A feature test is classed by its exit: 0 pass, 2 instrument-fail, anything else product-fail. package-verify by its rc.

THE RECEIPT: {"suites": [pass + product-fail]  (what RAN and MEASURED - Jev 2026-10-13 receipt_product_fail_covered =
covered-with-fail-flag 0.94: a product failure is covered, and the cut is refused by the acceptance RECORD),
"product_fail": [...], "instrument_fail": [...] (NOT in suites - uncovered), "not_run": [...], "result": pass|fail, ...}.
Exit 0 receipt written; 2 the campaign dir or an argument is unusable (no receipt - missing data fails).
Self-test: tools/tests/coverage-receipt-selftest.sh (knob: instrumentcovered).
"""
from __future__ import annotations
import argparse, glob, json, os, re, sys, time

# THE LEVEL TOKEN SITS BETWEEN THE TIMESTAMP AND THE VERDICT, AND THIS PATTERN HAD NO SLOT FOR IT.
# matrix.sh's verdict lines are tagged with the writer's level so a sweep can tell "3 passed, 2
# failed" from "5 passed, 0 failed" - the right change, and it silently blinded this parser:
#     [11:13:08] [ERROR] FAIL  win10-clean: the guest log sweep found a breach or a defect
# matched nothing, so EVERY matrix cell read as not_run while its report.json sat on disk with
# graded breaches. The 4.3.36 campaign ran all eight cells and the receipt said `covered=3`,
# `not_run=[all eight]`, and gate-scope then refused the cut with "required 18, covered 3" - a
# release blocked by a regex, with the evidence it wanted already written.
# The self-test did not catch it because its fixture carried the PRE-TAGGING shape, so it was green
# against text nothing emits any more (the standing trap: a fixture comes from a CAPTURE, not from a
# model of the format). Its fixture is now the captured shape, and the legacy forms stay parsed.
VERDICT_RE = re.compile(r"^(?:\[[0-9:]+\]\s*)?(?:\[(?:ERROR|WARN|WARNING|INFO|DEBUG)\]\s*)?(PASS|FAIL)  ([A-Za-z0-9]+-[A-Za-z0-9-]+?)(?: boot \d+)?:\s*(.*)$")
FOOTER_RE = re.compile(r"^=== MATRIX: (\d+) passed, (\d+) failed ===$")
INSTRUMENT_TOKENS = ("INVALID", "INSTRUMENT", "INCONCLUSIVE", "BLOCKED", "SKIPPED")
# A SWEEP DECLARES "I COULD NOT MEASURE" IN ITS STATUS, NOT IN A TOKEN THIS LIST HOLDS. MEASURED
# 2026-11-07, campaign 42400226595 at 4b55d0a46510: supervision-gate's ONLY failing row was
# `FAIL  [SW] the sweep finds nothing new or breached -- LOGSWEEP-RESULT ... rc=3 status=DATA`,
# and template-update failed twice on "missing data fails". Neither text carries one of the five
# tokens above, so BOTH were recorded as product regressions - the one thing a blind instrument
# cannot tell you - while every graded product cell passed (matrix 8/8 CLEAN, 0 breaches, 0 P1).
# mgmt/harness/verdict-lib.sh:11 states the invariant that broke: "missing data is
# INVALID-INSTRUMENT, never FAIL, never a default", and this file's own docstring already named
# "sweep DATA/INCOMPLETE" as instrument per plan section 6 - only the vocabulary never got it.
# ANCHORED ON `status=`, NOT THE BARE WORD: "DATA" is a substring of METADATA and of any prose that
# mentions data, so a bare token would silently reclassify real product FAILs. The predicate has to
# BE the declaration, not a word that co-occurs with it. (# GUARD:ungradedstatus)
UNGRADED_STATUS_RE = re.compile(r"\bstatus=(?:DATA|INCOMPLETE)\b")


def instrument_line(text: str) -> bool:
    """True when a FAIL text DECLARES it could not measure, wherever in the text that sits."""
    return any(t in text for t in INSTRUMENT_TOKENS) or bool(UNGRADED_STATUS_RE.search(text))


def ledger_class(path: str) -> str:
    """pass | product-fail | instrument-fail, or "" when there is no usable ledger.

    THE CLASS IS DECLARED PER ROW AND THE COLUMN IS NOT FIXED. tools/gate-remainder.sh:92 reads
    column 3, which is right for the failproof ledgers (c3=INVALID-INSTRUMENT) and WRONG for
    supervision-e2e's (c1=SW, c2=FAIL, c3=the claim, c4=LOGSWEEP-RESULT ... status=DATA): there it
    reads the claim text, finds no token, returns NONE and the caller falls back to the exit code -
    which is exactly the defect this fixes. So scan the WHOLE row. Worst wins: one product FAIL
    outranks every gap. A missing, empty or unreadable ledger returns "" so the caller keeps its
    old behaviour - "no row" must never read as "not a failure".
    """
    try:
        rows = [ln for ln in open(path, encoding="utf-8", errors="replace").read().splitlines() if ln.strip()]
    except OSError:
        return ""
    if not rows:
        return ""
    worst = "pass"
    for ln in rows:
        fields = [f.strip() for f in ln.split("\t")]
        if not any(f == "FAIL" or any(f.startswith(t) for t in INSTRUMENT_TOKENS) for f in fields):
            continue
        if instrument_line(ln):
            if worst != "product-fail":
                worst = "instrument-fail"
        else:
            worst = "product-fail"
    return worst


def label_of(cell: str) -> str:
    os_, _, rest = cell.partition("-")
    return "%s-%s" % (os_.upper(), rest)


def classify_campaign(campdir: str, cells: list[str]) -> tuple[dict[str, dict], list[str]]:
    outs = sorted(glob.glob(os.path.join(campdir, "*.out")))
    notes: list[str] = []
    lines_by_label: dict[str, list[tuple[str, str, str]]] = {}
    finished_groups: list[str] = []
    for f in outs:
        try:
            text = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except OSError as e:
            notes.append("%s unreadable: %s" % (f, e))
            continue
        footer = [ln for ln in text if FOOTER_RE.match(ln)]
        if footer:
            finished_groups.append(os.path.basename(f))
        else:
            notes.append("%s has no MATRIX footer - that cell-group did not finish" % os.path.basename(f))
        for ln in text:
            m = VERDICT_RE.match(ln)
            if m:
                lines_by_label.setdefault(m.group(2).lower(), []).append((m.group(1), m.group(3), os.path.basename(f)))
    out: dict[str, dict] = {}
    for c in cells:
        rows = lines_by_label.get(label_of(c).lower(), [])
        fails = [r for r in rows if r[0] == "FAIL"]
        product = [r for r in fails if not instrument_line(r[1])]
        instrument = [r for r in fails if instrument_line(r[1])]
        if not rows:
            cls = "not-run"
        elif product:
            cls = "product-fail"
        elif instrument:
            cls = "instrument-fail"
        else:
            cls = "pass"
        out[c] = {"class": cls, "pass_lines": sum(1 for r in rows if r[0] == "PASS"), "product_fail_lines": [r[1][:200] for r in product][:5],
                  "instrument_fail_lines": [r[1][:200] for r in instrument][:5]}
    return out, notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--campaign", required=True)
    ap.add_argument("--cells", default="")
    ap.add_argument("--feature", action="append", default=[], help="<name>=<rc> (repeatable)")
    ap.add_argument("--feature-ledger", action="append", default=[],
                    help="<name>=<path to the suite's verdicts.tsv> (repeatable); its DECLARED class "
                         "beats the exit code, which cannot carry the distinction")
    ap.add_argument("--package-verify-rc", type=int)
    ap.add_argument("--package-run", default="")
    ap.add_argument("--built-from", default="")
    ap.add_argument("--range", default="")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.campaign):
        print("coverage-receipt: no campaign dir %s - no receipt (missing data fails)" % a.campaign, file=sys.stderr)
        return 2
    cells = a.cells.split()
    classes, notes = classify_campaign(a.campaign, cells)
    suites: dict[str, str] = {}
    for c, info in classes.items():
        suites[c] = info["class"]
    ledgers: dict[str, str] = {}
    for fl in a.feature_ledger:
        name, _, path = fl.partition("=")
        if not name or not path:
            print("coverage-receipt: bad --feature-ledger %r (want name=path)" % fl, file=sys.stderr)
            return 2
        ledgers[name] = path
    for f in a.feature:
        name, _, rc = f.partition("=")
        if not name or not rc.lstrip("-").isdigit():
            print("coverage-receipt: bad --feature %r (want name=rc)" % f, file=sys.stderr)
            return 2
        rc_i = int(rc)
        by_exit = "pass" if rc_i == 0 else ("instrument-fail" if rc_i == 2 else "product-fail")
        # AN EXIT CODE CANNOT CARRY THIS DISTINCTION, and the reason is recorded in
        # tools/gate-remainder.sh:82-87: two conventions exist in this apparatus and they are
        # INVERTED - verdict-lib.sh reads 1 as EXECUTED-WITH-GAPS and 2 as BROKEN, while
        # release-acceptance.sh's logvol arm reads 2 as INVALID-RIG and every other non-zero as a
        # product FAIL. That gate fixed it for the two suites whose ledger it can find and said so;
        # the feature-test path never inherited the fix (the standing rule: a copied idiom needs
        # EVERY site of that operation). The suites ALREADY declare the class per row - read that.
        declared = ledger_class(ledgers[name]) if name in ledgers else ""
        # A LEDGER MAY NEVER TURN A NON-ZERO EXIT INTO A PASS. The ledger is written DURING the run,
        # so a suite that died after its last row would otherwise read as green on its own stale
        # evidence - a verifier reading its own bookkeeping. Downgrading product-fail to
        # instrument-fail is the whole point and is safe: `covered` below excludes instrument-fail,
        # so the suite leaves `suites`, gate-scope.py check still refuses the cut on coverage, and
        # `result` stays "fail" for any non-pass class. The CLASS the operator is told changes;
        # no gate decision does.
        if declared and not (rc_i != 0 and declared == "pass"):
            suites[name] = declared
            if declared != by_exit:
                notes.append("%s: class %s DECLARED by %s (exit %d alone would have said %s)"
                             % (name, declared, ledgers[name], rc_i, by_exit))
        else:
            suites[name] = by_exit
            if declared == "pass" and rc_i != 0:
                notes.append("%s: ledger %s declares every row passing but the suite exited %d - "
                             "kept %s; a ledger cannot outrank a non-zero exit"
                             % (name, ledgers[name], rc_i, by_exit))
    if a.package_verify_rc is not None:
        suites["package-verify"] = "pass" if a.package_verify_rc == 0 else "product-fail"
    covered = sorted(s for s, c in suites.items() if c in ("pass", "product-fail"))   # GUARD:instrumentcovered DEFECT: covered = sorted(s for s, c in suites.items() if c in ("pass", "product-fail", "instrument-fail"))
    rec = {"suites": covered,
           "product_fail": sorted(s for s, c in suites.items() if c == "product-fail"),
           "instrument_fail": sorted(s for s, c in suites.items() if c == "instrument-fail"),
           "not_run": sorted(s for s, c in suites.items() if c == "not-run"),
           "result": "pass" if all(c == "pass" for c in suites.values()) and suites else "fail",
           "classes": {s: classes.get(s, {"class": c}) for s, c in suites.items()},
           "package_run": a.package_run, "built_from": a.built_from, "range": a.range,
           "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "notes": notes,
           "note": "written by tools/coverage-receipt.py from the campaign's own verdict lines; `suites` names what RAN and MEASURED "
                   "(pass + product-fail); instrument-fail is uncovered and refuses the cut (plan section 6)"}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    json.dump(rec, open(a.out, "w", encoding="utf-8"), indent=1)
    print("RECEIPT %s: covered=%d product_fail=%s instrument_fail=%s not_run=%s result=%s -> %s" % (
        a.built_from[:12] or "-", len(covered), rec["product_fail"] or "-", rec["instrument_fail"] or "-", rec["not_run"] or "-", rec["result"], a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
