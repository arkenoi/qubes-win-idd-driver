#!/bin/bash
# jev-artifact.sh - put the ARTIFACT in front of Jev. Never a description of it.
#
#   tools/jev-artifact.sh <rubric.json> <source-file> [more-source-files...] -- <command> [more commands...]
#
# WHY THIS EXISTS, and why it takes no prose argument. On 2026-10-14 the error detector was scored
# about ten times by writing a "state document" describing it - what it does, what was fixed, why
# the remaining gaps are acceptable - and watching the number move: 0.32, 0.49, 0.53, 0.60, 0.63.
# Every one of those measured the DOCUMENT. The same tool, judged from its own source, its test
# output and its cross-checks against real data, scored 0.83. The owner named it exactly:
# "checking the prose is exactly cheating the classifier" and "you should ALWAYS check the tool".
#
# A state document is advocacy. Its author chooses which caveats appear, how they are phrased, and
# what sits next to them - so the score tracks the advocacy and improves when the writing improves.
# That is not a measurement of anything, and a rising number from it is not progress.
#
# So: this script accepts SOURCE FILES and COMMANDS TO RUN. It concatenates the sources verbatim and
# the commands' real output, adds one fixed neutral header it does not let the caller change, and
# sends that. There is no argument for an explanation, on purpose.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
RUB="${1:?usage: $0 <rubric.json> <source>... -- <command>...}"; shift
[ -f "$RUB" ] || { echo "jev-artifact: no rubric at $RUB" >&2; exit 2; }

SRC=(); CMD=(); seen_sep=0
for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" = 1 ]; then CMD+=("$a"); else SRC+=("$a"); fi
done
[ "${#SRC[@]}" -gt 0 ] || { echo "jev-artifact: name at least one source file" >&2; exit 2; }

# COMPLETENESS IS A FIXED RULE, NOT A PER-RUN CHOICE. Sending only the tool's source scored it 0.64;
# adding its TEST SOURCE and the code that WIRES it scored the same unchanged tool 0.72, because the
# judge could finally see what is actually asserted and where it runs. That is a real gap in the
# artifact - but which extras to include is exactly the kind of decision that becomes advocacy if it
# is remade every run. So the rule is stated once here and applied every time:
#
#   include EVERY IMPLEMENTATION of the function being judged, its TESTS, and the code that CALLS
#   it. Nothing else, and never a narrative.
#
# "Every implementation" is not pedantry, it is the hole this rule was first written with. An error
# detector was judged sound from tools/sweep-gate.sh - which reads only declared severity and never
# guesses - while tools/log-sweep.py, the sweeper that actually handles the GUEST logs, was
# assigning E and W BY VOCABULARY the whole time. Both answer "is this line an error"; only one was
# in the artifact, so the score was never about the question it appeared to answer. Curating the
# narrative and curating the SCOPE are the same mistake.
#
# If a named source has an obvious test file beside it and that file was not named, this says so
# rather than quietly sending a partial artifact.
for f in "${SRC[@]}"; do
    base=$(basename "$f"); stem="${base%.*}"
    for cand in "tools/tests/${stem}-selftest.sh" "tools/tests/${stem}-test.sh" "tools/tests/${stem}.ps1"; do
        [ -f "$cand" ] || continue
        case " ${SRC[*]} " in *" $cand "*) ;; *) echo "jev-artifact: NOTE $cand exists and was not included - a partial artifact understates the thing being judged" >&2 ;; esac
    done
done

ART=$(mktemp); trap 'rm -f "$ART"' EXIT
{
  # FIXED header. The caller cannot supply or edit it - that is the whole point.
  echo "JUDGE THIS FROM THE ARTIFACT ITSELF."
  echo
  echo "Below is the complete source of what is being judged, followed by the real output of"
  echo "commands run against it just now. No description, summary or argument is offered: the"
  echo "author of the thing is not a reliable narrator of it. Judge what is here."
  echo
  for f in "${SRC[@]}"; do
      [ -f "$f" ] || { echo "jev-artifact: no such source $f" >&2; exit 2; }
      echo "=== SOURCE: $f"; echo '---'; cat "$f"; echo
  done
  for c in "${CMD[@]}"; do
      echo "=== RAN: $c"; echo '---'
      bash -c "$c" 2>&1
      echo "    (exit $?)"; echo
  done
} > "$ART"
echo "jev-artifact: $(wc -c < "$ART") bytes, $(wc -l < "$ART") lines, ${#SRC[@]} source(s), ${#CMD[@]} command(s)" >&2
# JEV_ARTIFACT_OUT writes the judge's full answer objects, so a mid score can be READ instead of
# guessed at. It cannot touch the artifact - that is still built above from sources and commands
# only, under the fixed header.
if [ -n "${JEV_ARTIFACT_OUT:-}" ]; then
    python3 tools/jev.py "$RUB" "$ART" --out "$JEV_ARTIFACT_OUT"
else
    python3 tools/jev.py "$RUB" "$ART"
fi
