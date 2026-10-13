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

VERDICT_RE = re.compile(r"^(?:\[[0-9:]+\]\s*)?(PASS|FAIL)  ([A-Za-z0-9]+-[A-Za-z0-9-]+?)(?: boot \d+)?:\s*(.*)$")
FOOTER_RE = re.compile(r"^=== MATRIX: (\d+) passed, (\d+) failed ===$")
CELLS_RE = re.compile(r"^(?:\[[0-9:]+\])?\s*cells:\s*(.*)$")
INSTRUMENT_TOKENS = ("INVALID", "INSTRUMENT", "INCONCLUSIVE", "BLOCKED", "SKIPPED")


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
        product = [r for r in fails if not any(t in r[1] for t in INSTRUMENT_TOKENS)]
        instrument = [r for r in fails if any(t in r[1] for t in INSTRUMENT_TOKENS)]
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
    for f in a.feature:
        name, _, rc = f.partition("=")
        if not name or not rc.lstrip("-").isdigit():
            print("coverage-receipt: bad --feature %r (want name=rc)" % f, file=sys.stderr)
            return 2
        rc_i = int(rc)
        suites[name] = "pass" if rc_i == 0 else ("instrument-fail" if rc_i == 2 else "product-fail")
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
