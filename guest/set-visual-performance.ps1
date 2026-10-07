# Strip the COSTLY visual effects while leaving the THEME intact.
#
# WHY: on a Qubes Windows guest there is no GPU - the desktop is on the Basic Display Adapter and
# every Win11 XAML/Mica/acrylic surface is composited in software. Measured on win11 2026-09-24, a
# right-click context menu takes ~560-580 ms to appear ON THE GUEST, with the gui-agent stopped -
# so it is the guest's own composition cost, not the agent's (agent off 560 ms mean vs agent on
# 582 ms). Animations and blur-behind are the obvious candidates for that cost.
# Owner, 2026-09-24: "snappy desktop is better than animations that could never be smooth" and
# "visual effects no one notices"; then "i need the theme to be correct but stripped of costly
# visual effects."
#
# MEASURED OUTCOME, 2026-09-24: NO PERCEPTIBLE WIN. Applied on win11-acc, the owner's verdict was
# "so it is wrong, but still not noticeably faster". The guest's ~560-580 ms context-menu cost did
# not visibly improve with animations and transparency disabled, so this script is kept as an
# explicit opt-in and is NOT applied by default. Do not reach for it expecting a speedup.
#
# WHAT NOT TO TOUCH, AND WHY THIS SCRIPT EXISTS AT ALL.
# The obvious lever - VisualFXSetting = 2, "Adjust for best performance" - ALSO disables "use
# visual styles on windows and buttons". Setting it mid-session left Explorer's command bar
# rendering in the DARK variant inside a LIGHT window (owner: "looks like a piece of dark theme",
# confirmed on a screen capture). So this script deliberately leaves VisualFXSetting on the
# appearance profile and disables only the individual effects that cost composition time.
#
# Run as the LOGGED-ON USER (these are all HKCU / per-user SPI settings), e.g. via
# guest/run-as-user.ps1. Restart Explorer afterwards (-RestartExplorer) so every XAML island
# re-reads theme and transparency together, rather than half of them picking up the change later.
[CmdletBinding()]
param(
    [ValidateSet('Performance','Default')] [string]$Mode = 'Performance',
    [switch]$RestartExplorer
)
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;using System.Runtime.InteropServices;
public class VfxSpi {
  [DllImport("user32.dll",SetLastError=true)]
  public static extern bool SystemParametersInfo(uint action,uint uiParam,IntPtr pvParam,uint winIni);
}
"@

$perf = ($Mode -eq 'Performance')
$on   = if ($perf) { 0 } else { 1 }   # 0 = effect OFF in Performance mode

# SPIF_UPDATEINIFILE | SPIF_SENDCHANGE so the setting persists AND running apps are told.
$SPIF = 3
$spis = @{
    0x1043 = 'CLIENTAREAANIMATION'  # XAML/WinUI animations - the master switch modern shell honours
    0x1003 = 'MENUANIMATION'
    0x1013 = 'MENUFADE'
    0x1015 = 'SELECTIONFADE'
    0x1019 = 'TOOLTIPANIMATION'
    0x1005 = 'COMBOBOXANIMATION'
    0x1009 = 'LISTBOXSMOOTHSCROLLING'
}
foreach ($k in $spis.Keys) {
    [void][VfxSpi]::SystemParametersInfo([uint32]$k, 0, [IntPtr]$on, [uint32]$SPIF)
}

# Blur-behind / acrylic / Mica. This is the expensive one without a GPU.
# NEVER `New-Item -Force` an EXISTING registry key. On the registry provider that DELETES AND
# RECREATES the key, wiping every value in it. An earlier version of this did exactly that and
# destroyed AppsUseLightTheme/SystemUsesLightTheme, which left Explorer's command bar rendering
# dark inside a light window (owner, 2026-09-24: "not just background. looks like a piece of dark
# theme"). Create it only when it is genuinely absent.
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
if (-not (Test-Path $personalize)) { New-Item -Path $personalize | Out-Null }
Set-ItemProperty -Path $personalize -Name EnableTransparency -Value $on -Type DWord

# Window minimise/maximise animation.
Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -Value "$on" -Type String

# DELIBERATELY NOT SET: VisualFXSetting. See the header - the "best performance" profile turns off
# visual styles and breaks theme consistency, which is the one thing the owner asked to preserve.
# If a previous run left it on the performance profile, put it back on the appearance profile.
$vfx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
if (Test-Path $vfx) {
    $cur = (Get-ItemProperty -Path $vfx -Name VisualFXSetting -ErrorAction SilentlyContinue).VisualFXSetting
    if ($cur -eq 2) { Set-ItemProperty -Path $vfx -Name VisualFXSetting -Value 1 -Type DWord }
}

"VISUALPERF mode=$Mode transparency=$on animations=$on visualstyles=preserved"

if ($RestartExplorer) {
    # THE SHELL IS WINDOWS' TO RELAUNCH (Winlogon AutoRestartShell), NOT THIS SCRIPT'S. The shell
    # instance is identified by the taskbar window it owns (Shell_TrayWnd -> owning pid), never by
    # name: `Stop-Process -Name explorer` ended every explorer, whoever started it, and then raced
    # Winlogon's relaunch with its own Start-Process (owner 2026-10-07). That one instance is ended
    # by its pid and the script then only WAITS for Winlogon's new instance; with AutoRestartShell=0
    # there is no relauncher, so nothing is ended and the settings take effect at the next logon.
    Add-Type -Namespace VP -Name U -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string w); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);'
    $ars = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoRestartShell -ErrorAction SilentlyContinue).AutoRestartShell
    $shellPid = [uint32]0
    $tray = [VP.U]::FindWindowW('Shell_TrayWnd', [NullString]::Value)   # [NullString]: a PowerShell $null marshals as "" (memory: powershell-null-string-pinvoke)
    if ($tray -ne [IntPtr]::Zero) { [void][VP.U]::GetWindowThreadProcessId($tray, [ref]$shellPid) }
    if ($ars -ne 1) { "VISUALPERF explorer NOT restarted: AutoRestartShell=$ars means no relauncher - the shell re-reads the theme at the next logon" }
    elseif ($shellPid -eq 0) { 'VISUALPERF explorer NOT restarted: no Shell_TrayWnd owner found (no shell in this session?)' }
    else {
        Stop-Process -Id $shellPid -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(30); $newPid = [uint32]0
        do {
            Start-Sleep -Milliseconds 500
            $t2 = [VP.U]::FindWindowW('Shell_TrayWnd', [NullString]::Value)
            if ($t2 -ne [IntPtr]::Zero) { [void][VP.U]::GetWindowThreadProcessId($t2, [ref]$newPid) }
        } while (($newPid -eq 0 -or $newPid -eq $shellPid) -and (Get-Date) -lt $deadline)
        if ($newPid -ne 0 -and $newPid -ne $shellPid) { "VISUALPERF explorer restarted by Winlogon (pid $shellPid -> $newPid) - theme and transparency re-read together" }
        else { "VISUALPERF explorer ended (pid $shellPid) but Winlogon's new instance was not seen within 30 s - NOT started by this script" }
    }
}
