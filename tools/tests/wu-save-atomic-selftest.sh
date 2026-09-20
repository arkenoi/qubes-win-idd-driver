#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
S="$ROOT/tools/tests/wu-save-atomic-test.ps1"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found"; exit 2; }
out=$("$PWSH" -NoProfile -File "$S" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
bad=0
[ "$rc" = 0 ] && echo "OK    clean leg passed" || { echo "FAIL  clean leg did not pass (rc=$rc)"; bad=1; }
out=$("$PWSH" -NoProfile -File "$S" -Defect plainwrite 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "FAIL  defect 'plainwrite' did NOT break the suite - the atomic write is decoration"; bad=1
else echo "OK    defect 'plainwrite' -> suite FAILS (a locked file kills the pass again)"; fi
[ "$bad" = 0 ] && { echo "SAVE MATRIX OK"; exit 0; }
echo "SAVE MATRIX FAILED"; exit 1
