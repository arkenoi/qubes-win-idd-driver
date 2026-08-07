#!/bin/bash
# TEST: present the answer file + payload to Windows Setup on an EMULATED USB STICK, so the
# vendor ISO is booted untouched and NEVER rebuilt. If this works it replaces the 5.8 GB
# grafted-ISO rebuild (which bakes the payload into the image, forcing a full rebuild on
# every payload change) with a 96 MB image that rebuilds in seconds.
#
# Why USB and not a second CD: `qvm-device block assign --option devtype=cdrom` creates a Xen
# PV device, and WinPE carries no PV drivers, so Setup never sees it (measured 2026-08-07,
# twice). WinPE DOES have USBSTOR/USBXHCI inbox, and Windows Setup's documented implicit
# search order includes the root of removable media.
set -u
cd /home/user/qubes-win-idd-driver
VM=win10-clean
USB_LOOP=${USB_LOOP:-loop9}
ISO_LOOP=${ISO_LOOP:-loop0}
HOLDER=win-idd-mgmt
log(){ echo "$(date -u +%H:%M:%S) usbtest: $*"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

if [ -n "$(state)" ]; then
    log "removing $VM"
    timeout 200 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 20); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || timeout 60 qvm-kill "$VM" >/dev/null 2>&1
    sleep 3
    timeout 200 qvm-remove -f "$VM" >/dev/null 2>&1 || { log "FAIL remove"; exit 1; }
fi

log "creating $VM"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$VM" || exit 1
qvm-prefs "$VM" memory 8192
qvm-prefs "$VM" maxmem 8192
qvm-prefs "$VM" vcpus 4
qvm-prefs "$VM" qrexec_timeout 300
qvm-prefs "$VM" netvm core-net
qvm-volume extend "$VM:root" 80GiB
qvm-features "$VM" os Windows
qvm-tags "$VM" add win-idd-testbed

# The stick must be a disk (NOT devtype=cdrom) at a frontend outside the emulated IDE range,
# so libxl declines to emulate it and hands it to the stubdom as /dev/xvdi - which our own
# QEMU line then re-presents as a USB mass storage device.
log "assigning the stick at xvdi"
qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk \
    "$VM" "$HOLDER:$USB_LOOP" 2>&1 | tail -2

# bootindex=99 keeps the stick OUT of the boot order. Without it SeaBIOS may try it, and
# more importantly the guest disk must stay EMPTY: a disk carrying a partition table from a
# previous partial Setup makes SeaBIOS show "Press any key to boot from CD or DVD", nobody
# presses one, and it falls through to the disk -> "An operating system wasn't found".
# That is why this script RECREATES the VM (fresh root volume) rather than restarting it.
log "setting qemu-extra-args (emulate it as a removable USB mass storage device)"
qvm-features "$VM" qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'
qvm-features "$VM" | grep qemu-extra-args | head -1

log "booting from the UNTOUCHED vendor ISO ($ISO_LOOP)"
qvm-start "$VM" --cdrom="$HOLDER:$ISO_LOOP" 2>&1 | tail -3
log "start rc=$? state=$(state)"
