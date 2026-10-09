#!/bin/bash
# Does kill_tree let an in-flight qrexec client finish connecting before it reaps the tree?
#
# WHY THIS TEST EXISTS. Killing the tree while a qrexec-client-vm is still mid-connect makes the
# client vanish before the guest-side wrapper reads the vchan's xenstore node, so the wrapper
# reports a departed peer. Three such lines fired at uptime 261 s on win11-acc while five gate
# suites failed fast, and log-sweep counted them as error_lines_undeclared=1 - the gate's own
# "clean error log" condition, breached by the measuring harness rather than by the product.
#
# BOTH ARMS, and the defect arm is the shipped behaviour before the fix:
#   A  a live qrexec-client-vm descendant  -> kill_tree WAITS (up to RL_QREXEC_GRACE)
#   B  the same, exiting on its own        -> kill_tree waits only as long as it lives
#   C  an ordinary descendant              -> no wait at all (a teardown is not slowed in general)
#   D  DEFECT=nowait                       -> arm A no longer waits, which is what used to ship
#
# /proc/<pid>/comm is truncated to 15 characters, so a process named qrexec-client-vm appears as
# "qrexec-client-v" - the match has to allow for that, and this test is what proves it does.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
TMP=$(mktemp -d)
WORK=""
trap 'for d in "$TMP" "$WORK"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT   # one trap, both dirs (lint L21)

LIB=mgmt/harness/run-lib.sh
DEFECT="${DEFECT:-}"
if [ "$DEFECT" = "nowait" ]; then
    # restore the pre-fix behaviour: no grace for an in-flight client
    sed 's/^  local qr grace="${RL_QREXEC_GRACE:-12}" waited=0$/  local qr grace=0 waited=0/' "$LIB" > "$TMP/run-lib.sh"
    command grep -q 'local qr grace=0' "$TMP/run-lib.sh" || { echo "FAIL could not seed the defect"; exit 2; }
    LIB="$TMP/run-lib.sh"
fi

cp /bin/sleep "$TMP/qrexec-client-vm"
cp /bin/sleep "$TMP/ordinary-child"

pass=0; fail=0
check(){ # name expected_min expected_max actual
    local n="$1" lo="$2" hi="$3" a="$4"
    if [ "$a" -ge "$lo" ] && [ "$a" -le "$hi" ]; then
        printf '  ok    %-52s waited %ss (wanted %s-%s)\n' "$n" "$a" "$lo" "$hi"; pass=$((pass+1))
    else
        printf '  FAIL  %-52s waited %ss (wanted %s-%s)\n' "$n" "$a" "$lo" "$hi"; fail=$((fail+1))
    fi
}

# Each arm: start a holder subshell with one child, time kill_tree against the holder.
arm(){ # child_path child_args
    local child="$1" secs="$2" out t0 t1
    out=$(
        . "$LIB" 2>/dev/null
        ( "$child" "$secs" & echo "$!" > "$TMP/kid"; wait ) &
        holder=$!
        sleep 0.4                               # let the child exist before we reap
        t0=$(date +%s)
        RL_QREXEC_GRACE=4 kill_tree "$holder" >/dev/null 2>&1
        t1=$(date +%s)
        kill -KILL "$holder" 2>/dev/null
        echo $((t1 - t0))
    )
    echo "${out##*$'\n'}"
}

echo "=== run-lib kill_tree: in-flight qrexec grace (DEFECT='${DEFECT:-none}')"
a=$(arm "$TMP/qrexec-client-vm" 30);  check "A live qrexec client -> waits the full grace" 3 6 "$a"
b=$(arm "$TMP/qrexec-client-vm" 2);   check "B qrexec client exits early -> waits only that long" 1 3 "$b"
c=$(arm "$TMP/ordinary-child" 30);    check "C ordinary descendant -> no wait" 0 1 "$c"

echo
if [ "$DEFECT" = "nowait" ]; then
    # With the defect, arm A must NOT wait. A suite that still reports 3 arms passing here would be
    # a check that cannot fail, which is the thing this file exists to prevent.
    if [ "$fail" -ge 1 ]; then
        echo "DEFECT ARM OK: $fail arm(s) failed with the pre-fix behaviour seeded - the check can fail"
        exit 0
    fi
    echo "DEFECT ARM BROKEN: everything passed with the defect present, so this test proves nothing"
    exit 1
fi
echo "$pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
echo "re-running with the defect seeded, to show the check can fail"
DEFECT=nowait bash "$0"
