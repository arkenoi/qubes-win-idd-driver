#!/bin/bash
# Run IN DOM0. Grants win-idd-mgmt the Admin API subset needed to create and manage the
# Windows test VM, plus qrexec/screenshot access. REVIEW BEFORE RUNNING: VM creation is a
# powerful right; everything else is scoped to VMs the mgmt qube itself created (Qubes
# auto-tags them 'created-by-<qube>') or to win-idd-test by name.
# Usage: ./06-install-mgmt-policy.sh [mgmt-qube] [test-qube]
set -euo pipefail

MGMT="${1:-win-idd-mgmt}"
VM="${2:-win-idd-test}"
TAG="created-by-$MGMT"
POLICY=/etc/qubes/policy.d/31-win-idd-mgmt.policy

cat > "$POLICY" <<EOF
# win-idd-mgmt orchestrator grants. Installed by qubes-win-idd 06-install-mgmt-policy.sh
# --- VM creation (global right — the one line to think hard about) ---
# StandaloneVM, NOT "standalone": the service name is the VM CLASS, verified against the
# installed qubesadmin client. The lowercase form matches NOTHING, so VM creation was
# silently never granted - measured 2026-08-09, when qvm-create/qvm-remove came back
# "Request refused" while property.Get/Set worked. Superseded in practice by
# mgmt/10-win-idd-all.policy, which is numbered to win first-match.
admin.vm.Create.StandaloneVM    *  $MGMT  dom0          allow target=dom0
admin.vm.Remove                 *  $MGMT  @tag:$TAG     allow target=dom0
admin.Events                    *  $MGMT  dom0          allow target=dom0
admin.Events                    *  $MGMT  @tag:$TAG     allow target=dom0

# --- management of VMs it created (auto-tag $TAG) + the test VM by name ---
EOF

for svc in admin.vm.List admin.vm.Remove admin.vm.CurrentState \
           admin.vm.Start admin.vm.Shutdown admin.vm.Kill admin.vm.Unpause \
           admin.vm.property.Get admin.vm.property.GetDefault admin.vm.property.Set \
           admin.vm.property.List \
           admin.vm.feature.Get admin.vm.feature.Set admin.vm.feature.List \
           admin.vm.feature.Remove admin.vm.feature.CheckWithTemplate \
           admin.vm.volume.List admin.vm.volume.Info admin.vm.volume.Resize \
           admin.vm.device.block.Attach admin.vm.device.block.Detach \
           admin.vm.device.block.List admin.vm.device.block.Set; do
    printf '%-31s *  %s  @tag:%s  allow target=dom0\n' "$svc" "$MGMT" "$TAG" >> "$POLICY"
    printf '%-31s *  %s  %s  allow target=dom0\n'       "$svc" "$MGMT" "$VM"  >> "$POLICY"
done

cat >> "$POLICY" <<EOF

# mgmt qube exposes its own ISO file as the install cdrom (backend-side device listing)
admin.vm.device.block.Available *  $MGMT  $MGMT         allow target=dom0
admin.vm.List                   *  $MGMT  dom0          allow target=dom0
admin.vm.List                   *  $MGMT  $MGMT         allow target=dom0
# NOTE: if qvm-* CLI tools hang waiting for events, additionally allow:
#admin.Events                   *  $MGMT  dom0          allow target=dom0
#admin.Events                   *  $MGMT  @tag:$TAG     allow target=dom0

# --- driving the installed guest: provisioning AND the dev test loop ---
qubes.VMShell                   *  $MGMT  $VM           allow
qubes.VMExec                    *  $MGMT  $VM           allow
qubes.Filecopy                  *  $MGMT  $VM           allow
local.WinScreenshot             *  $MGMT  dom0          allow
EOF

chmod 644 "$POLICY"
echo "Installed $POLICY ($(wc -l < "$POLICY") lines). Review it:"
echo "  less $POLICY"
