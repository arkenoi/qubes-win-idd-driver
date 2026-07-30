#!/bin/bash
# Run IN DOM0. Grants <dev-qube> control over win-idd-test ONLY (plus the screenshot RPC).
# Usage: ./03-install-policy.sh <dev-qube> [test-qube]
set -euo pipefail

DEV="${1:?usage: $0 <dev-qube> [test-qube]}"
VM="${2:-win-idd-test}"
POLICY=/etc/qubes/policy.d/30-win-idd-dev.policy

cat > "$POLICY" <<EOF
# IDD driver dev: $DEV drives $VM. Installed by qubes-win-idd 03-install-policy.sh
qubes.VMShell         *  $DEV  $VM    allow
qubes.VMExec          *  $DEV  $VM    allow
qubes.Filecopy        *  $DEV  $VM    allow
admin.vm.Start        *  $DEV  $VM    allow target=dom0
admin.vm.Shutdown     *  $DEV  $VM    allow target=dom0
admin.vm.Kill         *  $DEV  $VM    allow target=dom0
admin.vm.CurrentState *  $DEV  $VM    allow target=dom0
admin.vm.List         *  $DEV  $VM    allow target=dom0
local.WinScreenshot   *  $DEV  dom0   allow
EOF

chmod 644 "$POLICY"
echo "Installed $POLICY:"
cat "$POLICY"
