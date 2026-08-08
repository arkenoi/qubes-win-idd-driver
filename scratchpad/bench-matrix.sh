#!/bin/bash
# FOUR-ROW BENCHMARK MATRIX: {stock,ours} x {win10,win11}.
#
# Guests are all POLICY-KNOWN names, so dom0's per-window screenshot service serves them and
# no dom0 change is needed. Nothing here uses sudo.
#
#   stock win10 -> win10-e2e        ours win10 -> win10-clean
#   stock win11 -> win11-idd-test   ours win11 -> win11-fresh
#
# Rules this obeys, each learned the hard way on this project:
#  * INTERLEAVED by rep across all four configs, never four blocks. Scene state drifts
#    between blocks and a bimodal metric already voided a bisect here.
#  * ONE guest running at a time. Two 8 GB Windows guests concurrently is the memory
#    pressure that forced an earlier retraction.
#  * The running agent hash is verified before EVERY rep; a mismatch or an unreadable hash
#    DISCARDS the rep rather than quietly contributing a number.
#  * Results are kept per platform because benchmark.sh only knows the side labels
#    stock|ours|base and writes to $OUTDIR/$side-r$N.
#  * The verdict is withheld below MINREPS valid reps in ANY of the four cells.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
REPS="${REPS:-3}"
MINREPS="${MINREPS:-3}"
OURS_HASH=$(python3 -c "
import json;print(json.load(open('artifacts-final/MANIFEST.json'))['reference_binaries']['gui-agent.exe'][:16].upper())" 2>/dev/null)
STOCK_HASH="${STOCK_HASH:-3D2E6BCEC9F5BD89}"
[ -n "$OURS_HASH" ] || { echo "ABORT: cannot resolve our expected agent hash"; exit 4; }

# label  vm              side   outdir                    expected-hash
CONFIGS=(
  "stock-win10 win10-e2e      stock $S/bm-win10 $STOCK_HASH"
  "ours-win10  win10-clean    ours  $S/bm-win10 $OURS_HASH"
  "stock-win11 win11-idd-test stock $S/bm-win11 $STOCK_HASH"
  "ours-win11  win11-fresh    ours  $S/bm-win11 $OURS_HASH"
)
ALL_VMS="win10-e2e win10-clean win11-idd-test win11-fresh"

log(){ echo "$(date -u +%H:%M:%S) matrix: $*"; }
qq(){ QTEST_VM="$1" timeout "${QT:-120}" ./tools/qtest "${@:2}"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

solo_up(){ # $1 = vm to bring up, everything else down
  local want=$1 v
  for v in $ALL_VMS; do
    [ "$v" = "$want" ] && continue
    [ "$(state $v)" = Running ] && { log "stopping $v (one guest at a time)"; timeout 240 qvm-shutdown --wait "$v" >/dev/null 2>&1 || timeout 60 qvm-kill "$v" >/dev/null 2>&1; }
  done
  [ "$(state $want)" = Running ] || { log "starting $want"; timeout 150 qvm-start "$want" >/dev/null 2>&1; }
  local t0=$(date +%s)
  while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
    qq "$want" run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && { sleep 30; return 0; }
    sleep 20
  done
  return 1
}

verify_agent(){ # vm want
  local vm=$1 want=$2 out got alive tries=0
  while [ $tries -lt 12 ]; do
    out=$(qq "$vm" pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | tr -d '\r')
    got=$(echo "$out"  | grep -oE '^AGENTHASH=[0-9A-F]{16}' | head -1 | cut -d= -f2)
    alive=$(echo "$out"| grep -oE '^AGENTPROC=(ALIVE|DEAD)'  | head -1 | cut -d= -f2)
    [ -n "$got" ] && [ "$alive" = ALIVE ] && break
    tries=$((tries+1)); sleep 10
  done
  [ -n "$got" ]        || { log "  HASH UNREADABLE on $vm - rep DISCARDED"; return 1; }
  [ "$alive" = ALIVE ] || { log "  gui-agent NOT RUNNING on $vm - rep DISCARDED"; return 1; }
  [ "$got" = "$want" ] || { log "  HASH MISMATCH on $vm: $got != $want - rep DISCARDED"; return 1; }
  log "  $vm verified ($got, alive)"; return 0
}

log "=== four-row matrix: $REPS reps x 4 configs, interleaved, one guest at a time ==="
declare -A OK
for cfg in "${CONFIGS[@]}"; do set -- $cfg; OK[$1]=0; done

for r in $(seq 1 "$REPS"); do
  for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    label=$1 vm=$2 side=$3 outdir=$4 want=$5
    log "--- rep $r  $label  ($vm) ---"
    case " $ALL_VMS " in *" $vm "*) ;; *) log "ABORT: '$vm' is not one of the four guests"; exit 3 ;; esac
    solo_up "$vm"        || { log "  $vm did not come up - rep SKIPPED"; continue; }
    verify_agent "$vm" "$want" || continue
    # --expect-hash so benchmark.sh does its OWN verification and records hash_verified in
    # rep.json. Without it the previous run stamped every rep UNVERIFIED-HASH and compare
    # refused a verdict: "it is NOT proven that the build under test was installed".
    if QTEST_VM=$vm BENCH_OUT=$outdir ./scratchpad/benchmark.sh run "$side" --rep "$r" --expect-hash "$want" 2>&1 | tail -4; then
      OK[$label]=$(( ${OK[$label]} + 1 ))
      log "  $label rep $r OK (${OK[$label]} valid so far)"
    else
      log "  $label rep $r FAILED in benchmark.sh"
    fi
  done
done

log "=== valid reps per cell ==="
short=0
for cfg in "${CONFIGS[@]}"; do
  set -- $cfg
  log "  $1: ${OK[$1]}/$REPS"
  [ "${OK[$1]}" -lt "$MINREPS" ] && short=1
done
if [ "$short" = 1 ]; then
  log "VERDICT WITHHELD: at least one cell has fewer than $MINREPS valid reps"
fi

log "=== four-row table ==="
python3 ./scratchpad/matrix-table.py "$S/bm-win10" "$S/bm-win11" 2>&1
