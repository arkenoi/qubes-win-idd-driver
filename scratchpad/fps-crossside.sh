#!/bin/bash
# Generic FPS test, measured on BOTH sides of the glass at once:
#   rendered_fps   what the guest painted        (guest-side, fps-test.ps1)
#   delivered_fps  what actually reached dom0    (dom0-side, distinct screenshots)
#   delivery_ratio delivered / rendered
#
# The ratio is the number that means something. Rendered fps mostly measures Windows' GDI
# and is nearly identical on both sides by construction; DELIVERED fps is the agent's
# capture and send path, which is the thing this project changes. Reporting rendered fps
# alone would look like a benchmark while measuring almost nothing we touch.
#
# Neither figure depends on our QGAPERF instrumentation, so unlike every other frame-rate
# number we have, this one is genuinely comparable against stock.
#
# Usage: fps-crossside.sh <vm> <label> [seconds] [mode]
set -u
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> <label> [seconds] [mode]}"
LABEL="${2:?}"
SECS="${3:-10}"
MODE="${4:-move}"
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/fps-$LABEL.json"
log(){ echo "$(date -u +%H:%M:%S) fps[$VM/$LABEL]: $*"; }

# --- dom0-side sampler: count DISTINCT frames while the guest animates ------------------
# Distinct, not total: identical consecutive captures mean nothing new arrived. Comparing
# checksums is what separates "dom0 received a new frame" from "the sampler ran again".
sample_dom0(){
    local secs=$1 dir="$S/fpsshot-$LABEL"
    rm -rf "$dir"; mkdir -p "$dir"
    local t0 n=0
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
        qrexec-client-vm dom0 local.WinFullScreen+"$VM" > "$dir/s$n.tar" 2>/dev/null </dev/null
        n=$((n+1))
    done
    local distinct
    distinct=$(for f in "$dir"/s*.tar; do
                   tar -xOf "$f" ./screen.png 2>/dev/null | sha256sum | cut -d' ' -f1
               done | sort -u | wc -l)
    echo "$n $distinct"
    rm -rf "$dir"
}

log "starting guest animation (${SECS}s, mode=$MODE)"
QTEST_VM="$VM" timeout $((SECS + 120)) ./tools/qtest pushrun ./scratchpad/fps-test.ps1 \
    -Seconds "$SECS" -Mode "$MODE" > "$S/fps-guest-$LABEL.txt" 2>&1 &
guest_pid=$!
sleep 3                                   # let the form come up before sampling
read -r samples distinct <<< "$(sample_dom0 $((SECS - 4)))"
wait $guest_pid 2>/dev/null || true

rendered=$(tr -d '\r' < "$S/fps-guest-$LABEL.txt" | grep -a 'FPSRESULT' | tail -1 | sed 's/^FPSRESULT //')
if [ -z "$rendered" ]; then
    log "FAIL: no FPSRESULT from the guest - refusing to emit a number"
    echo "{\"label\":\"$LABEL\",\"error\":\"no guest result\"}" > "$OUT"
    exit 1
fi
python3 - "$rendered" "$samples" "$distinct" "$SECS" "$LABEL" > "$OUT" <<'PY'
import json,sys
g=json.loads(sys.argv[1]); samples=int(sys.argv[2]); distinct=int(sys.argv[3])
secs=int(sys.argv[4]); label=sys.argv[5]
window=max(secs-4,1)
if 'error' in g:
    print(json.dumps({"label":label,"error":g['error']})); raise SystemExit(0)
delivered=round(distinct/window,2)
rendered=g.get('rendered_fps',0)
out={
 "label":label,"mode":g.get("mode"),
 "rendered_fps":rendered,
 "dom0_samples":samples,"dom0_distinct":distinct,"dom0_window_s":window,
 "delivered_fps":delivered,
 # Capped at 1.0: the dom0 sampler cannot observe faster than it samples, so a ratio above
 # 1 would be a sampling artefact, not a real surplus.
 "delivery_ratio":(round(min(delivered/rendered,1.0),3) if rendered else None),
 "sampler_limited": samples < distinct*1.2,
}
print(json.dumps(out))
PY
log "$(cat "$OUT")"
