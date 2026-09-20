#!/usr/bin/env python3
"""wu-pass-judge.py - did each Windows Update PASS tell dom0 the truth, or did it die silently?

    tools/wu-pass-judge.py --agent-log AGENT.LOG [--dom0-reported N] [--limit N] [--no-judge] [--json out]

Input: the guest's updater agent log (C:\\ProgramData\\Qubes\\wu\\agent.log), as captured. This is the
WORKFLOW level - one line per step of each pass - and it is the level at which dom0's view of a guest
goes wrong. tools/wu-log-judge.py is the level below it (the decoded WU engine log inside one scan);
the two are complementary and neither substitutes for the other.

WHY THIS EXISTS. Updates here are dom0-owned: guest auto-update is off and dom0 drives every install,
so dom0's `updates-available` is only as true as the last pass that bothered to report. A pass that
throws before it reports leaves dom0 holding the PREVIOUS number with nothing anywhere saying so -
and Qube Manager then shows a guest as up to date. That is the shape of the field failure the
register carries (the updater "claimed that no updates were there"), and it is invisible in any
single-pass view: you only see it by reading every pass in a log and asking which ones ended without
speaking to dom0.

CODE (load-bearing, fixed strings the updater emits - counted over EVERY pass, never sampled):
  passes        segments starting at "VM class (live from qubesdb)" - one per agent invocation.
  reported      a pass that reached "reported N update(s) to dom0 qubes.NotifyUpdates".
  errored       a pass whose last substantive line is "ERROR: ...".
  noop          a pass that declined by design ("Doing nothing" - e.g. a StandaloneVM, which is
                template-only by design and is NOT a failure).
  SILENT        errored AND never reported: dom0 was left holding a stale number. Any is a FAIL.
  contradictory reported AND errored in the same pass: the number dom0 got is not trustworthy. FAIL.
  --dom0-reported N, when given, is what dom0 actually holds; it must equal the last reported value,
  or the guest and dom0 disagree and that is a FAIL.

JEV (semantic; the standing project rule is to delegate judgments and keep matching in code): the
updater's error vocabulary is open - an HRESULT, a relay refusal, a CBS state, a locale-specific
exception string - so "was this error FINAL or TRANSIENT, and was dom0 left stale" is not a fixed
string match. Each errored pass is rubric-graded on its own lines. A pass graded final-and-silent is
corroboration of the code FAIL; a pass graded transient-retry while the code says SILENT is a
CONFLICT and is reported as such rather than silently resolved either way. Any grade with
confidence < 0.7 is flagged - a low-confidence grade names what still has to be read by hand.

Exit 0 PASS, 3 FAIL, 2 instrument error (no key, no parseable passes) - so a caller can never mistake
"the judge did not run" for "the passes were fine".

SEEN TO FAIL, on real captured data, which is the only reason its PASS means anything:
  scratchpad/gweck/ev-final/guest-agent.log (the German 25H2 template, 26 passes):
  10 SILENT passes - 6 x 0x8024402C and 4 x 0x80072EFE - i.e. 38% of that guest's passes ended
  without telling dom0 anything. WUPASS_DEFECT=silent re-introduces the original state (the silent
  check does not fire) and the judge then reports PASS on that same log, which is the proof that the
  check is load-bearing rather than decorative.
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jev import load_key, ask  # noqa: E402

TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\s+(.*)$")
PASS_START = "VM class (live from qubesdb)"
REPORTED = re.compile(r"reported\s+(\d+)\s+update\(s\) to dom0")
OFFERED = re.compile(r"scan:\s+(\d+)\s+update\(s\) offered")
ERROR = re.compile(r"^ERROR:\s*(.+)$")
HRESULT = re.compile(r"(0x[0-9A-Fa-f]{8})")
NOOP = "Doing nothing"

QUESTIONS = {
    "outcome": {
        "type": "choice",
        "instructions": {
            "judge": "These are ALL the lines of one Windows Update pass run by a Qubes Windows guest's "
                     "updater agent, in order. Updates here are dom0-owned: the guest must report its "
                     "update count to dom0 at the end of every pass, and dom0 keeps whatever it was last "
                     "told. What happened in this pass?"
        },
        "criteria": {
            "reported-to-dom0": "the pass completed its work and told dom0 a number",
            "final-error-silent": "the pass hit an error it did not recover from and ended WITHOUT telling dom0 anything, leaving dom0 holding a previous value",
            "transient-retry": "the pass hit something it treated as temporary and would be expected to retry, rather than a final outcome",
            "declined-by-design": "the pass deliberately did nothing because this guest is not one it manages",
            "unclear": "these lines do not say what happened",
        },
    },
    "dom0_left_stale": {
        "type": "noul",
        "instructions": {
            "judge": "After this pass, is dom0's recorded update count for this guest STALE - i.e. the "
                     "pass changed or learned something about the guest's updates but did not tell dom0, "
                     "so dom0's number now describes an earlier moment?"
        },
        "criteria": {
            "true": "stale - dom0 holds a number this pass did not confirm",
            "false": "not stale - either dom0 was told, or the pass learned nothing that would change the number",
        },
    },
}


def parse_passes(path):
    """Split the agent log into passes. Tolerates cmd.exe banner lines around a captured log."""
    try:
        raw = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print("INSTRUMENT: cannot read %s: %s" % (path, e))
        sys.exit(2)
    passes, cur = [], None
    for line in raw:
        m = TS.match(line.strip())
        if not m:
            continue  # banner, prompt, blank
        t, msg = "%s:%s:%s" % (m.group(1), m.group(2), m.group(3)), m.group(4).strip()
        if PASS_START in msg:
            if cur:
                passes.append(cur)
            cur = {"t": t, "lines": []}
        if cur is None:
            continue  # lines before the first pass header
        cur["lines"].append("%s %s" % (t, msg))
    if cur:
        passes.append(cur)
    return passes


def classify(p):
    """Code facts for one pass - fixed strings only, no interpretation."""
    reported, offered, errors = None, None, []
    noop = False
    for line in p["lines"]:
        msg = line.split(" ", 1)[1] if " " in line else line
        m = REPORTED.search(msg)
        if m:
            reported = int(m.group(1))
        m = OFFERED.search(msg)
        if m:
            offered = int(m.group(1))
        m = ERROR.match(msg)
        if m:
            errors.append(m.group(1))
        if NOOP in msg:
            noop = True
    hres = [h for e in errors for h in HRESULT.findall(e)]
    p.update(reported=reported, offered=offered, errors=errors, hresults=hres, noop=noop)
    # GUARD:silent - the load-bearing rule. WUPASS_DEFECT=silent re-introduces the original state
    # in which an errored pass that never reported was indistinguishable from a healthy one.
    if os.environ.get("WUPASS_DEFECT") == "silent":
        p["silent"] = False
    else:
        p["silent"] = bool(errors) and reported is None and not noop
    p["contradictory"] = bool(errors) and reported is not None
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-log", required=True)
    ap.add_argument("--dom0-reported", type=int, default=None,
                    help="what dom0 actually holds now (qvm-features <vm> updates-available)")
    ap.add_argument("--limit", type=int, default=25,
                    help="max errored passes sent to Jev (cost bound; the code facts always cover every pass)")
    ap.add_argument("--no-judge", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()

    passes = [classify(p) for p in parse_passes(a.agent_log)]
    if not passes:
        print("INSTRUMENT: no passes found in %s (no '%s' line)" % (a.agent_log, PASS_START))
        sys.exit(2)

    silent = [p for p in passes if p["silent"]]
    contradictory = [p for p in passes if p["contradictory"]]
    reported = [p for p in passes if p["reported"] is not None]
    errored = [p for p in passes if p["errors"]]
    codes = {}
    for p in errored:
        for h in p["hresults"]:
            codes[h.lower()] = codes.get(h.lower(), 0) + 1

    facts = {
        "passes": len(passes),
        "reported": len(reported),
        "errored": len(errored),
        "noop": sum(1 for p in passes if p["noop"]),
        "silent": len(silent),
        "contradictory": len(contradictory),
        "hresults": codes,
        "last_reported": reported[-1]["reported"] if reported else None,
    }

    fails, flags, graded = [], [], []
    for p in silent:
        fails.append("SILENT pass at %s: ended on %s and never reported to dom0 - dom0 still holds the previous number"
                     % (p["t"], "; ".join(p["errors"])[:80]))
    for p in contradictory:
        fails.append("CONTRADICTORY pass at %s: reported %d to dom0 AND logged %s"
                     % (p["t"], p["reported"], "; ".join(p["errors"])[:60]))
    if a.dom0_reported is not None:
        if facts["last_reported"] is None:
            fails.append("DISAGREEMENT: dom0 holds %d but no pass in this log ever reported" % a.dom0_reported)
        elif a.dom0_reported != facts["last_reported"]:
            fails.append("DISAGREEMENT: dom0 holds %d, the last pass reported %d"
                         % (a.dom0_reported, facts["last_reported"]))

    if not a.no_judge and errored:
        key = load_key()
        if not key:
            print("INSTRUMENT: no API key (TYPESAFE_API_KEY or ~/.config/qwt-secrets/typesafe.key)")
            sys.exit(2)
        if len(errored) > a.limit:
            flags.append("COVERAGE: %d of %d errored passes sent to Jev (--limit); code facts cover all %d passes"
                         % (a.limit, len(errored), len(passes)))
        for p in errored[:a.limit]:
            r = ask(key, {"pass_lines": p["lines"]}, QUESTIONS, caller="wu-pass-judge")["answers"]
            g = {"t": p["t"], "outcome": r["outcome"]["choice"], "conf": r["outcome"]["confidence"],
                 "stale": r["dom0_left_stale"]["noul"], "code_silent": p["silent"]}
            graded.append(g)
            # A conflict between the code fact and Jev is reported, never resolved silently either way.
            if g["outcome"] == "transient-retry" and p["silent"]:
                flags.append("CONFLICT %s: code says SILENT (errored, never reported) but Jev graded transient-retry conf=%.2f"
                             % (g["t"], g["conf"]))
            elif g["outcome"] == "final-error-silent" and not p["silent"]:
                flags.append("CONFLICT %s: Jev graded final-error-silent conf=%.2f but the code facts do not show it"
                             % (g["t"], g["conf"]))
            if g["conf"] < 0.7:
                flags.append("JEV low-confidence %s (%s conf=%.2f) - read this pass by hand" % (g["t"], g["outcome"], g["conf"]))

    report = {"facts": facts, "graded": graded, "fails": fails, "flags": flags}
    if a.json:
        json.dump(report, open(a.json, "w"), indent=1)
    print("facts: " + " ".join("%s=%s" % (k, v) for k, v in facts.items()))
    for f in fails:
        print("  FAIL", f)
    for f in flags:
        print("  FLAG", f)
    print("verdict: %s" % ("FAIL" if fails else "PASS"))
    sys.exit(3 if fails else 0)


if __name__ == "__main__":
    main()
