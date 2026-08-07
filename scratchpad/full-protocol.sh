#!/bin/bash
# Full re-test under the SAME protocol, both platforms, clean-room path.
#  1. wait for a green release-package carrying MoveUsers + DisableCursor=1 + LogDir=Q:
#  2. PROVE the package contains each change before spending an hour installing it
#  3. rebuild the answer stick (seconds - the vendor ISO is never rebuilt)
#  4. Win10 clean-room install  -> this is ALSO the MoveUsers throwaway test: MoveUsers is
#     boot-critical (Session Manager!BootExecute), so "does the guest boot" is the test
#  5. full acceptance (cold boot + asserted_all)
#  6. same for Win11
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) protocol: $*"; }

log "waiting for a green release-package at or after fcecaee"
t0=$(date +%s)
while :; do
  RID=$(gh run list --workflow=release-package.yml --limit 8 --json databaseId,status,conclusion,headSha \
        -q '[.[] | select(.status=="completed" and .conclusion=="success")][0].databaseId' 2>/dev/null)
  SHA=$(gh run list --workflow=release-package.yml --limit 8 --json databaseId,status,conclusion,headSha \
        -q '[.[] | select(.status=="completed" and .conclusion=="success")][0].headSha' 2>/dev/null)
  [ -n "$RID" ] && git merge-base --is-ancestor fcecaee "$SHA" 2>/dev/null && { log "green build $RID @ ${SHA:0:8}"; break; }
  [ $(( $(date +%s)-t0 )) -gt 4200 ] && { log "ABORT: no suitable green build"; exit 1; }
  sleep 90
done

rm -rf artifacts-final
for a in 1 2 3; do gh run download $RID -n qwt-improved-setup -D artifacts-final && break; rm -rf artifacts-final; sleep 15; done
I=artifacts-final/Install-QwtImproved.ps1
grep -q "PvDriversDisk" $I            || { log "ABORT: no PvDriversDisk"; exit 1; }
grep -q "MoveUsers" $I                || { log "ABORT: no MoveUsers"; exit 1; }
grep -q "'DisableCursor', 'REG_DWORD', '1'" $I || { log "ABORT: DisableCursor not 1"; exit 1; }
grep -q "Q:.Qubes Logs" $I            || { log "ABORT: LogDir not on the private volume"; exit 1; }
[ -f artifacts-final/pv-drivers/xenvif.sys ] || { log "ABORT: no xenvif"; exit 1; }
log "package verified: PvDriversDisk + MoveUsers + DisableCursor=1 + LogDir=Q: + xenvif"
python3 -c "
import json;m=json.load(open('artifacts-final/MANIFEST.json'))
print('   agent',m['source']['agent_commit'][:12],'version',m['package_version'])"

run_side(){
  local vm=$1 iso=$2 stick=$3 tmpl=$4 loc=$5 img=$6 out=$7
  log "=== $vm: rebuild stick + clean-room install ==="
  UNATTEND=$tmpl RELEASE_SETUP=$PWD/artifacts-final LOCALE=$loc INSTALL_FLAGS=/idd \
    OUT=$out ./mgmt/build-answer-stick.sh "$img" > $S/stick-$vm.log 2>&1 \
    || { log "ABORT: stick build failed for $vm"; tail -5 $S/stick-$vm.log; return 1; }
  # The builder now rewrites the image IN PLACE, so the inode and the size never change and
  # the loop stays valid. VERIFY that rather than assume it. Match on the WHOLE losetup line:
  # "(deleted)" is a SEPARATE FIELD, so awk '{print $6}' returns the clean path and a stale
  # loop sails through - that exact bug let a full install run against a stale stick today.
  local dev=/dev/$stick lline
  lline=$(losetup -l 2>/dev/null | grep -F "$dev ")
  case "$lline" in
    *"(deleted)"*) log "ABORT: $dev backing file is DELETED - guest would read a stale stick: $lline"; return 1 ;;
    "") log "ABORT: $dev is not attached"; return 1 ;;
  esac
  echo "$lline" | grep -qF "$out" || { log "ABORT: $dev does not back $out: $lline"; return 1; }
  local exposed actual
  exposed=$(( $(cat /sys/block/$stick/size) * 512 )); actual=$(stat -c%s "$out")
  [ "$exposed" = "$actual" ] || { log "ABORT: $dev exposes $exposed but $out is $actual"; return 1; }
  log "$dev -> $out verified (live inode, $exposed bytes)"
  ./scratchpad/usb-provision.sh $vm $iso $stick core-net 2>&1 | tail -4 || return 1
  ./scratchpad/usb-acceptance.sh $vm 2>&1 | tail -22
}

run_side win10-clean loop0 loop9  mgmt/autounattend.xml       en-GB "Windows 10 Pro" /home/user/win-iso/answer-usb.img
log "=== win10 done, now win11 ==="
run_side win11-fresh loop3 loop10 mgmt/autounattend-win11.xml en-US "Windows 11 Pro" /home/user/win-iso/answer-usb-win11.img
