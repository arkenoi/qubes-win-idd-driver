#!/usr/bin/env python3
"""Deterministic scorer for the p4 RND "judgement" steps — mechanizes the judge out of the loop.

p4-rnd5-verdict and p4-rnd3-synth-crop were kind:"judgement": in live mode run.py paused for an
operator/LLM to read the evidence and pick an answer token. But both are DETERMINISTIC decision
trees over measured integers/hashes — no discretion. This scorer computes the SAME answer token a
correct judge would, from the SAME evidence files. run.py auto-answers a judgement carrying a
`scorer` field with this token (live AND selftest-dry), mapping it to GREEN/RED/INVALID exactly as
`apply_answer` maps an operator answer — so the 3-way verdict and every V-rule are unchanged, only
the human is removed.

Falsifiability is preserved and PROVEN by the existing scenarios: the selftest walks green +
defect-p4-* dry with this scorer supplying the answer, and grades the result against each
scenario's recorded truth. The scorer must therefore reproduce truth on green (GREEN) AND be SEEN
to emit RED/INVALID on the defect fixtures (defect-p4-map-unwitnessed -> MAP_IN_AGENT_LOG/RED for
rnd5; defect-p4-caret-hash -> SYNTH_NO_SYNTHPAINT/RED for rnd3). A wrong scorer makes the selftest
deviate; it can never turn a defect green.

Usage:  rnd-score.py <rnd5-verdict|rnd3-synth-crop> <evidence-file> [<evidence-file> ...]
Prints exactly one line:  RND-ANSWER: <TOKEN>   (always exit 0; the token carries the verdict).
The TOKEN is one of the step's judgement.answers keys.
"""
import re
import sys


def read_all(paths):
    text = ""
    for p in paths:
        try:
            text += open(p, encoding="utf-8", errors="replace").read() + "\n"
        except OSError:
            pass
    return text


def counter(text, key):
    """The witness lines are 'KEY <int>' on their own line (rnd5-two-witness.txt)."""
    m = re.search(rf"^{re.escape(key)}\s+(\d+)\s*$", text, re.M)
    return int(m.group(1)) if m else None


def score_rnd5(text):
    # Apply IN ORDER (p4-rnd5-verdict decision rule). Missing counter -> EVIDENCE_INCOMPLETE.
    shot = counter(text, "SHOT_MAPPED")
    ovr_big = counter(text, "OVRMAP_BIG")
    disc = counter(text, "DISCRIM_HITS")
    shell = counter(text, "SHELL_SURFACES")
    if None in (shot, ovr_big, disc, shell):
        return "EVIDENCE_INCOMPLETE"
    if ovr_big != 0:
        return "MAP_IN_AGENT_LOG"     # agent log shows an o-r MAP at screen scale (shot is blind to it)
    if shot != 0:
        return "WINDOW_IN_SHOT"       # a managed window reached dom0
    if disc == 0 or shell == 0:
        return "STIMULUS_ABSENT"      # the Start stimulus was never established -> negative is vacuous
    return "NOMAP_BOTH_WITNESSES"     # nothing reached dom0, by both witnesses, stimulus proven


def score_rnd3(text):
    # p4-rnd3-synth-crop: judge ONLY the SYNTH/SYNTHPAINT accounting + the owner-relative crop line;
    # IGNORE any whole-window hash (a caret blink moves it).
    crop = re.search(
        r"synth rect \(owner-relative\).*?crop\s+(\S+)\s*->\s*(\S+)", text)
    synth_m = re.search(r"SYNTH events=(\d+)", text)
    synth_n = int(synth_m.group(1)) if synth_m else 0
    no_paint = ("SYNTH but NEVER" in text) or ("accounted but never painted" in text)
    if crop:                                  # a SYNTHPAINT rect was reported
        if "does not intersect" in text:
            return "RECT_NOT_IN_CAPTURE"
        a, b = crop.group(1), crop.group(2)
        return "RECT_PAINTED_CHANGED" if a != b else "RECT_IDENTICAL"
    if synth_n > 0 and no_paint:
        return "SYNTH_NO_SYNTHPAINT"          # SYNTH logged but never a SYNTHPAINT
    if synth_n > 0:
        return "SYNTH_NO_SYNTHPAINT"          # SYNTH accounted, no paint rect at all
    return "EVIDENCE_INCOMPLETE"              # accounting/crop line absent entirely


def score_precondition(text):
    """s7-precondition-authority (campaign.json): P1.0's authority rule, mechanized.

    Evidence = $MATRIX_OUT/precondition-lines.txt, written by matrix.sh: one 'cell <LABEL>' entry
    per install cell, followed by that cell's '=== PRECONDITION ===' line (the installer's own
    report of the state it FOUND - real form is JSON with "installed_qwt_count"; the older
    fixtures use the QWTPRODUCTS=<n> shorthand, both are parsed). The decision is a closed table
    over the cell SELECTOR and the FOUND count - no discretion:

        clean / fresh / 1stage / 2stage  -> the installer must have found NO QWT (count == 0)
        reinstall / upgrade / seeded / stock -> it must have found one (count >= 1)
        appvm / grade                    -> no install ran; not this check's subject (skipped)

    Anything else fails closed: an unknown selector or a count-free line proves nothing, and a
    'no' that was never measured must never read as a pass (V3). MISMATCH outranks LINE_ABSENT -
    a measured contradiction is the stronger fact - and zero install entries is LINE_ABSENT, so a
    run that listed nothing can never vacuously ALL_MATCH."""
    entries = []
    cur = None
    for line in text.splitlines():
        m = re.match(r"^cell\s+(\S+)", line)
        if m:
            cur = {"label": m.group(1), "body": []}
            entries.append(cur)
        elif cur is not None:
            cur["body"].append(line)
    verdicts = []
    for e in entries:
        lbl = e["label"].lower()
        if "appvm" in lbl or lbl.endswith("-grade"):
            continue
        if any(k in lbl for k in ("reinstall", "upgrade", "seeded", "stock")):
            want_present = True
        elif any(k in lbl for k in ("clean", "fresh", "1stage", "2stage")):
            want_present = False
        else:
            verdicts.append("MISMATCH")       # unknown selector: identity not established
            continue
        body = "\n".join(e["body"])
        pm = re.search(r"=== PRECONDITION === (.+)", body)
        if not pm:
            verdicts.append("LINE_ABSENT")
            continue
        cm = (re.search(r'"installed_qwt_count"\s*:\s*(-?\d+)', pm.group(1))
              or re.search(r"QWTPRODUCTS=(-?\d+)", pm.group(1)))
        if not cm:
            verdicts.append("LINE_ABSENT")    # a line naming no count decides nothing
            continue
        n = int(cm.group(1))                  # installer error paths report -1: matches neither
        ok = (n >= 1) if want_present else (n == 0)
        verdicts.append("ALL_MATCH" if ok else "MISMATCH")
    if not verdicts:
        return "LINE_ABSENT"
    if "MISMATCH" in verdicts:
        return "MISMATCH"
    if "LINE_ABSENT" in verdicts:
        return "LINE_ABSENT"
    return "ALL_MATCH"


SCORERS = {"rnd5-verdict": score_rnd5, "rnd3-synth-crop": score_rnd3,
           "precondition-authority": score_precondition}


def main(argv):
    if len(argv) < 3 or argv[1] not in SCORERS:
        print("RND-ANSWER: EVIDENCE_INCOMPLETE")   # unusable invocation -> INVALID, never a pass
        return 0
    token = SCORERS[argv[1]](read_all(argv[2:]))
    print(f"RND-ANSWER: {token}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
