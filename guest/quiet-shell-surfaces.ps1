# Quiet the Windows shell surfaces that repaint on their own.
#
# STATUS: STAGED, NOT YET JUSTIFIED BY MEASUREMENT.
# Measured on Windows 11: 18.75 fps presented with NO input at all, ~350k real dirty pixels per
# frame (empty=0, so not cursor-only) - 77% of that guest's own workload present rate. Desktop
# effects were tested and RULED OUT as the cause (+2%..+9%, inside 9-25% noise, wrong
# direction). So something else repaints unprompted, and the surfaces below are the candidates.
#
# Which one it actually is comes from scratchpad/locate-idle-repaint.sh, which diffs
# whole-desktop captures during idle and attributes the changed bounding box to a window. Until
# that names a surface, applying everything here would be guessing - and would also make the
# result unattributable, since a single blanket change cannot say which key mattered.
#
# Hence -Group: apply ONE family at a time and re-measure, so the win is attributable and no
# setting is shipped that bought nothing. -Restore puts a family back.
#
# ORDER-INDEPENDENCE, as in disable-hw-accel.ps1: everything with a machine-wide policy is
# written as one, so it survives later software installs and applies to accounts created
# afterwards. Per-user settings with no policy equivalent are also written to the DEFAULT USER
# HIVE, since a plain HKCU write would cover only whoever happens to be logged on.
#
# NOT ATTEMPTED, deliberately: killing explorer.exe, disabling the taskbar, or removing shell
# packages. Those change what the user sees rather than what repaints behind their back, and a
# desktop that is fast because it is broken is not a fix.
[CmdletBinding()]
param(
    [ValidateSet('widgets', 'search', 'copilot', 'spotlight', 'all')]
    [string]$Group = 'all',
    [switch]$Restore,
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed  = 0
$on  = -not $Restore     # $on = quiet the surface

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why)
    if ($WhatIfOnly) { Write-Output ("WOULD  $Path!$Name = $Value   ($Why)"); return }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $script:changed++
        Write-Output ("SET    $Path!$Name = $Value")
    } catch {
        $script:failed++
        Write-Output ("FAIL   $Path!$Name : " + $_.Exception.Message)
    }
}

# machine-wide policies, per family
$machine = @{
    widgets = @(
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; n='AllowNewsAndInterests'; v=$(if($on){0}else{1}); why='Widgets / news and interests' },
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; n='EnableFeeds'; v=$(if($on){0}else{1}); why='feeds (Win10-era key, harmless on 11)' }
    )
    search = @(
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; n='EnableDynamicContentInWSB'; v=$(if($on){0}else{1}); why='search highlights (animated)' },
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; n='AllowSearchHighlights'; v=$(if($on){0}else{1}); why='search highlights' }
    )
    copilot = @(
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; n='TurnOffWindowsCopilot'; v=$(if($on){1}else{0}); why='Copilot surface' }
    )
    spotlight = @(
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; n='DisableWindowsSpotlightFeatures'; v=$(if($on){1}else{0}); why='Spotlight rotating content' },
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; n='DisableWindowsConsumerFeatures'; v=$(if($on){1}else{0}); why='consumer content pushes' },
        @{ p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; n='DisableSoftLanding'; v=$(if($on){1}else{0}); why='tips/suggestions popups' }
    )
}

# per-user settings with no policy equivalent, per family
$peruser = @{
    widgets = @(
        @{ sub='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; n='TaskbarDa'; v=$(if($on){0}else{1}); why='taskbar Widgets button' }
    )
    search = @(
        @{ sub='Software\Microsoft\Windows\CurrentVersion\Search'; n='SearchboxTaskbarMode'; v=$(if($on){0}else{1}); why='taskbar search box -> hidden' },
        @{ sub='Software\Microsoft\Windows\CurrentVersion\Feeds'; n='ShellFeedsTaskbarViewMode'; v=$(if($on){2}else{0}); why='feeds on taskbar -> off' }
    )
    copilot   = @()
    spotlight = @(
        @{ sub='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; n='SubscribedContent-338388Enabled'; v=$(if($on){0}else{1}); why='suggestions in Start' },
        @{ sub='Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; n='RotatingLockScreenOverlayEnabled'; v=$(if($on){0}else{1}); why='rotating lock screen' }
    )
}

$groups = if ($Group -eq 'all') { @('widgets','search','copilot','spotlight') } else { @($Group) }
Write-Output ("=== groups: " + ($groups -join ', ') + "  mode: " + $(if($on){'QUIET'}else{'RESTORE'}) + " ===")

foreach ($g in $groups) {
    Write-Output ""
    Write-Output "--- $g (machine-wide policy) ---"
    foreach ($e in $machine[$g]) { Set-Reg $e.p $e.n $e.v 'DWord' $e.why }

    if ($peruser[$g].Count -gt 0) {
        Write-Output "--- $g (per-user + default hive) ---"
        foreach ($e in $peruser[$g]) { Set-Reg "HKCU:\$($e.sub)" $e.n $e.v 'DWord' "current user: $($e.why)" }
    }
}

# default hive, once, for every per-user value in the selected groups
$allPerUser = @(); foreach ($g in $groups) { $allPerUser += $peruser[$g] }
$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if ($allPerUser.Count -gt 0 -and (Test-Path $defaultHive) -and -not $WhatIfOnly) {
    $loaded = $false
    try { & reg.exe load 'HKU\QwtNgShell' $defaultHive 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $loaded = $true } } catch { }
    if ($loaded) {
        foreach ($e in $allPerUser) {
            Set-Reg "Registry::HKEY_USERS\QwtNgShell\$($e.sub)" $e.n $e.v 'DWord' "default profile: $($e.why)"
        }
        # MUST unload or the default profile stays locked and new account creation fails in
        # ways that look unrelated to this script.
        [gc]::Collect()
        & reg.exe unload 'HKU\QwtNgShell' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "WARN   could not unload default hive - retrying"; [gc]::Collect(); Start-Sleep 1; & reg.exe unload 'HKU\QwtNgShell' 2>&1 | Out-Null }
    } else {
        Write-Output "WARN   could not load $defaultHive - new accounts will not inherit these"
    }
}

Write-Output ""
Write-Output "NOTE  explorer must be restarted for the taskbar-side values to take effect;"
Write-Output "      the measuring harness does that rather than assuming."
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed groups=" + ($groups -join ',') + " mode=" + $(if($on){'quiet'}else{'restore'}))
if ($script:failed -gt 0) { exit 1 }
