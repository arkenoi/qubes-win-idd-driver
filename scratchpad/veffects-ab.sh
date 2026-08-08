#!/bin/bash
# =============================================================================
# veffects-ab.sh - do Windows 11's desktop effects explain the extra presents?
# =============================================================================
#
#   scratchpad/veffects-ab.sh <vm> <label> [reps]
#
# THE QUESTION. Measured with agent, display path and resolution held constant, Windows 11
# presents ~1.88x more frames than Windows 10 for identical input (488 vs 259 over 20 s).
# The coalescing fix makes each redundant present cheaper. This asks whether the presents need
# to happen at all - i.e. whether they come from effects Windows 11 enables by default
# (Mica/acrylic transparency, window animations, fade/slide) that repaint a region over many
# frames with no user input behind them.
#
# If yes, a post-install registry tweak - the same delivery path as disable-hw-accel.ps1 -
# removes the overhead at the SOURCE rather than mitigating it, and is worth more than the
# coalescing fix. If no, that is equally worth knowing: it rules out the cheapest explanation
# and points the chase at DWM's composition cadence itself.
#
# METHOD. One guest, one binary, one resolution. The only thing that changes is the effects
# setting. Reps interleaved (rep outer, condition inner) so guest drift cannot masquerade as
# an effects difference; agent hash asserted at every point; explorer restarted after each
# switch because several of these settings are read at shell start rather than polled.
#
# HEADLINE METRIC is the present count (sum of QGAPERF `n` over the phase), NOT CPU - the
# hypothesis is about how many frames Windows generates, and CPU would confound that with how
# expensive each one is.
set -u
cd /home/user/qubes-win-idd-driver

VM="${1:?usage: $0 <vm> <label> [reps]}"
LABEL="${2:?usage: $0 <vm> <label> [reps]}"
REPS="${3:-3}"
SECS="${SECS:-15}"

S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/veffects-$LABEL"; mkdir -p "$OUT"
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

log(){ echo "$(date -u +%H:%M:%S) veffects[$LABEL]: $*"; }
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
sleep 20

AGENT_HASH=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
[ -n "$AGENT_HASH" ] || { log "ABORT: could not read the agent hash"; exit 1; }
log "agent=$AGENT_HASH"

log "config (resolution must not move across the A/B):"
qq pushrun "$S/iddstate.ps1" 2>&1 | clean | grep -aE "^VC |^SCREEN " | tee "$OUT/config.txt" | sed 's/^/    /'

qq push instrumentation/drag-harness.ps1 >/dev/null 2>&1
qq push instrumentation/collect-perf.ps1 >/dev/null 2>&1
qq push guest/disable-visual-effects.ps1 >/dev/null 2>&1

measure(){  # measure <cond:default|fast> <rep>
    local cond="$1" rep="$2" tag="$1-r$2"
    local d="$OUT/$tag"; mkdir -p "$d"
    echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false}" > "$d/point.json"

    local sw
    if [ "$cond" = fast ]; then sw=$(qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\disable-visual-effects.ps1" 2>&1 | clean)
    else                        sw=$(qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\disable-visual-effects.ps1 -Restore" 2>&1 | clean); fi
    echo "$sw" > "$d/switch.txt"
    echo "$sw" | grep -aE "^=== RESULT ===" | sed 's/^/      /'
    echo "$sw" | grep -q "mode=$( [ "$cond" = fast ] && echo performance || echo defaults )" || {
        log "  $tag: effects switch did not confirm - point voided"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"effects switch unconfirmed\"}" > "$d/point.json"
        return
    }

    # Several of these are read at shell start, not polled. Restart explorer rather than
    # assuming the setting took, and give DWM time to settle before measuring.
    qq run 'Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue' >/dev/null 2>&1
    sleep 12

    local h; h=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
    [ "$h" = "$AGENT_HASH" ] || {
        log "  $tag: agent hash changed ($h) - point voided"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"agent hash changed\"}" > "$d/point.json"; return
    }

    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\drag-harness.ps1 -DragSeconds $SECS -ScrollSeconds $SECS -TypeSeconds $SECS -IdleSeconds 5" 2>&1 | clean > "$d/harness.txt"

    local since until
    since=$(grep -aE "PHASE-START +drag" "$d/harness.txt" | tail -1 | awk '{print $NF}')
    until=$(grep -aE "PHASE-END +type"  "$d/harness.txt" | tail -1 | awk '{print $NF}')
    [ -n "$since" ] && [ -n "$until" ] || {
        log "  $tag: no phase markers - refusing an unbounded collection"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"no phase markers\"}" > "$d/point.json"; return
    }
    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\collect-perf.ps1 -Since $since -Until $until" 2>&1 | clean \
        | sed -n '/===PERFSTART===/,/===PERFEND===/p' > "$d/perf.txt"
    grep -aE "PHASE-(START|END)" "$d/harness.txt" > "$d/phases.txt"

    local recs; recs=$(grep -ac 'QGAPERF,' "$d/perf.txt" 2>/dev/null || echo 0)
    python3 -c "
import json
json.dump({'cond':'$cond','rep':$rep,'records':$recs,'valid':$recs>0},open('$d/point.json','w'))
"
    log "  $tag: $recs QGAPERF records"
}

log "=== 2 conditions x $REPS reps, interleaved ==="
for rep in $(seq 1 "$REPS"); do
    for cond in default fast; do
        log "rep $rep / effects=$cond"
        measure "$cond" "$rep"
    done
done

log "=== analysis ==="
./scratchpad/veffects-analyze.py "$OUT" | tee "$OUT/REPORT.txt"
log "done - $OUT"
