#!/bin/bash
# provision-recipe.sh - THE way a medium is put in front of a Windows guest on this rig, as CODE.
#
# WHY THIS FILE EXISTS. On 2026-09-21 a session changed ONE constant of this recipe - the block
# assignment mode, `--required` -> plain - as a "workaround". Provisioning stopped working, the
# rig was declared dead rig-wide, a dom0 fault was blamed at 0.93 confidence, an entire alternative
# delivery channel was built on top of that, and a day and a half was spent before anyone A/B'd the
# change against the process it replaced. The owner's instruction, 2026-09-22: record the correct
# procedure in a script so it cannot be messed with again.
#
# So this is the procedure, executable, with the measurement behind each step. Harnesses SOURCE it.
# tools/lint-harness.py rule L12 refuses the shapes that break it, and tools/tests/lint-selftest.sh
# drives L12 with each defect present, so the guard has been seen to fire.
#
#   . mgmt/harness/provision-recipe.sh
#   provision_assign_stick <vm> <holder> <loopN> [frontend-dev]   # --required, asserted
#   provision_boot_with_disc <vm> <holder> <loopN> [timeout]      # the disc goes in at START
#   provision_assert_medium <vm> <holder> <loopN>                 # after the start, never assumed
#   provision_assert_stubdom_served                               # the backend actually serves 2 domains
#   provision_disarm <vm>                                         # leave no stale claim behind
#
#   mgmt/harness/provision-recipe.sh --print    # the recipe and its evidence, for a human
#
# THE MEASUREMENTS, so nobody has to take this on trust:
#
#  [1] THE ASSIGNMENT IS `--required`, AND THAT IS THE LOAD-BEARING LINE.
#      Interleaved, 3 rounds, one subject, 2026-09-22, oracle = the rc of qvm-start:
#          --required + the stick's qemu-extra-args   rc=0  3/3
#          PLAIN      + the identical args            rc=1  3/3  "internal error: libxenlight
#                                                                 failed to create new domain"
#          --required + no args                       rc=0  3/3
#      MECHANISM (Jev: root_cause=plain-assign-is-a-hotplug 0.96, chain_established 0.13 - the
#      negative case has not yet been watched at the backend level, so this is the measured
#      pattern plus an inferred mechanism, and it is written down as exactly that):
#      a --required assignment is part of the domain's INITIAL configuration, so this qube serves
#      the VBD to the guest AND to its device-model stubdomain - measured, backends vbd-9468-51840
#      and vbd-9469-51840 for a guest whose xid was 9468. A plain assignment is attached AFTER the
#      domain exists, so the stubdomain's qemu cannot open /dev/xvdi, the device model never
#      signals ready, and libxl aborts the create at ~31 s. dom0's libxl log says only "startup
#      timed out" and "device model did not start: -9"; the stubdom console carries qemu's own
#      "Could not open '/dev/xvdi': No such file or directory".
#
#  [2] A DISC GOES IN AT START, NEVER AS A LIVE ATTACH.
#      `qvm-start <vm> --cdrom=<holder>:<loop>` works (measured in the 2026-09-22 campaign: the
#      release disc verified at D: with the expected driver_repo_commit). A LIVE
#      `qvm-device block attach -o devtype=cdrom` is refused by qubesd with "Got empty response
#      from qubesd" through BOTH the CLI and the raw python API, measured before AND after a full
#      host reboot - a persistent dom0-side defect, not a transient.
#
#  [3] LOOP NUMBERS ARE TRANSIENT AND `--required` CLAIMS PERSIST.
#      Recycled on every reboot and every `udisksctl loop-delete`. A golden carrying a stale claim
#      is UNSTARTABLE with only "libxenlight failed to create new domain" to show for it. Disarm
#      every subject when done: provision_disarm.
#
#  [4] ASSERT THE MEDIUM AFTER THE START.
#      prime-run once announced "the answer stick is NOT attached" for two whole campaigns when the
#      DOMAIN had never been created. A step that never checked the thing it names sends the next
#      session after the wrong subsystem.
set -u

# The emulated USB stick a PRISTINE Windows can read: it has no PV drivers, which is the entire
# reason an emulated medium exists here. xvdi = the answer stick; xvdj = the writable DIAG volume.
provision_stick_args() { # [stick-dev] [diag-dev] -> the qemu-extra-args string
    local s="${1:-xvdi}" d="${2:-}"
    local a="-drive file=/dev/$s,format=host_device,if=none,readonly=on,id=ansdrv"
    a="$a -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99"
    [ -n "$d" ] && a="$a -drive file=/dev/$d,format=host_device,if=none,id=diagdrv -device usb-storage,bus=ansusb.0,drive=diagdrv,removable=on"
    printf '%s' "$a"
}

provision_assign_stick() { # <vm> <holder> <loopN> [frontend-dev]
    local vm="$1" holder="$2" loop="$3" fe="${4:-xvdi}"
    # --required IS the recipe. Never make this a variable a caller can set to `plain`: that is
    # precisely the edit that cost 2026-09-21.
    timeout 60 qvm-device block assign --required -o "frontend-dev=$fe" -o devtype=disk \
        "$vm" "$holder:$loop" || { echo "provision: assign of $holder:$loop to $vm FAILED" >&2; return 1; }
    echo "provision: $holder:$loop assigned --required as $fe on $vm"
}

provision_boot_with_disc() { # <vm> <holder> <loopN> [timeout]
    local vm="$1" holder="$2" loop="$3" t="${4:-150}"
    [ "$(qvm-ls --raw-data --fields state "$vm" 2>/dev/null)" = Halted ] || {
        echo "provision: $vm must be Halted - the disc is a START-TIME attach and cannot be handed to a running guest" >&2
        return 1; }
    timeout -k 10 "$t" qvm-start "$vm" --cdrom="$holder:$loop"
}

provision_assert_medium() { # <vm> <holder> <loopN>
    local vm="$1" holder="$2" loop="$3" att
    # `qvm-device block list` is policy-refused from this qube, so read the HOLDER's own devices and
    # ask which domain each is attached to.
    att=$(timeout 90 python3 -c "
import qubesadmin
q=qubesadmin.Qubes(); me=q.domains['$holder']
print(','.join(d.port_id for d in me.devices['block']
                if getattr(getattr(d,'attachment',None),'name','')=='$vm') or 'NONE')" 2>/dev/null)
    case "$att" in
        *"$loop"*) echo "provision: $loop is ATTACHED to $vm (asserted, not assumed)"; return 0 ;;
        *) echo "provision: $vm started but $loop is NOT attached (attached: ${att:-unreadable}) - the guest is running with no medium and nothing about it is gradeable" >&2; return 1 ;;
    esac
}

provision_assert_stubdom_served() { # no args - reads this qube's own backends
    local doms
    doms=$(ls -d /sys/bus/xen-backend/devices/vbd-* 2>/dev/null | sed 's#.*/vbd-##; s#-.*##' | sort -u | tr '\n' ' ')
    local n; n=$(printf '%s' "$doms" | wc -w)
    echo "provision: this qube is serving block backends to domain(s): ${doms:-none}"
    [ "$n" -ge 2 ] || { echo "provision: only $n domain is being served - with --required the guest AND its stubdomain should both appear; tools/loopback-health.sh has the full read" >&2; return 1; }
}

provision_disarm() { # <vm> - no stale claim survives a run
    local vm="$1"
    timeout 60 python3 -c "
import qubesadmin
vm=qubesadmin.Qubes().domains['$vm']
for a in list(vm.devices['block'].get_assigned_devices()): vm.devices['block'].unassign(a)" 2>/dev/null
    qvm-features --unset "$vm" qemu-extra-args 2>/dev/null
    echo "provision: $vm disarmed (assignments cleared, qemu-extra-args unset)"
}

# --print: the recipe for a human, straight from this file's own header, so the two can never drift.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --print) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *) echo "usage: . ${BASH_SOURCE[0]}   (library)   |   ${BASH_SOURCE[0]} --print" >&2; exit 2 ;;
    esac
fi
