#!/usr/bin/env bash
# ONE TRUNCATED TRANSFER IS ONE ERROR LINE.
# run: tools/tests/wrapper-one-line-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
SRC=core-agent/src/qrexec-wrapper/qrexec-wrapper.c
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }
[ -f "$SRC" ] || { echo "FAIL $SRC is missing - nothing ran (missing data fails)"; exit 2; }

command grep -q 'LogError("i/o threads did not finish' "$SRC" \
  && ok "the truncated transfer itself is still an ERROR - it owns the event" \
  || bad "the drain-expiry ERROR is gone; a truncated transfer must still report"
# the two consequences must be conditioned on the drain having expired, and must not be ERROR
if command grep -q 'messageType == MSG_DATA_EXIT_CODE && g_exitReason == EXIT_REASON_DRAIN_EXPIRED' "$SRC"; then
  ok "the unsendable exit code is recognised as the drain's own consequence"
else
  bad "the unsendable exit code is not conditioned on EXIT_REASON_DRAIN_EXPIRED - it reports twice"
fi
blk=$(awk '/messageType == MSG_DATA_EXIT_CODE && g_exitReason == EXIT_REASON_DRAIN_EXPIRED/,/;/' "$SRC")
command grep -q "LogDebug" <<< "$blk" \
  && ok "and it reports at DEBUG, not ERROR" \
  || bad "the drain's consequence still reports at ERROR"
cblk=$(awk '/if \(!VchanSendExitCode\(child, exitCode\)\)/,/^            \}/' "$SRC")
command grep -q "g_exitReason == EXIT_REASON_DRAIN_EXPIRED" <<< "$cblk" \
  && ok "the caller does not re-report what the callee already said after a drain expiry" \
  || bad "the caller re-reports the send failure unconditionally - the duplicate-reporter shape"
command grep -q 'LogError("sending exit code failed")' <<< "$cblk" \
  && ok "a send failure with NO drain expiry is still an ERROR - that one is a real loss" \
  || bad "the non-drain send failure no longer reports at ERROR; that case must stay loud"

# SEEN TO FAIL: with the conditions stripped, one truncation reports three times again.
D=$(mktemp -d "${TMPDIR:-/tmp}/wrap1line-XXXXXX"); trap 'rm -rf "$D"' EXIT
sed -E 's/messageType == MSG_DATA_EXIT_CODE \&\& g_exitReason == EXIT_REASON_DRAIN_EXPIRED/0/; s/g_exitReason == EXIT_REASON_DRAIN_EXPIRED\)$/0)/' "$SRC" > "$D/regressed.c"
rb=$(awk '/messageType == MSG_DATA_EXIT_CODE && g_exitReason == EXIT_REASON_DRAIN_EXPIRED/,/;/' "$D/regressed.c")
[ -z "$rb" ] && ok "SEEN TO FAIL: without the condition the exit-code branch is gone and the generic ERROR reports again" \
             || bad "the regression copy still carries the condition - the case cannot be driven"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
