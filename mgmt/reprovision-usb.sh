#!/bin/bash
# Re-provision a Windows test qube from the UNTOUCHED vendor ISO plus an emulated USB answer
# stick. This is the route FINDINGS 2026-08-07 measured as working; scratchpad/reprovision.sh
# still implements the older second-CD variant, which cannot work (WinPE has no Xen PV
# drivers, so an assigned cdrom device is invisible to Setup).
#
# Usage: mgmt/reprovision-usb.sh <vm> <vendor-iso-loop> <answer-stick-loop>
#   e.g. mgmt/reprovision-usb.sh win10-clean loop0 loop9
# Build the stick first: mgmt/build-answer-stick.sh (keep SIZE_MB constant so the loop
# device's cached capacity stays valid - it is rewritten in place, no root needed).
set -u
VM="${1:?usage: $0 <vm> <iso-loop> <stick-loop>}"
ISOLOOP="${2:?}"
STICKLOOP="${3:?}"
HOLDER=win-idd-mgmt
BUDGET=${BUDGET:-5400}
# PRISTINE=1: building an ST0 (QWT-free) image. Success is a settled DESKTOP on screen rather than
# qrexec, which such an image never gets. See the completion-criterion note at the wait loop.
PRISTINE=${PRISTINE:-0}

log() { echo "$(date -u +%H:%M:%S) reprovision-usb: $*"; }
state() { qvm-ls --raw-data --fields state "$VM" 2>/dev/null; }

exec 9>"/tmp/reprovision-$VM.lock"
flock -n 9 || { log "another reprovision is already running for $VM - refusing"; exit 1; }

# The stick is served from a loop device whose capacity is cached at losetup time. A rebuilt
# image of a DIFFERENT size would be served truncated and Setup would silently fall back to
# the interactive picker - indistinguishable from "the answer file was ignored" an hour later.
exposed=$(( $(cat "/sys/block/$STICKLOOP/size") * 512 ))
backing=$(losetup -l | awk -v d="/dev/$STICKLOOP" '$1==d{print $6}')
actual=$(stat -c%s "$backing" 2>/dev/null || echo 0)
[ "$exposed" = "$actual" ] || { log "FAIL: /dev/$STICKLOOP exposes $exposed but $backing is $actual"; exit 1; }
case "$backing" in *"(deleted)"*) log "FAIL: $STICKLOOP backs a DELETED inode - the guest would read a stale stick"; exit 1 ;; esac
log "answer stick verified: /dev/$STICKLOOP -> $backing ($actual bytes)"

if [ -n "$(state)" ]; then
    log "shutting down $VM"
    timeout 200 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || { log "force kill"; timeout 60 qvm-kill "$VM" >/dev/null 2>&1; sleep 5; }
    # Clean slate: the disk must be EMPTY or SeaBIOS falls through to a diskless boot.
    log "removing $VM"
    timeout 300 qvm-remove -f "$VM" >/dev/null 2>&1 || { log "FAIL remove"; exit 1; }
fi

log "creating $VM"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$VM" || exit 1
qvm-prefs "$VM" memory 8192
qvm-prefs "$VM" maxmem 8192
qvm-prefs "$VM" vcpus 4
qvm-prefs "$VM" qrexec_timeout 300
qvm-prefs "$VM" netvm ''
qvm-volume extend "$VM:root" 80GiB
qvm-features "$VM" os Windows
qvm-tags "$VM" add win-idd-testbed

# The stick reaches the guest as an emulated USB mass storage device: the PV block device is
# handed to the stubdom as xvdi and QEMU re-exports it over an xHCI controller. bootindex=99
# keeps it out of the boot order.
qvm-features "$VM" qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99' || exit 1
qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$VM" "$HOLDER:$STICKLOOP" || exit 1
# Positive proof the assignment stuck: this qube may not LIST block devices, but a second
# assign answers "already assigned" exactly when the first one took effect.
proof=$(qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$VM" "$HOLDER:$STICKLOOP" 2>&1)
case "$proof" in
    *"already assigned"*) log "answer stick assignment verified" ;;
    *) log "FAIL: stick assignment did not stick - re-assign said: $proof"; exit 1 ;;
esac

log "booting the vendor ISO ($ISOLOOP) with the answer stick ($STICKLOOP)"
qvm-start "$VM" --cdrom="$HOLDER:$ISOLOOP" || exit 1

# Setup reboots several times and each guest reboot destroys the domain, so restart WITHOUT
# the CD until qrexec answers.
# COMPLETION CRITERION. Two of them, because a QWT-free provision can never satisfy the qrexec one.
#
# PRISTINE=1 builds an ST0 image: the answer stick carries no QWT payload (RELEASE_SETUP unset), so
# no gui-agent and no qrexec agent are ever installed. §2.1 states this plainly - ST0 is "No qrexec
# - undriveable" - yet this script's only success test was `qrexec alive`, which such an image
# cannot reach BY CONSTRUCTION. A successful pristine install therefore ran to the desktop and then
# sat here until BUDGET (5400 s) expired, to be reported as "FAIL: never reached qrexec".
# Measured 2026-08-30: win10-gold0 reached a clean Win10 desktop in ~20 min and the script was still
# waiting 17 minutes later, having logged nothing since boot.
#
# For a pristine image the SCREEN is the only channel that exists, so it is the criterion - which is
# also the project's standing rule that the evidence is pixels, not logs.
t0=$(date +%s)
SHOTDIR=$(mktemp -d); trap 'rm -rf "$SHOTDIR"' EXIT
_desktop(){ # 0 = the guest is showing a usable desktop
    rm -rf "$SHOTDIR"/* 2>/dev/null
    QTEST_VM=$VM timeout 90 ./tools/qtest shot "$SHOTDIR/s.tar" >/dev/null 2>&1 || return 1
    tar -xf "$SHOTDIR/s.tar" -C "$SHOTDIR" 2>/dev/null || return 1
    local big; big=$(ls -S "$SHOTDIR"/*.png 2>/dev/null | head -1)
    [ -n "$big" ] || return 1
    ./tools/winshot.py --png "$big" 2>/dev/null | grep -q 'VERDICT=DESKTOP'
}
while [ $(( $(date +%s) - t0 )) -lt "$BUDGET" ]; do
    if [ "${PRISTINE:-0}" = 1 ]; then
        # Require it TWICE, 30 s apart: one DESKTOP frame can be caught mid-OOBE. Two is a settled
        # desktop, not a transient.
        if _desktop; then
            sleep 30
            if _desktop; then
                log "pristine desktop reached after $(( $(date +%s) - t0 ))s (no qrexec expected - ST0)"
                exit 0
            fi
        fi
    elif [ "$(QTEST_VM=$VM timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | tr -d '\r\0' | grep -c BOOT_OK)" -ge 2 ]; then
        log "qrexec alive after $(( $(date +%s) - t0 ))s"
        exit 0
    fi
    [ "$(state)" = Halted ] && { log "install-phase halt -> restarting without CD"; timeout 90 qvm-start "$VM" >/dev/null 2>&1; }
    sleep 30
done
if [ "${PRISTINE:-0}" = 1 ]; then
    log "FAIL: never reached a settled desktop within ${BUDGET}s"
else
    log "FAIL: never reached qrexec within ${BUDGET}s"
fi
exit 1
