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
[ -x "$PWSH" ] || PWSH=/home/user/pwsh/pwsh
OUT="${WUDEADPASS_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wudeadpass-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-dead-pass-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check the knob must break, and the check-name prefixes its failures are allowed to carry: with
# the verdict disabled every killed-pass scenario polls to the sentinel, and nothing else may move.
TARGET='killed: Running+scan then Ready+0x41306 with the status unchanged -> DIED with 0x41306 and exit 1'
ALLOWED='^FAIL (killed|nostatus|foreign|contract|refused-held|refused-unknown|live-holder|died-error)'   # contract asserts the DIED
# line's shape, so it fails with it; the WU-HOLDER scenarios (refusals, the live-holder teardown guard, the last error) all act INSIDE
# the verdict, so with the verdict disabled they cannot fire either

if [ -n "${WUDEADPASS_DEFECT:-}" ]; then
    [ "$WUDEADPASS_DEFECT" = "1" ] || { say "FAIL  unknown WUDEADPASS_DEFECT='$WUDEADPASS_DEFECT' (1)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect 1; rc=$?
    say "--- defect knob 1: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 35 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
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

# Knobs 2 and 3 (WU-HOLDER, 2026-10-02): each must fail ITS target, and only within its own scenarios.
leg(){ # $1 knob, $2 target check, $3 allowed-failures regex
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" >"$OUT/defect-$1.out" 2>&1; local r=$? ff st
    ff=$(grep -c '^FAIL' "$OUT/defect-$1.out")
    st=$(grep '^FAIL' "$OUT/defect-$1.out" | grep -vE "$3" | head -3 | cut -c6-120)
    if [ $r -ne 0 ] && grep -qF "FAIL $2" "$OUT/defect-$1.out" && [ -z "$st" ]; then
        say "PASS  defect $1: suite FAILED as required on its target and only within its cases (rc=$r, $ff failing checks)"
    else
        say "FAIL  defect $1: rc=$r target-failed=$(grep -cF "FAIL $2" "$OUT/defect-$1.out") stray=[$st]"; bad=1
    fi
}
leg 2 'live-holder: our pass died while another pass holds the updater lock -> DIED, but the leftovers are NOT touched (no proxy reset, no relay kill)' '^FAIL live-holder'
leg 3 'refused-held: a mutex-held refusal is no death - no DIED, no teardown; the task is started again and the pass completes (exit 0, phase done)' '^FAIL (refused-held|refused-unknown|contract: the refusal)'
leg 4 'holder-wait: waits while the updater lock is held and returns when it is gone (ok, after 3 ticks), telling dom0 once what it waits for' '^FAIL holder-wait'

leg 5 "keep-cutoff: Start-RunTask keeps a non-terminal status (a cut-off pass's record the start gate reads) and still starts the task" '^FAIL keep-cutoff'

# Knobs 6 and 7 (2026-10-03, ADR-updater 12.4: the handler kills nothing): 6 restores the kill by name in the survivor branch, 7 drops
# the wait for the relay's own parent watchdog (then a relay that leaves on its own is judged a survivor, and the survivor's bound is gone).
leg 6 'killed-survivor: a relay still on 8082 after the bound is NOT killed' '^FAIL killed-survivor'
leg 7 'killed: the leftovers line reports the relay exited on its own' '^FAIL (killed: |killed-survivor: the wait ran|contract: the DIED and leftovers)'

say "--- outputs in $OUT"
exit $bad
