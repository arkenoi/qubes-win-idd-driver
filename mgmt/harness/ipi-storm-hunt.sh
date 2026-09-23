#!/bin/bash
# ipi-storm-hunt.sh - make the cross-processor wedge happen ON DEMAND, and A/B a fix against it.
#
# HYPOTHESIS: the wedge is a cross-processor call whose targets never answer (measured: a CPU
#   spinning at ntoskrnl polling KPRCB+0x2d80, the field KeIpiGenericCall touches, while another
#   CPU sits inside xen.sys). If that is the path, driving it hard should raise a 10-20 %
#   per-install failure into something reproducible. Jev 2026-09-23: `stress-the-cross-processor-
#   path` 0.63 as the cheapest way to prove any fix.
# BASELINE: the same guest, same package, storm NOT running - rounds alternate, so a wedge that
#   happens anyway is not miscredited to the storm.
# VARIABLE: the storm (and, with VCPUS=, the guest's processor count).
# INSTRUMENT: guest/ipi-storm.ps1 reports a CYCLE RATE every 10 s, so "the storm ran" is measured,
#   not assumed; the wedge oracle is the pair (qrexec dead) AND (domain cpu_time still advancing),
#   which is the fingerprint the specimens were identified by. On a wedge: dom0 forensics, and a
#   memory image for the FIRST wedge only (8.6 GB each).
# BUDGET: default 6 rounds x 180 s storm + 60 s quiet baseline each; about 30 minutes.
#
#   VM=<guest> mgmt/harness/ipi-storm-hunt.sh [rounds] [storm-seconds]
#   VCPUS=<n>  set the guest's processor count first (the fix candidate under test)
#
# A WEDGE HERE IS THE POINT, not a failure of the run: the guest is left RUNNING and captured.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${VM:?set VM to the guest to stress}"
ROUNDS="${1:-6}"; SECS="${2:-180}"
export QTEST_VM="$VM"
. mgmt/harness/vmlock.sh
vm_lock "$VM"
OUT="scratchpad/ipistorm-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) storm: $*" | tee -a "$OUT/run.log"; }

state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
cputime(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null >/dev/null; python3 - "$VM" <<'PY'
import sys
try:
    import qubesadmin
    vm = qubesadmin.Qubes().domains[sys.argv[1]]
    print(int(getattr(vm, "get_cputime", lambda: 0)() or 0))
except Exception:
    print(0)
PY
}
alive(){ timeout -k 5 45 ./tools/qtest run 'cmd /c echo PONG' 2>/dev/null | grep -qa PONG; }

if [ -n "${VCPUS:-}" ]; then
  [ "$(state)" = Halted ] || { qvm-shutdown "$VM" >/dev/null 2>&1; for _ in $(seq 1 18); do [ "$(state)" = Halted ] && break; sleep 10; done; }
  qvm-prefs "$VM" vcpus "$VCPUS" && say "vcpus set to $VCPUS (the fix candidate under test)"
fi
[ "$(state)" = Running ] || { say "starting $VM"; qvm-start "$VM" >/dev/null 2>&1; }
for _ in $(seq 1 30); do alive && break; sleep 10; done
alive || { say "TERMINAL: $VM never answered qrexec - nothing to stress"; exit 2; }
say "subject $VM up, vcpus=$(qvm-prefs "$VM" vcpus)"
timeout -k 5 120 ./tools/qtest push guest/ipi-storm.ps1 >/dev/null 2>&1 || { say "TERMINAL: push failed"; exit 2; }

wedged=0; core_taken=0
check_wedge(){ # $1=tag ; 0 = healthy, 1 = wedged (captured)
  alive && return 0
  local c1 c2
  c1=$(cputime); sleep 20; c2=$(cputime)
  if [ "${c2:-0}" -gt "${c1:-0}" ]; then
    say "WEDGE at $1: qrexec dead and cpu_time still advancing ($c1 -> $c2) - the specimen fingerprint"
    local d="$OUT/wedge-$1"; mkdir -p "$d"
    timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$VM" </dev/null > "$d/forensics.tar" 2>"$d/err" \
      && say "  forensics -> $d"
    if [ "$core_taken" = 0 ] && bash mgmt/harness/fetch-wedge-core.sh "$VM" "$d/guest.core" >>"$d/core.log" 2>&1; then
      core_taken=1; say "  memory image -> $d/guest.core"
    fi
    wedged=1
    return 1
  fi
  say "  $1: qrexec not answering but cpu_time is NOT advancing ($c1 -> $c2) - NOT the wedge fingerprint"
  return 0
}

for r in $(seq 1 "$ROUNDS"); do
  say "round $r/$ROUNDS: QUIET baseline ${SECS}s (no storm)"
  sleep "$SECS"
  check_wedge "quiet-$r" || break
  say "round $r/$ROUNDS: STORM ${SECS}s"
  timeout -k 10 $((SECS + 120)) ./tools/qtest run \
    "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt\\ipi-storm.ps1 -Seconds $SECS" \
    2>&1 | tr -d '\r' | tee -a "$OUT/storm-$r.log" | grep -a IPISTORM | tail -3
  grep -qa "IPISTORM t=" "$OUT/storm-$r.log" || say "  WARNING: no cycle heartbeat - the storm may not have run; treat this round as UNMEASURED"
  check_wedge "storm-$r" || break
done

say "RESULT: wedged=$wedged after $ROUNDS rounds (vcpus=$(qvm-prefs "$VM" vcpus 2>/dev/null))"
say "  storm rates: $(grep -hoaE 'rate=[0-9.]+/s' "$OUT"/storm-*.log 2>/dev/null | tail -3 | tr '\n' ' ')"
say "evidence: $OUT"
[ "$wedged" = 0 ]
