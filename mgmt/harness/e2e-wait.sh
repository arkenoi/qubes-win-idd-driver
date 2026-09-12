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
#
# PER-WINDOW ONLY. NO DESKTOP CAPTURE, EVER.
#
# This called `qtest fullshot` unconditionally and KEPT the tar - the entire dom0 desktop, every
# other qube, the owner's editor, dom0 scrollback - from 2026-08-30 until 2026-09-09. It was found
# only because a stall capture was opened by hand and contained the owner's notes. Three such
# captures reached a PUBLIC repo once before.
#
# THE BELIEF THAT KEPT IT THERE WAS FALSE. "fullshot is the only instrument that can see a
# session-less guest" (stability-e2e.sh's comment, and my own first fix here) is wrong:
# local.WinScreenshot selects windows by the dom0-set _QUBES_VMNAME property and captures each with
# `import -window <wid>` - it NEVER touches the root window, and a guest with no session still has
# its framebuffer drawn by the gui-daemon as a window carrying that property. So the per-window
# service sees the early-install and Automatic-Repair cases too. There is nothing to fall back FOR.
#
# An empty result is NOWINDOW - a real verdict every caller already handles - and NOT a reason to
# photograph the desktop. Its three causes (target missing/untagged, tool discarded the window,
# genuinely no windows) are diagnosed by checking the target and the tool, never by widening the
# capture.
w_screen(){ # $1=vm $2=tag $3=outdir
  local vm=$1 tag=$2 dir=$3 out
  QTEST_VM=$vm timeout -k 8 150 ./tools/qtest shot "$dir/$tag.tar" >/dev/null 2>&1
  [ -s "$dir/$tag.tar" ] || { echo NOWINDOW; return; }
  out=$(python3 tools/winshot.py "$dir/$tag.tar" "$vm" -o "$dir/$tag.png" --classify 2>/dev/null)
  case "$out" in *VERDICT=*) echo "${out##*VERDICT=}" ;; *) echo NOWINDOW ;; esac
}

w_alive(){ QTEST_VM=$1 timeout -k 5 40 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | grep -qa QREADY; }

# Wait for a usable session. 0=session 1=terminal 2=deadline
w_session(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 t0 now st shots=0 dark=0 wedgesus=0 cpu
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    if [ "$now" -ge "$dl" ]; then
      if [ "$wedgesus" = 1 ]; then
        # Not a bare timeout: the wedge signature was present and persisted to the deadline. Say so,
        # so a caller and a reader see a CLASSIFIED outcome instead of "something did not answer".
        $log "  $lbl: DEADLINE ${dl}s - and QWTWEDGESUSPECT held throughout. Treating as TERMINAL, guest LEFT AS IT STANDS."
        return 1
      fi
      $log "  $lbl: DEADLINE ${dl}s with no session (screen=$(w_screen "$vm" "$lbl-dl" "$dir"))"
      return 2
    fi
    w_alive "$vm" && { $log "  $lbl: session up at t+${now}s"; return 0; }
    if [ $(( now / 60 )) -gt "$shots" ]; then
      shots=$(( now / 60 )); st=$(w_screen "$vm" "$lbl-t${now}" "$dir")
      $log "  $lbl: t+${now}s qvm=$(w_state "$vm") screen=$st"
      [ "$st" = RECOVERY ] && { $log "  $lbl: TERMINAL - recovery screen, not waiting and not restarting ($dir/$lbl-t${now}.png)"; return 1; }
      # A guest with NO USABLE SCREEN minute after minute is not booting either. Black is
      # legitimately transient during early boot, so one sample proves nothing - three consecutive
      # minutes with no session does.
      #
      # BLACK *OR* NOWINDOW. Fixed 2026-09-10 after an inert fix: the counter used to increment on
      # BLACK alone, and w_screen returns NOWINDOW (not BLACK) whenever the tar is EMPTY - which is
      # exactly the measured wedge signature (specimen 2: 0-byte tar). So a wedged guest fell into
      # the `else` arm, reset the counter, and waited out the deadline; a terminal arm added to the
      # BLACK branch could never fire for it. Both verdicts mean "no usable screen"; keep them
      # distinguishable in the log, but count them together.
      case "$st" in
      BLACK|NOWINDOW)
        dark=$(( dark + 1 ))
        # DARK ALONE IS NOT TERMINAL. Measured 2026-08-28: a guest that looked dead behind a black
        # screen was consuming CPU steadily (cpu_time 92755 -> 119257 in 40 s, 8 GB resident) - it
        # was running headless with a half-installed QWT, not hung.
        cpu=$(printf '' | timeout 20 qrexec-client-vm "$vm" admin.vm.Stats 2>/dev/null | tr -d '\0' \
              | grep -aoE 'cpu_usage_raw[0-9]+' | grep -aoE '[0-9]+' | awk '{t+=$1} END{if(NR)print t; else print "NA"}')
        $log "  $lbl: dark #$dark (screen=$st), cpu_usage_raw=${cpu:-NA}"

        # WHAT THIS CAN AND CANNOT DECIDE, stated because two earlier attempts got it wrong.
        # It CANNOT distinguish a wedge from a legitimately busy headless guest:
        #   - CPU burn does not separate them (the 2026-08-28 headless guest burned CPU too);
        #   - and qrexec cannot either, because w_session RETURNS 0 at the top of this loop the
        #     moment qrexec answers, so every guest that reaches here is ALREADY deaf. My first fix
        #     used "deaf" as the discriminator, which is vacuous here.
        # Declaring TERMINAL on dark+deaf+burning would also break normal installs, which sit deaf
        # with no window for many minutes during "Working on updates".
        # So it does the one useful thing it can: REPORT THE SIGNATURE LOUDLY AND IMMEDIATELY, once,
        # while the specimen is still alive and interrogable - three specimens were lost because
        # nothing said "capture this now" - and keep waiting to the deadline rather than guessing.
        if [ "$dark" -ge 3 ] && [ "${cpu:-NA}" != NA ] && [ "$cpu" -gt 0 ] 2>/dev/null; then
          if [ "$wedgesus" = 0 ]; then
            wedgesus=1
            $log "  $lbl: QWTWEDGESUSPECT vm=$vm dark=${dark}min screen=$st cpu_usage_raw=$cpu qvm=$(w_state "$vm")"
            $log "  $lbl: This is the measured wedge signature: no usable screen, deaf to qrexec, and BURNING CPU."
            $log "  $lbl: It may still be a legitimately busy headless guest - this cannot tell them apart."
            $log "  $lbl: DO NOT KILL, REVERT OR CLONE OVER THIS GUEST. If it is the wedge, it is the only"
            $log "  $lbl: interrogable form of the defect, and three specimens were already lost to cleanup."
            $log "  $lbl: Capture it in dom0 NOW, read-only, with a RECORDED interval between the two dumps"
            $log "  $lbl: (without an interval a frozen host cannot be told from a hot loop - the open question):"
            $log "  $lbl:   date -u +%FT%T.%NZ; sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > d1.txt"
            $log "  $lbl:   sleep 30; date -u +%FT%T.%NZ; sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > d2.txt"
            $log "  $lbl:   sudo xl dmesg -c >/dev/null; sudo xl debug-keys v; sudo xl dmesg > v1.txt   # VM_EXIT per vCPU"
            $log "  $lbl:   sudo xl vcpu-list $vm; sudo xl list -l $vm"
          fi
          # deliberately NOT resetting $dark and NOT returning: the signature persists in the log
          # every minute, and the deadline below classifies the outcome.
        elif [ "$dark" -ge 3 ]; then
          $log "  $lbl: TERMINAL - no usable screen for ${dark} min and NOT burning CPU (cpu=${cpu:-NA}), qvm=$(w_state "$vm")"
          return 1
        fi ;;
      *)
        dark=0 ;;
      esac
    fi
    sleep 15
  done
}

# Wait for the interactive USER (autologon) session, not just qrexec. 0=user session
# 1=terminal(recovery) 2=deadline.
# WHY THIS EXISTS: w_alive/w_session prove only that qubes.VMShell answers - and on this
# testbed dom0 policy runs VMShell as NT AUTHORITY\SYSTEM (pre-session qrexec), which answers
# BEFORE autologon completes. qubes.Filecopy - what every `qtest pushrun` rides - delivers into
# the logged-on USER's Documents and yields NOTHING without the interactive session
# (RIG-CONSTRAINTS 1.1). Measured 2026-09-02 (P4 campaign): w_session passed on the SYSTEM
# channel, the pushrun preconditions fired immediately, and a HEALTHY 4.3.18 subject was graded
# INVALID-PRECONDITION - p4-scan-disarm returned shell banners only, p4-subject-identity 0
# bytes; the same health-check after settle returned a full healthy result. Gate on THIS after
# w_session, before any pushrun-based step.
# Two signals, in order, both required:
#   (a) explorer.exe is running - the shell exists only once the user logon completed
#       (whoami is NOT a discriminator here: policy pins the VMShell channel to SYSTEM
#       before AND after logon);
#   (b) a marker pushrun ROUND-TRIPS - the exact Filecopy-into-user-Documents path every
#       downstream pushrun needs. (a) alone could still race profile/file-agent readiness.
# Same three-exit shape as w_session; poll cadence >= 15 s (qrexec churn floor).
w_usersession(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 t0 now st shots=0 out probe
  probe="$dir/$lbl-usersession-probe.ps1"
  printf 'Write-Output "USERSESSION-MARKER-OK"\n' > "$probe"
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    if [ "$now" -ge "$dl" ]; then
      $log "  $lbl: DEADLINE ${dl}s - qrexec answers (SYSTEM pre-session channel) but the interactive user session never came up (screen=$(w_screen "$vm" "$lbl-usr-dl" "$dir")); autologon broken or not settled - every pushrun-based step would return NOTHING"
      return 2
    fi
    # Use the SELF-MATCH-SAFE probe (defined below; this file is sourced whole, so it resolves at
    # call time). The inline grep it replaces matched the echoed prompt line carrying the command
    # text itself, so signal (a) read true on a shell-less guest every poll, the "no explorer.exe"
    # branch was unreachable, and the deadline blamed Filecopy for what was a missing shell.
    if _shell_probe_explorer "$vm"; then
      out=$(QTEST_VM=$vm timeout -k 8 150 ./tools/qtest pushrun "$probe" 2>/dev/null | tr -d '\r')
      if grep -qa 'USERSESSION-MARKER-OK' <<<"$out"; then
        $log "  $lbl: user session up at t+${now}s (explorer running, marker pushrun round-tripped)"
        return 0
      fi
      $log "  $lbl: t+${now}s explorer running but marker pushrun did not round-trip yet (Filecopy/user profile not ready)"
    else
      $log "  $lbl: t+${now}s qrexec answers but no explorer.exe - autologon not complete"
    fi
    if [ $(( now / 60 )) -gt "$shots" ]; then
      shots=$(( now / 60 )); st=$(w_screen "$vm" "$lbl-usr-t${now}" "$dir")
      $log "  $lbl: t+${now}s qvm=$(w_state "$vm") screen=$st"
      [ "$st" = RECOVERY ] && { $log "  $lbl: TERMINAL - recovery screen, no user session is coming ($dir/$lbl-usr-t${now}.png)"; return 1; }
    fi
    sleep 20
  done
}

# Readiness gate for AppVM subjects: distinguish "logon session but NO desktop shell" - the
# STALE-PRIVATE-VOLUME signature - from a healthy shell. 0=shell up  1=terminal(diagnosed)
# 2=deadline.
#
# WHY THIS EXISTS (owner correction, 2026-09-04): an AppVM's PRIVATE volume (QWT redirects
# C:\Users onto it) is seeded from the template's private AT APPVM CREATION ONLY. It is NOT
# re-seeded when the AppVM is re-pointed at a template, nor when the template's root is re-based
# underneath it (checkpoint.sh unpark). A reused AppVM over a re-based template therefore boots
# and AUTOLOGONS - a console session goes Active - but the profile on the stale private is
# missing/mismatched, so explorer.exe NEVER starts: no desktop shell, and every pushrun/
# w_usersession dies as a silent timeout while the template itself boots fine. That state is
# PERMANENT for the boot - waiting longer cannot help - so a session that stays shell-less past a
# bounded settle is TERMINAL with the repair named, never a generic deadline. w_session cannot
# see this (it proves only the SYSTEM qrexec channel); w_usersession sees it only as its
# 600 s deadline with a generic "autologon broken" guess. Callers gating an AppVM subject chain
# this AFTER w_session (cell_appvm does; P2's boot path - protocol/steps/p2-network.json,
# p2-boot-appvm - should chain it after its w_session/w_usersession pair too).
#
# The probes are separate functions so the wait logic is testable rig-free (a stub overrides
# them; see mgmt/harness/failproof-appvm-shell.sh), and they are SELF-MATCH-SAFE: `qtest run`
# echoes the cmd.exe banner and the PROMPT LINE WITH THE COMMAND ON IT, which contains the very
# string grepped for - sg6-failproof measured explorer=1 on a shell-less guest from the echo
# alone. Both probes strip banner/prompt lines (the sg6 filter) before matching.
_shell_echo_strip(){ grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
_shell_probe_explorer(){ # $1=vm -> 0 iff explorer.exe is running
  QTEST_VM=$1 timeout -k 5 60 ./tools/qtest run 'cmd /c tasklist /fi "imagename eq explorer.exe" /nh' 2>/dev/null \
    | tr -d '\r' | _shell_echo_strip | grep -qa 'explorer\.exe'
}
_shell_probe_session(){ # $1=vm -> 0 iff an Active console logon session exists
  QTEST_VM=$1 timeout -k 5 60 ./tools/qtest run 'cmd /c query user' 2>/dev/null \
    | tr -d '\r' | _shell_echo_strip | grep -qaE '^[ >]*[A-Za-z0-9_.-]+ +console +[0-9]+ +Active'
}

# How long a session may stay shell-less before it is diagnosed. Healthy autologon starts
# explorer within seconds; 180 s is generous slack for a cold profile, small enough that the
# diagnosis lands minutes before any pushrun-based step would have silently timed out.
SHELL_SETTLE_SECS=${SHELL_SETTLE_SECS:-180}

w_appvm_shell(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 t0 now sess_t0=
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    [ "$now" -ge "$dl" ] && { $log "  $lbl: DEADLINE ${dl}s with no desktop shell and no settled session verdict (screen=$(w_screen "$vm" "$lbl-shell-dl" "$dir"))"; return 2; }
    if _shell_probe_explorer "$vm"; then
      $log "  $lbl: desktop shell up at t+${now}s (explorer.exe running)"
      return 0
    fi
    if _shell_probe_session "$vm"; then
      if [ -z "$sess_t0" ]; then
        sess_t0=$(date +%s)
        $log "  $lbl: t+${now}s console session Active but no explorer.exe yet - allowing ${SHELL_SETTLE_SECS}s settle"
      elif [ $(( $(date +%s) - sess_t0 )) -ge "$SHELL_SETTLE_SECS" ]; then
        $log "  $lbl: TERMINAL - AppVM booted with a logon session but NO desktop shell (explorer absent ${SHELL_SETTLE_SECS}s after the session went Active) - stale private volume; the AppVM was not re-created after its template was re-based. Re-create it fresh (see cell_appvm). (screen=$(w_screen "$vm" "$lbl-noshell" "$dir"))"
        return 1
      fi
    else
      # No Active session yet: autologon still in flight. The settle clock runs only while a
      # session is CONTINUOUSLY seen, so a slow logon (or a transient probe miss) restarts it -
      # the safe direction: a false reset delays the diagnosis, never fabricates one.
      sess_t0=
      $log "  $lbl: t+${now}s no Active console session yet (autologon in flight)"
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
          2>/dev/null | tr -d '\r' | grep -aE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^=== RESULT ===|^E2EMARK-' >> "$dir/$lbl-install.tail" || true
        # THE FILTER MUST ALSO KEEP THE RUN MARKER (^E2EMARK-). It kept only timestamped lines and
        # the RESULT trailer, so the marker run_install appends never reached this cumulative log -
        # the marker slice below then found nothing, emptied .cur, and the success test could never
        # match. Measured 2026-08-30: cell WIN10-1stage logged
        # "=== RESULT === {stage:stage2-install, ok:true}" at t+21s and was still declared
        # "install STALLED (no progress for 300s)" five minutes later. That was an interaction
        # between two fixes of mine - anchoring the trailer, and marking the run - each correct
        # alone.
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
          # JUDGE ONLY THIS RUN. run_install appends a unique E2E_MARK before launching the
          # installer, because the guest log CANNOT be reliably deleted - boot tasks append to the
          # same file, so a delete right after a clone boots races a live writer (measured: five
          # failed attempts over 75 s, then RC=0 GONE minutes later on the same guest). Everything
          # before the marker belongs to the golden's own install or to a boot task, and grading it
          # is how a cell reports someone else's result as its own.
          if [ -n "${E2E_MARK:-}" ] && grep -qa "$E2E_MARK" "$dir/$lbl-install.log"; then
            sed -n "/$E2E_MARK/,\$p" "$dir/$lbl-install.log" > "$dir/$lbl-install.cur"
          else
            : > "$dir/$lbl-install.cur"
          fi
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
        if grep -qa '^=== RESULT === {' "$dir/$lbl-install.cur" 2>/dev/null; then
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
# w_halt_stable <vm> <deadline> <label> <logfn> [hold-seconds]
#
# Halted, AND STILL HALTED A MOMENT LATER. Plain w_halt returns on the FIRST sighting of Halted,
# which cannot tell "the guest shut down" from "the guest shut down and something started it again".
# That distinction is the whole bug behind "subject would not halt" (2026-09-12): a queued qrexec
# call restarts a guest seconds after it halts, the state oscillates, and a harness that only ever
# sees Transient reports the PRODUCT as unable to halt. It is a restarter, and it must be named.
#
# Returns 0 halted and stayed halted; 2 deadline with no halt at all; 3 HALTED THEN CAME BACK -
# an INVALID-INSTRUMENT condition, never a product failure.
w_halt_stable(){ # $1=vm $2=deadline $3=label $4=logfn $5=hold
  local vm=$1 dl=$2 lbl=$3 log=$4 hold=${5:-20} t0 now saw=0
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    if [ "$(w_state "$vm")" = Halted ]; then
      saw=1
      local i held=1
      for i in $(seq 1 $(( hold / 5 + 1 ))); do
        sleep 5
        if [ "$(w_state "$vm")" != Halted ]; then held=0; break; fi
      done
      if [ "$held" = 1 ]; then $log "  $lbl: halted and stayed halted at t+${now}s"; return 0; fi
      $log "  $lbl: HALTED THEN CAME BACK UP - something restarted it (a queued qrexec call is the"
      $log "  $lbl: usual culprit; drain with a short qrexec_timeout before shutting down). This is"
      $log "  $lbl: an instrument condition, NOT the guest refusing to halt."
      return 3
    fi
    [ "$now" -ge "$dl" ] && { $log "  $lbl: DEADLINE ${dl}s, still $(w_state "$vm") (never reached Halted at all)"; return 2; }
    sleep 10
  done
}

# Drain queued qrexec calls, then shut down. A call still queued for a guest RESTARTS it after it
# halts, and with qrexec_timeout at its normal 600 s that restarter outlives any sane halt budget -
# which is exactly how a park lost the race and blamed the product. Dropping the timeout makes a
# queued call fail fast instead of holding the guest; it is restored afterwards, always.
w_drain_and_shutdown(){ # $1=vm $2=logfn
  local vm=$1 log=$2 prev
  prev=$(qvm-prefs "$vm" qrexec_timeout 2>/dev/null); prev=${prev:-6000}
  pkill -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null
  qvm-prefs "$vm" qrexec_timeout 15 >/dev/null 2>&1
  $log "  drain: qrexec_timeout ${prev} -> 15 so a queued call cannot hold or restart $vm"
  qvm-shutdown "$vm" >/dev/null 2>&1
  sleep 2
  qvm-prefs "$vm" qrexec_timeout "$prev" >/dev/null 2>&1
}

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

# ---------------------------------------------------------------------------------------------
# GUEST PROBES. Use these; do not hand-roll them. Each exists because hand-rolling it produced a
# FALSE result on 2026-09-09, in three separate tests, none of which were product defects.

# g_probe <vm> <KEY> <powershell> [timeout] -> the value after KEY=, or empty
#
# `qtest run` output carries the cmd.exe banner and prompt, so a probe that greps the raw capture
# compares against "Microsoft Windows [Version ...]" - one such check FAILED on noise and another
# PASSED on it, in the same run. And nested quoting through `qtest run` mangles PowerShell silently:
# a config write became `-Value binds+=( ... )` unquoted and died, reported as "<no output>".
# So: the script goes in base64 -EncodedCommand (no quoting to survive), it must Write-Host "KEY=…",
# and only a line matching ^KEY= is read.
g_probe(){ # $1=vm $2=key $3=ps $4=timeout
  local vm=$1 key=$2 ps=$3 to=${4:-120} b64
  b64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$ps") || return 1
  # -ExecutionPolicy Bypass: without it a probe that DOT-SOURCES a shipped .ps1 dies with
  # "running scripts is disabled on this system" and returns NOTHING, which reads as "<no output>"
  # and gets misdiagnosed as the feature being broken. Production launches every guest script as
  # `-NoProfile -ExecutionPolicy Bypass -File` (Install-QwtImproved.ps1:526), so a probe without it
  # is not exercising the same thing the product does.
  QTEST_VM=$vm timeout -k 5 "$to" ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null \
    | tr -d '\r' | grep -aoE "^$key=.*" | head -1 | sed "s/^$key=//"
}

# g_boot_id <vm> -> LastBootUpTime, the identity of the CURRENT boot
g_boot_id(){ g_probe "$1" BOOT 'Write-Host ("BOOT=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"))'; }

# g_reboot_proven <vm> [label] -> 0 only if the guest DEMONSTRABLY rebooted
#
# `qtest shutdown` is ASYNCHRONOUS. A test that issued it and then polled for "is the guest up"
# declared success 34 seconds later and ran every post-reboot assertion against the STILL-RUNNING
# pre-reboot guest - including an assertion that PASSED by re-reading a file written 30 seconds
# earlier. Assuming a reboot is how a test reports green for something it never exercised.
# This requires: a boot identity BEFORE, the guest OBSERVED Halted, and a DIFFERENT boot identity
# after. Any of those missing is a failure, not a retry.
g_reboot_proven(){ # $1=vm $2=label
  local vm=$1 label=${2:-reboot} before after i st
  before=$(g_boot_id "$vm"); [ -n "$before" ] || { echo "$label: no boot id BEFORE" >&2; return 1; }
  QTEST_VM=$vm timeout -k 5 90 ./tools/qtest shutdown >/dev/null 2>&1
  for i in $(seq 1 40); do [ "$(w_state "$vm")" = Halted ] && break; sleep 10; done
  st=$(w_state "$vm")
  [ "$st" = Halted ] || { echo "$label: never reached Halted (state=$st) - it did not reboot" >&2; return 1; }
  qvm-start "$vm" >/dev/null 2>&1
  for i in $(seq 1 60); do w_alive "$vm" && break; sleep 10; done
  w_alive "$vm" || { echo "$label: no qrexec within 10 min of start - TERMINAL" >&2; return 1; }
  after=$(g_boot_id "$vm"); [ -n "$after" ] || { echo "$label: no boot id AFTER" >&2; return 1; }
  [ "$after" != "$before" ] || { echo "$label: boot id UNCHANGED ($after) - it did not reboot" >&2; return 1; }
  echo "$before -> $after"
  return 0
}
