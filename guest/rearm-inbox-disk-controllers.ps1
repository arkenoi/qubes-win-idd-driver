<#
.SYNOPSIS
  Make the inbox ATA/AHCI controller drivers boot-start again, so removing the Xen PV disk
  driver cannot strand the boot disk.

.DESCRIPTION
  THE FAILURE THIS EXISTS FOR (forum 42717 post 27): upgrading a guest that already runs
  Qubes Windows Tools removes the installed QWT first, which takes xenvbd with it. The boot
  disk has by then been served by the PV path for a long time, and Windows demotes the inbox
  IDE/AHCI drivers it no longer needs (Start=3, demand). Remove xenvbd in that state and the
  next boot has no boot-capable storage driver at all: bugcheck 0x7B INACCESSIBLE_BOOT_DEVICE,
  recoverable only through a safe-mode boot, which is exactly what the reporter described.

  This is the standard controller-migration remedy: set the inbox storage drivers back to
  boot-start (Start=0) BEFORE the controller changes under Windows. It is harmless when they
  are already boot-start, and harmless on a guest whose disk was never on the PV path - a
  driver marked boot-start that finds no hardware simply does not load.

  Deliberately NOT touching xenvbd itself: this makes the fallback available, it does not
  disable the PV path.
#>
[CmdletBinding()]
param([switch]$WhatIfOnly)

$ErrorActionPreference = 'Stop'

# QEMU/Qubes presents a PIIX3 IDE controller, so intelide/pciide/atapi are the ones that
# matter here; the AHCI pair is included because a guest may be moved to a machine type that
# presents one, and an unused boot-start driver costs nothing.
$services = 'atapi', 'intelide', 'pciide', 'storahci', 'msahci', 'amdide', 'viaide'

$result = [ordered]@{ changed = @(); already = @(); absent = @() }
foreach ($s in $services) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path -LiteralPath $key)) { $result.absent += $s; continue }
    $cur = (Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction SilentlyContinue).Start
    if ($cur -eq 0) { $result.already += $s; continue }
    if ($WhatIfOnly) { $result.changed += "$s ($cur -> 0, not applied)"; continue }
    Set-ItemProperty -LiteralPath $key -Name Start -Value 0 -Type DWord
    $now = (Get-ItemProperty -LiteralPath $key -Name Start).Start
    if ($now -ne 0) { throw "failed to set $s Start=0 (still $now)" }
    $result.changed += "$s ($cur -> 0)"
}

Write-Host '=== RESULT ==='
Write-Host (($result | ConvertTo-Json -Compress))
