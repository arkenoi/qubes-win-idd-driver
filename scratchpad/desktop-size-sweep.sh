#!/bin/bash
# =============================================================================
# desktop-size-sweep.sh - does guest cost scale with DESKTOP AREA?
# =============================================================================
#
#   scratchpad/desktop-size-sweep.sh win11-idd-test win11
#   scratchpad/desktop-size-sweep.sh win-idd-test   win10
#
# Kill-first experiment for DESIGN-nonoccluding-desktop.md. The non-occluding ("RDP-like")
# design would tile every window into its own slot on one large desktop, so the composited
# surface becomes the SUM of window areas instead of the screen area. The user's objection:
# resource allocation that depends on overall desktop size could produce weird performance
# impacts. If cost scales with desktop area, single-giant-desktop tiling is dead before any
# coordinate work is attempted.
#
# WHY THIS IS A VALID CONTROLLED EXPERIMENT
# instrumentation/drag-harness.ps1 is resolution-INDEPENDENT in everything that generates
# damage: the Notepad window is a fixed 800x600 (`$w = 800; $h = 600`), the drag is a fixed
# -radius circle, and scroll/type happen inside that fixed window. Only the window's centred
# POSITION follows the screen. So the damaged area per frame is constant across the sweep and
# DESKTOP AREA IS THE ONLY VARIABLE. This is the property that makes the numbers attributable;
# if the harness ever starts sizing windows from the screen, this script stops being valid.
#
# WHAT IS EXPECTED TO MOVE, IF ANYTHING (prediction recorded before the run)
#   acq  - AcquireNextFrame. Most likely to scale: the desktop image is desktop-sized.
#   frames/present rate - if DWM does more full-target passes on a bigger target.
#   agent CPU - the aggregate.
# Expected NOT to move: dmg/snd (damage-proportional), area (constant by construction).
#
# METHOD
#   - one reboot to register the mode list (the driver reads it at monitor arrival), then
#     each mode is applied at runtime with modeprobe --apply; no reboot per point;
#   - modeprobe re-reads ENUM_CURRENT_SETTINGS and this script ABORTS the point if readback
#     != request, so no measurement is ever attributed to a mode that did not take;
#   - reps are INTERLEAVED (rep outer, mode inner) per CLAUDE.md rule 2, so a drift in guest
#     state cannot masquerade as a mode effect;
#   - the agent hash is re-asserted at every point (rule 3): one binary throughout;
#   - a mode that fails to apply is RECORDED as a failed point, not skipped silently - "the
#     desktop cannot go that large" is itself a finding about the tiling design (rule 4).
set -u
cd /home/user/qubes-win-idd-driver

VM="${1:?usage: $0 <vm> <label> [reps]}"
LABEL="${2:?usage: $0 <vm> <label> [reps]}"
REPS="${3:-3}"
SECS="${SECS:-12}"
MODES=(1920x1080 2560x1440 3440x1440 5120x2160 7680x4320)

S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/sweep-$LABEL"
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
mkdir -p "$OUT"

log(){ echo "$(date -u +%H:%M:%S) sweep[$LABEL]: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-240}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }
clean(){ tr -d '\r\0'; }

wait_up(){
    local t0=$(date +%s) lim="${1:-900}"
    while [ $(( $(date +%s)-t0 )) -lt "$lim" ]; do
        qq run 'echo UP' 2>&1 | clean | grep -q UP && { log "up after $(( $(date +%s)-t0 ))s"; return 0; }
        [ "$(state "$VM")" = Halted ] && { log "halted -> restarting"; timeout 150 qvm-start "$VM" >/dev/null 2>&1; }
        sleep 20
    done
    return 1
}

# --- serialize: a second Windows qube contaminates every timing ------------------------
for v in win10-clean win10-e2e win11-fresh win11-idd-test win-idd-test; do
    [ "$v" = "$VM" ] && continue
    [ "$(state "$v")" = Running ] && {
        log "stopping $v (timings must not be shared)"
        timeout 240 qvm-shutdown --wait "$v" >/dev/null 2>&1 || timeout 60 qvm-kill "$v" >/dev/null 2>&1
    }
done
[ "$(state "$VM")" = Running ] || { log "starting $VM"; timeout 150 qvm-start "$VM" >/dev/null 2>&1; }
wait_up 900 || { log "ABORT: $VM never answered"; exit 1; }
sleep 25

# --- the sweep needs the IDD: the BDA's mode list is fixed and cannot reach these sizes --
log "display config:"
qq pushrun "$S/iddstate.ps1" 2>&1 | clean | grep -aE "^VC |^SCREEN " | tee "$OUT/config.txt" | sed 's/^/    /'
grep -q "IddSampleDriver Device avail=3" "$OUT/config.txt" || {
    log "ABORT: the IDD is not active on $VM - the BDA's fixed mode list cannot span this sweep"
    exit 1
}

AGENT_HASH=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
[ -n "$AGENT_HASH" ] || { log "ABORT: could not read the agent hash"; exit 1; }
log "agent=$AGENT_HASH (asserted identical at every point)"

# --- register the mode list, then reboot so the monitor re-arrives with it --------------
log "registering sweep modes: ${MODES[*]}"
reg=$(qq pushrun ./scratchpad/sweep-modes.ps1 "-Modes $(IFS=,; echo "${MODES[*]}")" 2>&1 | clean)
echo "$reg" | grep -aE "^REGMODE=|^RESULT=" | sed 's/^/    /'
echo "$reg" | grep -q "^RESULT=OK" || { log "ABORT: mode registration failed (see above)"; exit 1; }

log "rebooting so the IDD monitor re-arrives with the new mode list"
qq run 'shutdown /r /t 0' >/dev/null 2>&1
sleep 45
wait_up 900 || { log "ABORT: $VM did not come back after the mode-list reboot"; exit 1; }
sleep 30

log "pushing harness, collector and modeprobe"
qq push instrumentation/drag-harness.ps1 >/dev/null 2>&1
qq push instrumentation/collect-perf.ps1 >/dev/null 2>&1
MP=$(find artifacts artifacts-t2 artifacts-rel artifacts-all3 -name modeprobe.exe -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$MP" ]; then qq push "$MP" >/dev/null 2>&1; log "modeprobe pushed from $MP"
else log "NOTE: no local modeprobe.exe - relying on the one already installed in the guest"; fi

# --- what modes does the driver ACTUALLY offer now? ------------------------------------
qq run "$INC\\modeprobe.exe" 2>&1 | clean > "$OUT/modelist.txt" || true
log "driver offers $(grep -ac 'x' "$OUT/modelist.txt" 2>/dev/null || echo 0) mode lines (saved)"

# =======================================================================================
# measurement
# =======================================================================================
measure(){  # measure <mode> <rep>
    local mode="$1" rep="$2" tag="$1-r$2" px
    px=$(( ${mode%x*} * ${mode#*x} ))
    local d="$OUT/$tag"; mkdir -p "$d"
    echo "{\"mode\":\"$mode\",\"rep\":$rep,\"pixels\":$px,\"valid\":false}" > "$d/point.json"

    # apply + READ BACK. modeprobe emits JSON carrying "readback" (what Windows actually made
    # current, never the request) and "match". The gate is that field, parsed as data - not a
    # grep for a hopeful substring, and not the qrexec exit status, which does not survive the
    # transport reliably.
    local ap; ap=$(qq run "$INC\\modeprobe.exe --apply $mode" 2>&1 | clean)
    echo "$ap" > "$d/apply.txt"
    if ! python3 - "$d/apply.txt" "${mode%x*}" "${mode#*x}" <<'PY'
import json, re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
w, h = int(sys.argv[2]), int(sys.argv[3])
for m in re.finditer(r'\{.*\}', txt, re.S):
    try:
        j = json.loads(m.group(0))
    except Exception:
        continue
    rb = j.get("readback") or {}
    if j.get("match") is True and rb.get("w") == w and rb.get("h") == h:
        sys.exit(0)
sys.exit(1)
PY
    then
        log "  $tag: mode did NOT apply - recorded as a failed point"
        echo "{\"mode\":\"$mode\",\"rep\":$rep,\"pixels\":$px,\"valid\":false,\"na\":\"mode did not apply\"}" > "$d/point.json"
        return
    fi
    sleep 6

    # the running binary must still be the one measured at every other point
    local h; h=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | clean | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
    if [ "$h" != "$AGENT_HASH" ]; then
        log "  $tag: agent hash changed ($h != $AGENT_HASH) - point voided"
        echo "{\"mode\":\"$mode\",\"rep\":$rep,\"pixels\":$px,\"valid\":false,\"na\":\"agent hash changed\"}" > "$d/point.json"
        return
    fi

    local c0 c1
    c0=$(qq pushrun ./scratchpad/bench-probe.ps1 2>/dev/null | clean | grep -oE 'agent_cpu_ms=[0-9]+' | cut -d= -f2 | head -1)

    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\drag-harness.ps1 -DragSeconds $SECS -ScrollSeconds $SECS -TypeSeconds $SECS -IdleSeconds 3" 2>&1 | clean > "$d/harness.txt"

    c1=$(qq pushrun ./scratchpad/bench-probe.ps1 2>/dev/null | clean | grep -oE 'agent_cpu_ms=[0-9]+' | cut -d= -f2 | head -1)

    # one windowed collection spanning the whole measured run; per-phase slicing is done
    # locally by analyze-perf.py, which costs no extra guest round-trips
    local since until
    since=$(grep -aE "PHASE-START +drag" "$d/harness.txt" | tail -1 | awk '{print $NF}')
    until=$(grep -aE "PHASE-END +type"  "$d/harness.txt" | tail -1 | awk '{print $NF}')
    if [ -z "$since" ] || [ -z "$until" ]; then
        log "  $tag: no phase boundaries - refusing an unbounded collection"
        echo "{\"mode\":\"$mode\",\"rep\":$rep,\"pixels\":$px,\"valid\":false,\"na\":\"harness produced no phase markers\"}" > "$d/point.json"
        return
    fi
    qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\collect-perf.ps1 -Since $since -Until $until" 2>&1 | clean \
        | sed -n '/===PERFSTART===/,/===PERFEND===/p' > "$d/perf.txt"

    local recs; recs=$(grep -ac 'QGAPERF,' "$d/perf.txt" 2>/dev/null || echo 0)
    local cpu=""; [ -n "${c0:-}" ] && [ -n "${c1:-}" ] && cpu=$(( c1 - c0 ))
    python3 - "$d" "$mode" "$rep" "$px" "${cpu:-null}" "$recs" <<'PY'
import json, sys
d, mode, rep, px, cpu, recs = sys.argv[1:7]
json.dump({"mode": mode, "rep": int(rep), "pixels": int(px),
           "cpu_ms": (None if cpu == "null" else int(cpu)),
           "records": int(recs), "valid": int(recs) > 0},
          open(d + "/point.json", "w"))
PY
    # keep the per-phase boundaries next to the data so the analyzer can slice
    grep -aE "PHASE-(START|END)" "$d/harness.txt" > "$d/phases.txt"
    log "  $tag: ${px} px, $recs QGAPERF records, agent cpu ${cpu:-?} ms"
}

log "=== sweep: ${#MODES[@]} modes x $REPS reps, interleaved (rep outer, mode inner) ==="
for rep in $(seq 1 "$REPS"); do
    for mode in "${MODES[@]}"; do
        log "rep $rep / mode $mode"
        measure "$mode" "$rep"
    done
done

log "restoring 3440x1440 (the baseline every other benchmark uses)"
qq run "$INC\\modeprobe.exe --apply 3440x1440" >/dev/null 2>&1

log "=== analysis ==="
./scratchpad/sweep-analyze.py "$OUT" | tee "$OUT/REPORT.txt"
log "done - $OUT"
