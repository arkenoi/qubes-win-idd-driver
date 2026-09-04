#!/bin/bash
# Fail-proof for w_appvm_shell (e2e-wait.sh) - ENTIRELY RIG-FREE. No qvm-*, no qtest, no guest:
# the guest probes and the screenshot classifier are stubbed; the wait logic under test is the
# REAL one sourced from mgmt/harness/e2e-wait.sh. Runnable any time, including while an
# acceptance run holds the rig.
#
# What it proves (H5 doctrine - a check counts only once it has been seen to FAIL on the defect):
#   1. DEFECT fixture - console session Active, explorer.exe never appears (the stale-private
#      AppVM signature): rc=1 and the output NAMES the diagnosis ("stale private volume ...
#      re-create"). A silent timeout here is exactly the failure mode this guard exists to kill.
#   2. HEALTHY fixture - explorer present: rc=0, no diagnosis.
#   3. NO-SESSION fixture - neither signal, ever: rc=2 at the deadline (bounded; the wait can
#      never spin forever, and a not-yet-logged-on guest is NOT misdiagnosed as stale-private).
#   4. SLOW-LOGON fixture - no session for the first polls, then session, then explorer: rc=0
#      (the settle clock starts only when a session is seen; a slow autologon is not a defect).
#   5. The echo-strip filter alone: the literal prompt-echo line sg6-failproof measured a false
#      explorer=1 from must NOT match; a real tasklist line MUST.
#
# Exit 0 = all five green. 1 = the guard cannot be trusted; fix before relying on it.
set -uo pipefail
cd "$(dirname "$0")/../.."
source mgmt/harness/e2e-wait.sh

fail=0
say(){ echo "$*"; }
pass(){ echo "ok: $*"; }
flunk(){ echo "FAILPROOF FAIL: $*"; fail=1; }

# ---- stubs: no rig calls can escape this script ----
w_screen(){ echo STUBBED; }
STATE=$(mktemp); trap 'rm -f "$STATE"' EXIT
echo 0 > "$STATE"
_tick(){ local n; n=$(<"$STATE"); echo $((n+1)) > "$STATE"; echo "$n"; }

echo "== 1. DEFECT: session Active, explorer never (stale private) => rc=1 + named diagnosis =="
_shell_probe_explorer(){ return 1; }
_shell_probe_session(){ return 0; }
out=$(SHELL_SETTLE_SECS=1 w_appvm_shell stub-vm 120 fp1 /tmp say); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'stale private volume' <<<"$out" && grep -q 're-created after its template was re-based' <<<"$out"; then
  pass "defect fixture FAILED FAST with the diagnosis (rc=1)"
else
  flunk "defect fixture: rc=$rc (want 1), output: $out"
fi

echo "== 2. HEALTHY: explorer present => rc=0 =="
_shell_probe_explorer(){ return 0; }
_shell_probe_session(){ return 0; }
out=$(w_appvm_shell stub-vm 120 fp2 /tmp say); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'stale private' <<<"$out"; then
  pass "healthy fixture proceeds (rc=0)"
else
  flunk "healthy fixture: rc=$rc (want 0), output: $out"
fi

echo "== 3. NO SESSION ever => rc=2 at the deadline (bounded, not misdiagnosed) =="
_shell_probe_explorer(){ return 1; }
_shell_probe_session(){ return 1; }
out=$(SHELL_SETTLE_SECS=1 w_appvm_shell stub-vm 20 fp3 /tmp say); rc=$?
if [ "$rc" -eq 2 ] && ! grep -q 'stale private' <<<"$out"; then
  pass "session-less fixture hits DEADLINE (rc=2), no false stale-private verdict"
else
  flunk "session-less fixture: rc=$rc (want 2), output: $out"
fi

echo "== 4. SLOW LOGON: session on poll 2, explorer on poll 3 => rc=0 =="
echo 0 > "$STATE"
_shell_probe_session(){ [ "$(_tick)" -ge 1 ]; }         # ticks 0.. : absent on the 1st look only
_shell_probe_explorer(){ [ "$(<"$STATE")" -ge 3 ]; }    # appears once the session has settled a poll
out=$(SHELL_SETTLE_SECS=300 w_appvm_shell stub-vm 300 fp4 /tmp say); rc=$?
if [ "$rc" -eq 0 ]; then
  pass "slow-logon fixture proceeds (rc=0) - late autologon is not a defect"
else
  flunk "slow-logon fixture: rc=$rc (want 0), output: $out"
fi

echo "== 5. echo-strip: the measured false-positive prompt line must not count =="
# The literal shape sg6-failproof measured explorer=1 from - the ECHO of the probe command.
echoline='C:\Windows\system32>cmd /c tasklist /fi "imagename eq explorer.exe" /nh'
realline='explorer.exe                  4242 Console                    1     98,765 K'
if printf '%s\n' "Microsoft Windows [Version 10.0.19045]" "$echoline" | _shell_echo_strip | grep -qa 'explorer\.exe'; then
  flunk "echo-strip let the command echo count as a running explorer (the sg6 false positive)"
else
  pass "command echo stripped - no self-match"
fi
if printf '%s\n' "$echoline" "$realline" | _shell_echo_strip | grep -qa 'explorer\.exe'; then
  pass "a real tasklist line still matches"
else
  flunk "echo-strip ate the REAL tasklist line - the probe would never see a healthy shell"
fi

[ "$fail" -eq 0 ] && echo "FAILPROOF: ALL GREEN (w_appvm_shell seen to fail on the defect and only on it)"
exit $fail
