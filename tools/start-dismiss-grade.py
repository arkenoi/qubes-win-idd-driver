#!/usr/bin/env python3
"""start-dismiss-grade.py - did the hidden Start menu actually CLOSE, on this capture?

    tools/start-dismiss-grade.py --agent-log AGENT.LOG [--source agent/gui-agent/main.c] [--json out]

Input: a captured gui-agent log (the dedicated Start test copies one per run). Verdict is about the
OPENINGS in it: for each one, did the agent attempt a dismissal, and was the menu observed closed
within the bound, or still holding input past it?

WHY THIS EXISTS AS A TRACKED TOOL. The dedicated Start test's grader lived in scratchpad/, untracked,
and anchored its success pattern on the literal "closed it with Escape". That string was added in
9186c17 and REMOVED in 0429a93 - so from 0429a93 onward the grader could not recognise a successful
dismissal at all, and the test reported no Start verdict while the captures it had just taken
carried the answer. The instrument for a P1 was both broken and unreviewable.

SO IT READS EVERY FORM THE EMITTER HAS EVER WRITTEN, not just today's. A capture is a historical
artifact: one taken from an older build is still evidence, and a grader that only knows the current
wording silently reports "nothing happened" about it. Three generations are live here:
  gen1  9186c17   "closed it with Escape"
  gen2  0429a93   "posted Escape TO THAT WINDOW" / later "posted Escape to 0x<hwnd> (focus=0x...)"
                  with "Start still closing N ms after Escape" and
                  "the hidden Start menu is STILL open N ms after Escape"
  gen3  ac45cd9   "activation returned to 0x<hwnd> (dom0 focus|shell desktop, plain|attached)",
                  "closed (surface cloaked|foreground left) N ms after activation returned",
                  "still open N ms after activation returned", and the two failure arms
                  "activation to 0x... refused" and "nothing to return activation to"

AND IT CHECKS ITS OWN ANCHORS. Given --source (default: the agent main.c beside this repo), every
CURRENT-generation stem must still be present in that file. If one is not, this exits 2 INSTRUMENT
and names the stem - because the failure mode being guarded here is precisely a grader whose
pattern has gone stale reporting "no evidence" instead of "I cannot read this".

Exit 0 the openings all closed, 3 at least one stayed open (or an attempt failed), 2 instrument.
"""
import argparse, json, os, re, sys

# gen3 stems that MUST still exist in the emitter. Each is the invariant part of one line - no
# format specifiers, no hwnd - so it survives wording changes around it but not a real rename.
CURRENT_STEMS = [
    "closed (%s) %llu ms after %s",
    "activation returned to 0x%x",
    "still open %llu ms after activation returned",
    "activation to 0x%x refused",
    "nothing to return activation to",
]

TAG = "QGASTARTDISMISS"
# One opening begins at an ATTEMPT line. gen1 had no separate attempt line (it logged only the
# closure), so a gen1 capture is graded on its closures alone.
# An attempt is the agent ACTING on an opening, which includes the two arms where the action
# did not land: a refused activation and a no-target. Reading only the success wording
# mis-grouped the 2026-10-17 capture as ONE opening when the log holds two.
ATTEMPT = re.compile(r"activation returned to 0x([0-9a-fA-F]+)"
                    r"|activation to 0x([0-9a-fA-F]+) refused"
                    r"|nothing to return activation to"
                    r"|posted Escape (?:TO THAT WINDOW|to 0x([0-9a-fA-F]+))")
# gen4 states WHETHER the activation was applied, because gen3 said "after activation returned"
# even when the foreground lock had refused it - a sentence that claims this agent closed a
# surface it did not, and Jev reading that capture concluded exactly that (0.63).
CLOSED = re.compile(r"closed \((surface cloaked|foreground left)\) (\d+) ms after "
                   r"(?:(activation returned - closed by this request)"
                   r"|(a REFUSED activation - NOT closed by this request)"
                   r"|activation returned)"
                   r"|closed it with Escape")
STUCK = re.compile(r"(?:still open|STILL open) (\d+) ms after (?:activation returned|Escape)")
CLOSING = re.compile(r"(?:closing, (\d+) ms after activation returned|Start still closing (\d+) ms after Escape)")
REFUSED = re.compile(r"activation to 0x([0-9a-fA-F]+) refused")
NOTARGET = re.compile(r"nothing to return activation to")
# The capture's own line shape: [YYYYMMDD.HHMMSS.mmm-pid:tid-LEVEL] Func: message
LINE = re.compile(r"^\[(\d{8}\.\d{6}\.\d{3})-(\d+):(\d+)-([A-Z])\]\s+(?:(\S+):\s*)?(.*)$")
HWND = re.compile(r"\b0x([0-9a-fA-F]+)\b")


def check_anchors(source):
    """A grader that cannot find its own emitter is an instrument fault, never a verdict."""
    if not source or not os.path.exists(source):
        return ["source not given or absent: %s" % source]
    try:
        src = open(source, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return ["cannot read %s: %s" % (source, e)]
    return ["stem no longer in the emitter: %r" % s for s in CURRENT_STEMS if s not in src]


def parse(path):
    try:
        raw = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print("INSTRUMENT: cannot read %s: %s" % (path, e))
        sys.exit(2)
    out = []
    for line in raw:
        m = LINE.match(line)
        if not m or TAG not in line:
            continue
        out.append({"ts": m.group(1), "pid": m.group(2), "level": m.group(4),
                    "func": m.group(5) or "", "msg": m.group(6)})
    return out


def grade(events):
    """Group the tagged lines into OPENINGS and judge each. An opening runs from an attempt (or a
    bare closure, on gen1) until the next attempt."""
    openings, cur = [], None
    for e in events:
        msg = e["msg"]
        if ATTEMPT.search(msg):
            if cur:
                openings.append(cur)
            hw = HWND.search(msg)
            cur = {"ts": e["ts"], "hwnd": hw.group(1) if hw else None, "lines": [],
                   "closed": None, "stuck": None, "refused": False, "notarget": False, "closings": 0}
        if cur is None:
            # gen1, or a closure whose attempt line is outside the capture window: still an opening.
            hw = HWND.search(msg)
            cur = {"ts": e["ts"], "hwnd": hw.group(1) if hw else None, "lines": [],
                   "closed": None, "stuck": None, "refused": False, "notarget": False, "closings": 0}
        cur["lines"].append("%s %s %s" % (e["ts"], e["level"], msg))
        m = CLOSED.search(msg)
        if m:
            cur["closed"] = {"why": m.group(1) or "escape",
                             "ms": int(m.group(2)) if m.group(2) else None,
                             # None on gen1-gen3, which could not say
                             "by_us": True if m.group(3) else (False if m.group(4) else None)}
        m = STUCK.search(msg)
        if m:
            cur["stuck"] = int(m.group(1))
        if CLOSING.search(msg):
            cur["closings"] += 1
        if REFUSED.search(msg):
            cur["refused"] = True
        if NOTARGET.search(msg):
            cur["notarget"] = True
    if cur:
        openings.append(cur)
    return openings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-log", required=True)
    ap.add_argument("--source", default=None,
                    help="the emitter, for the anchor self-check (default: agent/gui-agent/main.c beside this tool)")
    ap.add_argument("--json")
    a = ap.parse_args()

    source = a.source
    if source is None:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cand = os.path.join(here, "agent", "gui-agent", "main.c")
        source = cand if os.path.exists(cand) else None
    stale = check_anchors(source)
    if stale:
        print("INSTRUMENT: this grader's anchors no longer match the emitter - it cannot report a verdict")
        for s in stale:
            print("  " + s)
        print("  (a grader anchored on a retired string reports 'no evidence' about a capture that holds the answer:")
        print("   'closed it with Escape' was removed in 0429a93 and the Start test gave no verdict for days)")
        sys.exit(2)

    events = parse(a.agent_log)
    if not events:
        print("INSTRUMENT: no %s lines in %s - the agent never examined a hidden Start opening, "
              "so this capture cannot answer whether one closes" % (TAG, a.agent_log))
        sys.exit(2)

    openings = grade(events)
    fails, notes = [], []
    for o in openings:
        where = "%s 0x%s" % (o["ts"], o["hwnd"] or "?")
        # A refusal and a later closure can BOTH be true of one opening, and neither may hide the
        # other: the surface closing is what the user sees, the refusal is why the agent cannot
        # claim it closed it. Measured 2026-10-17: "activation to 0x30062 refused" and then
        # "closed (foreground left) 2140 ms after" on the same opening. Jev both-named 0.98.
        closure = ""
        if o["closed"]:
            ms = o["closed"]["ms"]
            closure = " - the surface DID close (%s%s)%s" % (
                o["closed"]["why"], "" if ms is None else ", after %d ms" % ms,
                "" if o["closed"].get("by_us") else ", and the emitter says NOT by this request")
        if o["notarget"]:
            fails.append("%s: nothing to return activation to - the hidden menu was left open%s" % (where, closure))
        elif o["refused"]:
            fails.append("%s: activation REFUSED by the foreground lock%s" % (where, closure or " - the hidden menu was left open"))
        elif o["stuck"] is not None:
            fails.append("%s: STILL OPEN %d ms after the dismissal - clicks go to a menu the user cannot see"
                         % (where, o["stuck"]))
        elif o["closed"]:
            ms = o["closed"]["ms"]
            notes.append("%s: closed (%s)%s" % (where, o["closed"]["why"],
                                                "" if ms is None else " after %d ms" % ms))
        else:
            # NO TERMINAL LINE. On gen2 and earlier this is the normal shape of a success, because
            # nothing was ever written when an opening ended - which is the hole ac45cd9 closed. It
            # is therefore NOT graded as a pass: an absent line is not evidence of a closure.
            fails.append("%s: no closure and no stuck line - this build does not record how the "
                         "opening ended, so nothing here says the menu closed" % where)

    facts = {"openings": len(openings), "closed": sum(1 for o in openings if o["closed"]),
             "stuck": sum(1 for o in openings if o["stuck"] is not None),
             "refused": sum(1 for o in openings if o["refused"]),
             "no_target": sum(1 for o in openings if o["notarget"]),
             "unrecorded": sum(1 for o in openings if not o["closed"] and o["stuck"] is None
                               and not o["refused"] and not o["notarget"])}
    print("facts: " + " ".join("%s=%s" % (k, v) for k, v in facts.items()))
    for n in notes:
        print("  OK   " + n)
    for f in fails:
        print("  FAIL " + f)
    print("verdict: %s" % ("FAIL" if fails else "PASS"))
    if a.json:
        json.dump({"facts": facts, "fails": fails, "notes": notes,
                   "openings": openings}, open(a.json, "w"), indent=1)
    sys.exit(3 if fails else 0)


if __name__ == "__main__":
    main()
