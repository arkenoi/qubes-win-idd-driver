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
# EXTEND THE PRIVATE VOLUME TOO. This is the THIRD script to need this fix, which is the point:
# scratchpad/reprovision.sh and mgmt/clone-to-template.sh both already do it, and this one - the
# script that builds the GOLDENS - did not, so every golden and every clone taken from it carried
# the Qubes default of 2 GiB.
#
# QWT's MoveUsers relocates C:\Users onto the private volume (stock behaviour; README says to check
# the size first). At 2 GiB it cannot complete, Q:\Users is never established, and then
# qubes.Filecopy fails with the file-receiver's own message:
#   "wmain: getting Documents path failed with error 0x80070002"
# which reads like a broken guest rather than a too-small disk. Measured 2026-08-30 on win10-app,
# derived from a 2 GiB-private golden: nothing could be pushed, so nothing could be tested.
#
# Runs BEFORE Windows installs, so QWT formats the volume at full size and no in-guest partition
# resize is needed. 20GiB per the owner ("40gb of private volumes is a waste, 20 should be
# typically enough").
qvm-volume extend "$VM:private" 20GiB || { log "FAIL: could not extend $VM:private"; exit 1; }
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
# COMPLETION CRITERION.
#
# RETRACTION (2026-08-30, same day it was written): an earlier version of this block declared a
# pristine build SUCCESSFUL when tools/winshot.py classified the screen as VERDICT=DESKTOP twice,
# 30 s apart. That is UNSOUND and it produced a false pass within minutes of being written:
# win11-gold0 reported "pristine desktop reached after 137s" while the screen was actually showing
# the Windows 11 Setup dialog "This PC doesn't currently meet Windows 11 system requirements".
# 137 s is not a Windows install. The classifier saw a light window on a dark ground and said
# DESKTOP; taking two samples changed nothing, because a static error dialog looks identical 30 s
# later. The protocol says this outright - "Screenshots are READ, not counted" and "DESKTOP means
# 'something renders', never 'step succeeded'" - and the gate was built on it regardless.
#
# So PRISTINE mode NO LONGER DECLARES SUCCESS. An ST0 image has no qrexec, the capture carries no
# window titles, and nothing else available here can distinguish a finished desktop from a Setup
# error screen. It waits for the screen to go quiet, SAVES the capture, and exits 3 =
# NEEDS-VISUAL-CONFIRMATION. A human or agent must READ that image before the qube is sealed.
# An honest "I cannot decide this" beats a gate that decides wrongly.
t0=$(date +%s)
QUIET=0
SHOTDIR="${PRISTINE_SHOTDIR:-$PWD/evidence/pristine-$VM-$(date -u +%Y%m%d-%H%M%S)}"
mkdir -p "$SHOTDIR"
_grab(){ # capture; echo the classifier verdict (advisory only, never a pass)
    # Do NOT delete latest.png up front: a failed capture (NOSHOT) would otherwise destroy the
    # last good image, which is the one a human needs to read.
    rm -f "$SHOTDIR"/s.tar "$SHOTDIR"/win-*.png 2>/dev/null
    QTEST_VM=$VM timeout 90 ./tools/qtest shot "$SHOTDIR/s.tar" >/dev/null 2>&1 || return 1
    tar -xf "$SHOTDIR/s.tar" -C "$SHOTDIR" 2>/dev/null || return 1
    # EXCLUDE latest.png from the candidates. It is the PREVIOUS iteration's image, so when a
    # capture produces no win-*.png this glob would select it, "succeed" by copying it onto itself
    # (the `cp: same file` noise in every log), and hand the classifier a STALE frame - reporting an
    # old screen as the current one. A failed capture must fail, not silently repeat itself.
    local big; big=$(ls -S "$SHOTDIR"/win-*.png 2>/dev/null | head -1)
    [ -n "$big" ] || return 1
    cp -f "$big" "$SHOTDIR/latest.png"
    ./tools/winshot.py --png "$big" 2>/dev/null | grep -oE 'VERDICT=[A-Z]+' | head -1
}

# CPU QUIESCENCE - the signal that was missing, and the reason 2026-08-30's win10-base was declared
# done while Windows Setup was still on "Installing updates". The header above has always claimed
# this loop "waits for the screen to go quiet"; it never did. The only conditions were the
# classifier's DESKTOP verdict and 900 s elapsed, and §0.8 already records that the classifier calls
# Setup dialogs DESKTOP. So the gate fired at the earliest instant it could, abandoned a guest
# mid-install with nothing left to restart it on its next reboot, and let the caller start a SECOND
# Windows guest concurrently.
#
# admin.vm.Stats needs no qrexec, which matters because this guest has none. Setup copying files and
# installing updates is busy; a settled desktop is not. Same probe matrix.sh uses in verify_installed.
# PARSE THE STREAM PROPERLY. admin.vm.Stats emits repeating NULL-separated records:
#   win10-base \0 vm-stats \0 memory_kb \0 8388656 \0 cpu_time \0 ... \0 cpu_usage_raw \0 0 \0
# The first version of this did `tr -d '\0'` and then `grep -oE 'cpu_usage_raw[0-9]+'`, which is
# wrong twice over: deleting the separators runs the value into the NEXT record (a real value of 3
# was read as "31"), and it then SUMMED every record in the whole 20 s stream. Measured 2026-08-30
# on a genuinely idle guest: the probe reported 149 and 6225 where the true value was 3, so the
# `quiet` threshold could never be met and the build would have spun to its 90-minute budget and
# failed with the install long since finished.
# Translate NULLs to newlines and read the value on the line AFTER each cpu_usage_raw key; report
# the MAX across the sampled window, so a brief idle moment inside heavy work does not read as calm.
_cpu(){
    printf '' | timeout 10 qrexec-client-vm "$VM" admin.vm.Stats 2>/dev/null | tr '\0' '\n' \
        | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print 9999; else print m}'
}
while [ $(( $(date +%s) - t0 )) -lt "$BUDGET" ]; do
    if [ "${PRISTINE:-0}" = 1 ]; then
        v=$(_grab || echo NOSHOT)
        el=$(( $(date +%s) - t0 ))
        # MINIMUM PLAUSIBLE INSTALL TIME. Win10 measured 17-20 min; nothing that "finishes" in
        # three minutes installed an operating system. This alone would not have caught the false
        # pass safely, which is why the verdict below is still not a pass.
        # MATCH WHAT _grab ACTUALLY ECHOES. It returns the full match "VERDICT=DESKTOP" (grep -oE
        # 'VERDICT=[A-Z]+'), so comparing against the bare word "DESKTOP" was never true and this
        # exit was UNREACHABLE - the same defect species as RB-03, written by me while fixing RB-03.
        # Measured: win11-gold0 sat at a finished desktop logging "screen=VERDICT=DESKTOP (advisory)"
        # for ~35 minutes past the 900 s floor without ever exiting.
        c=$(_cpu)
        if [ "$v" = "VERDICT=DESKTOP" ] && [ "${c:-9999}" -lt 15 ] 2>/dev/null; then
            QUIET=$((QUIET+1))
        else
            QUIET=0
        fi
        [ -n "$v" ] && log "  t+${el}s screen=$v cpu=${c:-?} quiet=$QUIET (all advisory)"
        # THREE conditions, not one: past the minimum plausible install time, the classifier sees a
        # desktop, AND the guest has been CPU-idle for three consecutive samples (~90 s). A busy
        # Setup screen fails the third even when it fools the first two - which is exactly what
        # happened on 2026-08-30.
        if [ "$el" -ge 900 ] && [ "$QUIET" -ge 3 ]; then
            log "candidate desktop after ${el}s: verdict=$v, cpu idle for $QUIET consecutive samples"
            log "NEEDS VISUAL CONFIRMATION - READ $SHOTDIR/latest.png before sealing this qube."
            log "  A Setup error dialog also classifies as DESKTOP; the classifier cannot decide this."
            log "  An idle guest is not necessarily a FINISHED one - a Setup dialog awaiting input is idle too."
            exit 3
        fi
    # -ge 2, not -ge 1, because qtest run echoes the prompt line WITH THE COMMAND on it, so
    # 'echo BOOT_OK' always matches once from the echo alone. Two matches = the guest actually ran it.
    # (Stated explicitly because the same echo silently inflated counts in two other harnesses.)
    elif [ "$(QTEST_VM=$VM timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | tr -d '\r\0' | grep -c BOOT_OK)" -ge 2 ]; then
        log "qrexec alive after $(( $(date +%s) - t0 ))s"
        exit 0
    fi
    [ "$(state)" = Halted ] && { log "install-phase halt -> restarting without CD"; timeout 90 qvm-start "$VM" >/dev/null 2>&1; }
    sleep 30
done
if [ "${PRISTINE:-0}" = 1 ]; then
    log "FAIL: no candidate desktop within ${BUDGET}s (last capture in $SHOTDIR)"
else
    log "FAIL: never reached qrexec within ${BUDGET}s"
fi
exit 1
