#!/usr/bin/env bash
# Attribute OUR extra CPU cost to specific fork mechanisms, one binary, knobs only.
#
#   tools/bench-ablate.sh [rounds]
#
# WHY THIS AND NOT A STOCK COMPARISON. stock-vs-ours says how much we cost against upstream;
# it cannot say WHICH of our mechanisms is spending it, because the two sides differ by
# thousands of lines. This varies ONE registry switch at a time on ONE binary, so a difference
# can only come from the mechanism that switch controls. The 2026-08-10 SweepDdaExempt result
# was established exactly this way - an A/B on one binary with the defect deliberately
# re-introduced as the control - and that is the strongest form of evidence this project has.
#
# Rounds are INTERLEAVED across configurations, not run in blocks, for the same reason the
# stock comparison is: guest drift must not land on one configuration.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/mgmt/harness/vmlock.sh"

ROUNDS="${1:-3}"
VM="${QTEST_VM:?set QTEST_VM}"
IN='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
KEY='HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
OUTDIR="$HERE/instrumentation/bench-ablate-$(date -u +%Y%m%d-%H%M%S)"

vm_lock "$VM"
mkdir -p "$OUTDIR"
qt() { "$HERE/tools/qtest" "$@"; }

# name:knob=value,... — "base" changes nothing and is the control every round is compared to.
CONFIGS=(
  "base:"
  "noslice:InputDragSlice=0"
  "noevtprio:DragEventPriority=0"
  "nofreeze:InputDragFreezeContent=0"
  "nopw:PerWindowCapture=0"
)

echo "== ablation on $VM, $ROUNDS rounds, out=$OUTDIR"
qt push "$HERE/guest/phase-cpu-bench.ps1" "$HERE/instrumentation/drag-harness.ps1" >/dev/null 2>&1

# Every knob any configuration touches, reset before each run, so a configuration can never
# inherit a switch the previous one set. Forgetting this is how a "ladder" measures itself.
ALL_KNOBS=(InputDragSlice DragEventPriority InputDragFreezeContent PerWindowCapture)

run_cfg() {  # run_cfg <name> <knobspec> <round>
    local name="$1" spec="$2" round="$3" tag="r${3}-${1}"
    local cmd=""
    for k in "${ALL_KNOBS[@]}"; do
        cmd+="reg delete \"$KEY\" /v $k /f >nul 2>&1 & "
    done
    if [ -n "$spec" ]; then
        local IFS=','
        for kv in $spec; do
            cmd+="reg add \"$KEY\" /v ${kv%%=*} /t REG_DWORD /d ${kv##*=} /f >nul & "
        done
    fi
    cmd+="echo KNOBS_SET"
    qt run "$cmd" > "$OUTDIR/$tag.knobs" 2>&1
    grep -q KNOBS_SET "$OUTDIR/$tag.knobs" || { echo "   INVALID: knob write failed"; return 1; }

    # Config is read at agent Init, so the agent must be restarted for it to be in force.
    qt run "powershell -NoProfile -Command \"Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 12\"" >/dev/null 2>&1
    sleep 6

    qt run "powershell -NoProfile -ExecutionPolicy Bypass -File $IN\\phase-cpu-bench.ps1" \
        > "$OUTDIR/$tag.raw" 2>&1
    python3 "$HERE/tools/bench-phase-cpu.py" "$OUTDIR/$tag.raw" > "$OUTDIR/$tag.json" 2>&1
    qt shot "$OUTDIR/$tag.tar" >/dev/null 2>&1
    python3 "$HERE/tools/bench-scene-check.py" "$OUTDIR/$tag.tar" "$OUTDIR/$tag.json"
    python3 -c "
import json;o=json.load(open('$OUTDIR/$tag.json'))
d=o.get('phases',{}).get('drag',{}).get('pct_core')
print('   $tag drag=',d,'valid=',o.get('valid'),o.get('scene',''))"
}

for r in $(seq 1 "$ROUNDS"); do
    for c in "${CONFIGS[@]}"; do
        echo "-- r$r ${c%%:*}"
        run_cfg "${c%%:*}" "${c#*:}" "$r"
    done
done

# Leave the guest on shipped defaults: an ablation that leaves a knob set poisons whatever
# runs next on this guest, and the next thing is usually someone judging by feel.
qt run "$(for k in "${ALL_KNOBS[@]}"; do printf 'reg delete "%s" /v %s /f >nul 2>&1 & ' "$KEY" "$k"; done)echo RESTORED" >/dev/null 2>&1
qt run "powershell -NoProfile -Command \"Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force\"" >/dev/null 2>&1

echo "== summary (drag, % of one core)"
python3 "$HERE/tools/bench-ablate-summary.py" "$OUTDIR" | tee "$OUTDIR/SUMMARY.txt"
