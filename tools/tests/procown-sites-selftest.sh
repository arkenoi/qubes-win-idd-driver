#!/usr/bin/env bash
# procown-sites-selftest.sh - offline proof matrix for every shipped site that used to kill a process BY NAME
# (owner's rule 2026-10-03, docs/ADR-updater.md 12.4; step 3 of the process-ownership change): the setup installer's
# SCM-pid service-stop helper, its xenbus_monitor stop, Stop-QwtRuntime, the stage-2 GUI quiesce and the pre-surgery
# re-assert; guest/activate-idd.ps1's quiesce; guest/pvnic-selfprime.ps1's QwtngNetSetup stop; guest/quiet-desktop.ps1's
# OneDrive block; the overlay installer's stop. Each now stops the OWNER (the service, through the SCM, waiting on the
# pid the SCM reports) or acts on that pid alone, asks the agent to exit through its own stop event, and REPORTS a
# survivor without touching it.
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is tools/tests/procown-sites-test.ps1, which
# extracts the marked regions of the shipped files and drives them against a fake service/process world that records
# every kill.
#
#   no env                 full matrix: the clean leg must PASS, and every defect knob must make the suite FAIL on the
#                          check it targets, and only within its own area (a guard never seen to fail is decoration).
#                          Exit 0 only if every leg came out as required.
#   PROCOWN_DEFECT=<knob>  run ONLY that knob and exit with the suite's own code - i.e. the knob makes this test FAIL,
#                          by design. Knobs: svcpid xbmbyname runtimebyname quiescebyname reassertbyname activatebyname
#                          netsetupbyname onedrivebyname overlaybyname.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/pwsh/pwsh
OUT="${PROCOWN_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/procown-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/procown-sites-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

KNOBS="svcpid xbmbyname wdstopdisarm runtimebyname quiescebyname reassertbyname activatebyname netsetupbyname onedrivebyname overlaybyname"
if [ -n "${PROCOWN_DEFECT:-}" ]; then
    case " $KNOBS " in *" $PROCOWN_DEFECT "*) ;; *) say "FAIL  unknown PROCOWN_DEFECT='$PROCOWN_DEFECT' ($KNOBS)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$PROCOWN_DEFECT"; rc=$?
    say "--- defect knob $PROCOWN_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 45 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-160))"; bad=1; fi

# Each knob must fail ITS target check, and only within its own area.
leg(){ # $1 knob, $2 target check (literal prefix), $3 allowed-failures regex
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" >"$OUT/defect-$1.out" 2>&1; local r=$? ff st
    ff=$(grep -c '^FAIL' "$OUT/defect-$1.out")
    st=$(grep '^FAIL' "$OUT/defect-$1.out" | grep -vE "$3" | head -3 | cut -c6-140)
    if [ $r -ne 0 ] && grep -qF "FAIL $2" "$OUT/defect-$1.out" && [ -z "$st" ]; then
        say "PASS  defect $1: suite FAILED as required on its target and only within its area (rc=$r, $ff failing checks)"
    else
        say "FAIL  defect $1: rc=$r target-failed=$(grep -cF "FAIL $2" "$OUT/defect-$1.out") stray=[$st]"; bad=1
    fi
}
# svcpid is planted in the SHARED helper (SVC-STOP), which the xbm, runtime, quiesce and activate regions dot-source: without
# the SCM pid none of them can wait on or end the service's own process, so their cases may fail too - all within the helper's users.
leg svcpid         'svcstop: with -TerminateSurvivor the lingering service process is ended by ITS handle (pid 100) and is dead afterwards' '^FAIL (svcstop|xbm|runtime|quiesce|activate):'
leg xbmbyname      'xbm: an orphan monitor the SCM does not own (pid 777) is reported, left ALIVE, and refused under -FatalIfSurvives' '^FAIL xbm:'
leg wdstopdisarm 'runtime: the watchdog service recovery is DISARMED BEFORE' 'runtime:'
leg runtimebyname  'runtime: an agent that ignores QGA_SHUTDOWN under an old watchdog is reported in gui_runtime_survivors with its pid and left ALIVE' '^FAIL runtime:'
leg quiescebyname  'quiesce: a foreign agent that ignores QGA_SHUTDOWN is reported (QUIESCE DID NOT HOLD, gui-agent/200) and left ALIVE' '^FAIL quiesce:'
leg reassertbyname 'reassert: a reappeared agent is recorded in idd_gui_reappeared with its pid and left ALIVE' '^FAIL reassert:'
leg activatebyname 'activate: a foreign agent that ignores QGA_SHUTDOWN makes Assert-GuiQuiesced refuse, naming gui-agent/200, and is left ALIVE' '^FAIL activate:'
leg netsetupbyname 'netsetup: a same-named stray (pid 501) that is not the SCM pid is left ALIVE' '^FAIL netsetup:'
leg onedrivebyname 'onedrive: the two policies are applied (changed=2) and the running instance (pid 300) is left ALIVE; the output says so' '^FAIL onedrive:'
leg overlaybyname  'overlay: an agent still running after the stop is warned about (pid 200 or the unreachable event) and left ALIVE; file replace is said to be at risk' '^FAIL overlay:'

say "--- outputs in $OUT"
exit $bad
