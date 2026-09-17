#!/usr/bin/env bash
# wu-dead-pass-selftest.sh - offline proof matrix for the dead-pass detection in guest/wu-update.ps1
# (a pass ended by the Task Scheduler 90 s in cost dom0 the handler's full 2 h bound, measured
# 2026-09-17 on win11de-gwt - findings/issues.md P1 "A KILLED UPDATE PASS COSTS dom0 TWO SILENT HOURS").
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-dead-pass-test.ps1, which extracts the marked WU-POLL region of the shipped handler
# and drives it in a child pwsh per scenario under a scripted scheduler and status writer.
#
#   no env                 full matrix: the clean leg must PASS, and the defect knob must make the suite
#                          FAIL on the check it targets (a guard never seen to fail is decoration).
#                          Exit 0 only if every leg came out as required.
#   WUDEADPASS_DEFECT=1    run ONLY that knob (the loop never looks at the task, as before 2026-09-17)
#                          and exit with the suite's own code - i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${WUDEADPASS_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wudeadpass-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-dead-pass-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check the knob must break, and the check-name prefixes its failures are allowed to carry: with
# the verdict disabled every killed-pass scenario polls to the sentinel, and nothing else may move.
TARGET='killed: Running+scan then Ready+0x41306 with the status unchanged -> DIED with 0x41306 and exit 1'
ALLOWED='^FAIL (killed|nostatus|foreign|contract)'   # contract asserts the DIED line's shape, so it fails with it

if [ -n "${WUDEADPASS_DEFECT:-}" ]; then
    [ "$WUDEADPASS_DEFECT" = "1" ] || { say "FAIL  unknown WUDEADPASS_DEFECT='$WUDEADPASS_DEFECT' (1)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect 1; rc=$?
    say "--- defect knob 1: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 16 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

"$PWSH" -NoProfile -File "$SUITE" -Defect 1 >"$OUT/defect-1.out" 2>&1; rc=$?
f=$(grep -c '^FAIL' "$OUT/defect-1.out")
stray=$(grep '^FAIL' "$OUT/defect-1.out" | grep -vE "$ALLOWED" | head -3 | cut -c6-120)
if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out" && [ -z "$stray" ]; then
    say "PASS  defect 1: suite FAILED as required on its target and only within the killed-pass cases (rc=$rc, $f failing checks)"
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out"; then
    say "FAIL  defect 1: target failed but so did checks outside its case: $stray"; bad=1
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
    say "FAIL  defect 1: suite failed (rc=$rc) but NOT on its target check '$TARGET' - the knob broke something else"; bad=1
else
    say "FAIL  defect 1: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
fi

say "--- outputs in $OUT"
exit $bad
