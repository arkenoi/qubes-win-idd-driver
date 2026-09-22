#!/bin/bash
# age-rig.sh - reproduce the CONDITION every known stall shared: a long session that has spent an
# hour creating, booting, parking, restoring and destroying guests. Not load in the parallel sense
# - the serial rule stands, one guest at a time - but ACCUMULATED session state: domid churn, pool
# allocation and release, checkpoint create/restore, repeated domain construction.
#
# WHY. The stall has been seen three times (2026-09-12, 09-17, 09-22), always inside long
# multi-guest sessions, and never in a deliberate repetition. An A/B that cycles one operation on
# an idle rig holds that condition constant - Jev, 2026-09-22: `add-load-as-a-variable` 0.56,
# and the 11 clean idle runs are still worth something (`cycling_value` 0.91: they bound the idle
# per-run rate, which nobody had).
#
#   mgmt/harness/age-rig.sh [cycles] [golden]
#
# Each cycle: clone -> boot to session -> (every 3rd) park + unpark -> shut down -> remove.
# It records what actually aged: elapsed, the subject's domid (which only goes up), dom0 pool use.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
. mgmt/harness/shutdown-lib.sh
. mgmt/harness/e2e-wait.sh
N="${1:-25}"; GOLDEN="${2:-win11-qwt}"
VM=win11-age
OUT="scratchpad/age-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) age-rig: $*" | tee -a "$OUT/age.log"; }
pool(){ qvm-pool info vm-pool 2>/dev/null | awk '$1=="usage"{u=$2} $1=="size"{s=$2} END{if(s)printf "%.1f", 100*u/s}'; }
domid(){ timeout 60 python3 -c "
import qubesadmin
try: print(qubesadmin.Qubes().domains['$VM'].xid)
except Exception: print('')" 2>/dev/null; }

t0=$(date +%s)
say "aging $N cycles from $GOLDEN; pool at start: $(pool)%"
for i in $(seq 1 "$N"); do
  qvm-check "$VM" >/dev/null 2>&1 && { qwt_shutdown "$VM" 300 >/dev/null 2>&1 || timeout 120 qvm-kill "$VM" >/dev/null 2>&1; timeout 300 qvm-remove -f "$VM" >/dev/null 2>&1; }
  bash mgmt/clone-guest.sh "$GOLDEN" "$VM" >/dev/null 2>&1 || { say "cycle $i: clone FAILED - pool at $(pool)%"; break; }
  timeout 300 qvm-start "$VM" >/dev/null 2>&1 || { say "cycle $i: start FAILED"; continue; }
  # A boot that never reaches a session is itself worth knowing about, but it is not a stall of the
  # kind under study: record and carry on rather than aborting the aging.
  if w_session "$VM" 420 "age$i" "$OUT" say; then sess=ok; else sess=NO-SESSION; fi
  if [ $((i % 3)) = 0 ]; then
    bash mgmt/harness/checkpoint.sh park "$VM" >/dev/null 2>&1 && \
    bash mgmt/harness/checkpoint.sh unpark "$VM" >/dev/null 2>&1 && ck=parked || ck=park-failed
  else ck=-; fi
  say "cycle $i/$N: domid=$(domid) session=$sess checkpoint=$ck pool=$(pool)% elapsed=$(( ($(date +%s)-t0)/60 ))m"
  qwt_shutdown "$VM" 300 >/dev/null 2>&1 || timeout 120 qvm-kill "$VM" >/dev/null 2>&1
  timeout 300 qvm-remove -f "$VM" >/dev/null 2>&1
done
say "aged $N cycles in $(( ($(date +%s)-t0)/60 )) minutes; pool now $(pool)%"
