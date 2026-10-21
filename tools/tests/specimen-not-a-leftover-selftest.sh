#!/bin/bash
# THE MOST DESTRUCTIVE PATH IN THE HARNESS MUST ASK WHETHER THE GUEST IS EVIDENCE.
#
# prime-run.sh's pre-clean kills the churn subject and then qvm-removes it. It consulted nothing
# before doing so. On 2026-10-20 a reliably captured wedge specimen was lost because a campaign
# recreated the guest two minutes after it had been classified - this is the shape of that loss, and
# the marker that exists to prevent it (specimen-lib, read by tools/hooks/golden-boot-gate.sh) was
# never read here.
#
# mgmt/harness/evidence-lock.sh looks purpose-built for this. MEASURED 2026-10-21: all five of its
# functions have ZERO consumers and no file sources it - it is dead code. This suite asserts the
# guard uses the LIVE mechanism, and reports the dead one rather than quietly wiring it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The guard block, taken OUT of the shipped file so this cannot drift from it.
guard=$(sed -n '/^# A SPECIMEN IS NOT A LEFTOVER\./,/^fi$/p' "$ROOT/mgmt/harness/prime-run.sh")
[ -n "$guard" ] || { echo "FATAL: could not find the guard block in prime-run.sh"; exit 2; }

run_guard(){ # $1=marked|unmarked -> "rc|output"
  local d="$T/g.$RANDOM"; mkdir -p "$d"
  local out rc
  out=$( cd "$ROOT" && SPECIMEN_DIR="$d/spec" bash -c '
      set -uo pipefail
      source mgmt/harness/specimen-lib.sh
      log(){ echo "$*"; }
      CHURN=somechurn
      [ "'"$1"'" = marked ] && specimen_mark "$CHURN" "a wedge was classified here" "'"$d"'" >/dev/null
      '"$guard"'
      echo "REACHED THE DESTRUCTIVE STEP"
  ' 2>&1 ); rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

r=$(run_guard marked); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && [[ "$out" != *"REACHED THE DESTRUCTIVE STEP"* ]]; then
  ok "a MARKED specimen stops the pre-clean (rc=$rc) before anything is killed or removed"
else
  no "a marked specimen reached the destructive step (rc=$rc): ${out:0:110}"
fi
[[ "$out" == *"specimen_clear"* ]] && ok "the refusal names the deliberate way out (specimen_clear)" \
                                   || no "the refusal does not say how to release the specimen"
[[ "$out" == *"a wedge was classified here"* ]] && ok "it prints the recorded reason, so the reader knows what is held" \
                                                || no "the recorded reason is not shown"

r=$(run_guard unmarked); rc=${r%%|*}; out=${r#*|}
if [ "$rc" = 0 ] && [[ "$out" == *"REACHED THE DESTRUCTIVE STEP"* ]]; then
  ok "an UNMARKED leftover proceeds as before (positive control - the guard is not blocking everything)"
else
  no "an unmarked leftover was also stopped (rc=$rc): ${out:0:110}"
fi

# NEGATIVE CONTROL: without the guard, a marked specimen reaches the destructive step.
out=$( cd "$ROOT" && SPECIMEN_DIR="$T/nc" bash -c '
    set -uo pipefail
    source mgmt/harness/specimen-lib.sh
    log(){ echo "$*"; }
    CHURN=somechurn
    specimen_mark "$CHURN" "a wedge was classified here" "'"$T"'" >/dev/null
    echo "REACHED THE DESTRUCTIVE STEP"
' 2>&1 )
[[ "$out" == *"REACHED THE DESTRUCTIVE STEP"* ]] \
  && ok "negative control: with no guard a marked specimen IS reached and would be destroyed" \
  || no "negative control did not reproduce"

# THE DEAD LIBRARY, REPORTED NOT WIRED. If someone gives evidence-lock.sh consumers this flips, and
# then there are two mechanisms and this suite says so - which is the point.
cons=0
# COMMENTS DO NOT COUNT. prime-run.sh's own guard comment NAMES all five functions to explain why
# it does not use them, and a line-blind grep read that as five consumers - a check firing on the
# prose that documents it, which is the exact mistake this repo keeps making.
for f in ev_lock ev_locked ev_release ev_reap ev_lock_survivors; do
  n=$(cd "$ROOT" && command grep -rn "\b$f\b" --include='*.sh' mgmt tools 2>/dev/null \
      | command grep -v 'evidence-lock.sh' | command grep -v '/tests/' \
      | command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | wc -l)
  cons=$(( cons + n ))
done
if [ "$cons" = 0 ]; then
  echo "note mgmt/harness/evidence-lock.sh still has ZERO consumers - dead code, the owner's call"
  ok "the guard does not depend on the unused evidence-lock library"
else
  no "evidence-lock.sh now has $cons consumer(s) - two mechanisms guard the same property, pick one"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
