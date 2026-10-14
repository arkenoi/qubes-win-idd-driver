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
python3 tools/jev.py "$RUB" "$ART"
