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
#   - The image is STREAMED to the caller and never stored in dom0 (changed 2026-09-23, owner:
#     "core will try to dump 8gb on dom0 fs, which does not have enough space"). dom0 holds only a
#     FIFO; the dev qube writes the bytes to its own disk, where tools/xen-core-rip.py reads them.
#     Fetch it with mgmt/harness/fetch-wedge-core.sh, which checks ITS free space before starting.
#   - It cannot fill dom0's root any more: nothing of the image touches dom0's filesystem.
#   - STDOUT IS THE RAW ELF CORE. Every message is on stderr. A caller that mixes them corrupts
#     the image. A SHORT stream means a FAILED capture - check the exit status and stderr.
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

cat > "$SVC" <<EOF
#!/bin/bash
# qubes-win-idd: write a guest memory image for one allowlisted VM. Installed by
# dom0/17-install-wedge-core-service.sh. Argument = VM name. The image stays in dom0.
set -u
ALLOWED="${VMS[*]}"
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

# THE IMAGE IS STREAMED, NOT STORED. dom0's filesystem on this host does not have 8 GiB to spare,
# and the previous version wrote the core there first - so the one service that can name a wedge
# refused exactly when it was needed. `xl dump-core` writes its ELF sequentially, so it can write
# into a FIFO and the bytes go straight out over qrexec; dom0 holds only the FIFO.
#
# STDOUT IS NOW BINARY. Every human-readable line below goes to STDERR - a single stray echo on
# stdout corrupts the image at exactly the offset it lands, and an 8 GiB corruption found hours
# later during analysis is the worst possible way to learn that.
echo "vm=\$VM domid=\$DOMID guest_ram_kb=\$MEM_KB mode=stream" >&2
TMPD=\$(mktemp -d /var/tmp/wedgecore.XXXXXX) || { echo "REFUSED: cannot create a temp dir" >&2; exit 1; }
FIFO="\$TMPD/core.fifo"
mkfifo "\$FIFO" || { echo "REFUSED: cannot create the FIFO" >&2; rm -rf "\$TMPD"; exit 1; }
cleanup() { rm -rf "\$TMPD"; }
trap cleanup EXIT
t0=\$(date +%s)
# PAUSES the domain while writing; does NOT kill, bugcheck or reboot it.
xl dump-core "\$DOMID" "\$FIFO" 2>"\$TMPD/xl.err" &
XLPID=\$!
# cat, not a shell redirect: the reader must stay attached for the whole write, and its exit
# status is what tells us the stream completed.
cat "\$FIFO"
CATRC=\$?
wait \$XLPID; XLRC=\$?
if [ "\$XLRC" -ne 0 ] || [ "\$CATRC" -ne 0 ]; then
    # A dump-core that FAILS on a wedge is itself a datum - say so, never swallow it. The caller
    # sees a SHORT stream plus this line, and must treat a short stream as a failed capture.
    echo "FAILED: xl dump-core rc=\$XLRC, stream rc=\$CATRC after \$(( \$(date +%s) - t0 ))s" >&2
    sed 's/^/  xl: /' "\$TMPD/xl.err" >&2 2>/dev/null
    exit 1
fi
echo "OK streamed in \$(( \$(date +%s) - t0 ))s (guest_ram_kb=\$MEM_KB - compare against the bytes received)" >&2
EOF
chmod 0755 "$SVC"
echo "installed $SVC (streams the image to $DEV, stores nothing; allowlist: ${VMS[*]:-<tag only>})"

if [ ! -f "$POLICY" ] || ! grep -q 'local.WinWedgeCore' "$POLICY" 2>/dev/null; then
    printf 'local.WinWedgeCore * %s dom0 allow\n' "$DEV" >> "$POLICY"
    echo "policy line added to $POLICY"
else
    echo "policy line already present"
fi

echo
echo "Fetch from $DEV:  mgmt/harness/fetch-wedge-core.sh <vm>"
