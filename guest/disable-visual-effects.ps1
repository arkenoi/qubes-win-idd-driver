# Turn off the desktop effects that make Windows repaint for their own sake.
#
# WHY THIS IS A PERFORMANCE FIX AND NOT COSMETICS.
# Measured, agent/display/resolution held constant: Windows 11 presents ~1.88x more frames
# than Windows 10 for identical input (488 vs 259 over 20 s). Every present costs the capture
# path a pass, and on a guest with no GPU that pass is CPU. Coalescing makes a redundant
# present CHEAPER; this aims at the presents existing at all.
#
# The suspects are the effects Windows 11 enables by default and Windows 10 largely does not:
# transparency (Mica/acrylic on frames and menus), window animations, and the fade/slide
# effects that repaint a region over many frames instead of one. Each is a repaint the guest
# generates on its own, with no user input behind it.
#
# WHETHER IT ACTUALLY HELPS IS A MEASUREMENT, NOT A CLAIM. scratchpad/veffects-ab.sh runs the
# same workload with these settings on and off and compares present counts. Ship it only if
# that shows a real reduction; a nil result is a result.
#
# ORDER-INDEPENDENCE. Same approach as disable-hw-accel.ps1: everything that HAS a machine-wide
# policy is written as one, and everything per-user is written to the DEFAULT USER HIVE as well
# as the current user, so accounts created later inherit it. Unlike browser settings, most
# visual-effect switches are per-user by design and have no policy equivalent - that is why the
# default hive is written rather than skipped.
[CmdletBinding()]
param(
    # Put the settings back to Windows' defaults, so an A/B can measure both directions.
    [switch]$Restore,
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

# perf value, restore value  (restore = Windows' out-of-box setting)
$fast = -not $Restore

# --- per-user settings, applied to the current user AND the default hive ------------------
# VisualFXSetting 2 = "adjust for best performance" (3 = let Windows choose, the default).
# MinAnimate 0 kills minimize/maximize animation. EnableTransparency 0 removes Mica/acrylic,
# which is the Windows 11 specific one and the most likely source of continuous repaint.
$perUser = @(
    @{ sub='Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; name='VisualFXSetting';
       val=$(if($fast){2}else{3}); type='DWord'; why='best performance vs let Windows choose' },
    @{ sub='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; name='EnableTransparency';
       val=$(if($fast){0}else{1}); type='DWord'; why='Mica/acrylic transparency' },
    @{ sub='Control Panel\Desktop\WindowMetrics'; name='MinAnimate';
       val=$(if($fast){'0'}else{'1'}); type='String'; why='minimize/maximize animation' },
    @{ sub='Control Panel\Desktop'; name='DragFullWindows';
       val=$(if($fast){'0'}else{'1'}); type='String'; why='show window contents while dragging' },
    @{ sub='Control Panel\Desktop'; name='FontSmoothing';
       val='2'; type='String'; why='left at default - changing it alters pixels, not repaint rate' }
)

Write-Output ("=== per-user visual effects (" + $(if($fast){'PERFORMANCE'}else{'WINDOWS DEFAULTS'}) + ") ===")
foreach ($e in $perUser) { Set-Reg "HKCU:\$($e.sub)" $e.name $e.val $e.type "current user: $($e.why)" }

$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if ((Test-Path $defaultHive) -and -not $WhatIfOnly) {
    $loaded = $false
    try {
        & reg.exe load 'HKU\QwtNgVfx' $defaultHive 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $loaded = $true }
    } catch { }
    if ($loaded) {
        foreach ($e in $perUser) {
            Set-Reg "Registry::HKEY_USERS\QwtNgVfx\$($e.sub)" $e.name $e.val $e.type "default profile: $($e.why)"
        }
        # The hive MUST be unloaded or the default profile is left locked and new account
        # creation fails in ways that look unrelated to this script.
        [gc]::Collect()
        & reg.exe unload 'HKU\QwtNgVfx' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "WARN   could not unload the default hive - retrying"
            [gc]::Collect(); Start-Sleep 1; & reg.exe unload 'HKU\QwtNgVfx' 2>&1 | Out-Null
        }
    } else {
        Write-Output "WARN   could not load $defaultHive - new accounts will not inherit these"
    }
}

# --- machine-wide, where one exists --------------------------------------------------------
# DWM composition itself is NOT disabled: it cannot be turned off on Windows 8+, and attempting
# it via the old DisallowFlip/Composition keys does nothing on 10/11. Only animation policy has
# a real machine-wide switch.
Write-Output ""
Write-Output "=== machine-wide ==="
Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' `
    $(if($fast){([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00))}else{([byte[]](0x9E,0x1E,0x07,0x80,0x12,0x00,0x00,0x00))}) `
    'Binary' 'animation/fade bitmask'

Write-Output ""
Write-Output "NOTE  a sign-out or explorer restart is needed for some of these to take effect;"
Write-Output "      the A/B harness restarts explorer rather than assuming."
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed mode=" + $(if($fast){'performance'}else{'defaults'}))
if ($script:failed -gt 0) { exit 1 }
