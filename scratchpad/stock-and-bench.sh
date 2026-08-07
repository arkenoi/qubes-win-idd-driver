#!/bin/bash
# Rebuild the STOCK control stick (now with the ITL certs), reinstall the control guest
# through the SAME clean-room path as ours, verify it is genuinely stock, then benchmark.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) sb: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-90}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

log "rebuilding the stock stick (vendor MSI, installed by OUR installer)"
STOCK_SETUP=$PWD/artifacts-stock LOCALE=en-GB \
  OUT=/home/user/win-iso/answer-usb-stock.img \
  ./mgmt/build-answer-stick.sh "Windows 10 Pro" > $S/stockstick2.log 2>&1 \
  || { log "ABORT: stick build failed"; tail -6 $S/stockstick2.log; exit 1; }
grep -E "STOCK control staged" $S/stockstick2.log || { log "ABORT: stock payload not staged"; exit 1; }

# in-place rewrite keeps the inode; VERIFY rather than assume (a stale loop served a whole
# install against the wrong image earlier today)
lline=$(losetup -l 2>/dev/null | grep -F "/dev/loop11 ")
case "$lline" in *"(deleted)"*) log "ABORT: loop11 backing file deleted: $lline"; exit 1;; "") log "ABORT: loop11 not attached"; exit 1;; esac
exposed=$(( $(cat /sys/block/loop11/size) * 512 )); actual=$(stat -c%s /home/user/win-iso/answer-usb-stock.img)
[ "$exposed" = "$actual" ] || { log "ABORT: loop11 exposes $exposed, file is $actual"; exit 1; }
log "loop11 verified live ($exposed bytes)"

log "reinstalling the control guest"
./scratchpad/usb-provision.sh win10-stock loop0 loop11 core-net 2>&1 | tail -3 || { log "ABORT: provision failed"; exit 1; }

log "waiting for the control guest (90 min budget)"
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    qq win10-stock run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "stock qrexec up after $(( $(date +%s)-t0 ))s"; break; }
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
log "control verified genuinely stock"

# While the control is up and idle, settle the lock question on a guest we can spare.
log "lock forensics on the control guest"
QT=150 qq win10-stock pushrun ./scratchpad/lock-forensics.ps1 2>&1 | tr -d '\r' | grep -aE "^EV |^PW |^Inactivity|^NoLock|^ScreenSave|^VIDEOIDLE|^STANDBYIDLE|^QubesLockProbe" | head -25

log "=== interleaved benchmark ==="
STOCK_AGENT_HASH="$STOCK" REPS=3 ./scratchpad/bench-interleaved.sh 2>&1 | tail -60
