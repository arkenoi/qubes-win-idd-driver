#!/bin/bash
# Recover win11-fresh if it wedges during validate-coalesce.sh's settling loop.
#
# The failure already happened once today: the guest answered qrexec, then went unreachable
# while Running - qtest shot returned an EMPTY tar (no mapped windows, so no gui-agent) - and
# stayed that way. validate-coalesce.sh's settling loop tolerates qrexec dropouts on purpose,
# because they are the expected signature of the firstboot reboot, so it cannot tell a reboot
# from a wedge and will poll for its full deadline before aborting. That costs ~50 minutes.
#
# ZERO INTERFERENCE BY DESIGN. This reads the harness's log instead of probing the guest, so
# it never issues a qrexec call that could collide with the harness's own. It acts only on
# what the harness itself reports.
#
# A reboot resolves in two or three minutes; a wedge does not. The threshold is therefore set
# far above any legitimate reboot, and the action is a kill - NOT a start - because the
# harness's own loop already restarts a Halted guest. Two interventions maximum: if the guest
# wedges repeatedly, that is a finding to report, not something to paper over indefinitely.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
LOG="$S/chain.log"
VM=win11-fresh
THRESHOLD=${THRESHOLD:-11}   # consecutive unreadable polls; the loop sleeps 60 s between them
MAX_ACTIONS=${MAX_ACTIONS:-2}

log(){ echo "$(date -u +%H:%M:%S) wedge-watch: $*"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

actions=0
while [ "$actions" -lt "$MAX_ACTIONS" ]; do
    sleep 60
    # Stop as soon as the harness is done with us, either way.
    grep -aq "fixed agent present after" "$LOG" 2>/dev/null && { log "hash gate satisfied - standing down"; exit 0; }
    grep -aq "ABORT:" "$LOG" 2>/dev/null && { log "harness aborted - standing down"; exit 0; }
    pgrep -f run-fix-validation.sh >/dev/null 2>&1 || { log "chain no longer running - standing down"; exit 0; }

    # Consecutive unreadable polls at the TAIL. A single readable line resets the count, which
    # is what keeps a reboot from tripping this.
    n=$(tac "$LOG" 2>/dev/null | awk '
        /settling: hash=/ { if ($0 ~ /unreadable/) { c++; next } else { exit } }
        END { print c+0 }')
    [ "$n" -ge 1 ] && log "consecutive unreadable polls: $n / $THRESHOLD"

    if [ "$n" -ge "$THRESHOLD" ] && [ "$(state $VM)" = Running ]; then
        actions=$((actions+1))
        log "WEDGE: $n consecutive unreadable polls (~$((n)) min) while Running - killing so the"
        log "       harness's own restart branch takes over (intervention $actions/$MAX_ACTIONS)"
        timeout 90 qvm-kill "$VM" >/dev/null 2>&1
        sleep 30
        log "state after kill: $(state $VM)"
        # Let the harness restart and get well past the threshold before considering again.
        sleep 600
    fi
done
log "intervention budget spent - a guest that wedges $MAX_ACTIONS times is a finding, not a retry loop"
