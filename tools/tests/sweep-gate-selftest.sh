#!/bin/bash
# sweep-gate-selftest.sh - does the error gate actually gate?
#
# Every case here was seen to FAIL before it was seen to pass. The two that matter most:
#   T2  the gate must LOSE recall when deliberately broken. A check that cannot fail is decoration,
#       and this tool's first --verify mode compared its own regex against itself and printed
#       EXHAUSTIVE while missing `WARNING log-volume bind failed` - the very incident it was built
#       for, which carries no bracketed level.
#   T7  the corpus must still match what the emitters EMIT. Rewording a harness message without
#       re-running the regenerator would leave the gate measured against text nothing prints.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# T0 - THE CORPUS MUST NOT SHRINK. Every recall ratio gets easier as the ground truth gets smaller,
# and this suite once printed 7/7 green after a broken regenerator silently cut the corpus to four
# MUST lines. The floor is asserted before any ratio is believed.
FLOOR_MUST=21; FLOOR_BENIGN=13
nm=$(grep -ac '^MUST' mgmt/harness/error-corpus.txt || echo 0)
nb=$(grep -ac '^BENIGN' mgmt/harness/error-corpus.txt || echo 0)
if [ "${nm:-0}" -ge "$FLOOR_MUST" ] && [ "${nb:-0}" -ge "$FLOOR_BENIGN" ]; then
  ok "T0 corpus holds $nm MUST / $nb BENIGN (floor $FLOOR_MUST/$FLOOR_BENIGN)"
else no "T0 the corpus SHRANK to $nm MUST / $nb BENIGN - a smaller corpus is an easier gate" "raise it back or lower the floor deliberately"; fi

# T1 - recall and precision against the committed corpus of real, filed defects
out=$(bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qa 'recall=\([0-9]*\)/\1 '; then
  ok "T1 every filed defect's own line is surfaced ($(printf '%s' "$out" | grep -ao 'recall=[^ ]*'))"
else no "T1 corpus recall is not 100%" "$(printf '%s' "$out" | head -3)"; fi

# T2 - THE GATE MUST BE ABLE TO FAIL. Dropping the W class must lose the gui-agent crash loop and
# the two log-volume warnings, which are W/WARNING lines.
out=$(SWEEP_GATE_DEFECT=1 bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'MISSED'; then
  ok "T2 a deliberately broken gate loses recall ($(printf '%s' "$out" | grep -ao 'recall=[^ ]*'))"
else no "T2 breaking the gate did not fail the check" "$out"; fi

# T3 - an empty or unreadable corpus is INCONCLUSIVE, never a pass. Two empty counts compared equal
# and printed EXHAUSTIVE when this was first checked by hand with a missing `bc`.
printf '# nothing\n' > "$T/empty-corpus.txt"
out=$(SWEEP_GATE_CORPUS="$T/empty-corpus.txt" bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qa INCONCLUSIVE; then ok "T3 an empty corpus is inconclusive, not a pass"
else no "T3 empty corpus did not report INCONCLUSIVE (rc=$rc)" "$out"; fi

# T4 - with no ledger the gate refuses rather than passing everything
printf 'x\n' > "$T/a.log"
out=$(SWEEP_GATE_LEDGER="$T/nope.txt" bash tools/sweep-gate.sh "$T/a.log" 2>&1); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qa REFUSING; then ok "T4 no ledger -> refuses"
else no "T4 ran without a ledger (rc=$rc)" "$out"; fi

# T5 - THE PIPEFAIL TRAP. A match-free file LAST must not swallow earlier findings: `grep` returns 1
# on no-match and under `set -o pipefail` that made the whole tool exit 2 silently, so 20 logs
# reported findings and 130 reported nothing depending on the last file. Measured 2026-10-14.
printf '[ERROR] something real broke\n' > "$T/has.log"; printf 'nothing to see\n' > "$T/none.log"
printf '# empty\n' > "$T/el.txt"
out=$(SWEEP_GATE_LEDGER="$T/el.txt" bash tools/sweep-gate.sh "$T/has.log" "$T/none.log" 2>&1)
if printf '%s' "$out" | grep -qa 'something real broke'; then ok "T5 a match-free file last does not swallow findings"
else no "T5 findings lost when the last file has no match" "$out"; fi

# T6 - a ledger entry accounts for a message, and only that message
# seed, then write a real reason over the seeder's TODO - a seeded row deliberately does not account
bash tools/sweep-gate.sh --write-ledger "$T/led.txt" "$T/has.log" >/dev/null
sed -i 's/# TODO.*/# reviewed: the probe writes this on every pass; harmless/' "$T/led.txt"
out=$(SWEEP_GATE_LEDGER="$T/led.txt" bash tools/sweep-gate.sh "$T/has.log" 2>&1); rc=$?
printf '[ERROR] a different thing broke\n' > "$T/other.log"
out2=$(SWEEP_GATE_LEDGER="$T/led.txt" bash tools/sweep-gate.sh "$T/other.log" 2>&1); rc2=$?
if [ $rc -eq 0 ] && [ $rc2 -ne 0 ]; then ok "T6 a ledger entry accounts for ONE message, not a class"
else no "T6 ledger entry behaved as a class silencer (rc=$rc rc2=$rc2)" "$out2"; fi

# T7 - DRIFT. The corpus must still be what the emitters emit: reword a harness message without
# re-running the regenerator and the gate would be measured against text nothing prints any more.
cp mgmt/harness/error-corpus.txt "$T/corpus-before.txt"
bash tools/regen-error-corpus.sh --write >/dev/null 2>"$T/regen.err"; rgrc=$?
if [ "${rgrc:-1}" -ne 0 ]; then
  no "T7 the regenerator could not rebuild every site" "$(head -2 "$T/regen.err")"
elif diff -q "$T/corpus-before.txt" mgmt/harness/error-corpus.txt >/dev/null; then
  ok "T7 corpus matches what the emitters actually emit"
else
  no "T7 corpus has drifted - tools/regen-error-corpus.sh --write updated it" "$(diff "$T/corpus-before.txt" mgmt/harness/error-corpus.txt | head -4)"
fi

# T8 - A SEEDED TODO IS NOT A REASON. --write-ledger stamps every row it creates with a TODO note.
# If that counted as an account, seeding a ledger from a run would silence every error in that run -
# the silencing this redesign removed, coming back through the seeder.
printf '[ERROR] seeded thing\n' > "$T/td.log"
printf '1 [ERROR] seeded thing   # TODO: why is this not a defect?\n' > "$T/td-todo.txt"
printf '1 [ERROR] seeded thing   # the ISO is already detached by the previous cell; harmless\n' > "$T/td-real.txt"
o1=$(SWEEP_GATE_LEDGER="$T/td-todo.txt" bash tools/sweep-gate.sh "$T/td.log" 2>&1); r1=$?
o2=$(SWEEP_GATE_LEDGER="$T/td-real.txt" bash tools/sweep-gate.sh "$T/td.log" 2>&1); r2=$?
if [ $r1 -ne 0 ] && [ $r2 -eq 0 ]; then ok "T8 a TODO does not account for an error; a written reason does"
else no "T8 ledger note handling wrong (todo rc=$r1 expect non-zero, real rc=$r2 expect 0)" "$o1"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
