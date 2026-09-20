#!/bin/bash
# Run IN DOM0 ONCE. Makes a guest MEMORY IMAGE a one-liner from the dev qube.
#
# WHY: on 2026-09-20 the multi-vCPU wedge was finally named - two vCPUs spinning in a lock-acquire
# loop in a PV driver while the other two sat idle in sti;hlt - and the ONLY reason it took until
# then is that nobody had a memory image. The NMI route does not work for this class (a bugcheck
# must freeze the other processors with IPIs, so if IPI delivery is involved the crash path
# deadlocks too; fired 2026-09-10, no dump). `xl dump-core` needs no guest cooperation, works on a
# guest whose qrexec is dead and whose console will not attach, and is what actually produced the
# answer. Getting it required a human to type a sudo command in dom0 at the right moment, which is
# exactly the "in practice the capture was usually missed" problem that 13-install-...-service.sh
# was written to remove. This does the same for the image.
#
# SEPARATE SERVICE, ON PURPOSE. local.WinWedgeForensics documents that it "runs a fixed script with
# no caller-supplied arguments"; teaching it a mode flag would make that sentence false. This is a
# second fixed-purpose service instead, gated identically on the win-idd-testbed TAG.
#
# WHAT IT DOES AND DOES NOT DO
#   - It is NOT destructive: `xl dump-core` PAUSES the domain while it writes, then leaves it
#     exactly as it was. The guest is not killed, not bugchecked, not rebooted. (--nmi remains
#     unreachable from any caller, in both services.)
#   - The image STAYS IN DOM0 and is never streamed back: ~8 GB for an 8192 MB guest does not fit
#     on the dev qube, and the dev qube does not need it - tools/xen-core-rip.py reads it in place
#     once the owner copies it across, or it can be read in dom0.
#   - It REFUSES rather than filling dom0's root: it checks free space against guest RAM + 10% +
#     1 GiB first. A half-written image that wedged dom0 would be worse than no image.
#   - stdout is a few lines of text (path, size, timing) - safe to read as data.
#
# Usage:  sudo ./17-install-wedge-core-service.sh <dev-qube> [vm ...]
#   e.g.  sudo ./17-install-wedge-core-service.sh win-idd-mgmt
# Remove: sudo rm /etc/qubes-rpc/local.WinWedgeCore
#         and delete the line from /etc/qubes/policy.d/29-win-idd-testbed.policy
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [vm ...]}"
shift || true
VMS=("$@")

SVC=/etc/qubes-rpc/local.WinWedgeCore
POLICY=/etc/qubes/policy.d/29-win-idd-testbed.policy
CORE_DIR="${CORE_DIR:-/var/tmp/win-wedge-cores}"

mkdir -p "$CORE_DIR"

cat > "$SVC" <<EOF
#!/bin/bash
# qubes-win-idd: write a guest memory image for one allowlisted VM. Installed by
# dom0/17-install-wedge-core-service.sh. Argument = VM name. The image stays in dom0.
set -u
ALLOWED="${VMS[*]}"
CORE_DIR="$CORE_DIR"
VM="\${QREXEC_SERVICE_ARGUMENT:-}"
# Tag gate first, identical to local.WinWedgeForensics.
if qvm-tags "\$VM" list 2>/dev/null | grep -qx win-idd-testbed; then
    :
elif [ -z "\$ALLOWED" ]; then
    echo "refused: '\$VM' lacks the win-idd-testbed tag" >&2; exit 1
else
case " \$ALLOWED " in
    *" \$VM "*) ;;
    *) echo "refused: '\$VM' lacks the win-idd-testbed tag and is not in the explicit allowlist" >&2; exit 1 ;;
esac
fi
case "\$VM" in
    *[!A-Za-z0-9._-]*|"") echo "refused: bad VM name" >&2; exit 1 ;;
esac

DOMID=\$(xl domid "\$VM" 2>/dev/null) || { echo "refused: '\$VM' is not running" >&2; exit 1; }
MEM_KB=\$(xl list "\$VM" 2>/dev/null | awk 'NR==2 {print \$3*1024}')
[ -z "\${MEM_KB:-}" ] && MEM_KB=\$((8192*1024))
mkdir -p "\$CORE_DIR"
FREE_KB=\$(df -Pk "\$CORE_DIR" | awk 'NR==2 {print \$4}')
NEED_KB=\$(( MEM_KB + MEM_KB/10 + 1048576 ))
echo "vm=\$VM domid=\$DOMID guest_ram_kb=\$MEM_KB need_kb=\$NEED_KB free_kb=\$FREE_KB"
if [ "\$FREE_KB" -lt "\$NEED_KB" ]; then
    echo "REFUSED: not enough free space in \$CORE_DIR (need ~\$((NEED_KB/1048576)) GiB, have \$((FREE_KB/1048576)) GiB)" >&2
    exit 1
fi
CORE="\$CORE_DIR/\${VM}-\${DOMID}-\$(date +%Y%m%d-%H%M%S).core"
t0=\$(date +%s)
# PAUSES the domain while writing; does NOT kill, bugcheck or reboot it.
if xl dump-core "\$DOMID" "\$CORE" 2>&1; then
    sz=\$(stat -c %s "\$CORE" 2>/dev/null || echo 0)
    echo "core=\$CORE bytes=\$sz seconds=\$(( \$(date +%s) - t0 ))"
    echo "OK - the image stays in dom0; copy it out with: qvm-copy-to-vm $DEV \$CORE"
else
    # A dump-core that FAILS on a wedge is itself a datum - say so, never swallow it.
    echo "FAILED: xl dump-core returned non-zero - on a deep wedge that is itself evidence" >&2
    rm -f "\$CORE"
    exit 1
fi
EOF
chmod 0755 "$SVC"
echo "installed $SVC (images under $CORE_DIR; allowlist: ${VMS[*]:-<tag only>})"

if [ ! -f "$POLICY" ] || ! grep -q 'local.WinWedgeCore' "$POLICY" 2>/dev/null; then
    printf 'local.WinWedgeCore * %s dom0 allow\n' "$DEV" >> "$POLICY"
    echo "policy line added to $POLICY"
else
    echo "policy line already present"
fi

echo
echo "Verify from $DEV:  tools/qtest dumpcore <vm>"
