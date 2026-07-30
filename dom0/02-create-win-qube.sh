#!/bin/bash
# Run IN DOM0. Creates the disposable-in-spirit Windows test qube for IDD driver work.
# Standalone HVM, no network, generous disk. Windows itself installed manually once.
set -euo pipefail

VM="${1:-win-idd-test}"

if qvm-ls --raw-list | grep -qx "$VM"; then
    echo "$VM already exists; not touching it." >&2; exit 1
fi

qvm-create --class StandaloneVM --label red \
    --property virt_mode=hvm \
    --property kernel='' \
    "$VM"

qvm-prefs "$VM" memory 8192
qvm-prefs "$VM" maxmem 8192          # no ballooning games during driver tests
qvm-prefs "$VM" vcpus 4              # 4 on purpose: also reproduces #10932/#10427 conditions;
                                     # drop to 2 if seamless is too glitchy to test against
qvm-prefs "$VM" netvm ''             # offline: everything arrives via qrexec Filecopy
qvm-prefs "$VM" qrexec_timeout 300   # Windows boots slowly
qvm-volume extend "$VM:root" 80GiB

# Tell Qubes this is Windows (input/GUI/QWT integration niceties)
qvm-features "$VM" os Windows
# Audio/USB intentionally not configured.

echo "Created $VM. Next:"
echo "  qvm-start $VM --cdrom=<download-qube>:/home/user/win-iso/<iso-name>"
echo "Then: install Windows (local account), install QWT 4.2.2 per current docs,"
echo "run guest/firstboot-setup.ps1 inside, reboot."
