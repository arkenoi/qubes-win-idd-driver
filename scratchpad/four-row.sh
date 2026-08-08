#!/bin/bash
# Build the four-row benchmark matrix on POLICY-KNOWN guest names only, with no dom0 action
# and no sudo anywhere.
#
#   ours  win10 -> win10-clean      already installed, 14/14
#   ours  win11 -> win11-fresh      already installed, 14/14
#   stock win10 -> win10-e2e        provisioned here from the stock stick (loop11)
#   stock win11 -> win11-idd-test   provisioned here from a stock win11 stick
#
# Every name above is already in dom0's local.WinScreenshot allowlist. The previous attempt
# invented `win10-stock`, which dom0 does not know, so the per-window screenshot service
# returned 0-byte tars ~1000x per rep and every dom0 pixel metric read 0.000.
#
# NO SUDO: the win11 stock stick is written IN PLACE over loop10's existing backing file, so
# the inode and the padded size never change and the loop needs no losetup -c.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) 4row: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-90}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

wait_up(){ # vm budget
  local t0=$(date +%s)
  while [ $(( $(date +%s)-t0 )) -lt "$2" ]; do
    qq "$1" run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "$1 up after $(( $(date +%s)-t0 ))s"; return 0; }
    [ "$(state $1)" = Halted ] && { log "$1 halted -> restarting"; timeout 120 qvm-start "$1" >/dev/null 2>&1; }
    sleep 45
  done; return 1
}

verify_loop(){ # loopname file
  local l=$1 f=$2 line exposed actual
  line=$(losetup -l 2>/dev/null | grep -F "/dev/$l ")
  case "$line" in *"(deleted)"*) log "ABORT: /dev/$l backing deleted"; return 1;; "") log "ABORT: /dev/$l not attached"; return 1;; esac
  echo "$line" | grep -qF "$f" || { log "ABORT: /dev/$l does not back $f"; return 1; }
  exposed=$(( $(cat /sys/block/$l/size) * 512 )); actual=$(stat -c%s "$f")
  [ "$exposed" = "$actual" ] || { log "ABORT: /dev/$l exposes $exposed, file $actual"; return 1; }
  log "/dev/$l verified ($exposed bytes)"; return 0
}

# ---------- stock win10 on win10-e2e ----------
log "=== stock win10 -> win10-e2e ==="
verify_loop loop11 /home/user/win-iso/answer-usb-stock.img || exit 1
./scratchpad/usb-provision.sh win10-e2e loop0 loop11 core-net 2>&1 | tail -3 || exit 1
wait_up win10-e2e 5400 || { log "ABORT: win10-e2e never answered"; exit 1; }
sleep 45

# ---------- stock win11 on win11-idd-test ----------
log "=== building the stock win11 stick IN PLACE over loop10 (no sudo) ==="
UNATTEND=mgmt/autounattend-win11.xml STOCK_SETUP=$PWD/artifacts-stock LOCALE=en-US \
  OUT=/home/user/win-iso/answer-usb-win11.img \
  ./mgmt/build-answer-stick.sh "Windows 11 Pro" > $S/stick-stock-win11.log 2>&1 \
  || { log "ABORT: win11 stock stick failed"; tail -5 $S/stick-stock-win11.log; exit 1; }
grep -q "STOCK control staged" $S/stick-stock-win11.log || { log "ABORT: stock payload missing"; exit 1; }
verify_loop loop10 /home/user/win-iso/answer-usb-win11.img || exit 1

log "=== stock win11 -> win11-idd-test ==="
./scratchpad/usb-provision.sh win11-idd-test loop3 loop10 core-net 2>&1 | tail -3 || exit 1
wait_up win11-idd-test 5400 || { log "ABORT: win11-idd-test never answered"; exit 1; }
sleep 45

log "=== all four guests ready ==="
for vm in win10-clean win10-e2e win11-fresh win11-idd-test; do
  [ "$(state $vm)" = Running ] || timeout 150 qvm-start "$vm" >/dev/null 2>&1
  wait_up "$vm" 900 >/dev/null 2>&1
  h=$(qq "$vm" pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | tr -d '\r' | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
  log "  $vm agent=$h"
  timeout 200 qvm-shutdown --wait "$vm" >/dev/null 2>&1
done
