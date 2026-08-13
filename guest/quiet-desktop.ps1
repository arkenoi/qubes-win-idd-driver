# QWT-NG: strip the consumer/cloud surface a Windows guest does not need in a qube.
#
# WHY. A qube is a tool. Everything below is either a popup that steals focus over the seamless
# desktop, a background service that repaints or phones home, or a feature that cannot work at
# all on a qube with no networking - and each one costs twice here, because every repaint also
# has to cross the agent's capture path to dom0.
#
# WHAT THIS IS NOT. Nothing is uninstalled and no service is disabled: every entry is a standard
# MACHINE policy under HKLM\SOFTWARE\Policies (plus two HKLM feature switches). Policies are read
# at runtime, so software installed LATER still honours them, and an admin can change or delete
# any value afterwards. Windows Search itself stays on - only Cortana and its web results go, so
# Start still finds local programs.
#
# Runs from installer stage 2 together with disable-hw-accel.ps1, under the same /noapptweaks
# switch. Emits the trailer the installer parses:  === RESULT === changed=N failed=N
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed = 0

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$What)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $cur -and "$cur" -eq "$Value") { Write-Output "ok     $What (already set)"; return }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $script:changed++
        Write-Output "SET    $What"
    } catch {
        $script:failed++
        Write-Output "FAIL   $What : $($_.Exception.Message)"
    }
}

$POL = 'HKLM:\SOFTWARE\Policies\Microsoft'

# --- OneDrive --------------------------------------------------------------------------------
# The "set up OneDrive" reminder pops over the seamless desktop and on an offline qube can never
# succeed at anything. DisableFileSyncNGSC stops the client starting at all.
Set-Reg "$POL\Windows\OneDrive" 'DisableFileSyncNGSC' 1 'DWord' 'OneDrive: client does not start'
Set-Reg "$POL\Windows\OneDrive" 'DisableFileSync'     1 'DWord' 'OneDrive: file sync off'
$run = @(Get-Process OneDrive -ErrorAction SilentlyContinue)
if ($run.Count) {
    $run | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:changed++
    Write-Output "SET    OneDrive: stopped $($run.Count) running instance(s)"
}

# --- news, weather, widgets ------------------------------------------------------------------
# Win11 calls it Widgets (Dsh), Win10 called it News and Interests (Windows Feeds). Both are a
# live-updating panel on the taskbar: constant repaints of content that cannot load offline.
Set-Reg "$POL\Dsh"             'AllowNewsAndInterests' 0 'DWord' 'Widgets (news/weather panel) off'
Set-Reg "$POL\Windows\Windows Feeds" 'EnableFeeds'     0 'DWord' 'News and Interests (Win10 taskbar) off'
Set-Reg "$POL\Windows\Windows Chat"  'ChatIcon'        3 'DWord' 'Chat/Meet Now taskbar icon hidden'

# --- Cortana and web results in Start --------------------------------------------------------
# Local search keeps working; only the assistant and the internet round-trips go.
Set-Reg "$POL\Windows\Windows Search" 'AllowCortana'             0 'DWord' 'Cortana off'
Set-Reg "$POL\Windows\Windows Search" 'DisableWebSearch'         1 'DWord' 'no web results in Start search'
Set-Reg "$POL\Windows\Windows Search" 'ConnectedSearchUseWeb'    0 'DWord' 'no connected web search'
Set-Reg "$POL\Windows\Windows Search" 'AllowSearchToUseLocation' 0 'DWord' 'search does not use location'
Set-Reg "$POL\Windows\Windows Search" 'EnableDynamicContentInWSB' 0 'DWord' 'no search highlights'

# --- Copilot / Recall (25H2) ------------------------------------------------------------------
Set-Reg "$POL\Windows\WindowsCopilot" 'TurnOffWindowsCopilot'  1 'DWord' 'Windows Copilot off'
Set-Reg "$POL\Windows\WindowsAI"      'DisableAIDataAnalysis'  1 'DWord' 'Recall (AI screen analysis) off'

# --- suggestions, spotlight, tips, auto-installed apps ---------------------------------------
$cc = "$POL\Windows\CloudContent"
Set-Reg $cc 'DisableWindowsConsumerFeatures'    1 'DWord' 'no auto-installed consumer apps/suggestions'
Set-Reg $cc 'DisableSoftLanding'                1 'DWord' 'no "tips about Windows" popups'
Set-Reg $cc 'DisableWindowsSpotlightFeatures'   1 'DWord' 'no Windows Spotlight content'
Set-Reg $cc 'DisableConsumerAccountStateContent' 1 'DWord' 'no account-state advertising content'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
        'ScoobeSystemSettingEnabled' 0 'DWord' 'no "finish setting up your device" nag'

# --- telemetry, advertising, feedback ---------------------------------------------------------
# Policy values only. On Pro/Enterprise AllowTelemetry=0 means Security; Home floors at Basic.
Set-Reg "$POL\Windows\DataCollection" 'AllowTelemetry'                0 'DWord' 'telemetry at the minimum the SKU allows'
Set-Reg "$POL\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1 'DWord' 'no feedback prompts'
Set-Reg "$POL\Windows\AdvertisingInfo" 'DisabledByGroupPolicy'         1 'DWord' 'advertising ID off'

# --- Xbox Game Bar / Game DVR -----------------------------------------------------------------
# Pure overhead on a GPU-less guest, and the Game Bar popup can appear over a fullscreen app.
Set-Reg "$POL\Windows\GameDVR" 'AllowGameDVR' 0 'DWord' 'Game Bar / Game DVR off'

# --- Store background downloads ---------------------------------------------------------------
# 2 = disabled. The guest has no network except during a dom0-driven update pass, so background
# app updates only generate failed connection attempts.
Set-Reg "$POL\WindowsStore" 'AutoDownload' 2 'DWord' 'Store auto app-updates off'

# --- per-user settings (no machine-wide equivalent) -------------------------------------------
# The File Explorer "sync provider notifications" ARE the OneDrive / Microsoft 365 adverts -
# "Back up your folders", "Finish setting up OneDrive" - and there is no HKLM policy for them:
# the value lives in each user hive. So write it to the invoking user, to every EXISTING profile
# (loaded hives in place, offline ones via reg load/unload), and to the DEFAULT profile so
# accounts created later inherit it. Same machinery disable-hw-accel.ps1 uses for the Office keys,
# and for the same reason: under qrexec this runs as SYSTEM, where a plain HKCU write lands in
# the wrong hive and silently does nothing.
$perUser = @(
    @{ sub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
       name = 'ShowSyncProviderNotifications'; val = 0; why = 'no OneDrive/365 adverts in File Explorer' },
    @{ sub = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
       name = 'SubscribedContent-338388Enabled'; val = 0; why = 'no suggested content on Start' },
    @{ sub = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
       name = 'SubscribedContent-338389Enabled'; val = 0; why = 'no tips/suggestions in Settings' },
    @{ sub = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
       name = 'SilentInstalledAppsEnabled';      val = 0; why = 'no silently installed suggested apps' }
)

function Set-PerUserValues([string]$HiveRoot, [string]$Label) {
    foreach ($e in $perUser) { Set-Reg "$HiveRoot\$($e.sub)" $e.name $e.val 'DWord' "${Label}: $($e.why)" }
}

Set-PerUserValues 'HKCU:' 'current user'

$profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
foreach ($prof in (Get-ChildItem $profileList -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -match '^S-1-5-21-' })) {
    $sid  = $prof.PSChildName
    $path = (Get-ItemProperty $prof.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        Set-PerUserValues "Registry::HKEY_USERS\$sid" "profile $sid (loaded)"
    } elseif ($path -and (Test-Path "$path\NTUSER.DAT")) {
        $mount = 'QWTNG_' + $sid.Substring($sid.Length - 6)
        & reg load "HKU\$mount" "$path\NTUSER.DAT" *> $null
        if ($LASTEXITCODE -eq 0) {
            Set-PerUserValues "Registry::HKEY_USERS\$mount" "profile $sid (offline)"
            [gc]::Collect()
            & reg unload "HKU\$mount" *> $null
        }
    }
}

if (Test-Path 'C:\Users\Default\NTUSER.DAT') {
    & reg load 'HKU\QWTNG_DEF' 'C:\Users\Default\NTUSER.DAT' *> $null
    if ($LASTEXITCODE -eq 0) {
        Set-PerUserValues 'Registry::HKEY_USERS\QWTNG_DEF' 'default profile'
        [gc]::Collect()
        & reg unload 'HKU\QWTNG_DEF' *> $null
    }
}

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed")
if ($script:failed -gt 0) { exit 1 }
