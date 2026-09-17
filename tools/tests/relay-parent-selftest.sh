#!/usr/bin/env bash
# relay-parent-selftest.sh - offline proof matrix for the relay's parent watchdog
# (guest/qubes-updates-relay.cs, ParentWatch/StartParentWatchdog): the relay outlived a pass the
# Task Scheduler had killed and served the proxy for hours (measured 2026-09-17 on win11de-gwt,
# findings/issues.md P1 "A KILLED UPDATE PASS COSTS dom0 TWO SILENT HOURS").
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/relay-parent-test.ps1, which compiles the SHIPPED source file with Add-Type and arms
# the watchdog on a sleeper process it spawns and kills.
#
#   no env                  full matrix: the clean leg must PASS, and the defect knob must make the
#                           suite FAIL on the check it targets (a guard never seen to fail is
#                           decoration). Exit 0 only if every leg came out as required.
#   RELAYPARENT_DEFECT=1    run ONLY that knob (watchdog disabled) and exit with the suite's own
#                           code - i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${RELAYPARENT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/relay-parent-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/relay-parent-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check the knob must break, and where its failures may land: with the watchdog disabled the
# fire-after-kill check and the log line it writes fail; nothing else may move.
TARGET='watchdog: after the parent is killed it fires within 7 s'
ALLOWED='^FAIL watchdog: (after the parent is killed|the log names the gone parent)'

if [ -n "${RELAYPARENT_DEFECT:-}" ]; then
    [ "$RELAYPARENT_DEFECT" = "1" ] || { say "FAIL  unknown RELAYPARENT_DEFECT='$RELAYPARENT_DEFECT' (1)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect 1; rc=$?
    say "--- defect knob 1: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 12 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

"$PWSH" -NoProfile -File "$SUITE" -Defect 1 >"$OUT/defect-1.out" 2>&1; rc=$?
f=$(grep -c '^FAIL' "$OUT/defect-1.out")
stray=$(grep '^FAIL' "$OUT/defect-1.out" | grep -vE "$ALLOWED" | head -3 | cut -c6-120)
if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out" && [ -z "$stray" ]; then
    say "PASS  defect 1: suite FAILED as required on its target and only within its case (rc=$rc, $f failing checks)"
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $TARGET" "$OUT/defect-1.out"; then
    say "FAIL  defect 1: target failed but so did checks outside its case: $stray"; bad=1
elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
    say "FAIL  defect 1: suite failed (rc=$rc) but NOT on its target check '$TARGET' - the knob broke something else"; bad=1
else
    say "FAIL  defect 1: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
fi

say "--- outputs in $OUT"
exit $bad
