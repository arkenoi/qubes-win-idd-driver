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
source mgmt/harness/lifecycle-lib.sh   # ctl_start / ctl_stop: the control window, by handle - no process is killed by name
source mgmt/harness/shutdown-lib.sh   # qwt_shutdown: the bit is applied across a reboot, see set_bits
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
  T=120 write_bits 0 >/dev/null 2>&1 || true   # registry only: a reboot here would outlive the verdict
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

# THE BIT IS APPLIED ACROSS A REBOOT, BECAUSE dom0 DOES NOT COME BACK FROM AN AGENT RESTART.
# This used to write the bit and restart the agent through the QubesGuiWatchdog service (owner
# 2026-10-07: through the owning service, nothing killed by name), then read dom0's window list.
# MEASURED 2026-10-09 on win11-acc, same guest, same control, same probe, one variable:
#   agent service restart -> notepad running guest-side with a visible HWND, the agent parked on
#     "Awaiting for a vchan client" with NO connect line after its last init, dom0 shot = 0 PNGs
#   guest reboot          -> "Awaiting for a vchan client" then "A vchan client has connected"
#     0.32 s later, dom0 shot = 1 PNG
# So dom0's gui-daemon does not reconnect after a gui-agent restart; it connects on a fresh boot.
# That is the gap DESIGN-gui-daemon-restart-survival.md Sec. 3 already names - handle_vchan_error
# never consults vchan_at_eof, diverging from the Linux agent's copy - and it is NOT ours to fix
# here (GUI protocol / gui-daemon work needs a design writeup and the owner's review first).
# What WAS ours is this suite's premise: "one agent restart and one screenshot" cannot see a control
# on this rig, so every run graded REFUSING "the harness control is not visible" and blamed the rig
# for a connection the restart had dropped. A reboot gives a fresh agent AND a fresh guid.
#
# AND THE CONNECTION IS NOW GRADED HERE, not inferred downstream from an empty window list. A guest
# whose agent is up but has no vchan client can never show a control, and saying so is the whole
# difference between a diagnosis and "0 windows".
write_bits(){  # <value> -> GATEOFF readback only; no reboot. For the restore paths.
  psrun "New-Item -Path '$KEY' -Force | Out-Null
Set-ItemProperty -Path '$KEY' -Name FaultGateOff -Value $1 -Type DWord
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" | grep -aE 'GATEOFF'
}

boot_ready(){  # bounded: qrexec answers AND a file push lands (the receiver needs a logged-on
               # session, which qrexec does not prove - the same gap that made this suite's own
               # helper push fail 14 s after "answers qrexec"). rc 1 = never became ready.
  local i probe; probe=$(mktemp); printf 'PFRDY\n' > "$probe"
  for i in $(seq 1 42); do
    if alive; then
      if QTEST_VM=$VM timeout 90 "$QTEST_BIN" push "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        # THE CLOCK, BEFORE ANYTHING READS IT. These guests boot ~3 h ahead (no in-guest time
        # setting survives a reboot - the domain is destroyed), and log-sweep REFUSES a collection
        # whose guest clock is skewed from the host's: rc=3 "clockskew ... +10837 s", which is how
        # the gate's sweep produced no verdict at all. qtest synctime pushes this qube's clock in,
        # accurate to ~0.3 s, and is documented as the thing to call after every VM start.
        QTEST_VM=$VM timeout 120 "$QTEST_BIN" synctime >/dev/null 2>&1 || true
        return 0
      fi
    fi
    sleep 10
  done
  rm -f "$probe"; return 1
}

# What the guest says about the agent THAT IS RUNNING NOW: its pid, and whether a vchan client
# connected after its own init record. Scoped by the pid the process wrote, never by a clock - the
# guest's clock jumps ~3 h backwards about a minute into every boot, so a time window here would
# discard exactly the records this reads.
AGENT_PROOF_PS='$ag = @(Get-Process -Name "gui-agent" -ErrorAction SilentlyContinue)
if ($ag.Count -eq 0) { Write-Output "AGENTPID 0 after boot"; Write-Output "VCHANCONN 0"; exit }
$p = $ag[0].Id
Write-Output ("AGENTPID " + $p + " after boot")
$dir = ""
try { $dir = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -ErrorAction Stop).LogDir } catch { }
if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { Write-Output "VCHANCONN 0"; Write-Output "NEWLOG none"; exit }
$f = @(Get-ChildItem -LiteralPath $dir -Filter "gui-agent-*.log" -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($f.Count -eq 0) { Write-Output "VCHANCONN 0"; Write-Output "NEWLOG none"; exit }
Write-Output ("NEWLOG " + $f[0].Name)
$L = @(Get-Content -LiteralPath $f[0].FullName -ErrorAction SilentlyContinue)
$init = 0; $i = 0
foreach ($ln in $L) { $i++; if ($ln -match ("-" + $p + ":[0-9]+-[A-Z]\]") -and $ln -match "process ID: $p") { $init = $i } }
if ($init -eq 0) { Write-Output "VCHANCONN 0"; Write-Output "INITLINE 0"; exit }
Write-Output ("INITLINE " + $init)
$conn = 0
for ($j = $init; $j -lt $L.Count; $j++) { if ($L[$j] -match "A vchan client has connected") { $conn = 1 } }
Write-Output ("VCHANCONN " + $conn)'

set_bits(){  # <value> -> writes the bit, REBOOTS, and emits the boot-side proof lines
  write_bits "$1" >/dev/null 2>&1 || true
  qwt_shutdown "$VM" 600 >/dev/null 2>&1
  timeout 300 qvm-start "$VM" >/dev/null 2>&1
  boot_ready || { echo "BOOTREADY 0"; return 0; }   # the caller grades it; never out-waited
  echo "BOOTREADY 1"
  psrun "$AGENT_PROOF_PS
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" \
    | grep -aE 'GATEOFF|AGENTPID|VCHANCONN|NEWLOG|INITLINE'
}

watchdog_failed(){  # <context> - the watchdog service is not Running after Start-Service: the
                    # toggle never restarted the agent, so nothing downstream measures the bit.
                    # Graded INVALID-INSTRUMENT (exit 3), never a silent proceed.
  log "watchdog did not start - one bounded FaultGateOff=0 restore attempt, then the verdict"
  T=120 write_bits 0 >/dev/null 2>&1 || true
  log "-> INVALID-INSTRUMENT: QubesGuiWatchdog not Running after Start-Service ($1)."
  log "   The agent was never restarted under bit $BITS, so any control reading would grade a"
  log "   leftover state, not the bit. The failproof is NOT TAKEABLE this run."
  printf 'PREFLIGHT\t%s\t%s\tINVALID-INSTRUMENT\tQubesGuiWatchdog not Running after Start-Service (%s); failproof not takeable this run\n' \
    "$VM" "$BITS" "$1"
  exit 3
}

# The GATEOFF echo must ROUND-TRIP or the toggle is graded, never assumed. Called only at top
# level (never in a pipe/substitution) so guest_gone's exit actually terminates the script.
set_bits_checked(){  # <value> <context> - the bit must round-trip onto a FRESHLY BOOTED, CONNECTED agent
  local out; out=$(set_bits "$1")
  echo "$out" | sed 's/^/  /'
  _pf(){ echo "$out" | grep -aoE "^$1 [0-9]+" | head -1 | awk '{print $2}'; }   # one marker's value
  if [ "$(_pf BOOTREADY)" != 1 ]; then
    guest_gone "$2: the guest never answered qrexec and took a file push after the reboot that applies bit $1"
  fi
  if ! echo "$out" | grep -qa GATEOFF; then
    require_alive "$2"
    out=$(set_bits "$1")   # answered liveness - one bounded retry, then grade
    echo "$out" | sed 's/^/  /'
    echo "$out" | grep -qa GATEOFF || \
      guest_gone "$2: guest answers liveness but the FaultGateOff write never round-trips"
  fi
  local got; got=$(echo "$out" | grep -aoE 'GATEOFF [0-9]+' | head -1 | awk '{print $2}')
  [ "${got:-x}" = "$1" ] || \
    guest_gone "$2: FaultGateOff reads back '${got:-unreadable}' after the reboot, not '$1' - the bit was not applied"
  # A FRESH AGENT. Without one the bit is not in any running process and everything downstream
  # would grade the previous boot's state.
  local apid; apid=$(_pf AGENTPID)
  if [ "${apid:-0}" -le 0 ]; then
    # NOT watchdog_failed: that line says "QubesGuiWatchdog not Running after Start-Service", which
    # is a different fact and was never measured here. Say what was measured.
    log "  no gui-agent process exists after the reboot that applies bit $1"
    log "  INVALID-INSTRUMENT: the bit is in no running process, so nothing downstream measures it."
    T=120 write_bits 0 >/dev/null 2>&1 || true
    printf 'PREFLIGHT\t%s\t%s\tINVALID-INSTRUMENT\tno gui-agent process after the reboot applying bit %s (newest log %s); failproof not takeable this run\n' \
      "$VM" "$BITS" "$1" "$(echo "$out" | grep -aoE 'NEWLOG [^ ]+' | head -1 | awk '{print $2}')"
    exit 3
  fi
  # AND dom0 MUST BE CONNECTED TO IT. This is graded HERE, as an instrument precondition, because a
  # guest whose agent has no vchan client cannot show any window to dom0 - which this suite used to
  # report as "the harness control is not visible", blaming the rig for a missing connection.
  local conn; conn=$(_pf VCHANCONN)
  if [ "${conn:-0}" != 1 ]; then
    log "  dom0's gui-daemon is NOT connected to the agent that just booted (pid ${apid:-?})"
    log "  INVALID-INSTRUMENT: no window of this guest can reach dom0, so no control could be read."
    log "  This is the gui-daemon reconnect gap (DESIGN-gui-daemon-restart-survival.md Sec. 3), not"
    log "  a fault of bit $BITS - and not something this suite can measure around."
    T=120 write_bits 0 >/dev/null 2>&1 || true
    printf 'PREFLIGHT\t%s\t%s\tINVALID-INSTRUMENT\tdom0 gui-daemon not connected to the freshly booted agent (pid %s); no control can be visible; failproof not takeable this run\n' \
      "$VM" "$BITS" "${apid:-0}"
    exit 3
  fi
  log "  fresh agent pid ${apid:-?}, dom0 gui-daemon connected, FaultGateOff=$got"
}

# THE CONTROL IS OURS BY IDENTITY, NOT BY NAME (owner 2026-10-07). This used to `taskkill /f /im
# notepad.exe` - any notepad on the guest, whoever started it - before each start and at the end.
# Now the previous control THIS run started is stopped by the pid + start time recorded when it was
# started (lifecycle-lib.sh ctl_start/ctl_stop), and a fresh one is started by handle. A notepad
# this run did not start is never touched: it would show in the window count exactly as before.
# The identity lives in a FILE: control_up runs inside $(...), where a shell variable would die
# with the subshell and the restore step would find nothing to stop.
CTL_FILE=$(mktemp -u /tmp/pf-ctl-XXXX); : > "$CTL_FILE"
control_stop(){ local _ pid start; read -r _ pid start < "$CTL_FILE" 2>/dev/null
  [ "${pid:-0}" != 0 ] && { echo "  control: $(T=60 ctl_stop "$pid" "${start:-0}")"; : > "$CTL_FILE"; }; return 0; }
control_up(){  # -> echoes the window list once the control appears, or after the deadline;
               #    rc 3 = the guest stopped answering (caller grades it, never out-waits it)
  control_stop >&2
  T=60 ctl_start notepad > "$CTL_FILE" || log "  control: notepad did not start as ours ($(cat "$CTL_FILE")) - the outcome poll below grades what is visible" >&2
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
# NO HELPER GATE HERE ANY MORE. This was
#   agent_restart_push || { log "FATAL: guest/restart-gui-agent.ps1 could not be pushed and proven
#                           on $VM - no agent restart is possible without it"; exit 2; }
# back when the bit was applied by restarting the agent through that helper. set_bits now applies
# it across a reboot, so the helper is not used by this suite at all and a FATAL on pushing it
# would refuse the run over an artefact nothing here reads. ctl_start/ctl_stop still come from
# lifecycle-lib and do not need it.
log "=== control WITHOUT the bit (this is the reference) ==="
set_bits_checked 0 "clearing the gate for the reference run"
BEFORE=$(control_up) || guest_gone "guest stopped answering while polling for the unarmed reference control"
log "  dom0: $BEFORE"
nb=${BEFORE%%|*}
if [ "${nb:-0}" -eq 0 ]; then
  log "REFUSING: the harness control is not visible even with NO bit set. The rig is not in a"
  log "  state where any proof could be read; fix that before arming anything."
  control_stop
  exit 2
fi

log "=== control WITH $BITS armed ==="
set_bits_checked "$BITS" "arming $BITS"
AFTER=$(control_up) || guest_gone "guest stopped answering while polling for the control with $BITS armed"
log "  dom0: $AFTER"
na=${AFTER%%|*}

log "=== restoring (bit cleared, our control notepad stopped) ==="
set_bits_checked 0 "clearing $BITS during restore"
control_stop

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
