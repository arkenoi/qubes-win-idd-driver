#!/usr/bin/env bash
# wu-catch-scope-selftest.sh - offline proof that qubes-windows-update.ps1's main catch runs the 0x8024402C remedy at SCRIPT scope
# (tools/tests/wu-catch-scope-test.ps1): the clean leg must pass and WUCATCH_DEFECT=1 (the `$st =` that silenced the remedy from
# e6037f5d, 2026-09-21, to 2026-10-02) must make it FAIL. Exit 0 only if both hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
S="$ROOT/guest/qubes-windows-update.ps1"
T="$ROOT/tools/tests/wu-catch-scope-test.ps1"
echo "== clean"
out=$("$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); rc=$?
printf '%s\n' "$out"
echo "== WUCATCH_DEFECT=1 (the colliding \$st - must FAIL)"
dout=$(WUCATCH_DEFECT=1 "$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); drc=$?
printf '%s\n' "$dout" | grep -E 'FAIL|PASS|INSTRUMENT'
if [ "$rc" = 0 ] && [ "$drc" = 1 ] && printf '%s\n' "$dout" | grep -q 'FAIL the status object is still a dictionary'; then
  echo "PASS  clean leg passes, the colliding \$st is caught"; exit 0
fi
echo "FAIL  clean rc=$rc defect rc=$drc"; exit 1
