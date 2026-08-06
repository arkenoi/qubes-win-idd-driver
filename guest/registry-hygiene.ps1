# registry-hygiene.ps1 — one-shot, conservative cleanup of display-identity churn debris.
# Run ELEVATED in win-idd-test via qrexec:
#   tools/qtest push guest/registry-hygiene.ps1
#   tools/qtest ps "& '<incoming>\registry-hygiene.ps1'"          # report only (-WhatIf semantics)
#   tools/qtest ps "& '<incoming>\registry-hygiene.ps1' -Force"   # actually delete
#
# Scope — deliberately narrow:
#   1. Monitor instance keys under HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\Default_Monitor\*
#      ONLY (the EDID-less identity churned by virtual-display flapping). A key is a PHANTOM
#      iff its instance id ("DISPLAY\Default_Monitor\<subkey>") is NOT in
#      Get-PnpDevice -Class Monitor -PresentOnly. Other vendor ids (QBS0001, anything with a
#      real EDID) are never touched.
#   2. HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration subkeys whose NAME
#      contains the DEFAULT_MONITOR path fragment. Removed only when NO Default_Monitor
#      monitor is currently present (then the referenced topology cannot be current). If any
#      Default_Monitor IS present we cannot tell which config is live -> KEEP all and say so.
#
# Never deletes silently: every key is reported kept/removed/locked, with before/after counts.
# Enum keys are ACL-protected (SYSTEM-owned): deletion failures are reported as LOCKED, never
# a script error. Machine-parseable summary:
#   RESULT PHANTOMS_FOUND=<n> PHANTOMS_REMOVED=<n> PHANTOMS_LOCKED=<n>
#   RESULT CFG_FOUND=<n> CFG_REMOVED=<n> CFG_KEPT=<n>

param(
    [switch]$Force   # default is report-only (-WhatIf semantics); -Force performs deletions
)

$ErrorActionPreference = 'Continue'

$EnumBase = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\Default_Monitor'
$CfgBase  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
$Fragment = 'DEFAULT_MONITOR'   # match in Configuration subkey names, case-insensitive

# --- elevation check ------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Output 'ERROR not elevated - run as admin'
    Write-Output 'RESULT PHANTOMS_FOUND=-1 PHANTOMS_REMOVED=0 PHANTOMS_LOCKED=0'
    Write-Output 'RESULT CFG_FOUND=-1 CFG_REMOVED=0 CFG_KEPT=0'
    exit 1
}

$mode = if ($Force) { 'FORCE (deleting)' } else { 'WHATIF (report only, nothing deleted)' }
Write-Output "MODE $mode"

# --- ground truth: currently-present monitors -----------------------------------------
$presentIds = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty InstanceId)
Write-Output ("PRESENT_MONITORS count=" + $presentIds.Count)
foreach ($p in $presentIds) { Write-Output "PRESENT $p" }
$defaultMonitorPresent = @($presentIds | Where-Object { $_ -match '^DISPLAY\\Default_Monitor\\' }).Count -gt 0
Write-Output ("DEFAULT_MONITOR_PRESENT " + $defaultMonitorPresent)

# =====================================================================================
# Target 1: phantom Default_Monitor instance keys
# =====================================================================================
$phantomsFound = 0; $phantomsRemoved = 0; $phantomsLocked = 0

if (Test-Path $EnumBase) {
    $instKeys = @(Get-ChildItem $EnumBase -ErrorAction SilentlyContinue)
    Write-Output ("ENUM_BEFORE Default_Monitor instance keys: " + $instKeys.Count)

    foreach ($k in $instKeys) {
        $instanceId = "DISPLAY\Default_Monitor\$($k.PSChildName)"
        $isPresent = @($presentIds | Where-Object { $_ -ieq $instanceId }).Count -gt 0
        if ($isPresent) {
            Write-Output "ENUM_KEEP $instanceId (device present)"
            continue
        }
        # not present -> phantom
        $phantomsFound++
        if (-not $Force) {
            Write-Output "ENUM_PHANTOM $instanceId (would delete; -WhatIf mode)"
            continue
        }
        try {
            Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $k.PSPath) {
                # Remove-Item can "succeed" partially on ACL-protected subkeys
                $phantomsLocked++
                Write-Output "ENUM_LOCKED $instanceId (key still exists after delete attempt)"
            } else {
                $phantomsRemoved++
                Write-Output "ENUM_REMOVED $instanceId"
            }
        } catch {
            $phantomsLocked++
            Write-Output ("ENUM_LOCKED $instanceId (" + $_.Exception.Message.Trim() + ")")
        }
    }

    $after = @(Get-ChildItem $EnumBase -ErrorAction SilentlyContinue).Count
    Write-Output ("ENUM_AFTER Default_Monitor instance keys: " + $after)
} else {
    Write-Output "ENUM_BEFORE Default_Monitor instance keys: 0 (base key absent)"
    Write-Output "ENUM_AFTER Default_Monitor instance keys: 0"
}

# =====================================================================================
# Target 2: GraphicsDrivers\Configuration entries referencing Default_Monitor
# =====================================================================================
$cfgFound = 0; $cfgRemoved = 0; $cfgKept = 0

if (Test-Path $CfgBase) {
    $cfgAll = @(Get-ChildItem $CfgBase -ErrorAction SilentlyContinue)
    Write-Output ("CFG_BEFORE Configuration keys total: " + $cfgAll.Count)

    $cfgMatch = @($cfgAll | Where-Object { $_.PSChildName -imatch [regex]::Escape($Fragment) })
    foreach ($c in $cfgMatch) {
        $cfgFound++
        $name = $c.PSChildName
        if ($defaultMonitorPresent) {
            # A Default_Monitor is live: we cannot tell which Configuration entry backs the
            # current topology. Unsure -> KEEP.
            $cfgKept++
            Write-Output "CFG_KEEP $name (unsure: a Default_Monitor is currently present, cannot prove this config stale)"
            continue
        }
        # No Default_Monitor present: any config referencing it is stale by definition.
        if (-not $Force) {
            $cfgKept++
            Write-Output "CFG_KEEP $name (stale, would delete; -WhatIf mode)"
            continue
        }
        try {
            Remove-Item -LiteralPath $c.PSPath -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $c.PSPath) {
                $cfgKept++
                Write-Output "CFG_KEEP $name (delete attempted but key still exists)"
            } else {
                $cfgRemoved++
                Write-Output "CFG_REMOVED $name"
            }
        } catch {
            $cfgKept++
            Write-Output ("CFG_KEEP $name (delete failed: " + $_.Exception.Message.Trim() + ")")
        }
    }
    if ($cfgFound -eq 0) { Write-Output "CFG_NONE no Configuration keys reference $Fragment" }

    $cfgAfter = @(Get-ChildItem $CfgBase -ErrorAction SilentlyContinue).Count
    Write-Output ("CFG_AFTER Configuration keys total: " + $cfgAfter)
} else {
    Write-Output "CFG_BEFORE Configuration keys total: 0 (base key absent)"
    Write-Output "CFG_AFTER Configuration keys total: 0"
}

# =====================================================================================
# Machine-parseable summary
# =====================================================================================
Write-Output "RESULT PHANTOMS_FOUND=$phantomsFound PHANTOMS_REMOVED=$phantomsRemoved PHANTOMS_LOCKED=$phantomsLocked"
Write-Output "RESULT CFG_FOUND=$cfgFound CFG_REMOVED=$cfgRemoved CFG_KEPT=$cfgKept"
exit 0
