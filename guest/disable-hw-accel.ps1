# Disable GPU/hardware acceleration for software known to attempt it.
#
# WHY. A Qubes Windows guest has no GPU. Applications that try hardware acceleration fall
# back through a software path that is frequently slower than asking for software rendering
# outright, and on the Basic Display Adapter it is a common source of rendering artifacts and
# blank/garbled regions. Every frame also has to reach dom0 through the agent's capture path,
# so anything that makes the guest repaint more aggressively costs twice.
# Measured proof (FINDINGS.md 2026-08-02): Word with HW accel ON presented a frame every
# 257 ms and dirtied ~237k px per keystroke; OFF it was 31 ms and ~3.4k px. The Office keys
# below are the only A/B-measured entries; the rest are the standard GPU-less-VDI set
# (VMware OSOT / Citrix Optimizer prior art), extrapolated, not measured here.
#
# ORDER-INDEPENDENCE - the point of this script.
# It runs at post-install time, BEFORE any of this software is installed. That works because
# almost everything below is written as a POLICY under HKLM\SOFTWARE\Policies. Policies are
# read by the application at runtime, not baked in at install time, and installers do not
# remove policy keys they did not create. So a browser installed next month still honours a
# key written today.
#
# The exceptions are called out inline: settings with no machine-wide equivalent live in the
# user hive and are therefore per-user. For those, this script writes:
#   1. HKCU of the invoking user (whoever that is - under qrexec that is SYSTEM, which is
#      harmless but useless; the real coverage comes from 2 and 3),
#   2. every EXISTING local profile (ProfileList walk; already-loaded hives are written in
#      place, offline ones are reg-load'ed and unloaded),
#   3. the DEFAULT profile (C:\Users\Default\NTUSER.DAT) so accounts created later inherit.
# This makes the script safe to run from any elevated context, including qrexec/SYSTEM,
# where a plain HKCU write would land in the wrong hive.
# An OFFLINE hive is only ever loaded once the autologon user's own logon is complete - see the
# HIVE-GUARD block: loading NTUSER.DAT under a logon in flight hands that user a temp profile.
#
# WOW6432Node is deliberately NOT written separately: policy keys are read from the native
# 64-bit view by 32-bit apps too via the standard policy lookup, and duplicating them creates
# two sources of truth that drift.
#
# ---------------------------------------------------------------------------------------
# DELIBERATELY NOT COVERED - Electron apps that ignore policies (manual, per-user only).
# Electron does not ship Chromium's enterprise-policy machinery, so Chrome-style
# HKLM\Software\Policies keys do NOTHING for these. The toggle lives in per-user JSON that
# the app itself (and its updater) rewrites, so seeding it from an installer is fragile and
# is not attempted here. If a user needs one of these quiet, do it in-app or per user:
#   * VS Code:       %APPDATA%\Code\argv.json -> { "disable-hardware-acceleration": true }
#                    (official "Configure Runtime Arguments" file; no policy equivalent -
#                    the VSCode HKLM policy allowlist does not include HW accel).
#   * Discord:       %APPDATA%\discord\settings.json -> "enableHardwareAcceleration": false
#                    (same as the in-app Appearance toggle; no policy support; shortcut
#                    --disable-gpu is unreliable, Discord filters/relaunches).
#   * Teams classic: %APPDATA%\Microsoft\Teams\desktop-config.json ->
#                    appPreferenceSettings.disableGpu = true (Electron Teams is retired;
#                    only matters on old installs).
#   * Teams new / any WebView2 host: NO app-level toggle. The one central lever is the
#                    machine env var WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu
#                    (REG_SZ under HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\
#                    Environment). NOT set here: it hits EVERY WebView2 app on the box and
#                    Microsoft labels it unsupported/troubleshooting-only. Opt-in manually
#                    if new-Teams rendering hurts; test Teams video paths after.
#   * Signal:        no documented switch at all; --disable-gpu on the shortcut is the only
#                    route and Signal's updater recreates shortcuts. Skipped.
# The one Electron app with real policy support is Slack - handled below in the HKLM set.
# ---------------------------------------------------------------------------------------
[CmdletBinding()]
param(
    # Report what would change without writing anything.
    [Alias('DryRun', 'WhatIf')]
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed  = 0

# HKLM writes and hive loads need elevation; fail early with a clear message instead of
# emitting a page of FAILs. Dry runs are allowed unelevated.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated -and -not $WhatIfOnly) {
    Write-Output "FAIL   this script must run elevated (HKLM policies + user-hive loads)"
    Write-Output "=== RESULT === changed=0 failed=1"
    exit 1
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why)
    if ($WhatIfOnly) { Write-Output ("WOULD  $Path!$Name = $Value   ($Why)"); return }
    try {
        # Idempotent: report already-correct values as OK, do not count them as changes.
        if (Test-Path $Path) {
            $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
            if ($null -ne $cur -and "$cur" -eq "$Value") {
                Write-Output ("OK     $Path!$Name = $Value (already set)")
                return
            }
        } else {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
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
# decides, which on a guest with no GPU is the outcome we want anyway. (Caveat to verify
# once per image: Chromium documents some registry policies as trusted only on managed
# machines; this one is the standard VDI recipe and is reported to work from plain HKLM.)
foreach ($b in @(
    @{ p = 'HKLM:\SOFTWARE\Policies\Google\Chrome';           n = 'Chrome' },
    @{ p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';          n = 'Edge' },
    @{ p = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';     n = 'Brave' },
    @{ p = 'HKLM:\SOFTWARE\Policies\Chromium';                n = 'Chromium' }
)) {
    Set-Reg $b.p 'HardwareAccelerationModeEnabled' 0 'DWord' "$($b.n): software rendering"
}

# --- Firefox ---------------------------------------------------------------------------
# Firefox's enterprise policy engine reads HardwareAcceleration from this key (FF 60+).
# Modern Firefox still composites via WebRender; this forces WebRender-on-software, which
# is the path a GPU-less guest would fall back to anyway - the policy makes it
# deterministic and skips the probing.
Set-Reg 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'HardwareAcceleration' 0 'DWord' 'Firefox: software rendering'

# --- Slack -----------------------------------------------------------------------------
# The one mainstream Electron app with an official policy surface (Slack 4.31+, ADMX
# published by Slack). Enforced variant: removes the user's Preferences>Advanced toggle.
Set-Reg 'HKLM:\SOFTWARE\Policies\Slack' 'HardwareAcceleration' 0 'DWord' 'Slack: software rendering (enforced)'

# --- Microsoft Office, HKLM attempt (UNVERIFIED - see per-user section below) -----------
# The Office ADMX defines this policy under HKCU only (User Configuration); research found
# no HKLM path that Office documents reading. These HKLM writes are kept as free insurance
# for builds that do consult HKLM, but the delivery that is KNOWN to work (A/B-measured
# 2026-08-02) is the per-user set below. Do not count on this block alone.
# 16.0 covers 2016/2019/2021/2024/365; 15.0 = 2013; 14.0 = 2010 (partial HW accel, anecdotal).
foreach ($v in @('16.0', '15.0', '14.0')) {
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\office\$v\common\graphics" 'disablehardwareacceleration' 1 'DWord' "Office $v (unverified HKLM path)"
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\office\$v\common\graphics" 'disableanimations'          1 'DWord' "Office ${v}: no animation (unverified HKLM path)"
}

# --- Internet Explorer / legacy WebBrowser control ---------------------------------------
# Still relevant: the embedded WebBrowser control is used by installers and older apps.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' 'UseSWRender' 1 'DWord' 'IE/WebBrowser control'

# --- WPF (Avalon), machine-wide variant -------------------------------------------------
# Officially documented under HKCU (aa970912); the HKLM mirror is long-standing practice
# (VDI optimizers set it) and honored machine-wide. Set both: HKLM covers future users
# immediately, the per-user pass below makes it deterministic per profile.
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Avalon.Graphics' 'DisableHWAcceleration' 1 'DWord' 'WPF software rasteriser (machine)'

Write-Output ""
Write-Output "=== per-user settings with no verified machine-wide equivalent ==="
Write-Output "    written to the invoking user, every existing profile, and the DEFAULT profile"

# Each entry: registry subpath relative to a user hive root, name, value, type, rationale.
# Office plain keys are the A/B-MEASURED remedy (FINDINGS.md 2026-08-02: 257 ms -> 31 ms
# frame interval in Word). The HKCU *Policies* variant is the documented ADMX location and
# additionally greys out the Options>Advanced checkbox so users cannot re-enable it.
# UseAnimations=0 under ...\Common was part of the measured remedy; it is sparsely
# documented (type/effect not independently verified) - kept because it was in the set
# that demonstrably fixed Word typing.
$perUser = @(
    @{ sub = 'Software\Microsoft\Avalon.Graphics'; name = 'DisableHWAcceleration'; val = 1; type = 'DWord'; why = 'WPF software rasteriser' }
)
foreach ($v in @('16.0', '15.0')) {
    $perUser += @{ sub = "Software\Microsoft\Office\$v\Common\Graphics";          name = 'DisableHardwareAcceleration'; val = 1; type = 'DWord'; why = "Office ${v}: HW accel off (measured)" }
    $perUser += @{ sub = "Software\Microsoft\Office\$v\Common\Graphics";          name = 'DisableAnimations';           val = 1; type = 'DWord'; why = "Office ${v}: no animations (measured)" }
    $perUser += @{ sub = "Software\Microsoft\Office\$v\Common";                   name = 'UseAnimations';               val = 0; type = 'DWord'; why = "Office ${v}: no typing animation (measured, sparsely documented)" }
    $perUser += @{ sub = "Software\Policies\Microsoft\office\$v\common\graphics"; name = 'disablehardwareacceleration'; val = 1; type = 'DWord'; why = "Office ${v}: policy variant, locks the UI checkbox" }
    $perUser += @{ sub = "Software\Policies\Microsoft\office\$v\common\graphics"; name = 'disableanimations';           val = 1; type = 'DWord'; why = "Office ${v}: policy variant" }
}

function Set-PerUserValues {
    param([string]$HiveRoot, [string]$Label)
    foreach ($e in $perUser) {
        Set-Reg "$HiveRoot\$($e.sub)" $e.name $e.val $e.type "${Label}: $($e.why)"
    }
}

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
# Load an offline NTUSER.DAT, apply $perUser, unload. Counts load/unload failures as
# failures: a silently skipped profile is exactly the "check that cannot fail" this
# project has been burned by, and a hive left loaded locks the profile against logon.
# EVERY reg.exe load in this script goes through here, so the hive guard gates all of them
# (tools/tests/hive-guard-selftest.sh counts the loads outside this block and requires zero).
function Set-OfflineHive {
    param([string]$DatPath, [string]$Label)
    if (-not (Test-Path $DatPath)) {
        Write-Output "SKIP   ${Label}: $DatPath not found"
        return
    }
    if ($WhatIfOnly) {
        # Dry run must still report the per-profile writes (a real run would make them).
        foreach ($e in $perUser) {
            Write-Output ("WOULD  [$DatPath]\$($e.sub)!$($e.name) = $($e.val)   (${Label}: $($e.why))")
        }
        return
    }
    Invoke-HiveGuard   # once per run; prints its verdict; a deadline is a counted failure
    if (-not $script:hiveGuardVerdict) { Write-Output "SKIP   ${Label}: $DatPath NOT loaded - a logon may be in flight (counted above)"; return }   # GUARD:hivewait
    $mount = "QwtNg$PID"   # unique per process so concurrent runs cannot collide
    & reg.exe load "HKU\$mount" $DatPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $script:failed++
        Write-Output "FAIL   ${Label}: could not load $DatPath - its user will not get the per-user settings"
        return
    }
    try {
        Set-PerUserValues "Registry::HKEY_USERS\$mount" $Label
    } finally {
        # The hive MUST be unloaded or the profile is left locked and logon/new-user
        # creation fails in ways that look unrelated to this script.
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

# 1. The invoking user's own hive. Under qrexec this is SYSTEM's hive - harmless; the
#    profile walk below is what reaches real users in that context.
Set-PerUserValues 'HKCU:' 'current user'

# 2. Every existing local profile (SIDs S-1-5-21-*; system accounts 18/19/20 excluded).
#    Logged-on users' hives are already mounted under HKU\<SID> - write them in place;
#    offline profiles are loaded/unloaded.
$profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
foreach ($prof in (Get-ChildItem $profileList -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' })) {
    $sid = $prof.PSChildName
    $img = (Get-ItemProperty -Path $prof.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $img) { Write-Output "SKIP   profile ${sid}: no ProfileImagePath"; continue }
    $who = Split-Path $img -Leaf
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        Set-PerUserValues "Registry::HKEY_USERS\$sid" "profile $who (loaded)"
    } else {
        Set-OfflineHive (Join-Path $img 'NTUSER.DAT') "profile $who"
    }
}

# 3. The default profile, so accounts created later inherit the settings.
Set-OfflineHive 'C:\Users\Default\NTUSER.DAT' 'default profile'

Write-Output ""
Write-Output "=== not covered (see header comment for per-app manual steps) ==="
Write-Output "NOTE   Electron apps ignore HKLM policies: VS Code, Discord, Teams classic, Signal - per-user JSON only"
Write-Output "NOTE   WebView2 hosts (new Teams/Outlook): env-var hammer available but NOT set here (affects every WebView2 app)"

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed")
if ($script:failed -gt 0) { exit 1 }
