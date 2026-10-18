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

# IS THE GUEST EXECUTING? cpu_time is CUMULATIVE, so a domain that runs anything at all increases
# it; a flat reading across a sample means the domain is not executing. This is the discriminator
# that separates "busy and silent" from "stopped", and every stall verdict in this harness needs
# it: they all ask "did the guest answer?" and treat no as dead.
#
# VALIDATED on this rig 2026-09-14, same metric, same session, three calls:
#   WIN11-reinstall "STALLED"      cpu_time +135364 / 20 s  -> busy,   the verdict was FALSE
#   WIN11-reinstall post-reboot    cpu_time       0 / 20 s  -> FROZEN, the verdict was TRUE
#   win11-nfy "no answer"          cpu_time  +66935 / 20 s  -> busy,   the verdict was FALSE
# The first and third cost four FAILs across a campaign and both feature tests, on guests that
# were working the whole time - one of them for 900 s more before rebooting normally.
#
# Returns 0 (moving/unknown) or 1 (FLAT). UNREADABLE COUNTS AS MOVING, deliberately: a stats read
# that fails must never manufacture a stall, which is the same missing-data-fails-closed rule the
# rest of this file follows.
w_cpu_time(){ printf '' | timeout 15 qrexec-client-vm "$1" admin.vm.Stats 2>/dev/null \
              | tr '\0' '\n' | awk '/^cpu_time$/{getline v; print v; exit}'; }
w_cpu_moving(){ # $1=vm $2=sample seconds (default 20)
  local a b
  a=$(w_cpu_time "$1"); [ -n "$a" ] || return 0
  sleep "${2:-20}"
  b=$(w_cpu_time "$1"); [ -n "$b" ] || return 0
  [ "$a" = "$b" ] && return 1
  return 0
}

# THREE-WAY, and it reports the DELTA. w_cpu_moving collapses "could not read" into "moving",
# which is the right VERDICT (a failed read must never manufacture a stall) but a LIE in the log:
# callers printed "the guest IS EXECUTING" about domains that were Halted and simply returned
# nothing. A fabricated reading in an evidence log is exactly what this project's rules forbid, so
# the state and the number are exposed and the caller prints what was actually measured.
#
# Echoes one of:  "FLAT <delta>"  |  "MOVING <delta>"  |  "UNREADABLE -"
# Callers MUST treat UNREADABLE as "not proven stopped" - never as a stall.
w_cpu_state(){ # $1=vm $2=sample seconds (default 20)
  local a b
  a=$(w_cpu_time "$1"); [ -n "$a" ] || { echo "UNREADABLE -"; return 0; }
  sleep "${2:-20}"
  b=$(w_cpu_time "$1"); [ -n "$b" ] || { echo "UNREADABLE -"; return 0; }
  if [ "$a" = "$b" ]; then echo "FLAT 0"; else echo "MOVING $(( b - a ))"; fi
}

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

# CAPTURE, THEN MATCH. `producer | grep -q` loses a SIGPIPE race: grep -q exits on the first match,
# the still-writing producer dies of SIGPIPE, timeout reports that as 141, and `set -o pipefail` in the
# sourcing harness (matrix, prime-run, quick-upgrade, collect-failure all set it) makes 141 the
# pipeline's status - so a guest that ANSWERED is graded dead. Measured 2026-10-14: 41 of 300 here, 86
# of 200 in the collector's own probe. This is the project's canonical liveness predicate and w_session,
# w_install, w_halt_stable and the 10-minute TERMINAL verdict below all rest on it.

# The RTC helper lives in its own file so prime-run.sh can source it WITHOUT sourcing this
# one, which it deliberately does not (prime-run.sh:66). Calling it from there while it was
# defined here resolved to nothing: `w_rtc_utc: command not found`, measured 2026-10-14.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/rtc-lib.sh"

# A BOUND SHORTER THAN THE EVENT IT WAITS FOR ABANDONS A REQUEST EVERY TIME.
# The default 40 s is right for "is this guest still answering" - a settled guest answers in under a
# second, and a long bound would only delay the caller's own deadline. It is WRONG for waiting on a
# BOOT: MEASURED win11-clean 2026-10-17, the session came up at t+56 s, so every probe before that
# was killed at 40 s while its request was still QUEUED. Queued qrexec is delivered when the agent
# finally starts, so all the abandoned requests arrived at once - three wrappers inside 33 ms, on
# consecutive ports, each finding its caller gone - and the guest logged
# `InitVchan: QGAVCHANFAIL ... request dropped` once per abandoned probe, against a gate whose
# condition is a clean error log. Nothing was lost: the caller had already given up and re-polls.
# Jev: the per-probe bound below the awaited event is itself the defect, 0.82.
# So the bound is a PARAMETER. Callers polling a settled guest keep 40 s; a caller waiting for a
# boot passes one that exceeds the boot, so its single outstanding probe answers instead of being
# abandoned. w_session's own deadline remains the real bound, which is why this one may be generous.
w_alive(){ grep -qa QREADY <<< "$(QTEST_VM=$1 timeout -k 5 "${2:-40}" ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; }

# A READINESS PROBE MUST NOT ABANDON ITSELF, and for a long time this one did.
#
# `timeout` around a qrexec call leaves the request IN THE GUEST'S QUEUE with no caller: when the
# agent finally starts, the wrapper picks it up, finds the dom0 end gone, and writes
# "InitVchan: QGAVCHANFAIL ... request dropped" at ERROR. Nine of those in campaign 20261018-083319,
# every one with caller domain 10858 - THIS management qube - in sub-100 ms bursts coinciding exactly
# with our probes (findings/issues.md QGAVCHANUNDECLARED, open and recurred three times). The guest
# is reporting our abandonment, correctly, and Jev refused to let the line be lowered for it
# (conceals 0.67): the fix is to stop abandoning, not to stop reporting.
#
# ONE CALL FOR THE WHOLE WAIT. It is started once, in the background, and polled - so nothing is
# re-queued per iteration and nothing is cut off while the agent is still coming up, while the
# caller's per-minute screen and wedge checks keep running. Three exits, as a wait must have: the
# marker arrives (0), the call ends without it (1, the guest answered something else), or the
# caller's own deadline passes (2) - and only that last one abandons anything, deliberately, at the
# point where the run is giving up and preserving the guest as evidence anyway.
# The pid is $!, never a pattern match.
w_alive_start(){ # $1=vm $2=outfile [$3=client bound s] -> prints the pid of the single probe
  : > "$2"
  # THE CLIENT BOUND IS BACK, AND DELIBERATELY - it pairs with the 20 s qrexec_timeout the callers
  # set, which is prime-run's proven combination (qrexec_timeout 20 plus `timeout -k 5 30` probes).
  # Attempt 1 removed the client timeout because it looked like the abandonment; the real variable
  # was dom0's hold. With the hold at 20 s a client bound no longer strands anything for ten
  # minutes, and WITHOUT one a client that never returns would park this wait for ever - the poll
  # would read "still running" on every turn and never re-probe. Default 30 s, as prime-run's.
  QTEST_VM=$1 timeout -k 5 "${3:-30}" ./tools/qtest run 'cmd /c echo QREADY' > "$2" 2>/dev/null &
  echo $!
}
w_alive_poll(){ # $1=pid $2=outfile -> 0=marker seen 1=call ended without it 2=still running
  grep -qa QREADY "$2" 2>/dev/null && return 0
  kill -0 "$1" 2>/dev/null && return 2
  return 1
}

# ONE PROBE, POLLED, FOR A WHOLE WAIT - the loop form of w_alive_start/w_alive_poll.
# Every POLLING caller uses this; a caller whose single call IS the verdict keeps w_alive.
# Returns 0 when the marker arrives, 1 at the deadline. Nothing is left queued behind us: a new
# call starts only once the previous one has ENDED.
# CANCEL AN OUTSTANDING PROBE BEFORE THE GUEST GOES DOWN - and the first version of this file got
# this exactly backwards. It left the call running on every non-success exit, reasoning that killing
# it WAS the abandonment. The opposite is true: a probe still outstanding when we halt the guest is
# the one dom0 QUEUES and delivers on the NEXT boot with no caller, which the guest then reports as
# "InitVchan: QGAVCHANFAIL ... request dropped".
#
# MEASURED, campaign 20261018-112936, clean cell:
#   11:41:25  WIN11-clean-park-halt: halted and stayed halted   (our halt, probe outstanding)
#   14:42:39  guest: QGAVCHANFAIL x2, ports 513/517, uptime 41 s
#             command line: qrexec-wrapper.exe 10858|513|(null)|6|c:\Windows\System32\cmd.exe
#   11:42:44  WIN11-clean-boot: session up at t+60s
# That cmd.exe IS this probe, and 10858 is this management qube. Cancelling while the guest is still
# up drops the request before it can be queued across a boot. By pid, from $!, never a pattern.
# DOM0 HOLDS A QUEUED CALL FOR qrexec_timeout, AND THAT - NOT THE POLL CADENCE, NOT THE CLIENT'S
# LIFETIME - IS WHAT STRANDS A PROBE. prime-run.sh:613 states it: "`timeout -k 5 45` kills the
# CLIENT; dom0 keeps the queued call for qrexec_timeout, which prime-run sets to 600 for this
# subject." So a probe outstanding when we halt the guest is held for up to ten minutes and
# delivered on the NEXT boot with no caller, which the guest reports as
# "InitVchan: QGAVCHANFAIL ... request dropped" (measured x9, campaign 20261018-112936).
#
# prime-run already brackets its own post-install wait this way, which is why those bursts land in
# the matrix cells and not in prime-run's phase. These waits did not, and two earlier attempts at
# this cause changed poll cadence instead - the wrong variable, twice.
#
# THE STANDING VALUE IS READ, NOT ASSUMED. prime-run sets 600; the recorded drain procedure restores
# 6000. Hardcoding either would silently re-time somebody else's subject.
w_qt_lower(){ # $1=vm -> prints the value to restore, empty when it could not be read
  local cur
  cur=$(qvm-prefs "$1" qrexec_timeout 2>/dev/null)
  case "$cur" in ''|*[!0-9]*) echo ""; return 0 ;; esac
  qvm-prefs "$1" qrexec_timeout 20 2>/dev/null || { echo ""; return 0; }
  echo "$cur"
}
w_qt_restore(){ # $1=vm $2=saved value (no-op when empty)
  [ -n "${2:-}" ] && qvm-prefs "$1" qrexec_timeout "$2" 2>/dev/null
  return 0
}

w_alive_cancel(){ # $1=pid $2=outfile
  [ -n "${1:-}" ] && kill "$1" 2>/dev/null
  [ -n "${2:-}" ] && rm -f "$2"
  return 0
}

w_alive_wait(){ # $1=vm $2=deadline seconds (default 600) $3=optional poll seconds (default 10)
  local vm=$1 dl=${2:-600} iv=${3:-10} t0 out pid rc
  t0=$(date +%s); out=$(mktemp); pid=$(w_alive_start "$vm" "$out")
  while [ $(( $(date +%s) - t0 )) -lt "$dl" ]; do
    w_alive_poll "$pid" "$out"; rc=$?
    [ "$rc" = 0 ] && { rm -f "$out"; return 0; }
    if [ "$rc" = 1 ]; then rm -f "$out"; out=$(mktemp); pid=$(w_alive_start "$vm" "$out"); fi
    sleep "$iv"
  done
  w_alive_cancel "$pid" "$out"; return 1
}

# Wait for a usable session. 0=session 1=terminal 2=deadline
w_session(){ # $1=vm $2=deadline $3=label $4=outdir $5=logfn
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 t0 now st shots=0 dark=0 wedgesus=0 cpu
  # LOCAL, so a second wait in the same shell cannot inherit a finished probe's pid.
  local _wa_pid= _wa_out= _wa_rc=
  # The deadline arms below leave the single probe to FINISH on its own rather than killing it: a
  # kill is an abandonment, which is the thing this wait exists to stop causing. Only the temp file
  # goes, and a late write to a deleted file is harmless.
  local _qt_saved; _qt_saved=$(w_qt_lower "$vm")
  local _wa_cleanup='w_alive_cancel "${_wa_pid:-}" "${_wa_out:-}"; w_qt_restore "$vm" "${_qt_saved:-}"'
  t0=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    if [ "$now" -ge "$dl" ]; then
      if [ "$wedgesus" = 1 ]; then
        # Not a bare timeout: the wedge signature was present and persisted to the deadline. Say so,
        # so a caller and a reader see a CLASSIFIED outcome instead of "something did not answer".
      eval "$_wa_cleanup"
        $log "  $lbl: DEADLINE ${dl}s - and QWTWEDGESUSPECT held throughout. Treating as TERMINAL, guest LEFT AS IT STANDS."
        # This is the moment the guest stops being a machine and becomes evidence, so it is the
        # moment to write that down. The marker makes tools/hooks/golden-boot-gate.sh refuse a
        # hand-typed start of this name - the mistake made on 2026-10-14, minutes after this very
        # line fired. Guarded by `type`, so sourcing this file alone still works.
        if type specimen_mark >/dev/null 2>&1; then
          specimen_mark "$vm" "$lbl: no session by ${dl}s, kept as evidence" "$dir" >/dev/null || true
        fi
        return 1
      fi
      eval "$_wa_cleanup"
      $log "  $lbl: DEADLINE ${dl}s with no session (screen=$(w_screen "$vm" "$lbl-dl" "$dir"))"
      return 2
    fi
    # ONE PROBE FOR THE WHOLE WAIT (w_alive_start/w_alive_poll). The old form bounded each call at
    # 90 s - above the ~55-56 s this rig measures from start to session - on the reasoning that a
    # healthy guest answers on one probe and abandons nothing. A guest that is SLOWER than the bound
    # abandons one request per iteration, and that is what the guest reports as QGAVCHANFAIL.
    if [ -z "${_wa_pid:-}" ]; then
      _wa_out=$(mktemp); _wa_pid=$(w_alive_start "$vm" "$_wa_out")
    fi
    w_alive_poll "$_wa_pid" "$_wa_out"; _wa_rc=$?
    if [ "$_wa_rc" = 0 ]; then
      rm -f "$_wa_out"; w_qt_restore "$vm" "${_qt_saved:-}"; $log "  $lbl: session up at t+${now}s"; return 0
    fi
    if [ "$_wa_rc" = 1 ]; then
      # The call ENDED without the marker: the channel answered but the session is not up yet. A new
      # call is legitimate here - the previous one is finished, so nothing is left queued.
      rm -f "$_wa_out"; _wa_out=$(mktemp); _wa_pid=$(w_alive_start "$vm" "$_wa_out")
    fi
    if [ $(( now / 60 )) -gt "$shots" ]; then
      shots=$(( now / 60 )); st=$(w_screen "$vm" "$lbl-t${now}" "$dir")
      $log "  $lbl: t+${now}s qvm=$(w_state "$vm") screen=$st"
      [ "$st" = RECOVERY ] && { eval "$_wa_cleanup"; $log "  $lbl: TERMINAL - recovery screen, not waiting and not restarting ($dir/$lbl-t${now}.png)"; return 1; }
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
        # CLASSIFY IT, DO NOT ASSERT IT. This fired on `cpu > 0` - ANY non-zero counter - and then
        # announced "the measured wedge signature: ... BURNING CPU". mgmt/harness/wedge-lib.sh
        # calibrated that same counter on 2026-09-23 and records what it is worth:
        #     idle, healthy .................   9,865  and  44,540
        #     PEGGED (4-thread storm) ....... 130,976
        #     unreachable, all vCPUs blocked .  96,262
        # "A pegged guest and an idle unreachable one are INDISTINGUISHABLE in that counter, so
        # every verdict built on it was unsound in both directions." On 2026-10-14 this printed
        # cpu_usage_raw=14736 and 272 - idle-band and far below it - called both a wedge, told the
        # reader not to clean up, and sent them to dom0 for xl dumps. Both guests then came down
        # normally. The owner: "i do not think there ever was a real wedge ... it is more bs".
        #
        # What actually discriminates is `xl vcpu-list` sampled twice, and that is reachable from
        # here: wedge_classify calls the POLICIED dom0 service local.WinWedgeForensics - no dom0
        # shell, no sudo, nothing for a human to run. Asking it costs one call and answers the
        # question this block existed to raise.
        if [ "$dark" -ge 3 ] && [ "$wedgesus" = 0 ]; then
            wedgesus=1
            _wdir="${4:-${TMPDIR:-/tmp}}/wedge-$vm-$(date -u +%H%M%S)"
            # shellcheck disable=SC1091
            [ -z "${WEDGE_LIB_SOURCED:-}" ] && { . mgmt/harness/wedge-lib.sh 2>/dev/null && WEDGE_LIB_SOURCED=1; }
            _wv=$(wedge_classify "$vm" "$_wdir" 2>/dev/null | tail -1)
            $log "  $lbl: dark ${dark}min, screen=$st, qvm=$(w_state "$vm") - asked the forensics service: ${_wv:-UNREADABLE}"
            case "${_wv%% *}" in
              SPINNING)
                $log "  $lbl: SPINNING - a vCPU is consuming a full core while the guest is unreachable."
                $log "  $lbl: DO NOT KILL, REVERT OR CLONE OVER THIS GUEST: it is the only interrogable"
                $log "  $lbl: form of the defect, and three specimens were already lost to cleanup."
                $log "  $lbl: Evidence: $_wdir" ;;
              BLOCKED)
                $log "  $lbl: BLOCKED - every vCPU is idle and the guest is unreachable. Not a spin;"
                $log "  $lbl: it is waiting on something. Evidence: $_wdir" ;;
              UNREADABLE|"")
                $log "  $lbl: the forensics service could not be read, so NOTHING is claimed about why"
                $log "  $lbl: this guest is dark - it is unreachable, and that is all this knows." ;;
              *)
                $log "  $lbl: forensics verdict '${_wv}' - evidence: $_wdir" ;;
            esac
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
  local vm=$1 dl=$2 lbl=$3 dir=$4 log=$5 glog=$6 t0 now n last=-1 lastchange st _iqt
  # LOCAL, so a second install wait in the same shell cannot inherit a finished probe's pid or a
  # half-restored qrexec_timeout.
  local _iw_pid= _iw_out= _iw_rc=
  t0=$(date +%s); lastchange=$(date +%s)
  while :; do
    now=$(( $(date +%s) - t0 ))
    # Cancel before giving up: a probe left outstanding here is queued into the guest's next boot.
    [ "$now" -ge "$dl" ] && { w_alive_cancel "${_iw_pid:-}" "${_iw_out:-}"; w_qt_restore "$vm" "${_iqt:-}"; $log "  $lbl: DEADLINE ${dl}s"; return 2; }
    if [ "$(w_state "$vm")" = Halted ]; then
      # THE GUEST IS GOING DOWN: cancel first, or this probe is queued into its next boot.
      w_alive_cancel "${_iw_pid:-}" "${_iw_out:-}"; _iw_pid=""
      w_qt_restore "$vm" "${_iqt:-}"
      $log "  $lbl: guest HALTED at t+${now}s (install rebooted or shut it down)"; return 3
    fi
    # ONE PROBE FOR THE WHOLE WAIT. This wait spans the installer's own reboots, and the old
    # bounded form abandoned one request per turn across every one of them - which the guest
    # reports as InitVchan: QGAVCHANFAIL. Measured: still x4 on the clean cell of campaign
    # 20261018-103039 AFTER w_session alone was fixed, which is how this site was found.
    if [ -z "${_iqt+set}" ]; then _iqt=$(w_qt_lower "$vm"); fi
    if [ -z "${_iw_pid:-}" ]; then _iw_out=$(mktemp); _iw_pid=$(w_alive_start "$vm" "$_iw_out"); fi
    w_alive_poll "$_iw_pid" "$_iw_out"; _iw_rc=$?
    if [ "$_iw_rc" = 1 ]; then w_alive_cancel "$_iw_pid" "$_iw_out"; _iw_out=$(mktemp); _iw_pid=$(w_alive_start "$vm" "$_iw_out"); fi
    if [ "$_iw_rc" = 0 ]; then
      rm -f "$_iw_out"; _iw_pid=""
      w_qt_restore "$vm" "${_iqt:-}"; unset _iqt

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
        # SAFE TO GATE HERE, unlike the unreachable branch below: this arm runs only when the guest
        # ANSWERS qrexec (w_alive above), so "executing" really does mean working - a spin-wedged
        # guest answers nothing. A quiet log on a responsive guest is a long MSI phase.
        cs=$(w_cpu_state "$vm")
        case "${cs%% *}" in
          FLAT)
            st=$(w_screen "$vm" "$lbl-stall" "$dir")
            $log "  $lbl: STALLED - ${n} log lines unchanged for ${STALL_SECS}s AND cpu_time FLAT over the sample, screen=$st"
            return 4 ;;
          MOVING)
            $log "  $lbl: ${n} log lines unchanged for ${STALL_SECS}s, qrexec answers and cpu_time ADVANCED ${cs#* } - working, not stalled; clock reset"
            lastchange=$(date +%s) ;;
          *)
            # UNREADABLE is not evidence of anything. It must not manufacture a stall, and it must
            # not be logged as a measurement either.
            $log "  $lbl: ${n} log lines unchanged for ${STALL_SECS}s; qrexec answers but cpu_time UNREADABLE - not proven stopped, so not called a stall; clock reset"
            lastchange=$(date +%s) ;;
        esac
      fi
    else
      if [ $(( $(date +%s) - lastchange )) -ge "$STALL_SECS" ]; then
        # QREXEC IS DEAD HERE. cpu_time CLASSIFIES this stall - it must never SUPPRESS it.
        #
        # This branch had the same cpu gate as the reachable one above, and on this branch that
        # gate is INVERTED against the defect it was supposed to help with. issues.md P1: "AT LEAST
        # ONE vCPU BURNING 88-101% OF A CORE sustained ... the 8/8 invariant across all eight
        # captured events". A spinning vCPU MOVES domain cpu_time, so every recorded specimen of
        # the wedge would have been logged "IS EXECUTING - waiting, not a stall" and run to the
        # 2400 s deadline instead of being called at 300 s, with the stall screenshot never taken.
        # Caught in review 2026-09-14 before it ever ran against a real wedge.
        #
        # The distinction that actually holds: on the branch ABOVE the guest ANSWERS qrexec, so
        # "executing" genuinely means working. HERE it does not answer, and dead qrexec + burning
        # CPU IS the register's fingerprint. So both outcomes are a STALL; cpu_time only says which
        # kind, which is the thing the next reader needs.
        st=$(w_screen "$vm" "$lbl-stall" "$dir")
        cs=$(w_cpu_state "$vm")
        case "${cs%% *}" in
          FLAT)   $log "  $lbl: STALLED (FROZEN) - unreachable ${STALL_SECS}s AND cpu_time FLAT over the sample: the domain is NOT EXECUTING. screen=$st" ;;
          MOVING) $log "  $lbl: STALLED (SPINNING) - unreachable ${STALL_SECS}s while cpu_time ADVANCED ${cs#* } over the sample. Dead qrexec + burning CPU is the issues.md P1 fingerprint (8/8 specimens burn 88-101% of a core). screen=$st" ;;
          *)      $log "  $lbl: STALLED - unreachable ${STALL_SECS}s; cpu_time UNREADABLE, so executing-or-not is UNMEASURED (not a claim either way). screen=$st" ;;
        esac
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
# Returns 0 halted and stayed halted; 2 deadline with no halt at all; 3 HALTED THEN CAME BACK
# WITH A QUEUED CALL OBSERVED (instrument); 4 HALTED THEN CAME BACK WITH NOTHING PENDING - an
# unexplained restart, graded as a product condition rather than assumed away.
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
      $log "  $lbl: HALTED THEN CAME BACK UP at t+${now}s - something restarted it."
      # ATTRIBUTE ON EVIDENCE, NOT ON HABIT. A queued qrexec call is the known cause, but it is
      # not the only one: an HVM that reboots itself comes back exactly like this, and that would
      # be a PRODUCT defect (a guest asked to halt must halt). Only w_drain_and_shutdown knows
      # whether a restarter was actually present, so use what it saw.
      if [ "${W_DRAIN_PENDING:-0}" -gt 0 ] 2>/dev/null; then
        $log "  $lbl: ${W_DRAIN_PENDING} queued qrexec call(s) were observed at drain time, which is"
        $log "  $lbl: the known restarter. Instrument condition, not the guest refusing to halt."
        return 3
      fi
      $log "  $lbl: NO queued qrexec call was pending when this guest was shut down, so the usual"
      $log "  $lbl: instrument explanation does NOT apply here. An unexplained restart of a guest"
      $log "  $lbl: that was asked to halt is a PRODUCT condition until something else is shown."
      return 4
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
  # DIAGNOSE BEFORE DRAINING. This function's first version pkill'd every pending call and said
  # nothing about it, which was an OVER-CORRECTION: having just proved that a queued call can
  # restart a halted guest, it went on to treat EVERY pending call as that same benign leftover.
  # A call can also be pending because THE GUEST STOPPED ANSWERING QREXEC - a product defect, and
  # a serious one - and killing both cases silently makes a dead-qrexec guest look like a tidy
  # park. Blaming the instrument by default is the same error as blaming the product by default.
  local vm=$1 log=$2 prev pend n
  prev=$(qvm-prefs "$vm" qrexec_timeout 2>/dev/null); prev=${prev:-6000}
  W_DRAIN_PENDING=0; W_DRAIN_QREXEC_DEAD=0

  # PULL WHAT dom0 WAS TOLD, WHILE THE GUEST IS STILL UP. This is the last moment the record is
  # reachable: it lives on the guest's PRIVATE volume, so it dies with a disposable AppVM, and a
  # whole day of toast work ran with nothing on this side - the owner had to read toasts aloud
  # (2026-10-10, in capitals: "I SHOULD NEVER EVER READ FUCKING TOASTS TO YOU ALOUD"). Every
  # harness that parks a guest comes through here, so the hook belongs here and not in each one.
  # It never boots a guest (--no-start) and never blocks the park; an UNREADABLE record is said
  # LOUDLY under its own tag so the sweep can grade it, because a silent nothing is
  # indistinguishable from "dom0 was told nothing" - which is the hole being closed.
  if [ "${W_SKIP_DOM0_SENDS:-0}" != 1 ] && [ -x tools/dom0-sends.sh ]; then
    # NOT `tool | while read`: a pipeline's status is the LAST command's, so the failure arm below
    # could never fire - and that arm is the whole point. Output to a file, then read the rc.
    local sends_out sends_rc
    sends_out=$(mktemp "${TMPDIR:-/tmp}/dom0-sends-park.XXXXXX")
    timeout 300 bash tools/dom0-sends.sh "$vm" "park-$(date -u +%H%M%S)" --no-start > "$sends_out" 2>&1
    sends_rc=$?
    while IFS= read -r l; do $log "  $l"; done < "$sends_out"
    rm -f "$sends_out"
    if [ "$sends_rc" != 0 ]; then
      $log "  [WARN] DOM0SENDSUNREAD $vm: the dom0 notification record could not be read before the park (rc=$sends_rc) -"
      $log "    this side now has NO record of what dom0 was told on this boot"
    fi
  fi

  pend=$(pgrep -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null)
  if [ -n "$pend" ]; then
    n=$(printf '%s\n' "$pend" | grep -c .)
    W_DRAIN_PENDING=$n
    $log "  drain: $n qrexec call(s) STILL PENDING for $vm at park time (ages below)"
    ps -o etime=,args= -p $(printf '%s' "$pend" | tr '\n' ' ') 2>/dev/null | cut -c1-150 \
      | while IFS= read -r l; do $log "    pending: $l"; done
    # BY PID, AND VERIFIED. `pkill -f <pattern>` is prohibited outright (owner 2026-10-10:
    # "PKILL IS HARD PROHIBITED FOREVER") because a pattern also matches the process doing the
    # matching - a pgrep-fed kill took out my own tool shell twice in one hour. The pids are
    # already in $pend; each one's /proc/<pid>/comm must say it really is a qrexec client before
    # it is signalled, so a shell that merely CONTAINS this pattern in its command line survives.
    local _k=0 _pp _comm
    for _pp in $pend; do
      _comm=$(cat "/proc/$_pp/comm" 2>/dev/null)
      case "$_comm" in
        qrexec-client*) kill -TERM "$_pp" 2>/dev/null && _k=$((_k+1)) ;;
        "")             $log "  drain: pid $_pp vanished before the signal - nothing to do" ;;
        *)              $log "  drain: pid $_pp is '$_comm', NOT a qrexec client - left alone" ;;
      esac
    done
    $log "  drain: signalled $_k of $n queued call(s) by pid so none can restart $vm after it halts"
  else
    $log "  drain: no qrexec call pending for $vm (nothing to drain)"
  fi

  # THE DEAD-QREXEC PROBE IS NOT CONDITIONAL ON A PENDING CALL. It used to be nested inside the
  # branch above, so the only guest that could ever be graded QREXECDEAD was one that happened to
  # have a client process still hanging - and a guest whose qrexec died LONG ago has none, because
  # every client that was waiting on it has already timed out and exited. Measured 2026-09-17
  # (release 4.3.29.538, run 35171496552, guest win11-acc): prime-run had just proved qrexec dead
  # for 1083 s and left the guest Running as evidence; this function then printed "no qrexec call
  # pending ... (nothing to drain)", never probed, never set the flag, and the caller went on to
  # spend 660 s asking a wedged guest to shut down and then killed it - grading the cell "subject
  # would not halt for unpark" when the honest class was "qrexec was DEAD on a running guest".
  # The discriminator the comment above describes was unreachable in exactly the case it was
  # written for. Cost: one class of a P1 stall recorded as a shutdown failure.
  #
  # So: whenever the guest is not Halted, ask it a FRESH, short question, pending calls or not.
  if [ "$(w_state "$vm")" != Halted ]; then
    if w_alive "$vm"; then
      if [ "${W_DRAIN_PENDING:-0}" -gt 0 ] 2>/dev/null; then
        $log "  drain: the guest answers a fresh qrexec probe, so those were instrument leftovers"
      fi
    else
      W_DRAIN_QREXEC_DEAD=1
      $log "  drain: QREXECDEAD vm=$vm pending=$W_DRAIN_PENDING state=$(w_state "$vm") - qrexec is"
      $log "  drain: NOT answering a fresh probe. That is a PRODUCT condition, not an instrument"
      $log "  drain: one. It is recorded and graded, NOT drained away. Do not read the park or the"
      $log "  drain: shutdown that follows as evidence the guest was healthy."
      $log "  drain: cpu=$(w_cpu_state "$vm") screen=$(w_screen "$vm" "qrexecdead-$vm" "${M:-${TMPDIR:-/tmp}}")"
    fi
  fi

  qvm-prefs "$vm" qrexec_timeout 15 >/dev/null 2>&1
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
  # The boot bound here too: this loop waits for a START, so a 40 s probe is abandoned mid-queue on
  # the way up and the guest logs a dropped request for each one (see w_alive).
  # 600 s, the same ten minutes the seq-60 loop allowed, in ONE probe instead of sixty.
  w_alive_wait "$vm" 600 10 || true
  w_alive "$vm" "${W_ALIVE_BOOT_BOUND:-90}" || { echo "$label: no qrexec within 10 min of start - TERMINAL" >&2; return 1; }
  after=$(g_boot_id "$vm"); [ -n "$after" ] || { echo "$label: no boot id AFTER" >&2; return 1; }
  [ "$after" != "$before" ] || { echo "$label: boot id UNCHANGED ($after) - it did not reboot" >&2; return 1; }
  echo "$before -> $after"
  return 0
}
