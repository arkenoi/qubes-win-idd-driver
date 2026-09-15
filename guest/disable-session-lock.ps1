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

    # THE SECURE DESKTOP - and it depends on the GUI mode, so read it rather than assume.
    # Every UAC elevation prompt switches the INPUT DESKTOP to Winlogon,
    # which invalidates the desktop duplication - DXGI_ERROR_ACCESS_LOST - and forces the agent
    # to rebuild capture and follow the switch. That is one of the few remaining triggers of a
    # fault class that can, in its bad tail, cost the qube its GUI.
    #
    # IN SEAMLESS MODE it buys nothing. A secure desktop defends against another program in the
    # same session painting a convincing fake elevation prompt - a defence that only works if the
    # user can trust what they are looking at. Seamless composites individual guest windows into
    # dom0's desktop, so a lookalike prompt is paintable as an ordinary window and the user has no
    # trusted full-screen surface to compare it against. There the switch costs display stability
    # and returns a property this architecture cannot provide.
    #
    # IN FULLSCREEN MODE it is real, and is kept. The qube owns the whole viewport, and dom0 can
    # deliver a genuine secure attention sequence: MSG_KEYPRESS-driven SignalSASEvent (agent
    # gui-agent/vchan-handlers.c) sets Global\QGA_SAS_TRIGGER and the watchdog SERVICE calls
    # SendSAS. In-guest code cannot synthesise that, so what appears after it is genuinely
    # Winlogon and the secure desktop means what it claims.
    #
    # UAC itself is UNCHANGED either way: prompts still appear and still require consent. Only
    # the desktop they appear on changes, and only in seamless.
    $seamless = 0
    foreach ($qk in 'HKLM:\Software\Invisible Things Lab\Qubes Tools\gui-agent',
                    'HKLM:\Software\Invisible Things Lab\Qubes Tools') {
        $v = (Get-ItemProperty $qk -EA SilentlyContinue).SeamlessMode
        if ($null -ne $v) { $seamless = [int]$v; break }
    }
    if ($seamless -eq 1) {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' `
            $(if($off){0}else{1}) 'DWord' 'seamless: UAC prompts on the normal desktop (no Winlogon switch)'
    } else {
        Write-Output "  PromptOnSecureDesktop: LEFT ALONE - fullscreen mode, where dom0's emulated Ctrl-Alt-Del makes the secure desktop a real guarantee"
    }

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

# ---- HIVE-GUARD-BEGIN
# NEVER reg-load an offline hive while a logon may be in flight. This script runs as SYSTEM from
# installer stage 2 (an ONSTART task) CONCURRENTLY with the autologon that is armed on every image we
# ship. On a slow first boot - pending driver packages, or an AppVM's FIRST boot where the profile is
# still being created by copying C:\Users\Default\NTUSER.DAT - the autologon user's hive is not under
# HKEY_USERS yet when this runs. reg-loading their NTUSER.DAT, or the Default hive it is being copied
# from, at that instant makes Winlogon's LoadUserProfile find the file in use: TEMP PROFILE, no
# shell, seamless maps zero windows - and our own load succeeded, so the trailer said failed=0
# (findings/issues.md, installer audit 2026-09-16, item 2). So: if autologon is armed, wait (bounded)
# until Winlogon has loaded that user's hive before touching anything offline; if it never appears,
# SKIP every offline hive and COUNT A FAILURE, so the caller cannot read the run as success. Hives
# already under HKEY_USERS are written in place regardless - nothing is mounted for those.
#
# BYTE-IDENTICAL in guest/disable-hw-accel.ps1 and guest/disable-session-lock.ps1 (origin of the
# logic: guest/quiet-desktop.ps1:169-203, inline there). Duplicated rather than shared on purpose:
# packaging/make-setup.ps1 and mgmt/build-answer-stick.sh copy each guest script BY NAME into a flat
# payload, so a shared module would have to be added to both lists and would ship NOWHERE if either
# were missed (the 2026-09-04 helper-packaging P1). tools/tests/hive-guard-selftest.sh fails the
# moment the two copies drift.
#
# The three primitives are separate one-liners so the offline suite can replace them (the dev qube
# has no registry); everything else in the block is the code under test.
function Get-HiveGuardWinlogon { Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue }
function Test-HiveGuardKey([string]$Sid) { Test-Path "Registry::HKEY_USERS\$Sid" }
function Resolve-HiveGuardSid([string]$Account) { ([System.Security.Principal.NTAccount]$Account).Translate([System.Security.Principal.SecurityIdentifier]).Value }
$script:hiveGuardVerdict    = $null   # decided ONCE per run: $true = offline loads allowed, $false = every offline hive is skipped
$script:hiveGuardTimeoutSec = 120
$script:hiveGuardPollSec    = 5

# Decides the verdict on first use (later calls return at once), prints why, and counts a failure
# when the answer is "not safe". It prints through the pipeline like the rest of this script, so it
# deliberately returns NOTHING - read $script:hiveGuardVerdict after calling it.
function Invoke-HiveGuard {
    if ($null -ne $script:hiveGuardVerdict) { return }
    $script:hiveGuardVerdict = $false
    $wl = Get-HiveGuardWinlogon
    if ("$($wl.AutoAdminLogon)" -ne '1' -or -not $wl.DefaultUserName) {
        Write-Output 'ok     no autologon armed - no logon expected in flight, offline hives allowed'
        $script:hiveGuardVerdict = $true
        return
    }
    $acct = if ($wl.DefaultDomainName) { "$($wl.DefaultDomainName)\$($wl.DefaultUserName)" } else { "$($wl.DefaultUserName)" }
    $autoSid = $null
    try { $autoSid = Resolve-HiveGuardSid $acct } catch { }
    if (-not $autoSid) {
        $script:failed++
        Write-Output "FAIL   autologon user '$acct' does not resolve to a SID - cannot tell whether a logon is in flight, offline hives SKIPPED"
        return
    }
    # THIS IS A POLL, deliberately. The push form is RegNotifyChangeKeyValue(HKEY_USERS,
    # REG_NOTIFY_CHANGE_NAME); whether a hive LOAD (a link cell, not a created key) raises it is not
    # documented, it needs a P/Invoke compiled under SYSTEM at boot, and the most it could save is
    # one poll interval on a wait that ends with the logon itself. The truth is the re-check, never
    # the timer: the loop ends on the key EXISTING, or on the deadline - which is a counted failure.
    $deadline = (Get-Date).AddSeconds($script:hiveGuardTimeoutSec)
    $announced = $false
    while (-not (Test-HiveGuardKey $autoSid) -and (Get-Date) -lt $deadline) {
        if (-not $announced) {
            Write-Output "WAIT   autologon user '$acct' ($autoSid) has no loaded hive yet - waiting up to $($script:hiveGuardTimeoutSec)s for the logon to complete (poll $($script:hiveGuardPollSec)s)"
            $announced = $true
        }
        Start-Sleep -Seconds $script:hiveGuardPollSec
    }
    if (Test-HiveGuardKey $autoSid) {
        Write-Output "ok     autologon user '$acct' hive is loaded - logon complete, offline hives allowed"
        $script:hiveGuardVerdict = $true
        return
    }
    $script:failed++
    Write-Output "FAIL   autologon user '$acct' ($autoSid) has no loaded hive after $($script:hiveGuardTimeoutSec)s - logon may still be in flight, offline hives SKIPPED this run"
}
# ---- HIVE-GUARD-END

# ---- OFFLINE-HIVE-BEGIN
# Load an offline NTUSER.DAT, write $perUser, unload - reading EVERY result. Until 2026-09-16 the
# second unload attempt's exit code was discarded (installer audit item 15): a hive left loaded keeps
# the Default profile locked for the rest of the boot, every account created after that gets a temp
# profile, and the trailer still said failed=0. Twin of Set-OfflineHive in guest/disable-hw-accel.ps1
# (which counts a failed LOAD too; this one keeps its pre-existing WARN there - not this mandate).
# EVERY reg.exe load in this script goes through here, so the hive guard gates all of them
# (tools/tests/hive-guard-selftest.sh counts the loads outside this block and requires zero).
function Set-OfflineHive {
    param([string]$DatPath, [string]$Label)
    Invoke-HiveGuard   # once per run; prints its verdict; a deadline is a counted failure
    if (-not $script:hiveGuardVerdict) { Write-Output "SKIP   ${Label}: $DatPath NOT loaded - a logon may be in flight (counted above)"; return }   # GUARD:hivewait
    $mount = 'QwtNgLock'
    & reg.exe load "HKU\$mount" $DatPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "WARN   could not load $DatPath - later accounts will not inherit"
        return
    }
    try {
        foreach ($e in $perUser) { Set-Reg "Registry::HKEY_USERS\$mount\$($e.sub)" $e.n $e.v 'String' "${Label}: $($e.why)" }
    } finally {
        # MUST unload or the default profile stays locked and new account creation fails in
        # ways that look unrelated to this script. Two attempts: the provider handles need a GC
        # to go away. The result of the LAST attempt is what counts.
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep 1; [gc]::Collect()
            & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { $script:failed++; Write-Output "FAIL   ${Label}: could not unload hive $DatPath - PROFILE LEFT LOCKED" }   # GUARD:unloadread
    }
}
# ---- OFFLINE-HIVE-END

$defaultHive = 'C:\Users\Default\NTUSER.DAT'
if ($elevated -and (Test-Path $defaultHive) -and -not $WhatIfOnly) {
    Set-OfflineHive $defaultHive 'default profile'
} elseif (-not $elevated) {
    Write-Output "SKIP   default user hive (needs elevation) - current user only"
}

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed mode=" + $(if($off){'nolock'}else{'restore'}))
if ($script:failed -gt 0) { exit 1 }
