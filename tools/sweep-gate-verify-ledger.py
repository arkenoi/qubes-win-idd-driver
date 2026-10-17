#!/usr/bin/env python3
"""Can each error-ledger row still be PRODUCED by the current emitters?

Called by tools/sweep-gate.sh --verify-ledger. Reads the ledger and a flattened dump of every
emitter source, and classifies each row OK / UNCERTAIN / LOST.

WHY THIS EXISTS. sweep-gate's orphan report has told readers for weeks to "check with
--verify-ledger" - a flag the parser never accepted. So the one diagnosis the gate prescribes for a
drifted row could not be run, and a LOST disposition stayed indistinguishable from a condition that
simply did not occur. Run 38994277148 reported "5 of 7 row(s) matched nothing this run" and nobody
could tell which kind they were; one of them was real - the ApplyGuestShadows row, whose emitter was
reworded from "yet (token%s); cannot" to "yet, cannot", so the error came back UNACCOUNTED x18 with
its reason orphaned on disk.

THREE STATES, because two of them are honest and the third is not available.
  OK         a literal run of 20+ characters from the row is present in the emitters.
  UNCERTAIN  no long run survives, but a shorter stem does - which is what a message ASSEMBLED from
             pieces looks like: "CfgReadMultiString(" REG_CONFIG_AUTOSTART_VALUE L")" never exists
             as one string anywhere. This check cannot decide, so it says so and does not fail.
  LOST       no stem at all. Whatever wrote that line does not say it any more.

THE FUNCTION NAME IS NOT PART OF THE MESSAGE. The QWT log macro prepends "Func: ", so a run that
begins with it can never be found in a format string. The first version of this check did not strip
it and called two healthy rows LOST for that reason alone - a verifier that confidently sends
someone to repair a working row is worse than no verifier.
"""
import re, sys, io

PREFIX = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*: ")
HOLE   = re.compile(r"<(?:HEX|PATH|OSMSG|CELL|VM)>|\bN\b")
LONG, SHORT = 20, 16

def stems(msg):
    body = PREFIX.sub("", msg)
    out = [r for r in HOLE.split(body) if r and len(r.strip()) >= 8]
    out += [r for r in HOLE.split(msg) if r and len(r.strip()) >= 8]
    return out

def main():
    led, srcfile = sys.argv[1], sys.argv[2]
    src = io.open(srcfile, encoding="utf-8", errors="replace").read()
    bad = unc = okn = 0
    for line in io.open(led, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        msg = line.split(" ", 1)[1].split("   #")[0] if " " in line else line
        runs = stems(msg)
        if any(len(r) >= LONG and r in src for r in runs):
            okn += 1; print("  OK    %s" % msg[:110]); continue
        near = None
        for r in runs:
            for n in range(len(r), SHORT - 1, -1):
                if r[:n] in src:  near = r[:n];  break
                if r[-n:] in src: near = r[-n:]; break
            if near: break
        if near:
            unc += 1
            print("  UNCERTAIN  %s" % msg[:104])
            print("        no literal run of %d+ chars survives, but %r is still in the tree - the" % (LONG, near[:40]))
            print("        message is probably assembled from pieces. Cannot decide; read the emitter.")
        else:
            bad += 1
            print("  LOST  TEXT-GONE  %s" % msg[:104])
            print("        no stem of %d+ chars from this row is anywhere in the emitters: whatever wrote" % SHORT)
            print("        it does not say that any more, so this disposition accounts for nothing while")
            print("        its error returns as unaccounted. Re-point it at the current text, or drop it.")
    print("SWEEP-GATE-VERIFY-LEDGER ok=%d uncertain=%d lost=%d" % (okn, unc, bad))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
