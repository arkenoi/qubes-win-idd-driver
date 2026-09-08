#!/bin/bash
# evidence-lock.sh - make destroying a failed guest IMPOSSIBLE, not discouraged.
#
# Every "preserve the failing guest" rule in this repo lived in comments, memory files and other
# scripts, and none of it stopped `qvm-remove -f` written thirty lines later in a wrapper. Two
# failure states were destroyed that way on 2026-09-06 and two more on 2026-09-07, after which the
# failures could no longer be attributed. Rules do not work; code does.
#
# Usage - source it and use ev_reap instead of qvm-kill/qvm-remove:
#     . mgmt/harness/evidence-lock.sh
#     ev_lock  <vm> "<why>"     # mark: this guest is evidence, do not destroy
#     ev_reap  <vm>...          # kill+remove, REFUSING any locked guest
#     ev_locked <vm>            # 0 if locked
#     ev_release <vm>           # deliberate, explicit unlock (after harvesting)
#     EV_FORCE=1 ev_reap <vm>   # the only override, and it says so loudly
#
# The lock is a file under mgmt/fixtures/, so it survives the script that set it, a crash, a new
# shell, and a different harness - which is the point: the next runner cannot quietly step on it.
set -uo pipefail

_ev_dir() { local d="${EV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/mgmt/fixtures}"
            mkdir -p "$d" 2>/dev/null; echo "$d"; }
_ev_file() { echo "$(_ev_dir)/$1.evidence-lock"; }

ev_lock() {   # $1=vm $2=reason
    local vm="$1" why="${2:-unspecified}"
    { echo "locked_utc=$(date -u +%FT%TZ)"
      echo "reason=$why"
      echo "by=${0##*/} pid=$$"
    } > "$(_ev_file "$vm")"
    echo "EVIDENCE-LOCK $vm: $why (destroy refused until ev_release)" >&2
}

ev_locked() { [ -f "$(_ev_file "$1")" ]; }

ev_release() { # $1=vm - deliberate unlock, after the evidence has been taken
    local f; f="$(_ev_file "$1")"
    [ -f "$f" ] && { echo "EVIDENCE-UNLOCK $1 (was: $(sed -n 's/^reason=//p' "$f"))" >&2; rm -f "$f"; }
}

# kill+remove, refusing locked guests. Same signature as the ad-hoc loops it replaces.
ev_reap() {
    local vm s i
    for vm in "$@"; do
        if ev_locked "$vm"; then
            if [ "${EV_FORCE:-0}" = 1 ]; then
                echo "EVIDENCE-LOCK OVERRIDDEN for $vm (EV_FORCE=1) - $(sed -n 's/^reason=//p' "$(_ev_file "$vm")")" >&2
                ev_release "$vm"
            else
                echo "REFUSING to destroy $vm: it is EVIDENCE - $(sed -n 's/^reason=//p' "$(_ev_file "$vm")")" >&2
                echo "  harvest it, then: ev_release $vm   (or EV_FORCE=1 to override deliberately)" >&2
                continue
            fi
        fi
        for i in $(seq 1 10); do
            s=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v n="$vm" '$1==n{print $2}')
            [ -z "$s" ] && break
            if [ "$s" = Halted ]; then qvm-remove -f "$vm" >/dev/null 2>&1; sleep 2; continue; fi
            qvm-kill "$vm" >/dev/null 2>&1; sleep 5
        done
    done
}

# Lock every guest a harness left behind for a FAILED cell. Call it right after a cell returns
# non-zero: from then on no reap in any script can take it.
ev_lock_survivors() { # $1=reason, rest=candidate vm names
    local why="$1"; shift
    local vm s
    for vm in "$@"; do
        s=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v n="$vm" '$1==n{print $2}')
        [ -n "$s" ] && ev_lock "$vm" "$why"
    done
}
