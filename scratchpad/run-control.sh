#!/bin/bash
# Control stick is already built and verified; provision, verify stock, then benchmark.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) ctl: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-90}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

log "provisioning the control guest"
./scratchpad/usb-provision.sh win10-stock loop0 loop11 core-net 2>&1 | tail -3 || { log "ABORT: provision failed"; exit 1; }

log "waiting for the control guest (90 min)"
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    qq win10-stock run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "control qrexec up after $(( $(date +%s)-t0 ))s"; break; }
    [ "$(state win10-stock)" = Halted ] && { log "halt -> restarting"; timeout 120 qvm-start win10-stock >/dev/null 2>&1; }
    sleep 45
done
qq win10-stock run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: control never answered"; exit 1; }
sleep 45

OURS=$(python3 -c "
import json;m=json.load(open('artifacts-final/MANIFEST.json'))
print(m['reference_binaries']['gui-agent.exe'][:16].upper())" 2>/dev/null)
STOCK=$(QT=120 qq win10-stock run 'powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 \"C:\Program Files\Qubes Tools\bin\gui-agent.exe\").Hash.Substring(0,16)"' 2>&1 | tr -d '\r' | grep -oE '^[0-9A-F]{16}$' | head -1)
log "ours=$OURS control=$STOCK"
[ -n "$STOCK" ] || { log "ABORT: control agent hash unreadable"; exit 1; }
[ "$STOCK" != "$OURS" ] || { log "ABORT: control is running OUR agent"; exit 1; }
log "CONTROL VERIFIED GENUINELY STOCK"

log "lock forensics (settles the locked-session question on a spare guest)"
QT=150 qq win10-stock pushrun ./scratchpad/lock-forensics.ps1 2>&1 | tr -d '\r' | grep -aE "^EV |^PW |^Inactivity|^NoLock|^ScreenSave|^VIDEOIDLE|^STANDBYIDLE|^QubesLockProbe" | head -20

log "=== interleaved benchmark ==="
STOCK_AGENT_HASH="$STOCK" REPS=3 ./scratchpad/bench-interleaved.sh 2>&1 | tail -60
