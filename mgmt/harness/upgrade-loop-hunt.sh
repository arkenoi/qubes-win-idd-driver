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
SUBJECT="${3:?usage: $0 <pkg> <os> <subject> - name the subject; there is no default target}"
# Hold the guest lock for the WHOLE loop: quick-upgrade takes the same lock per run and is
# re-entrant when an ancestor holds it, so this keeps anything else off the subject between
# runs - including the window where a wedged specimen is being captured.
export QTEST_VM="$SUBJECT"   # e2e-lib.sh refuses to load without it - there is no default target
. .claude/skills/win-guest-e2e/e2e-lib.sh
. mgmt/harness/e2e-wait.sh
. mgmt/harness/vmlock.sh
vm_lock "$SUBJECT"
OUT="scratchpad/upgradeloop-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) uploop: $*" | tee -a "$OUT/run.log"; }

state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$SUBJECT" '$1==v{print $2}'; }
# w_cpu_state FROM THE SHARED WAIT LIBRARY, never a hand-rolled reader. The first version called
# qubesadmin's get_cputime, which DOES NOT EXIST on this toolstack (QubesNoSuchPropertyError):
# the exception was swallowed, 0 was returned twice, and "0 > 0" made a LIVE WEDGE read as
# healthy. Run 7 of the 2026-09-23 loop was a real SPINNING stall, correctly identified by the
# upgrade harness itself, and this oracle discarded it; the next run recloned the guest and the
# specimen was lost. MISSING DATA MUST FAIL, never read as a negative.
wedge_now(){ # 0 = spin fingerprint, 1 = not it, 2 = UNMEASURED; reason in $WEDGE_WHY
  local cs
  if alive; then WEDGE_WHY="guest answers qrexec"; return 1; fi
  cs=$(w_cpu_state "$SUBJECT" 20)
  case "${cs%% *}" in
    MOVING) WEDGE_WHY="unreachable while cpu_time advanced ${cs#* }"; return 0 ;;
    FLAT)   WEDGE_WHY="unreachable but cpu_time FLAT - a frozen domain, not the spin"; return 1 ;;
    *)      WEDGE_WHY="cpu_time UNREADABLE - executing-or-not UNMEASURED, which is NOT a negative"; return 2 ;;
  esac
}
alive(){ QTEST_VM="$SUBJECT" timeout -k 5 45 ./tools/qtest run 'cmd /c echo PONG' 2>/dev/null | grep -qa PONG; }

stalls=0; fails=0; clean=0; core_taken=0
for r in $(seq 1 "$N"); do
  say "run $r/$N (clean=$clean stalls=$stalls other-failures=$fails)"
  bash mgmt/harness/quick-upgrade.sh "$ISO" "$SUBJECT" "${OS:?set OS (win10|win11)}" >"$OUT/run-$r.log" 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then
    clean=$((clean+1)); say "  run $r: clean (rc=0)"
  else
    # A NON-ZERO RC IS NOT AUTOMATICALLY THE WEDGE. Check the fingerprint independently: the guest
    # unreachable while its cpu_time still advances. Anything else is counted as an ordinary
    # failure and kept, not credited to the hunt.
    if [ "$(state)" = Running ]; then
      wedge_now; w=$?
      [ "$w" = 2 ] && say "  run $r: UNMEASURED - $WEDGE_WHY (not counted clean)"
      if [ "$w" = 0 ]; then
        stalls=$((stalls+1))
        say "  run $r: WEDGE (rc=$rc) - $WEDGE_WHY"
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
