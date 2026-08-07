#!/bin/bash
# Interleaved benchmark: STOCK QWT vs OUR build, on two SEPARATE clean E2E installs.
#
# DESIGN NOTES (each one is a rule this project learned the hard way):
#
#  * INTERLEAVED at rep level: stock,ours,stock,ours,... never all-of-one-then-the-other.
#    A bimodal metric that was repeatable within a run inverted when interleaved and voided
#    a whole bisect here. Back-to-back full sides do NOT satisfy that.
#  * ONE guest running at a time. Two 8 GB Windows guests concurrently is the memory
#    pressure that already forced a retraction on this host. Alternation costs a
#    shutdown/start per rep (~2-4 min); running them together costs correctness.
#  * HASH VERIFIED before every rep. A harness that proceeds on a failed install reports
#    numbers for a build that was never running.
#  * Scene generator must run in the INTERACTIVE session: a session-0 load made both sides
#    read 0.05 % and produced a meaningless comparison.
#  * CROSS-SIDE metrics only in the verdict. QGAPERF rows are ours-only BY CONSTRUCTION
#    (stock emits no per-frame instrumentation), so they are never a delta.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
REPS="${REPS:-3}"
STOCK_VM=win10-stock
OURS_VM=win10-clean          # already carries our build from the all-three acceptance
STOCK_AGENT_HASH=3D2E6BCEC9F5BD89
log(){ echo "$(date -u +%H:%M:%S) bench: $*" | tee -a "$S/bench-interleaved.log"; }

state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

# Bring VM up, everything else down. Returns only when qrexec answers.
solo_up(){
  local want=$1 other=$2
  if [ "$(state "$other")" = Running ]; then
    log "stopping $other (one guest at a time)"
    timeout 240 qvm-shutdown --wait "$other" >/dev/null 2>&1 || timeout 60 qvm-kill "$other" >/dev/null 2>&1
  fi
  [ "$(state "$want")" = Running ] || { log "starting $want"; timeout 150 qvm-start "$want" >/dev/null 2>&1; }
  local t0=$(date +%s)
  while [ $(( $(date +%s)-t0 )) -lt 420 ]; do
    QTEST_VM=$want timeout 25 ./tools/qtest run 'echo OK' 2>&1 | tr -d '\r\0' | grep -q OK && { log "$want up"; return 0; }
    sleep 20
  done
  log "FAIL: $want never answered qrexec"; return 1
}

# The running agent must be the build we think it is - else the rep is discarded, not fudged.
verify_hash(){
  local vm=$1 want=$2
  local got
  got=$(QTEST_VM=$vm timeout 90 ./tools/qtest run \
    'powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 ((Get-Process gui-agent -EA 0).Path | Select -First 1)).Hash.Substring(0,16)"' \
    2>/dev/null | tr -d '\r' | grep -oE '^[0-9A-F]{16}$' | head -1)
  if [ -z "$got" ]; then log "HASH UNREADABLE on $vm - rep DISCARDED (missing data fails)"; return 1; fi
  if [ "$got" != "$want" ]; then log "HASH MISMATCH on $vm: running=$got want=$want - rep DISCARDED"; return 1; fi
  log "$vm agent hash OK ($got)"; return 0
}

[ "$(state $STOCK_VM)" ] || { log "ABORT: $STOCK_VM does not exist - build the stock side first (loop8 = answer-stock.iso)"; exit 1; }

log "=== interleaved run: $REPS reps per side, one guest at a time ==="
ok_stock=0; ok_ours=0
for r in $(seq 1 "$REPS"); do
  for side in stock ours; do
    if [ "$side" = stock ]; then vm=$STOCK_VM other=$OURS_VM want=$STOCK_AGENT_HASH
    else vm=$OURS_VM other=$STOCK_VM
         want=$(python3 -c "
import json;print(json.load(open('artifacts-all3/MANIFEST.json'))['files']['gui-agent.exe']['sha256'][:16].upper())" 2>/dev/null || echo UNKNOWN)
    fi
    log "--- rep $r side=$side ---"
    solo_up "$vm" "$other" || { log "rep $r/$side SKIPPED (guest down)"; continue; }
    verify_hash "$vm" "$want" || { log "rep $r/$side SKIPPED (hash)"; continue; }
    if BENCH_SIDE=$side BENCH_VM=$vm BENCH_REP=$r ./scratchpad/benchmark.sh run "$side" 2>&1 | tail -5; then
      [ "$side" = stock ] && ok_stock=$((ok_stock+1)) || ok_ours=$((ok_ours+1))
    else
      log "rep $r/$side FAILED in benchmark.sh"
    fi
  done
done

log "completed reps: stock=$ok_stock ours=$ok_ours (of $REPS each)"
if [ "$ok_stock" -lt 3 ] || [ "$ok_ours" -lt 3 ]; then
  log "VERDICT WITHHELD: fewer than 3 valid reps per side. CLAUDE.md requires >=3 interleaved."
  exit 2
fi
log "=== compare (cross-side metrics only) ==="
./scratchpad/benchmark.sh compare 2>&1 | tail -40
