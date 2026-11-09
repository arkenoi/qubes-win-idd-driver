#!/bin/bash
# log-key-drift-gate.sh - A MESSAGE'S TEXT IS A KEY. Refuse a commit that breaks one silently.
#
#   tools/hooks/log-key-drift-gate.sh                        the staged diff + every bumped submodule
#   tools/hooks/log-key-drift-gate.sh <diff-file>            a saved diff
#   tools/hooks/log-key-drift-gate.sh --sub <path> <o> <n>   one submodule range
#
# Exit: 0 nothing at risk; 1 a ledger row would be orphaned; 2 nothing could be read.
#
# SEEN TO FAIL, which is what separates a check from decoration. Against the real commit that
# caused the rc=4, replayed in the shape it will actually meet - a SUBMODULE range, not a parent
# diff: `--sub core-agent d228a03^ d228a03` exits 1, naming the run "vchan buffer full, blocking
# write" and the x43 row it orphaned. And it stays quiet where it must, all measured 2026-11-09:
# `--sub winutils f7ffa81 bd9a197` (ships, changes no message) 0; the same append diff with the
# ledger staged 0; under LOGKEY_DRIFT_REASON 0; core-agent 5b2bff9, where the text was already
# appended, 0; agent 60d00bf, which changed the (FALSE) sibling and not the keyed (TRUE) row, 0.
#
# WHY. mgmt/harness/error-ledger.txt matches a disposition on the WHOLE normalised message, and
# the row carries the RISE CEILING for it as its count. Change the text and the row stops
# matching, in two directions at once: the unaccounted channel fails LOUDLY - on 2026-11-09 a
# 25-minute guest run exited rc=4 with 12 of 12 product gates passed - while the ceiling is
# dropped SILENTLY, so a message capped at x43 could have gone to x4300 and nothing would say so.
#
# WHY THE EXISTING CHECK DOES NOT COVER IT. tools/sweep-gate.sh --verify-ledger exists for exactly
# this and cannot decide: 9 of 25 rows come back UNCERTAIN because its heuristic wants a literal
# 20+ char run taken from the ROW, and the row's <HEX>/N normalisation tokens shred it into
# fragments ("the message is probably assembled from pieces. Cannot decide; read the emitter").
# It also cannot distinguish "a condition that did not occur" from "a row whose text has drifted",
# and neither fails a run. FRAGMENT PRESENCE PROVES NOTHING: the 2026-11-09 change was an APPEND,
# so every fragment of the dead row was still in the source.
#
# WHAT IS DECIDABLE FROM A DIFF, and it is the OLD text - Jev 0.91 over three candidates
# (old_text_vs_ledger 0.93, normalise_source 0.02, run_based_staleness 0.01). A source-side
# normaliser scored last for a reason: %s expands to a caller-supplied word that is not in the
# format string at all (the row above carries "output data", which its emitting line does not),
# so no transform of the source can reproduce a row's key. The text that WAS there needs no
# transform - it is what the row was written against.
#
# THE RULE. Take the literal runs of every W/E-class log line the diff REMOVES. For each run a
# ledger row contains, require the same run to reappear EXACTLY on a W/E-class line the diff ADDS.
# Exact, not substring: an append makes the old run a prefix of the new one, which is the whole
# defect. If it does not reappear, that row is at risk and the commit must also stage the ledger.
# This catches both measured cases with one rule: the APPEND (text differs) and a DEMOTION to
# Info or Debug (the line is no longer graded at all, so the row can never match again).
#
# KNOWN LIMIT, stated rather than hidden: a C literal split across source lines puts the macro on
# the first line only, so a run that spans the split is not seen on the added side and this
# reports it. That is a false positive in the safe direction; LOGKEY_DRIFT_REASON records the
# decision, exactly as GOLDEN_RESEAL_REASON does for a seal.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

LEDGER=mgmt/harness/error-ledger.txt
MINRUN=20
[ -s "$LEDGER" ] || exit 0

# Only W and E lines are graded by the sweep, so only their text is ever a ledger key. The
# harness's own PowerShell and bash lines declare their level in the text instead of a macro.
WE_RX='Log(Warning|Error)\(|LogWarningUnlessGoingDown\(|Write-Log|\[WARN\]|\[ERROR\]'
# A format specifier ends a literal run. %S and %s are included deliberately: what they expand to
# is not in the source, so a run may not cross one.
SPEC='s/%[-+ #0-9.*lhIzjt]*[diouxXeEfgGaAcspnS%]/\n/g'

# WHERE THE EMITTERS ACTUALLY LIVE, and why this is not just `git diff --cached`. Every C log
# emitter is in a SUBMODULE (agent/, core-agent/, winutils/), and a submodule commit does not run
# the superproject's hooks: none of the three has core.hooksPath or a pre-commit of its own, so a
# gate reading only the parent's staged diff would never fire where the text actually changes - it
# would be decoration, which is the one thing a check must not be. The POINTER BUMP is the first
# moment the change can reach a package, and it is also the commit that can carry the fix, because
# the ledger is a parent-repo file. So for every submodule whose pin this commit moves, the gate
# reads that submodule's own old..new diff and applies the same rule to it.
if [ "${1:-}" = "--sub" ]; then
    # Replay one submodule range. This is how the submodule leg is PROVED, with real shas.
    [ "$#" -ge 4 ] || { echo "usage: $0 --sub <path> <old> <new>" >&2; exit 2; }
    DIFF=$(git -C "$2" diff "$3" "$4" -- '*.c' '*.h' '*.cpp' '*.ps1' 2>/dev/null)
    LEDGER_STAGED=0
elif [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
    [ -r "$1" ] || { echo "log-key-drift: cannot read $1" >&2; exit 2; }
    DIFF=$(cat "$1")
    LEDGER_STAGED=$(printf '%s\n' "$DIFF" | grep -cE "^(\+\+\+ b/)?$LEDGER")
else
    DIFF=$(git diff --cached -U0 -- '*.c' '*.h' '*.cpp' '*.ps1' '*.sh' '*.py')
    LEDGER_STAGED=$(git diff --cached --name-only | grep -cxF "$LEDGER")
    while IFS= read -r sub; do
        [ -n "$sub" ] || continue
        [ -e "$sub/.git" ] || continue
        subd=$(git diff --cached -- "$sub")
        old=$(printf '%s\n' "$subd" | sed -n 's/^-Subproject commit \([0-9a-f]\{7,\}\).*/\1/p' | head -1)
        new=$(printf '%s\n' "$subd" | sed -n 's/^+Subproject commit \([0-9a-f]\{7,\}\).*/\1/p' | head -1)
        [ -n "$old" ] && [ -n "$new" ] || continue
        subdiff=$(git -C "$sub" diff "$old" "$new" -- '*.c' '*.h' '*.cpp' '*.ps1' 2>/dev/null)
        [ -n "$subdiff" ] && DIFF="$DIFF
$subdiff"
    done < <(git diff --cached --name-only)
fi
[ -n "$DIFF" ] || exit 0

# The runs on each side. Same extraction both times so the comparison is of like with like.
REMOVED=$(printf '%s\n' "$DIFF" | grep -E '^-' | grep -E "$WE_RX" \
    | grep -oE '"[^"]*"' | sed -e 's/^"//' -e 's/"$//' -e "$SPEC" \
    | sed -e 's/^[^A-Za-z(]*//' -e 's/[[:space:]]*$//' | grep -E ".{$MINRUN,}" | grep ' ' | sort -u)
ADDED=$(printf '%s\n' "$DIFF" | grep -E '^\+' | grep -E "$WE_RX" \
    | grep -oE '"[^"]*"' | sed -e 's/^"//' -e 's/"$//' -e "$SPEC" \
    | sed -e 's/^[^A-Za-z(]*//' -e 's/[[:space:]]*$//' | grep -E ".{$MINRUN,}" | grep ' ' | sort -u)
[ -n "$REMOVED" ] || exit 0

AT_RISK=0
while IFS= read -r run; do
    [ -n "$run" ] || continue
    row=$(grep -m1 -F -- "$run" "$LEDGER")
    [ -n "$row" ] || continue
    case "$row" in \#*) continue ;; esac
    still=$(printf '%s\n' "$ADDED" | grep -cxF -- "$run")
    [ "$still" -gt 0 ] && continue
    if [ "$AT_RISK" -eq 0 ]; then
        echo "BLOCKED: this diff changes the text or the severity of a log message that"
        echo "         $LEDGER keys a disposition on. The row stops matching, and the"
        echo "         RISE CEILING it carries is lost without a sound."
    fi
    AT_RISK=$((AT_RISK+1))
    echo "  run no longer emitted at W/E: \"$run\""
    echo "    ledger row: $(printf '%s' "$row" | sed 's/   #.*//' | cut -c1-120)"
done <<< "$REMOVED"

[ "$AT_RISK" -eq 0 ] && exit 0
if [ -n "${LOGKEY_DRIFT_REASON:-}" ]; then
    echo "log-key-drift: ALLOWED by LOGKEY_DRIFT_REASON=$LOGKEY_DRIFT_REASON"
    exit 0
fi
if [ "$LEDGER_STAGED" -gt 0 ]; then
    echo "log-key-drift: $LEDGER is in this commit - the row(s) above are being re-keyed. OK."
    exit 0
fi
echo "log-key-drift REFUSED: $AT_RISK row(s) at risk and $LEDGER is not in this commit."
echo "  Re-key or retire the row in the SAME commit, or set LOGKEY_DRIFT_REASON=<why> to record"
echo "  a deliberate exception. Do not use --no-verify: it also skips the capture gate."
exit 1
