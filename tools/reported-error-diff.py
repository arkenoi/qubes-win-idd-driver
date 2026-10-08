#!/usr/bin/env python3
"""reported-error-diff.py - OF THE ERRORS THE REPORTER SAW, WHICH DOES THIS RUN SHOW?

Owner, 2026-10-08: "let it report and analyze with jev what do we see of these errors".

tools/log-sweep.py already asks Jev about every signature a run produces (defect / expected / noise /
insufficient-evidence). This asks the other question, the one a sweep cannot: of the specific errors
THE REPORTER photographed, which are present here, which are gone - and, for each one that is gone,
whether this run could have produced it at all.

THAT LAST PART IS THE WHOLE POINT, and it is the trap this project has fallen into before: "absence
of a regression is not evidence of intended behaviour" (CLAUDE.md). Every one of his errors needs a
TRIGGERING CONDITION before it can fire:

  QGADESKSTUCK        needs a secure desktop up for over 30 s. A guest that autologs in promptly
                      never produces it, and its absence then says nothing about any fix.
  QGADESLICEDOWN      needs the broker to be absent or not ready for over 30 s.
  QGANOTIFBRIDGEEXIT  needs a bridge instance to exit - and, for the case fixed on 2026-10-08, a
                      SECOND launch against a live bridge, or a console session change.
  the WU scan death   needs a scan to run under a previous pass that was cut off in THIS boot.

So the code counts occurrences AND gathers the evidence for whether the condition arose; Jev judges
the only part that is a judgement - whether a zero means FIXED or merely NOT EXERCISED. Counting and
matching stay here (owner: differentials are code, not agents); exactly one Jev call is made.

    tools/reported-error-diff.py <logsdir-or-file>... [--label 4.3.35] [--out report.json]
                                 [--no-jev]

Exit 0 = it ran. Exit 2 = it could not run (no inputs, or Jev did not answer and --no-jev was not
given) - never confused with "nothing was found", which is a RESULT and exits 0.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# HIS ERRORS, from the screenshots in forum 42717 posts 167 and 175 on our released 4.3.35, each tied
# to the log tag its dom0 notification names. The notification TEXT is what he saw; the TAG is what a
# log carries, and the tag is what we can count. Keep both: a text that changes while the tag does
# not is still the same error to him.
REPORTED = [
    {
        "id": "signin-stuck",
        "tag": "QGADESKSTUCK",
        "text": "The guest is waiting at the sign-in or lock screen",
        "condition": "a secure desktop (Winlogon) up for more than 30 s",
        "condition_tags": ["secure-desktop ENTERED", "QGADESK secure-desktop"],
        "ours": False,
        "note": "a TRUE report of a real condition on his guest, not a defect to remove; it is here so a run that "
                "reproduces his conditions can say whether the condition itself still arises",
    },
    {
        "id": "broker-down-shadow",
        "tag": "QGADESLICEDOWN",
        "text": "The notification and menu capture helper is not running",
        "condition": "the broker absent or not ready for over 30 s",
        "condition_tags": ["QGABROKERMISSING", "QGABROKERDIED", "QGADESLICEDOWN"],
        "ours": True,
        "note": "on his guest this fired ALONGSIDE the sign-in report, which is the shadow it should no longer be: "
                "while the input desktop is secure nothing can capture, so the sign-in report owns the condition",
    },
    {
        "id": "bridge-death",
        "tag": "QGANOTIFBRIDGEEXIT",
        "text": "The notification bridge exited unexpectedly - a clean exit nobody asked for, exit code 0",
        "condition": "a bridge instance exiting at all",
        "condition_tags": ["NOTIFBRIDGE", "QGANOTIFNOTREADY", "QGANOTIFSESSION"],
        "ours": True,
        "note": "FOUR of these in one of his boots, pids 8772/6796/10168/1232, deaths 1/2/4/6. Three ran 0:00:00 "
                "(the singleton-duplicate case) and one ran 0:00:20 (one of the other intended departures)",
    },
    {
        "id": "wu-scan-failed",
        "tag": "QubesWindowsUpdateScan",
        "text": "The Windows Update scan task failed - incorrect function, result 0x80070001",
        "condition": "a scheduled scan running under a previous pass cut off in THIS boot",
        "condition_tags": ["QWTUPDSTATEUNKNOWN", "GUARD:scanreadonly", "0x80070001"],
        "ours": True,
        "note": "the boot+2min scan landing under the installer's own cut-off pass; it refused and exited 1, which "
                "Task Scheduler records as 0x80070001",
    },
]

# What a run must show for the fixes to have been EXERCISED rather than merely not triggered. Counted
# here, handed to Jev as evidence - never interpreted here.
EXERCISE = {
    "bridge-death": ["already holds the singleton", "an intended departure", "QTB_EXIT_ALREADY_RUNNING", "exit-reason"],
    "broker-down-shadow": ["QGADESLICEDOWN not reported", "QGADESKSTUCK"],
    "wu-scan-failed": ["a scan only reads", "GUARD:scanreadonly", "scan: "],
    "signin-stuck": ["secure desktop left", "QGADESK secure-desktop"],
}


def read_text(path):
    """Guest logs are not reliably UTF-8 (German installs carry cp1252 in places), and a decode error
    must never silently drop a line that names an error - that exact failure mode is on record."""
    with open(path, "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def gather(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for dirpath, _dirs, names in os.walk(p):
                for n in sorted(names):
                    fp = os.path.join(dirpath, n)
                    if os.path.getsize(fp) > 0:
                        files.append(fp)
        elif os.path.isfile(p):
            files.append(p)
    return files


def count_in(files, needles):
    """Per-needle occurrence counts plus up to three example lines each, with the file they came from.
    Case-sensitive on purpose: these are log TAGS, not prose."""
    hits = {n: {"count": 0, "examples": []} for n in needles}
    for fp in files:
        try:
            txt = read_text(fp)
        except Exception as e:                                   # pragma: no cover
            print("WARN could not read %s: %s" % (fp, e), file=sys.stderr)
            continue
        for line in txt.splitlines():
            for n in needles:
                if n in line:
                    h = hits[n]
                    h["count"] += 1
                    if len(h["examples"]) < 3:
                        h["examples"].append({"file": os.path.basename(fp), "line": line.strip()[:300]})
    return hits


def build_state(label, files, rows):
    L = []
    L.append("WHAT THIS RUN IS: %s" % label)
    L.append("Logs scanned: %d file(s): %s" % (len(files), ", ".join(sorted({os.path.basename(f) for f in files}))[:400]))
    L.append("")
    L.append("THE REPORTER'S ERRORS (forum 42717, posts 167 and 175, photographed on our released 4.3.35),")
    L.append("each with what THIS run shows. Counts are exact matches on the log tag, made in code.")
    L.append("")
    for r in rows:
        L.append("ITEM %s" % r["id"])
        L.append("  his notification: %s" % r["text"])
        L.append("  log tag counted : %s" % r["tag"])
        L.append("  ours to fix     : %s" % ("yes" if r["ours"] else "NO - a true report of a real condition"))
        L.append("  note            : %s" % r["note"])
        L.append("  OCCURRENCES HERE: %d" % r["count"])
        for ex in r["examples"]:
            L.append("      %s: %s" % (ex["file"], ex["line"]))
        L.append("  COULD IT HAVE FIRED? the triggering condition is: %s" % r["condition"])
        for t, c in sorted(r["condition_counts"].items()):
            L.append("      evidence '%s': %d occurrence(s)" % (t, c))
        for t, c in sorted(r["exercise_counts"].items()):
            L.append("      fix-exercised marker '%s': %d occurrence(s)" % (t, c))
        L.append("")
    L.append("THE TRAP THIS EXISTS TO AVOID, stated so it is in front of the judge: absence of an error is not")
    L.append("evidence that it was fixed. Every one of these needs its triggering condition before it can appear,")
    L.append("so a zero on a run where the condition never arose says nothing about any fix. A zero is evidence")
    L.append("only when the condition IS evidenced and the error still did not appear.")
    return "\n".join(L)


def build_rubric(rows):
    q = {}
    for r in rows:
        q[r["id"]] = {
            "type": "choice",
            "instructions": {"judge":
                "From the state under 'ITEM %s' ONLY: what does this run show about the reporter's error '%s'? "
                "Do not treat a zero count as a fix unless the state evidences that the triggering condition "
                "arose in this run. Prefer 'insufficient-evidence' over a guess." % (r["id"], r["text"])},
            "criteria": {
                "still-present": "the error appears in this run",
                "gone-and-condition-arose": "the error does not appear AND the state evidences that its triggering condition arose, so this run exercised it",
                "absent-but-not-exercised": "the error does not appear, but nothing shows its triggering condition arose - so this run says nothing about whether it is fixed",
                "insufficient-evidence": "the state cannot settle it",
            }}
    q["overall"] = {
        "type": "choice",
        "instructions": {"judge":
            "Taking the items together: what may be claimed about this run as a whole with respect to the "
            "reporter's errors? Judge only from the state."},
        "criteria": {
            "noise-reproduced": "this run reproduces the reporter's error noise",
            "noise-gone-and-exercised": "the noise is gone AND the conditions that produce it arose, so the run demonstrates the fixes",
            "noise-absent-untested": "the noise is absent but the conditions did not arise, so nothing is demonstrated",
            "mixed": "some items are demonstrated and others were not exercised",
            "insufficient-evidence": "the state cannot settle it",
        }}
    return {"questions": q}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="decoded log directory/directories, or individual log files")
    ap.add_argument("--label", default="(unlabelled run)", help="what this run is, e.g. '4.3.35 on his environment'")
    ap.add_argument("--out", help="write the full result as JSON here")
    ap.add_argument("--no-jev", action="store_true", help="count only; do not ask for a judgement")
    a = ap.parse_args()

    files = gather(a.paths)
    if not files:
        # MISSING DATA FAILS: an empty input must never read as "no errors found".
        print("reported-error-diff: no readable log files under %s - nothing ran" % ", ".join(a.paths))
        return 2

    rows = []
    for spec in REPORTED:
        hits = count_in(files, [spec["tag"]])
        cond = count_in(files, spec["condition_tags"])
        exer = count_in(files, EXERCISE.get(spec["id"], []))
        r = dict(spec)
        r["count"] = hits[spec["tag"]]["count"]
        r["examples"] = hits[spec["tag"]]["examples"]
        r["condition_counts"] = {k: v["count"] for k, v in cond.items()}
        r["exercise_counts"] = {k: v["count"] for k, v in exer.items()}
        rows.append(r)

    print("RUN: %s   (%d log file(s))" % (a.label, len(files)))
    for r in rows:
        cond_total = sum(r["condition_counts"].values())
        print("  %-20s %-24s seen=%-4d condition-evidence=%-4d %s"
              % (r["id"], r["tag"], r["count"], cond_total, "" if r["ours"] else "(not ours to fix)"))

    result = {"label": a.label, "files": len(files), "items": rows}
    if not a.no_jev:
        state = build_state(a.label, files, rows)
        workdir = os.path.join(ROOT, "scratchpad")
        os.makedirs(workdir, exist_ok=True)
        rp = os.path.join(workdir, "jev-reported-error-rubric.json")
        sp = os.path.join(workdir, "jev-reported-error-state.txt")
        apath = os.path.join(workdir, "jev-reported-error-answers.json")
        with open(rp, "w", encoding="utf-8") as f:
            json.dump(build_rubric(rows), f, indent=1)
        with open(sp, "w", encoding="utf-8") as f:
            f.write(state)
        p = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "jev.py"), rp, sp, "--out", apath],
                           capture_output=True, text=True)
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        if p.returncode != 0:
            # Exit 2 from jev.py means the INSTRUMENT did not run. Never paper over it.
            print("reported-error-diff: the judge did not answer (rc=%d) - no verdict, and this is not a pass"
                  % p.returncode)
            if a.out:
                result["jev"] = {"rc": p.returncode, "answers": None}
                with open(a.out, "w", encoding="utf-8") as f:
                    json.dump(result, f, indent=1, default=str)
            return 2
        try:
            with open(apath, encoding="utf-8") as f:
                result["jev"] = {"rc": 0, "answers": json.load(f)}
        except Exception:
            result["jev"] = {"rc": 0, "answers": None}

    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1, default=str)
        print("written: %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
