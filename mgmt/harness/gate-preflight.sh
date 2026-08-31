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
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> <hex-bits>}"
BITS="${2:?usage: $0 <vm> <hex-bits>}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
KEY='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-200}" ./tools/qtest "$@" 2>/dev/null; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  q run "cmd /c powershell -NoProfile -EncodedCommand $b" | tr -d '\r'; }
log(){ echo "$(date -u +%H:%M:%S) preflight[$VM $BITS]: $*"; }

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

set_bits(){ psrun "New-Item -Path '$KEY' -Force | Out-Null
Set-ItemProperty -Path '$KEY' -Name FaultGateOff -Value $1 -Type DWord
Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
Start-Service QubesGuiWatchdog -EA SilentlyContinue; Start-Sleep 22
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" | grep -a GATEOFF; }

# POLL for the control, never a fixed sleep. A fixed settle is how P5 once scored SG3 as FAIL
# against a window the agent had already mapped: the settle was shorter than the guest needed to
# draw. Measured again 2026-08-31 on a cold AppVM - 14 s was not enough for a first-run Notepad,
# and the preflight reported "0 windows" for a guest whose agent was perfectly healthy (vchan
# connected, seamless mode 1, no errors). Wait for the OUTCOME, with a deadline.
control_up(){  # -> echoes the window list once the control appears, or after the deadline
  q run 'cmd /c taskkill /f /im notepad.exe 2>nul & start "" notepad.exe' >/dev/null 2>&1
  local i w n
  for i in $(seq 1 12); do
    sleep 6
    w=$(windows); n=${w%%|*}
    [ "${n:-0}" -gt 0 ] && { echo "$w"; return 0; }
  done
  echo "$w"; return 0
}

log "=== control WITHOUT the bit (this is the reference) ==="
set_bits 0 | sed 's/^/  /'
BEFORE=$(control_up); log "  dom0: $BEFORE"
nb=${BEFORE%%|*}
if [ "${nb:-0}" -eq 0 ]; then
  log "REFUSING: the harness control is not visible even with NO bit set. The rig is not in a"
  log "  state where any proof could be read; fix that before arming anything."
  q run 'cmd /c taskkill /f /im notepad.exe 2>nul & exit 0' >/dev/null 2>&1
  exit 2
fi

log "=== control WITH $BITS armed ==="
set_bits "$BITS" | sed 's/^/  /'
AFTER=$(control_up); log "  dom0: $AFTER"
na=${AFTER%%|*}

log "=== restoring (bit cleared, notepad killed) ==="
set_bits 0 >/dev/null
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
