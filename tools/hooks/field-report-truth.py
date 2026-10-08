#!/usr/bin/env python3
"""A REPRODUCTION IS NEVER THE SOURCE OF TRUTH FOR A FIELD REPORT.

Owner, 2026-10-08: "i would also note you are known from prominently faking test conditions. so,
the reproduction is never source of truth".

PAID FOR TWICE IN ONE WEEK. Two FIELD-REPORTED P1s were recorded FIXED and "VERIFIED 2026-10-06 on
his environment", closing on the 4.3.35 release, on the strength of a SCRIPTED stimulus run on a
clone of a sealed golden. The reporter then reported failures on 4.3.35. Jev, asked whether
recording that as verified on his environment was sound: 0.17.

A rig run is evidence about OUR conditions. It can show that a stimulus behaves a certain way on a
clone of an environment we assembled; it cannot establish anything about the reporter's machine,
and env-assert passing is not his condition. So an entry marked FIELD-REPORTED may not carry a
verified-on-his-environment claim, nor say that it closes on a release, unless it also carries
REPORTER-CONFIRMED - which only the reporter saying so can justify. Everything else is written as
what WE RAN.

Reads the file's content on STDIN (so the hook can feed it the STAGED copy via `git show`) and
takes the path as argv[1] for the message. Exit 0 = clean, 1 = refuse, 2 = could not run.

NOTE ON ITS OWN SHAPE: this is a FILE and not a heredoc on purpose. The first version was
`git show ":$f" | python3 - "$f" <<'PY'`, where the heredoc is stdin, so the program was read from
stdin and the piped register never arrived - the check passed the exact text it was written to
refuse. A check that cannot fail is decoration (see tools/tests/field-report-truth-selftest.sh,
which drives it against the real pre-retraction revision).
"""
import re
import sys

# STRUCTURAL, NOT LEXICAL. The first version matched the PROSE "verified on his environment", and a
# register has to be able to DISCUSS a claim it is withdrawing: it flagged both the retraction
# ("NOT VERIFIED ON HIS ENVIRONMENT") and the sentence recording Jev's score on having made it. No
# regex tells "we claim X" from "we are writing about having claimed X", so the prose matcher is
# gone. What is checked instead are the two things that actually decide whether a field report is
# treated as settled, and neither is a matter of wording:
#   1. CLOSES-ON-RELEASE - a release cannot close a field report; only the reporter can.
#   2. MOVED TO issues-closed.md - the act of closing it.
# Wording discipline ("write what WE RAN") is a judgement, so it stays with the human and the
# memory rather than pretending to be enforceable here.
CLAIMS = (
    (re.compile(r"\bCloses when\b", re.I), "says a RELEASE closes it - only the reporter can"),
)


# A RETRACTION IS NOT A CLAIM. The text that WITHDRAWS one necessarily quotes it - "NOT VERIFIED ON
# HIS ENVIRONMENT - CLAIM RETRACTED" - so judging the whole block flagged the correction itself.
# Each MATCH SITE is judged on the words immediately before it instead, which is far harder to
# satisfy by accident than a block-level "RETRACTED" token anywhere would be.
NEGATED_BEFORE = re.compile(r"(?:\bNOT\b|\bNEVER\b|RETRACTED|WITHDRAWN|\bno longer\b)[\s\"\u201c\u201d'*:-]{0,8}$", re.I)


def offenders(src, name):
    out = []
    closing_file = name.endswith("issues-closed.md")
    for block in re.split(r"\n(?=- )", src):
        one = " ".join(block.split())
        if not re.search(r"FIELD-REPORTED", one):
            continue
        if re.search(r"REPORTER-CONFIRMED", one):
            continue
        head = re.sub(r"^- P[0-9] \[[^\]]*\]\s*", "", one)[:90]
        if closing_file:
            # THE ACT OF CLOSING IT. Nothing we run can justify this - not a passing reproduction,
            # not an env-asserted clone, not a green gate.
            out.append("is CLOSED without the reporter confirming it: %s" % head)
            continue
        for rx, what in CLAIMS:
            if rx.search(one):
                out.append("%s: %s" % (what, head))
                break
    return out


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "(stdin)"
    try:
        src = sys.stdin.read()
    except Exception as e:                                  # pragma: no cover
        print("field-report-truth: could not read %s: %s" % (name, e))
        return 2
    if not src.strip():
        # MISSING DATA FAILS: an empty read is how the heredoc bug looked, and it looked clean.
        print("field-report-truth: %s arrived EMPTY on stdin - the check did not run" % name)
        return 2
    bad = offenders(src, name)
    if not bad:
        return 0
    print("BLOCKED: %s - a FIELD-REPORTED entry makes a claim only the reporter can justify:" % name)
    for x in bad:
        print("         " + x)
    print("         A reproduction is never the source of truth for a field report (owner 2026-10-08).")
    print("         Write what WE RAN, or add REPORTER-CONFIRMED with what the reporter said.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
