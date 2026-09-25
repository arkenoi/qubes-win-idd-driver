#!/usr/bin/env python3
"""Audit the stage-1 ledger's own invariant. The invariant does not audit itself, and that cost a
real hole: PwLedgerSynth was incremented at a primitive that does not touch PwLedgerCopies, so a
synth copy could never surface as UNATTRIBUTED - the check meant to catch uninstrumented copy sites
had a copy site it could not see. It was found by writing a brief, not by a check. This is the
check.

THE RULE, which the ledger's comments state and nothing enforced: every SOURCE counter increment
must be accompanied by an increment of the discriminator PwLedgerCopies - either in the same
statement, or because the copy it counts goes through PwSliceCopyAndDamageSrc, which increments the
discriminator itself.

Usage:  ledger-invariant-audit.py [--prove]
        --prove re-runs with the synth pairing stripped from a COPY of the source and requires this
        audit to fail, because a check never seen to fail is decoration.
"""
import re, sys, pathlib, tempfile, shutil, subprocess

SRC = pathlib.Path(__file__).resolve().parents[2] / "agent/gui-agent/main.c"
# counters that are bookkeeping, not pixel sources
NOT_SOURCES = {"Copies", "CopiesPrev", "FramesSeen", "None", "Unattributed",
               "UnattributedLogged", "Class", "EngineFed"}
PRIMITIVE = "PwSliceCopyAndDamage"   # matches ...AndDamage and ...AndDamageSrc


def strip_comments(line: str) -> str:
    """Comments must not satisfy the check. The first version matched PwSliceCopyAndDamageSrc inside
    a comment that said the path does NOT go through it, so a genuine hole passed the audit and the
    mutant did too - the instrument was defeated by prose about the instrument."""
    return re.sub(r"/\*.*?\*/", "", line.split("//", 1)[0])


def audit(path: pathlib.Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = [strip_comments(l) for l in text.split("\n")]
    problems, checked = [], 0
    for i, line in enumerate(lines):
        for m in re.finditer(r"->PwLedger([A-Za-z]+)\+\+", line):
            name = m.group(1)
            if name in NOT_SOURCES:
                continue
            checked += 1
            # paired in the same statement?
            if "PwLedgerCopies++" in line:
                continue
            # or the ENCLOSING FUNCTION calls the primitive, which increments the discriminator
            # itself. A fixed line window is not good enough: the broker site's primitive call sits
            # 22 lines above its counter, and a +/-12 window reported it as a hole. Scope by the
            # function, found by walking back to the previous line that starts at column zero and
            # opens a body.
            start = 0
            for j in range(i, -1, -1):
                if lines[j].startswith("{") and j > 0 and not lines[j - 1].startswith(" "):
                    start = j
                    break
            end = len(lines)
            for j in range(i, len(lines)):
                if lines[j] == "}":
                    end = j
                    break
            if PRIMITIVE in "\n".join(lines[start:end]):
                continue
            problems.append((i + 1, name, line.strip()[:88]))
    return checked, problems


def main():
    if not SRC.exists():
        print(f"AUDIT-ERROR: {SRC} missing"); return 2
    checked, problems = audit(SRC)
    print(f"ledger invariant audit: {checked} source-counter increment(s) examined")
    for ln, name, snippet in problems:
        print(f"  FAIL line {ln}: PwLedger{name}++ is not paired with the discriminator")
        print(f"        {snippet}")
        print( "        a copy counted here can never appear as UNATTRIBUTED, so the invariant")
        print( "        cannot see an uninstrumented site on this path")
    rc = 1 if problems else 0
    print("PASS: every source counter is covered by the discriminator" if rc == 0
          else "FAIL: the invariant has a blind spot")

    if "--prove" in sys.argv:
        print("--- proof of failure: strip the synth pairing from a copy of the source")
        with tempfile.TemporaryDirectory() as td:
            mutant = pathlib.Path(td) / "main.c"
            shutil.copy(SRC, mutant)
            t = mutant.read_text(encoding="utf-8", errors="replace")
            t2 = t.replace("{ owner->PwLedgerSynth++; owner->PwLedgerCopies++; }",
                           "{ owner->PwLedgerSynth++; }")
            if t2 == t:
                print("  AUDIT-ERROR: the synth pairing this proof strips was not found"); return 2
            mutant.write_text(t2, encoding="utf-8")
            _, mp = audit(mutant)
            if mp:
                print(f"  OK   the mutant was caught ({len(mp)} finding(s))")
            else:
                print("  FAIL the mutant PASSED - this audit is decoration"); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
