#!/bin/bash
# CONTROLLED comparison: our agent, Basic Display Adapter, SAME resolution, Win10 vs Win11.
#
# Everything measured so far varied several things at once:
#   four-row matrix : agent AND display path differed on Win11
#   typing probe    : OS, display path (IDD vs BDA) AND resolution (7.37 vs 4.95 Mpx)
# A shorter acq on a smaller framebuffer is exactly what resolution alone would produce, so
# the frame-rate signal could not be attributed. This run holds agent, display path and
# resolution constant so the ONLY difference left is the operating system.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) ctrl: $*"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }
qq(){ QTEST_VM="$1" timeout "${QT:-180}" ./tools/qtest "${@:2}"; }

log "installing our build with NO /idd onto win10-clean (BDA, matching win11-fresh)"
./scratchpad/usb-provision.sh win10-clean loop0 loop9 core-net 2>&1 | tail -3 || exit 1
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    qq win10-clean run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "up after $(( $(date +%s)-t0 ))s"; break; }
    [ "$(state win10-clean)" = Halted ] && { log "halt -> restarting"; timeout 120 qvm-start win10-clean >/dev/null 2>&1; }
    sleep 45
done
qq win10-clean run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: win10-clean never answered"; exit 1; }
sleep 40

# Both guests must be on the BDA. Assert it rather than assume the no-/idd install did it.
for vm in win10-clean; do
  vc=$(qq $vm pushrun $S/iddstate.ps1 2>&1 | tr -d '\r' | grep -a "^VC ")
  echo "$vc" | sed "s/^/    $vm /"
  echo "$vc" | grep -q "Basic Display Adapter avail=3" || { log "ABORT: $vm not on the BDA"; exit 1; }
  echo "$vc" | grep -q "IddSampleDriver Device avail=3" && { log "ABORT: $vm also has the IDD active"; exit 1; }
done
log "win10-clean confirmed on the BDA"
