#!/bin/bash
# BENCH + guest-aware gate for the p4-rendering acceptance.
#
# Runs the canonical stock-vs-ours suite unchanged, then applies the win10/win11 scroll
# criterion via tools/bench-gate.py:
#   win10 (build <  26100): scroll must be REAL disjoint, ours BETTER (the fork perf win).
#   win11 (build >= 26100): scroll must NOT be REAL disjoint, ours WORSE (no regression) -
#                           the platform makes all agents indistinguishable on scroll, so a
#                           disjoint-better verdict is unsatisfiable there for ANY build.
# The disarm re-assert (BENCH-disarm) and the canonical suite's own evidence rules
# (per-rep RUNNING-hash, pixel scene check, 0-INVALID, settle floor) are untouched.
#
#   bench-gate-run.sh <vm> <stock-agent.exe> <ours-agent.exe> <accept-out-dir>
set -uo pipefail
VM="${1:?usage: $0 <vm> <stock> <ours> <outdir>}"
STOCK="${2:?stock agent}"
OURS="${3:?ours agent}"
OUT="${4:?outdir}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"

# One harness per guest; the child bench sees QWT_VMLOCK_HELD and its own vm_lock passes through.
source "$HERE/mgmt/harness/vmlock.sh"; vm_lock "$VM"
export QWT_VMLOCK_HELD="$VM"

grep -aq 'DISARMED True' "$OUT/disarm.txt" || { echo "FATAL: scan not provably disarmed (BENCH-disarm)"; exit 1; }

QTEST_VM="$VM" QWT_VMLOCK_HELD="$VM" BENCH_SETTLE_S=45 \
  "$HERE/tools/bench-stock-vs-ours.sh" "$STOCK" "$OURS" 3 2>&1 | tee "$OUT/bench-suite.log"

# Guest OS build governs the criterion (queried from the guest, not caller-supplied).
GB=$(QTEST_VM="$VM" timeout -k 5 40 "$HERE/tools/qtest" run \
      'cmd /c reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber' \
      2>/dev/null | tr -d '\r' | grep -aoE '[0-9]{4,}' | tail -1)
echo "GUEST_BUILD=${GB:-unknown}"
[ -n "${GB:-}" ] || { echo "BENCH-GATE FAIL: could not read guest build number"; exit 1; }

python3 "$HERE/tools/bench-gate.py" "$OUT/bench-suite.log" "$GB"
