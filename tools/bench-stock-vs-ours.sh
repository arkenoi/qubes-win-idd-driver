#!/usr/bin/env bash
# Single-variable stock-vs-ours gui-agent CPU benchmark, unattended.
#
# ONE guest, ONE install, ONE display stack, ONE workload. The only thing that changes between
# sides is gui-agent.exe, swapped in place. That is what makes this the authoritative comparison
# in docs/BENCHMARKS.md and the four-install table historical: those cells differed in install
# AND display stack, so they cannot carry a claim about the agent.
#
#   tools/bench-stock-vs-ours.sh <stock-agent.exe> <ours-agent.exe> [rounds]
#
# Both binaries are built by the SAME CI job from the same toolchain and pinned dependencies -
# stock from the fork's upstream merge-base, ours from HEAD - so the compiler is not a variable
# either. A vendor-signed binary built elsewhere would reintroduce one.
#
# RULES THIS ENFORCES, because each of them has already been broken here at least once:
#  - vm_lock: two harnesses on one guest interleave their probes and fabricate verdicts.
#  - INTERLEAVED, and the starting side alternates per round, so drift in the guest (thermal,
#    background work, a service waking up) cannot land entirely on one side.
#  - The RUNNING binary's hash is compared to the one that was pushed, every single run. A
#    harness that proceeds on a failed swap reports numbers for a build that never ran.
#  - MISSING DATA FAILS: a run that cannot be parsed, or whose sampler produced too little, is
#    recorded INVALID and excluded - never coerced to zero.
#  - The scene is checked by PIXELS once per run. A wedged Notepad (title strip drawn, client
#    area white, typing invisible) faked two regressions here on 2026-08-12; it survives agent
#    restarts and binary swaps, so nothing in the agent's own output can detect it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/mgmt/harness/vmlock.sh"

STOCK="${1:?usage: $0 <stock-agent.exe> <ours-agent.exe> [rounds]}"
OURS="${2:?usage: $0 <stock-agent.exe> <ours-agent.exe> [rounds]}"
ROUNDS="${3:-3}"
VM="${QTEST_VM:?set QTEST_VM to the guest to benchmark}"
IN='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
OUTDIR="$HERE/instrumentation/bench-stock-vs-ours-$(date -u +%Y%m%d-%H%M%S)"

vm_lock "$VM"
mkdir -p "$OUTDIR"
echo "== stock-vs-ours on $VM, $ROUNDS rounds, out=$OUTDIR"

qt() { "$HERE/tools/qtest" "$@"; }
hash16() { sha256sum "$1" | cut -c1-16 | tr 'a-f' 'A-F'; }

STOCK_H="$(hash16 "$STOCK")"; OURS_H="$(hash16 "$OURS")"
echo "   stock=$STOCK_H  ours=$OURS_H"
[ "$STOCK_H" = "$OURS_H" ] && { echo "FATAL: both sides are the same binary"; exit 2; }

cp "$STOCK" "$OUTDIR/agent-stock.exe"; cp "$OURS" "$OUTDIR/agent-ours.exe"
qt push "$HERE/guest/swap-agent.ps1" "$HERE/guest/phase-cpu-bench.ps1" \
        "$HERE/instrumentation/drag-harness.ps1" >/dev/null 2>&1

# --- one repetition: swap the named side in, verify it is running, run the workload ----------
run_side() {  # run_side <side> <exe> <expected-hash> <round>
    local side="$1" exe="$2" want="$3" round="$4"
    local tag="r${round}-${side}"
    echo "-- $tag"

    qt push "$exe" >/dev/null 2>&1
    local swap; swap="$(qt run "powershell -NoProfile -ExecutionPolicy Bypass -File $IN\\swap-agent.ps1 -NewAgent $IN\\$(basename "$exe")" 2>&1)"
    printf '%s\n' "$swap" > "$OUTDIR/$tag.swap"
    local got; got="$(printf '%s\n' "$swap" | grep -oE 'HASH_RUNNING=[0-9A-F]+' | cut -d= -f2)"
    if [ "$got" != "$want" ]; then
        echo "   INVALID: running hash '$got' != expected '$want' - not benchmarking a build that is not running"
        echo "{\"valid\":false,\"why\":[\"swap did not land: running=$got want=$want\"]}" > "$OUTDIR/$tag.json"
        return 1
    fi
    echo "   running $got"

    # SETTLE. Not cosmetic: swapping between two DIFFERENT agents forces a full
    # re-establishment - re-enumeration, per-window capture channels, buffers, grants - and our
    # startup is heavier than stock's, so a short settle biases against whichever side was just
    # swapped in. Measured 2026-09-01: with an 8 s settle, ours' win11 drag read 18.3-21.7,
    # while the same binary at the same defaults in a session with no cross-agent swap read
    # 13.3-16.3. Between-session variance larger than the within-session spread is exactly what
    # a disjoint-ranges verdict cannot survive, so the settle is now long enough for the
    # transient to be over, and overridable for anyone re-testing that claim.
    sleep "${BENCH_SETTLE_S:-45}"

    qt run "powershell -NoProfile -ExecutionPolicy Bypass -File $IN\\phase-cpu-bench.ps1" \
        > "$OUTDIR/$tag.raw" 2>&1
    python3 "$HERE/tools/bench-phase-cpu.py" "$OUTDIR/$tag.raw" > "$OUTDIR/$tag.json" 2>&1
    local rc=$?

    # PIXELS, not logs: prove the scene the numbers came from was actually rendering.
    qt shot "$OUTDIR/$tag.tar" >/dev/null 2>&1
    python3 "$HERE/tools/bench-scene-check.py" "$OUTDIR/$tag.tar" "$OUTDIR/$tag.json"
    python3 -c "import json,sys;o=json.load(open('$OUTDIR/$tag.json'));print('   ',{k:v.get('pct_core') for k,v in o.get('phases',{}).items()},'valid=',o.get('valid'),o.get('scene',''))"
    return $rc
}

for r in $(seq 1 "$ROUNDS"); do
    # Alternate which side goes first, so an ordering effect cannot bias one side.
    if [ $((r % 2)) -eq 1 ]; then
        run_side stock "$OUTDIR/agent-stock.exe" "$STOCK_H" "$r"
        run_side ours  "$OUTDIR/agent-ours.exe"  "$OURS_H"  "$r"
    else
        run_side ours  "$OUTDIR/agent-ours.exe"  "$OURS_H"  "$r"
        run_side stock "$OUTDIR/agent-stock.exe" "$STOCK_H" "$r"
    fi
done

echo "== summary"
python3 "$HERE/tools/bench-summarise.py" "$OUTDIR" | tee "$OUTDIR/SUMMARY.txt"
echo "raw data: $OUTDIR"
