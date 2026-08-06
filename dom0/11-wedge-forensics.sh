#!/bin/bash
# Run IN DOM0, AT THE MOMENT OF A WEDGE, BEFORE any kill/restart.
# One command captures everything the guest-side instruments cannot see, then
# (optionally) fires the NMI that makes Windows write a kernel dump naming the
# spinning code. Nothing here is destructive except --nmi, which deliberately
# bugchecks the guest (it reboots itself afterwards and the dump survives).
#
#   sudo ./11-wedge-forensics.sh            # capture only
#   sudo ./11-wedge-forensics.sh --nmi      # capture, then NMI (guest bugchecks)
#
# Results land in ~/wedge-<timestamp>/ and are copied to the dev qube at the end.
set -u
VM="${VM:-win-idd-test}"
DEV="${DEV:-win-idd-mgmt}"
NMI=0
[ "${1:-}" = "--nmi" ] && NMI=1

OUT=~/wedge-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
echo "capturing to $OUT"

DOMID=$(xl list 2>/dev/null | awk -v v="$VM" '$1==v{print $2}')
if [ -z "$DOMID" ]; then echo "FATAL: $VM not running per xl list" >&2; exit 1; fi
echo "domid=$DOMID" | tee "$OUT/domid.txt"

# 1. Is it spinning, and on how many vCPUs? (two samples, 10 s apart)
xl list -l "$VM" > "$OUT/xl-list-long.json" 2>&1
xentop -b -i2 -d5 2>/dev/null | grep -E "NAME|$VM" > "$OUT/xentop.txt"
xl vcpu-list "$DOMID" > "$OUT/vcpu-list-1.txt" 2>&1
sleep 10
xl vcpu-list "$DOMID" > "$OUT/vcpu-list-2.txt" 2>&1

# 2. THE grant table: how many entries, how many still pinned by dom0.
#    (debug-keys output goes to the hypervisor ring, so dump it right after.)
xl debug-keys g 2>/dev/null
sleep 2
xl dmesg > "$OUT/xl-dmesg.txt" 2>&1
grep -A100000 "grant-table for remote d$DOMID" "$OUT/xl-dmesg.txt" \
    | head -200 > "$OUT/granttable-head.txt" 2>/dev/null
echo "grant entries (this domain, active):" > "$OUT/grant-summary.txt"
awk "/grant-table for remote d$DOMID/,/gnttab_usage_print_all/" "$OUT/xl-dmesg.txt" \
    | grep -cE '^\(XEN\) \[0x' >> "$OUT/grant-summary.txt" 2>/dev/null

# 3. Event channels (the qrexec/gui vchan path) and domain state
xl debug-keys e 2>/dev/null; sleep 2
xl dmesg | tail -300 > "$OUT/xl-dmesg-evtchn.txt" 2>&1
xl debug-keys q 2>/dev/null; sleep 2
xl dmesg | tail -200 > "$OUT/xl-dmesg-domains.txt" 2>&1

# 4. gui-daemon: alive? what did it last say? (log is perishable - copy now)
ps aux | grep "[g]uid.*$VM" > "$OUT/guid-ps.txt" 2>&1
cp "/var/log/qubes/guid.$VM.log" "$OUT/" 2>/dev/null
cp "/var/log/qubes/qrexec.$VM.log" "$OUT/" 2>/dev/null

# 5. Serial console (may be empty; xl console has crashed here before - bounded)
timeout 6 xl console "$DOMID" > "$OUT/console.txt" 2>&1 || true

echo "--- summary ---" | tee -a "$OUT/grant-summary.txt"
grep -E "Mem|VCPUs|state" "$OUT/xentop.txt" 2>/dev/null | tail -2
cat "$OUT/grant-summary.txt"

if [ "$NMI" = 1 ]; then
    echo "firing NMI -> guest will bugcheck and write C:\\Windows\\MEMORY.DMP, then reboot"
    xl trigger "$DOMID" nmi
    echo "NMI sent at $(date -u +%H:%M:%S)" >> "$OUT/domid.txt"
fi

tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
qvm-copy-to-vm "$DEV" "$OUT.tar.gz" 2>/dev/null && echo "sent $OUT.tar.gz to $DEV"
echo "done: $OUT"
