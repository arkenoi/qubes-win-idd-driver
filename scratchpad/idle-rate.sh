#!/bin/bash
# =============================================================================
# idle-rate.sh - is the Windows 11 surplus AMBIENT, or driven by the workload?
# =============================================================================
#
#   scratchpad/idle-rate.sh <vm> <label> [seconds]
#
# THE DISCRIMINATOR THE OTHER EXPERIMENTS ARE MISSING.
#
# Everything measured so far ran a workload: drag, scroll, type. So the Win11 surplus
# (488 vs 259 frames over 20 s, agent/display/resolution held constant) could be either
#
#   workload-driven - Windows 11 repaints MORE per unit of user input, or
#   ambient         - Windows 11 repaints on its own regardless of input, and the workload
#                     measurement simply contained that background rate for 20 seconds.
#
# Those have completely different fixes, and no experiment run so far can tell them apart.
# With NO input at all, an ambient cause shows up as a high idle present rate and a
# workload-driven one collapses to near zero.
#
# It is also cheap: no new instrumentation, no code change. drag-harness.ps1 already accepts
# zero-length work phases, so a pure idle run is just an argument.
#
# WHY IT MATTERS FOR THE FIX. If the surplus is ambient, the target is whatever repaints with
# nobody touching the machine - Windows 11 shell surfaces (widgets, search highlight, Copilot,
# notification polling) - and the remedy is disabling those, on the same post-install path as
# disable-hw-accel.ps1. If it is workload-driven, that whole direction is a dead end and the
# chase belongs in DWM's composition behaviour instead.
#
# Run on BOTH guests; the number is meaningless without the other side to compare against.
set -u
cd /home/user/qubes-win-idd-driver

VM="${1:?usage: $0 <vm> <label> [seconds]}"
LABEL="${2:?usage: $0 <vm> <label> [seconds]}"
SECS="${3:-30}"
REPS="${REPS:-3}"

S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/idle-$LABEL"; mkdir -p "$OUT"
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

log(){ echo "$(date -u +%H:%M:%S) idle[$LABEL]: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-240}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }
clean(){ tr -d '\r\0'; }

for v in win10-clean win10-e2e win11-fresh win11-idd-test win-idd-test win10-stock; do
    [ "$v" = "$VM" ] && continue
    [ "$(state "$v")" = Running ] && { log "stopping $v"; timeout 240 qvm-shutdown --wait "$v" >/dev/null 2>&1 || timeout 60 qvm-kill "$v" >/dev/null 2>&1; }
done
[ "$(state "$VM")" = Running ] || { log "starting $VM"; timeout 150 qvm-start "$VM" >/dev/null 2>&1; }
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
    qq run 'echo UP' 2>&1 | clean | grep -q UP && break; sleep 20
done
qq run 'echo UP' 2>&1 | clean | grep -q UP || { log "ABORT: $VM not answering"; exit 1; }
sleep 25

log "config (resolution and display path must match the other side):"
qq pushrun "$S/iddstate.ps1" 2>&1 | clean | grep -aE "^VC |^SCREEN " | tee "$OUT/config.txt" | sed 's/^/    /'
AGENT_HASH=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
log "agent=$AGENT_HASH"
echo "$AGENT_HASH" > "$OUT/agent-hash.txt"

qq push instrumentation/drag-harness.ps1 >/dev/null 2>&1
qq push instrumentation/collect-perf.ps1 >/dev/null 2>&1

for rep in $(seq 1 "$REPS"); do
    d="$OUT/r$rep"; mkdir -p "$d"
    log "rep $rep: ${SECS}s with NO input at all"
    # Zero-length work phases. The window is still created and shown, so the scene matches the
    # workload runs - the ONLY thing removed is the input.
    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\drag-harness.ps1 -DragSeconds 0 -ScrollSeconds 0 -TypeSeconds 0 -IdleSeconds $SECS -KeepNotepad" 2>&1 | clean > "$d/harness.txt"

    since=$(grep -aE "PHASE-START +idle-pre" "$d/harness.txt" | tail -1 | awk '{print $NF}')
    until=$(grep -aE "PHASE-END +idle-pre"   "$d/harness.txt" | tail -1 | awk '{print $NF}')
    if [ -z "$since" ] || [ -z "$until" ]; then
        log "  rep $rep: no idle-pre markers - refusing an unbounded collection"
        echo '{"valid":false,"na":"no idle-pre phase markers"}' > "$d/point.json"; continue
    fi
    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\collect-perf.ps1 -Since $since -Until $until" 2>&1 | clean \
        | sed -n '/===PERFSTART===/,/===PERFEND===/p' > "$d/perf.txt"
    grep -aE "PHASE-(START|END)" "$d/harness.txt" > "$d/phases.txt"
    recs=$(grep -ac 'QGAPERF,' "$d/perf.txt" 2>/dev/null || echo 0)
    python3 -c "
import json; json.dump({'rep':$rep,'records':$recs,'secs':$SECS,'valid':$recs>0},open('$d/point.json','w'))"
    log "  rep $rep: $recs QGAPERF records over ${SECS}s idle"
done

log "=== idle present rate, $LABEL ==="
./scratchpad/idle-analyze.py "$OUT" "$LABEL" | tee "$OUT/REPORT.txt"
log "done - $OUT"
