# Disable GPU/hardware acceleration for software known to attempt it.
#
# WHY. A Qubes Windows guest has no GPU. Applications that try hardware acceleration fall
# back through a software path that is frequently slower than asking for software rendering
# outright, and on the Basic Display Adapter it is a common source of rendering artifacts and
# blank/garbled regions. Every frame also has to reach dom0 through the agent's capture path,
# so anything that makes the guest repaint more aggressively costs twice.
#
# ORDER-INDEPENDENCE - the point of this script.
# It runs at post-install time, BEFORE any of this software is installed. That works because
# almost everything below is written as a POLICY under HKLM\SOFTWARE\Policies. Policies are
# read by the application at runtime, not baked in at install time, and installers do not
# remove policy keys they did not create. So a browser installed next month still honours a
# key written today.
#
# The exceptions are called out inline: settings with no policy equivalent live in HKCU and
# are therefore per-user. For those, this script writes the DEFAULT USER HIVE
# (C:\Users\Default\NTUSER.DAT) as well as the current user, so accounts created later
# inherit them. A plain HKCU write would apply only to whoever happened to be logged on.
#
# WOW6432Node is deliberately NOT written separately: policy keys are read from the native
# 64-bit view by 32-bit apps too via the standard policy lookup, and duplicating them creates
# two sources of truth that drift.
[CmdletBinding()]
param(
    # Report what would change without writing anything.
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed  = 0

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

Write-Output "=== machine-wide policies (survive later installation of the software) ==="

# --- Chromium family -------------------------------------------------------------------
# HardwareAccelerationModeEnabled is a supported policy in Chrome, Edge and Brave. Setting it
# to 0 makes the browser start in software rendering regardless of what the GPU blocklist
# decides, which on a guest with no GPU is the outcome we want anyway.
foreach ($b in @(
    @{ p = 'HKLM:\SOFTWARE\Policies\Google\Chrome';           n = 'Chrome' },
    @{ p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';          n = 'Edge' },
    @{ p = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';     n = 'Brave' },
    @{ p = 'HKLM:\SOFTWARE\Policies\Chromium';                n = 'Chromium' }
)) {
    Set-Reg $b.p 'HardwareAccelerationModeEnabled' 0 'DWord' "$($b.n): software rendering"
}

# --- Firefox ---------------------------------------------------------------------------
# Firefox's enterprise policy engine reads HardwareAcceleration from this key.
Set-Reg 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'HardwareAcceleration' 0 'DWord' 'Firefox: software rendering'

# --- Microsoft Office ------------------------------------------------------------------
# Office honours the Graphics policy per major version. 16.0 covers 2016/2019/2021/365;
# 15.0/14.0 are included so an older install is covered without a second pass.
foreach ($v in @('16.0', '15.0', '14.0')) {
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\office\$v\common\graphics" 'disablehardwareacceleration' 1 'DWord' "Office $v"
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\office\$v\common\graphics" 'disableanimations'          1 'DWord' "Office $v: no animation"
}

# --- Internet Explorer / legacy WebBrowser control ---------------------------------------
# Still relevant: the embedded WebBrowser control is used by installers and older apps.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' 'UseSWRender' 1 'DWord' 'IE/WebBrowser control'

Write-Output ""
Write-Output "=== per-user settings with no policy equivalent ==="
Write-Output "    written to the DEFAULT profile as well, so accounts created later inherit them"

# WPF (Avalon) has no policy key; it is read per-user. DisableHWAcceleration=1 forces WPF
# applications onto the software rasteriser.
$perUser = @(
    @{ sub = 'Software\Microsoft\Avalon.Graphics'; name = 'DisableHWAcceleration'; val = 1; why = 'WPF software rasteriser' }
)

foreach ($e in $perUser) { Set-Reg "HKCU:\$($e.sub)" $e.name $e.val 'DWord' "current user: $($e.why)" }

# Load the default profile hive and apply the same values, so this is not a one-account fix.
$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if ((Test-Path $defaultHive) -and -not $WhatIfOnly) {
    $loaded = $false
    try {
        & reg.exe load 'HKU\QwtNgDefault' $defaultHive 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $loaded = $true }
    } catch { }
    if ($loaded) {
        foreach ($e in $perUser) {
            Set-Reg "Registry::HKEY_USERS\QwtNgDefault\$($e.sub)" $e.name $e.val 'DWord' "default profile: $($e.why)"
        }
        # The hive MUST be unloaded or the default profile is left locked and new user
        # creation fails in ways that look unrelated to this script.
        [gc]::Collect()
        & reg.exe unload 'HKU\QwtNgDefault' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "WARN   could not unload the default hive - retrying"; [gc]::Collect(); Start-Sleep 1; & reg.exe unload 'HKU\QwtNgDefault' 2>&1 | Out-Null }
    } else {
        Write-Output "WARN   could not load $defaultHive - new accounts will not inherit the per-user settings"
    }
}

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed")
if ($script:failed -gt 0) { exit 1 }
