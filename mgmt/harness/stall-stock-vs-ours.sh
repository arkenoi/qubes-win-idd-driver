#!/bin/bash
# stall-stock-vs-ours.sh - does the stall happen WITHOUT our software at all?
#
# HYPOTHESIS: the post-install stall class (a kernel cross-processor wait that never completes,
#   both recorded specimens polling the same structure offset 0x2d80) is induced by something
#   THIS PROJECT ships. Jev 2026-09-23: axis `ours-vs-stock-qwt` 0.81, first experiment
#   `stock-qwt-clean-installs` 0.74, most plausible candidate `something-our-software-does-
#   continuously` 0.83. Refuted if STOCK QWT stalls at the same rate; supported if ours stalls
#   and stock does not.
# BASELINE:   the arm ITSELF is the baseline - stock QWT 4.2.2 (mgmt/prime-jobs/stock-422), which
#   contains nothing of ours, installed by the same harness onto the same pristine golden.
# VARIABLE:   the software installed. Nothing else: same base golden, same host, same vCPU count,
#   same clean-install path, arms INTERLEAVED so anything drifting in the background (pool fill,
#   dom0 state, time of night) hits both equally.
# INSTRUMENT: prime-run's own stall detection (deadline + cpu_time advancing while qrexec is dead,
#   guest left RUNNING), plus dom0 forensics on every stall, plus - for the FIRST stall of each
#   arm only, because each image is ~8.6 GB - a full memory image via fetch-wedge-core.sh. Module
#   bases are armed by prime-run since 9a9eae9, so a stall RESOLVES to a module without the core.
# BUDGET:     ~25-40 min per clean install, serial. Default 6 runs per arm = roughly 5-8 hours.
#   The failure is intermittent at order 10-20 %, so a 1-2 run arm proves NOTHING and this refuses
#   to pretend otherwise: it reports counts, not a verdict.
#
#   mgmt/harness/stall-stock-vs-ours.sh <ours-setup-tree> [runs-per-arm]
#
# WHY NOT A BISECT OF OUR RELEASES FIRST: the occurrences span at least three of our packages AND
# a guest that was three hours into NORMAL SERVICE with nothing installing, so "which of our
# releases" is the wrong first question. Establish whether the rig stalls without us at all.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
OURS="${1:?usage: stall-stock-vs-ours.sh <ours-setup-tree> [runs-per-arm]}"
N="${2:-6}"
BASE="${BASE:?set BASE to the base golden - there is no default target}"
# NO DEFAULT TARGET (lint L-target): a harness that defaults its subject runs against whatever
# that name happens to be today. Name it: VM=<qube> ... - it is created and destroyed per run.
VM="${VM:?set VM to the churn qube this hunt may create and destroy, e.g. VM=win10-hunt}"
OUT="scratchpad/stockvsours-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) svo: $*" | tee -a "$OUT/run.log"; }

. mgmt/harness/vmlock.sh
vm_lock "$VM"

declare -A stalls=([stock]=0 [ours]=0) ran=([stock]=0 [ours]=0)
core_taken=([stock]=0 [ours]=0)

release_guest(){ # ACPI, then kill - the subject is discarded either way and never reused
  qvm-shutdown "$VM" >/dev/null 2>&1
  for _ in $(seq 1 12); do
    [ "$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}')" = Halted ] && return 0
    sleep 10
  done
  say "  $VM did not halt - killing the discarded subject"
  qvm-kill "$VM" >/dev/null 2>&1; sleep 8
}

capture(){ # $1=arm $2=tag - everything, BEFORE the guest is released
  local arm="$1" tag="$2" d="$OUT/stall-$arm-$tag"
  mkdir -p "$d"
  timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$VM" </dev/null > "$d/forensics.tar" 2>"$d/forensics.err" \
    && say "  forensics captured -> $d" || say "  WARNING: forensics capture failed (kept $d/forensics.err)"
  if [ "${core_taken[$arm]}" = 0 ]; then
    # One image per arm: 8.6 GB each, and the second adds little the first does not have.
    if bash mgmt/harness/fetch-wedge-core.sh "$VM" "$d/guest.core" >>"$d/core.log" 2>&1; then
      core_taken[$arm]=1
      say "  memory image taken -> $d/guest.core (resolve: tools/core-module-list.py ... --contains 0x<rip>)"
    else
      say "  memory image NOT taken (see $d/core.log) - forensics still stand"
    fi
  fi
}

run_one(){ # $1=arm
  local arm="$1" tag; tag="$(date -u +%H%M%S)"
  local rc
  say "=== arm $arm, run $(( ran[$arm] + 1 ))/$N"
  qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | grep -qx "$VM|Halted" || qvm-remove -f "$VM" >/dev/null 2>&1
  if [ "$arm" = stock ]; then
    bash mgmt/harness/prime-run.sh "$BASE" "$VM" stock-422 >"$OUT/$arm-$tag.log" 2>&1; rc=$?
  else
    bash mgmt/harness/prime-run.sh "$BASE" "$VM" ours --payload "$OURS" >"$OUT/$arm-$tag.log" 2>&1; rc=$?
  fi
  ran[$arm]=$(( ran[$arm] + 1 ))
  # prime-run leaves a STALLED guest running and exits 2 with the spin fingerprint in its log.
  if [ "$rc" != 0 ] && grep -qa "EXECUTING-BUT-UNREACHABLE\|DEADLINE:" "$OUT/$arm-$tag.log"; then
    stalls[$arm]=$(( stalls[$arm] + 1 ))
    say "  STALL (rc=$rc) - capturing before release"
    capture "$arm" "$tag"
  elif [ "$rc" != 0 ]; then
    say "  run FAILED rc=$rc but NOT with the stall fingerprint - counted as neither arm's stall (see $OUT/$arm-$tag.log)"
  else
    say "  completed clean"
  fi
  release_guest
  say "  running totals: stock ${stalls[stock]}/${ran[stock]}, ours ${stalls[ours]}/${ran[ours]}"
}

for i in $(seq 1 "$N"); do
  run_one stock
  run_one ours
done

say "RESULT after $N runs per arm:"
say "  stock-422 : ${stalls[stock]} stalls / ${ran[stock]} runs"
say "  ours      : ${stalls[ours]} stalls / ${ran[ours]} runs"
say "A DIFFERENCE IS NOT A VERDICT at these counts - feed the numbers to Jev with the per-run logs."
say "evidence: $OUT"
