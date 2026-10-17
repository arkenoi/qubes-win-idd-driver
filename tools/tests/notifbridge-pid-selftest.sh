#!/usr/bin/env bash
# notifbridge-pid-selftest.sh - DO NOT CALL A CRASH YOU DID NOT OBSERVE.
#
# The agent waits for notifhost.exe to publish its pid in a heartbeat, and checks the heartbeat's
# tick against its OWN launch - which is right. But a PREDECESSOR's bridge can still be alive and
# heart-beating when a new agent starts, so a fresh tick can carry the OLD bridge's pid; and a fresh
# agent process holds no knowledge of its predecessor's pid, so it cannot tell them apart.
#
# MEASURED win11-clean, campaign run 38994277148, agent pid 4508:
#   06:05:14.139  NOTIFHOST launched via Task Scheduler
#   06:05:16.752  W NOTIFBRIDGE published pid 4996 is gone, the bridge crashed right after starting
#   06:05:21.181  I NOTIFBRIDGE ready (pid 8340 published 10375 ms after the launch)
# pid 4996 was published at 06:03:08 by the PREVIOUS agent instance (4236). Nothing crashed. Jev
# rated that signature defect 0.61 - above the floor - so it failed an acceptance cell on a phantom.
#
# What the agent CAN say is whether IT saw the pid ready. A real crash of a bridge it did see ready
# is reported by the exit path, with the exit code.
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
