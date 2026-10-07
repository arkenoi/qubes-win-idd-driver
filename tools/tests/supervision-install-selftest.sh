#!/usr/bin/env bash
# supervision-install-selftest.sh - offline proof matrix for the installer side of docs/ADR-supervision.md: the recovery
# arming over the three MSI services (Set-QubesServiceRecovery), our Event Log source (Register-QwtEventSource), the ONE
# event-triggered reporter task (Register-QwtDeathReporter) and pvnic-selfprime.ps1's arming of QwtngNetSetup where it
# is created. Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/supervision-install-test.ps1, which extracts the marked regions of the shipped files and drives them
# against a fake sc/reg/wevtutil/schtasks that records every call.
#
#   no env                  full matrix: the clean leg must PASS, and every defect knob must make the suite FAIL on the
#                           check it targets (a guard never seen to fail is decoration). Exit 0 only if every leg came out
#                           as required.
#   SUPERV_DEFECT=<knob>    run ONLY that knob and exit with the suite's own code - i.e. the knob makes this test FAIL,
#                           by design. Knobs: recovthree evsrc tasklog selftrigger argsinject netsetuprecov.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${SUPERV_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/superv-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/supervision-install-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

KNOBS="recovsuspend recovquote recovreadback rearmreadback recovthree evsrc tasklog selftrigger argsinject netsetuprecov"
if [ -n "${SUPERV_DEFECT:-}" ]; then
    case " $KNOBS " in *" $SUPERV_DEFECT "*) ;; *) say "FAIL  unknown SUPERV_DEFECT='$SUPERV_DEFECT' ($KNOBS)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$SUPERV_DEFECT"; rc=$?
    say "--- defect knob $SUPERV_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 45 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-200))"; bad=1; fi

leg(){ # $1 knob, $2 target check (literal prefix)
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" >"$OUT/defect-$1.out" 2>&1; local r=$? ff
    ff=$(grep -c '^FAIL' "$OUT/defect-$1.out")
    if [ $r -ne 0 ] && grep -qF "FAIL $2" "$OUT/defect-$1.out"; then
        say "PASS  defect $1: suite FAILED as required on its target (rc=$r, $ff failing checks)"
    else
        say "FAIL  defect $1: rc=$r target-failed=$(grep -cF "FAIL $2" "$OUT/defect-$1.out") first=[$(grep -m1 '^FAIL' "$OUT/defect-$1.out" | cut -c1-160)]"; bad=1
    fi
}
leg recovsuspend  'suspend: a SECOND call for the same service does not throw'
leg recovquote    'suspend: the disarm sends a NON-EMPTY actions token'
leg recovreadback 'suspend: a write that sc ACCEPTS but does not apply is caught by the readback'
leg rearmreadback 'resume: a re-arm that does not take is an ERROR-class flag'
leg recovthree    'recovery: QubesGuiWatchdog = armed'
leg evsrc         'event source: EventMessageFile is REG_EXPAND_SZ to the message file, under the Application log, forced'
leg tasklog       'reporter: TaskScheduler/Operational is enabled first'
leg selftrigger   'subscription: the reporter never subscribes to its own task'
leg argsinject    'task: the arguments carry $(Channel) and $(RecordId) and no other event field'
leg netsetuprecov 'netsetup: sc failureflag QwtngNetSetup 1'
say "--- outputs in $OUT"
exit $bad
