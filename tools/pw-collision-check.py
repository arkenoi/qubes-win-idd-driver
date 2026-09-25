#!/usr/bin/env python3
"""pw-collision-check.py - does one window's granted buffer belong to another window too?

    tools/pw-collision-check.py GUI-AGENT-LOG [--json]

WHY THIS EXISTS. The open P2 is a field report (forum 42717 post 160) that the Settings app's
right panel renders inside an UNRELATED window's frame, persistently enough to navigate by
keyboard. One window's pixels in another window's buffer is what dom0 would draw if two live
windows were announced against one granted slab. The entry's stated first measurement is to open
Settings and lusrmgr together and compare, per window, the slab and the refs actually sent - "a
collision is visible directly and needs no theory". This does that comparison, so nobody has to
eyeball an agent log for it.

WHAT IT READS. Two line kinds the agent emits (agent >= 41b438e):
  QGAPROTO,msg=PWATTACH,hwnd=0x...,...,buf=0x...,ref0=N,pages=N,dumppages=N,...
      what this window was announced to dom0 with. ref0 is read from the array actually handed
      to SendWindowDump, so it is what the daemon was TOLD.
  PWCOLLISION hwnd=0x... took slab buf=0x... ref0=N while live window hwnd=0x... still holds it
      the agent's own alarm, raised at the only moment a double-binding can be created.

A PWCOLLISION line is decisive on its own and is reported verbatim. The PWATTACH cross-check is
weaker BY CONSTRUCTION and is labelled so: slabs are pooled and deliberately reused, so one buffer
legitimately serves many windows OVER TIME. Re-use across time is normal; what is not normal is
the agent's alarm, or a reused buffer whose earlier holder is never seen to detach. This prints
re-use chains as CONTEXT for the alarm, never as a verdict of its own.

Exit 0 = no collision alarm found; 1 = at least one alarm; 2 = instrument error (unreadable log,
or a log with no PWATTACH lines at all, which means tracing was off and the run proves nothing).
"""
import argparse, json, re, sys
from collections import defaultdict

ATTACH = re.compile(
    r"QGAPROTO,msg=PWATTACH,hwnd=(0x[0-9a-fA-F]+).*?buf=(0x[0-9a-fA-F]+),ref0=(\d+),"
    r"pages=(\d+),dumppages=(\d+)")
COLLIDE = re.compile(
    r"PWCOLLISION hwnd=(0x[0-9a-fA-F]+) took slab buf=(0x[0-9a-fA-F]+) ref0=(\d+) "
    r"while live window hwnd=(0x[0-9a-fA-F]+)")


def die(msg):
    print("INSTRUMENT: " + msg, file=sys.stderr)
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    try:
        lines = open(a.log, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        die("cannot read %s: %s" % (a.log, e))

    attaches, alarms = [], []
    for n, line in enumerate(lines, 1):
        m = ATTACH.search(line)
        if m:
            attaches.append({"line": n, "hwnd": m.group(1), "buf": m.group(2),
                             "ref0": int(m.group(3)), "pages": int(m.group(4)),
                             "dumppages": int(m.group(5))})
        m = COLLIDE.search(line)
        if m:
            alarms.append({"line": n, "taker": m.group(1), "buf": m.group(2),
                           "ref0": int(m.group(3)), "holder": m.group(4),
                           "text": line.strip()})

    if not attaches and not alarms:
        die("no PWATTACH and no PWCOLLISION lines in %s - per-window tracing was OFF "
            "(qvm-features <vm> service.gui-agent-debug 1) or this agent predates 41b438e. "
            "This run proves NOTHING about buffer sharing; it is missing data, not a clean result."
            % a.log)

    by_buf = defaultdict(list)
    for r in attaches:
        by_buf[r["buf"]].append(r)
    reused = {b: rs for b, rs in by_buf.items()
              if len({r["hwnd"] for r in rs}) > 1}

    if a.json:
        print(json.dumps({"alarms": alarms, "attaches": len(attaches),
                          "buffers": len(by_buf),
                          "reused_across_windows": {b: rs for b, rs in reused.items()}},
                         indent=2))
        sys.exit(1 if alarms else 0)

    print("PWATTACH lines: %d over %d distinct buffers" % (len(attaches), len(by_buf)))
    if alarms:
        print("\nCOLLISION ALARMS - %d. The agent caught a slab being taken while a live window"
              "\nstill held it. This is the defect, not an inference:" % len(alarms))
        for c in alarms:
            print("  line %d: hwnd %s took buf %s (ref0 %d) from live hwnd %s"
                  % (c["line"], c["taker"], c["buf"], c["ref0"], c["holder"]))
    else:
        print("\nNo PWCOLLISION alarm in this log.")
        print("That is NOT a clean bill of health unless the alarm has been seen to fire on this")
        print("build - drive it with FI_SLAB_DOUBLE_BIND first, or this silence proves nothing.")

    if reused:
        print("\nCONTEXT ONLY - buffers that served more than one window over time (%d)."
              % len(reused))
        print("Slab reuse is DELIBERATE and normal; this is here to read alongside an alarm,")
        print("never as a verdict on its own:")
        for b, rs in sorted(reused.items()):
            who = ", ".join("%s@%d" % (r["hwnd"], r["line"]) for r in rs)
            print("  %s  ref0=%d  <- %s" % (b, rs[0]["ref0"], who))

    sys.exit(1 if alarms else 0)


if __name__ == "__main__":
    main()
