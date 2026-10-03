#!/usr/bin/env bash
# wu-defplatform-selftest.sh - the Defender platform effect probe (qubes-windows-update.ps1 WU-DEFENDER-PLATFORM, judged through the
# shipped WU-AGENT-VERDICT): the clean leg must pass; -Defect noeffect (the measured effect ignored, as before 2026-10-03) must fail exactly
# the two effect cases; -Defect behindinfo (a platform left below the offer laundered into 'informational') must fail exactly the behind
# and switch-never-happened cases; -Defect nopending (a platform staged earlier in THIS boot not recognised) must fail exactly the pending
# case. Exit 0 only if all four hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-defplatform-test.ps1"
out=$("$PWSH" -NoProfile -File "$T" 2>&1); rc=$?
dout=$("$PWSH" -NoProfile -File "$T" -Defect noeffect 2>&1); drc=$?
bout=$("$PWSH" -NoProfile -File "$T" -Defect behindinfo 2>&1); brc=$?
pout=$("$PWSH" -NoProfile -File "$T" -Defect nopending 2>&1); prc=$?
printf '%s\n' "$out" | tail -1
fails_of() { printf '%s\n' "$1" | grep -oE '^  FAIL [a-z -]+:' | sed 's/^  FAIL //; s/:$//' | sort | tr '\n' ','; }
df=$(fails_of "$dout"); bf=$(fails_of "$bout"); pf=$(fails_of "$pout")
if [ "$rc" = 0 ] && [ "$drc" = 1 ] && [ "$df" = "moved,staged," ] && [ "$brc" = 1 ] && [ "$bf" = "behind,switch-never-happened," ] \
   && [ "$prc" = 1 ] && [ "$pf" = "pending," ]; then
  echo "PASS  clean passes; noeffect fails exactly {$df}; behindinfo fails exactly {$bf}; nopending fails exactly {$pf}"; exit 0
fi
echo "FAIL  clean rc=$rc; noeffect rc=$drc fails={$df} (want moved,staged,); behindinfo rc=$brc fails={$bf} (want behind,switch-never-happened,); nopending rc=$prc fails={$pf} (want pending,)"
printf '%s\n' "$out" | grep FAIL; exit 1
