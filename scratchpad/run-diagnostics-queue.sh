#!/bin/bash
# Diagnostics D4 and D5 from PLAN-perf-win11.md, queued behind the running chain.
#
#   D4  idle present rate, BOTH guests  - is the Win11 surplus ambient or workload-driven?
#   D5  desktop effects off vs on       - do Win11's default effects cause the surplus?
#
# D4 runs on both guests because one side settles nothing: the whole point is the Win10-vs-Win11
# comparison. Both must be on the same display path (BDA) at the same resolution, which is why
# win10-clean and win11-fresh are the pair - win11-idd-test would add the IddCx variable that
# PLAN-perf-win11.md keeps separate as overhead B.
#
# CAVEAT RECORDED UP FRONT, not discovered later: the two guests do NOT carry the same agent
# build. That is acceptable for an idle PRESENT COUNT, because `n` counts frames delivered by
# AcquireNextFrame and neither build changes what Windows presents - but it is a real difference
# and each side's hash is recorded so the comparison can be redone matched if the result turns
# out to be decisive.
#
# Waits for the chain rather than racing it: two Windows guests running at once contaminates
# every timing, and CLAUDE.md requires VM-mutating jobs to run serially.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) queue: $*"; }

log "waiting for the running chain to finish"
waited=0
while pgrep -f run-fix-validation.sh >/dev/null 2>&1; do
    sleep 60; waited=$((waited+1))
    [ $((waited % 10)) -eq 0 ] && log "  still waiting (${waited} min)"
    [ "$waited" -gt 180 ] && { log "ABORT: chain still running after 3 h - not queueing behind it blindly"; exit 1; }
done
log "chain finished after ${waited} min of waiting"

log "=== D4a: idle present rate, win11-fresh (BDA) ==="
./scratchpad/idle-rate.sh win11-fresh win11 30 2>&1 | tee "$S/queue-idle-win11.log"

log "=== D5: desktop effects off vs on, win11-fresh ==="
./scratchpad/veffects-ab.sh win11-fresh win11 3 2>&1 | tee "$S/queue-veffects-win11.log"

log "restoring Windows' default visual effects on win11-fresh"
QTEST_VM=win11-fresh timeout 180 ./tools/qtest run \
  'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\disable-visual-effects.ps1 -Restore' 2>&1 \
  | tr -d '\r\0' | grep -aE "^=== RESULT ===" | sed 's/^/    /'

log "=== D4b: idle present rate, win10-clean (BDA) ==="
./scratchpad/idle-rate.sh win10-clean win10 30 2>&1 | tee "$S/queue-idle-win10.log"

log "=== D4 comparison ==="
for g in win11 win10; do
    f="$S/idle-$g/REPORT.txt"
    if [ -f "$f" ]; then
        echo "--- $g ---"
        grep -aE "median idle rate|agent=" "$f" 2>/dev/null | sed 's/^/    /'
        [ -f "$S/idle-$g/agent-hash.txt" ] && echo "    agent: $(cat "$S/idle-$g/agent-hash.txt")"
        [ -f "$S/idle-$g/config.txt" ] && grep -aE "^SCREEN|^VC " "$S/idle-$g/config.txt" | sed 's/^/    /'
    else
        echo "--- $g: NO REPORT (that is a failure, not an absence) ---"
    fi
done

log "=== queue complete - reports under $S/idle-win11, $S/idle-win10, $S/veffects-win11 ==="
