#!/usr/bin/env python3
"""acceptance_json.py - the ONE reader of what an acceptance campaign wrote as JSON. It matches no text.

Owner, 2026-11-10: "i think acceptance should produce clear jsons, not ambiguous text output"; 2026-11-11: "we were
intended to stop grepping and make json parser instead, grep is unreliable".

WHAT IT READS - each written where the fact is decided, none recovered from a log line:
  <campaign>/matrix/matrix-result.json   mgmt/harness/matrix.sh, at every cell boundary and from its exit trap: state
                                         running|ended, exit_code, run, counts{PASS,FAIL,INVALID}, finished, abort_line,
                                         complete, cell_running, cells_planned
  <campaign>/matrix/checks.jsonl         matrix.sh, one row per counted verdict: run, seq, cell, class PASS|FAIL|INVALID
                                         (FAIL = the product; INVALID = could not be measured), kind, text
  <campaign>/feature-<test>.json         tools/release-acceptance.sh, one per feature test, through feature-result below
  <work>/acceptance.json                 tools/release-acceptance.sh, the run as one document
WHO CALLS IT: tools/release-acceptance.sh (did the matrix complete; a feature test's result), tools/coverage-receipt.py
(each cell's class), tools/record-acceptance.sh (the record's inputs), tools/campaign-state.py (the operator's view),
mgmt/harness/campaign-full.sh (did the matrix complete).

    tools/acceptance_json.py matrix-complete <campaign-dir>
        one line of the facts; exit 0 complete, 1 not complete, 2 no readable result file
    tools/acceptance_json.py record-facts <campaign-dir> [--rerun <campaign-dir>]...
        the acceptance record's inputs as one JSON document; exit 2 when the campaign holds no group result
    tools/acceptance_json.py feature-result <campaign-dir> <test> <exit-code> [--ledger P] [--out P] [--attempt ID]
        writes <campaign-dir>/feature-<test>.json

THE RULES, in one place:
  * A matrix result is FINAL only when it says state=ended, every line of checks.jsonl is a row, and this run's rows
    counted by class equal the run's own counters. Anything else - still "running" (the process died without its exit
    trap), a line that is not a row, a lost row - and nothing is classed from it: every cell is instrument-fail with
    the reason. A missing datum fails here; it is never filled in from a log.
  * checks.jsonl is appended across continuations of one campaign directory, so only the rows whose `run` is the
    result's belong to this run.
  * COMPLETE = ended + the normal footer was reached + no abort line. A missing result file is not complete.
  * A cell's class: a FAIL row that grades -> product-fail; else an INVALID row that grades -> instrument-fail; else a
    PASS row -> pass; else not-run. Rows of kind check and subject-unusable grade their cell; cell-not-run and
    selector-refused rows are counted by the matrix and say why a cell has no grade - they do not give it one.
  * A matrix group is CLEAN for the record when its result is final and complete, no row is FAIL or INVALID, and every
    planned cell has a passing check. A feature group is clean when its test exited 0.
  * A failed matrix group may be SUPERSEDED by re-run campaigns only as _supersede below says: it reached its footer,
    a failed check names a cell, and every cell that failed or has no passing check passed in a clean re-run. A failed
    feature group may be, only when its test exited 2 (could not measure) and the same group passed in a clean re-run.
"""
from __future__ import annotations
import argparse, glob, json, os, sys, time

ROW_CLASSES = ("PASS", "FAIL", "INVALID")
GRADING_KINDS = ("check", "subject-unusable")


def read_matrix(campdir: str) -> dict:
    """The matrix result and this run's rows, and whether they are FINAL (see the rules above).

    -> {dir, present, result, rows, final, why_not_final}. `rows` are returned even when the run is not final, so a
    reader showing a campaign in progress can count what has been written so far; nothing may be CLASSED from them.
    """
    mdir = os.path.join(campdir, "matrix")
    m: dict = {"dir": mdir, "present": False, "result": {}, "rows": [], "final": False, "why_not_final": ""}
    rpath = os.path.join(mdir, "matrix-result.json")
    if not os.path.exists(rpath):
        m["why_not_final"] = "no matrix-result.json in %s" % mdir
        return m
    m["present"] = True
    try:
        res = json.load(open(rpath, encoding="utf-8"))
    except (OSError, ValueError) as e:
        m["why_not_final"] = "matrix-result.json is unreadable: %s" % e
        return m
    if not isinstance(res, dict) or not res.get("run"):
        m["why_not_final"] = "matrix-result.json is not a result document (no run id)"
        return m
    m["result"] = res
    bad_line = ""
    cpath = os.path.join(mdir, "checks.jsonl")
    if os.path.exists(cpath):      # no file at all is a run that counted nothing; the counters below decide
        try:
            for n, ln in enumerate(open(cpath, encoding="utf-8").read().splitlines(), 1):
                if not ln.strip():
                    continue
                try:
                    r = json.loads(ln)
                except ValueError:
                    r = None
                if not isinstance(r, dict) or r.get("class") not in ROW_CLASSES:
                    bad_line = bad_line or "checks.jsonl line %d is not a verdict row" % n
                elif r.get("run") == res["run"]:
                    m["rows"].append(r)
        except (OSError, ValueError) as e:
            bad_line = "checks.jsonl is unreadable: %s" % e
    have = {k: sum(1 for r in m["rows"] if r["class"] == k) for k in ROW_CLASSES}
    want = res.get("counts") if isinstance(res.get("counts"), dict) else {}
    if res.get("state") != "ended":
        m["why_not_final"] = ("matrix-result.json says state=%r - the run did not end through its exit trap, so its "
                              "counts are not final" % res.get("state"))
    elif bad_line:
        m["why_not_final"] = bad_line
    elif have != {k: want.get(k) for k in ROW_CLASSES}:
        m["why_not_final"] = ("the rows of run %s count %r and the run's own counters say %r (rows_lost=%r)"
                              % (res["run"], have, want, res.get("rows_lost")))
    else:
        m["final"] = True
    return m


def matrix_complete(m: dict) -> tuple[str, str]:
    """("complete" | "incomplete" | "missing", one line of the facts that rests on)."""
    res = m["result"]
    if not res:
        return "missing", m["why_not_final"] or "no readable matrix-result.json"
    c = res.get("counts") if isinstance(res.get("counts"), dict) else {}
    desc = "run %s state=%s finished=%s exit_code=%s PASS=%s FAIL=%s INVALID=%s cell_running=%s abort_line=%r" % (
        res.get("run"), res.get("state"), res.get("finished"), res.get("exit_code"), c.get("PASS"), c.get("FAIL"),
        c.get("INVALID"), res.get("cell_running"), res.get("abort_line"))
    # FROM THE FIELDS, not from the summary alone: `complete` is the writer's own conjunction of the three, and a
    # document whose summary contradicts its parts is not believed.
    done = res.get("state") == "ended" and res.get("finished") is True and not res.get("abort_line")
    if (res.get("complete") is True) != done:
        return "incomplete", desc + " [complete=%r CONTRADICTS these fields - not believed]" % res.get("complete")
    return ("complete" if done else "incomplete"), desc


def cell_classes(m: dict, cells: list[str]) -> tuple[dict[str, dict], list[str]]:
    """Each planned cell's class from the rows: {cell: {class, pass_lines, product_fail_lines, instrument_fail_lines}}."""
    notes: list[str] = []
    if not m["present"]:
        notes.append("%s - no matrix cell has a verdict; this tool reads no log text" % m["why_not_final"])
        return {c: {"class": "not-run", "pass_lines": 0, "product_fail_lines": [], "instrument_fail_lines": []} for c in cells}, notes
    if not m["final"]:
        why = m["why_not_final"]
        notes.append("matrix rows UNUSABLE - %s; every matrix cell is instrument-fail" % why)
        return {c: {"class": "instrument-fail", "pass_lines": 0, "product_fail_lines": [], "instrument_fail_lines": [why[:200]]}
                for c in cells}, notes
    word, desc = matrix_complete(m)
    if word != "complete":
        notes.append("the matrix did not complete (%s) - cells without rows did not run" % desc)
    out: dict[str, dict] = {}
    for c in cells:
        mine = [r for r in m["rows"] if r.get("cell") == c]
        graded = [r for r in mine if r.get("kind") in GRADING_KINDS]
        product = [r for r in graded if r["class"] == "FAIL"]
        instrument = [r for r in graded if r["class"] == "INVALID"]
        npass = sum(1 for r in graded if r["class"] == "PASS")
        cls = "product-fail" if product else "instrument-fail" if instrument else "pass" if npass else "not-run"
        out[c] = {"class": cls, "pass_lines": npass, "product_fail_lines": [str(r.get("text"))[:200] for r in product][:5],
                  "instrument_fail_lines": [str(r.get("text"))[:200] for r in instrument][:5]}
        ungraded = [r for r in mine if r.get("kind") not in GRADING_KINDS]
        if ungraded:
            out[c]["not_graded"] = ["%s: %s" % (r.get("kind"), str(r.get("text"))[:200]) for r in ungraded][:5]
    return out, notes


def write_feature_result(campdir: str, test: str, exit_code: int, ledger: str = "", out: str = "", attempt: str = "") -> str:
    """<campdir>/feature-<test>.json: what one feature test left, as fields. Whole and atomically; returns the path."""
    doc = {"schema": 1, "group": "feature-%s" % test, "test": test, "exit_code": int(exit_code), "ledger": ledger or None,
           "out": out or None, "attempt": attempt or None, "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    path = os.path.join(campdir, "feature-%s.json" % test)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    os.replace(path + ".tmp", path)
    return path


def read_groups(campdir: str) -> list[dict]:
    """The campaign's groups - the matrix when it left a result, and one per feature-<test>.json - each with clean,
    why, its cells, and for the matrix its failures (by cell) and the cells that passed."""
    groups: list[dict] = []
    m = read_matrix(campdir)
    if m["present"]:
        res = m["result"]
        planned = [str(c) for c in res.get("cells_planned")] if isinstance(res.get("cells_planned"), list) else []
        classes, _ = cell_classes(m, planned)
        word, desc = matrix_complete(m)
        failures = [r for r in m["rows"] if r["class"] != "PASS"] if m["final"] else []
        passed = sorted(c for c in planned if classes[c]["class"] == "pass")
        unpassed = sorted(c for c in planned if classes[c]["class"] != "pass")
        if not m["final"]:
            clean, why = False, m["why_not_final"]
        elif word != "complete":
            clean, why = False, "the matrix did not complete: %s" % desc
        elif failures:
            clean, why = False, "%d FAIL and %d INVALID row(s)" % (sum(1 for r in failures if r["class"] == "FAIL"),
                                                                   sum(1 for r in failures if r["class"] == "INVALID"))
        elif not planned:
            clean, why = False, "the result names no planned cell - a run that graded nothing is not a clean one"
        elif unpassed:
            clean, why = False, "planned cell(s) with no passing check: %s" % " ".join(unpassed)
        else:
            clean, why = True, "complete, %d PASS row(s), 0 FAIL, 0 INVALID, every planned cell has a passing check" % len(m["rows"])
        groups.append({"group": "matrix", "kind": "matrix", "clean": clean, "why": why, "final": m["final"],
                       "finished": res.get("finished") is True, "cells": planned, "passed_cells": passed,
                       "failures": [{"cell": str(r.get("cell") or ""), "class": r["class"], "kind": r.get("kind"),
                                     "text": str(r.get("text"))[:400]} for r in failures],
                       "source": os.path.join(m["dir"], "matrix-result.json")})
    for p in sorted(glob.glob(os.path.join(campdir, "feature-*.json"))):
        name = os.path.basename(p)[:-len(".json")]
        try:
            d = json.load(open(p, encoding="utf-8"))
            rc = d.get("exit_code") if isinstance(d, dict) else None
            good = isinstance(d, dict) and d.get("group") == name and isinstance(rc, int) and not isinstance(rc, bool)
        except (OSError, ValueError):
            good, rc = False, None
        if good:
            clean, why = rc == 0, "the feature test exited %d" % rc
        else:
            clean, why = False, "%s is not a readable feature result naming group %s" % (os.path.basename(p), name)
        groups.append({"group": name, "kind": "feature", "clean": clean, "why": why, "final": good, "cells": [name],
                       "passed_cells": [name] if clean else [], "failures": [], "source": p,
                       "exit_code": rc if good else None})
    return groups


def _supersede(failed: list[dict], reruns: list[str]) -> tuple[str, list[dict], list[str]]:
    """May these failed groups be superseded by these re-run campaigns? -> (refusal or "", superseded, cells re-run).

    Owner-approved 2026-10-03 ("rerun two missing cells"). A failed group is superseded only when ALL of these hold:
      * it is the matrix group, its rows are final, and the matrix REACHED ITS FOOTER (finished) - one that ended before
        it never ran its campaign-level checks and must run again;
      * at least one failed CHECK in it names a cell - a group that failed only through cells that never ran, or a dead
        subject, has nothing to supersede;
      * every failure names a cell;
      * every cell a failed row names, and every planned cell with no passing check (so a cell that never ran too),
        passed in a re-run campaign whose every group is clean.
    A failed FEATURE group is superseded only when its result is readable, its test exited 2 - it could not measure
    the product (tools/release-acceptance.sh: every feature test exits 2 for exactly that, and the coverage receipt
    reads 2 as instrument-fail) - and the same group passed in a re-run campaign whose every group is clean
    (docs/ADR-acceptance.md section 7: a measured verdict replaces an instrument-fail; a product-fail stays). Any other
    failed feature group - a product failure - keeps the refusal.
    Anything else keeps the record FAILED.
    """
    passed_by: dict[str, str] = {}
    for d in reruns:
        rg = read_groups(d)
        if not rg:
            return "re-run campaign %s holds no group result" % d, [], []
        for g in rg:
            if not g["clean"]:
                return "re-run group %s in %s is not clean: %s" % (g["group"], d, g["why"]), [], []
            for c in g["passed_cells"]:
                passed_by[c] = os.path.abspath(d)
    sup: list[dict] = []
    for g in failed:
        if g["kind"] == "feature":
            if not (g["final"] and g.get("exit_code") == 2):
                return ("%s failed (%s) - a feature test is superseded by a re-run only when it exited 2 (could not "
                        "measure); a product failure stays" % (g["group"], g["why"])), [], []
            if g["group"] not in passed_by:
                return "%s exited 2 in %s and no clean re-run passed it" % (g["group"], g["source"]), [], []
            sup.append({"cell": g["group"], "failed_in": g["source"], "failure": g["why"][:400],
                        "passed_in": passed_by[g["group"]]})
            continue
        if g["kind"] != "matrix":
            return ("%s failed (%s) - only a failed matrix cell or an instrument-failed feature test can be superseded "
                    "by a re-run" % (g["group"], g["why"])), [], []
        if not g["final"]:
            return "the matrix group cannot be superseded - its rows are not final: %s" % g["why"], [], []
        if not g["finished"]:
            return ("the matrix group cannot be superseded - the run ended before its footer, so its campaign-level checks "
                    "never ran and the matrix must run again (%s)" % g["why"]), [], []
        if not any(f["kind"] == "check" for f in g["failures"]):
            return ("the matrix group is not clean (%s) and no failed check names a cell - nothing to supersede" % g["why"]), [], []
        need: dict[str, str] = {}
        for f in g["failures"]:
            if not f["cell"]:
                return "a matrix failure names no cell: %s" % f["text"][:160], [], []
            need.setdefault(f["cell"], "%s: %s" % (f["class"], f["text"]))
        for c in g["cells"]:
            if c not in g["passed_cells"]:
                need.setdefault(c, "planned and has no passing check")
        for c in sorted(need):
            if c not in passed_by:
                return "cell %s failed or did not run in %s and no clean re-run covers it" % (c, g["source"]), [], []
            sup.append({"cell": c, "failed_in": g["source"], "failure": need[c][:400], "passed_in": passed_by[c]})
    return "", sup, sorted(passed_by)


def record_facts(campdir: str, reruns: list[str]) -> dict:
    """What tools/record-acceptance.sh records: {groups, clean, failed, cells, superseded, rerun_refused}."""
    groups = read_groups(campdir)
    failed = [g for g in groups if not g["clean"]]
    cells = sorted({c for g in groups for c in g["cells"]})
    out = {"groups": groups, "clean": len(groups) - len(failed), "failed": len(failed), "cells": cells, "superseded": [],
           "rerun_refused": ""}
    if failed and reruns:
        why, sup, recells = _supersede(failed, reruns)
        if why:
            out["rerun_refused"] = why
        else:
            out.update(superseded=sup, clean=len(groups), failed=0, cells=sorted(set(cells) | set(recells)))
    return out


def read_acceptance(workdir: str) -> dict | None:
    """<workdir>/acceptance.json as tools/release-acceptance.sh last wrote it, or None."""
    try:
        d = json.load(open(os.path.join(workdir, "acceptance.json"), encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("matrix-complete")
    p.add_argument("campaign")
    p = sub.add_parser("record-facts")
    p.add_argument("campaign")
    p.add_argument("--rerun", action="append", default=[])
    p = sub.add_parser("feature-result")
    p.add_argument("campaign")
    p.add_argument("test")
    p.add_argument("exit_code", type=int)
    p.add_argument("--ledger", default="")
    p.add_argument("--out", default="")
    p.add_argument("--attempt", default="")
    a = ap.parse_args(argv)
    if a.cmd == "matrix-complete":
        word, desc = matrix_complete(read_matrix(a.campaign))
        print(desc)
        return {"complete": 0, "incomplete": 1}.get(word, 2)
    if a.cmd == "record-facts":
        facts = record_facts(a.campaign, a.rerun)
        print(json.dumps(facts, indent=1))
        return 0 if facts["groups"] else 2
    print(write_feature_result(a.campaign, a.test, a.exit_code, a.ledger, a.out, a.attempt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
