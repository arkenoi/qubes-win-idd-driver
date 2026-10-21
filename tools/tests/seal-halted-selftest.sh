#!/bin/bash
# A GOLDEN IS NEVER SEALED WHILE IT IS RUNNING.
#
# MEASURED 2026-10-21 by the descending audit: mgmt/harness/seal-qwt-golden.sh was the only consumer
# of qwt_shutdown that trusted its exit code without an independent Halted re-check. matrix.sh never
# does that - it re-reads the state at four separate sites. Sealing a RUNNING guest is the worst
# version of the defect: whatever that guest was doing gets frozen into the golden and inherited by
# every clone taken from it, which is exactly what the comment three lines above the call says about
# a killed guest.
#
# The block is extracted from the shipped script between its two markers and driven with a stubbed
# state reader, because the real path needs a rig.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

blk=$(awk '/# SEAL-HALTED-A/,/# SEAL-HALTED-B/' mgmt/harness/seal-qwt-golden.sh)
if [ -n "$blk" ] && printf '%s' "$blk" | command grep -qa 'AFTER a shutdown that returned success'; then
  ok "the halted re-check was extracted from seal-qwt-golden.sh"
else
  echo "FATAL: could not extract the halted re-check"; exit 2
fi

drive(){ # $1=state before  $2=shutdown rc  $3=state after -> "rc=<n> <output>"
  local out rc
  # THE VALUES ARE BOUND TO NAMES FIRST. The first version read "$2"/"$3" INSIDE the stub
  # functions, where those are the FUNCTION's arguments - qvm-ls is called with
  # `--raw-data --fields NAME,STATE`, so the state reader returned the literal "NAME,STATE" and
  # three legs failed against working code.
  out=$(bash -c '
    GOLD=win11-qwt
    _before="$1"; _sdrc="$2"; _after="$3"; _blk="$4"
    st="$_before"
    qwt_shutdown(){ return "$_sdrc"; }
    qvm-ls(){ printf "%s|%s\n" "$GOLD" "$_after"; }
    eval "$_blk"
    echo SEALED-WOULD-PROCEED
  ' _ "$1" "$2" "$3" "$blk" 2>&1); rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

got=$(drive Running 0 Halted)
case "$got" in
  rc=0*SEALED-WOULD-PROCEED*) ok "a guest that really halted proceeds to the seal" ;;
  *) no "a properly halted guest was refused" "$got" ;;
esac

got=$(drive Running 0 Running)
case "$got" in
  rc=1*"reports state 'Running' AFTER a shutdown that returned success"*)
    ok "a guest STILL RUNNING after a successful shutdown is REFUSED - the audit's case" ;;
  *) no "a running guest would have been sealed" "$got" ;;
esac

got=$(drive Running 0 '')
case "$got" in
  rc=1*unreadable*) ok "an unreadable state is refused, not assumed halted" ;;
  *) no "an unreadable state was accepted" "$got" ;;
esac

got=$(drive Running 1 Running)
case "$got" in
  rc=1*"did not shut down cleanly"*) ok "a failed shutdown is still refused by the original check" ;;
  *) no "a failed shutdown was not refused" "$got" ;;
esac

got=$(drive Halted 9 Halted)
case "$got" in
  rc=0*SEALED-WOULD-PROCEED*) ok "an already-Halted guest skips the shutdown and still passes the re-check" ;;
  *) no "an already-halted guest was refused" "$got" ;;
esac

# SEEN TO FAIL: without the re-check, a guest still Running after rc=0 would be sealed
nofix=$(printf '%s' "$blk" | sed '/AND THE STATE IS RE-READ/,/^fi$/d')
got=$(bash -c '
  GOLD=win11-qwt; st="Running"
  qwt_shutdown(){ return 0; }
  qvm-ls(){ printf "%s|Running\n" "$GOLD"; }
  eval "$1"
  echo SEALED-WOULD-PROCEED
' _ "$nofix" 2>&1)
case "$got" in
  *SEALED-WOULD-PROCEED*) ok "SEEN TO FAIL: without the re-check a RUNNING golden would be sealed" ;;
  *) no "the pre-fix shape did not reproduce" "$got" ;;
esac

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
