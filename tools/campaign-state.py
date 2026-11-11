#!/usr/bin/env python3
"""campaign-state.py - the authoritative state of a running or finished acceptance campaign.

WHY THIS EXISTS. On 2026-10-15 a campaign had FOUR failed cells and THREE P1 breaches - two
user-visible "task failed" toasts and a clock correction of 960 s - and they were reported to the
owner as "0 FAIL, campaign healthy", four times in a row. Nothing was wrong with the sweep: it had
returned `rc=1 status=FINDINGS` for every one of those cells and listed the P1s. What was wrong was
the WATCHER - a hand-written grep, `^\\[[0-9:]+\\] (FAIL|no) `, against a line that actually reads
`[20:00:38] [ERROR] FAIL  win10-clean: ...`. The pattern matched nothing and silence was read as
success. The owner found the failures by asking a question.

So this reads STRUCTURED ARTIFACTS, never log prose:
  * every <cell>-guestlogs/report.json  - the sweep's own status, rc and breach list, with severity
  * what the run wrote about ITSELF as JSON, through tools/acceptance_json.py (the one reader):
    the driver's acceptance.json (phase, result, each feature test's exit code), the matrix's
    matrix-result.json (state, the cell running, complete or not) and its rows in checks.jsonl
    (counts by class per cell, and every FAIL and INVALID check's own text). Until 2026-11-11 the
    second bullet here promised "the campaign's own verdict lines" and no code read them: a quiet
    stdout was taken for a stall while seven cells passed, and `grep -c INVALID` counted the line
    that names the class. Owner: "we were intended to stop grepping and make json parser instead".
and it EXITS NON-ZERO whenever any cell failed or any P1 breached - a failing matrix row counts. A
watcher that cannot fail is the defect this file exists to prevent, so `--selftest` plants a
failing report and requires this tool to report it.

Usage:
  tools/campaign-state.py [<campaign-dir>]     # default: the newest under ~/qwt-accept/*/campaign
  tools/campaign-state.py --selftest
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance_json  # noqa: E402 - the one reader of a campaign's JSON

P1 = "P1"


def run_facts(campdir):
    """What the run wrote about itself as JSON -> (printable lines, number of failing matrix rows).

    Every line is a field read through acceptance_json; nothing is matched in a log. Row counts are
    shown even while the matrix is running (they are what has been written so far); a CLASS is shown
    only once the rows are final, because nothing may be classed from a run that has not ended.
    """
    lines = []
    acc = acceptance_json.read_acceptance(os.path.dirname(os.path.abspath(campdir)))
    if acc:
        dead = acc.get("state") == "running" and not os.path.exists("/proc/%s" % acc.get("pid"))
        lines.append("  driver: state=%s phase=%s result=%s exit_code=%s attempt=%s written=%s pid=%s%s" % (
            acc.get("state"), acc.get("phase"), acc.get("result"), acc.get("exit_code"), acc.get("attempt"),
            acc.get("written_utc"), acc.get("pid"),
            "  <- NO SUCH PROCESS: the driver died without writing its end" if dead else ""))
        if acc.get("stopped"):
            lines.append("  driver stopped at %s: %s" % (acc["stopped"].get("at"), acc["stopped"].get("why")))
        for t in (acc.get("features") or {}).get("tests") or []:
            lines.append("    feature %-28s exit_code=%s" % (t.get("name"), t.get("exit_code")))
    else:
        lines.append("  driver: no acceptance.json beside this campaign directory")
    m = acceptance_json.read_matrix(campdir)
    word, desc = acceptance_json.matrix_complete(m)
    lines.append("  matrix: %s - %s" % (word.upper(), desc))
    failing = [r for r in m["rows"] if r["class"] != "PASS"]
    if m["result"]:
        res = m["result"]
        planned = [str(c) for c in res.get("cells_planned")] if isinstance(res.get("cells_planned"), list) else []
        if not m["final"]:
            lines.append("  matrix rows are NOT FINAL (%s) - counts below are what has been written so far" % m["why_not_final"])
        classes = acceptance_json.cell_classes(m, planned)[0] if m["final"] else {}
        for c in planned + [""]:
            mine = [r for r in m["rows"] if (r.get("cell") or "") == c]
            if not c and not mine:
                continue
            n = {k: sum(1 for r in mine if r["class"] == k) for k in acceptance_json.ROW_CLASSES}
            lines.append("    %-18s PASS=%-3d FAIL=%-3d INVALID=%-3d %s%s" % (
                c or "(campaign-level)", n["PASS"], n["FAIL"], n["INVALID"], classes.get(c, {}).get("class", ""),
                "  <- running" if c and c == res.get("cell_running") and res.get("state") == "running" else ""))
        for r in failing:
            lines.append("    [%s] %s: %s" % (r["class"], r.get("cell") or "(campaign-level)", str(r.get("text"))[:200]))
    return lines, len(failing)


def find_campaign(arg=None):
    if arg:
        return arg
    cands = sorted(glob.glob(os.path.expanduser("~/qwt-accept/*/campaign")), key=os.path.getmtime)
    return cands[-1] if cands else None


def cell_reports(campdir):
    """Every per-cell sweep report, as (cell, dict-or-None, why-missing)."""
    out = []
    for d in sorted(glob.glob(os.path.join(campdir, "matrix", "*-guestlogs"))):
        cell = os.path.basename(d)[: -len("-guestlogs")]
        rp = os.path.join(d, "report.json")
        if not os.path.exists(rp):
            nfiles = sum(len(f) for _, _, f in os.walk(d))
            out.append((cell, None, "no report.json (%d file(s) pulled) - this cell has NO sweep verdict" % nfiles))
            continue
        try:
            out.append((cell, json.load(open(rp, encoding="utf-8")), None))
        except Exception as e:  # a truncated report is missing data, not a pass
            out.append((cell, None, "report.json unreadable: %s" % e))
    return out


def summarise(campdir):
    rows = cell_reports(campdir)
    p1s, bad = [], []
    for cell, rep, why in rows:
        if rep is None:
            bad.append((cell, why))
            continue
        status = rep.get("status", "?")
        br = rep.get("breaches") or []
        hi = [b for b in br if b.get("severity") == P1]
        for b in hi:
            p1s.append((cell, b.get("metric"), b.get("value"), b.get("max"),
                        ((b.get("jev") or {}).get("choice"), (b.get("jev") or {}).get("confidence"))))
        if status != "CLEAN" or rep.get("rc"):
            bad.append((cell, "status=%s rc=%s breaches=%d (P1 %d)" % (status, rep.get("rc"), len(br), len(hi))))
    return rows, p1s, bad


def main(argv):
    if "--selftest" in argv:
        return selftest()
    campdir = find_campaign(argv[1] if len(argv) > 1 else None)
    if not campdir or not os.path.isdir(campdir):
        print("campaign-state: no campaign directory found", file=sys.stderr)
        return 2
    rows, p1s, bad = summarise(campdir)
    print("campaign %s" % campdir)
    facts, mfail = run_facts(campdir)
    for ln in facts:
        print(ln)
    if not rows:
        print("  no cell has produced a sweep report yet")
    for cell, rep, why in rows:
        if rep is None:
            print("  %-18s MISSING  %s" % (cell, why))
        else:
            br = rep.get("breaches") or []
            print("  %-18s %-10s rc=%s  breaches=%d (P1 %d)" %
                  (cell, rep.get("status"), rep.get("rc"), len(br),
                   len([b for b in br if b.get("severity") == P1])))
    if p1s:
        print("P1 BREACHES (%d):" % len(p1s))
        for cell, m, v, mx, (jc, jconf) in p1s:
            print("  [P1] %-18s %-28s = %s (max %s)  Jev: %s %s" % (cell, m, v, mx, jc, jconf))
    # NO REPORT IS NOT A CLEAN REPORT. The first version printed "CAMPAIGN CLEAN - 0 cell(s) with
    # a report" while the campaign was still on its first cell, which is the exact shape this file
    # exists to remove: a zero that reads as reassurance because nothing was measured. A campaign
    # with no cell verdict yet has no verdict, and says so.
    have = len([r for r in rows if r[1]])
    if have == 0:
        print("CAMPAIGN NO-VERDICT - no cell has produced a sweep report yet; this is not a pass")
        return 2
    print("CAMPAIGN %s - %d cell(s) with a report, %d not CLEAN, %d P1, %d failing matrix row(s)" %
          ("FINDINGS" if (bad or p1s or mfail) else "CLEAN", have, len(bad), len(p1s), mfail))
    return 1 if (bad or p1s or mfail) else 0


def selftest():
    """SEEN TO FAIL. A watcher that cannot report a failure is the defect this file prevents."""
    import tempfile
    import shutil
    t = tempfile.mkdtemp(prefix="campstate-")
    try:
        ok = 0
        fail = 0

        def ck(name, cond, detail=""):
            nonlocal ok, fail
            if cond:
                print("ok   %s" % name); ok += 1
            else:
                print("FAIL %s   %s" % (name, detail)); fail += 1

        m = os.path.join(t, "matrix")
        os.makedirs(os.path.join(m, "clean-guestlogs"))
        os.makedirs(os.path.join(m, "broken-guestlogs"))
        os.makedirs(os.path.join(m, "nolog-guestlogs"))
        json.dump({"status": "CLEAN", "rc": 0, "breaches": []},
                  open(os.path.join(m, "clean-guestlogs", "report.json"), "w"))
        json.dump({"status": "FINDINGS", "rc": 1, "breaches": [
            {"metric": "dom0_loud_failures", "value": 2, "max": 0, "severity": "P1",
             "jev": {"choice": "defect", "confidence": 0.63}},
            {"metric": "error_lines_undeclared", "value": 19, "max": 0, "severity": "P2"}]},
            open(os.path.join(m, "broken-guestlogs", "report.json"), "w"))
        # nolog-guestlogs gets NO report.json: the win10-appvm case, where no log volume was attached
        rows, p1s, bad = summarise(t)
        ck("the clean cell is not counted as bad", not any(c == "clean" for c, _ in bad))
        ck("the P1 cell is reported", any(c == "broken" for c, _ in bad))
        ck("its P1 is listed with the metric", any(x[1] == "dom0_loud_failures" for x in p1s),
           "p1s=%r" % (p1s,))
        ck("the P2 is NOT promoted to P1", len(p1s) == 1, "p1s=%r" % (p1s,))
        ck("a cell with NO report is MISSING, never a pass", any(c == "nolog" for c, _ in bad))
        rc = 1 if (bad or p1s) else 0
        ck("and the tool exits non-zero", rc == 1)
        # and a wholly clean campaign exits zero, or this could never report success either
        shutil.rmtree(os.path.join(m, "broken-guestlogs"))
        shutil.rmtree(os.path.join(m, "nolog-guestlogs"))
        rows, p1s, bad = summarise(t)
        ck("a wholly clean campaign exits zero", not bad and not p1s)
        # SEEN TO FAIL: an empty campaign must not read as a pass. The first version printed
        # "CAMPAIGN CLEAN - 0 cell(s) with a report" on a campaign that had not graded anything.
        shutil.rmtree(os.path.join(m, "clean-guestlogs"))
        rows2, p1s2, bad2 = summarise(t)
        ck("an EMPTY campaign is not clean - it has no verdict at all",
           len([r for r in rows2 if r[1]]) == 0 and not bad2 and not p1s2)
        print("campaign-state selftest: %d passed, %d failed" % (ok, fail))
        return 0 if fail == 0 else 1
    finally:
        shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
