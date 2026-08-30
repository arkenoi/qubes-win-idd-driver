#!/bin/bash
# Wait primitives with FAILURE MODES. Sourced by the matrix harness.
#
# Every wait here ends for one of four stated reasons, and says which:
#   SESSION/DONE   the thing we wanted happened
#   TERMINAL       the guest is in a state it will never leave on its own (recovery screen)
#   STALLED        nothing has changed for STALL_SECS - no new log lines, no state change
#   DEADLINE       the overall budget ran out
#
# The STALLED case is the one that was missing everywhere, and it is the common one: an install
# that finishes without rebooting, a guest that never halts, a stream that dies silently. Polling
# a fixed number of cycles and then reporting the deadline turns a 90-second answer into a
# 35-minute hang - measured today.
#
# Poll cadence is deliberately >= 15 s: per-second qrexec churn is what wedged a guest before
# (IPI shootdown, see FINDINGS), so these must not become tight loops.

STALL_SECS=${STALL_SECS:-300}
# Poll cadence for w_install. Default 20 s. A run that is EXPECTED to die early can lower it to
# catch the last lines before the guest goes - but not below ~5 s: qrexec churn wedged a guest
# once (IPI shootdown), so this is a floor, not a knob to turn down freely.
POLL_SECS=${POLL_SECS:-20}

w_state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

# Classify the guest's screen: RECOVERY | BLACK | DESKTOP | UNKNOWN | NOWINDOW
w_screen(){ # $1=vm $2=tag $3=outdir
  local vm=$1 tag=$2 dir=$3 out
  QTEST_VM=$vm timeout -k 8 150 ./tools/qtest fullshot "$dir/$tag.tar" >/dev/null 2>&1
  [ -s "$dir/$tag.tar" ] || { echo NOWINDOW; return; }
  out=$(python3 tools/winshot.py "$dir/$tag.tar" "$vm" -o "$dir/$tag.png" --classify 2>/dev/null)
  case "$out" in *VERDICT=*) echo "${out##*VERDICT=}" ;; *) echo NOWINDOW ;; esac
}

w_alive(){ QTEST_VM=$1 timeout -k 5 40 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | grep -qa QREADY; }

# Wait for a usable session. 0=session 1=terminal 2=deadline
w_session(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 t0 now st shots=0 blacks=0
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    [ "$now" -ge "$dl" ] && { $log "  $lbl: DEADLINE ${dl}s with no session (screen=$(w_screen "$vm" "$lbl-dl" "$dir"))"; return 2; }
    w_alive "$vm" && { $log "  $lbl: session up at t+${now}s"; return 0; }
    if [ $(( now / 60 )) -gt "$shots" ]; then
      shots=$(( now / 60 )); st=$(w_screen "$vm" "$lbl-t${now}" "$dir")
      $log "  $lbl: t+${now}s qvm=$(w_state "$vm") screen=$st"
      [ "$st" = RECOVERY ] && { $log "  $lbl: TERMINAL - recovery screen, not waiting and not restarting ($dir/$lbl-t${now}.png)"; return 1; }
      # A guest that is BLACK minute after minute is not booting either. Black is legitimately
      # transient during early boot, so one sample proves nothing - three consecutive minutes with
      # no session does. Measured today: a bricked guest stayed black and Transient for 15 minutes
      # while the harness sat inside qvm-start waiting for a qrexec that was never coming.
      if [ "$st" = BLACK ]; then
        blacks=$(( blacks + 1 ))
        # BLACK ALONE IS NOT TERMINAL. Measured 2026-08-28: a guest that looked dead behind a black
        # screen was consuming CPU steadily (cpu_time 92755 -> 119257 in 40 s, 8 GB resident) - it
        # was running headless with a half-installed QWT, not hung. Require no CPU as well, or this
        # rule declares a live guest dead.
        cpu=$(printf '' | timeout 20 qrexec-client-vm "$vm" admin.vm.Stats 2>/dev/null | tr -d '\0' \
              | grep -aoE 'cpu_usage_raw[0-9]+' | grep -aoE '[0-9]+' | awk '{t+=$1} END{if(NR)print t; else print "NA"}')
        $log "  $lbl: black #$blacks, cpu_usage_raw=${cpu:-NA}"
        if [ "$blacks" -ge 3 ] && [ "${cpu:-NA}" != NA ] && [ "$cpu" -gt 0 ] 2>/dev/null; then
          $log "  $lbl: black but consuming CPU (${cpu}) - the guest is RUNNING HEADLESS, not dead; still waiting"
          blacks=0
        elif [ "$blacks" -ge 3 ]; then
          $log "  $lbl: TERMINAL - black for ${blacks} min, cpu=${cpu:-NA}, qvm=$(w_state "$vm") ($dir/$lbl-t${now}.png)"
          return 1
        fi
      else
        blacks=0
      fi
    fi
    sleep 15
  done
}

# Wait for the install to reach a conclusion, whatever that conclusion is.
# 0=RESULT present  1=terminal(recovery)  2=deadline  3=guest halted  4=STALLED
# Reads the guest log by bounded polls: the Get-Content -Wait stream truncated silently at 28 of
# 104 lines today, so line COUNTS from a fresh read are the trustworthy signal.
w_install(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn $6=guest-log-path
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 glog=$6 t0 now n last=-1 lastchange st
  t0=$(date +%s); lastchange=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    [ "$now" -ge "$dl" ] && { $log "  $lbl: DEADLINE ${dl}s"; return 2; }
    if [ "$(w_state "$vm")" = Halted ]; then
      $log "  $lbl: guest HALTED at t+${now}s (install rebooted or shut it down)"; return 3
    fi
    if w_alive "$vm"; then
      # WHO issues a reboot: event 1074 records the process and reason for an OS-initiated
      # shutdown; 1076/6008 cover the unexpected ones. On a guest that is about to become
      # unbootable this must be read WHILE IT LIVES - afterwards there is nothing to ask.
      # Off by default (one extra qrexec call per cycle); EVENT_POLL=1 turns it on.
      if [ "${EVENT_POLL:-0}" = 1 ]; then
        QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run \
          'cmd /c wevtutil qe System /q:"*[System[(EventID=1074 or EventID=1076 or EventID=6008)]]" /c:4 /rd:true /f:text' \
          2>/dev/null | tr -d '\r' | grep -aiE 'Date|Process|Reason|shut down|Event ID' > "$dir/$lbl-shutdown-events.txt.new" || true
        # KEEP THE DATE. Without it a 1074 from this run cannot be told apart from one the golden
        # image already carried, and "the monitor rebooted it" becomes unfalsifiable.
        if [ -s "$dir/$lbl-shutdown-events.txt.new" ]; then
          { echo "# captured $(date '+%Y-%m-%d %H:%M:%S') at t+${now}s"; cat "$dir/$lbl-shutdown-events.txt.new"; } \
            > "$dir/$lbl-shutdown-events.txt"
        fi
        rm -f "$dir/$lbl-shutdown-events.txt.new"
      fi
      # ALSO poll the MSI's own verbose log. Our installer writes NOTHING while msiexec runs -
      # measured: its log stops at line 25 ("suppressor running") and the guest dies 108 s later,
      # so the entire window in which the brick happens is silent on our side. msiexec /l*v writes
      # continuously, so its tail names the action that was in flight when the guest went. This is
      # the only view into that window that survives, since the guest's disk cannot be read
      # afterwards (admin.vm.device.block.* on dom0 is refused by policy).
      if [ "${MSI_POLL:-1}" = 1 ]; then
        QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run \
          'cmd /c powershell -NoProfile -Command "if(Test-Path C:\qwt-install.log){Get-Content C:\qwt-install.log -Tail 40}"' \
          2>/dev/null | tr -d '\r' > "$dir/$lbl-msi.log.new" || true
        if [ -s "$dir/$lbl-msi.log.new" ]; then mv -f "$dir/$lbl-msi.log.new" "$dir/$lbl-msi.log"
        else rm -f "$dir/$lbl-msi.log.new"; fi
      fi
      n=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run \
            "cmd /c powershell -NoProfile -Command \"if(Test-Path '$glog'){(Get-Content '$glog').Count}else{0}\"" \
            2>/dev/null | tr -d '\r' | grep -aE '^[0-9]+$' | head -1)
      n=${n:-0}
      if [ "$n" -ne "$last" ]; then
        last=$n; lastchange=$(date +%s)
        # NEVER truncate what we already hold: > opens the file before the guest answers, so a
        # read that returns nothing (the guest dying - the moment that matters) wipes the capture.
        # TAIL, APPEND, DEDUP. Fetching the whole growing file loses the race with a dying guest:
        # measured 23:46 - the counter saw 25 lines, the last full capture that landed had 19, and
        # the six missing lines were exactly the ones under test (msiexec, the monitor kill).
        # A 15-line tail is small enough to complete, and appending into a cumulative file means a
        # partial or failed poll costs nothing instead of replacing good data with less of it.
        QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run \
          "cmd /c powershell -NoProfile -Command \"if(Test-Path '$glog'){Get-Content '$glog' -Tail 15}\"" \
          2>/dev/null | tr -d '\r' | grep -aE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^=== RESULT ===' >> "$dir/$lbl-install.tail" || true
        # THE FILTER MUST KEEP THE RESULT TRAILER. It used to be `grep -a '^2026'`, which drops
        # every line not starting with a timestamp - and the installer writes its trailer as
        # "=== RESULT === {json}" with NO timestamp (Install-QwtImproved.ps1). The success test
        # below then searched this filtered file for exactly that line, so w_install's success exit
        # was UNREACHABLE: every completed install ran to the STALL_SECS deadline and was graded
        # FAIL. A green product could not have produced a green matrix. Found 2026-08-30 by auditing
        # the harness against the installer instead of trusting it; never observed before only
        # because both archived runs aborted earlier for other reasons.
        # The year is no longer hardcoded either - '^2026' would have started silently dropping
        # every log line on 1 January.
        # Cumulative, order-preserving, deduplicated view - this is the file to read.
        if [ -s "$dir/$lbl-install.tail" ]; then
          awk '!seen[$0]++' "$dir/$lbl-install.tail" > "$dir/$lbl-install.log.tmp" && \
            mv -f "$dir/$lbl-install.log.tmp" "$dir/$lbl-install.log"
        fi
        $log "  $lbl: t+${now}s ${n} log lines | $(tail -1 "$dir/$lbl-install.log" | cut -c1-120)"
        # MATCH THE INSTALLER'S TERMINAL TRAILER, NOT ANY "=== RESULT ===" LINE.
        # 111 guest scripts emit that banner, and the installer LOGS THEIR OUTPUT as it runs - so a
        # bare match stops the wait at the first nested banner, mid-install. Measured 2026-08-30:
        # cell WIN10-1stage was graded 5 s after
        #   "2026-08-30 04:37:16 [INFO]   === RESULT === changed=0 warnings=0"
        # (ensure-autologon.ps1's banner) while the installer was still seeding the PV NIC latch.
        # The whole cell "completed" in 33 s and every json-derived check then failed against an
        # absent RESULT - reported as product FAILs when nothing had been measured.
        # Install-QwtImproved.ps1 writes its own trailer UNPREFIXED and followed by JSON:
        #   === RESULT === {"stage":"stage2-install","ok":true,...}
        # while nested banners are timestamped ("2026-.. [INFO]   === RESULT === ...") and are not
        # JSON. Anchoring to start-of-line plus the opening brace separates them exactly.
        if grep -qa '^=== RESULT === {' "$dir/$lbl-install.log"; then
          $log "  $lbl: RESULT line present at t+${now}s"; return 0
        fi
      elif [ $(( $(date +%s) - lastchange )) -ge "$STALL_SECS" ]; then
        st=$(w_screen "$vm" "$lbl-stall" "$dir")
        $log "  $lbl: STALLED - ${n} log lines unchanged for ${STALL_SECS}s, guest alive, screen=$st"
        return 4
      fi
    else
      if [ $(( $(date +%s) - lastchange )) -ge "$STALL_SECS" ]; then
        st=$(w_screen "$vm" "$lbl-stall" "$dir")
        $log "  $lbl: STALLED - unreachable for ${STALL_SECS}s, screen=$st"
        [ "$st" = RECOVERY ] && return 1
        return 4
      fi
    fi
    sleep $POLL_SECS
  done
}

# Wait for a clean halt. 0=halted 2=deadline. Never kills: the caller decides.
w_halt(){ # $1=vm $2=deadline $3=label $4=logfn
  local vm=$1 dl=$2 lbl=$3 log=$4 t0 now
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    [ "$(w_state "$vm")" = Halted ] && { $log "  $lbl: halted at t+${now}s"; return 0; }
    [ "$now" -ge "$dl" ] && { $log "  $lbl: DEADLINE ${dl}s, still $(w_state "$vm")"; return 2; }
    sleep 10
  done
}
