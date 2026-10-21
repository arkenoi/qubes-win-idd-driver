#!/bin/bash
# A CELL THAT FAILED TO DISABLE WINDOWS UPDATE MUST NOT BE GRADED AS A CLEAN ONE.
#
# MEASURED 2026-10-21 by the harness audit. tools/accept-clean.sh records the guest's update
# posture BEFORE a cell and fails closed when it cannot read it ("refusing to grade a cell whose
# update posture is unknown"). It then disables the updater in quick mode with
#     qq run "... Set-ItemProperty NoAutoUpdate 1 ... Stop-Service wuauserv ..." >/dev/null 2>&1 || true
# and never read the result. mgmt/harness/matrix.sh never sets ACCEPT_MODE, so EVERY cell of every
# campaign takes that branch: if the disable failed, the cell was still graded and reported as a
# clean "our package only" measurement with Windows Update live, and nothing in the record said so.
#
# The predicate is extracted from the shipped script between its two markers and driven over state
# files, because the disable itself needs a guest and this check does not.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
A=tools/accept-clean.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/acwu-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

pred=$(awk '/# ACCEPT-WU-ASSERT-A/,/# ACCEPT-WU-ASSERT-B/' "$A")
if [ -n "$pred" ] && printf '%s' "$pred" | command grep -qa '_wu_is_disabled' \
   && printf '%s' "$pred" | command grep -qa 'NAU:1'; then
  ok "the posture predicate was extracted from $A ($(printf '%s' "$pred" | wc -l) lines)"
else
  echo "FATAL: could not extract _wu_is_disabled from $A - the legs below would test nothing"; exit 2
fi

judge(){ # $1=file contents ("" means an empty file) -> prints ON or OFF
  printf '%s' "$1" > "$T/state.txt"
  bash -c '
    eval "$1"
    if _wu_is_disabled "$2"; then echo OFF; else echo ON; fi
  ' _ "$pred" "$T/state.txt"
}

# ---- the posture the disable is supposed to produce ---------------------------------------------
[ "$(judge 'NAU:1
SVC:Stopped')" = OFF ] && ok "NoAutoUpdate=1 with the service Stopped reads as OFF" \
  || no "the disabled posture did not read as OFF" "$(judge 'NAU:1
SVC:Stopped')"

[ "$(judge 'NAU:1
SVC:')" = OFF ] && ok "an absent service (removed/disabled, empty Status) reads as OFF" \
  || no "an absent service did not read as OFF"

# ---- every posture that means the cell is CONTAMINATED ------------------------------------------
[ "$(judge 'NAU:1
SVC:Running')" = ON ] && ok "policy set but the SERVICE STILL RUNNING reads as ON - contaminated" \
  || no "a running service was accepted as disabled" "this is the case that graded a live WU as clean"

[ "$(judge 'NAU:0
SVC:Stopped')" = ON ] && ok "NoAutoUpdate=0 reads as ON even with the service stopped" \
  || no "NoAutoUpdate=0 was accepted as disabled"

[ "$(judge 'NAU:
SVC:Stopped')" = ON ] && ok "an ABSENT policy value reads as ON, not as off-by-default" \
  || no "an absent NoAutoUpdate was treated as disabled"

[ "$(judge '')" = ON ] && ok "an EMPTY state file reads as ON - missing data fails, as the before-state does" \
  || no "an empty state file was treated as disabled" "the whole point of reading the posture"

[ "$(judge 'NAU:1')" = ON ] && ok "a TRUNCATED readback (no SVC line) reads as ON" \
  || no "a truncated readback was treated as disabled"

# ---- and the shipped script must actually USE it on the after-state -----------------------------
command grep -qa 'wu-state-after.txt' "$A" \
  && ok "the script reads the posture back AFTER the disable" \
  || no "nothing reads the posture back after the disable" "the disable is still '|| true' with no check"
if command grep -qaE 'fail "the updater did NOT turn off' "$A"; then
  ok "and a failed disable calls fail(), not log()"
else no "a failed disable does not call fail()" "a warn would leave the cell graded as clean"; fi

# ---- SEEN TO FAIL: with the predicate inverted, a live updater reads as OFF ----------------------
inv=$(printf '%s' "$pred" | sed "s/command grep -qaE '\^SVC:(Stopped|StopPending|)\$' \"\$f\" || return 1//")
got=$(bash -c '
  eval "$1"
  printf "NAU:1\nSVC:Running\n" > "$2"
  if _wu_is_disabled "$2"; then echo OFF; else echo ON; fi
' _ "$inv" "$T/inv.txt")
[ "$got" = OFF ] && ok "SEEN TO FAIL: without the service check a RUNNING updater reads as OFF again" \
                 || no "the regressed predicate still rejected a running updater" "the check cannot be driven ($got)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
