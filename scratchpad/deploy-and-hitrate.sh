#!/bin/bash
# Deploy the build carrying the order-free occlusion test, then re-measure the hit rate.
#
# WHY A CLEAN INSTALL AND NOT AN AGENT SWAP. guest/swap-agent.ps1 needs elevation, and qrexec
# runs UNELEVATED on clean-room guests - the same wall that produced zero valid points in the
# FocusRaise A/B. The USB firstboot path runs as SYSTEM, so a reinstall is the only route that
# actually places a new binary on this guest.
#
# WHAT CHANGED AND WHY IT SHOULD MOVE. The previous build measured 0 skips in 5557 decisions,
# because PwScreenUnchanged required g_ZOrderValid and CollectZOrder deliberately leaves that
# FALSE unless an override-redirect popup is on screen. The check never ran. This build
# replaces the ordering requirement with an order-free pair (foreground window + no other
# visible window overlaps it), so the fast path can fire for the window the user is in.
#
# WHAT WOULD FALSIFY THE FIX: a hit rate still at 0 %, with the refusal columns showing the
# order-free conditions (not-fg / overlap) binding instead. That is a different defect, not a
# vindication, and the report says so rather than leaving it to interpretation.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) deploy: $*"; }

# Serialize behind the diagnostics queue: two Windows guests at once contaminates timings, and
# the queue is still driving win10-clean/win11-fresh.
waited=0
while pgrep -f run-diagnostics-queue.sh >/dev/null 2>&1; do
    sleep 60; waited=$((waited+1))
    [ $((waited % 10)) -eq 0 ] && log "waiting for the diagnostics queue (${waited} min)"
    [ "$waited" -gt 120 ] && { log "ABORT: queue still running after 2 h"; exit 1; }
done
[ "$waited" -gt 0 ] && log "queue finished after ${waited} min"

# The artifact must actually carry the new counters. A green build is not evidence that the
# binary contains them - the literals are UTF-16 in the PE, so probe accordingly.
log "confirming the newest artifact carries the order-free counters"
rm -rf artifacts-v4
RID=$(gh run list --workflow=release-package.yml --limit 6 \
      --json databaseId,status,conclusion \
      -q '[.[] | select(.status=="completed" and .conclusion=="success")][0].databaseId')
[ -n "$RID" ] || { log "ABORT: no green build"; exit 1; }
for a in 1 2 3; do gh run download "$RID" -n qwt-improved-setup -D artifacts-v4 && break; rm -rf artifacts-v4; sleep 15; done
F=$(find artifacts-v4 -name gui-agent.exe | head -1)
[ -n "$F" ] || { log "ABORT: no gui-agent.exe in the artifact"; exit 1; }
for probe in pwnofg pwovl pwchg; do
    n=$(strings -a -e l "$F" | grep -c "$probe")
    [ "$n" -gt 0 ] || { log "ABORT: artifact lacks '$probe' - wrong build (run $RID)"; exit 1; }
done
log "run $RID carries pwnofg/pwovl/pwchg"

# validate-coalesce.sh already does: pick newest green descendant, download, build the stick,
# clean install with NO /idd, settle, assert the hash, assert the BDA, run 3 reps. Reuse it
# rather than duplicating install logic that has been debugged once already.
log "=== clean install + 3 reps ==="
./scratchpad/validate-coalesce.sh 2>&1 | tee "$S/deploy-validate.log"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { log "ABORT: install/reps failed (rc=$rc) - refusing to report a hit rate for an unconfirmed build"; exit "$rc"; }

log "=== hit rate and refusal causes ==="
./scratchpad/hitrate-report.py "$S/bm-fix" 2>&1 | tee "$S/deploy-hitrate.txt"
log "=== done ==="
