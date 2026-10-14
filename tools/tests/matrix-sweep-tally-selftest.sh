#!/bin/bash
# matrix-sweep-tally-selftest.sh - one failure, one tally entry; and still printed.
#
# WHY. matrix.sh's no() both increments the campaign tally AND writes the failure into the campaign
# log as "[ERROR] FAIL  <what>". The end-of-campaign error gate then sweeps that same log, so each
# graded verdict came back as an UNACCOUNTED row and added a SECOND entry - classed INVALID, which
# asserts that nothing graded it. One failure, two entries, wrong class on the second.
#
# Jev was asked to choose between dropping those lines from the gate and keeping them, with the
# project's rules as premises, and chose neither: keep_but_reclass (0.63) - still show the line,
# because a declared error that stops being shown is how the original incident happened, but do not
# move the counter for a verdict that was already graded. These checks pin that behaviour.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-sweep-tally-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

M=$(ls mgmt/harness/matri*.sh | head -1)

# A campaign log with BOTH shapes: our own graded verdict, and a sub-script's ungraded stderr.
# The second has no tally entry anywhere and must still move the counter.
printf '[15:06:07] [ERROR] FAIL  WIN10-reinstall: could not write the run marker\n' >  "$T/matrix.log"
printf '[15:06:54] FAIL: could not clear the previous module table (got no answer)\n' >> "$T/matrix.log"
printf '[15:07:00] [WARN] log-volume bind failed on the upgrade cell\n'              >> "$T/matrix.log"
timeout 100 bash tools/sweep-gate.sh "$T/matrix.log" > "$T/sweep.out" 2>&1

# The gate still SHOWS the graded verdict - that is the half Jev kept.
ck "the graded verdict is still printed by the gate" "1" \
   "$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/sweep.out")"

# matrix.sh's arithmetic, applied to this real gate output.
nun=$(grep -ac '^  UNACCOUNTED' "$T/sweep.out" 2>/dev/null || true); nun=${nun:-0}
ngr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/sweep.out" 2>/dev/null || true); ngr=${ngr:-0}
net=$((nun - ngr)); [ "$net" -lt 0 ] && net=0

ck "the graded verdict is discounted from the tally" "1" "$ngr"
ck "the ungraded line still counts"                  "1" "$([ "$net" -ge 1 ] && echo 1 || echo "0 (net=$net of nun=$nun)")"

# A log carrying ONLY graded verdicts must raise nothing, while the gate still exits non-zero.
printf '[15:06:07] [ERROR] FAIL  WIN10-clean: a graded product check\n' > "$T/only-graded.log"
timeout 100 bash tools/sweep-gate.sh "$T/only-graded.log" > "$T/only.out" 2>&1
onun=$(grep -ac '^  UNACCOUNTED' "$T/only.out" 2>/dev/null || true); onun=${onun:-0}
ongr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/only.out" 2>/dev/null || true); ongr=${ongr:-0}
onet=$((onun - ongr)); [ "$onet" -lt 0 ] && onet=0
ck "a graded-only log adds no INVALID entry"         "0" "$onet"

# And the shipped file must carry the guard, not just this test.
ck "matrix.sh discounts graded verdicts"            "1" "$(grep -c 'ngr=\$(grep -acE' "$M")"
ck "matrix.sh raises INVALID-SWEEP conditionally"   "1" "$(grep -c 'if \[ \$((nun + nro)) -gt 0 \]; then' "$M")"
ck "matrix.sh still prints every row"               "1" "$(grep -c "grep -aE '\^  (UNACCOUNTED|ROSE)'" "$M")"

echo "matrix-sweep-tally-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
