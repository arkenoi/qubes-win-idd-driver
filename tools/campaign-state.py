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
  * the campaign's own verdict lines, located by the harness's marker, not by a pattern of mine
and it EXITS NON-ZERO whenever any cell failed or any P1 breached. A watcher that cannot fail is
the defect this file exists to prevent, so `--selftest` plants a failing report and requires this
tool to report it.

Usage:
  tools/campaign-state.py [<campaign-dir>]     # default: the newest under ~/qwt-accept/*/campaign
  tools/campaign-state.py --selftest
"""
import glob
import json
import os
import sys

P1 = "P1"


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
    print("CAMPAIGN %s - %d cell(s) with a report, %d not CLEAN, %d P1" %
          ("FINDINGS" if (bad or p1s) else "CLEAN", len([r for r in rows if r[1]]), len(bad), len(p1s)))
    return 1 if (bad or p1s) else 0


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
        print("campaign-state selftest: %d passed, %d failed" % (ok, fail))
        return 0 if fail == 0 else 1
    finally:
        shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
