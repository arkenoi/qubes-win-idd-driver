#!/usr/bin/env python3
"""grade-noise.py <agent-log-excerpt> [--pixels <file>] - is this boot FREE of notification noise?

THE ACCEPTANCE CRITERION, owner 2026-10-11: "acceptance criteria includes absense of notification
noise". It is graded here rather than read off a log by eye, because reading it by eye is how the
previous receipt passed three of four conditions and let a WARNING through: BROKERHOLD was INFO, so
the eye stopped there, and BROKERLATEREG was still W on all three boots.

A boot PASSES only if all of these hold on the excerpt:
  1. no QGADIRECTSUPPRESS         - no display fault declared about a window that was fine
  2. no "user notification sent"  - dom0 was not told anything by a notifhost one-shot
  3. no NOTIFYERR ... sent        - dom0 was not told anything by the error route
  4. every BROKERHOLD is INFO     - a hold while the broker starts is the designed path
  5. every BROKERLATEREG is INFO  - so is the registration that ends it
  6. both tags present            - an excerpt with neither did not exercise the condition at all,
                                    and MISSING DATA FAILS: it must never read as quiet
With --pixels, the capture must also show the window delivered (windows>=1 and a non-black mean),
because "no noise" on a boot that never showed the window is not the result being claimed. AND no
capture may show a window that is BLACK: the owner's criterion is "slicefed window is held until
broker comes up AND NOTHING WEIRD HAPPENS IN BETWEEN" (2026-10-11), so a window that flashed black
at t+3 and was correct at t+15 is a failure, and grading only the best capture would pass it.

rc 0 pass, 1 fail, 2 could not grade. The level is the field between the last '-' and ']' in the
agent's own stamp: [20261011.102247.645-4448:4452-I].
"""
import argparse
import re
import sys

STAMP = re.compile(r"^\[\d{8}\.\d{6}\.\d{3}-\d+:\d+-([A-Z])\]")
PIX = re.compile(r"windows=(\d+).*?mean=([0-9.]+)")
# below this a capture is black, not dim: the measured correct delivery is mean 0.9906-0.9939
# and an unpainted window measures ~0.00
BLACK = 0.05
# SCOPE, stated because it bounds what a PASS means: race-pixels.sh writes ONE line per capture
# carrying up to four windows ("windows=2 win-0.png=... mean=... win-1.png=... mean=..."), and this
# pattern needs `windows=` before `mean=`, so it grades the FIRST window of each capture only. That
# is deliberate - the subject is the one window the probe opened, and grading every window would
# fail on any legitimately dark surface that happens to be captured. A black SECOND window would
# not be caught here; it would be caught by the agent-log arms, which are per-window.


def levels(lines, tag):
    """(level, line) for every line carrying tag, level None if the stamp is unreadable."""
    out = []
    for ln in lines:
        if tag not in ln:
            continue
        m = STAMP.match(ln.strip())
        out.append((m.group(1) if m else None, ln.strip()))
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("excerpt")
    ap.add_argument("--pixels")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv[1:])
    try:
        lines = open(a.excerpt, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print("GRADE 2 could not read %s: %s" % (a.excerpt, e))
        return 2
    fails, notes = [], []

    for bad, what in (("QGADIRECTSUPPRESS", "a display fault was declared"),
                      ("user notification sent", "dom0 was told by a notifhost one-shot"),
                      ("sent to dom0", "dom0 was told by the error route")):
        hits = [l for l in lines if bad in l]
        if hits:
            fails.append("%s: %s (%d line(s)) | %s" % (bad, what, len(hits), hits[0][:150]))
        else:
            notes.append("%s absent" % bad)

    for tag in ("BROKERHOLD", "BROKERLATEREG"):
        got = levels(lines, tag)
        if not got:
            fails.append("%s: ABSENT - the excerpt does not exercise the pre-broker condition, so it "
                         "cannot be graded quiet (missing data fails)" % tag)
            continue
        loud = [(lv, l) for lv, l in got if lv != "I"]
        if loud:
            fails.append("%s: %d of %d line(s) not INFO (levels %s) | %s"
                         % (tag, len(loud), len(got), ",".join(str(lv) for lv, _ in loud),
                            loud[0][1][:170]))
        else:
            notes.append("%s x%d all INFO" % (tag, len(got)))

    if a.pixels:
        try:
            pl = open(a.pixels, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("GRADE 2 could not read %s: %s" % (a.pixels, e))
            return 2
        ms = PIX.findall(pl)
        if not ms:
            fails.append("pixels: no 'windows=N ... mean=M' capture line at all - the window was "
                         "never graded, and absence is not delivery")
        else:
            caps = [(int(n), float(m)) for n, m in ms]
            best = max(caps)
            if best[0] < 1 or best[1] < BLACK:
                fails.append("pixels: best capture windows=%d mean=%.4f - the window was not "
                             "delivered with content" % best)
            else:
                notes.append("pixels windows=%d mean=%.4f (best of %d captures)" % (best + (len(caps),)))
            # NOTHING WEIRD IN BETWEEN. A mapped window with no content is the defect the hold
            # exists to prevent, and it is invisible if only the best capture is graded.
            black = [c for c in caps if c[0] >= 1 and c[1] < BLACK]
            if black:
                fails.append("pixels: %d of %d capture(s) show a MAPPED BLACK window (worst "
                             "windows=%d mean=%.4f) - held means not mapped at all, so a black "
                             "frame in between is the defect"
                             % ((len(black), len(caps)) + min(black, key=lambda c: c[1])))
            else:
                notes.append("no capture shows a mapped black window (%d graded)" % len(caps))

    if not a.quiet:
        for n in notes:
            print("  ok   %s" % n)
        for f in fails:
            print("  FAIL %s" % f)
    print("GRADE %d %s" % (1 if fails else 0, "NOISE PRESENT" if fails else "no notification noise"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
