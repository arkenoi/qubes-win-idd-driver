#!/bin/bash
# Drive straight through to the benchmark verdict.
#  1. recover win10-clean (reboot -> autologon gives an UNLOCKED session; qrexec lives in it)
#  2. re-run its gate with the corrected checker -> expect asserted_all=true
#  3. provision the STOCK control guest through the SAME clean-room path
#  4. interleaved benchmark, cross-side metrics only
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) tobench: $*"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }
qq(){ QTEST_VM="$1" timeout "${QT:-90}" ./tools/qtest "${@:2}"; }

# $1=vm, $2=budget seconds (default 900). A REBOOT needs ~60 s; a FRESH INSTALL needs ~40
# min, and reusing the reboot budget for an install aborted a perfectly healthy stock guest
# 15 minutes in (measured 2026-08-07). Always pass the install budget explicitly.
up_wait(){
  local t0=$(date +%s) budget=${2:-900}
  while [ $(( $(date +%s)-t0 )) -lt $budget ]; do
    qq "$1" run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "$1 qrexec up"; return 0; }
    sleep 20
  done; return 1
}
coldboot(){  # $1=vm
  timeout 240 qvm-shutdown --wait "$1" >/dev/null 2>&1
  for _ in $(seq 1 40); do [ "$(state $1)" = Halted ] && break; sleep 5; done
  [ "$(state $1)" = Halted ] || timeout 60 qvm-kill "$1" >/dev/null 2>&1
  sleep 5
  timeout 150 qvm-start "$1" >/dev/null 2>&1
  up_wait "$1" 900 || return 1
  sleep 45
}

log "=== 1. recover win10-clean from the idle lock ==="
coldboot win10-clean || { log "ABORT: win10-clean would not come back"; exit 1; }

log "=== 2. re-run the Win10 gate with the corrected checker ==="
qq win10-clean ps 'Start-Process notepad' >/dev/null 2>&1; sleep 5
QT=240 qq win10-clean pushrun ./guest/health-check.ps1 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$S/w10-regate.json"
python3 - "$S/w10-regate.json" <<'PY'
import json,sys
d=json.loads(open(sys.argv[1]).read().split('=== HEALTH ===',1)[1])
for k,v in d['checks'].items(): print(f"  {'PASS' if v.get('pass') else 'FAIL'}  {k}")
print("ok=%s asserted_all=%s failed=%s" % (d.get('ok'), d.get('asserted_all'), d.get('failed')))
PY
grep -q '"asserted_all":true' "$S/w10-regate.json" \
  && log "WIN10 GATE: asserted_all=true" \
  || log "WIN10 GATE STILL FAILING (see $S/w10-regate.json)"

log "=== 3. provision the STOCK control guest (same clean-room path, stock MSI) ==="
timeout 240 qvm-shutdown --wait win10-clean >/dev/null 2>&1
./scratchpad/usb-provision.sh win10-stock loop0 loop11 core-net 2>&1 | tail -4 || { log "ABORT: stock provision failed"; exit 1; }
log "waiting for the stock guest to finish installing"
up_wait win10-stock 5400 || { log "ABORT: stock guest never answered in 90 min"; exit 1; }
# The control must really be STOCK: our agent hash must NOT be what is running.
QT=120 qq win10-stock run 'powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 \"C:\Program Files\Qubes Tools\bin\gui-agent.exe\").Hash.Substring(0,16)"' 2>&1 | tr -d '\r' | grep -oE '^[0-9A-F]{16}$' | head -1 | tee "$S/stock-agent-hash.txt"
log "stock agent hash: $(cat $S/stock-agent-hash.txt 2>/dev/null)"

log "=== 4. interleaved benchmark ==="
REPS=3 ./scratchpad/bench-interleaved.sh 2>&1 | tail -50
