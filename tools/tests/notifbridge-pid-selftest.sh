#!/usr/bin/env bash
# DO NOT CALL A CRASH YOU DID NOT OBSERVE: only a bridge pid THIS agent saw ready can have crashed.
# run: tools/tests/notifbridge-pid-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
SRC=agent/gui-agent/main.c
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }
[ -f "$SRC" ] || { echo "FAIL $SRC is missing - nothing ran (missing data fails)"; exit 2; }

B=$(awk '/HANDLE probe = OpenProcess\(SYNCHRONIZE, FALSE, hbPid\);/,/^                \}/' "$SRC")
[ -n "$B" ] || { bad "the gone-pid branch could not be located"; echo "  ---- $pass passed, $fail failed"; exit 1; }

command grep -q "g_NotifBridgePid == hbPid" <<< "$B" \
  && ok "a crash is claimed only for a pid THIS agent saw ready" \
  || bad "the gone-pid branch does not check whether this agent ever saw the pid ready"
command grep -q "was never ready here" <<< "$B" \
  && ok "a predecessor's heartbeat is named as what it is" \
  || bad "a pid never ready here has no distinct report"
# the unobserved case must NOT be a warning - that is the phantom that failed the cell
gone=$(awk '/is gone and was never ready here/,/hbPid\);/' "$SRC")
command grep -q "LogInfo" <<< "$gone" \
  && ok "and it reports at INFO, not WARNING" \
  || bad "the unobserved case still reports at WARNING - the phantom survives"
# a pid this agent DID see ready must still warn
command grep -q 'LogWarning("NOTIFBRIDGE pid %lu was ready here and is now gone' "$SRC" \
  && ok "a bridge that WAS ready here and then went is still a warning" \
  || bad "a genuinely observed early exit no longer warns"
# and the forged-pid arm must survive untouched
command grep -q "looks like a forged pid" "$SRC" \
  && ok "the forged-pid arm is untouched" \
  || bad "the forged-pid arm is gone"

# SEEN TO FAIL: without the ready check, any gone pid is called a crash again.
D=$(mktemp -d "${TMPDIR:-/tmp}/nbpid-XXXXXX"); trap 'rm -rf "$D"' EXIT
sed -E 's/if \(g_NotifBridgePid == hbPid\)/if (1)/' "$SRC" > "$D/regressed.c"
RB=$(awk '/HANDLE probe = OpenProcess\(SYNCHRONIZE, FALSE, hbPid\);/,/^                \}/' "$D/regressed.c")
command grep -q "g_NotifBridgePid == hbPid" <<< "$RB" \
  && bad "the regression copy still carries the check - the case cannot be driven" \
  || ok "SEEN TO FAIL: without it, a predecessor's gone pid is reported as our bridge crashing"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
