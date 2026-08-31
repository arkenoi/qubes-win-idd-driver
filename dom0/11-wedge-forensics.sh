#!/bin/bash
# Run IN DOM0, AT THE MOMENT OF A WEDGE, BEFORE any kill/restart.
# One command captures everything the guest-side instruments cannot see, then
# (optionally) fires the NMI that makes Windows write a kernel dump naming the
# spinning code. Nothing here is destructive except --nmi, which deliberately
# bugchecks the guest (it reboots itself afterwards and the dump survives).
#
#   sudo ./11-wedge-forensics.sh <vm>            # capture only
#   sudo ./11-wedge-forensics.sh <vm> --nmi      # capture, then NMI (guest bugchecks)
#
# THE VM IS AN ARGUMENT NOW. It used to be `VM="${VM:-win-idd-test}"` with no way to pass one
# except an environment variable that sudo often refuses to forward - so during a LIVE wedge on
# win10-app (2026-09-01) the documented invocation would have aborted with "FATAL: win-idd-test
# not running", against a qube that has not booted for weeks, and the evidence would have been
# lost while someone worked out why. A forensics tool that defaults to the wrong subject at the
# only moment it matters is worse than no tool. Env VM= still works, for the qrexec service.
#
# Results land in ~/wedge-<timestamp>/ and are copied to the dev qube at the end.
set -u
DEV="${DEV:-win-idd-mgmt}"
NMI=0
VM="${VM:-}"
for a in "$@"; do
    case "$a" in
        --nmi) NMI=1 ;;
        -*)    echo "unknown option: $a" >&2; exit 2 ;;
        *)     VM="$a" ;;
    esac
done
if [ -z "$VM" ]; then
    echo "usage: $0 <vm> [--nmi]     (or VM=<vm> $0 [--nmi])" >&2
    echo "running domains:" >&2
    xl list 2>/dev/null | awk 'NR>1 && $1!="Domain-0" {print "  " $1}' >&2
    exit 2
fi

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

# 5. Consoles. NOTE (2026-09-01): plain `xl console $DOMID` could NEVER have worked here.
#    A Qubes HVM has a stubdomain, so libxl__primary_console_find() redirects the default to
#    the STUBDOM's console 3 (STUBDOM_CONSOLE_SERIAL) - and libxl only creates that console
#    when the guest has an emulated serial port (libxl_dm.c: `if (b_info->u.hvm.serial)
#    num_console++`). Qubes' libvirt template emits no <serial>, so nserials==0, the stubdom
#    gets consoles 0-2 only, and xenconsole dies on the missing tty node (qubes-issues #3039;
#    the "buffer overflow detected" crash logged on 2026-08-04 was this call). `-t pv` targets
#    the GUEST's own Xen PV console ring instead - the one xenconsoled logs to guest-$VM.log.
timeout 6 xl console -t pv "$DOMID" > "$OUT/console-pv.txt" 2>&1 || true

# 5b. guest-$VM.log = the guest's PV console ring. Since 4.3.16 we ship xencons, so that ring
#     carries an interactive cmd.exe (xencons_monitor -> xencons_tty -> cmd.exe /q /a) and the
#     log is a real transcript, not just firmware output. guest-$VM-dm.log = the stubdomain's
#     logging console, where a `qemu-extra-args '-serial file:/dev/hvc0'` feature would land
#     guest COM1/EMS output (pre-Windows and high-IRQL coverage xencons cannot give).
for f in "/var/log/xen/console/guest-$VM.log" "/var/log/xen/console/guest-$VM-dm.log"; do
    [ -f "$f" ] && tail -c 262144 "$f" > "$OUT/$(basename "$f")" 2>/dev/null
done
# What libvirt believes the console pty is - "" here means qvm-console is structurally dead
# for this domain (admin.vm.Console returns /domain/devices/console/@tty verbatim).
virsh -c xen:/// dumpxml "$VM" 2>/dev/null | grep -E '<(console|serial)|@?tty=' > "$OUT/libvirt-console.txt" 2>&1 || true

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
