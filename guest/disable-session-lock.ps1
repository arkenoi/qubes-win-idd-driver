# Stop the Windows guest locking its own session.
#
# WHY THIS IS CORRECT IN QUBES, not a security weakening.
# In Qubes the isolation boundary is the VM, enforced by dom0. A guest-side lock screen adds
# no isolation: anyone able to reach the qube's windows is already at dom0's display, and
# dom0's own screen lock is what actually protects the machine. Linux qubes have no lock
# screen at all for exactly this reason. Worse, a guest lock invites the user to type a
# password INTO an untrusted VM, which is the thing Qubes exists to discourage.
#
# So a Windows qube locking itself is friction with no security benefit - and it actively
# breaks things:
#   - a locked session composites the LOCK SCREEN, whose clock and Spotlight image repaint on
#     their own, which silently contaminates any capture/present measurement;
#   - SendInput cannot reach the secure desktop, so scripted input fails - the documented cause
#     of the harness's "input cadence jitter" rep invalidations.
#
# The guest account keeps its password; nothing here weakens the VM boundary or dom0.
#
# REQUIRES ELEVATION for the machine-wide half. qrexec runs unelevated on clean-room guests,
# so the installer (SYSTEM) and the answer file's FirstLogonCommands are the paths that can
# apply this; -UserOnly exists for an unelevated best-effort.
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$UserOnly,
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed  = 0
$off = -not $Restore          # $off = locking disabled

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output ("ELEVATED=" + $elevated)
if (-not $elevated -and -not $UserOnly -and -not $WhatIfOnly) {
    Write-Output "RESULT=FAIL not elevated - the machine-wide half cannot be applied."
    Write-Output "       Use -UserOnly for the per-user half, or run from the installer/SYSTEM."
    exit 2
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why)
    if ($WhatIfOnly) { Write-Output ("WOULD  $Path!$Name = $Value   ($Why)"); return }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $rb = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ("$rb" -ne "$Value") { throw "readback '$rb' != '$Value'" }
        $script:changed++
        Write-Output ("SET    $Path!$Name = $Value")
    } catch {
        $script:failed++
        Write-Output ("FAIL   $Path!$Name : " + $_.Exception.Message)
    }
}

if (-not $UserOnly) {
    Write-Output "=== machine-wide ==="
    # THE DECISIVE ONE. NoLockScreen only suppresses the lock-screen UI; this is what stops the
    # workstation being locked at all (Win+L, idle, programmatic LockWorkStation).
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableLockWorkstation' `
        $(if($off){1}else{0}) 'DWord' 'no workstation lock at all'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' `
        $(if($off){1}else{0}) 'DWord' 'no lock screen UI'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'InactivityTimeoutSecs' `
        0 'DWord' 'no machine inactivity limit'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop' 'ScreenSaveActive' `
        $(if($off){'0'}else{'1'}) 'String' 'screensaver off, machine-wide'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop' 'ScreenSaverIsSecure' `
        '0' 'String' 'screensaver does not demand a password'

    # THE SECURE DESKTOP. Every UAC elevation prompt switches the INPUT DESKTOP to Winlogon,
    # which invalidates the desktop duplication - DXGI_ERROR_ACCESS_LOST - and forces the agent
    # to rebuild capture and follow the switch. That is one of the few remaining triggers of a
    # fault class that can, in its bad tail, cost the qube its GUI.
    #
    # It buys nothing HERE. A secure desktop defends against another program in the same Windows
    # session painting a convincing fake elevation prompt - a defence that only works if the user
    # can trust what they are looking at. In the Qubes model dom0 renders whatever the guest
    # sends, so any program in this guest can paint a lookalike prompt on the ordinary desktop
    # regardless. Real elevation gating would have to be a trusted DOM0 prompt (the shape of
    # gui-gated sudo), not an in-guest desktop switch. So the switch costs display stability and
    # returns a property this architecture cannot provide.
    #
    # UAC itself is UNCHANGED: prompts still appear and still require consent. Only the desktop
    # they appear on changes.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' `
        $(if($off){0}else{1}) 'DWord' 'UAC prompts on the normal desktop (no Winlogon switch)'

    if (-not $WhatIfOnly) {
        # Power: never blank or sleep, and never require a password on wake. CONSOLELOCK is the
        # "require sign-in on wakeup" knob and is invisible in the registry paths above.
        Write-Output "=== power ==="
        foreach ($c in @(
            'powercfg /change monitor-timeout-ac 0', 'powercfg /change monitor-timeout-dc 0',
            'powercfg /change standby-timeout-ac 0', 'powercfg /change standby-timeout-dc 0',
            'powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0',
            'powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0',
            'powercfg /setactive SCHEME_CURRENT'
        )) {
            $r = cmd /c "$c" 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Output "PWR    $c" ; $script:changed++ }
            else { Write-Output ("PWRFAIL $c : " + ($r -join ' ')) ; $script:failed++ }
        }
    }
}

Write-Output "=== per-user (current + default hive, so later accounts inherit) ==="
$perUser = @(
    @{ sub='Control Panel\Desktop'; n='ScreenSaveActive';    v=$(if($off){'0'}else{'1'}); why='screensaver' },
    @{ sub='Control Panel\Desktop'; n='ScreenSaverIsSecure'; v='0';                        why='no password on resume' },
    @{ sub='Control Panel\Desktop'; n='ScreenSaveTimeOut';   v='0';                        why='no timeout' }
)
foreach ($e in $perUser) { Set-Reg "HKCU:\$($e.sub)" $e.n $e.v 'String' "current user: $($e.why)" }

$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if ($elevated -and (Test-Path $defaultHive) -and -not $WhatIfOnly) {
    $loaded = $false
    try { & reg.exe load 'HKU\QwtNgLock' $defaultHive 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $loaded = $true } } catch { }
    if ($loaded) {
        foreach ($e in $perUser) { Set-Reg "Registry::HKEY_USERS\QwtNgLock\$($e.sub)" $e.n $e.v 'String' "default profile: $($e.why)" }
        # MUST unload or the default profile stays locked and new account creation fails in
        # ways that look unrelated to this script.
        [gc]::Collect(); & reg.exe unload 'HKU\QwtNgLock' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { [gc]::Collect(); Start-Sleep 1; & reg.exe unload 'HKU\QwtNgLock' 2>&1 | Out-Null }
    } else { Write-Output "WARN   could not load $defaultHive - later accounts will not inherit" }
} elseif (-not $elevated) {
    Write-Output "SKIP   default user hive (needs elevation) - current user only"
}

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed mode=" + $(if($off){'nolock'}else{'restore'}))
if ($script:failed -gt 0) { exit 1 }
