#!/bin/bash
# dom0-sends.sh <vm> [tag] [--no-start] - WHAT THIS GUEST TOLD dom0, pulled to THIS side.
#
# WHY IT EXISTS. Owner, 2026-10-10: "IF I SEE SOMETHING IN DOM0, YOU ARE SUPPOSED TO SEE THE SAME IN
# LOGS, WITH ONE HUNDRED PERCENT CERTAINTY AND ZERO GUESSWORK, ALWAYS... I SHOULD NEVER READ TOASTS TO
# YOU ALOUD!" Every sender of ours logs its own send - but into the guest's PRIVATE volume, which dies
# with a disposable AppVM and needs the guest booted to read. A search of this whole side found ZERO
# pulled logs carrying a send tag, so every dom0 toast ever discussed here came from his screen.
#
# This pulls the send record and appends it to a ledger HERE (scratchpad/dom0-notifications.jsonl,
# append-only, gitignored - it is per-run evidence and the repo is public).
#
# CONTRACT, so a harness can rely on it:
#   rc 0  the record was read and appended (0 sends is a valid answer: nothing was sent)
#   rc 1  the guest was reachable but the record could NOT be read. MISSING DATA FAILS - but the
#         FAILURE IS DELIVERED BY THE ERROR-LINE GATE, NOT BY THE CALLER ABORTING, and that is
#         deliberate. Both callers (quick-upgrade.sh dom0_sends_park, e2e-wait.sh's park)
#         declare the condition as `[WARN] DOM0SENDSUNREAD <vm>: no record of what dom0 was
#         told on this boot (rc=N)` and return 0, because aborting a cell mid-run over a
#         diagnostic record would discard the product evidence the cell exists to collect.
#         That WARN is a MUST line in mgmt/harness/error-corpus.txt (tag DOM0SENDSPARKHANG),
#         so tools/sweep-gate.sh surfaces it and the run is not clean - verified: feeding the
#         line to the gate gives `unaccounted=1`, exit 1. If that corpus entry is ever
#         demoted or reworded the chain breaks silently, so tools/tests/dom0-sends-selftest.sh
#         asserts it is present and MUST.
#         Until 2026-10-21 this line claimed the CALLER fails, which no caller did - a
#         contract describing a mechanism nobody implemented.
#   rc 2  usage / the guest could not be reached at all
# --no-start: never boot the guest (rc 0 with SKIP when it is not Running) - for use inside a cell,
# right after a boot is graded and while the guest is still up.
#
# QTEST_BIN is overridable ONLY so both arms are provable off-rig, the same reason
# gate-remainder.sh's assert_candidate exposes it. tools/tests/dom0-sends-selftest.sh drives it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: tools/dom0-sends.sh <vm> [tag] [--no-start]}"
TAG="${2:-$(date -u +%Y%m%dT%H%M%SZ)}"
NOSTART=0
for a in "${@:3}"; do [ "$a" = "--no-start" ] && NOSTART=1; done
# THE PER-GUEST LOCK (lint L2). vm_lock is re-entrant - QWT_VMLOCK_HELD makes it a no-op inside a
# harness that already holds it - so this is correct both standalone and at a park hook.
if [ -z "${QTEST_BIN:-}" ]; then . mgmt/harness/vmlock.sh; vm_lock "$VM" >/dev/null || { echo "  ERROR: could not lock $VM"; exit 2; }; fi
QT="${QTEST_BIN:-./tools/qtest}"
OUT="${DOM0_SENDS_OUT:-scratchpad/dom0-sends-$VM-$TAG}"; mkdir -p "$OUT"
# NO attempt_dir GATE HERE, DELIBERATELY. This script's ledger is CUMULATIVE by contract -
# tools/tests/dom0-sends-selftest.sh asserts `append_only`, that a second run into the same dir
# still carries the earlier run's records. A contaminated-subject gate refuses that second run,
# so the records stop accruing and the suite reads it as a lost record. Measured 2026-10-27:
# adding the gate took that suite to 17 passed / 1 failed. The ledger is not a per-attempt
# artefact and must not be scoped like one.

LEDGER="${DOM0_SENDS_LEDGER:-scratchpad/dom0-notifications.jsonl}"
# THE CAPTURE SCRIPT IS TRACKED, and it has to be: this read `scratchpad/dom0-sends-capture.ps1`,
# a GITIGNORED path, so the tool worked on exactly one machine. Measured 2026-10-25 by running the
# gate in a fresh worktree - dom0-sends-selftest.sh went 5 passed / 13 failed with
# "ERROR: scratchpad/dom0-sends-capture.ps1 missing - nothing to push", every leg bailing before it
# exercised anything, while the same suite was green in the working tree where the file happens to
# exist. A CI runner is a fresh checkout, so registering that suite would have put a red suite in
# the gate - 0e597399's defect over again. Overridable like OUT and LEDGER above, so the
# missing-file arm stays reachable.
P="${DOM0_SENDS_CAPTURE:-guest/dom0-sends-capture.ps1}"
[ -s "$P" ] || { echo "ERROR: $P missing - nothing to push"; exit 2; }

st=$(QTEST_VM="$VM" timeout 25 $QT state 2>&1 | command grep -ao 'power_state=[A-Za-z]*')
echo "[$(date -u +%H:%M:%S)] dom0-sends $VM ${st:-power_state=UNREAD}"
if [ "$st" != "power_state=Running" ]; then
  [ "$NOSTART" = 1 ] && { echo "  SKIP $VM is ${st:-UNREAD} and --no-start was given"; exit 0; }
  QTEST_VM="$VM" timeout 420 $QT start >/dev/null 2>&1 || { echo "  ERROR: $VM did not start"; exit 2; }
fi
# `pushrun <script.ps1>` is the primitive: it pushes to QubesIncoming and runs it from there. The
# first version did `push <local> <remote-path>` + `run`, which qtest reads as TWO LOCAL FILES - it
# failed with fstatat("C:\Windows\Temp\...") on the first real guest, after passing a selftest
# whose stub ignored its arguments. The stub now asserts the argument shape for exactly that reason.
# A TOOL WHOSE OWN BOUND EXCEEDS ITS CALLER'S CAN NEVER REPORT. This was `timeout 420` while
# quick-upgrade.sh's dom0_sends_park wraps the whole script in `timeout 300`, so the outer bound
# always fired first and the caller saw a bare rc=124 - never the "FAIL the record was NOT read"
# line below, which is the only line that says WHY. Measured 2026-10-14 on win11de-fix: four such
# 124s, one per boot, each costing 300 s and losing that boot's record (DOM0SENDSPARKHANG).
# The default now leaves room under a 300 s caller; a caller with a different bound sets the knob.
QTEST_VM="$VM" timeout "${DOM0_SENDS_PUSHRUN_SECS:-240}" $QT pushrun "$P" > "$OUT/raw.txt" 2>"$OUT/raw.err"
rc=$?
# MISSING DATA FAILS. The capture always prints SENDS DONE, so its absence means the read did not
# happen - and a silent "no sends" is exactly the hole this tool exists to close.
if ! command grep -aq "SENDS DONE" "$OUT/raw.txt" 2>/dev/null; then
  echo "  FAIL the record was NOT read from $VM (rc=$rc) - $(head -c 160 "$OUT/raw.err" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi
command grep -a "^SEND " "$OUT/raw.txt" | sed 's/^SEND //' > "$OUT/sends.txt"
n=$(wc -l < "$OUT/sends.txt")
echo "  $n dom0-bound send line(s) -> $OUT/sends.txt"
python3 tools/dom0-sends-ledger.py "$VM" "$OUT/sends.txt" "$LEDGER" || exit 1
if [ "$n" -gt 0 ]; then
  echo "  routes:"
  python3 - "$OUT/sends.txt" <<'PY'
import collections, importlib.util, sys
spec = importlib.util.spec_from_file_location("led", "tools/dom0-sends-ledger.py")
led = importlib.util.module_from_spec(spec); spec.loader.exec_module(led)
c = collections.Counter(led.classify(l.strip()) or "(unclassified)"
                        for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.strip())
for route, k in c.most_common():
    print("    %-26s x%d" % (route, k))
PY
fi
