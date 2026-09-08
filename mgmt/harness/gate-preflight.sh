#!/bin/bash
# TWO-MINUTE PREFLIGHT for a fault bit, before committing 28 minutes to a full prove cycle.
#
# WHY. Measured 2026-08-31: a prove() cycle is exactly 28 minutes (14 min armed + 14 min
# restored). Two of the three cases run that day spent the whole 28 minutes to produce
# INVALID-INSTRUMENT, for reasons that were visible within seconds of arming the bit:
#   * START|NOCARD  - bypassing the cardless reject destabilised the WINDOW SET; `dom0 dims`
#                     came back EMPTY, the control window itself gone.
#   * FI_DROP_CAPTIONED - the bit drops captioned windows, and the harness's own control IS a
#                     captioned Notepad, so it disabled the instrument's control.
# Both are the same question: WITH THIS BIT ARMED, CAN THE HARNESS STILL SEE ITS CONTROL? If the
# answer is no, the bit cannot be proved through that harness and no amount of runtime changes
# that. Asking it costs one agent restart and one screenshot.
#
# This does NOT decide whether the bit works - only whether a proof through this harness is
# POSSIBLE. A green preflight is permission to spend the 28 minutes, nothing more.
#
#   mgmt/harness/gate-preflight.sh <vm> <hex-bits>
#
# Exit: 0 = CLEAR TO RUN; 1 = do not spend the 28 min (the bit blinds the harness - a GRADED
# outcome); 2 = refusing (no control even unarmed); 3 = INVALID-INSTRUMENT, guest unresponsive
# mid-sequence or the watchdog service not Running after a toggle (also graded - this script
# must ALWAYS return a verdict, never hang).
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> <hex-bits>}"
BITS="${2:?usage: $0 <vm> <hex-bits>}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
KEY='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
QTEST_BIN="${QTEST_BIN:-./tools/qtest}"   # overridable ONLY so the degraded-guest paths are provable off-rig
q(){ QTEST_VM=$VM timeout -k 8 "${T:-200}" "$QTEST_BIN" "$@" 2>/dev/null; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  q run "cmd /c powershell -NoProfile -EncodedCommand $b" | tr -d '\r'; }
log(){ echo "$(date -u +%H:%M:%S) preflight[$VM $BITS]: $*"; }

# LIVENESS BOUND (2026-09-04). The preflight cycles arm + agent-restart per bit, and the cycling
# itself can degrade the guest's qrexec/session: measured in the P5 run 0x3 -> 0x14 -> 0x20, by
# 0x20 the guest stopped answering after "GATEOFF 0" and THIS script spun >12 min (VMShell calls
# each burning their full per-call timeout in series) without emitting a verdict, until an
# external watchdog killed the step. A guest that stops answering mid-sequence is a GRADED
# outcome - INVALID-INSTRUMENT, the failproof is not takeable this run - never a condition to
# out-wait: every further probe against a dead guest manufactures the same emptiness. Nothing
# here touches the responsive paths: an ALIVE guest still flows to CLEAR TO RUN / DO NOT SPEND /
# REFUSING exactly as before, so an armed run's power to prove the SG can fail is unchanged.
alive(){ T=30 q run 'cmd /c echo LIVE' | grep -qa LIVE; }

guest_gone(){  # <context> - one bounded restore attempt, the verdict row, and OUT (exit 3)
  log "guest gone - one bounded FaultGateOff=0 restore attempt, then the verdict"
  T=120 set_bits 0 >/dev/null 2>&1 || true   # 120: set_bits may now poll up to 45 s for the agent PID
  log "-> INVALID-INSTRUMENT: guest unresponsive during the fault-toggle sequence"
  log "   (arm+agent-restart degraded the session at bit $BITS; $1)."
  log "   The failproof is NOT TAKEABLE this run - a graded, honest outcome: the SG rows it"
  log "   would have upgraded stay PASS-UNPROVEN, and the campaign completes at its autonomous"
  log "   ceiling instead of stalling here."
  printf 'PREFLIGHT\t%s\t%s\tINVALID-INSTRUMENT\tguest unresponsive during the fault-toggle sequence (arm+agent-restart degraded the session at bit %s; %s); failproof not takeable this run\n' \
    "$VM" "$BITS" "$BITS" "$1"
  exit 3
}

require_alive(){  # <context> - 3 bounded probes, then the graded exit; never an unbounded loop
  local i; for i in 1 2 3; do
    alive && return 0
    log "  liveness probe $i/3: guest did not answer ($1)"
    sleep 5
  done
  guest_gone "$1"
}

windows(){  # -> "<count>|<WxH>,..."
  local t; t=$(mktemp -u /tmp/pf-XXXX).tar
  q shot "$t" >/dev/null 2>&1
  local n; n=$(tar tf "$t" 2>/dev/null | grep -c '\.png$'); n=${n:-0}
  local d=""
  if [ "$n" -gt 0 ]; then
    local x; x=$(mktemp -d); tar xf "$t" -C "$x" 2>/dev/null
    d=$(for f in "$x"/*.png; do [ -e "$f" ] && python3 -c "
import struct,sys; b=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',b[16:24]); print(f'{w}x{h}')" "$f"; done | paste -sd,)
    rm -rf "$x"
  fi
  rm -f "$t"; echo "$n|$d"
}

# AGENT RESTART WAITS ON A FACT, NOT A TIMER (audit 2026-09-08). This used to be `Start-Service;
# Start-Sleep 22`. Start-Service returning says nothing about the agent: the watchdog reports
# RUNNING at once and spawns gui-agent from its own loop, so a slow session (cold AppVM, IDD
# re-bind) had no agent yet at 22 s and the toggle was graded against a stale state, while a
# fast guest idled ~20 s per toggle. Worse, -EA SilentlyContinue hid a watchdog that never
# started, and any gui-agent left over from before the kill then stood in for the "restarted"
# one. Now: the pre-kill PIDs are recorded and only a gui-agent NOT among them counts (bounded
# 45 s poll), the service status is echoed for the caller to grade, and the window-map witness
# is control_up's own outcome poll below.
set_bits(){ psrun "New-Item -Path '$KEY' -Force | Out-Null
Set-ItemProperty -Path '$KEY' -Name FaultGateOff -Value $1 -Type DWord
\$old = @(Get-Process gui-agent -EA SilentlyContinue | ForEach-Object Id)
Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
\$wdErr = ''
try { Start-Service QubesGuiWatchdog -EA Stop } catch { \$wdErr = \$_.Exception.Message }
\$wd = (Get-Service QubesGuiWatchdog -EA SilentlyContinue).Status
Write-Output ('WDSTART ' + \$wd + ' ' + \$wdErr)
\$new = 0; \$sw = [Diagnostics.Stopwatch]::StartNew()
while (\$sw.Elapsed.TotalSeconds -lt 45) {
  \$p = @(Get-Process gui-agent -EA SilentlyContinue | Where-Object { \$old -notcontains \$_.Id })
  if (\$p.Count -gt 0) { \$new = \$p[0].Id; break }
  Start-Sleep -Milliseconds 500
}
Write-Output ('AGENTPID ' + \$new + ' after ' + [int]\$sw.Elapsed.TotalSeconds + 's')
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" | grep -aE 'GATEOFF|WDSTART|AGENTPID'; }

watchdog_failed(){  # <context> - the watchdog service is not Running after Start-Service: the
                    # toggle never restarted the agent, so nothing downstream measures the bit.
                    # Graded INVALID-INSTRUMENT (exit 3), never a silent proceed.
  log "watchdog did not start - one bounded FaultGateOff=0 restore attempt, then the verdict"
  T=120 set_bits 0 >/dev/null 2>&1 || true
  log "-> INVALID-INSTRUMENT: QubesGuiWatchdog not Running after Start-Service ($1)."
  log "   The agent was never restarted under bit $BITS, so any control reading would grade a"
  log "   leftover state, not the bit. The failproof is NOT TAKEABLE this run."
  printf 'PREFLIGHT\t%s\t%s\tINVALID-INSTRUMENT\tQubesGuiWatchdog not Running after Start-Service (%s); failproof not takeable this run\n' \
    "$VM" "$BITS" "$1"
  exit 3
}

# The GATEOFF echo must ROUND-TRIP or the toggle is graded, never assumed. Called only at top
# level (never in a pipe/substitution) so guest_gone's exit actually terminates the script.
set_bits_checked(){  # <value> <context>
  local out; out=$(set_bits "$1")
  if ! echo "$out" | grep -qa GATEOFF; then
    log "  no GATEOFF echo from the guest ($2)"
    require_alive "$2"
    out=$(set_bits "$1")   # answered liveness - one bounded retry, then grade
    echo "$out" | grep -qa GATEOFF || \
      guest_gone "$2: guest answers liveness but the FaultGateOff write never round-trips"
  fi
  echo "$out" | sed 's/^/  /'
  # A watchdog that is not Running is an instrument failure, graded here (see set_bits). A
  # Running watchdog with no NEW gui-agent inside the bound is an anomaly worth a loud line, but
  # not a verdict: control_up grades the OUTCOME (windows or none) against a live guest.
  echo "$out" | grep -qa 'WDSTART Running' || \
    watchdog_failed "$2: $(echo "$out" | grep -a WDSTART | head -1)"
  echo "$out" | grep -qa 'AGENTPID 0 ' && \
    log "  ANOMALY: watchdog Running but no NEW gui-agent PID within 45 s ($2) - grading the control poll, not a guess"
}

# POLL for the control, never a fixed sleep. A fixed settle is how P5 once scored SG3 as FAIL
# against a window the agent had already mapped: the settle was shorter than the guest needed to
# draw. Measured again 2026-08-31 on a cold AppVM - 14 s was not enough for a first-run Notepad,
# and the preflight reported "0 windows" for a guest whose agent was perfectly healthy (vchan
# connected, seamless mode 1, no errors). Wait for the OUTCOME, with a deadline.
control_up(){  # -> echoes the window list once the control appears, or after the deadline;
               #    rc 3 = the guest stopped answering (caller grades it, never out-waits it)
  T=60 q run 'cmd /c taskkill /f /im notepad.exe 2>nul & start "" notepad.exe' >/dev/null 2>&1
  local i w n dead=0
  # 16 polls (96 s), was 12: set_bits no longer sleeps a fixed 22 s after Start-Service, so the
  # time a cold guest needs to init the agent AND draw the control is all spent here, on the
  # outcome poll. Keeps the worst-case window budget where it was (22 + 72 s) instead of
  # shrinking it and re-creating the "0 windows for a healthy agent" false REFUSING above.
  for i in $(seq 1 16); do
    sleep 6
    w=$(windows); n=${w%%|*}
    [ "${n:-0}" -gt 0 ] && { echo "$w"; return 0; }
    # an empty poll is DATA only while the guest still answers; this exact loop is what spun
    # >12 min against the degraded guest at 0x20
    if alive; then dead=0; else dead=$((dead+1)); fi
    [ "$dead" -ge 3 ] && { echo "$w"; return 3; }
  done
  echo "$w"; return 0
}

require_alive "before the unarmed reference control"
log "=== control WITHOUT the bit (this is the reference) ==="
set_bits_checked 0 "clearing the gate for the reference run"
BEFORE=$(control_up) || guest_gone "guest stopped answering while polling for the unarmed reference control"
log "  dom0: $BEFORE"
nb=${BEFORE%%|*}
if [ "${nb:-0}" -eq 0 ]; then
  log "REFUSING: the harness control is not visible even with NO bit set. The rig is not in a"
  log "  state where any proof could be read; fix that before arming anything."
  q run 'cmd /c taskkill /f /im notepad.exe 2>nul & exit 0' >/dev/null 2>&1
  exit 2
fi

log "=== control WITH $BITS armed ==="
set_bits_checked "$BITS" "arming $BITS"
AFTER=$(control_up) || guest_gone "guest stopped answering while polling for the control with $BITS armed"
log "  dom0: $AFTER"
na=${AFTER%%|*}

log "=== restoring (bit cleared, notepad killed) ==="
set_bits_checked 0 "clearing $BITS during restore"
q run 'cmd /c taskkill /f /im notepad.exe 2>nul & exit 0' >/dev/null 2>&1

if [ "${na:-0}" -eq 0 ]; then
  log "-> DO NOT SPEND THE 28 MINUTES. With $BITS armed the harness sees NO windows at all,"
  log "   its control included. Any verdict from that state would be INVALID-INSTRUMENT, exactly"
  log "   as START|NOCARD and FI_DROP_CAPTIONED both were. This bit needs a control the bit"
  log "   cannot affect, or a different harness."
  exit 1
fi
log "-> CLEAR TO RUN: the control survives the bit ($nb window(s) before, $na after), so a"
log "   'nothing mapped' verdict from the armed run will mean something."
exit 0
