#!/usr/bin/env bash
# wu-effectsettle-selftest.sh - the effect wait (qubes-windows-update.ps1 WU-REGWATCH, WU-EFFECT-SETTLE): the clean leg must pass, and each
# -Defect knob must fail EXACTLY the cases its guard protects - a guard never seen to fail is decoration. Exit 0 only if every leg comes
# out as required.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-effectsettle-test.ps1"
out=$("$PWSH" -NoProfile -File "$T" 2>&1); rc=$?
printf '%s\n' "$out" | tail -1
fails_of() { printf '%s\n' "$1" | grep -oE '^  FAIL [a-z -]+:' | sed 's/^  FAIL //; s/:$//' | LC_ALL=C sort | tr '\n' ','; }
bad=0
expect() {   # knob, expected failing cases
  local kout krc kf
  kout=$("$PWSH" -NoProfile -File "$T" -Defect "$1" 2>&1); krc=$?; kf=$(fails_of "$kout")
  if [ "$krc" = 1 ] && [ "$kf" = "$2" ]; then echo "OK    $1 fails exactly {$kf}"; else echo "FAIL  $1 rc=$krc fails={$kf} (want $2)"; bad=1; fi
}
[ "$rc" = 0 ] || { echo "FAIL  clean rc=$rc"; printf '%s\n' "$out" | grep FAIL; bad=1; }
# nowait is the rz38b defect: every row that needed the wait is decided on the read right after the agent returned.
expect nowait        "lands,never,platbehind,sigbehind,"
expect widen         "agree,mrt,"
expect dropsig       "agree,sigbehind,"
expect passonexpiry  "never,"
expect silentunarmed "unarmed,"
# noarm: no watch object at all - nothing waits, and the ERROR line has no reason to name.
expect noarm         "lands,never,platbehind,sigbehind,unarmed,"
expect bound         "bound,"
[ "$bad" = 0 ] && { echo "PASS  clean passes; every knob fails exactly its cases"; exit 0; }
exit 1
