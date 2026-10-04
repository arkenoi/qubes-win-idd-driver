#!/usr/bin/env bash
# svc-serial-start-selftest.sh - offline proof matrix for the serialized service start after msiexec AND the qrexec hold
# through the stage-2 device work (docs/ADR-boot.md 1 and 2): after msiexec QdbDaemon is started and observed RUNNING and
# READY before any further stage-2 step; QrexecAgent is HELD and started, observed RUNNING, only after the stage's last
# device-work step - or by every exit path that does not power off (Fail, the main catch, a refused power-off), and not at
# all on the -Auto -RebootAtEnd path, where the RESULT says so; QubesGuiWatchdog is held for the quiesce; a service that
# never starts is a loud, flagged failure; a RESULT written with QrexecAgent still held is flagged; an MSI that would start
# the services itself is refused before it runs, and reported if it did anyway. Runs on this dev qube with the linux pwsh;
# no rig, no guest. The suite is tools/tests/svc-serial-start-test.ps1, which extracts the marked regions of the shipped
# installer and drives them against a fake SCM, a fake clock, a fake qubesdb, a fake shutdown.exe and a scripted Windows
# Installer database, recording every call; its file-level checks read the whole installer.
#
#   no env                    full matrix: the clean leg must PASS, and every defect knob must make the suite FAIL on the
#                             check it targets, and only within its own area (a guard never seen to fail is decoration).
#                             Exit 0 only if every leg came out as required.
#   SVCSERIAL_DEFECT=<knob>   run ONLY that knob and exit with the suite's own code - i.e. the knob makes this test FAIL,
#                             by design. Knobs: msicontract noviolation startwatchdog nowaitrunning nowaitready silentfail
#                             serialfirst noserialstart startonexit failstart msinostart noholdqrexec releaseunobserved
#                             qrexecsilentfail noreleasestart startonpoweroff releaseearly regionearly releasetwice
#                             noqrexecflag failrelease catchrelease poweroffrefused emitcheck.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${SVCSERIAL_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/svcserial-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/svc-serial-start-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

KNOBS="msicontract noviolation startwatchdog nowaitrunning nowaitready silentfail serialfirst noserialstart startonexit failstart msinostart noholdqrexec releaseunobserved qrexecsilentfail noreleasestart startonpoweroff releaseearly regionearly releasetwice noqrexecflag failrelease catchrelease poweroffrefused emitcheck"
if [ -n "${SVCSERIAL_DEFECT:-}" ]; then
    case " $KNOBS " in *" $SVCSERIAL_DEFECT "*) ;; *) say "FAIL  unknown SVCSERIAL_DEFECT='$SVCSERIAL_DEFECT' ($KNOBS)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$SVCSERIAL_DEFECT"; rc=$?
    say "--- defect knob $SVCSERIAL_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 70 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-200))"; bad=1; fi

# Each knob must fail ITS target check, and only within its own area(s). Check names start with their area ('clean:',
# 'release:', 'release failure:', 'poweroff:', ...); the area regex is anchored on the FAIL line.
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
# ---- ADR-boot 1: the serialized start ----
leg msicontract   'contract: an MSI whose StartServices is not conditioned is REFUSED'                                 '^FAIL contract:'
leg noviolation   'violation: services found running right after msiexec are recorded in svc_msi_started'              '^FAIL violation:'
# the knob starts the watchdog in EVERY case, so every check that counts starts (the violation world, the not-held release) changes too
leg startwatchdog 'clean: QubesGuiWatchdog is never started by the serialized start'                                   '^FAIL (clean|violation|retry|shipped|exit):|^FAIL failure: the stage continues|^FAIL release: an agent the MSI had started'
# without the SCM wait every started service stays START_PENDING in the world: every observed start - the serialized one and the release at every site - changes
leg nowaitrunning 'pacing: QdbDaemon RUNNING is observed through the SCM before its first readiness probe'            '^FAIL (clean|pacing|order|failure|retry|exit|release|release failure|poweroff|maincatch|failpath):'
leg nowaitready   'pacing: the first step after the serialized start (recovery arming) runs only after QdbDaemon is observed RUNNING and READY' '^FAIL (clean|pacing|failure|violation|retry):'
leg silentfail    'failure: a service that never reaches RUNNING sets svc_serial_start_failed'                         '^FAIL failure:'
leg serialfirst   'order: nothing but the sweep, the xenbus_monitor stop and the MSI-start check runs before the serialized start completes' '^FAIL (clean|order|failure|shipped):'
leg noserialstart 'clean: the recorded order is sweep, xbm, start QdbDaemon'                                           '^FAIL (clean|pacing|order|failure|violation|shipped|exit|release|release failure|poweroff|maincatch):'
leg startonexit   'exit: a step between msiexec and the start that Fails still gets QdbDaemon started'                '^FAIL exit:'
leg failstart     'failpath: a Fail after msiexec starts the services one at a time BEFORE the RESULT is written'   '^FAIL failpath:'
leg msinostart    'msiexec: both /i argument lists carry QWTNG_SERIALSTART=1'                                          '^FAIL msiexec:'
# ---- ADR-boot 2: the qrexec hold ----
# QrexecAgent started right after QdbDaemon: nothing is held, so every hold/release/exit-path check changes
leg noholdqrexec  'clean: QrexecAgent is HELD by the serialized start'                                                 '^FAIL (clean|order|retry|exit|release|release failure|poweroff|maincatch|failpath):'
leg releaseunobserved 'release: after the device work QrexecAgent is started and observed RUNNING through the SCM'      '^FAIL (release|release failure|poweroff|maincatch|failpath):'
leg qrexecsilentfail 'release failure: a QrexecAgent that never reaches RUNNING at the release is flagged svc_qrexec_start_failed' '^FAIL release failure:'
leg noreleasestart 'release: after the device work QrexecAgent is started and observed RUNNING through the SCM'         '^FAIL (release|release failure):'
leg startonpoweroff 'release: on the -Auto -RebootAtEnd path QrexecAgent is NOT started'                               '^FAIL (release: on the -Auto|poweroff:)'
# file-level knobs (the in-memory copy of the installer is patched before extraction): the static place-of-the-release checks
leg releaseearly  'shipped: nothing starts QrexecAgent between the serialized start and the QREXEC-RELEASE site'       '^FAIL (shipped|clean|order|release|poweroff|maincatch):'
leg regionearly   'shipped: QrexecAgent is released only after the last device-work step of stage 2'                   '^FAIL (shipped|clean|order|pacing|release|poweroff|maincatch|exit|failure|violation|retry):'
# the skip marks the hold released: the static one-set/one-clear check, the skip's own "not marked released" assertion and the refused power-off all change
leg releasetwice  'shipped: the hold is set in one place (GUARD:holdqrexec) and cleared in one (Start-HeldQrexecAgent)' '^FAIL (shipped:|poweroff:|release: on the -Auto)'
leg noqrexecflag  'shipped: the stage-2 ok= block names svc_serial_start_failed, svc_qrexec_start_failed and svc_msi_started' '^FAIL shipped:'
# every exit path that does not power off releases the hold before its RESULT; the RESULT writer refuses a silent held state
leg failrelease   'failpath: that Fail also starts the QrexecAgent the serialized start held'                           '^FAIL failpath:'
leg catchrelease  'maincatch: an unexpected exception during the device work starts the held QrexecAgent'              '^FAIL maincatch:'
leg poweroffrefused 'poweroff: a refused shutdown starts the held QrexecAgent'                                         '^FAIL poweroff:'
leg emitcheck     'emit: a RESULT written with QrexecAgent still held records NEVER-STARTED'                            '^FAIL emit:'
say "--- outputs in $OUT"
exit $bad
