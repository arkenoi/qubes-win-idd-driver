#!/bin/bash
# Validate desktop_on_idd by BREAKING it deliberately. CLAUDE.md: a check counts as evidence
# only once it has been seen to FAIL on a build with the defect re-introduced; otherwise its
# PASS is recorded as unproven. NoTopologyApply disables EnsureQubesIddSolo, which reproduces
# exactly the pre-fix behaviour (IDD bound but never attached to the desktop).
set -u
cd /home/user/qubes-win-idd-driver
VM=win10-clean
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) falsify: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-90}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

coldboot(){
    timeout 240 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || timeout 60 qvm-kill "$VM" >/dev/null 2>&1
    sleep 5
    [ "$(state)" = Halted ] || { log "FAIL: $VM would not halt"; return 1; }
    log "verified Halted -> starting"
    timeout 150 qvm-start "$VM" >/dev/null 2>&1
    local t0=$(date +%s)
    while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
        qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "up after $(( $(date +%s)-t0 ))s"; sleep 40; return 0; }
        sleep 20
    done
    return 1
}

verdict(){
    qq pushrun ./guest/health-check.ps1 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$S/falsify-$1.json"
    python3 - "$S/falsify-$1.json" <<'PY'
import json,sys
d=json.loads(open(sys.argv[1]).read().split('=== HEALTH ===',1)[1])
c=d['checks']
print("  desktop_on_idd=%s idd_device_bound=%s asserted_all=%s" % (
    c.get('desktop_on_idd',{}).get('pass'), c.get('idd_device_bound',{}).get('pass'), d.get('asserted_all')))
PY
}

log "=== ARM the defect: NoTopologyApply=1 ==="
qq run 'reg add "HKLM\SOFTWARE\QubesIDD" /v NoTopologyApply /t REG_DWORD /d 1 /f' 2>&1 | tr -d '\r' | grep -ai "success" | head -1
coldboot || { log "ABORT"; exit 1; }
log "with the defect re-introduced:"
verdict broken

log "=== DISARM: remove NoTopologyApply ==="
qq run 'reg delete "HKLM\SOFTWARE\QubesIDD" /v NoTopologyApply /f' 2>&1 | tr -d '\r' | grep -ai "success" | head -1
coldboot || { log "ABORT"; exit 1; }
log "with the fix active:"
verdict fixed
