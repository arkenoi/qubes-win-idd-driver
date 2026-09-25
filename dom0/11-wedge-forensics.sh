#!/bin/bash
# Run IN DOM0, AT THE MOMENT OF A WEDGE, BEFORE any kill/restart.
# One command captures everything the guest-side instruments cannot see, then
# (optionally) fires the NMI that makes Windows write a kernel dump naming the
# spinning code. Nothing here is destructive except --nmi, which deliberately
# bugchecks the guest (it reboots itself afterwards and the dump survives).
#
#   sudo ./11-wedge-forensics.sh <vm>              # capture only
#   sudo ./11-wedge-forensics.sh <vm> --nmi        # capture, then NMI (guest bugchecks)
#   sudo ./11-wedge-forensics.sh <vm> --dump-core  # capture, then a full guest memory image
#
# --dump-core (added 2026-09-20) is the ONLY remaining route to name the spinning code of the
# multi-vCPU wedge: the NMI route was tried on 2026-09-10 and produced NO bugcheck and no dump,
# for a self-consistent reason - a bugcheck must freeze the other processors with IPIs, so if IPI
# delivery is what is wedged, the crash path deadlocks too. `xl dump-core` needs no guest
# cooperation at all. It is NOT destructive (the domain is paused for the write, not killed), but
# it writes roughly the guest's RAM to disk - about 8 GB for an 8192 MB guest - so it checks for
# free space first and REFUSES rather than filling dom0's root. The image STAYS IN DOM0 and is
# never copied to the dev qube: 8 GB would not fit there, and the dev qube does not need it.
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
DEV="${DEV:?set DEV to the dev qube - there is no default target}"
NMI=0
DUMPCORE=0
SPINSHAPE=0
VM="${VM:-}"
for a in "$@"; do
    case "$a" in
        --nmi) NMI=1 ;;
        --dump-core) DUMPCORE=1 ;;
        -*)    echo "unknown option: $a" >&2; exit 2 ;;
        *)     VM="$a" ;;
    esac
done
if [ -z "$VM" ]; then
    echo "usage: $0 <vm> [--nmi] [--dump-core]     (or VM=<vm> $0 ...)" >&2
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
#    debug-keys output goes to the hypervisor ring, which is SMALL. On the 2026-09-01 capture
#    `g` printed ~1952 entry lines and the ring WRAPPED: by the time `xl dmesg` ran, the only
#    "grant-table for remote dN" header left was the STUBDOM's (d4612), not the guest's (d4611).
#    The summary below then reported "grant entries (this domain, active): 0" - which reads as
#    the finding "no grant leak" and is really "we captured nothing". CLEAR the ring first so it
#    holds our output and nothing else; -c prints-and-clears, so keep the pre-existing contents.
xl dmesg -c > "$OUT/xl-dmesg-before.txt" 2>&1
xl debug-keys g 2>/dev/null
sleep 2
xl dmesg > "$OUT/xl-dmesg.txt" 2>&1
if ! grep -q "grant-table for remote d$DOMID" "$OUT/xl-dmesg.txt"; then
    echo "WARNING: no grant table for d$DOMID in the captured ring - it wrapped or the domain" \
         "printed none. Treat any count below as MISSING DATA, not as zero." \
         > "$OUT/grant-CAPTURE-INCOMPLETE.txt"
fi
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

# 3b. vCPU REGISTERS - THE RIP. This is the capture every stall specimen has been missing.
#    `d` is dump_registers: it dumps each PHYSICAL CPU's state, and prints a guest's registers
#    only for a vCPU that is CURRENTLY RUNNING on that pCPU. A spinning vCPU is therefore caught
#    (it is running); a vCPU that is blocked or descheduled - the waiting side of a lock spin -
#    is NOT dumped by any key. So "no RIP for dNvM" here means "not running at that instant",
#    never "not spinning". `v` (vmcs_dump) prints VMX state incl. the last exit reason for EVERY
#    HVM domain x vCPU, which on a dom0 with many qubes can wrap the ring by itself. Nine wedges
#    were recorded with g/e/q only, so each one's spin site stayed a guess; with the per-boot
#    module bases arm-module-bases.sh records, a RIP here resolves to driver+offset via
#    tools/resolve-guest-rip.py. Same ring discipline as `g` above: clear first, and a SECOND
#    dump a few seconds later so a spin (same RIP twice) can be told from progress.
xl dmesg -c > "$OUT/xl-dmesg-before-regs.txt" 2>&1
xl debug-keys d 2>/dev/null; sleep 2
xl dmesg > "$OUT/xl-dmesg-vcpu-regs-1.txt" 2>&1
sleep 5
xl dmesg -c >/dev/null 2>&1
xl debug-keys d 2>/dev/null; sleep 2
xl dmesg > "$OUT/xl-dmesg-vcpu-regs-2.txt" 2>&1
xl dmesg -c >/dev/null 2>&1
xl debug-keys v 2>/dev/null; sleep 2
xl dmesg > "$OUT/xl-dmesg-vmx.txt" 2>&1

# --- The Xen-side half, EXTRACTED so it gets read rather than archived (added 2026-09-25).
#     `xl debug-keys v` prints, per vCPU, the VMCS guest-interrupt-status field: RVI in the low
#     byte - a vector LATCHED for delivery - and SVI in the high. That is the direct answer to
#     "did the IPI ever reach the target's vLAPIC", which findings/wedge.md had recorded for weeks
#     as THE open link and as "invisible from any guest dump by construction". It was never
#     invisible: four bundles sat unread on the dev qube with the field in them, one of them
#     showing RVI=0xE1 - the Windows IPI vector - pending on a vCPU that never took it while three
#     others spun in nt!KiIpiSendRequestEx waiting for exactly that acknowledgement. An 1800-line
#     hypervisor log that nobody opens is not evidence, so pull this domain's block out here.
awk -v d=">>> Domain $DOMID <<<" '$0~d{f=1;next} f&&/>>> Domain/{f=0} f' \
    "$OUT/xl-dmesg-vmx.txt" > "$OUT/vmcs-d$DOMID.txt" 2>/dev/null
if [ ! -s "$OUT/vmcs-d$DOMID.txt" ]; then
    echo "WARNING: no VMCS block for d$DOMID - the hypervisor ring wrapped before \`xl dmesg\` ran." \
         "MISSING DATA: nothing about interrupt delivery may be concluded from this capture." \
         > "$OUT/vmcs-CAPTURE-INCOMPLETE.txt"
else
    grep -E 'VCPU|InterruptStatus|reason=' "$OUT/vmcs-d$DOMID.txt" > "$OUT/vmcs-summary.txt" 2>/dev/null
    # SPIN shape = a PAUSE-loop exit (reason 0x28), or any vector latched and not being taken.
    if grep -qE 'reason=00000028' "$OUT/vmcs-d$DOMID.txt" 2>/dev/null \
       || grep -E 'InterruptStatus = [0-9a-f]+' "$OUT/vmcs-d$DOMID.txt" 2>/dev/null \
          | grep -qvE 'InterruptStatus = 0000'; then
        SPINSHAPE=1
    fi
fi
# Pull this domain's RIPs out so the next reader does not have to: one line per vCPU per dump.
# Xen's _show_registers prints "RIP:    %04x:[<%016lx>]" (xen/arch/x86/x86_64/traps.c) for HVM
# guests too, under a "guest state (dNvM)" header from dump_execstate. The first version of this
# used 'RIP:\s*[0-9a-f:]+\s*[0-9a-f]+', which stops at the '[<' and captured ONLY THE CS SELECTOR
# ("RIP:    0010") - every rip file would have been useless to tools/resolve-guest-rip.py, which
# is the whole point of the block. And an unanchored "d$DOMID" matched d5 inside d51v0 and inside
# any GPR hex, letting foreign RIPs land here and silence the CAPTURE-INCOMPLETE marker. Both
# caught in review 2026-09-16 before any capture was taken with it.
for n in 1 2; do
    grep -A24 -E "guest state \(d${DOMID}v[0-9]+\)" "$OUT/xl-dmesg-vcpu-regs-$n.txt" 2>/dev/null \
        | grep -oE 'RIP:\s*[0-9a-f]+:\[<[0-9a-f]+>\]' | head -8 > "$OUT/rip-d$DOMID-$n.txt"
done
if [ ! -s "$OUT/rip-d$DOMID-1.txt" ]; then
    echo "WARNING: no RIP lines for d$DOMID in the register dump - the ring wrapped or the key" \
         "printed nothing for this domain. MISSING DATA, not 'no spin'." > "$OUT/rip-CAPTURE-INCOMPLETE.txt"
fi

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

# The memory image comes BEFORE the NMI: the NMI reboots the guest, and a rebooted guest is not
# the specimen any more. If both are asked for, the image is the one that survives the mistake.
# A SPIN-shaped wedge is precisely the one that NEEDS a memory image: the Xen side can say a vector
# is latched, but only a core can say which MODULE the vCPU refusing to take it is running, by
# walking its stack (tools/core-module-list.py) and naming the frames (tools/pdb-symbolize.py).
# Those two halves have never been captured from the SAME instance, which is why the case is open.
#
# It is NOT taken here, and that is deliberate. `--dump-core` writes the image to DOM0's disk, and
# dom0 on this rig does not have room for one - that is the whole reason `local.WinWedgeCore`
# (dom0/17) exists and STREAMS the core through a FIFO to the dev qube instead, writing nothing
# locally. Auto-setting DUMPCORE here would have quietly reintroduced the exact footprint that
# service was built to avoid. So leave a loud marker and let the dev qube pull the core over the
# streaming route while the guest is still up; tools/wedge-guard acts on this file automatically.
if [ "${SPINSHAPE:-0}" = 1 ]; then
    cat > "$OUT/SPIN-SHAPE-TAKE-A-CORE.txt" <<EOM
SPIN shape detected in the VMCS for d$DOMID: a PAUSE-loop exit and/or a vector latched but not
taken. This is the shape whose stuck vCPU can only be attributed to a module from a memory image.

THE GUEST IS STILL UP AND MUST NOT BE KILLED OR RESTARTED. Take the core NOW, over the streaming
route that writes nothing to dom0's disk:

    mgmt/harness/fetch-wedge-core.sh $VM

Then: tools/core-module-list.py <core> --contains 0x<rip> --stack 0x<rsp>
      tools/pdb-symbolize.py ident <core> --base <hex>   (then fetch / sym / field)
      tools/wedge-vmcs.py <this bundle>
EOM
    echo "SPIN shape - wrote SPIN-SHAPE-TAKE-A-CORE.txt (core NOT written to dom0 disk; stream it)"
fi

if [ "$DUMPCORE" = 1 ]; then
    CORE="$OUT/../${VM}-${DOMID}-$(date +%Y%m%d-%H%M%S).core"
    # Guest RAM in KiB, from the toolstack rather than from the qube's configured maxmem.
    MEM_KB=$(xl list "$VM" 2>/dev/null | awk 'NR==2 {print $3*1024}')
    [ -z "${MEM_KB:-}" ] && MEM_KB=$((8192*1024))
    FREE_KB=$(df -Pk "$(dirname "$CORE")" | awk 'NR==2 {print $4}')
    NEED_KB=$(( MEM_KB + MEM_KB/10 + 1048576 ))   # RAM + 10% + 1 GiB headroom
    echo "dump-core: guest RAM ${MEM_KB} KiB, need ~${NEED_KB} KiB, free ${FREE_KB} KiB"
    if [ "$FREE_KB" -lt "$NEED_KB" ]; then
        # Refusing loudly beats half-writing an image and filling dom0's root.
        echo "dump-core REFUSED: not enough free space for the image (need ~$((NEED_KB/1048576)) GiB, have $((FREE_KB/1048576)) GiB)" \
            | tee -a "$OUT/domid.txt" >&2
    else
        echo "dump-core: writing $CORE (the domain is PAUSED while this runs, not killed)"
        t0=$(date +%s)
        if xl dump-core "$DOMID" "$CORE" 2>>"$OUT/dump-core.err"; then
            sz=$(stat -c %s "$CORE" 2>/dev/null || echo 0)
            echo "dump-core: OK $CORE ($((sz/1048576)) MiB in $(( $(date +%s) - t0 )) s)" | tee -a "$OUT/domid.txt"
        else
            # A dump-core that fails ON A WEDGE IS ITSELF A DATUM - record it, never swallow it.
            echo "dump-core: FAILED (see dump-core.err) - on a wedge this deep that is itself evidence" \
                | tee -a "$OUT/domid.txt" >&2
            rm -f "$CORE"
        fi
    fi
fi

if [ "$NMI" = 1 ]; then
    echo "firing NMI -> guest will bugcheck and write C:\\Windows\\MEMORY.DMP, then reboot"
    xl trigger "$DOMID" nmi
    echo "NMI sent at $(date -u +%H:%M:%S)" >> "$OUT/domid.txt"
fi

tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
qvm-copy-to-vm "$DEV" "$OUT.tar.gz" 2>/dev/null && echo "sent $OUT.tar.gz to $DEV"
echo "done: $OUT"
