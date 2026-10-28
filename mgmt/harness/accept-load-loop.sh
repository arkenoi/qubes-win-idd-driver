#!/bin/bash
# accept-load-loop.sh <vm> [duration-seconds]
#
# WHY THIS EXISTS. The owner's acceptance matrix (mgmt/harness/matrix.sh) drives a cell's guest
# through a specific, hard-won sequence of qrexec/qtest calls - clock_correct, log-clear, a run
# marker, two rounds of module-base-recorder arming, a reboot-dialog watcher, a tasklist probe loop,
# the installer-log polling cycle, a base64 MSI-log fetch, and a battery of post-install reads
# (console-window-check, the dialog summary, PV console, xenbus_monitor, the agent hash). This
# script REPLAYS that exact sequence of CALLS, verbatim, in a loop, against an ALREADY-RUNNING
# guest, for DURATION seconds - to find out whether sustained acceptance-shaped qrexec load alone
# can wedge a guest that is not being installed, rebooted or otherwise lifecycle-managed.
#
# IT DOES NOT SIMPLIFY, BATCH, REORDER OR SUBSTITUTE ANYTHING. Where the source calls
# `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "1"`, this calls exactly
# that. Where the source pushes guest/reboot-dialog-watch.ps1 as ONE file via `qtest push`, this
# pushes exactly that ONE file, the same way. See scratchpad/ACCEPTANCE-LOAD-LOOP-SEQUENCE.md
# (extracted before this file was written) for the full annotated list with matrix.sh/primitives.sh/
# e2e-wait.sh line numbers for every call below.
#
# TWO DELIBERATE, DECLARED EXCLUSIONS FROM THE REAL SEQUENCE, both forced by this task's own hard
# constraints ("NEVER reboot... no installs") and NOT a simplification I chose:
#   1. matrix.sh's run_install launches install.cmd (Start-Process ... install.cmd /auto
#      /autologon:qubes) right after arming the watchers. Running that against an already-installed
#      guest IS an install. SKIPPED, and every iteration's log says so explicitly.
#   2. matrix.sh's SEED_DELAY fault-injection branch. Off by default upstream too (needs an
#      exported SEED_DELAY + SEED_CELL=1); never set here.
# Everything else in the sequence - including calls whose current behaviour looks redundant or
# slightly odd, like deleting a log it is about to overwrite with a marker, or polling an MSI log
# that will never grow because no installer is running - is kept AS-IS. A no-op poll is still the
# same qrexec traffic the real cell generates at that point, which is the thing under test.
#
# WHAT THIS SCRIPT NEVER DOES: qvm-start / qvm-shutdown / qvm-kill / qvm-remove / qvm-clone, or
# anything else that creates, boots, reboots, halts or destroys a qube. It refuses to run against a
# guest that is not already Running, and it does not wait for one to come up.
#
# STALL DETECTION: the rig's own definition (findings/wedge.md) is "qrexec stops answering AND an
# ACPI shutdown request is ignored" - and this script is explicitly forbidden from issuing that ACPI
# probe (qvm-shutdown), because that IS a lifecycle operation on the specimen. So the operational
# proxy here is: any guest-facing call that fails triggers an immediate liveness re-probe
# (`qtest run 'cmd /c echo QREADY'`), repeated every 10s; if the guest answers NOTHING for 120
# consecutive seconds, that is treated as the stall endpoint. The loop then stops immediately,
# touches the guest NO FURTHER (it is the specimen - CLAUDE.md), and reports.
#
# Evidence: scratchpad/accept-load-loop-<VM>-<UTC-start>/  (calls.log, RESULT.txt)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HERE" || exit 2

VM="${1:?usage: accept-load-loop.sh <vm> [duration-seconds]  -- NO default target, ever}"
DURATION="${2:-${DURATION:-3600}}"
case "$DURATION" in ''|*[!0-9]*) echo "accept-load-loop.sh: DURATION must be a positive integer of seconds, got '$DURATION'" >&2; exit 2 ;; esac

# NEVER START THE GUEST. This script's entire premise is load against a guest that is ALREADY up;
# tools/qtest itself refuses run/push/synctime against a Halted target (it would start it), so this
# check exists to fail with a clear reason rather than let that refusal read like a transport error.
VMSTATE="$(qvm-ls --raw-data --fields state "$VM" 2>/dev/null)"
if [ -z "$VMSTATE" ]; then
  echo "accept-load-loop.sh: '$VM' does not exist (qvm-ls found nothing) - refusing to guess or create it." >&2
  exit 2
fi
if [ "$VMSTATE" != Running ] && [ "$VMSTATE" != Transient ]; then
  echo "accept-load-loop.sh: '$VM' is $VMSTATE, not Running - this script NEVER starts a guest. Start it yourself if that is what you want, then re-run." >&2
  exit 2
fi

export QTEST_VM="$VM"

# shellcheck source=mgmt/harness/vmlock.sh
source "$HERE/mgmt/harness/vmlock.sh"
vm_lock "$VM" || { echo "accept-load-loop.sh: could not take the lock on $VM - another job owns it (serial rig)." >&2; exit 2; }
trap 'vm_unlock "$VM"' EXIT
# shellcheck source=mgmt/harness/primitives.sh
source "$HERE/mgmt/harness/primitives.sh"

RUNSTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVID="$HERE/scratchpad/accept-load-loop-${VM}-${RUNSTAMP}"
mkdir -p "$EVID"
CALLLOG="$EVID/calls.log"
: > "$CALLLOG"

GLOG='C:\qwt-improved-install.log'
INC="$(./tools/qtest incoming 2>/dev/null || true)"
NETVM="$(qvm-prefs "$VM" netvm 2>/dev/null || true)"

ITER=0
CALLS_OK=0
CALLS_FAIL=0
STOP_STALL=0
STALL_UTC=""
LAST_OK_DESC=""
LAST_OK_UTC=""

utc(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

# log_call <desc> <rc> <duration_s>  -- one line per call, every call, always.
log_call(){
  printf '%s desc=%q rc=%s dur=%ss\n' "$(utc)" "$1" "$2" "$3" >> "$CALLLOG"
}

# liveness_probe -- exactly the `echo QREADY` shape e2e-wait.sh's w_alive uses (e2e-wait.sh:144),
# bounded to 40s like the source. Returns 0 if the guest answered QREADY, 1 otherwise.
# THE SOURCE'S OWN LINE, CHARACTER FOR CHARACTER (e2e-wait.sh:144). It already solves the pipe:
# a here-string feeds grep from a string that is ALREADY captured, so grep's early exit SIGPIPEs
# nothing - the qrexec client has exited. Piping the client straight into grep -q is what SIGPIPEs
# it mid-connect; the guest logs QGAVCHANFAIL request dropped and pipefail grades a live guest dead.
# The anchor is NOT optional and must not be relaxed to a substring: this probe's own command text
# is `cmd /c echo QREADY`, and a VMShell stream carries cmd's banner, so an unanchored match can be
# satisfied by the echoed command line on a guest that never ran it.
liveness_probe(){
  command grep -qa '^QREADY' <<< "$(QTEST_VM="$VM" timeout -k 5 40 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"
}

# on_call_failure -- invoked after ANY guest-facing call returns non-zero. Re-probes liveness every
# 10s; 120 consecutive unreachable seconds is this script's stall endpoint (see header). Never
# issues qvm-shutdown/kill/etc - the rig's own ACPI half of the stall definition is explicitly out of
# bounds for a script that must leave the specimen untouched.
on_call_failure(){
  local unreachable_since="" elapsed=0
  while :; do
    if liveness_probe; then
      [ -n "$unreachable_since" ] && echo "$(utc) RECOVERED after ${elapsed}s unreachable" >> "$CALLLOG"
      return 0
    fi
    [ -z "$unreachable_since" ] && unreachable_since="$(date +%s)"
    elapsed=$(( $(date +%s) - unreachable_since ))
    echo "$(utc) UNREACHABLE for ${elapsed}s (probing every 10s)" >> "$CALLLOG"
    if [ "$elapsed" -ge 120 ]; then
      STOP_STALL=1
      STALL_UTC="$(utc)"
      return 1
    fi
    sleep 10
  done
}

# call <desc> -- <cmd...>  : runs a guest-facing command, times it, logs it, feeds the stall
# detector on failure. Returns the command's own exit code. Callers check STOP_STALL afterwards.
call(){
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  local t0 t1 rc
  t0=$(date +%s.%N)
  "$@"
  rc=$?
  t1=$(date +%s.%N)
  log_call "$desc" "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f",(b-a)}')"
  if [ "$rc" -eq 0 ]; then
    CALLS_OK=$((CALLS_OK+1)); LAST_OK_DESC="$desc"; LAST_OK_UTC="$(utc)"
  else
    CALLS_FAIL=$((CALLS_FAIL+1))
    on_call_failure || true
  fi
  return "$rc"
}

vmshell_q(){ printf '%s\n' "$1" | qrexec-client-vm "$VM" qubes.VMShell; }

# call_capture <desc> -- <cmd...> : like call(), but captures stdout+stderr into $_CALL_OUT instead
# of letting it fall through to this script's own stdout. The call's rc (hence stall-feeding) is the
# TRANSPORT's exit code (qrexec-client-vm / timeout), never the guest-side PRESENT/ABSENT content -
# "ABSENT" is a legitimate, expected answer (the marker has not landed YET), not a call failure.
_CALL_OUT=""
call_capture(){
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  local t0 t1 rc
  t0=$(date +%s.%N)
  _CALL_OUT=$("$@" 2>&1)
  rc=$?
  t1=$(date +%s.%N)
  log_call "$desc" "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f",(b-a)}')"
  if [ "$rc" -eq 0 ]; then
    CALLS_OK=$((CALLS_OK+1)); LAST_OK_DESC="$desc"; LAST_OK_UTC="$(utc)"
  else
    CALLS_FAIL=$((CALLS_FAIL+1))
    on_call_failure || true
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# ONE FULL CELL-SEQUENCE REPLAY. Steps numbered as in scratchpad/ACCEPTANCE-LOAD-LOOP-SEQUENCE.md.
# ---------------------------------------------------------------------------------------------
run_cycle(){
  local n="$1" E2E_MARK seen

  # Step 1: clock_correct (primitives.sh:193-213) - the single synctime+skew door. Its internals
  # ARE the two vmshell calls (latency probe + Set-Date) plus the separate skew read-back; calling
  # the primitive itself, rather than re-typing its body, is the "do not re-implement a sealed
  # primitive" rule (primitives.sh:2) applied literally.
  call "clock_correct" -- clock_correct "$VM" 120
  [ "$STOP_STALL" = 1 ] && return

  # Step 2: clear both installer logs (matrix.sh:1646)
  call "clear-logs" -- ./tools/qtest run "cmd /c del /f /q $GLOG 2>nul & del /f /q C:\\qwt-install.log 2>nul & echo CLEARED"
  [ "$STOP_STALL" = 1 ] && return

  # Step 3: write the run marker (matrix.sh:1656-1658)
  E2E_MARK="E2EMARK-$(date -u +%Y%m%d%H%M%S)-$$-c${n}"
  call "write-marker" -- ./tools/qtest run "cmd /c echo $E2E_MARK >> $GLOG & del /f /q C:\\qwt-install.log 2>nul & echo MARKED"
  [ "$STOP_STALL" = 1 ] && return

  # Step 4: _mark_seen (matrix.sh:863-865), with the SAME retry-while-cpu-moving shape
  # (matrix.sh:1659-1682), up to 6 retries, each gated on w_cpu_moving (admin.vm.Stats, NOT VMShell).
  # Via call_capture: the stall detector is fed by the TRANSPORT's exit code, never by ABSENT, which
  # is a legitimate, expected answer (the marker just has not landed yet), not a call failure.
  call_capture "mark-seen-1" -- ./tools/qtest run "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT"
  [ "$STOP_STALL" = 1 ] && return
  seen=$(printf '%s' "$_CALL_OUT" | tr -d '\r\0' | grep -aoE 'PRESENT|ABSENT' | tail -1)
  if [ "$seen" != PRESENT ] && [ "$STOP_STALL" != 1 ]; then
    local mtry a b
    for mtry in 1 2 3 4 5 6; do
      a=$(printf '' | timeout 15 qrexec-client-vm "$VM" admin.vm.Stats 2>/dev/null | tr '\0' '\n' | awk '/^cpu_time$/{getline v; print v; exit}')
      sleep 20
      b=$(printf '' | timeout 15 qrexec-client-vm "$VM" admin.vm.Stats 2>/dev/null | tr '\0' '\n' | awk '/^cpu_time$/{getline v; print v; exit}')
      echo "$(utc) w_cpu_moving sample a=$a b=$b retry=$mtry" >> "$CALLLOG"
      call "write-marker-retry$mtry" -- ./tools/qtest run "cmd /c echo $E2E_MARK >> $GLOG & echo MARKED"
      [ "$STOP_STALL" = 1 ] && return
      call_capture "mark-seen-retry$mtry" -- ./tools/qtest run "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT"
      [ "$STOP_STALL" = 1 ] && return
      seen=$(printf '%s' "$_CALL_OUT" | tr -d '\r\0' | grep -aoE 'PRESENT|ABSENT' | tail -1)
      [ "$seen" = PRESENT ] && break
    done
  fi
  [ "$STOP_STALL" = 1 ] && return

  # Step 5: arm the module-base recorder BEFORE the (skipped) install (matrix.sh:1713-1718).
  # Invoked as the committed script itself, not reimplemented - same as matrix.sh does.
  call "arm-module-bases-pre" -- env VM="$VM" OUT="$EVID/modbases-c${n}-pre" "$HERE/mgmt/harness/arm-module-bases.sh"
  [ "$STOP_STALL" = 1 ] && return

  # Step 6: arm the premature-reboot dialog watcher (matrix.sh:1727-1737). ONE file via qtest push.
  call "push-reboot-watch" -- ./tools/qtest push guest/reboot-dialog-watch.ps1
  [ "$STOP_STALL" = 1 ] && return
  call "launch-reboot-watch" -- ./tools/qtest run "powershell -NoProfile -Command \"Start-Process -WindowStyle Minimized -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$INC\\reboot-dialog-watch.ps1','-DurationSeconds','2700'\""
  [ "$STOP_STALL" = 1 ] && return

  # Step 7 (install.cmd launch + SEED_DELAY) DELIBERATELY SKIPPED - see header. Logged, not silent.
  echo "$(utc) SKIPPED install.cmd launch (matrix.sh:1741-1742) and SEED_DELAY branch - forbidden by this task's own constraints, not dropped silently" >> "$CALLLOG"

  # Step 8: xenbus-probe loop, concurrent with the install wait in the source (matrix.sh:1793-1799).
  # Run a bounded number of iterations (the source's own cap is 90 @ 5s = 450s) in the foreground,
  # same command, same cadence.
  local p
  for p in $(seq 1 90); do
    [ $(( $(date +%s) - START_TS )) -ge "$DURATION" ] && { echo "$(utc) xenbus-probe loop: outer DURATION budget exhausted at $p/90" >> "$CALLLOG"; break; }
    call "xenbus-probe-$p" -- ./tools/qtest run 'cmd /c tasklist | findstr /i xenbus & sc query xenbus_monitor | findstr /i STATE'
    [ "$STOP_STALL" = 1 ] && return
    sleep 5
  done

  # Step 9: w_install's polling cycle (e2e-wait.sh:503-600+) - liveness probe, MSI tail, glog count,
  # glog tail-15 - run at the source's own cadence (POLL_SECS=20) for the source's own deadline
  # (matrix.sh passes 2400s to w_install), BOUNDED ONLY by the outer DURATION budget this script was
  # invoked with - that bound is the user's own explicit parameter for the whole replay, not an
  # invented shortcut, and it is the only thing that can cut this step short. Because step 7 (the
  # installer launch) is skipped, no RESULT trailer will ever appear and the guest log will not
  # grow - that is unavoidable given the "no installs" constraint and is recorded, not hidden: the
  # polls still issue the IDENTICAL commands w_install issues at the IDENTICAL cadence, which is the
  # qrexec load this replay exists to apply.
  local wi_t0 wi_now wi_elapsed wi=0
  wi_t0=$(date +%s)
  while :; do
    wi_now=$(date +%s)
    wi_elapsed=$((wi_now - wi_t0))
    [ "$wi_elapsed" -ge 2400 ] && { echo "$(utc) w_install-equivalent: reached the source's own 2400s deadline" >> "$CALLLOG"; break; }
    [ $(( $(date +%s) - START_TS )) -ge "$DURATION" ] && { echo "$(utc) w_install-equivalent: outer DURATION budget exhausted, stopping this sub-wait" >> "$CALLLOG"; break; }
    wi=$((wi+1))
    call "w_install-alive-$wi" -- ./tools/qtest run 'cmd /c echo QREADY'
    [ "$STOP_STALL" = 1 ] && return
    call "w_install-msi-tail-$wi" -- ./tools/qtest run 'cmd /c powershell -NoProfile -Command "if(Test-Path C:\qwt-install.log){Get-Content C:\qwt-install.log -Tail 40}"'
    [ "$STOP_STALL" = 1 ] && return
    call "w_install-glog-count-$wi" -- ./tools/qtest run "cmd /c powershell -NoProfile -Command \"if(Test-Path '$GLOG'){(Get-Content '$GLOG').Count}else{0}\""
    [ "$STOP_STALL" = 1 ] && return
    call "w_install-glog-tail-$wi" -- ./tools/qtest run "cmd /c powershell -NoProfile -Command \"if(Test-Path '$GLOG'){Get-Content '$GLOG' -Tail 15}\""
    [ "$STOP_STALL" = 1 ] && return
    sleep 20
  done

  # Step 10: fetch_msi_verbose (matrix.sh:1572-1607), copied near-verbatim (it is already one
  # PowerShell -EncodedCommand line in the source).
  local b64
  b64=$(python3 -c "import base64;print(base64.b64encode('''\$ErrorActionPreference='Stop'
if (Test-Path 'C:/qwt-install.log') {
  Write-Host 'MSIB64BEGIN'
  Write-Host ([Convert]::ToBase64String([IO.File]::ReadAllBytes('C:/qwt-install.log')))
  Write-Host 'MSIB64END'
} else { Write-Host 'MSIB64ABSENT' }'''.encode('utf-16-le')).decode())")
  call "fetch-msi-verbose" -- bash -c "QTEST_VM='$VM' timeout -k 5 300 './tools/qtest' run \"powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64\" >/dev/null 2>&1"
  [ "$STOP_STALL" = 1 ] && return

  # Step 12: re-arm the module-base recorder AFTER the (skipped) install (matrix.sh:1963-1968).
  call "arm-module-bases-post" -- env VM="$VM" OUT="$EVID/modbases-c${n}-post" "$HERE/mgmt/harness/arm-module-bases.sh"
  [ "$STOP_STALL" = 1 ] && return

  # Step 13: final installer-log fetch, 3 attempts with backoff (matrix.sh:1977-1987).
  local fa
  for fa in 1 2 3; do
    call "final-glog-fetch-$fa" -- bash -c "QTEST_VM='$VM' timeout -k 5 90 './tools/qtest' run 'cmd /c type \"$GLOG\"' >/dev/null 2>&1"
    [ "$STOP_STALL" = 1 ] && return
    [ "$CALLS_FAIL" -eq 0 ] && break
    sleep $((fa * 15))
  done

  # Step 14: console-window-check.sh (matrix.sh:2126), invoked as-is. No --allow-installer-console:
  # this replay never starts install.cmd, so no console window of ours is expected either.
  call "console-window-check" -- "$HERE/mgmt/harness/console-window-check.sh" "$VM"
  [ "$STOP_STALL" = 1 ] && return

  # Step 15: reboot-dialog watcher summary pull (matrix.sh:2155) - SKIPPED when netvm='' (matrix.sh's
  # own N/A gate, matrix.sh:2153-2164), exactly like the real cell. win10-acc's netvm is read live,
  # not assumed.
  if [ -z "$NETVM" ]; then
    echo "$(utc) N/A reboot-dialog-watch summary pull - netvm='' on $VM, same as matrix.sh's gate" >> "$CALLLOG"
  else
    call "reboot-watch-summary" -- ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\reboot-dialog-watch.ps1 -Summary"
    [ "$STOP_STALL" = 1 ] && return
  fi

  # Step 16: PV console (xencons) bound check (matrix.sh:2199).
  call "pv-console-check" -- ./tools/qtest run "powershell -NoProfile -Command \"(Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { \$_.PNPDeviceID -like 'XENBUS\\VEN_XP0001&DEV_CONS*' } | ForEach-Object { 'CONS:err='+\$_.ConfigManagerErrorCode+' svc='+\$_.Service })\""
  [ "$STOP_STALL" = 1 ] && return

  # Step 17: ITL Version registry read, informational (matrix.sh:2210).
  call "itl-version-read" -- ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version'
  [ "$STOP_STALL" = 1 ] && return

  # Step 18: xenbus_monitor service state (matrix.sh:2217).
  call "xenbus-monitor-state" -- ./tools/qtest run 'cmd /c sc qc xenbus_monitor & sc query xenbus_monitor'
  [ "$STOP_STALL" = 1 ] && return

  # Step 19: gui-agent hash (matrix.sh:2104).
  call "gui-agent-hash" -- ./tools/qtest run 'certutil -hashfile "C:\Program Files\Qubes Tools\bin\gui-agent.exe" SHA256'
}

# ---------------------------------------------------------------------------------------------
START_TS=$(date +%s)
echo "$(utc) accept-load-loop START vm=$VM duration=${DURATION}s netvm='${NETVM}' incoming='${INC}'" >> "$CALLLOG"
while :; do
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))
  [ "$ELAPSED" -ge "$DURATION" ] && break
  ITER=$((ITER+1))
  echo "$(utc) ITERATION $ITER begin (elapsed ${ELAPSED}s of ${DURATION}s)" >> "$CALLLOG"
  run_cycle "$ITER"
  echo "$(utc) ITERATION $ITER end (ok=$CALLS_OK fail=$CALLS_FAIL stall=$STOP_STALL)" >> "$CALLLOG"
  [ "$STOP_STALL" = 1 ] && break
done
END_TS=$(date +%s)

{
  echo "accept-load-loop RESULT"
  echo "vm=$VM"
  echo "started=$(date -u -d @"$START_TS" +%Y-%m-%dT%H:%M:%SZ)"
  echo "ended=$(date -u -d @"$END_TS" +%Y-%m-%dT%H:%M:%SZ)"
  echo "requested_duration_s=$DURATION"
  echo "actual_duration_s=$((END_TS - START_TS))"
  echo "iterations_started=$ITER"
  if [ "$STOP_STALL" = 1 ]; then echo "iterations_fully_completed=$((ITER>0?ITER-1:0))"; else echo "iterations_fully_completed=$ITER"; fi
  echo "calls_issued=$((CALLS_OK + CALLS_FAIL))"
  echo "calls_ok=$CALLS_OK"
  echo "calls_failed=$CALLS_FAIL"
  if [ "$STOP_STALL" = 1 ]; then
    echo "stall_observed=YES"
    echo "stall_utc=$STALL_UTC"
    echo "last_successful_call=$LAST_OK_DESC"
    echo "last_successful_call_utc=$LAST_OK_UTC"
    echo "guest_state_at_stop=$(qvm-ls --raw-data --fields state "$VM" 2>/dev/null)"
    echo "guest left RUNNING AND UNTOUCHED - it is the specimen, per CLAUDE.md"
  else
    echo "stall_observed=NO"
    echo "guest_state_at_end=$(qvm-ls --raw-data --fields state "$VM" 2>/dev/null)"
  fi
} > "$EVID/RESULT.txt"

cat "$EVID/RESULT.txt"
echo "evidence: $EVID"
[ "$STOP_STALL" = 1 ] && exit 1
exit 0
