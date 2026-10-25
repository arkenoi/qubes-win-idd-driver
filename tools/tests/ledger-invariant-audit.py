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
# Refused is BOOKKEEPING, not a pixel source: it is the difference between an attempt and a
# copy. Left out of this set, the old direction reads the refusal helper itself as an
# uninstrumented copy site.
NOT_SOURCES = {"Copies", "CopiesPrev", "FramesSeen", "None", "Unattributed",
               "UnattributedLogged", "Class", "EngineFed", "Refused"}
# BOTH copy primitives. This was the single name "PwSliceCopyAndDamage", and the broker path
# has had its own primitive since 2026-10-01 (PwBrokerCopyDiff, which increments the
# discriminator itself), so the broker attribution's enclosing function looked unpaired and
# this audit was RED on a correct tree - two findings at main.c:11847/11848, unseen because
# nothing ran it. A check that names one of two implementations measures the name.
PRIMITIVES = ("PwSliceCopyAndDamage", "PwBrokerCopyDiff")   # ...AndDamage and ...AndDamageSrc
REFUSE = "PwLedgerRefuse"


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
            start, end = _body_range(lines, i)
            if any(p in "\n".join(lines[start:end]) for p in PRIMITIVES):
                continue
            problems.append((i + 1, name, line.strip()[:88]))
    return checked, problems


def _body_range(lines, i):
    """The enclosing function body of line i. ANY brace at column zero opens one - this codebase
    puts the brace on its own line. The condition that used to live inline here ALSO required the
    preceding line to start at column zero, which a MULTI-LINE SIGNATURE does not satisfy
    (PwSliceCopyAndDamageSrc's wraps): the walk skipped the real opening brace, kept going back,
    and the computed body spanned several functions."""
    start = 0
    for j in range(i, -1, -1):
        if lines[j].startswith("{"):
            start = j
            break
    end = len(lines)
    for j in range(i, len(lines)):
        if lines[j] == "}":
            end = j
            break
    return (start, end)


def audit_refusals(path: pathlib.Path):
    """THE OTHER DIRECTION. A function that increments PwLedgerCopies has counted the copy before it
    validates anything, so every path that leaves WITHOUT copying must say so - or the global
    invariant reads the difference as a copy site nobody instrumented. Not hypothetical:
    QGALEDGERGAP hwnd=0x1021c copies=4 attributed=3 failed a release campaign on 2026-10-25 with
    every copy site correctly instrumented."""
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = [strip_comments(l) for l in text.split("\n")]
    ranges = []
    for i, line in enumerate(lines):
        if "PwLedgerCopies++" not in line:
            continue
        r = _body_range(lines, i)
        if r not in ranges:
            ranges.append(r)
    problems, checked = [], 0
    for start, end in ranges:
        for i in range(start, end):
            if re.search(r"\breturn\s+FALSE\s*;", lines[i]):
                checked += 1
                problems.append((i + 1, lines[i].strip()[:88]))
            elif REFUSE in lines[i] and "return" in lines[i]:
                checked += 1
    return checked, problems


def audit_helper_and_gate(path: pathlib.Path):
    """THE COUNTER MUST ACTUALLY MOVE, AND A REFUSED FRAME MUST NOT BE ATTRIBUTED.

    audit_refusals proves every exit routes through PwLedgerRefuse. That is satisfied just as well
    by a helper that returns FALSE and counts nothing - every path would be "covered" while the
    counter stayed at zero, the invariant stayed copies <= attributed, and QGALEDGERGAP went on
    firing on healthy guests. Jev named exactly this gap when the fix was reviewed
    (needs_refusal_counter_test 0.62), so it is answered here as three properties, each with its
    own mutant - and then answered again by EXECUTION in audit_arithmetic below, which compiles the
    shipped expressions and runs them over the tuple the failing campaign measured.

      1. the helper increments PwLedgerRefused and returns FALSE;
      2. the invariant that raises the warning includes the refused term - otherwise a counted
         refusal is still read as an uninstrumented copy;
      3. the broker's two attributions are reachable only through the primitive's captured result,
         so a refusal cannot be credited as a frame.
    """
    lines = [strip_comments(l) for l in path.read_text(encoding="utf-8", errors="replace").split("\n")]
    problems, checked = [], 0

    # 1. the helper's body
    helper = None
    for i, line in enumerate(lines):
        if re.search(r"\bPwLedgerRefuse\s*\(\s*IN\s+OUT", line) or \
           re.search(r"BOOL\s+PwLedgerRefuse\s*\(", line):
            helper = _body_range(lines, i)
            break
    if helper is None:
        problems.append((0, "PwLedgerRefuse is not defined in this file"))
    else:
        body = "\n".join(lines[helper[0]:helper[1]])
        checked += 1
        if "PwLedgerRefused++" not in body:
            problems.append((helper[0] + 1, "PwLedgerRefuse does not increment PwLedgerRefused - "
                                            "every refusal would route through a counter that never moves"))
        if not re.search(r"return\s+FALSE\s*;", body):
            problems.append((helper[0] + 1, "PwLedgerRefuse does not return FALSE - a refusal would "
                                            "read to its caller as a copy that happened"))

    # 2. every arithmetic that relates the discriminator to the attributed total carries the
    # refused term - the comparison that raises the warning AND the subtraction that sizes the gap.
    #
    # THIS LEG MEASURED NOTHING when it was written: it searched for `\bcopies\b`, and the source
    # says `entry->PwLedgerCopies`, where neither the word boundary nor the lower case matches. The
    # population was empty, so the mutant that strips the refused term PASSED and the property was
    # decoration. An empty population is a green that measured nothing, so the emptiness is now a
    # finding in its own right.
    inv = [i for i, l in enumerate(lines) if "PwLedgerCopies" in l and "attributed" in l]
    if not inv:
        problems.append((0, "no line relates PwLedgerCopies to the attributed total - this property "
                            "measured NOTHING, which is how it passed a mutant that removed the term"))
    for i in inv:
        checked += 1
        if "Refused" not in lines[i]:
            problems.append((i + 1, "relates PwLedgerCopies to attributed without the refused term: "
                                    "a counted refusal is still read as an uninstrumented copy site"))

    # 3. the broker attributions are UNREACHABLE when the primitive refused.
    #
    # NOT a spelling. The first version of this leg demanded the literal `if (brokerCopied)` and
    # went red on correct code, because the product writes the refusal arm first:
    #     if (!brokerCopied)         { /* refused: counted as a refusal, not as a frame */ }
    #     else if (ls && ls->TickPw) entry->PwLedgerBrokerPw++;
    #     else                       entry->PwLedgerBrokerWgc++;
    # which is the clearer way round - the comment sits on the case it explains. So the property is
    # the POLARITY TOGETHER WITH THE ARM: a negated condition requires the attribution to be in a
    # later arm (`else`), a positive one requires it to be inside the arm the condition guards.
    # Both mutants are driven below: delete the condition, and flip its polarity while leaving the
    # arms where they are - the second is the one a spelling check cannot catch.
    for i, line in enumerate(lines):
        m = re.search(r"entry->(PwLedgerBrokerWgc|PwLedgerBrokerPw)\+\+", line)
        if not m:
            continue
        checked += 1
        cond = None
        for j in range(i - 1, max(-1, i - 20), -1):
            c = re.search(r"\bif\s*\(\s*(!?)\s*brokerCopied\s*\)", lines[j])
            if c:
                cond = bool(c.group(1))
                break
        in_else = lines[i].lstrip().startswith("else")
        if cond is None:
            problems.append((i + 1, "%s++ is not gated on the primitive's captured result - a "
                                    "refused broker frame would be attributed as a copy" % m.group(1)))
        elif cond is True and not in_else:
            problems.append((i + 1, "%s++ sits INSIDE the `if (!brokerCopied)` arm - it is counted "
                                    "exactly when the primitive refused" % m.group(1)))
        elif cond is False and in_else:
            problems.append((i + 1, "%s++ is the `else` of `if (brokerCopied)` - it is counted "
                                    "exactly when the primitive refused" % m.group(1)))
    return checked, problems


def audit_arithmetic(path: pathlib.Path):
    """RUN THE SHIPPED ARITHMETIC. The other three properties are source SHAPE - the refused term is
    present, the helper increments, the gate has the right polarity. None of them answers the
    question the acceptance run asked, which is a question about NUMBERS: given the tuple actually
    measured on a healthy guest, does the warning still fire?

    The premise this docstring used to carry was that it could not be answered - "there is no local
    Windows compiler to answer it by running the code". That premise was wrong, and believing it is
    what left Jev's needs_refusal_counter_test (0.62) standing for a day. The invariant is two lines
    of unsigned integer arithmetic. It needs A compiler, not a Windows one. So the two expressions
    are EXTRACTED VERBATIM from the product source, compiled by the host cc, and run over tuples -
    one of which is the tuple off the failing campaign:

        QGALEDGERGAP hwnd=0x1021c copies=4 attributed=3   (acceptance 40142194040, 2026-10-25)

    with the fourth number, refused=1, being the one the product did not have a counter for. The
    leg is worth having only because its mutant arm goes red: strip the refused term and THAT tuple
    warns again, which is the pre-fix behaviour and is the sweep line the release reported. Nothing
    here reads a test; the subject is agent/gui-agent/main.c.
    """
    lines = [strip_comments(l) for l in path.read_text(encoding="utf-8", errors="replace").split("\n")]
    problems, checked = [], 0

    # Extract, never retype. A hand-copied expression tests the copy.
    cmps = [m.group(1).strip() for m in
            (re.search(r"\bif\s*\((\s*entry->PwLedgerCopies\s*[<>=!]=?[^)]*\battributed\b[^)]*)\)\s*$", l)
             for l in lines) if m]
    # The OPERATOR is a wildcard on purpose. Hardcoding `<=` sent the `<` mutant red on this
    # extraction instead of on the underflow tuple, which would leave that tuple never seen to
    # fail - decoration. `attributed` is required so the PwLedgerCopiesPrev comparison, which is
    # a different question, is not a second match.
    subs = [m.group(1).strip() for m in
            (re.search(r"\bentry->PwLedgerUnattributed\s*=\s*(.+?);", l) for l in lines) if m]
    if len(cmps) != 1:
        problems.append((0, "found %d early-return comparison(s) on PwLedgerCopies, want exactly 1 - "
                            "this leg cannot say WHICH arithmetic runs" % len(cmps)))
    if len(subs) != 1:
        problems.append((0, "found %d assignment(s) to PwLedgerUnattributed, want exactly 1" % len(subs)))
    if problems:
        return checked, problems, None

    cc = shutil.which("cc") or shutil.which("gcc")
    if cc is None:
        # INSTRUMENT, not product. A green here would mean the arithmetic was never run.
        return checked, [], "no C compiler on PATH (cc/gcc) - the arithmetic was NOT executed"

    # copies, attributed, refused, want_warning, want_gap
    cases = (
        ("the measured acceptance case", 4, 3, 1, False, 0),
        ("one genuinely uninstrumented copy site", 4, 2, 1, True, 1),
        ("an idle window", 0, 0, 0, False, 0),
        ("every attempt refused", 3, 0, 3, False, 0),
        ("every copy attributed, nothing refused", 5, 5, 0, False, 0),
        ("two uninstrumented sites alongside refusals", 9, 5, 2, True, 2),
        # If the comparison were < or ==, this falls through and the ULONG64 subtraction
        # underflows to ~1.8e19, which dom0 would read as an astronomical gap.
        ("more attributed than copies - must not underflow", 3, 4, 0, False, 0),
    )
    prog = """#include <stdio.h>
#include <stdlib.h>
typedef unsigned long long ULONG64;
struct E { ULONG64 PwLedgerCopies, PwLedgerRefused, PwLedgerUnattributed; };
static int probe(ULONG64 copies, ULONG64 att, ULONG64 refused, ULONG64 *gap) {
    struct E e; struct E *entry = &e;
    ULONG64 attributed = att;
    entry->PwLedgerCopies = copies; entry->PwLedgerRefused = refused;
    entry->PwLedgerUnattributed = 0;
    if (%s) { *gap = entry->PwLedgerUnattributed; return 0; }   /* no warning */
    entry->PwLedgerUnattributed = %s;
    *gap = entry->PwLedgerUnattributed; return 1;
}
int main(int argc, char **argv) {
    int i; for (i = 1; i + 2 < argc; i += 3) {
        ULONG64 g = 0;
        int w = probe(strtoull(argv[i],0,10), strtoull(argv[i+1],0,10), strtoull(argv[i+2],0,10), &g);
        printf("%%d %%llu\\n", w, g);
    }
    return 0;
}
""" % (cmps[0], subs[0])
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        (d / "probe.c").write_text(prog, encoding="utf-8")
        cp = subprocess.run([cc, "-O1", "-o", str(d / "probe"), str(d / "probe.c")],
                            capture_output=True, text=True)
        if cp.returncode != 0:
            return checked, [], ("the extracted arithmetic did not compile: " +
                                 (cp.stderr.strip().split("\n") or [""])[-1])
        argv = []
        for _, c, a, r, _, _ in cases:
            argv += [str(c), str(a), str(r)]
        out = subprocess.run([str(d / "probe")] + argv, capture_output=True, text=True)
        rows = [l.split() for l in out.stdout.strip().split("\n") if l.strip()]
    if len(rows) != len(cases):
        return checked, [], "the probe printed %d row(s) for %d case(s)" % (len(rows), len(cases))
    for (name, c, a, r, want_w, want_g), row in zip(cases, rows):
        checked += 1
        got_w, got_g = row[0] == "1", int(row[1])
        if got_w != want_w:
            problems.append((0, "copies=%d attributed=%d refused=%d %s a QGALEDGERGAP warning "
                                "(%s) - %s" % (c, a, r, "raises" if got_w else "raises NO",
                                               name, "a healthy guest is reported as a defect"
                                               if got_w else "an uninstrumented site is invisible")))
        elif got_w and got_g != want_g:
            problems.append((0, "copies=%d attributed=%d refused=%d sizes the gap at %d, want %d (%s)"
                             % (c, a, r, got_g, want_g, name)))
    return checked, problems, None


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
    rchecked, rproblems = audit_refusals(SRC)
    print(f"refusal audit: {rchecked} exit path(s) examined inside the copy primitives")
    for ln, snippet in rproblems:
        print(f"  FAIL line {ln}: leaves a copy primitive without counting the refusal")
        print(f"        {snippet}")
        print( "        PwLedgerCopies was already incremented on entry, so this path counts")
        print( "        a copy that never happened - use `return PwLedgerRefuse(entry);`")
    hchecked, hproblems = audit_helper_and_gate(SRC)
    print(f"refusal-counter audit: {hchecked} propert(y/ies) examined - the helper, the invariant, the broker gate")
    for ln, why in hproblems:
        print(f"  FAIL line {ln}: {why}")
    achecked, aproblems, anote = audit_arithmetic(SRC)
    if anote:
        # An instrument that could not run is UNCOVERED, never a pass.
        print(f"AUDIT-ERROR: the arithmetic leg did not run: {anote}")
        return 2
    print(f"arithmetic audit: {achecked} tuple(s) run through the SHIPPED expressions, compiled by cc")
    for _, why in aproblems:
        print(f"  FAIL {why}")
    rc = 1 if (problems or rproblems or hproblems or aproblems) else 0
    print("PASS: every source counter is covered by the discriminator, every refusal is counted, the "
          "counter and the gate are real, and the measured tuple raises nothing"
          if rc == 0 else "FAIL: the invariant has a blind spot")

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

        print("--- proof of failure (refusals): turn one counted refusal back into a bare return")
        with tempfile.TemporaryDirectory() as td:
            mutant = pathlib.Path(td) / "main.c"
            shutil.copy(SRC, mutant)
            t = mutant.read_text(encoding="utf-8", errors="replace")
            t2 = t.replace("return PwLedgerRefuse(entry);", "return FALSE;", 1)
            if t2 == t:
                print("  AUDIT-ERROR: no counted refusal to strip - is the product fix applied?")
                return 2
            mutant.write_text(t2, encoding="utf-8")
            _, mp2 = audit_refusals(mutant)
            if mp2:
                print(f"  OK   the refusal mutant was caught ({len(mp2)} finding(s))")
            else:
                print("  BAD  the refusal mutant PASSED - this direction is decoration"); rc = 1

        # THREE MORE MUTANTS, one per property, because "every path is covered" is satisfied by a
        # helper that counts nothing - which is the whole reason this third audit exists.
        for label, old, new, fn in (
            ("a helper that counts nothing",
             "entry->PwLedgerRefused++;", "/* mutant: counts nothing */;", audit_helper_and_gate),
            ("an invariant without the refused term",
             "attributed + entry->PwLedgerRefused", "attributed", audit_helper_and_gate),
            ("an ungated broker attribution",
             "if (!brokerCopied)", "if (TRUE)", audit_helper_and_gate),
            ("a broker gate with its polarity flipped and the arms left alone",
             "if (!brokerCopied)", "if (brokerCopied)", audit_helper_and_gate),
        ):
            print(f"--- proof of failure: {label}")
            with tempfile.TemporaryDirectory() as td:
                mutant = pathlib.Path(td) / "main.c"
                shutil.copy(SRC, mutant)
                src = mutant.read_text(encoding="utf-8", errors="replace")
                m = src.replace(old, new, 1)
                if m == src:
                    print(f"  AUDIT-ERROR: the text this proof mutates is absent: {old!r}")
                    return 2
                mutant.write_text(m, encoding="utf-8")
                _, mp3 = fn(mutant)
                if mp3:
                    print(f"  OK   caught ({len(mp3)} finding(s))")
                else:
                    print("  BAD  the mutant PASSED - that property is decoration"); rc = 1
        # THE ONE THAT DECIDES. Put the arithmetic back the way it was when the campaign ran, and
        # the measured tuple must warn again. A green arithmetic leg over a tree where the refused
        # term never mattered would be the same decoration as the \bcopies\b leg that measured an
        # empty population.
        print("--- proof of failure: the pre-fix arithmetic, on the tuple the campaign measured")
        with tempfile.TemporaryDirectory() as td:
            mutant = pathlib.Path(td) / "main.c"
            shutil.copy(SRC, mutant)
            src = mutant.read_text(encoding="utf-8", errors="replace")
            m = src
            for old_t, new_t in (("attributed + entry->PwLedgerRefused", "attributed"),
                                 ("- attributed - entry->PwLedgerRefused", "- attributed")):
                if m.count(old_t) != 1:
                    print(f"  AUDIT-ERROR: {old_t!r} occurs {m.count(old_t)} time(s), want 1")
                    return 2
                m = m.replace(old_t, new_t, 1)
            mutant.write_text(m, encoding="utf-8")
            ac, ap, an = audit_arithmetic(mutant)
            if an:
                print(f"  AUDIT-ERROR: the mutant's arithmetic did not run: {an}"); return 2
            if any("copies=4 attributed=3 refused=1" in why for _, why in ap):
                print(f"  OK   caught: without the refused term the measured tuple warns again "
                      f"({len(ap)} finding(s) over {ac} tuple(s))")
            else:
                print("  BAD  the pre-fix arithmetic passed the measured tuple - this leg is "
                      "decoration, or the tuple no longer exercises the term"); rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
