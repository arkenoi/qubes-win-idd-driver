#!/bin/bash
# Queued behind the deploy: locate WHICH surface repaints on an idle Windows 11 desktop.
#
# Win10 is deliberately NOT re-measured (user, 2026-08-08: metering there is finished). The
# ambient conclusion does not need it: the load-bearing comparison is WITHIN Windows 11 -
# 18.75 fps idle against its own 24.4 fps under workload, i.e. ~77% of its presents happen
# with nobody touching the machine. An earlier note calling that finding "one-sided" was
# overstated; the Win10 idle number would have been corroboration, not the evidence.
#
# Runs on the freshly installed guest, whose shell state has not been perturbed by the
# visual-effects toggling from the earlier A/B - so whatever it finds is a property of a stock
# Windows 11 desktop rather than of this session's poking.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) followup: $*"; }

waited=0
while pgrep -f deploy-and-hitrate.sh >/dev/null 2>&1; do
    sleep 60; waited=$((waited+1))
    [ $((waited % 15)) -eq 0 ] && log "waiting for the deploy (${waited} min)"
    [ "$waited" -gt 150 ] && { log "ABORT: deploy still running after 2.5 h"; exit 1; }
done
[ "$waited" -gt 0 ] && log "deploy finished after ${waited} min"

log "=== locate the idle repaint on win11-fresh ==="
./scratchpad/locate-idle-repaint.sh win11-fresh win11 6 2>&1 | tee "$S/followup-locate.log"

log "=== followup complete - report: $S/idlerepaint-win11/REPORT.txt ==="
