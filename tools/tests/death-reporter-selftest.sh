#!/usr/bin/env bash
# guest/qwt-report-death.ps1 is the ONE death reporter, and every guard fails on its own defect
# run: tools/tests/death-reporter-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# pwsh, FROM THE PATH IF IT IS THERE. The two dev-qube paths were the only candidates, so this suite
# could not run anywhere else - which is why it was never in tools/tests/offline-suites.txt and why the
# battery that gates every commit did not cover the death reporter at all. GitHub's ubuntu runners ship
# pwsh on the PATH, so the PATH is tried first and the dev-qube paths remain as fallbacks.
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
OUT="${DEATHREPORTER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/death-reporter-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/death-reporter-test.ps1"
REPORTER="$ROOT/guest/qwt-report-death.ps1"
HELPER="$ROOT/guest/qwt-notify-error.ps1"
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
        bootbacklog) printf '%s' '    $seed = $fresh   # DEFECT: the previous boot'"'"'s backlog is read and reported - the toasts the owner called misleading' ;;
        endedbyshutdown) printf '%s' '                $ended = '"'"'not-ended'"'"'   # DEFECT: a task instance ended BY A SHUTDOWN is reported as a death anyway' ;;
        timeoutdup) printf '%s' '                if ($false) {   # DEFECT: the 201 of a time-limit kill opens a SECOND death beside its 329 - one hang, two notifications' ;;
        wdjoin)    printf '%s' '                    $r.rec = '"'"'scm-agentdied'"'"'   # DEFECT: the watchdog'"'"'s agent-died exit opens a death of its own (a second notification per agent death)' ;;
        sysendtext) printf '%s' '            $sysEnd = $false   # DEFECT: a child Windows ended with its session gets the family'"'"'s header and advice (exited unexpectedly, a Task Scheduler restart)' ;;
        sysendisdeath) printf '%s' '                if ($false) {   # DEFECT: a child Windows ended with its session during a shutdown is escalated as a death (the measured five)' ;;
        scmshutdown) printf '%s' '                if ($false) {   # DEFECT: a service the SHUTDOWN stopped is escalated as a failing service (the SCM class had no shutdown test at all)' ;;
        launchshutdown) printf '%s' '                if ($false) {   # DEFECT: a task launch Windows refused because it is shutting down is escalated as a task that could not start' ;;
        build)     printf '%s' '    # DEFECT: the technical line does not name the build that produced it' ;;
        shortbuild) printf '%s' '    $techShort = (Format-QwtNotifyTechLine -Subject $subject -ProcessId $procId -Code $codeText -Ran $ran -Count "death $Number this boot" -Evidence '"'"'qwt-deaths.log'"'"') -replace '"'"'; build [^ ]+'"'"', '"'"''"'"'   # DEFECT: the short form drops the build' ;;
    esac
}
# which file a knob lives in: the route for build, the reporter for every other
knob_file() { case "$1" in build) printf '%s' "$HELPER" ;; *) printf '%s' "$REPORTER" ;; esac; }
knob_target() {
    case "$1" in
        build)     printf '%s' 'build: the technical line names the build that produced it, after the count' ;;
        shortbuild) printf '%s' 'short form: the over-length fallback line still carries the build' ;;
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
        bootbacklog) printf '%s' 'catch-up: a watermark from another boot reports NOTHING' ;;
        endedbyshutdown) printf '%s' 'ended by shutdown: a 201 whose instance Task Scheduler ended while the system went down' ;;
        timeoutdup) printf '%s' 'one kill one death: the 201 of an instance that has a 329 is ignored' ;;
        wdjoin)    printf '%s' 'wd exit: the watchdog'"'"'s 7024 with QGA_SVC_EXIT_AGENT_DIED attaches to the agent'"'"'s death' ;;
        sysendtext) printf '%s' 'teardown text: the header says Windows ended it, not that it exited unexpectedly or crashed' ;;
        sysendisdeath) printf '%s' 'shutdown teardown: a 4003 carrying 0x40010004 near a shutdown is ignored - nothing launched, ledger empty' ;;
        scmshutdown) printf '%s' 'purge: a service the shutdown stopped is ignored - no toast for the stop the shutdown asked for' ;;
        launchshutdown) printf '%s' 'purge: a launch refused because a shutdown is in progress is ignored - a launch that did not happen is not a death' ;;
    esac
}
make_copy() { # $1 knob -> the copy's path on stdout
    local knob=$1 copy="$OUT/reporter-defect-$1.ps1" hits src
    src=$(knob_file "$knob")
    hits=$(grep -c "# GUARD:$knob\$" "$src")
    if [ "$hits" -ne 1 ]; then say "FAIL  knob $knob: expected exactly 1 '# GUARD:$knob' line in $(basename "$src"), found $hits"; return 1; fi
    REPL="$(knob_line "$knob")" python3 - "$src" "$copy" "$knob" <<'EOF'
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

KNOBS="ours deathid anchorpid logfirst onerec werjoin helperjoin pidreuse managedonly installdir wdjoin endedbyshutdown timeoutdup sysendtext sysendisdeath build shortbuild scmshutdown launchshutdown bootbacklog"
# the suite against a copy with one knob applied: the route's knobs go in through -HelperPath, the reporter's through -ReporterPath
run_knob() { # $1 knob, $2 copy, $3 output file
    if [ "$(knob_file "$1")" = "$HELPER" ]; then "$PWSH" -NoProfile -File "$SUITE" -HelperPath "$2" >"$3" 2>&1
    else "$PWSH" -NoProfile -File "$SUITE" -ReporterPath "$2" >"$3" 2>&1; fi
}
if [ -n "${DEATHREPORTER_DEFECT:-}" ]; then
    case " $KNOBS " in *" $DEATHREPORTER_DEFECT "*) ;; *) say "FAIL  unknown DEATHREPORTER_DEFECT='$DEATHREPORTER_DEFECT' ($KNOBS)"; exit 2 ;; esac
    copy=$(make_copy "$DEATHREPORTER_DEFECT") || exit 2
    run_knob "$DEATHREPORTER_DEFECT" "$copy" /dev/stdout; rc=$?
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
    run_knob "$k" "$copy" "$OUT/defect-$k.out"; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$k.out")
    if [ $rc -ne 0 ] && grep -qF "FAIL $(knob_target "$k")" "$OUT/defect-$k.out"; then
        say "PASS  defect $k: suite FAILED as required on its target (rc=$rc, $f failing checks)"
    else
        say "FAIL  defect $k: rc=$rc target-failed=$(grep -cF "FAIL $(knob_target "$k")" "$OUT/defect-$k.out") first=[$(grep -m1 '^FAIL' "$OUT/defect-$k.out" | cut -c1-160)]"; bad=1
    fi
done
say "--- outputs in $OUT"
exit $bad
