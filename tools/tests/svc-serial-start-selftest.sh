#!/usr/bin/env bash
# svc-serial-start-selftest.sh - offline proof matrix for the serialized service start after msiexec (docs/ADR-boot.md 1):
# after msiexec QWT's services come up ONE AT A TIME - QdbDaemon started and observed RUNNING and READY, then QrexecAgent
# started and observed RUNNING, QubesGuiWatchdog held for the quiesce - before any further stage-2 step; a service that
# never starts is a loud, flagged failure; an MSI that would start the services itself is refused before it runs, and
# reported if it did anyway. Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/svc-serial-start-test.ps1, which extracts the marked regions of the shipped installer and drives them
# against a fake SCM, a fake clock, a fake qubesdb and a scripted Windows Installer database, recording every call.
#
#   no env                    full matrix: the clean leg must PASS, and every defect knob must make the suite FAIL on the
#                             check it targets, and only within its own area (a guard never seen to fail is decoration).
#                             Exit 0 only if every leg came out as required.
#   SVCSERIAL_DEFECT=<knob>   run ONLY that knob and exit with the suite's own code - i.e. the knob makes this test FAIL,
#                             by design. Knobs: msicontract noviolation startwatchdog nowaitrunning nowaitready silentfail
#                             serialfirst noserialstart msinostart.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${SVCSERIAL_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/svcserial-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/svc-serial-start-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

KNOBS="msicontract noviolation startwatchdog nowaitrunning nowaitready silentfail serialfirst noserialstart startonexit failstart msinostart"
if [ -n "${SVCSERIAL_DEFECT:-}" ]; then
    case " $KNOBS " in *" $SVCSERIAL_DEFECT "*) ;; *) say "FAIL  unknown SVCSERIAL_DEFECT='$SVCSERIAL_DEFECT' ($KNOBS)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$SVCSERIAL_DEFECT"; rc=$?
    say "--- defect knob $SVCSERIAL_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 34 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-200))"; bad=1; fi

# Each knob must fail ITS target check, and only within its own area(s).
leg(){ # $1 knob, $2 target check (literal prefix), $3 allowed-failures regex
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" >"$OUT/defect-$1.out" 2>&1; local r=$? ff st
    ff=$(grep -c '^FAIL' "$OUT/defect-$1.out")
    st=$(grep '^FAIL' "$OUT/defect-$1.out" | grep -vE "$3" | head -3 | cut -c6-160)
    if [ $r -ne 0 ] && grep -qF "FAIL $2" "$OUT/defect-$1.out" && [ -z "$st" ]; then
        say "PASS  defect $1: suite FAILED as required on its target and only within its area (rc=$r, $ff failing checks)"
    else
        say "FAIL  defect $1: rc=$r target-failed=$(grep -cF "FAIL $2" "$OUT/defect-$1.out") stray=[$st]"; bad=1
    fi
}
leg msicontract   'contract: an MSI whose StartServices is not conditioned is REFUSED'                                 '^FAIL contract:'
leg noviolation   'violation: services found running right after msiexec are recorded in svc_msi_started'              '^FAIL violation:'
# the knob starts the watchdog in EVERY case, so the one failure-area check that records the whole call sequence changes too
leg startwatchdog 'clean: QubesGuiWatchdog is never started by the serialized start'                                   '^FAIL (clean|violation|retry|shipped|exit):|^FAIL failure: the stage continues'
# without the SCM wait the service stays START_PENDING in the world: the clean order, the pacing and the failure narratives all change
leg nowaitrunning 'pacing: QdbDaemon RUNNING is observed through the SCM before its first readiness probe'            '^FAIL (clean|pacing|order|failure|retry|exit):'
leg nowaitready   'pacing: QrexecAgent is started only after QdbDaemon is observed RUNNING and READY'                 '^FAIL (clean|pacing|failure|violation|retry):'
leg silentfail    'failure: a service that never reaches RUNNING sets svc_serial_start_failed'                         '^FAIL failure:'
leg serialfirst   'order: nothing but the sweep, the xenbus_monitor stop and the MSI-start check runs before the serialized start completes' '^FAIL (clean|order|failure|shipped):'
leg noserialstart 'clean: the recorded order is sweep, xbm, start QdbDaemon'                                           '^FAIL (clean|pacing|order|failure|violation|shipped|exit):'
leg startonexit   'exit: a step between msiexec and the start that Fails still gets the services started'          '^FAIL exit:'
leg failstart     'failpath: a Fail after msiexec starts the services one at a time BEFORE the RESULT is written'   '^FAIL failpath:'
leg msinostart    'msiexec: both /i argument lists carry QWTNG_SERIALSTART=1'                                          '^FAIL msiexec:'
say "--- outputs in $OUT"
exit $bad
