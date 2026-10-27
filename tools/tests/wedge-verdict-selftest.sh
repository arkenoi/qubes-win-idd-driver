#!/bin/bash
# EVERY VERDICT THE CLASSIFIER CAN EMIT MUST BE HANDLED WHERE IT IS CONSUMED.
# run: tools/tests/wedge-verdict-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
pass=0; fail=0
ok(){  pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }

EMITTER=mgmt/harness/wedge-lib.sh
CONSUMER=mgmt/harness/e2e-wait.sh

# the tokens the emitter can print, taken from its own print statements
TOKENS=$(command grep -aoE '"(SPIN|BLOCKED|UNREADABLE)[^"]*"' "$EMITTER" \
         | sed -E 's/"([A-Z]+).*/\1/' | sort -u)
n=$(printf '%s\n' "$TOKENS" | command grep -ac .)
if [ "$n" -lt 2 ]; then
  bad "extraction: found $n token(s) in $EMITTER" "the extraction broke, not the consumer"
else
  ok "extraction: $n verdict token(s) from $EMITTER: $(printf '%s' "$TOKENS" | tr '\n' ' ')"
fi

# the arms of the consumer's case on ${_wv%% *}
ARMS=$(sed -n '/case "${_wv%% \*}" in/,/esac/p' "$CONSUMER" \
       | command grep -aoE '^\s*[A-Z|"]+\)' | tr -d ' )"' | tr '|' '\n' | sort -u)
for tok in $TOKENS; do
  if printf '%s\n' "$ARMS" | command grep -qx "$tok"; then
    ok "verdict '$tok' is handled by $CONSUMER"
  else
    bad "verdict '$tok' has NO arm in $CONSUMER" "it falls to the catch-all, so any protection in the named arms never runs"
  fi
done

# the SPIN arm must TAKE the core, not ask a human to
if sed -n '/SPIN|SPINNING)/,/;;/p' "$CONSUMER" | command grep -q 'fetch-wedge-core.sh'; then
  ok "the SPIN arm takes the memory image itself"
else
  bad "the SPIN arm does not call fetch-wedge-core.sh" "a printed DO-NOT is an instruction, and the campaign does not read logs"
fi

echo
echo "wedge-verdict-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
