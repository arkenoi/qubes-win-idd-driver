#!/bin/bash
# Run IN DOM0. Tag-based replacement for 03-install-policy.sh's per-NAME rules.
#
# WHY: every test qube so far was granted by name (win-idd-test), so a newly created
# qube (win10-fresh, win11-fresh, any future one) silently has NO qrexec access from
# the dev qube - qtest run/push simply fail. Tag-based rules fix that once.
#
# Grants <dev-qube> control over every qube tagged `win-idd-testbed`, and lets it
# TAG qubes itself (admin.vm.tag.Set) so new test qubes need no dom0 round trip.
# Everything stays scoped to that tag: untagged qubes are unaffected.
#
# Usage: sudo ./12-install-policy-tagged.sh <dev-qube> [qube-to-tag ...]
#   e.g. sudo ./12-install-policy-tagged.sh win-idd-mgmt win-idd-test win10-fresh win11-fresh
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [qube-to-tag ...]}"
shift || true
POLICY=/etc/qubes/policy.d/29-win-idd-testbed.policy   # 29 = before the name-based 30-*

cat > "$POLICY" <<EOF
# Tag-based testbed access for the qubes-win-idd kit. Installed by
# dom0/12-install-policy-tagged.sh. Scope: qubes tagged win-idd-testbed only.
qubes.VMShell         *  $DEV  @tag:win-idd-testbed  allow
qubes.VMExec          *  $DEV  @tag:win-idd-testbed  allow
qubes.Filecopy        *  $DEV  @tag:win-idd-testbed  allow
admin.vm.Start        *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.Shutdown     *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.Kill         *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.CurrentState *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.List         *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.property.Get *  $DEV  @tag:win-idd-testbed  allow target=dom0
admin.vm.property.Set *  $DEV  @tag:win-idd-testbed  allow target=dom0

# Let the dev qube tag/untag qubes itself, so a newly created test qube can be
# admitted to the testbed without another dom0 visit. Deliberately NOT restricted
# to the tag (a qube cannot yet carry the tag it is about to be given).
admin.vm.tag.Set      *  $DEV  @anyvm  allow target=dom0
admin.vm.tag.Remove   *  $DEV  @anyvm  allow target=dom0
admin.vm.tag.List     *  $DEV  @anyvm  allow target=dom0

# dom0 helper services already installed by 04/07/10-install-*.sh. The services
# themselves resolve their target from the qrexec argument, so a tag-scoped rule
# is enough here.
local.WinScreenshot   *  $DEV  dom0  allow
local.WinFullScreen   *  $DEV  dom0  allow
local.WinResize       *  $DEV  dom0  allow
EOF

echo "Installed $POLICY"

for vm in "$@"; do
    if qvm-ls --raw-list | grep -qx "$vm"; then
        qvm-tags "$vm" add win-idd-testbed
        echo "tagged: $vm"
    else
        echo "skip (no such qube): $vm" >&2
    fi
done

echo
echo "Verify from $DEV:  qvm-ls --tags | grep win-idd-testbed"
