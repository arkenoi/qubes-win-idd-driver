#!/bin/bash
# Run IN DOM0 ONCE. Makes wedge forensics AUTOMATIC instead of something the user has to
# fire by hand every time a guest wedges.
#
# WHY: 11-wedge-forensics.sh must run in dom0 AT THE MOMENT OF THE WEDGE, before anything
# kills or restarts the guest. Until now that meant the user noticing the wedge and typing
# a sudo command - so in practice the capture was usually missed and the evidence lost
# (happened twice: a wedge killed with no forensics, and a wedged win10-clean whose log was
# never captured). This installs a qrexec service so the dev qube can take the capture the
# instant its own watchers detect the wedge, with no human in the loop.
#
# SECURITY POSTURE. The service is dom0-side and takes exactly one argument: the target VM
# name, which must carry the `win-idd-testbed` TAG. Tag membership is the same gate the
# qrexec policy already uses (dom0/12-install-policy-tagged.sh), so a name allowlist here
# added no real restriction - the policy had already admitted the call - while silently
# returning nothing for any qube created later (win11-fresh got an empty screenshot for
# exactly this reason, 2026-08-07). If you want the stricter posture, pass explicit names
# and they are enforced IN ADDITION to the tag. It runs a fixed script with no caller-supplied
# arguments, and NEVER honours --nmi from the caller: bugchecking a guest is destructive, so
# it stays a deliberate human action. Output is streamed back as a tar on stdout; nothing
# from the caller is executed or interpolated into a shell command.
#
# Usage:  sudo ./13-install-wedge-forensics-service.sh <dev-qube> [vm ...]
#   e.g.  sudo ./13-install-wedge-forensics-service.sh win-idd-mgmt      (tag-gated; names would NARROW it)
# Remove: sudo rm /etc/qubes-rpc/local.WinWedgeForensics
#         and delete the line from /etc/qubes/policy.d/29-win-idd-testbed.policy
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [vm ...]}"
shift || true
VMS=("$@")
# NO default names (changed 2026-10-02). The default used to be five legacy qube names, and the gate
# below admitted a name from that list even WITHOUT the tag - the opposite of what the posture note
# above promises. Every test guest carries the tag, so the default is now the tag alone, exactly as
# local.WinWedgeCore (dom0/17) has always been; names you pass are enforced IN ADDITION to the tag.

SVC=/etc/qubes-rpc/local.WinWedgeForensics
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICY=/etc/qubes/policy.d/29-win-idd-testbed.policy

# The forensics script itself is copied to a fixed dom0 path so the service does not depend
# on a working copy in a user's home that may move or change under it.
# NOTE: dom0 cannot be pushed to - the files must be PULLED, and BOTH of them. Fetching only
# this installer leaves 11-wedge-forensics.sh missing and the install half-done, so check.
SRC_FORENSICS="${FORENSICS:-$KIT_DIR/11-wedge-forensics.sh}"
if [ ! -f "$SRC_FORENSICS" ]; then
    cat >&2 <<EOM
FATAL: 11-wedge-forensics.sh not found next to this script ($KIT_DIR).
dom0 must pull BOTH files. In dom0:

  mkdir -p ~/win-idd-dom0 && cd ~/win-idd-dom0
  for f in 11-wedge-forensics.sh 13-install-wedge-forensics-service.sh; do
      qvm-run --pass-io $DEV "cat /home/user/qubes-win-idd-driver/dom0/\$f" > "\$f"
  done
  sudo bash 13-install-wedge-forensics-service.sh $DEV

(or point this script at the file with FORENSICS=/path/to/11-wedge-forensics.sh)
EOM
    exit 1
fi
install -m 0755 "$SRC_FORENSICS" /usr/local/sbin/win-wedge-forensics.sh

cat > "$SVC" <<EOF
#!/bin/bash
# qubes-win-idd: capture wedge forensics for one tagged VM, return a tar on stdout.
# Installed by dom0/13-install-wedge-forensics-service.sh. Argument = VM name.
set -u
ALLOWED="${VMS[*]:-}"
VM="\${QREXEC_SERVICE_ARGUMENT:-}"
# The tag is REQUIRED (the same gate the qrexec policy uses); an explicit name list, if one was
# given at install time, narrows it further and never widens it.
if ! qvm-tags "\$VM" list 2>/dev/null | grep -qx win-idd-testbed; then
    echo "refused: '\$VM' lacks the win-idd-testbed tag" >&2; exit 1
fi
if [ -n "\$ALLOWED" ]; then
    case " \$ALLOWED " in
        *" \$VM "*) ;;
        *) echo "refused: '\$VM' is tagged but not in the explicit allowlist" >&2; exit 1 ;;
    esac
fi
# Refuse anything that is not a plain VM name, belt and braces.
case "\$VM" in
    *[!A-Za-z0-9._-]*|"") echo "refused: bad VM name" >&2; exit 1 ;;
esac

OUT=\$(mktemp -d /var/tmp/wedge-XXXXXX)
# --nmi is deliberately NOT reachable from the caller: it bugchecks the guest.
VM="\$VM" /usr/local/sbin/win-wedge-forensics.sh > "\$OUT/capture.log" 2>&1 || true
# Collect EXACTLY the directory this run reported on its first line ("capturing to <dir>"; under
# qrexec the service runs as root, so that is /root/wedge-<ts>). This used to collect the NEWEST
# /home/*/wedge-* or /root/wedge-* entry - but 11 also writes <dir>.tar.gz AFTER the directory, so
# the newest entry was that archive, copying it as a directory failed silently, and every tar this service
# returned held capture.log alone (shown on a stubbed dom0, 2026-10-02). That stayed hidden while 11
# defaulted DEV and copied its own archive to the dev qube; since 8a961ba1 the service leaves DEV
# unset and this tar is the ONLY route back - and tools/wedge-guard looks in it for the SPIN marker
# that starts the core fetch. A run that reported no directory returns capture.log plus a
# COLLECT-FAILED note - never an older capture passed off as this one.
DIR=\$(sed -n 's/^capturing to //p' "\$OUT/capture.log" | head -1)
case "\${DIR##*/}" in wedge-[0-9]*) ;; *) DIR="" ;; esac
if [ -n "\$DIR" ] && [ -d "\$DIR" ]; then
    cp -r "\$DIR"/. "\$OUT/" 2>"\$OUT/collect.err" \\
        || echo "collect FAILED from \$DIR (see collect.err)" > "\$OUT/COLLECT-FAILED.txt"
    [ -s "\$OUT/collect.err" ] || rm -f "\$OUT/collect.err"
else
    echo "the capture reported no directory - see capture.log" > "\$OUT/COLLECT-FAILED.txt"
fi
tar -C "\$OUT" -cf - . 2>/dev/null
rm -rf "\$OUT"
EOF
chmod 0755 "$SVC"
echo "installed $SVC (admits: tagged win-idd-testbed${VMS[*]:+, and only: ${VMS[*]}})"

if [ ! -f "$POLICY" ] || ! grep -q 'local.WinWedgeForensics' "$POLICY" 2>/dev/null; then
    printf 'local.WinWedgeForensics * %s dom0 allow\n' "$DEV" >> "$POLICY"
    echo "policy line added to $POLICY"
else
    echo "policy line already present"
fi

echo
echo "Verify from $DEV:  QTEST_VM=<a running tagged guest> tools/qtest wedge <out-dir>   (the tar must hold vmcs-d<domid>.txt, not capture.log alone)"
