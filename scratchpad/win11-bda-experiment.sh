#!/bin/bash
# WHY: the four-row table's Windows 11 comparison varies TWO things at once -
#   ours  win11 = our agent + IddCx display
#   stock win11 = stock agent + Basic Display Adapter
# so "ours costs more CPU on Win11" cannot be attributed to the agent or to the display path.
# This installs OUR agent WITHOUT /idd, giving our agent on the BDA: the missing third point.
#   ours-on-BDA ~ stock        -> the cost is the IddCx path
#   ours-on-BDA still elevated -> the cost is our agent on Windows 11
# Reuses win11-fresh (policy-known). Its IDD numbers are already collected on disk in
# bm-win11/ours-r*, so reinstalling the guest does not lose them.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) w11bda: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-120}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

lline=$(losetup -l 2>/dev/null | grep -F "/dev/loop10 ")
case "$lline" in *"(deleted)"*) log "ABORT: loop10 backing deleted"; exit 1;; "") log "ABORT: loop10 not attached"; exit 1;; esac
[ "$(( $(cat /sys/block/loop10/size) * 512 ))" = "$(stat -c%s /home/user/win-iso/answer-usb-win11.img)" ] \
  || { log "ABORT: loop10 capacity != image size"; exit 1; }
log "loop10 verified"

log "clean install of OUR build with NO /idd onto win11-fresh"
./scratchpad/usb-provision.sh win11-fresh loop3 loop10 core-net 2>&1 | tail -3 || exit 1

t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    qq win11-fresh run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "up after $(( $(date +%s)-t0 ))s"; break; }
    [ "$(state win11-fresh)" = Halted ] && { log "halt -> restarting"; timeout 120 qvm-start win11-fresh >/dev/null 2>&1; }
    sleep 45
done
qq win11-fresh run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: never answered"; exit 1; }
sleep 45

# PROVE the display stack is what this experiment requires: BDA driving, IDD not active.
log "display stack:"
qq win11-fresh pushrun $S/iddstate.ps1 2>&1 | tr -d '\r' | grep -aE "^VC |^SCREEN " | sed 's/^/    /'
vc=$(qq win11-fresh pushrun $S/iddstate.ps1 2>&1 | tr -d '\r' | grep -a "^VC ")
echo "$vc" | grep -q "Basic Display Adapter avail=3" \
  || { log "ABORT: BDA is not the active controller - this would not answer the question"; exit 1; }
echo "$vc" | grep -q "IddSampleDriver Device avail=3" \
  && { log "ABORT: the IDD is ALSO active - not a clean BDA configuration"; exit 1; }
log "confirmed: our agent running on the Basic Display Adapter"

OURS_HASH=$(python3 -c "
import json;print(json.load(open('artifacts-final/MANIFEST.json'))['reference_binaries']['gui-agent.exe'][:16].upper())")
got=$(qq win11-fresh pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | tr -d '\r' | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
[ "$got" = "$OURS_HASH" ] || { log "ABORT: agent hash $got != $OURS_HASH"; exit 1; }
log "agent verified ($got)"

log "=== 3 reps: ours + BDA on Windows 11 ==="
for r in 1 2 3; do
  QTEST_VM=win11-fresh BENCH_OUT=$S/bm-win11-bda ./scratchpad/benchmark.sh run ours --rep "$r" --expect-hash "$OURS_HASH" 2>&1 | tail -3
done

log "=== comparison ==="
python3 ./scratchpad/win11-compare.py "$S/bm-win11" "$S/bm-win11-bda"
