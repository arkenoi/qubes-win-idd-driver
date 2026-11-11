#!/usr/bin/env python3
"""coverage-receipt.py - the coverage receipt the release-cut gate reads, DERIVED from what actually ran, with
PRODUCT-FAIL and INSTRUMENT-FAIL told apart (PLAN-acceptance-optimization section 6; docs/ADR-acceptance.md section 4).

    tools/coverage-receipt.py --out <receipt.json> --campaign <dir> --cells "<cell> ..." [--feature <name>=<rc>]...
                              [--package-verify-rc <n>] [--package-run <id>] [--built-from <sha>] [--range <b>..<h>]

WHY. tools/release-acceptance.sh used to write the receipt from the INTENDED cell list, whatever happened - a receipt
is a record, not an intention - and a suite that could not measure the product (an INVALID-* cell, a feature test
exiting 2) was recorded exactly like one that measured it and failed. Section 6: instrument-fail is not a product
regression, the suite is UNCOVERED, and the gate refuses the cut.

HOW A CELL IS CLASSED: by tools/acceptance_json.py from the matrix's own JSON - <dir>/matrix/matrix-result.json and the
rows in <dir>/matrix/checks.jsonl, where the cell and the class are fields set where mgmt/harness/matrix.sh decides
them. NO LOG TEXT IS READ. Until 2026-11-11 this file recovered both by a regex over the campaign's *.out lines, with
a token list of its own, and was blinded by a change to that prose (the 4.3.36 receipt: every cell "not run" with the
evidence on disk). Owner, 2026-11-11: "we were intended to stop grepping and make json parser instead, grep is
unreliable". The rules are the reader's and are stated in its header; in short:
  cell class:  a FAIL row -> product-fail;  else an INVALID row -> instrument-fail;  else a PASS row -> pass;
               no row -> not-run;  rows that cannot be relied on (the run did not end through its exit trap, a lost
               or corrupt row) -> EVERY cell instrument-fail, with the reason.
  A campaign directory with no matrix-result.json has no matrix verdict at all: every cell is not-run. That includes
  campaigns recorded before the rows existed - they cannot be re-classed by this tool, and that is deliberate.
  `cell_verdict_source` in the receipt says which it was: rows | none.
A feature test is classed by the class its own ledger DECLARES when one is passed (--feature-ledger; see main()), and
otherwise by its exit: 0 pass, 2 instrument-fail, anything else product-fail. package-verify by its rc.

THE RECEIPT: {"suites": [pass + product-fail]  (what RAN and MEASURED - Jev 2026-10-13 receipt_product_fail_covered =
covered-with-fail-flag 0.94: a product failure is covered, and the cut is refused by the acceptance RECORD),
"product_fail": [...], "instrument_fail": [...] (NOT in suites - uncovered), "not_run": [...], "result": pass|fail, ...}.
Exit 0 receipt written; 2 the campaign dir or an argument is unusable (no receipt - missing data fails).
"""
from __future__ import annotations
import argparse, json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance_json  # noqa: E402 - the one reader of a campaign's JSON; this file reads no log text

# THE UNGRADED VOCABULARY, for a FEATURE TEST'S LEDGER only (ledger_class below). Matrix cells are not classed by
# token any more: their class is a field of the matrix's own rows, read through tools/acceptance_json.py.
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
# BE the declaration, not a word that co-occurs with it.
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
    matrix = acceptance_json.read_matrix(a.campaign)
    classes, notes = acceptance_json.cell_classes(matrix, cells)
    source = "rows" if matrix["present"] else "none"
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
    covered = sorted(s for s, c in suites.items() if c in ("pass", "product-fail"))   # an instrument-fail suite is NOT covered
    rec = {"suites": covered,
           "product_fail": sorted(s for s, c in suites.items() if c == "product-fail"),
           "instrument_fail": sorted(s for s, c in suites.items() if c == "instrument-fail"),
           "not_run": sorted(s for s, c in suites.items() if c == "not-run"),
           "result": "pass" if all(c == "pass" for c in suites.values()) and suites else "fail",
           "classes": {s: classes.get(s, {"class": c}) for s, c in suites.items()},
           "cell_verdict_source": source,
           "package_run": a.package_run, "built_from": a.built_from, "range": a.range,
           "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "notes": notes,
           "note": "written by tools/coverage-receipt.py from the campaign's own verdicts (cell_verdict_source: rows = the matrix's "
                   "checks.jsonl through tools/acceptance_json.py, none = the campaign left no matrix result); `suites` names what "
                   "RAN and MEASURED (pass + product-fail); instrument-fail is uncovered and refuses the cut (plan section 6)"}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    json.dump(rec, open(a.out, "w", encoding="utf-8"), indent=1)
    print("RECEIPT %s: covered=%d product_fail=%s instrument_fail=%s not_run=%s result=%s -> %s" % (
        a.built_from[:12] or "-", len(covered), rec["product_fail"] or "-", rec["instrument_fail"] or "-", rec["not_run"] or "-", rec["result"], a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
