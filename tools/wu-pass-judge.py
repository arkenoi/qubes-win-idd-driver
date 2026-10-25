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
  errored       a pass whose last substantive line declares ERROR - either "[ERROR] ..." (the form
                the writer emits since e4162c79) or the older bare "ERROR: ...". Both, always: see
                SEEN TO FAIL below for what reading only one of them cost.
  noop          a pass that declined by design ("Doing nothing" - e.g. a StandaloneVM, which is
                template-only by design and is NOT a failure).
  SILENT        errored AND never reported: dom0 was left holding a stale number. Any is a FAIL.
  DIED MID-PASS a pass that reported nothing, declared nothing and declined nothing, with a LATER
                pass proving it was over - so it was cut off (scheduler, reboot, crash) and left
                dom0 stale in total silence. SILENT cannot see this: it requires an error line.
                The LAST pass is only FLAGGED - from this log a kill and a still-running pass are
                the same thing, and only the caller knows whether the round had ended.
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

  qwt-accept/rel-38994277148/template-update.d/wu-e2e/round1/agent.log (release 4.3.36, win11de-tup):
  one pass that threw in Ensure-Proxy and never reported. This judge graded it
  "errored=0 silent=0 verdict: PASS" for three rounds, and the cell reported fails=0 - a RELEASE
  GATE passing a guest whose updater was dead, for three days. Cause: the error pattern was anchored
  at the front of the message, and on 2026-10-14 e4162c79 made the writer declare its level THERE
  ("[ERROR] msg"). Nothing matched, and `errors` is what drives silent, contradictory AND whether
  Jev is consulted at all - so one unmatched prefix turned the whole judge off in silence.
  WUPASS_DEFECT=levelprefix restores that blindness and the judge reports PASS on that capture again.
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jev import load_key, ask  # noqa: E402

TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\s+(.*)$")
PASS_START = "VM class (live from qubesdb)"
REPORTED = re.compile(r"reported\s+(\d+)\s+update\(s\) to dom0")
OFFERED = re.compile(r"scan:\s+(\d+)\s+update\(s\) offered")
# BOTH FORMS THE WRITER HAS EVER DECLARED, because this pattern is anchored where a level tag goes.
# "[ERROR] msg" since e4162c79 (2026-10-14), bare "ERROR: msg" before it. A log captured across an
# upgrade holds both. What the single old form cost is in SEEN TO FAIL above.
# ERROR-SITE and ERROR-STACK are the SAME failure's continuation lines (the throwing source line and
# its PowerShell stack). They must not match: three lines would count as three errors and the
# diagnosis handed to Jev would be a source line instead of the message. Requiring "]" or ":"
# immediately after ERROR is what excludes them - as does it exclude a "C:\..." path line.
ERROR = re.compile(r"^(?:\[ERROR\]|ERROR:)\s*(.+)$")
# GUARD:levelprefix - the 2026-10-14 blindness, reachable with WUPASS_DEFECT=levelprefix so the
# check above is proven load-bearing against the real capture that it let through.
ERROR_FRONT_ANCHORED_ONLY = re.compile(r"^ERROR:\s*(.+)$")
# ONE [WARN] IS A FAILURE, AND IT IS THIS ONE. QWTUPDDEFCLASSNEW means a Defender SIGNATURE offer
# came back without the classification the definition exclusion keys on - so the exclusion silently
# stopped applying, dom0's flag goes back to oscillating, and the only thing that says why is this
# line. A declared level that nothing acts on is just a tidier log, so it is judged here: the pass
# did not "fail" in the sense of throwing, but the product behaviour dom0 depends on is broken and
# a run must go red rather than pass with a warning nobody reads.
DEFCLASSNEW = re.compile(r"QWTUPDDEFCLASSNEW\s+(.+)$")
# DELIBERATELY NOT ERRORS, so the next reader does not re-derive it: the writer also declares
# "[WARN]" at two further sites (the status file could not be written; and the signature watcher
# above, which IS judged) and "ANOMALY:" (two - a relay that did
# not exit when this pass stopped it). Neither says the PASS failed, and this tool judges passes.
# Counted 2026-10-17 over 170 captured agent logs: "[WARN]" 0, "ANOMALY:" 0, QWTUPDLOGLOST 0 - so
# treating them as errors would be machinery for a shape never once observed. Worth knowing if that
# changes: the ANOMALY pair reports a lingering relay, which is the condition that strands a stale
# relay exe on the next deploy (findings/updates.md, QWTRELAYBUSY), and the [WARN] means dom0's
# status file is stale - both are about this tool's own subject.
# THE LOG ANNOUNCING ITS OWN GAP. guest/qubes-windows-update.ps1 writes this on the first
# successful append after any line could not be written. A judge that reads this file to decide
# whether a pass told dom0 the truth CANNOT trust a file with holes: on 2026-10-08 two dropped
# lines ("relay started", "proxy up") were nearly written up as a product defect that did not
# exist, because an absent line was read as an event that never happened.
# EVERY by-design decline is gated on the CLASS, not on its sentence. guest/qubes-windows-update.ps1
# falls through to the work only for TemplateVM (2421); StandaloneVM with direct internet, offline
# StandaloneVM, and any other class each log one line and exit 0 (2423-2436). Reading the sentences
# knew only one of the three: measured 2026-10-17 over 170 captured logs, three StandaloneVM passes
# that declined exactly as designed were about to be reported as deaths by the DIED MID-PASS rule,
# because "Doing nothing" was the only decline this tool could recognise. The class is the fact.
VMCLASS = re.compile(r"VM class \(live from qubesdb\):\s*(\S+)")
LOGLOST = re.compile(r"QWTUPDLOGLOST\s+(\d+)\s+line")
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
    vmclass = None
    err_re = ERROR_FRONT_ANCHORED_ONLY if os.environ.get("WUPASS_DEFECT") == "levelprefix" else ERROR
    for line in p["lines"]:
        msg = line.split(" ", 1)[1] if " " in line else line
        m = REPORTED.search(msg)
        if m:
            reported = int(m.group(1))
        m = OFFERED.search(msg)
        if m:
            offered = int(m.group(1))
        m = err_re.match(msg)
        if m:
            errors.append(m.group(1))
        if NOOP in msg:
            noop = True
        m = VMCLASS.search(msg)
        if m:
            vmclass = m.group(1)
    # A pass on anything but a template declines by design and never reports: that is the contract,
    # not a failure. GUARD:classnoop
    if vmclass is not None and vmclass != "TemplateVM" and os.environ.get("WUPASS_DEFECT") != "classnoop":
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
    # GUARD:vanished - A PASS THAT SAID NOTHING AT ALL. `silent` above requires an error line, so
    # the one thing it structurally could not see was actual silence: a pass ended between its first
    # line and its terminal one - the Task Scheduler cutting it off, a reboot, a crash - declared
    # nothing, reported nothing, and graded PASS. Measured 2026-10-17 against a real capture
    # truncated at that point: "passes=2 reported=1 errored=0 silent=0 verdict: PASS", with the
    # dead pass provably over. dom0 keeps the previous number, which is the exact field failure this
    # tool exists for.
    # A segment always means a pass that really began: every refusal exits by line 418 of
    # guest/qubes-windows-update.ps1 and "VM class" is logged at 2420, so a refused pass writes no
    # pass-start line and cannot appear here. The LAST segment, though, may simply still be running
    # when the log was captured - from the log alone that is indistinguishable from a kill - so it is
    # FLAGGED, never failed. Only the caller knows whether the round had ended.
    def _mute(p):
        return p["reported"] is None and not p["errors"] and not p["noop"]
    vanished = [p for p in passes[:-1] if _mute(p)]
    if os.environ.get("WUPASS_DEFECT") == "vanished":
        vanished = []
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
        "vanished": len(vanished),
        "contradictory": len(contradictory),
        "hresults": codes,
        "last_reported": reported[-1]["reported"] if reported else None,
    }

    fails, flags, graded = [], [], []
    # A LOSSY LOG CANNOT WITNESS A PASS. Counted over the whole capture, not per pass: the notice is
    # written once per pass that lost anything, and any loss at all makes every absence in this file
    # unsafe to reason from.
    lost = 0
    try:
        for _ln in open(a.agent_log, encoding="utf-8", errors="replace"):
            _m = LOGLOST.search(_ln)
            if _m:
                lost += int(_m.group(1))
    except OSError:
        pass   # parse_passes already failed loudly on an unreadable log; never report a loss we did not read
    if lost:
        fails.append("LOSSY LOG: the updater's own log reports %d line(s) it could not write "
                     "(QWTUPDLOGLOST). This file is incomplete, so no absence in it is evidence - "
                     "and this judge decides by what the passes did and did not say" % lost)
    # THE SIGNATURE WATCHER FIRED. Whole-file, like LOSSY LOG: the line belongs to whichever pass
    # emitted it, but the consequence is about the product, not about that one pass.
    defclass = []
    try:
        for _ln in open(a.agent_log, encoding="utf-8", errors="replace"):
            _m = DEFCLASSNEW.search(_ln)
            if _m:
                defclass.append(_m.group(1).strip())
    except OSError:
        pass
    for _d in defclass[:5]:
        fails.append("DEFINITION CLASSIFICATION CHANGED (QWTUPDDEFCLASSNEW): %s - the Defender "
                     "exclusion is not applying, so dom0's updates-available will oscillate again. "
                     "This needs the GUID checked against what Windows Update now returns, not a "
                     "re-run" % _d[:240])
    if len(defclass) > 5:
        fails.append("DEFINITION CLASSIFICATION CHANGED: %d further QWTUPDDEFCLASSNEW line(s) not "
                     "listed" % (len(defclass) - 5))

    for p in silent:
        fails.append("SILENT pass at %s: ended on %s and never reported to dom0 - dom0 still holds the previous number"
                     % (p["t"], "; ".join(p["errors"])[:80]))
    for p in vanished:
        fails.append("DIED MID-PASS at %s: a later pass started, so this one was over - it never reported "
                     "and never declared an error, so nothing anywhere says dom0's number is stale" % p["t"])
    if passes and _mute(passes[-1]):
        flags.append("FINAL pass at %s said nothing terminal: a kill and a pass still running look the "
                     "same in this log - if the round had ended, this is a silent death" % passes[-1]["t"])
    for p in contradictory:
        fails.append("CONTRADICTORY pass at %s: reported %d to dom0 AND logged %s"
                     % (p["t"], p["reported"], "; ".join(p["errors"])[:60]))
    # dom0's `updates-available` is a FLAG, not a count: it reads empty/0 for "none" and 1 for
    # "some", whatever number the guest reported. Comparing it to the guest's count produced a
    # FALSE FAIL on 2026-09-20 (guest reported 6, dom0 held 1, called a disagreement) and a PASS
    # one round earlier only because the count happened to BE 1. Compare PRESENCE, which is the
    # only thing the two sides actually agree to talk about. (# GUARD:dom0flag)
    if a.dom0_reported is not None:
        dom0_has = a.dom0_reported > 0
        if facts["last_reported"] is None:
            if dom0_has:
                fails.append("DISAGREEMENT: dom0 says updates are available but no pass in this log ever reported")
        else:
            guest_has = facts["last_reported"] > 0
            if dom0_has != guest_has:
                fails.append("DISAGREEMENT: dom0 says %s, the last pass reported %d update(s)"
                             % ("updates ARE available" if dom0_has else "NO updates", facts["last_reported"]))

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
