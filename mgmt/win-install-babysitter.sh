#!/bin/bash
# Run IN win-idd-mgmt. Drives the unattended Windows install of a test qube (arg 1):
# a guest reboot destroys the Qubes domain (on_reboot=destroy), so this loop restarts
# the qube (WITHOUT the installer CD) at each halt until activity settles.
# Emits one line per state transition; exits DONE after the expected ~4 halts have
# passed and the qube then stays up >8 min (stage2/QWT install finished), or FAIL on
# a crash-loop (halt <90s after start, 3x consecutive) / overall timeout.
set -u
# NO DEFAULT TARGET (owner, 2026-09-21: "no attempts to target dom0 or self as default target
# qube where explicit target is required"). A default turns "I forgot to name the guest" into
# "silently drive a different guest" - which sent both arms of an A/B to the wrong VM and left
# three guests running at once. Name it or be refused.
if [ -z "${1:-}" ]; then echo "win-install-babysitter: name the guest - there is NO default target." >&2; exit 2; fi
VM="$1"
BUDGET_S=$((75*60))
t0=$(date +%s)
restarts=0 fastfails=0
last_start=$t0

state() { qvm-ls --raw-data --fields state "$VM" 2>/dev/null; }

echo "babysitter: watching $VM (budget ${BUDGET_S}s)"
# Don't count a pre-existing Halted as a phase transition: wait for the first
# Running before entering the halt/restart loop (races the initial qvm-start
# otherwise - counted a phantom "halt #1 after 0s" and double-started once).
while [ "$(state)" != "Running" ] && [ "$(state)" != "Transient" ]; do
    [ $(( $(date +%s) - t0 )) -gt 300 ] && { echo "FAIL: VM never reached Running in 300s"; exit 1; }
    sleep 5
done
last_start=$(date +%s)
while :; do
    now=$(date +%s)
    [ $((now-t0)) -gt "$BUDGET_S" ] && { echo "FAIL: budget exceeded after $restarts restarts"; exit 1; }
    s=$(state)
    case "$s" in
      Running|Transient) : ;;
      Halted)
        up=$((now-last_start))
        if [ "$up" -lt 90 ]; then
            fastfails=$((fastfails+1))
            [ "$fastfails" -ge 3 ] && { echo "FAIL: crash-loop ($fastfails fast halts)"; exit 1; }
        else
            fastfails=0
        fi
        restarts=$((restarts+1))
        echo "halt #$restarts after ${up}s uptime - restarting (no cdrom)"
        qvm-start "$VM" >/dev/null 2>&1 || { echo "FAIL: qvm-start rc=$?"; exit 1; }
        last_start=$(date +%s)
        ;;
      *) echo "note: state='$s'" ;;
    esac
    # Settled: enough phases passed and current boot has stayed up
    if [ "$restarts" -ge 3 ] && [ "$(state)" = "Running" ] && [ $(( $(date +%s) - last_start )) -gt 480 ]; then
        echo "DONE: $restarts restarts, current boot up >8min - install presumed complete"
        exit 0
    fi
    sleep 20
done
