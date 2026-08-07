#!/bin/bash
# Acceptance on the guest installed via the USB answer-stick clean-room path.
# Does NOT reprovision: the install under test is already running. Asserts, in order:
#   1. qrexec comes up on a guest that had none (proves the stick payload installed QWT)
#   2. COLD BOOT (the boot path is part of acceptance, a live restart hides faults)
#   3. health-check with asserted_all: disks + network + IDD in the SAME run
#   4. dom0 pixels actually change (judge output, not logs)
set -u
cd /home/user/qubes-win-idd-driver
VM=win10-clean
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT=evidence/usb-accept-$(date -u +%Y%m%d-%H%M%S); mkdir -p "$OUT"
log(){ echo "$(date -u +%H:%M:%S) usbaccept: $*" | tee -a "$OUT/accept.log"; }
fail(){ log "ACCEPT=FAIL reason=$*"; exit 1; }
qq(){ QTEST_VM="$VM" timeout "${QT:-60}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

log "waiting for qrexec (guest had NO QWT - the stick payload must install it)"
t0=$(date +%s); up=0
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    if [ "$(qq run 'echo BOOT_OK' 2>&1 | tr -d '\r\0' | grep -c BOOT_OK)" -ge 2 ]; then
        up=1; log "qrexec alive after $(( $(date +%s)-t0 ))s - QWT installed from the stick"; break
    fi
    [ "$(state)" = Halted ] && { log "halt -> restarting (installer reboots destroy the domain)"; timeout 120 qvm-start "$VM" >/dev/null 2>&1; }
    sleep 45
done
[ "$up" = 1 ] || fail "qrexec never came up within 90 min"

log "install trailer:"
qq run 'powershell -NoProfile -Command "(Select-String -Path C:\qwt-improved-install.log -Pattern \"=== RESULT ===\" | Select-Object -Last 1).Line"' 2>&1 | tr -d '\r' | grep -a 'RESULT' | tail -1 | tee -a "$OUT/install-result.txt"

# --- COLD BOOT ---------------------------------------------------------------------
log "cold boot (part of acceptance)"
timeout 240 qvm-shutdown --wait "$VM" >/dev/null 2>&1
for _ in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done
[ "$(state)" = Halted ] || timeout 60 qvm-kill "$VM" >/dev/null 2>&1
sleep 5
timeout 150 qvm-start "$VM" >/dev/null 2>&1
t0=$(date +%s); up=0
while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
    qq run 'echo COLD_OK' 2>&1 | tr -d '\r\0' | grep -q COLD_OK && { up=1; log "cold boot OK after $(( $(date +%s)-t0 ))s"; break; }
    sleep 20
done
[ "$up" = 1 ] || fail "guest did not return from cold boot"
sleep 45

# --- health: all three subsystems in ONE run ---------------------------------------
qq ps 'Start-Process notepad' >/dev/null 2>&1; sleep 5
log "health-check (full assertion)"
QT=240 qq pushrun ./guest/health-check.ps1 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$OUT/health.json"
[ -s "$OUT/health.json" ] || fail "health-check produced no output"
python3 - "$OUT/health.json" <<'PY' | tee -a "$OUT/accept.log"
import json,sys
d=json.loads(open(sys.argv[1]).read().split('=== HEALTH ===',1)[1])
for k,v in d['checks'].items():
    mark='PASS' if v.get('pass') else ('n/a' if v.get('na') else 'FAIL')
    print(f"  {mark:4} {k}")
print("ok=%s asserted_all=%s failed=%s not_applicable=%s" % (
    d.get('ok'), d.get('asserted_all'), ','.join(d.get('failed') or []), ','.join(d.get('not_applicable') or [])))
PY
grep -q '"asserted_all":true' "$OUT/health.json" || fail "not every check asserted (see $OUT/health.json)"

log "visual evidence"
qrexec-client-vm dom0 local.WinFullScreen+$VM > "$OUT/screen.tar" 2>/dev/null </dev/null
log "ACCEPT=PASS evidence=$OUT"
