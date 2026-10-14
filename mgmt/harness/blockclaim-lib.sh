#!/bin/bash
# blockclaim-lib.sh - drop block-device claims whose loop device is gone, so a subject stays startable.
#
# THE TRAP (findings/rig.md, and measured again on 2026-10-14). `assign --required` PERSISTS on the
# qube while loop numbers are TRANSIENT - recycled on reboot and by every `udisksctl loop-delete`.
# A required claim naming a loop that no longer carries a backing file makes the domain
# UNCREATABLE, and the only thing Qubes says is "internal error: libxenlight failed to create new
# domain". The guest is then a brick until the claim is removed.
#
# WHO LEAKS ONE. `qvm-start <vm> --cdrom=<holder>:loopN` leaves a `--required` cdrom claim behind;
# the campaign releases its release-ISO loop at the end (matrix.sh), and from that moment the
# subject it booted cannot start. Measured: win10-acc carried `win-idd-mgmt:loop14:*
# required=True devtype=cdrom` after the 2026-10-14 campaign released /dev/loop14 at 20:47:45, and
# every later attempt to start it printed nothing but "start failed".
#
# TWO THINGS THE OBVIOUS IMPLEMENTATION GETS WRONG, both measured here:
#   * `qvm-device block unassign <vm> <holder>:loopN` does NOT remove a claim that was made with a
#     WILDCARD device identity: it expands the name to one concrete ident and answers "not assigned
#     to <vm>" while the claim sits there. The assignment object has to be taken from the collection
#     and handed back to unassign(), which is why this goes through the Admin API and not the CLI.
#   * a loop NODE can exist while bound to nothing - /dev/loop14 was present the whole time and
#     `losetup -l` simply did not list it. The test for "gone" is therefore the BACKING FILE
#     (/sys/block/loopN/loop/backing_file), never the existence of the device node.
#
# `qvm-device block list` is policy-refused from this qube (mgmt/CLAUDE.md), so reading the claims
# also goes through the Admin API.
set -uo pipefail

_bc_say(){ echo "blockclaim: $*" >&2; }

claim_list(){ # <vm> - print one line per assigned block claim: <ident> <options>
  python3 - "${1:?[ERROR] claim_list <vm>}" <<'PY'
import sys
import qubesadmin
q = qubesadmin.Qubes()
try:
    coll = q.domains[sys.argv[1]].devices['block']
except KeyError:
    sys.exit(0)
for a in coll.get_assigned_devices():
    print(str(a), getattr(a, 'options', {}) or {})
PY
}

claim_sweep_stale(){ # <vm> [logfn] - drop every claim whose loop has no backing file; 0 = the guest is startable
  local vm="${1:?[ERROR] claim_sweep_stale <vm> [logfn]}" lg="${2:-_bc_say}" out rc
  out=$(python3 - "$vm" <<'PY'
import os, sys
import qubesadmin

def bound(base):
    # A loop node can exist unbound, so the backing FILE is the test - not the node.
    return os.path.exists(f'/sys/block/{base}/loop/backing_file')

q = qubesadmin.Qubes()
try:
    coll = q.domains[sys.argv[1]].devices['block']
except KeyError:
    print('NOVM'); sys.exit(0)

left = 0
for a in list(coll.get_assigned_devices()):
    s = str(a)
    base = s.split(':')[1] if ':' in s else ''
    if base.startswith('loop') and not bound(base):
        try:
            # The ASSIGNMENT OBJECT, not a name: a wildcard ident cannot be re-spelled on the CLI.
            coll.unassign(a)
            print(f'DROPPED {s}')
        except Exception as e:
            print(f'FAILED {s} {type(e).__name__}: {e}')
            left += 1
    else:
        print(f'KEPT {s}')
sys.exit(1 if left else 0)
PY
  ) ; rc=$?
  local n_drop n_fail
  n_drop=$(printf '%s\n' "$out" | grep -ac '^DROPPED ' || true)
  n_fail=$(printf '%s\n' "$out" | grep -ac '^FAILED ' || true)
  if [ "$n_drop" -gt 0 ]; then
    $lg "  $vm: dropped $n_drop stale block claim(s) - a claim on a released loop makes the domain uncreatable"
    printf '%s\n' "$out" | grep -a '^DROPPED ' | while read -r _ id; do $lg "    stale: $id"; done
  fi
  if [ "$n_fail" -gt 0 ]; then
    $lg "  $vm: [ERROR] $n_fail stale claim(s) could not be dropped - this guest will not start"
    printf '%s\n' "$out" | grep -a '^FAILED ' | while read -r l; do $lg "    $l"; done
    return 1
  fi
  [ "$rc" -eq 0 ]
}

claim_drop_loop(){ # <vm> <loopN> - drop a specific loop's claim, wildcard ident included
  local vm="${1:?[ERROR] claim_drop_loop <vm> <loopN>}" dev="${2:?[ERROR] claim_drop_loop <vm> <loopN>}"
  python3 - "$vm" "$dev" <<'PY'
import sys
import qubesadmin
q = qubesadmin.Qubes()
try:
    coll = q.domains[sys.argv[1]].devices['block']
except KeyError:
    sys.exit(0)
want = sys.argv[2]
for a in list(coll.get_assigned_devices()):
    s = str(a)
    parts = s.split(':')
    if len(parts) < 2 or parts[1] != want:
        continue
    try:
        coll.unassign(a); print(f'DROPPED {s}')
    except Exception as e:
        print(f'FAILED {s} {type(e).__name__}: {e}'); sys.exit(1)
PY
}
