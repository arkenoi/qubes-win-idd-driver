#!/bin/bash
# Clean leg must pass; the zip64only knob must make it FAIL - a carve that has never been seen to
# miss is not evidence that it finds anything.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
S="$ROOT/tools/tests/wu-appx-carve-test.ps1"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH"; exit 2; }
out=$("$PWSH" -NoProfile -File "$S" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
bad=0
[ "$rc" = 0 ] && echo "OK    clean leg passed" || { echo "FAIL  clean leg did not pass (rc=$rc)"; bad=1; }
out=$("$PWSH" -NoProfile -File "$S" -Defect zip64only 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "FAIL  defect 'zip64only' did NOT break the suite - the classic-EOCD path is decoration"; bad=1
else echo "OK    defect 'zip64only' -> suite FAILS (the classic-EOCD path is load-bearing)"; fi
[ "$bad" = 0 ] && { echo "CARVE MATRIX OK"; exit 0; }
echo "CARVE MATRIX FAILED"; exit 1
