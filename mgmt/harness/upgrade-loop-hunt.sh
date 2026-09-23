#!/bin/bash
# upgrade-loop-hunt.sh - loop the PV-driver/MSI install path, which is the one variable three
# negative experiments did not contain.
#
# HYPOTHESIS: the wedge needs the PV DRIVER INSTALLATION, not display-device surgery. Measured
#   against it so far, all negative: a TLB-shootdown storm (~10^9 page events); the same plus USB
#   root-hub load/unload cycling; and 20 cycles of display devnode remove/create with 40 boots on
#   the exact pre-fix code. What the natural occurrences contain and those do not is the MSI
#   replacing the Xen PV driver set - and at the 2026-09-23 wedge a processor was inside xen.sys,
#   while the 2026-09-20 specimen had the PV BUS driver spinning on a lock nobody released.
#   Jev 2026-09-23: next_variable `pv-driver-reinstall` 0.96, best use of the rig 0.87. It also
#   rates the chance that ANY cheap experiment reproduces this at only 0.34 - so this loop reports
#   counts and stops on the first wedge; it does not promise one.
# BASELINE: the loop IS the natural path - quick-upgrade is how the 2026-09-22 reference stall was
#   produced, so the per-run rate here is known to be non-zero.
# VARIABLE: none within the loop; every run is identical by construction. That is the point: the
#   only thing varying is chance.
# INSTRUMENT: quick-upgrade's own exits (0 clean, 1 failure with the guest left as evidence, 2
#   deadline, 3 refused), plus an independent check of the specimen fingerprint afterwards -
#   unreachable while the domain's cpu_time advances - because a run can fail for reasons that are
#   not this wedge and those must not be counted as one.
# BUDGET: ~5-7 minutes per run. 20 runs is about 2 hours.
#
#   mgmt/harness/upgrade-loop-hunt.sh <release-iso> [runs] [subject]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
ISO="${1:?usage: upgrade-loop-hunt.sh <release-iso> [runs] [subject]}"
N="${2:-20}"
SUBJECT="${3:-win10-up}"
# Hold the guest lock for the WHOLE loop: quick-upgrade takes the same lock per run and is
# re-entrant when an ancestor holds it, so this keeps anything else off the subject between
# runs - including the window where a wedged specimen is being captured.
. mgmt/harness/vmlock.sh
vm_lock "$SUBJECT"
OUT="scratchpad/upgradeloop-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) uploop: $*" | tee -a "$OUT/run.log"; }

state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$SUBJECT" '$1==v{print $2}'; }
cpu(){ python3 - "$SUBJECT" <<'PY'
import sys
try:
    import qubesadmin
    print(int(qubesadmin.Qubes().domains[sys.argv[1]].get_cputime() or 0))
except Exception:
    print(0)
PY
}
alive(){ QTEST_VM="$SUBJECT" timeout -k 5 45 ./tools/qtest run 'cmd /c echo PONG' 2>/dev/null | grep -qa PONG; }

stalls=0; fails=0; clean=0; core_taken=0
for r in $(seq 1 "$N"); do
  say "run $r/$N (clean=$clean stalls=$stalls other-failures=$fails)"
  bash mgmt/harness/quick-upgrade.sh "$ISO" "$SUBJECT" "${OS:-win10}" >"$OUT/run-$r.log" 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then
    clean=$((clean+1)); say "  run $r: clean (rc=0)"
  else
    # A NON-ZERO RC IS NOT AUTOMATICALLY THE WEDGE. Check the fingerprint independently: the guest
    # unreachable while its cpu_time still advances. Anything else is counted as an ordinary
    # failure and kept, not credited to the hunt.
    if [ "$(state)" = Running ] && ! alive; then
      c1=$(cpu); sleep 20; c2=$(cpu)
      if [ "${c2:-0}" -gt "${c1:-0}" ]; then
        stalls=$((stalls+1))
        say "  run $r: WEDGE (rc=$rc) - unreachable while cpu_time advances ($c1 -> $c2)"
        d="$OUT/wedge-$r"; mkdir -p "$d"
        timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$SUBJECT" </dev/null > "$d/forensics.tar" 2>"$d/err" \
          && say "    forensics -> $d"
        if [ "$core_taken" = 0 ] && bash mgmt/harness/fetch-wedge-core.sh "$SUBJECT" "$d/guest.core" >>"$d/core.log" 2>&1; then
          core_taken=1; say "    memory image -> $d/guest.core"
        fi
        say "  STOPPING on the first wedge - the specimen is worth more than the remaining runs."
        break
      fi
    fi
    fails=$((fails+1))
    say "  run $r: failed rc=$rc but NOT the wedge fingerprint (see $OUT/run-$r.log)"
  fi
done

say "RESULT: $clean clean, $stalls wedge(s), $fails other failure(s) over the runs attempted"
say "evidence: $OUT"
[ "$stalls" = 0 ]
