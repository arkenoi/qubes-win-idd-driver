#!/bin/bash
# =============================================================================
# hitrate-ab.sh - per-window fast-path HIT RATE, focus raise off vs on
# =============================================================================
#
#   scratchpad/hitrate-ab.sh <vm> <label> [reps]
#
# Measures what the coalescing fix actually does, and whether z-order sync raises it:
#
#   hit rate = pwskip / (pwskip + pwcap)
#
# pwskip = per-window recaptures avoided because the window's screen bytes were provably
# unchanged; pwcap = recaptures issued. Both come from the QGAPERF record (v3). Before this
# pair existed the effect was uncountable: the fix incremented a file-static nothing read.
#
# THE TWO CONDITIONS, on ONE binary (registry DWORD FocusRaise, agent restarted between):
#   off - historic behaviour, SetForegroundWindow only
#   on  - plus BringWindowToTop, so guest z-order agrees with dom0 for the focused window
#
# Why this is the right experiment: PwScreenUnchanged refuses the fast path for any window
# covered by another (RectInRegion(rgnCoveredAbove)), so occlusion IS the ceiling on the fix.
# dom0 owns stacking and never tells the guest it; MSG_FOCUS is the only stacking-adjacent
# message that crosses. If focus-raise makes the guest agree with dom0 for the window the
# user is in, the ceiling lifts for exactly that window.
#
# A nil result is a RESULT, not a failure: SetForegroundWindow usually raises already, so the
# increment may be zero. That is worth knowing before anyone designs a restack message.
#
# Interleaved (rep outer, condition inner) per CLAUDE.md rule 2, agent hash asserted on both
# sides per rule 3, and every run's condition is read back out of the agent's own log rather
# than assumed.
set -u
cd /home/user/qubes-win-idd-driver

VM="${1:?usage: $0 <vm> <label> [reps]}"
LABEL="${2:?usage: $0 <vm> <label> [reps]}"
REPS="${3:-3}"
SECS="${SECS:-15}"

S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/hitrate-$LABEL"; mkdir -p "$OUT"
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

log(){ echo "$(date -u +%H:%M:%S) hitrate[$LABEL]: $*"; }
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

log "pushing harness + collector + switch"
qq push instrumentation/drag-harness.ps1 >/dev/null 2>&1
qq push instrumentation/collect-perf.ps1 >/dev/null 2>&1

measure(){  # measure <cond:off|on> <rep>
    local cond="$1" rep="$2" tag="$1-r$2"
    local d="$OUT/$tag"; mkdir -p "$d"
    echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false}" > "$d/point.json"

    local sw
    if [ "$cond" = on ]; then sw=$(qq pushrun ./scratchpad/set-focusraise.ps1 -On 2>&1 | clean)
    else                      sw=$(qq pushrun ./scratchpad/set-focusraise.ps1     2>&1 | clean); fi
    echo "$sw" > "$d/switch.txt"
    echo "$sw" | grep -aE "^QGAFOCUSRAISE=|^RESULT=" | sed 's/^/      /'
    echo "$sw" | grep -q "^RESULT=OK focusraise=$cond" || {
        log "  $tag: condition did not take - point voided"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"FocusRaise=$cond not confirmed by the agent log\"}" > "$d/point.json"
        return
    }
    sleep 8

    local h; h=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
    [ "$h" = "$AGENT_HASH" ] || {
        log "  $tag: agent hash changed ($h) - point voided"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"agent hash changed\"}" > "$d/point.json"; return
    }

    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\drag-harness.ps1 -DragSeconds $SECS -ScrollSeconds $SECS -TypeSeconds $SECS -IdleSeconds 3" 2>&1 | clean > "$d/harness.txt"

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
    # pwskip/pwcap only exist from PERF_RECORD_VERSION 3. If they are absent the build predates
    # the counters and no hit rate can be computed - that must fail loudly, not read as zero.
    local hasfields; hasfields=$(grep -ac 'pwskip=' "$d/perf.txt" 2>/dev/null || echo 0)
    if [ "$hasfields" -eq 0 ]; then
        log "  $tag: no pwskip/pwcap fields - this build cannot report a hit rate"
        echo "{\"cond\":\"$cond\",\"rep\":$rep,\"valid\":false,\"na\":\"build predates pwskip/pwcap (PERF_RECORD_VERSION < 3)\"}" > "$d/point.json"
        return
    fi
    python3 -c "
import json,sys
json.dump({'cond':'$cond','rep':$rep,'records':$recs,'valid':$recs>0},open('$d/point.json','w'))
"
    log "  $tag: $recs QGAPERF records"
}

log "=== 2 conditions x $REPS reps, interleaved ==="
for rep in $(seq 1 "$REPS"); do
    for cond in off on; do
        log "rep $rep / FocusRaise=$cond"
        measure "$cond" "$rep"
    done
done

log "restoring FocusRaise=off (the shipped default)"
qq pushrun ./scratchpad/set-focusraise.ps1 2>&1 | clean | grep -aE "^RESULT=" | sed 's/^/    /'

log "=== analysis ==="
./scratchpad/hitrate-analyze.py "$OUT" | tee "$OUT/REPORT.txt"
log "done - $OUT"
