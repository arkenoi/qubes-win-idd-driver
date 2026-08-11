#!/bin/bash
# Run IN DOM0. Installs qvm-windows-update: drive a Windows guest's updates FROM dom0, the same
# model as Linux qubes (guest never auto-installs; dom0 decides when).
#
# Guest side (shipped by install.cmd /updatesonly): a scheduled scan-only task reports
# availability via qubes.NotifyUpdates (lights the same updates-available flag Linux templates
# use), and the qubes.WindowsUpdate rpc service performs the update when dom0 calls it, speaking
# the qubes-vm-update agent protocol: bare float progress lines 0..100 on stderr, exit 0 =
# success, exit 100 = no updates. This wrapper renders that protocol. Stock qubes-vm-update
# cannot drive Windows directly (it injects a Python agent), hence the thin wrapper; the
# protocol match keeps a future upstream integration mechanical.
#
# dom0-initiated calls need no qrexec policy.
#
# Usage:   ./14-install-qvm-windows-update.sh
# Then:    qvm-windows-update <qube> [qube...]   |   qvm-windows-update --all
# Remove:  rm /usr/local/bin/qvm-windows-update
set -euo pipefail

cat > /usr/local/bin/qvm-windows-update <<'WRAP'
#!/bin/bash
# Update Windows qubes from dom0 via the qubes.WindowsUpdate guest service (QWT-NG).
# --all = every running qube with feature os=Windows reporting updates-available.
set -uo pipefail

usage() { echo "usage: qvm-windows-update <qube> [qube...] | --all" >&2; exit 2; }
[ $# -ge 1 ] || usage

if [ "$1" = "--all" ]; then
    mapfile -t QUBES < <(qvm-ls --running --raw-list | while read -r vm; do
        [ "$(qvm-features "$vm" os 2>/dev/null)" = "Windows" ] || continue
        avail="$(qvm-features "$vm" updates-available 2>/dev/null)" || continue
        [ -n "$avail" ] && [ "$avail" != "0" ] && echo "$vm"
    done)
    [ ${#QUBES[@]} -gt 0 ] || { echo "no running Windows qubes report updates available"; exit 0; }
else
    QUBES=("$@")
fi

overall=0
for vm in "${QUBES[@]}"; do
    echo "=== $vm ==="
    qvm-run --service --no-gui --pass-io "$vm" qubes.WindowsUpdate \
        2> >(while IFS= read -r line; do
                 if [[ "$line" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                     printf '\r  progress: %5.1f%%   ' "$line" >&2
                 else
                     printf '\n  %s\n' "$line" >&2
                 fi
             done; printf '\n' >&2)
    rc=$?
    case $rc in
        0)   echo "  $vm: done (a restart of the qube may be required - see messages above)";;
        100) echo "  $vm: no updates"; rc=0;;
        *)   echo "  $vm: FAILED rc=$rc"; overall=1;;
    esac
done
exit $overall
WRAP
chmod 755 /usr/local/bin/qvm-windows-update
echo "installed /usr/local/bin/qvm-windows-update"
