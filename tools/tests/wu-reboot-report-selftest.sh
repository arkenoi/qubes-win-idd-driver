#!/usr/bin/env bash
# wu-reboot-report-selftest.sh - offline proof matrix for the reboot-pending availability report and
# the scheduled-scan debounce in guest/qubes-windows-update.ps1 (GWeck's Patch Tuesday failure:
# dom0 told 0 updates after a reboot-pending pass, and the correcting boot scan debounced away).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-reboot-report-test.ps1, which extracts the marked regions of the shipped script and
# replays the German guest's captured update-status.json files against them.
#
#   no env               full matrix: the clean leg must PASS, and each defect knob must make the suite
#                        FAIL on the check it targets (a guard never seen to fail is decoration).
#                        Exit 0 only if every leg came out as required.
#   WUREPORT_DEFECT=x    run ONLY that knob (deadfilter | debounce) and exit with the suite's own code -
#                        i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${WUREPORT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wureport-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-reboot-report-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check each knob must break - the failure has to land on the replayed case, not just anywhere.
target_of() {
    case "$1" in
        deadfilter) printf '%s' "report: pass-1 replay - remaining is 1 (KB5129195 ok=false state=deferred); the guest wrote 0" ;;
        debounce)   printf '%s' "debounce: boot scan at 22:54:00 after the reboot-pending pass (done_ts 22:49:16) RUNS" ;;
        *)          return 1 ;;
    esac
}

if [ -n "${WUREPORT_DEFECT:-}" ]; then
    target_of "$WUREPORT_DEFECT" >/dev/null || { say "FAIL  unknown WUREPORT_DEFECT='$WUREPORT_DEFECT' (deadfilter | debounce)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WUREPORT_DEFECT"; rc=$?
    say "--- defect knob $WUREPORT_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 30 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

for d in deadfilter debounce; do
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
    want="$(target_of "$d")"
    if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out"; then
        say "PASS  defect $d: suite FAILED as required on its target (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c6-120))"
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
        say "FAIL  defect $d: suite failed (rc=$rc) but NOT on its target check '$want' - the knob broke something else"; bad=1
    else
        say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
    fi
done

say "--- outputs in $OUT"
exit $bad
