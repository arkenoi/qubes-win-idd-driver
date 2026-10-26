#!/bin/bash
# blockclaim-selftest.sh - the staleness test, the API route, and the wiring.
#
# WHAT CANNOT BE SHIMMED HERE. Reading and dropping claims goes through the Admin API (the CLI
# `qvm-device block list` is policy-refused from this qube), so there is no PATH shim that would
# exercise claim_sweep_stale end to end without a real qube. What IS tested here is every part that
# got it wrong on 2026-10-14:
#   * a loop NODE can exist while bound to nothing - /dev/loop14 was present and `losetup -l` did
#     not list it, so my first sweep called the stale claim LIVE and dropped nothing. The predicate
#     is the BACKING FILE, and that is driven here against a real loop device.
#   * `qvm-device block unassign <vm> <holder>:loopN` does not remove a WILDCARD-ident claim: it
#     answers "not assigned to <vm>" while the claim stays. So the lib must not use that route.
# The end-to-end drop has a live receipt instead: win10-acc's `win-idd-mgmt:loop14:*` claim was
# dropped through this code path on 2026-10-14 (findings/issues.md CLAIMSTALELOOP).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

# shellcheck disable=SC1091
source mgmt/harness/blockclaim-lib.sh

T=$(mktemp -d "${TMPDIR:-/tmp}/blockclaim.XXXXXX") || exit 2
# ROUTE is whichever one set the device up, so teardown matches setup (see TWO ROUTES below).
ROUTE=""
cleanup(){
    if [ -n "${DEV:-}" ]; then
        case "$ROUTE" in
            sudo) sudo -n losetup -d "$DEV" >/dev/null 2>&1 ;;
            *)    udisksctl loop-delete -b "$DEV" >/dev/null 2>&1 ;;
        esac
    fi
    rm -rf "$T"
}
trap cleanup EXIT INT TERM

# The predicate, against a REAL loop: bound -> has a backing file; deleted -> node may remain.
bound(){ [ -e "/sys/block/$1/loop/backing_file" ] && echo 1 || echo 0; }

# TEARDOWN IS ASYNCHRONOUS, and reading it once is a race. Measured 2026-10-26 over 5 runs of this
# suite on an unchanged tree: one read the backing file as still present immediately after
# `udisksctl loop-delete` returned (rc=0,1,0,0,0 - BLOCKCLAIMSELFTESTRACES). The property is "AFTER
# the delete it is gone", so it is WAITED for, with a bound, and the wait says which exit it took.
# Echoes "<final reading> <how long>", so the label can carry the settle time.
wait_bound(){ # <base> <wanted reading>
    local i=0 v
    while [ "$i" -lt 100 ]; do
        v=$(bound "$1")
        [ "$v" = "$2" ] && { echo "$v $((i*50))ms"; return 0; }
        sleep 0.05; i=$((i+1))
    done
    echo "$v DEADLINE-5s"
}
wait_unlisted(){ # <base>
    local i=0 n
    while [ "$i" -lt 100 ]; do
        n=$(losetup -l 2>/dev/null | grep -c "^/dev/$1 ")
        [ "$n" = 0 ] && { echo "$n $((i*50))ms"; return 0; }
        sleep 0.05; i=$((i+1))
    done
    echo "$n DEADLINE-5s"
}

dd if=/dev/zero of="$T/img" bs=1M count=4 >/dev/null 2>&1 || { echo "FATAL: cannot make an image"; exit 2; }
# TWO ROUTES TO A LOOP DEVICE, tried in this order, and the one that works is recorded in ROUTE.
#   1. udisksctl - the ROOT-FREE route, and the only one available on the dev qube, where sudo is
#      interactive-only by design (mgmt/CLAUDE.md), so a non-interactive `sudo -n` cannot work.
#   2. sudo -n losetup - for a CI runner. MEASURED on ubuntu-latest, CI run 40262136871: udisks2
#      installs and its service is ACTIVE, `udisksctl status` lists the disk, and loop-setup STILL
#      yields no device (the runner session is not polkit-authorised for it). So route 1 alone kept
#      this suite out of the gate for a DEPENDENCY, not a defect, and a runner has passwordless sudo.
# Neither available is "nothing ran" - missing data fails, it never reads as a pass.
DEV=$(udisksctl loop-setup -f "$T/img" 2>/dev/null | grep -aoE '/dev/loop[0-9]+' | head -1)
if [ -n "$DEV" ]; then
    ROUTE=udisks
else
    DEV=$(sudo -n losetup --find --show "$T/img" 2>/dev/null | grep -aoE '/dev/loop[0-9]+' | head -1)
    [ -n "$DEV" ] && ROUTE=sudo
fi
[ -n "$DEV" ] || { echo "FATAL: no loop device - udisksctl loop-setup gave none (root-free route, see mgmt/CLAUDE.md) and sudo -n losetup is unavailable; nothing ran"; exit 2; }
echo "     (loop route: $ROUTE, device $DEV)"
BASE=${DEV#/dev/}

ck "a bound loop has a backing file"            "1" "$(bound "$BASE")"
ck "and losetup lists it"                       "1" "$(losetup -l 2>/dev/null | grep -c "^$DEV ")"

# THE WAITER MUST BE ABLE TO SAY "STILL THERE", or waiting for 0 below would prove nothing: while
# the loop is still bound it has to spend its whole bound and report 1.
still=$(wait_bound "$BASE" "0")
ck "the waiter reports a STILL-BOUND loop and takes its deadline (${still#* })" "1" "${still% *}"

case "$ROUTE" in
    sudo) sudo -n losetup -d "$DEV" >/dev/null 2>&1 ;;
    *)    udisksctl loop-delete -b "$DEV" >/dev/null 2>&1 ;;
esac
DEV=""
gone=$(wait_bound "$BASE" "0")
ck "a deleted loop has NO backing file (${gone#* })"         "0" "${gone% *}"
unl=$(wait_unlisted "$BASE")
ck "and losetup no longer lists it (${unl#* })"              "0" "${unl% *}"
# THE TRAP ITSELF: the node often survives the delete, which is why node existence must not be the
# test. If this prints 0 the node happened to go too - the predicate above is still the right one.
echo "     (node /dev/$BASE still present after delete: $([ -e "/dev/$BASE" ] && echo yes || echo no))"

# The lib must test the backing file, not the node, and must not use the CLI unassign for the sweep.
ck "the sweep tests the backing file"           "1" "$(grep -c "sys/block/{base}/loop/backing_file" mgmt/harness/blockclaim-lib.sh)"
ck "no os.path.exists on the device node"       "0" "$(grep -c "os.path.exists(f'/dev/" mgmt/harness/blockclaim-lib.sh)"
ck "claims are dropped via the API object"      "2" "$(grep -c 'coll.unassign(a)' mgmt/harness/blockclaim-lib.sh)"
ck "never via the CLI unassign"                 "0" "$(grep -vE '^[[:space:]]*#' mgmt/harness/blockclaim-lib.sh | grep -c 'qvm-device block unassign')"

# A missing qube is not an error: a sweep runs before a subject may even exist.
ck "an absent qube sweeps clean"                "0" "$(claim_sweep_stale __no_such_qube__ >/dev/null 2>&1; echo $?)"

# The wiring: swept before the start that would fail, dropped before the loop is released.
ck "matrix sweeps before the ISO start"         "1" \
   "$(awk '/booting \$vm with the release ISO/{found=1} /claim_sweep_stale "\$vm" say/{if(!found) c++} END{print c+0}' mgmt/harness/matrix.sh)"
ck "matrix records the claimed subject"         "1" "$(grep -c 'MATRIX_CDROM_CLAIMED="\$MATRIX_CDROM_CLAIMED \$vm"' mgmt/harness/matrix.sh)"
ck "and drops it before loop-delete"            "1" \
   "$(awk '/^_matrix_release_loop\(\)/,/^}/' mgmt/harness/matrix.sh | awk '/claim_drop_loop/{c++} /loop-delete/{if(c>0) ok=1} END{print ok+0}')"

echo "blockclaim-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
