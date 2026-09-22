#!/bin/bash
# guest-config-snapshot.sh - the per-run record that did not exist, and whose absence makes a
# faithful reproduction of the install stall impossible.
#
# WHY. A machine-built matrix over all 35 surviving install/upgrade logs (tools/stall-matrix.py)
# found every recorded field constant across the stalled run and the 33 clean ones. Jev over that
# table: `corpus_can_discriminate` 0.08, `necessary_candidate=nothing-in-this-corpus` 0.85,
# `what_to_record=guest-config-snapshot` 1.00. What separates a stall from a clean run is not in any
# log we keep; this starts keeping it.
#
#   tools/guest-config-snapshot.sh <vm> <outdir> [tag]
#
# Bounded and non-fatal: every probe has a timeout, a failure is written as MISSING rather than a
# blank, and nothing here mutates the guest.
set -u
VM="${1:?usage: guest-config-snapshot.sh <vm> <outdir> [tag]}"
OUT="${2:?usage: guest-config-snapshot.sh <vm> <outdir> [tag]}"
TAG="${3:-snap}"
cd "$(dirname "$0")/.." || exit 1
mkdir -p "$OUT" || exit 1

# Serialises JOBS, not calls: vm_lock returns at once when an ancestor already holds this vm
# (mgmt/harness/vmlock.sh:103-106), which is the normal case - a harness calls this mid-run.
. mgmt/harness/vmlock.sh
vm_lock "$VM"

F="$OUT/guest-config-$TAG.txt"
say(){ printf '%s\n' "$*" >> "$F"; }
probe(){ # <label> <command...> - a failed probe is MISSING data, never a silent blank
  local label="$1"; shift
  local o; o=$("$@" 2>&1); local rc=$?
  if [ $rc = 0 ] && [ -n "$o" ]; then say "--- $label"; printf '%s\n' "$o" >> "$F"
  else say "--- $label: MISSING (rc=$rc) ${o:0:200}"; fi
}
gp(){ QTEST_VM="$VM" timeout 90 ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
# Escaped quotes inside `powershell -Command` fail SILENTLY across qrexec (lint L3), and a blank
# answer is indistinguishable from a real one - the missing-data-as-value trap this file exists to
# avoid. So every PowerShell probe is base64 UTF-16LE via -EncodedCommand.
gps(){ # <label> <powershell>
  local label="$1"; shift
  local enc; enc=$(printf '%s' "$1" | python3 -c "import sys,base64;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
  local o; o=$(gp "powershell -NoProfile -EncodedCommand $enc")
  o=$(printf '%s' "$o" | grep -v '^C:\\' | grep -v '^Microsoft Windows' | grep -v '^(c) Microsoft' | sed '/^$/d')
  if [ -n "$o" ]; then say "--- $label"; printf '%s\n' "$o" >> "$F"
  else say "--- $label: MISSING (no answer from the guest)"; fi
}

: > "$F"
say "guest-config snapshot: vm=$VM tag=$TAG utc=$(date -u +%FT%TZ)"

# --- the dom0-side shape of the qube: what it was BUILT as ---
probe "qvm-prefs"    timeout 60 qvm-prefs "$VM"
probe "qvm-features" timeout 60 qvm-features "$VM"
probe "qvm-tags"     timeout 60 qvm-tags "$VM" list
probe "xid-and-state" timeout 60 python3 -c "
import qubesadmin
vm = qubesadmin.Qubes().domains['$VM']
print('xid', vm.xid, 'state', vm.get_power_state())"
probe "block-backends-this-qube" timeout 120 bash tools/loopback-health.sh

# --- the guest-side state: what it actually IS at this boot ---
say "--- os build"; gp 'cmd /c ver' | sed '/^$/d' >> "$F"
gps "qwt products"      'Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* -EA SilentlyContinue | Where-Object DisplayName -like "*Qubes*" | ForEach-Object { $_.DisplayName + " " + $_.DisplayVersion }'
gps "qubes services"    'Get-Service | Where-Object Name -like "*Qubes*" | ForEach-Object { $_.Name + " " + $_.Status }'
gps "xen pnp devices"   'Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -like "XEN*" -or $_.FriendlyName -like "*Xen*" } | ForEach-Object { $_.Status + " " + $_.Class + " " + $_.InstanceId }'
gps "disks"             'Get-Disk -EA SilentlyContinue | ForEach-Object { $_.Number.ToString() + " " + $_.FriendlyName + " " + $_.SerialNumber + " " + $_.PartitionStyle + " " + $_.Size }'
gps "pending reboot"    '@((Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"),(Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")) -join " "'
gps "cpus and boot time" '(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors.ToString() + " cpus, booted " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime'
say "--- qubesdb"; gp 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\qubes-qubesdb-read.ps1' | sed '/^$/d' >> "$F"

say "=== end of snapshot ==="
echo "$F"
