#!/bin/bash
# Clean-room provision: boot the UNTOUCHED vendor ISO, deliver autounattend.xml + the QWT
# payload on an emulated USB stick. Generalised from the win10 proof so win11 uses the same
# path. See FINDINGS 2026-08-07 "CLEAN ROOM WORKS".
#
# Usage: usb-provision.sh <vm> <iso-loop> <stick-loop> [netvm]
set -u
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> <iso-loop> <stick-loop> [netvm]}"
ISO_LOOP="${2:?}"
USB_LOOP="${3:?}"
NETVM="${4:-core-net}"
HOLDER=win-idd-mgmt
log(){ echo "$(date -u +%H:%M:%S) provision[$VM]: $*"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

exec 9>"/tmp/usb-provision-$VM.lock"
flock -n 9 || { log "another provision is running for $VM - refusing"; exit 1; }

if [ -n "$(state)" ]; then
    log "removing $VM (clean slate; the disk MUST be empty or SeaBIOS prompts and falls through to a diskless boot)"
    timeout 200 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 24); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || timeout 60 qvm-kill "$VM" >/dev/null 2>&1
    sleep 4
    timeout 200 qvm-remove -f "$VM" >/dev/null 2>&1 || { log "FAIL remove"; exit 1; }
fi

log "creating $VM (netvm=$NETVM)"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$VM" || exit 1
qvm-prefs "$VM" memory 8192
qvm-prefs "$VM" maxmem 8192
qvm-prefs "$VM" vcpus 4
qvm-prefs "$VM" qrexec_timeout 300
qvm-prefs "$VM" netvm "$NETVM"
qvm-volume extend "$VM:root" 80GiB
qvm-features "$VM" os Windows
qvm-tags "$VM" add win-idd-testbed

log "assigning the stick at xvdi (disk, NOT cdrom - an assigned cdrom is a PV device WinPE cannot see)"
qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$VM" "$HOLDER:$USB_LOOP" 2>&1 | tail -1

# bootindex=99 keeps the stick out of the boot order.
log "qemu-extra-args: present it as removable USB mass storage"
qvm-features "$VM" qemu-extra-args -- "-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99"
qvm-features "$VM" | grep -q qemu-extra-args || { log "FAIL: qemu-extra-args did not stick"; exit 1; }

log "booting the UNTOUCHED vendor ISO ($ISO_LOOP)"
qvm-start "$VM" --cdrom="$HOLDER:$ISO_LOOP" >/dev/null 2>&1
log "state=$(state)"
