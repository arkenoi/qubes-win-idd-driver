#!/bin/bash
# a scope question must not be asked in the small hours, and the clock is the thing refusing
# run: tools/tests/ask-operator-night-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 1
G=tools/hooks/ask-operator-gate.sh
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/asknight.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{}}' > "$T/hook.json"

ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# Returns: "clock" | "jev" | "allowed" - WHICH rule refused, not merely whether something did.
who(){ env "$@" bash "$G" <"$T/hook.json" >/dev/null 2>"$T/err"; local rc=$?
  if [ "$rc" -eq 0 ]; then echo allowed
  elif command grep -q 'night window' "$T/err"; then echo clock
  else echo jev; fi; }

echo "PART A  inside the window it refuses, and the clock is the thing refusing"
r=$(who ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=24)
[ "$r" = clock ] && ok "a question inside the night window is refused BY THE CLOCK" \
  || bad "inside the window the refusal came from '$r', not the clock"

echo "PART B  outside the window the clock says nothing"
# The gate's other rule may still refuse - that is correct and not this rule's business. What must
# not happen is the clock refusing outside its own hours.
r=$(who ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=0)
[ "$r" != clock ] && ok "outside the window the clock does not refuse (got '$r' - the Jev rule or allow)" \
  || bad "the clock refused outside its own window"
# The shipped window must be the owner's, not whatever a test left behind.
f=$(command grep -oE 'ASK_GATE_NIGHT_FROM:-[0-9]+' "$G" | command grep -oE '[0-9]+$')
t=$(command grep -oE 'ASK_GATE_NIGHT_TO:-[0-9]+' "$G" | command grep -oE '[0-9]+$')
[ "$f" = 1 ] && ok "the shipped window starts at 01:00" || bad "the shipped window starts at '$f', not 1"
[ "$t" = 6 ] && ok "the shipped window ends at 06:00"   || bad "the shipped window ends at '$t', not 6"

echo "PART C  the two refusals are TELLABLE APART"
# Without this the suite would pass on a gate whose clock rule had been deleted, because the Jev
# rule refuses everything anyway in a session with no recent operator call.
n=$(who ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=24)
d=$(who ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=0)
[ "$n" = clock ] && [ "$d" != clock ] \
  && ok "night and day give DIFFERENT refusals ($n vs $d), so the clock rule is really there" \
  || bad "night and day refuse identically ($n vs $d) - this suite cannot see the clock rule"
# SEEN TO FAIL: with the clock block stripped out, PART A must stop reporting 'clock'.
sed '/inside the .* night window/d' "$G" > "$T/gutted.sh"
env ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=24 bash "$T/gutted.sh" <"$T/hook.json" >/dev/null 2>"$T/err2"
command grep -q 'night window' "$T/err2" \
  && bad "the gutted gate still reports the night window - PART A proves nothing" \
  || ok "with the clock message stripped, the night refusal is gone (seen to fail)"

echo "PART D  the override exists and is narrow"
r=$(who ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=24 ASK_OPERATOR_NIGHT_OK=1)
[ "$r" != clock ] && ok "ASK_OPERATOR_NIGHT_OK=1 bypasses the clock (got '$r')" \
  || bad "the override does not bypass the clock"
env ASK_GATE_NIGHT_FROM=0 ASK_GATE_NIGHT_TO=24 bash "$G" <"$T/hook.json" >/dev/null 2>"$T/err"
command grep -q 'unsafe or destructive' "$T/err" \
  && ok "the message says the override is for unsafe/destructive only" \
  || bad "the override is not scoped in the message"
command grep -q 'never for "this one is big"' "$T/err" \
  && ok "and explicitly not for 'this decision is big'" || bad "the message does not rule out scope-size use"

echo "PART E  it tells the model what to do instead"
for frag in 'Pick the option that KEEPS WORKING' 'State the assumption' 'REASON TO START'; do
  command grep -q "$frag" "$T/err" && ok "says: $frag" || bad "the message omits: $frag"
done

echo "ask-operator-night-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
