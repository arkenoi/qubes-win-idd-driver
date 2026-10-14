#!/bin/bash
# sweep-gate.sh - NO ERROR-SHAPED LINE IN A HARNESS LOG MAY BE READ BY A MODEL AND WAVED THROUGH.
#
#   tools/sweep-gate.sh <harness-log> [...]                 gate: fail on any NEW shape
#   tools/sweep-gate.sh --write-baseline <out> <log> [...]   seed the baseline from known-clean runs
#
# Exit: 0 no new shape; 1 at least one NEW shape; 2 nothing could be read.
#
# WHY IT EXISTS (owner, 2026-10-14, twice in one night, the second time in capitals). Nothing swept
# the harnesses' OWN logs - log-sweep.sh covers the GUEST's, and 50 of the harnesses that drive a
# guest never call it, including every harness that grades a release. So error-shaped lines were
# graded by whoever happened to read them, and that was a model calling four "no qrexec (cause
# UNKNOWN)" lines "expected installer behaviour" without checking.
#
# WHY IT IS A BASELINE AND NOT A DECLARED LIST. The first version demanded that every error-shaped
# line be covered by a hand-written regex carrying a reason, with nothing pre-declared. Measured on
# a product-CLEAN campaign (96 of 96 checks passed): 19 flagged lines, of which 2 were a real defect
# and ~14 were explanatory prose and summary text that merely contain the words - "it cannot occur
# here", "could not detach the ISO (harmless: ...)", "product-FAIL=0". Jev on that design:
# design_sound 0.27, survives_contact 0.32, biggest flaw "matching line text catches explanatory
# prose and summaries, so the signal is swamped" - it would have been declared away until it meant
# nothing, which is the "baselined away" failure tools/lint-baseline.txt already warns about.
#
# So it works the way log-sweep.sh works: normalise each error-shaped line to a SHAPE, compare
# against a reviewed baseline, and report only what is NEW. A clean run passes. A shape nobody has
# seen before fails, and the only way to accept it is a deliberate commit to the baseline file -
# visible in a diff, with its provenance at the top of that file.
#
# NORMALISATION makes a shape stable across runs: timestamps, numbers, paths, vm names and hex go to
# placeholders, so "no qrexec for 38s" and "no qrexec for 135s" are ONE shape, and a genuinely new
# message is a genuinely new shape.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

WRITE=""
if [ "${1:-}" = "--write-baseline" ]; then WRITE="${2:?--write-baseline needs an output path}"; shift 2; fi
[ $# -ge 1 ] || { echo "usage: $0 [--write-baseline <out>] <harness-log> [...]" >&2; exit 2; }
BASE="${SWEEP_GATE_BASELINE:-mgmt/harness/harness-log-baseline.txt}"

# WIDENED 2026-10-14 after measuring RECALL on a real corpus (296 logs, 31214 lines). The first
# shape list missed, among others: "=> STALL (alive=dead halt=ignored ...)" - a stall verdict, the
# single thing this rig cares most about - plus every bare nonzero `rc=`, German OS error text
# ("nicht gefunden", "falsch geschrieben", "Fehler", "Zugriff verweigert"), hex status codes like
# 0xC0000142, and silent-result shapes like stdout_bytes=0. A gate that cannot see a STALL is not a
# gate. False positives from the widening are absorbed by the baseline, which is the whole point of
# comparing shapes rather than matching text once.
SHAPES='ERROR|FAIL|FATAL|WARNING|WARN:|refus|REFUS|cannot|could not|cause UNKNOWN|timed out|timeout|TIMEOUT|abort|ABORT|INVALID|unreadable|no qrexec|not Halted|exception|Exception|Traceback|STALL|WEDGE|alive=dead|=DEAD|=UNREAD|rc=[1-9]|exit code [1-9]|0x[0-9A-Fa-f]{8}|denied|verweigert|nicht gefunden|falsch geschrieben|Fehler|not recognized|No such|_bytes=0|SKIPPED|INCONCLUSIVE|BLOCKED|expired|abgelaufen|has stopped|wedged|exit=[1-9]|status=[1-9]|code=[1-9]|=LOST|=MISSING|BROKEN|UNREACHABLE|windows=0|never (came|arrived|appeared|fired|ran)|konnte nicht|panic|assert(ion)? fail'

# DEFECT KNOB for tools/tests/sweep-gate-selftest.sh ONLY: the pre-2026-10-14 shape list, which
# missed the stall verdict, bare rc=, German OS text, hex status codes and expiry. The recall cases
# in that self-test must FAIL with this set, or none of them is evidence about the widening.
if [ "${SWEEP_GATE_DEFECT:-}" = "1" ]; then   # GUARD:shapes
  SHAPES='ERROR|FAIL|FATAL|WARNING|refus|cannot|could not|timeout|abort|INVALID|exception'
fi

normalise() {
    sed -E \
        -e 's/^\[?[0-9]{2}:[0-9]{2}:[0-9]{2}\]?[[:space:]]*//' \
        -e 's/\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}[^]]*\]//g' \
        -e 's#/[A-Za-z0-9._/-]{8,}#<PATH>#g' \
        -e 's#[A-Za-z]:\\\\[^ ]+#<PATH>#g' \
        -e 's/\b(WIN|Win)[0-9]+[a-z]*-[a-z0-9]+/<CELL>/g' \
        -e 's/\bwin[0-9]+[a-z]*-[a-z0-9]+\b/<VM>/g' \
        -e 's/\b0x[0-9a-fA-F]+\b/<HEX>/g' \
        -e 's/\b[0-9]+\b/N/g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ //; s/ $//'
}

# WITH COUNTS. A baseline entry is otherwise a standing silencer: once "could not detach the ISO" is
# accepted, a genuine later instance of it is invisible. Jev scored that the dominant remaining flaw
# at 0.85. So the baseline records "<count> <shape>" and the gate reports a known shape whose count
# ROSE as well as one that is NEW - the same NEW/ROSE split log-sweep.sh uses against its baseline.
collect() { for l in "$@"; do [ -f "$l" ] || { echo "sweep-gate: $l does not exist" >&2; return 2; }
              grep -ahE "$SHAPES" "$l" 2>/dev/null; done | normalise | sort | uniq -c \
            | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1 /'; }
shapes_only() { sed -E 's/^[0-9]+ //'; }

if [ -n "$WRITE" ]; then
    { echo "# harness-log-baseline.txt - NORMALISED error-shaped lines seen on runs reviewed as clean."
      echo "# Seeded $(date -u +%Y-%m-%dT%H:%M:%SZ) from: $*"
      echo "#"
      echo "# tools/sweep-gate.sh reports only shapes that are NOT here. Adding a line is a deliberate"
      echo "# act in a commit: it says 'this shape was looked at and is not a finding'. A shape that IS"
      echo "# a finding gets FIXED, not added - two lines in the seeding run were the log-volume bind"
      echo "# failing on both upgrade cells, and they are deliberately absent from this file."
      collect "$@"
    } > "$WRITE" || exit 2
    echo "SWEEP-GATE-BASELINE wrote $(grep -vc '^#' "$WRITE") shape(s) to $WRITE"
    exit 0
fi

[ -f "$BASE" ] || { echo "sweep-gate: REFUSING - no baseline at $BASE (seed it with --write-baseline)" >&2; exit 2; }
NOW=$(mktemp); collect "$@" > "$NOW" || { rm -f "$NOW"; exit 2; }
BL=$(mktemp); grep -vE '^\s*(#|$)' "$BASE" > "$BL"
newn=0; rose=0
while IFS= read -r row; do
    [ -n "$row" ] || continue
    cnt=${row%% *}; shape=${row#* }
    base=$(grep -aF -- " $shape" "$BL" | head -1 | sed -E 's/^([0-9]+) .*/\1/')
    if [ -z "$base" ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE:"
        newn=$((newn+1)); printf '  NEW   x%-4s %s\n' "$cnt" "$(printf '%s' "$shape" | cut -c1-140)"
    elif [ "$cnt" -gt "$((base * 2))" ] && [ "$cnt" -gt $((base + 3)) ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE:"
        rose=$((rose+1)); printf '  ROSE  x%-4s (baseline x%s) %s\n' "$cnt" "$base" "$(printf '%s' "$shape" | cut -c1-120)"
    fi
done < "$NOW"
rm -f "$NOW" "$BL"
if [ "$newn" -gt 0 ] || [ "$rose" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT new_shapes=$newn risen_shapes=$rose"
    echo "  Each is a finding, or a shape that belongs in $BASE by a deliberate commit. Reading it and"
    echo "  moving on is not one of the options."
    exit 1
fi
echo "SWEEP-GATE-RESULT new_shapes=0 risen_shapes=0"
