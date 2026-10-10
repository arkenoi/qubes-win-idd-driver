#!/usr/bin/env bash
# death-reporter-selftest.sh - offline proof matrix for guest/qwt-report-death.ps1, the ONE death reporter
# (docs/ADR-supervision.md 3). Runs on this dev qube with the linux pwsh; no rig, no guest, no event log.
#
#   clean    tools/tests/death-reporter-test.ps1 against the shipped reporter MUST pass
#   knobs    a copy of the reporter with ONE `# GUARD:<name>` line replaced by its defect MUST make the suite FAIL on
#            the check that guard protects (a guard never seen to fail is decoration):
#      ours        any executable is ours             -> a notepad.exe crash would be reported as a death of ours
#      deathid     one id for every death             -> the route's once-per-(component,id)-per-boot rule hides the second death
#      anchorpid   identity by executable only        -> a second death of the same exe inside the window is "the first"
#      logfirst    the ERROR line only when notified  -> past the cap, a death leaves no record in our log
#      onerec      a death absorbs any number of records of one type -> a service exiting without a crash record, over and
#                  over, is ONE notification (found in review 2026-10-03)
#      werjoin     a WER 1001 may open a death -> a foreign autologon.exe (its 1000 refused by path) is reported as ours
#      helperjoin  a helper task's 201 may open a death -> the agent ending its own helper is reported as a death
#      pidreuse    one pid is one death whatever it records -> a reused pid hides a second crash
#      managedonly a 1026 counts for any executable in the table -> a foreign .NET program named like ours is reported
#      installdir  the registry's install dir is ignored -> every crash of ours on a non-default install is refused
#      wdjoin      the watchdog's own failure exit (7024, QGA_SVC_EXIT_AGENT_DIED) opens a death of its own -> two notifications
#                  per agent death (2026-10-07, docs/ADR-supervision.md 5)
#      sysendtext  a child Windows ended with its session (exit 0x40010004) gets the family's text -> dom0 is told it "exited
#                  unexpectedly" and that Task Scheduler restarts it, into a session that is going away (the measured 2026-10-10
#                  shutdown notifications; outside a shutdown the record is still escalated, with its own header and line 1)
#      sysendisdeath a child Windows ended with its session DURING A SHUTDOWN is escalated -> the measured 2026-10-10 defect: five
#                  dom0 notifications on win10-acc, every one an ordinary shutdown (owner: "suppress only on shutdown")
#   DEATHREPORTER_DEFECT=<knob>  run only that knob and exit with the suite's own code (non-zero is the required outcome)
#   DEATHREPORTER_OUT=<dir>      outputs (default: a mktemp dir)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${DEATHREPORTER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/death-reporter-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/death-reporter-test.ps1"
REPORTER="$ROOT/guest/qwt-report-death.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# knob -> (the defect line that replaces the GUARD line, the check it must fail, the area its failures may touch)
knob_line() {
    case "$1" in
        ours)      printf '%s' '        if (-not $e) { return $false }   # DEFECT: any executable is ours' ;;
        deathid)   printf '%s' '    $id = '"'"'died'"'"'   # DEFECT: one id for every death - the route hides the second' ;;
        anchorpid) printf '%s' '            $match = $sameExe | Select-Object -First 1   # DEFECT: identity by executable only' ;;
        logfirst)  printf '%s' '    if ($false) { Write-QwtDeathLog '"'"'ERROR'"'"' '"'"'never'"'"' }   # DEFECT: the ERROR line only on the notify path' ;;
        onerec)    printf '%s' '        '"'"'enrich'"'"' { $match = $sameExe | Select-Object -First 1 }   # DEFECT: a death absorbs any number of records of one type' ;;
        werjoin)   printf '%s' '            $r.anchor = '"'"'enrich'"'"'   # DEFECT: a 1001 opens a death' ;;
        helperjoin) printf '%s' '                $r.exe = $script:QwtDeathHelperTasks[$task]; $r.component = $script:QwtDeathExes[$r.exe]; $r.anchor = '"'"'enrich'"'"'   # DEFECT: a helper 201 opens a death' ;;
        pidreuse)  printf '%s' '            # DEFECT: one pid is one death' ;;
        managedonly) printf '%s' '            if (-not (& $owned $exe '"'"''"'"')) { $r.reason = "managed application '"'"'$exe'"'"' is not ours"; return $r }   # DEFECT: any table executable' ;;
        installdir) printf '%s' '    if ($false) { }   # DEFECT: the registry install dir is ignored' ;;
        endedbyshutdown) printf '%s' '                $ended = '"'"'not-ended'"'"'   # DEFECT: a task instance ended BY A SHUTDOWN is reported as a death anyway' ;;
        wdjoin)    printf '%s' '                    $r.rec = '"'"'scm-agentdied'"'"'   # DEFECT: the watchdog'"'"'s agent-died exit opens a death of its own (a second notification per agent death)' ;;
        sysendtext) printf '%s' '            $sysEnd = $false   # DEFECT: a child Windows ended with its session gets the family'"'"'s header and advice (exited unexpectedly, a Task Scheduler restart)' ;;
        sysendisdeath) printf '%s' '                if ($false) {   # DEFECT: a child Windows ended with its session during a shutdown is escalated as a death (the measured five)' ;;
    esac
}
knob_target() {
    case "$1" in
        ours)      printf '%s' 'ours: a notepad.exe crash is not ours' ;;
        deathid)   printf '%s' 'e2e: death 2 - a SECOND gui-agent crash 30 s later (another pid) is a second death (want send' ;;
        anchorpid) printf '%s' 'pid identity: a crash of ANOTHER pid right after the watchdog'"'"'s record of the first is a second death' ;;
        logfirst)  printf '%s' 'log: death 9 is STILL logged at ERROR as NEW (past the cap)' ;;
        onerec)    printf '%s' 'svc loop: three bare 7031s of one service at 0/20/80 s are three deaths and three notifications' ;;
        werjoin)   printf '%s' 'wer join: a foreign autologon.exe - its 1000 refused by its path, its 1001 alone - opens no death and sends nothing' ;;
        helperjoin) printf '%s' 'helper join: a helper task'"'"'s 201 with no 4002/4003 (the agent ended the task itself) opens no death' ;;
        pidreuse)  printf '%s' 'pid reuse: a second crash record of the SAME pid 5 min later is a second death' ;;
        managedonly) printf '%s' 'clr not ours: a foreign .NET program named like one of our native executables (autologon.exe) is not ours' ;;
        installdir) printf '%s' 'install dir: the registry InstallDir decides, else the folder above the script'"'"'s bin, else the default' ;;
        endedbyshutdown) printf '%s' 'ended by shutdown: a 201 whose instance Task Scheduler ended while the system went down' ;;
        wdjoin)    printf '%s' 'wd exit: the watchdog'"'"'s 7024 with QGA_SVC_EXIT_AGENT_DIED attaches to the agent'"'"'s death' ;;
        sysendtext) printf '%s' 'teardown text: the header says Windows ended it, not that it exited unexpectedly or crashed' ;;
        sysendisdeath) printf '%s' 'shutdown teardown: a 4003 carrying 0x40010004 near a shutdown is ignored - nothing launched, ledger empty' ;;
    esac
}
make_copy() { # $1 knob -> the copy's path on stdout
    local knob=$1 copy="$OUT/reporter-defect-$1.ps1" hits
    hits=$(grep -c "# GUARD:$knob\$" "$REPORTER")
    if [ "$hits" -ne 1 ]; then say "FAIL  knob $knob: expected exactly 1 '# GUARD:$knob' line in the reporter, found $hits"; return 1; fi
    REPL="$(knob_line "$knob")" python3 - "$REPORTER" "$copy" "$knob" <<'EOF'
import os, sys
src, dst, knob = sys.argv[1:4]
repl = os.environ['REPL']
out = []
for line in open(src, encoding='utf-8').read().split('\n'):
    out.append(repl if line.endswith('# GUARD:' + knob) else line)
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
EOF
    printf '%s' "$copy"
}

KNOBS="ours deathid anchorpid logfirst onerec werjoin helperjoin pidreuse managedonly installdir wdjoin endedbyshutdown sysendtext sysendisdeath"
if [ -n "${DEATHREPORTER_DEFECT:-}" ]; then
    case " $KNOBS " in *" $DEATHREPORTER_DEFECT "*) ;; *) say "FAIL  unknown DEATHREPORTER_DEFECT='$DEATHREPORTER_DEFECT' ($KNOBS)"; exit 2 ;; esac
    copy=$(make_copy "$DEATHREPORTER_DEFECT") || exit 2
    "$PWSH" -NoProfile -File "$SUITE" -ReporterPath "$copy"; rc=$?
    say "--- defect knob $DEATHREPORTER_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 90 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-200))"; bad=1; fi

for k in $KNOBS; do
    copy=$(make_copy "$k") || { bad=1; continue; }
    "$PWSH" -NoProfile -File "$SUITE" -ReporterPath "$copy" >"$OUT/defect-$k.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$k.out")
    if [ $rc -ne 0 ] && grep -qF "FAIL $(knob_target "$k")" "$OUT/defect-$k.out"; then
        say "PASS  defect $k: suite FAILED as required on its target (rc=$rc, $f failing checks)"
    else
        say "FAIL  defect $k: rc=$rc target-failed=$(grep -cF "FAIL $(knob_target "$k")" "$OUT/defect-$k.out") first=[$(grep -m1 '^FAIL' "$OUT/defect-$k.out" | cut -c1-160)]"; bad=1
    fi
done
say "--- outputs in $OUT"
exit $bad
