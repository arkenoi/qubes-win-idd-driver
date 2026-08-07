#!/bin/bash
# Continue from a stock guest that is ALREADY installing: wait properly, verify it is
# genuinely stock, then run the interleaved benchmark.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) finish: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-90}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

log "waiting for win10-stock to finish installing (90 min budget - a fresh install is ~40 min)"
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 5400 ]; do
    qq win10-stock run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { log "stock qrexec up after $(( $(date +%s)-t0 ))s"; break; }
    [ "$(state win10-stock)" = Halted ] && { log "halt -> restarting (installer reboots destroy the domain)"; timeout 120 qvm-start win10-stock >/dev/null 2>&1; }
    sleep 45
done
qq win10-stock run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: stock guest never answered"; exit 1; }
sleep 45

# The control must be genuinely STOCK. Compare against OUR agent hash from the manifest:
# if they match, the wrong package installed and every later number is meaningless.
OURS=$(python3 -c "
import json;m=json.load(open('artifacts-final/MANIFEST.json'))
print(m['reference_binaries']['gui-agent.exe'][:16].upper())" 2>/dev/null)
STOCK=$(QT=120 qq win10-stock run 'powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 \"C:\Program Files\Qubes Tools\bin\gui-agent.exe\").Hash.Substring(0,16)"' 2>&1 | tr -d '\r' | grep -oE '^[0-9A-F]{16}$' | head -1)
log "ours=$OURS stock=$STOCK"
[ -n "$STOCK" ] || { log "ABORT: could not read the stock agent hash - refusing to benchmark an unverified control"; exit 1; }
[ "$STOCK" != "$OURS" ] || { log "ABORT: control is running OUR agent - not a control at all"; exit 1; }
echo "$STOCK" > "$S/stock-agent-hash.txt"
log "control verified stock"

log "=== interleaved benchmark ==="
STOCK_AGENT_HASH="$STOCK" REPS=3 ./scratchpad/bench-interleaved.sh 2>&1 | tail -60
