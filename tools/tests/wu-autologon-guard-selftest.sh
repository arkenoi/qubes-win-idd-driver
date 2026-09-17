#!/usr/bin/env bash
# wu-autologon-guard-selftest.sh - offline proof for Protect-Autologon in guest/qubes-windows-update.ps1
# (the updater read ensure-autologon.ps1 from a `vmupdate-shim\` directory the installer never creates,
# so autologon was never re-asserted before the reboots it causes - measured 2026-09-17 on win11de-gwt).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-autologon-guard-test.ps1, which extracts the marked function from the shipped script
# and drives it against a real temporary <Qubes Tools> layout with Log and powershell shadowed.
#
#   no env                 full matrix: the clean leg must PASS, and the defect knob must make the suite
#                          FAIL on the deployed-path case and nowhere else. Exit 0 only if both came out
#                          as required.
#   WUAUTOLOGON_DEFECT=1   run ONLY the knob (the pre-fix `vmupdate-shim\` path) and exit with the
#                          suite's own code - i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${WUAUTOLOGON_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wuautologon-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-autologon-guard-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

TARGET="deployed-path: reboot pending, helper deployed - the guard invokes it (powershell -File <deployed path>)"
ALLOWED='^FAIL deployed-path'

if [ -n "${WUAUTOLOGON_DEFECT:-}" ]; then
    [ "$WUAUTOLOGON_DEFECT" = "1" ] || { say "FAIL  unknown WUAUTOLOGON_DEFECT='$WUAUTOLOGON_DEFECT' (1)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect 1; rc=$?
    say "--- defect knob 1: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 12 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

"$PWSH" -NoProfile -File "$SUITE" -Defect 1 >"$OUT/defect-1.out" 2>&1; rc=$?
f=$(grep -c '^FAIL' "$OUT/defect-1.out")
stray=$(grep '^FAIL' "$OUT/defect-1.out" | grep -vE "$ALLOWED" | head -3 | cut -c6-120)
if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out" && [ -z "$stray" ]; then
    say "PASS  defect 1: suite FAILED as required on its target and only within the deployed-path case (rc=$rc, $f failing checks)"
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out"; then
    say "FAIL  defect 1: target failed but so did checks outside its case: $stray"; bad=1
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
    say "FAIL  defect 1: suite failed (rc=$rc) but NOT on its target check '$TARGET' - the knob broke something else"; bad=1
else
    say "FAIL  defect 1: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
fi

say "--- outputs in $OUT"
exit $bad
