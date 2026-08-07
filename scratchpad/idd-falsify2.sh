#!/bin/bash
# Falsification attempt 2. Attempt 1 was INCONCLUSIVE: desktop_on_idd passed with the kill
# switch armed, because EnsureQubesIddSolo persists the topology via CDS_UPDATEREGISTRY, so a
# previously-applied solo topology survives reboots even when the apply no longer runs.
# To reproduce the PRE-FIX state the persisted topology must also be torn down: re-enable the
# emulated VGA and make it primary again, which is exactly where the installer used to leave
# the guest.
set -u
cd /home/user/qubes-win-idd-driver
VM=win10-clean
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) falsify2: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-120}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }
coldboot(){
    timeout 240 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || timeout 60 qvm-kill "$VM" >/dev/null 2>&1
    sleep 5; [ "$(state)" = Halted ] || return 1
    timeout 150 qvm-start "$VM" >/dev/null 2>&1
    local t0=$(date +%s)
    while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
        qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { sleep 45; return 0; }
        sleep 20
    done; return 1
}
verdict(){
    qq pushrun ./guest/health-check.ps1 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$S/f2-$1.json"
    python3 - "$S/f2-$1.json" <<'PY'
import json,sys
d=json.loads(open(sys.argv[1]).read().split('=== HEALTH ===',1)[1])
c=d['checks']
print("  desktop_on_idd=%s  evidence=%s" % (
  c.get('desktop_on_idd',{}).get('pass'),
  json.dumps(c.get('desktop_on_idd',{}).get('evidence'))[:260]))
PY
}

log "confirm the kill switch value is actually present"
qq run 'reg query "HKLM\SOFTWARE\QubesIDD" /v NoTopologyApply' 2>&1 | tr -d '\r' | grep -aiE "NoTopologyApply|ERROR" | head -2

log "=== ARM: kill switch ON + tear down the persisted solo topology ==="
qq run 'reg add "HKLM\SOFTWARE\QubesIDD" /v NoTopologyApply /t REG_DWORD /d 1 /f' 2>&1 | tr -d '\r' | grep -ai success | head -1
# Re-enable the emulated VGA: this is precisely the state the installer used to leave behind,
# where the IDD is bound but the desktop is driven by the VGA.
qq ps "\$v = Get-PnpDevice -Class Display -EA 0 | Where-Object { \$_.InstanceId -like 'PCI\\VEN_1234*' }
if (\$v) { Enable-PnpDevice -InstanceId \$v.InstanceId -Confirm:\$false -EA 0; 'VGA re-enabled: ' + \$v.InstanceId } else { 'no VGA devnode found' }" 2>&1 | tr -d '\r' | grep -aE "VGA re-enabled|no VGA" | head -1
coldboot || { log "ABORT: no cold boot"; exit 1; }
log "PRE-FIX state reproduced (apply disabled, VGA back):"
verdict broken

log "=== DISARM: kill switch OFF, let the agent re-apply ==="
qq run 'reg delete "HKLM\SOFTWARE\QubesIDD" /v NoTopologyApply /f' 2>&1 | tr -d '\r' | grep -ai success | head -1
coldboot || { log "ABORT"; exit 1; }
log "fix active again:"
verdict fixed
