#!/usr/bin/env bash
# wu-evidence-facts.sh <vm> <facts-out> - measure, on a RUNNING guest, the artefact versions tools/wu-exclusion-evidence.py turns into
# the INDEPENDENT evidence tools/wu-exclusion-audit.py --evidence judges against. Read by the harness, never by the updater under test.
#
# Why a script of its own (2026-10-03): it was inline in mgmt/harness/template-update-test.sh, where its first live run would have been
# a release candidate's acceptance. Standalone, it is validated on a real guest before any candidate depends on it (Jev 0.99).
#
# One PowerShell, run as SYSTEM over `qtest run` (the testbed policy runs qubes.VMShell as SYSTEM - the pattern env-assert.sh uses
# live): Get-AppxPackage -AllUsers and Get-AppxProvisionedPackage -Online need it. Prints 'EV|key=value' lines; the last is EV|end=1.
# Exit 0 = the answer is complete (the end marker arrived); 2 = it is not (guest down, qrexec refused, the probe died) - missing data
# fails, and an empty value stays empty for the builder's required-key check to refuse.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
VM="${1:?usage: wu-evidence-facts.sh <vm> <facts-out>}"
OUT="${2:?usage: wu-evidence-facts.sh <vm> <facts-out>}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
# DEFENDER LOADS LATE (measured 2026-10-03 on the rz35 subject, German 25H2): 68 s after boot WinDefend was Running but reported
# AMRunningMode 'Not running', engine 0.0.0.0 and NO signature version; at 170 s it reported Normal, engine 1.1.26080.3, signatures
# 1.459.526.0. A read in that window is not a fact, so wait for the engine - three exits, each named in EV|defender: ready; disabled
# (WinDefend's start type is Disabled - it will never load); not-ready (no engine after 300 s). Only 'ready' yields the Defender facts
# the builder requires; the others leave them empty, and the builder refuses (missing data fails).
read -r -d '' EVPS <<'PS' || true
$ErrorActionPreference = 'SilentlyContinue'
$t0 = Get-Date; $dstate = 'not-ready'
while ($true) {
  if ((Get-Service WinDefend).StartType -eq 'Disabled') { $dstate = 'disabled'; break }
  $m = Get-MpComputerStatus
  if ($m.AMServiceEnabled -and $m.AMEngineVersion -and $m.AMEngineVersion -ne '0.0.0.0' -and $m.AntivirusSignatureVersion) { $dstate = 'ready'; break }
  if (((Get-Date) - $t0).TotalSeconds -ge 300) { break }
  Start-Sleep -Seconds 5
}
'EV|defender=' + $dstate + ' after ' + [int]((Get-Date) - $t0).TotalSeconds + 's (mode ' + $m.AMRunningMode + ')'
if ($dstate -ne 'ready') { $m = $null }
'EV|platform=' + $m.AMProductVersion
'EV|engine=' + $m.AMEngineVersion
'EV|signature=' + $m.AntivirusSignatureVersion
$ax = Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI | Select-Object -First 1
'EV|sechealth=' + $ax.Version
$pv = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | Select-Object -First 1
'EV|sechealth_prov=' + $pv.Version
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
'EV|build=' + $cv.CurrentBuild + '.' + $cv.UBR
'EV|hotfixes=' + ((Get-HotFix | ForEach-Object { $_.HotFixID }) -join ',')
'EV|boot=' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s')
'EV|whoami=' + [Security.Principal.WindowsIdentity]::GetCurrent().Name
'EV|end=1'
PS
b64=$(printf '%s' "$EVPS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
raw="$OUT.raw"
QTEST_VM="$VM" timeout -k 5 420 tools/qtest run "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $b64" \
  2>&1 | tr -d '\r' > "$raw"
grep -a '^EV|' "$raw" > "$OUT"
grep -a -q '^EV|end=1$' "$OUT" || { echo "INCOMPLETE: no end marker from $VM (raw answer kept in $raw)" >&2; exit 2; }
echo "facts from $VM: $(grep -a -v '^EV|end=' "$OUT" | tr '\n' ' ' | cut -c1-400)"   # -a: SYSTEM's name is localized (NT-AUTORITÄT, OEM codepage)
