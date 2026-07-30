#!/bin/bash
# Run IN DOM0. Creates 'win-idd-mgmt': an AppVM running Claude Code that automates
# ISO prep, unattended Windows install, and test-VM provisioning via the Admin API.
set -euo pipefail

# Template is REQUIRED: it must be the one where you installed the mgmt packages
# (qubes-core-admin-client, p7zip, xorriso, ...) — guessing default_template here
# would silently produce a broken mgmt qube.
VM="${1:-win-idd-mgmt}"
TEMPLATE="${2:?usage: $0 [mgmt-qube-name] <template-with-mgmt-packages>}"
qvm-ls --raw-list | grep -qx "$TEMPLATE" || { echo "no such template: $TEMPLATE" >&2; exit 1; }

qvm-ls --raw-list | grep -qx "$VM" && { echo "$VM already exists" >&2; exit 1; }

qvm-create --class AppVM --template "$TEMPLATE" --label orange "$VM"
qvm-prefs "$VM" memory 2048
qvm-prefs "$VM" maxmem 4096
qvm-volume extend "$VM:private" 40GiB    # ISO + repack workspace (~20 GB peak)
# networking: needed for the Anthropic API + ISO/QWT downloads; default netvm is fine.

echo "Created $VM (template: $TEMPLATE)."
echo
echo "Template packages required (install in $TEMPLATE via dnf — goes through the updates"
echo "proxy, templates have no direct network):"
echo "  qubes-core-admin-client  p7zip p7zip-plugins  xorriso  curl  git"
echo "Claude Code: either template-wide (npm -g with https_proxy=http://127.0.0.1:8082 —"
echo "the updates proxy allows CONNECT), or inside $VM: curl -fsSL https://claude.ai/install.sh | bash"
echo "(template ~/.local does NOT propagate to AppVMs — system-wide installs only)"
echo
echo "Then: ./06-install-mgmt-policy.sh $VM"
echo "And from the dev qube:  qvm-copy the qubes-win-idd kit dir to $VM"
