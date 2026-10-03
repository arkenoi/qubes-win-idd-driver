#!/usr/bin/env bash
# wu-secplatform-selftest.sh - the KB5007651 platform verdict (qubes-windows-update.ps1 WU-SECPLATFORM-READ + WU-SECURITY-PLATFORM, judged
# through the shipped WU-AGENT-VERDICT): the clean leg must pass; -Defect noeffect (the platform's move ignored) must fail exactly the two
# moved cases; -Defect nocurrent (a platform at or past the offer not recognised) exactly the two current cases; -Defect unreadablefails (an
# unreadable platform judged anyway) exactly the two unreadable cases; -Defect appcertifies (the APP decides, as before 2026-10-03) exactly
# the two concealment cases. Exit 0 only if all five hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-secplatform-test.ps1"
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
expect noeffect        "moved,moved-noversion,"
expect nocurrent       "ahead,already-current,"
expect unreadablefails "unreadable,unreadable-before,"
expect appcertifies    "concealment-app-current,concealment-app-moved,"
[ "$bad" = 0 ] && { echo "PASS  clean passes; every knob fails exactly its cases"; exit 0; }
exit 1
