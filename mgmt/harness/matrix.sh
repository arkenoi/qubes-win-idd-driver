#!/bin/bash
# FULL INSTALL/UPGRADE MATRIX for 4.3.15.
#
# "we did major change so regressions could be literally anywhere" - so this covers the paths a
# user can actually take, not just the one the previous e2e happened to exercise:
#
#   fresh-1stage   testsigning already ACTIVE -> stage 2 only, no reboot          (win10, win11)
#   fresh-2stage   testsigning OFF -> stage 1, reboot, stage 2                    (never tested before)
#   seeded         pending xenbus reboot Request + monitor auto-start             (the field's state)
#   upgrade-ours   4.3.14 installed first, then 4.3.15 over it
#   upgrade-stock  stock QWT 4.2.2 installed first, then 4.3.15 over it
#   appvm          derive an AppVM from the installed template, cold boot it
#
# Every cell starts from a FRESH CLONE of the golden, so no cell can inherit another's damage, and
# each states its own verdict. Cells are selected with CELLS="..." and run SERIALLY - concurrent
# VM-mutating jobs reboot each other, which has destroyed results here before.
set -uo pipefail
cd /home/user/qubes-win-idd-driver
source .claude/skills/win-guest-e2e/e2e-lib.sh
# P0-PRE (protocol H0): the wait primitives are sourced from the REPO, not from a session tmp
# directory. They used to live under /home/user/.claude/jobs/<id>/tmp, which is session-scoped and
# garbage-collectable - the same class of mistake that once nearly lost the only copy of a
# matrix's evidence. A harness whose wait library can vanish between campaigns is not a harness.
source "$(dirname "${BASH_SOURCE[0]}")/e2e-wait.sh"

# Working area for downloaded artifacts. Overridable, and no longer hardcoded to one session's
# tmp: a campaign must be re-runnable from a fresh session.
S="${MATRIX_WORK:-$HOME/qwt-matrix-work}"; mkdir -p "$S"
# Results directory. It used to be hardcoded to a Claude session tmp
# (/home/user/.claude/jobs/<id>/tmp/matrix) — session-scoped and garbage-collectable, which is how
# the only copy of the 2026-08-28 matrix evidence came within a GC of being lost, and why the cell
# logs now live in evidence/2026-08-29-fresh-cell-contamination/. Default somewhere durable and let
# a caller override; never write a run's only record to a path that disappears with the session.
M="${MATRIX_OUT:-$HOME/qwt-matrix/$(date -u +%Y%m%d-%H%M%S)}"; mkdir -p "$M"
R=$M/matrix.log; : > "$R"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$R"; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); say "PASS  $*"; }
no(){ FAIL=$((FAIL+1)); say "FAIL  $*"; }
# qvm-start BLOCKS until qrexec connects (up to qrexec_timeout). On a guest that never boots
# that is dead silence for the whole timeout - measured today: 15 minutes of a harness that
# looked hung was simply sitting inside qvm-start. Fire it and poll the state ourselves.
start_vm(){ timeout -k 10 150 qvm-start "$1" >/dev/null 2>&1 & disown; sleep 8; }

GLOG='C:\qwt-improved-install.log'
TAR=$S/qwt-setup.tar.gz
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

reclone(){ # $1=golden $2=target
  local g=$1 t=$2
  # NEVER KILL. Measured 2026-08-28: a guest sitting in the Windows recovery screen honours ACPI
  # shutdown and halts in 10 s, so the kill bought nothing - and it COST the next step, because a
  # killed guest leaves its volume dirty and qubesd then refuses the clone outright:
  #   "Cannot import to dirty volume qubes_dom0/vm-win10-tpl-private - start and stop a qube to
  #    cleanup"
  # which is how a cell that had already reproduced the bug failed with "could not reclone".
  if [ "$(w_state "$t")" != Halted ]; then
    qvm-shutdown "$t" >/dev/null 2>&1
    if ! w_halt "$t" 420 "shutdown-$t" say; then
      say "  $t ignored ACPI shutdown for 420 s (screen=$(w_screen "$t" "stuck-$t" "$M")) - killing as the last resort"
      qvm-kill "$t" >/dev/null 2>&1
      w_halt "$t" 120 "kill-$t" say >/dev/null 2>&1
      say "  NOTE: a killed guest leaves a dirty volume; the clone below may need the start/stop cycle"
    fi
  fi
  # Keep the error text. "could not reclone" told me nothing; the real message named the cause
  # exactly (dirty volume after a kill) and pointed straight at the fix.
  local cerr
  cerr=$(python3 - "$g" "$t" 2>&1 <<'EOF'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
dst.virt_mode='hvm'; dst.kernel=''
dst.memory=8192; dst.maxmem=0; dst.vcpus=4; dst.qrexec_timeout=600
EOF
  ) || { say "  clone attempt 1 FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"; }

  # RETRY WITH RECOVERY, up to three more times. A guest that was killed - or one that bricked and
  # never completed startup - leaves its volumes dirty and qubesd refuses the import. The error
  # names the remedy ("start and stop a qube to cleanup") and it works, but ONE cycle is not
  # always enough: measured 2026-08-28, the first retry cleared -root and then failed on
  # -private, and the single-shot version reported "could not reclone" on a rig that was one more
  # cycle from fine. A bricked guest never reaches Running, so the loop does not require it to.
  local att i
  for att in 2 3 4; do
    echo "$cerr" | grep -qa 'dirty volume' || break
    # REVERT, don't cycle. The documented remedy ("start and stop a qube to cleanup") assumes the
    # guest can BOOT - and the guests that dirty their volumes here are exactly the ones that
    # cannot: bricked, ignoring ACPI for 420 s, then killed. That cycle burned ~10 minutes per
    # attempt and still failed. admin.vm.volume.Revert is policied, needs no boot, and clears the
    # dirty state in seconds (measured 2026-08-28: revert root+private -> clone OK immediately).
    say "  dirty volume - reverting root+private to their last snapshot (clone attempt $att)"
    if [ "$(w_state "$t")" != Halted ]; then
      qvm-shutdown "$t" >/dev/null 2>&1
      w_halt "$t" 120 "revert-halt-$t" say >/dev/null 2>&1 || { qvm-kill "$t" >/dev/null 2>&1; sleep 10; }
    fi
    local v rev
    for v in root private; do
      rev=$(printf '' | timeout 15 qrexec-client-vm "$t" admin.vm.volume.ListSnapshots+$v 2>/dev/null | tr -d '\0' | tr ' ' '\n' | grep -a 'back' | head -1)
      [ -n "$rev" ] || { say "    no snapshot for $v - cannot revert"; continue; }
      printf '%s' "$rev" | timeout 60 qrexec-client-vm "$t" admin.vm.volume.Revert+$v >/dev/null 2>&1
      say "    reverted $v to $rev"
    done
    cerr=$(python3 - "$g" "$t" 2>&1 <<'EOF'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
dst.virt_mode='hvm'; dst.kernel=''
dst.memory=8192; dst.maxmem=0; dst.vcpus=4; dst.qrexec_timeout=600
EOF
) && { cerr=''; break; }
    say "  clone attempt $att FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"
  done
  [ -z "$cerr" ] || { say "  clone FAILED after every retry"; return 1; }
  say "  cloned $g -> $t"
}

push_payload(){ # $1=vm $2=dir-name
  # RETRY, and keep the error text. A session that has just answered its first `echo QREADY` is
  # not necessarily ready to receive a file: the first attempt failed in ONE SECOND right after
  # "session up at t+0s", and the old code threw the message away and failed the whole cell on a
  # transient. Three attempts, 20 s apart, and the stderr goes into the log either way.
  local vm=$1 d=$2 a rc
  for a in 1 2 3; do
    QTEST_VM=$vm timeout -k 8 900 ./tools/qtest push "$TAR" >"$M/$d-push.out" 2>&1; rc=$?
    [ $rc -eq 0 ] && break
    say "  $d: push attempt $a failed (rc=$rc): $(tail -1 "$M/$d-push.out" | cut -c1-140)"
    sleep 20
  done
  [ $rc -eq 0 ] || { no "$d: push failed 3 times - $(tail -1 "$M/$d-push.out" | cut -c1-140)"; return 1; }
  QTEST_VM=$vm qrun "cmd /c \"rmdir /s /q C:\\$d 2>nul & mkdir C:\\$d & tar -xzf $INC\\$(basename $TAR) -C C:\\$d && echo EXTRACT_OK\"" 2>/dev/null \
    | grep -qa EXTRACT_OK || { no "$d: extract failed"; return 1; }
  say "  $d: payload pushed and extracted"
}

# Run the installer and judge the outcome. Sets CELL_RC.
run_install(){ # $1=vm $2=label $3=payload-dir $4=extra-args
  local vm=$1 lbl=$2 d=$3 extra=${4:-}
  # Clear BOTH logs. The MSI verbose log lives at a fixed path and survives from earlier installs,
  # so without this the capture can show a two-week-old install and read as this run's evidence.
  QTEST_VM=$vm qrun "cmd /c del /f /q $GLOG 2>nul & del /f /q C:\\qwt-install.log 2>nul & echo CLEARED" >/dev/null 2>&1
  QTEST_VM=$vm qrun "cmd /c start \"\" /min C:\\$d\\install.cmd /auto /autologon:qubes $extra" >/dev/null 2>&1
  # SEED_DELAY: write the PV reboot Request mid-MSI, which is when the field gets it.
  #
  # CONTAMINATION GUARD, added 2026-08-29. SEED_DELAY is an ENVIRONMENT variable, so if it is set
  # anywhere in the calling environment it fires in EVERY cell — including cells named and reported
  # as unseeded — and its only record was a separate <label>-seed.log that the cell transcript never
  # references. That is exactly what happened: the 01:16 WIN10-fresh cell was seeded at install+25s
  # while matrix.log said nothing, and its brick observation is void. See FINDINGS 2026-08-29 and
  # evidence/2026-08-29-fresh-cell-contamination/.
  #
  # Two rules now: the seed state is ALWAYS written to the cell transcript (so "unseeded" is a
  # recorded fact, not an absence), and firing requires an explicit per-run opt-in — an inherited
  # SEED_DELAY alone is a hard abort, never a silent injection.
  say "  $lbl: SEED_DELAY=${SEED_DELAY:-unset} SEED_CELL=${SEED_CELL:-unset}"
  if [ -n "${SEED_DELAY:-}" ] && [ "${SEED_CELL:-}" != "1" ]; then
    no "$lbl: SEED_DELAY=${SEED_DELAY} is set but SEED_CELL=1 was not — refusing to inject into a"
    no "     cell that does not declare itself seeded. Export SEED_CELL=1 deliberately, or unset"
    no "     SEED_DELAY. (Inherited-env injection voided the 2026-08-28 WIN10 matrix.)"
    CELL_RC=2
    return 1
  fi
  if [ -n "${SEED_DELAY:-}" ]; then
    # Timestamp the injection from the same clock the installer logs with, so "before/after msiexec"
    # is decidable afterwards instead of inferred.
    say "  $lbl: SEEDED CELL — injecting PV reboot Request at install+${SEED_DELAY}s"
  fi
  if [ -n "${SEED_DELAY:-}" ]; then
    ( sleep "$SEED_DELAY"
      QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run \
        'cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request\xenvbd" /v Reboot /t REG_DWORD /d 1 /f /reg:64 & echo REQ_WRITTEN' \
        2>/dev/null | tr -d '\r' | grep -a REQ_WRITTEN >> "$M/$lbl-seed.log" 2>&1
      echo "request written at install+${SEED_DELAY}s ($(date +%H:%M:%S))" >> "$M/$lbl-seed.log" ) &
  fi
  # Probe the MONITOR PROCESS directly. tasklist is far cheaper than reading a growing log, so it
  # keeps answering while the guest is busy - which is exactly where every file-read poll lost the
  # race and cost us the six lines that mattered.
  ( for _p in $(seq 1 90); do
      echo "[$(date +%H:%M:%S)] $(QTEST_VM=$vm timeout -k 3 25 ./tools/qtest run \
        'cmd /c tasklist | findstr /i xenbus & sc query xenbus_monitor | findstr /i STATE' \
        2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-150)" >> "$M/$lbl-monitor.log" 2>&1
      sleep 5
    done ) &
  PROBE_PID=$!
  w_install "$vm" 2400 "$lbl" "$M" say "$GLOG"; CELL_RC=$?
  kill ${PROBE_PID:-0} 2>/dev/null
  case $CELL_RC in
    0) say "  $lbl: install reported a RESULT" ;;
    1) no "$lbl: guest went to the recovery screen DURING the install" ;;
    2) no "$lbl: install hit the 2400s deadline" ;;
    3) say "  $lbl: guest halted during/after the install (expected for a two-stage install)" ;;
    4) no "$lbl: install STALLED (no progress for ${STALL_SECS}s)" ;;
  esac
  return 0
}

verify_installed(){ # $1=vm $2=label   - the guest must be healthy and carry OUR build
  local vm=$1 lbl=$2 j
  # Report WHICH terminal state, never a guess. This line used to say "boots to the Windows
  # recovery screen" for every terminal verdict, and printed exactly that for a guest that was
  # black and still consuming CPU - a harness that misnames the failure is how wrong conclusions
  # get written down as facts.
  # THE INSTALLER EXPECTS THE CALLER TO REBOOT. Its own closing lines say so: "INSTALL COMPLETE -
  # the PV drivers bind at the guest's NEXT start ... -RebootAtEnd restores the old behaviour for a
  # caller that wants the finished state immediately (our own acceptance harness reboots by itself)".
  # On any path that installs the PV drivers FRESH, that swap tears down the vchan qrexec runs on,
  # so no session can appear until the guest restarts - and waiting 900 s for one and calling the
  # result a brick is what produced ten identical black screens.
  #
  # qrexec is gone, but admin.vm.Stats is not: CPU tells us when the install actually finished.
  if ! w_alive "$vm"; then
    say "  $lbl: no qrexec (expected while the MSI replaces the agent / swaps PV drivers) - waiting for the install to go quiet"
    local quiet=0 q c
    for q in $(seq 1 60); do
      c=$(printf '' | timeout 20 qrexec-client-vm "$vm" admin.vm.Stats 2>/dev/null | tr -d '\0' \
          | grep -aoE 'cpu_usage_raw[0-9]+' | grep -aoE '[0-9]+' | awk '{t+=$1} END{if(NR)print t; else print 9999}')
      if [ "${c:-9999}" -lt 60 ] 2>/dev/null; then quiet=$((quiet+1)); else quiet=0; fi
      [ $((q % 4)) -eq 0 ] && say "    t+$((q*15))s cpu=${c:-?} quiet=$quiet"
      [ "$quiet" -ge 3 ] && { say "  $lbl: CPU quiet - the install has finished working"; break; }
      w_alive "$vm" && { say "  $lbl: qrexec came back on its own at t+$((q*15))s"; break; }
      sleep 15
    done
    if ! w_alive "$vm"; then
      say "  $lbl: rebooting the guest, as the installer's contract requires of its caller"
      qvm-shutdown "$vm" >/dev/null 2>&1
      w_halt "$vm" 420 "$lbl-postinstall-halt" say || { qvm-kill "$vm" >/dev/null 2>&1; sleep 10; }
      start_vm "$vm"
    fi
  fi
  w_session "$vm" 900 "$lbl-back" "$M" say
  case $? in
    1) no "$lbl: BRICKED - $(grep -a "$lbl-back: TERMINAL" "$R" | tail -1 | sed 's/.*TERMINAL - //' | cut -c1-120)"; return 1 ;;
    2) no "$lbl: no session within 900s even after the post-install reboot (last screen: $(w_screen "$vm" "$lbl-final" "$M"))"; return 1 ;;
  esac
  ok "$lbl: guest came back with a session"
  QTEST_VM=$vm timeout -k 5 120 ./tools/qtest run "cmd /c type \"$GLOG\"" 2>/dev/null \
    | tr -d '\r' | grep -av 'system32>' > "$M/$lbl-final.log"
  j=$(grep -ao '=== RESULT === .*' "$M/$lbl-final.log" | tail -1)
  say "  $lbl RESULT: $(echo "$j" | cut -c1-300)"
  echo "$j" | grep -qa "\"installed_gui_agent_sha256\":\"$ASHA" \
    && ok "$lbl: installed agent == release binary" || no "$lbl: installed agent is NOT the release binary"
  echo "$j" | grep -qa '"autologon":"armed"' \
    && ok "$lbl: autologon armed" || no "$lbl: autologon NOT armed ($(echo "$j" | grep -ao '"autologon":"[^"]*"'))"
  local ver; ver=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  $lbl installed version: $ver"

  # PROVE THE MECHANISM, not just the absence of a brick. The fix is in xenbus.inf: the monitor
  # service must be installed but DISABLED and NOT RUNNING after the driver install. Asserting
  # this is what separates "the fix works" from "this run happened not to lose the race" - the
  # old INF starts the service (SPSVCSINST_STARTSERVICE, StartType=auto), so on an unfixed build
  # this check FAILS, which is what makes its PASS evidence.
  local q; q=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run 'cmd /c sc qc xenbus_monitor & sc query xenbus_monitor' 2>/dev/null | tr -d '\r')
  local start state
  start=$(echo "$q" | grep -aiE 'START_TYPE' | head -1 | sed 's/^[[:space:]]*//')
  state=$(echo "$q" | grep -aiE '^\s*STATE' | head -1 | sed 's/^[[:space:]]*//')
  say "  $lbl xenbus_monitor: ${start:-<no service>} | ${state:-<no state>}"
  if echo "$start" | grep -qai 'DISABLED'; then
    ok "$lbl: xenbus_monitor is DISABLED by the shipped INF"
  else
    no "$lbl: xenbus_monitor start type is NOT disabled ($start) - the INF patch did not reach this guest"
  fi
  if echo "$state" | grep -qai 'STOPPED'; then
    ok "$lbl: xenbus_monitor is not running"
  else
    no "$lbl: xenbus_monitor is RUNNING ($state) - it can still restart the guest"
  fi
}

# --------------------------------------------------------------------------- cells
cell_fresh_1stage(){ # $1=golden $2=tpl $3=tag   testsigning already active -> stage 2, no reboot
  say "######## CELL $3-fresh-1stage ########"
  reclone "$1" "$2" || { no "$3-fresh-1stage: could not reclone"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-1stage-boot" "$M" say || { no "$3-fresh-1stage: clone did not boot"; return; }
  push_payload "$2" q4315 || return
  run_install "$2" "$3-1stage" q4315
  if [ "$(w_state "$2")" = Halted ]; then start_vm "$2"; fi
  verify_installed "$2" "$3-1stage"
}

cell_fresh_2stage(){ # testsigning OFF first -> the TRUE two-stage path, never tested before
  say "######## CELL $3-fresh-2stage (testsigning OFF -> stage 1 -> reboot -> stage 2) ########"
  reclone "$1" "$2" || { no "$3-fresh-2stage: could not reclone"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-2stage-pre" "$M" say || { no "$3-fresh-2stage: clone did not boot"; return; }
  QTEST_VM=$2 qrun 'cmd /c bcdedit /set testsigning off & echo TS_OFF' 2>/dev/null | grep -qa TS_OFF \
    && say "  testsigning turned OFF for the next boot" || { no "$3-fresh-2stage: could not turn testsigning off"; return; }
  QTEST_VM=$2 qrun 'cmd /c shutdown /r /t 0' >/dev/null 2>&1
  w_halt "$2" 420 "$3-2stage-tsoff-halt" say || { no "$3-fresh-2stage: did not halt"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-2stage-boot" "$M" say || { no "$3-fresh-2stage: did not come back with testsigning off"; return; }
  local sso; sso=$(QTEST_VM=$2 timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v SystemStartOptions' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  SystemStartOptions now: $sso"
  echo "$sso" | grep -qai TESTSIGNING && { no "$3-fresh-2stage: testsigning still ACTIVE - this cell cannot test what it claims"; return; }
  ok "$3-fresh-2stage: precondition real (testsigning inactive) - the installer must now do stage 1"
  push_payload "$2" q4315 || return
  run_install "$2" "$3-2stage-s1" q4315
  # stage 1 ends by rebooting; this testbed halts on that.
  if [ "$(w_state "$2")" = Halted ]; then
    say "  stage 1 rebooted the guest - starting it for stage 2"
    start_vm "$2"
    w_session "$2" 900 "$3-2stage-s2boot" "$M" say
    case $? in
      1) no "$3-fresh-2stage: BRICKED after stage 1 - recovery screen"; return ;;
      2) no "$3-fresh-2stage: never came back after stage 1"; return ;;
    esac
    # stage 2 resumes from the boot task; wait for it to write its RESULT
    w_install "$2" 2400 "$3-2stage-s2" "$M" say "$GLOG"
    grep -qa 'stage2' "$M/$3-2stage-s2-install.log" 2>/dev/null \
      && ok "$3-fresh-2stage: stage 2 ran after the reboot" || no "$3-fresh-2stage: no stage-2 marker in the log"
  else
    no "$3-fresh-2stage: stage 1 did not reboot the guest - the two-stage path did not happen"
  fi
  verify_installed "$2" "$3-2stage"
}

cell_seeded(){ # the field's state: a pending PV reboot request + the monitor set to auto-start
  say "######## CELL $3-seeded (pending xenbus Request + monitor auto-start) ########"
  say "  THIS IS THE SUSPECTED BRICK. Control (seed off) completed in 90 s and stayed healthy;"
  say "  the seeded run halted at 80 s mid-MSI and came back in Automatic Repair. n=2, unproven."
  reclone "$1" "$2" || { no "$3-seeded: could not reclone"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-seeded-boot" "$M" say || { no "$3-seeded: clone did not boot"; return; }
  push_payload "$2" q4315 || return
  local XK='HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor'
  # TIMING IS THE WHOLE TEST, and the old timing made this cell meaningless. Writing the Request
  # BEFORE the install let the already-running, idle monitor act on it immediately: measured
  # 2026-08-29, event 1074 at 00:20:10Z versus the installer's first log line at 00:20:15 - the
  # restart was in flight five seconds before the installer existed. No installer-side fix can
  # prevent that, so six "failures" said nothing about the fix under test.
  #
  # The field's sequence is: installer runs -> stops/disables the monitor -> msiexec starts -> the
  # PV driver install files a Request MID-MSI. So arm auto-start here, and write the Request
  # DURING msiexec (run_install, SEED_DELAY) - after the installer has had its chance.
  QTEST_VM=$2 qrun "cmd /c sc config xenbus_monitor start= auto >nul & echo ARMED" 2>/dev/null \
    | grep -qa ARMED && ok "$3-seeded: monitor armed (Request lands mid-MSI)" || { no "$3-seeded: could not arm - cell inconclusive"; return; }
  run_install "$2" "$3-seeded" q4315
  if [ "$(w_state "$2")" = Halted ]; then
    say "  the guest HALTED during the install - this is the reproduction if it now fails to boot"
    start_vm "$2"
  fi
  verify_installed "$2" "$3-seeded"
}

cell_fresh(){ # $1=golden $2=tpl $3=tag  - a TRUE fresh install: QWT removed first
  # The goldens all carry QWT already, so "fresh" has to be constructed: uninstall what is there,
  # confirm it is gone, then install ours onto a guest with no previous QWT. This is the path a
  # brand-new qube takes, and it is the one the xenbus.inf change governs (the driver package IS
  # applied when it was never installed, so AddService/StartType actually take effect).
  say "######## CELL $3-fresh (uninstall QWT, then install ours) ########"
  reclone "$1" "$2" || { no "$3-fresh: could not reclone"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-fresh-boot" "$M" say || { no "$3-fresh: clone did not boot"; return; }
  local before; before=$(QTEST_VM=$2 timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  QWT before: ${before:-<none>}"
  # Uninstall every registered QWT product, quietly, suppressing any reboot.
  QTEST_VM=$2 timeout -k 8 1200 ./tools/qtest pushrun /home/user/.claude/jobs/c2a0f57b/tmp/uninstall-qwt.ps1 2>/dev/null | tr -d '\r' | grep -a "=== UNINSTALL ===" | tail -1 | sed 's/^/  /' | tee -a "$R"
  # The uninstall may want a reboot to finish; give it one so the next install starts clean.
  QTEST_VM=$2 qrun 'cmd /c shutdown /r /t 0' >/dev/null 2>&1
  w_halt "$2" 420 "$3-fresh-unihalt" say || { no "$3-fresh: guest did not reboot after uninstall"; return; }
  start_vm "$2"
  w_session "$2" 900 "$3-fresh-reboot" "$M" say
  case $? in
    1) no "$3-fresh: guest bricked by the UNINSTALL, before our install ran at all"; return ;;
    2) no "$3-fresh: guest never came back after the uninstall reboot"; return ;;
  esac
  # ASSERT ON THE SIGNAL THE CODE UNDER TEST USES. The old check read the ITL registry Version key -
  # which our own uninstall deletes - while the MSI PRODUCT REGISTRATION survived. It therefore
  # printed "precondition real (no QWT installed)" about a guest where the installer then found
  # "installed QWT (4.3.2.0) ... IN-PLACE MSI major upgrade", so the cell upgraded over a
  # half-uninstalled system: a state no user produces, and its failure was not evidence about us.
  local prod; prod=$(QTEST_VM=$2 timeout -k 8 240 ./tools/qtest pushrun /home/user/.claude/jobs/c2a0f57b/tmp/count-qwt.ps1 \
    2>/dev/null | tr -d '\r' | grep -aoE 'QWTPRODUCTS=[0-9]+' | tail -1 | cut -d= -f2)
  say "  QWT products still registered after uninstall: ${prod:-<unreadable>}"
  if [ "${prod:-1}" != 0 ]; then
    no "$3-fresh: ${prod:-?} QWT product(s) still registered - NOT a fresh install, cell INVALID"
    return
  fi
  ok "$3-fresh: precondition real (no QWT product registered - the signal the installer reads)"
  push_payload "$2" q4315 || return
  run_install "$2" "$3-fresh" q4315
  if [ "$(w_state "$2")" = Halted ]; then start_vm "$2"; fi
  verify_installed "$2" "$3-fresh"
}

cell_upgrade_stock(){ # $1=golden $2=tpl $3=tag  - stock QWT 4.2.2 in place, then ours over it
  # The field's actual path: a guest running the shipped 4.2.2 gets our package on top.
  say "######## CELL $3-upgrade-stock (stock 4.2.2 -> 4.3.15) ########"
  reclone "$1" "$2" || { no "$3-upgrade-stock: could not reclone"; return; }
  start_vm "$2"
  w_session "$2" 600 "$3-stock-boot" "$M" say || { no "$3-upgrade-stock: clone did not boot"; return; }
  # Remove the newer QWT first: Windows Installer will not "upgrade" down to 4.2.2.
  QTEST_VM=$2 timeout -k 8 1200 ./tools/qtest pushrun /home/user/.claude/jobs/c2a0f57b/tmp/uninstall-qwt.ps1 2>/dev/null | tr -d '\r' | grep -a "=== UNINSTALL ===" | tail -1 | sed 's/^/  stock-prep /' | tee -a "$R"
  QTEST_VM=$2 qrun 'cmd /c shutdown /r /t 0' >/dev/null 2>&1
  w_halt "$2" 420 "$3-stock-unihalt" say || { no "$3-upgrade-stock: no reboot after removing QWT"; return; }
  start_vm "$2"
  w_session "$2" 900 "$3-stock-clean" "$M" say || { no "$3-upgrade-stock: guest lost after removing QWT"; return; }
  # Push and install the SHIPPED 4.2.2 MSI - the real thing users have.
  QTEST_VM=$2 timeout -k 8 900 ./tools/qtest push vendor/qwt-4.2.2/installer.msi >/dev/null 2>&1 \
    || { no "$3-upgrade-stock: could not push the stock MSI"; return; }
  QTEST_VM=$2 timeout -k 8 1800 ./tools/qtest run "cmd /c msiexec /i \"$INC\\installer.msi\" /qn /norestart REBOOT=ReallySuppress /l*v C:\\stock-install.log & echo STOCKRC=%ERRORLEVEL%" 2>/dev/null | tr -d '\r' | grep -a 'STOCKRC=' | tail -1 | sed 's/^/  stock install /' | tee -a "$R"
  QTEST_VM=$2 qrun 'cmd /c shutdown /r /t 0' >/dev/null 2>&1
  w_halt "$2" 420 "$3-stock-halt" say
  start_vm "$2"
  w_session "$2" 900 "$3-stock-up" "$M" say
  case $? in
    1) no "$3-upgrade-stock: guest bricked by the STOCK install (not ours)"; return ;;
    2) no "$3-upgrade-stock: guest never came back after the stock install"; return ;;
  esac
  local sv; sv=$(QTEST_VM=$2 timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  stock QWT now: ${sv:-<none>}"
  case "$sv" in *4.2.2*) ok "$3-upgrade-stock: precondition real (stock 4.2.2 installed)" ;;
                *) no "$3-upgrade-stock: stock 4.2.2 is not installed ($sv) - cell INVALID"; return ;; esac
  push_payload "$2" q4315 || return
  run_install "$2" "$3-upgrade-stock" q4315
  if [ "$(w_state "$2")" = Halted ]; then start_vm "$2"; fi
  verify_installed "$2" "$3-upgrade-stock"
}

cell_appvm(){ # $1=unused $2=tpl $3=tag $4=appvm - derive an AppVM and cold boot it
  say "######## CELL $3-appvm (derive from the installed template, cold boot) ########"
  local tpl=$2 app=${4:-}
  [ -n "$app" ] || { no "$3-appvm: no AppVM name"; return; }
  if [ "$(w_state "$tpl")" != Halted ]; then
    qvm-shutdown "$tpl" >/dev/null 2>&1
    w_halt "$tpl" 420 "$3-appvm-tplhalt" say || { no "$3-appvm: template would not halt"; return; }
  fi
  if [ "$(w_state "$app")" != Halted ]; then
    qvm-shutdown "$app" >/dev/null 2>&1; w_halt "$app" 420 "$3-appvm-halt" say >/dev/null 2>&1
  fi
  qvm-prefs "$app" template "$tpl" >/dev/null 2>&1 || { no "$3-appvm: could not point $app at $tpl"; return; }
  say "  $app now derives from $tpl"
  local b
  for b in 1 2 3; do
    say "  --- $3 AppVM cold boot $b/3 ---"
    if [ "$(w_state "$app")" != Halted ]; then
      qvm-shutdown "$app" >/dev/null 2>&1; w_halt "$app" 420 "$3-appvm-b${b}-halt" say >/dev/null 2>&1
    fi
    start_vm "$app"
    w_session "$app" 900 "$3-appvm-b$b" "$M" say
    case $? in
      0) : ;;
      1) no "$3-appvm boot $b: terminal state, guest unusable"; return ;;
      2) no "$3-appvm boot $b: no session within 900s"; return ;;
    esac
    # Pixels, not logs: open notepad and require a mapped, non-fullscreen window.
    QTEST_VM=$app timeout -k 5 45 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1
    local try W=0 big=0 f w h
    for try in 1 2 3 4 5 6; do
      sleep 7
      rm -f $M/$3-appvm-b$b.tar
      QTEST_VM=$app timeout -k 8 120 ./tools/qtest shot $M/$3-appvm-b$b.tar >/dev/null 2>&1
      [ -s $M/$3-appvm-b$b.tar ] && [ "$(tar tf $M/$3-appvm-b$b.tar 2>/dev/null | grep -c '\.png$')" -gt 0 ] && break
    done
    rm -rf $M/$3-appvm-b$b-png; mkdir -p $M/$3-appvm-b$b-png
    tar xf $M/$3-appvm-b$b.tar -C $M/$3-appvm-b$b-png 2>/dev/null
    for f in $M/$3-appvm-b$b-png/*.png; do
      [ -e "$f" ] || continue
      W=$((W+1)); read -r w h < <(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(33); w,h=struct.unpack('>II',d[16:24]); print(w,h)" "$f" 2>/dev/null)
      [ -z "${w:-}" ] && continue
      say "    $(basename $f) ${w}x${h}"
      [ "$w" -ge $(( 5120 * 99 / 100 )) ] && [ "$h" -ge $(( 1440 * 99 / 100 )) ] && big=1
    done
    QTEST_VM=$app timeout -k 5 45 ./tools/qtest run 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1
    if [ "$big" = 1 ]; then no "$3-appvm boot $b: a FULLSCREEN-SIZED window was mapped"
    elif [ "$W" -gt 0 ]; then ok "$3-appvm boot $b: $W window(s) mapped, none fullscreen-sized"
    else no "$3-appvm boot $b: notepad opened but dom0 got NO window"; fi
  done
}

# --------------------------------------------------------------------------- driver
[ -s "$TAR" ] || { say "FATAL no setup tarball at $TAR"; exit 1; }
ASHA=$(sha256sum $S/dl/qwt-full-package/gui-agent.exe | cut -c1-12)
PV=$(python3 -c "import json;print(json.load(open('$S/dl/qwt-improved-iso/MANIFEST.json'))['package_version'])")
say "=== MATRIX for $PV (agent $ASHA) ==="
say "  cells: ${CELLS:-seeded}"
for c in ${CELLS:-seeded}; do
  case $c in
    win10-seeded)   cell_seeded        win10-clean win10-tpl WIN10 ;;
    win10-1stage)   cell_fresh_1stage  win10-clean win10-tpl WIN10 ;;
    win10-2stage)   cell_fresh_2stage  win10-clean win10-tpl WIN10 ;;
    win11-1stage)   cell_fresh_1stage  win11-fresh win11-tpl WIN11 ;;
    win11-2stage)   cell_fresh_2stage  win11-fresh win11-tpl WIN11 ;;
    win11-seeded)   cell_seeded        win11-fresh win11-tpl WIN11 ;;
    win10-fresh)    cell_fresh         win10-clean win10-tpl WIN10 ;;
    win11-fresh)    cell_fresh         win11-fresh win11-tpl WIN11 ;;
    win10-stock)    cell_upgrade_stock win10-clean win10-tpl WIN10 ;;
    win11-stock)    cell_upgrade_stock win11-fresh win11-tpl WIN11 ;;
    win10-appvm)    cell_appvm         - win10-tpl WIN10 win10-app ;;
    win11-appvm)    cell_appvm         - win11-tpl WIN11 win11-app ;;
    *) say "unknown cell '$c'" ;;
  esac
done
say ""
say "=== MATRIX: $PASS passed, $FAIL failed ==="
say "=== DONE ==="
