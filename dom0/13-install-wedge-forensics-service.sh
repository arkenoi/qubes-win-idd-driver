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
# name, which must be in the allowlist below (tag membership is NOT used - a compromised
# dev qube can set tags via admin.vm.tag.Set). It runs a fixed script with no caller-supplied
# arguments, and NEVER honours --nmi from the caller: bugchecking a guest is destructive, so
# it stays a deliberate human action. Output is streamed back as a tar on stdout; nothing
# from the caller is executed or interpolated into a shell command.
#
# Usage:  sudo ./13-install-wedge-forensics-service.sh <dev-qube> [vm ...]
#   e.g.  sudo ./13-install-wedge-forensics-service.sh win-idd-mgmt win-idd-test win10-clean
# Remove: sudo rm /etc/qubes-rpc/local.WinWedgeForensics
#         and delete the line from /etc/qubes/policy.d/29-win-idd-testbed.policy
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [vm ...]}"
shift || true
VMS=("$@")
[ ${#VMS[@]} -eq 0 ] && VMS=(win-idd-test win10-clean win10-e2e win11-idd-test win11-fresh)

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
  sudo bash 13-install-wedge-forensics-service.sh $DEV win-idd-test win10-clean win10-e2e

(or point this script at the file with FORENSICS=/path/to/11-wedge-forensics.sh)
EOM
    exit 1
fi
install -m 0755 "$SRC_FORENSICS" /usr/local/sbin/win-wedge-forensics.sh

cat > "$SVC" <<EOF
#!/bin/bash
# qubes-win-idd: capture wedge forensics for one allowlisted VM, return a tar on stdout.
# Installed by dom0/13-install-wedge-forensics-service.sh. Argument = VM name.
set -u
ALLOWED="${VMS[*]}"
VM="\${QREXEC_SERVICE_ARGUMENT:-}"
case " \$ALLOWED " in
    *" \$VM "*) ;;
    *) echo "refused: '\$VM' is not in the allowlist" >&2; exit 1 ;;
esac
# Refuse anything that is not a plain VM name, belt and braces.
case "\$VM" in
    *[!A-Za-z0-9._-]*|"") echo "refused: bad VM name" >&2; exit 1 ;;
esac

OUT=\$(mktemp -d /var/tmp/wedge-XXXXXX)
# --nmi is deliberately NOT reachable from the caller: it bugchecks the guest.
VM="\$VM" /usr/local/sbin/win-wedge-forensics.sh > "\$OUT/capture.log" 2>&1 || true
# 11-wedge-forensics.sh writes to ~/wedge-<ts>/; collect the newest one.
# 11-wedge-forensics.sh writes to the INVOKING USER's home. Under qrexec the service runs
# as root, so ~ is /root while a hand-run capture lands in /home/<dom0-user>. Looking only
# at ~ returned an empty tar on the first real capture (2026-08-06) even though the run
# succeeded - search both.
NEWEST=\$(ls -1dt /home/*/wedge-* /root/wedge-* 2>/dev/null | head -1)
[ -n "\$NEWEST" ] && cp -r "\$NEWEST"/. "\$OUT/" 2>/dev/null
tar -C "\$OUT" -cf - . 2>/dev/null
rm -rf "\$OUT"
EOF
chmod 0755 "$SVC"
echo "installed $SVC (allowlist: ${VMS[*]})"

if [ ! -f "$POLICY" ] || ! grep -q 'local.WinWedgeForensics' "$POLICY" 2>/dev/null; then
    printf 'local.WinWedgeForensics * %s dom0 allow\n' "$DEV" >> "$POLICY"
    echo "policy line added to $POLICY"
else
    echo "policy line already present"
fi

echo
echo "Verify from $DEV:  tools/qtest wedge win-idd-test"
