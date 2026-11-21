# tiny11sc strip.ps1 - run ONCE by SetupComplete.cmd, as SYSTEM, before OOBE and the first logon.
#
# The "serviceable core": tiny11 core removes about this much, but it also guts WinSxS and Windows
# Update, which is why core can neither update nor add anything back. This keeps both, and does
# every component removal through the servicing stack on the running OS, so:
#   (a) the dom0-driven updater works unchanged - WU agent, CBS/TrustedInstaller, DISM, the
#       component store, Task Scheduler, PowerShell/.NET are all left as Windows ships them;
#   (b) everything removed here is recorded in removed.json, and restore.ps1 adds it back from the
#       command line (capabilities and features from Windows Update or a -Source, apps from the
#       Store via winget, Defender by writing back the service start values recorded at build).
#
# Windows PowerShell 5.1 syntax only (no ternary, ??, && or ||): this runs on the guest's
# powershell.exe, never pwsh.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Root = Join-Path $env:WINDIR 'tiny11sc'
$LogFile = Join-Path $Root 'strip.log'
$Manifest = Join-Path $Root 'removed.json'
$StatusKey = 'HKLM:\SOFTWARE\tiny11sc'
$Version = 1
New-Item -ItemType Directory -Force -Path $Root | Out-Null

$script:Errors = 0
$script:Removed = New-Object System.Collections.ArrayList

function Log([string]$msg, [string]$level = 'INFO') {
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  Write-Output $line
  if ($level -eq 'ERROR') { $script:Errors++ }
}
function Record([string]$kind, [string]$name, [string]$detail) {
  [void]$script:Removed.Add([ordered]@{ kind = $kind; name = $name; detail = $detail })
  # Rewritten after every removal: a strip that dies half way still leaves an exact record of what
  # it took, which is what restore.ps1 reads.
  ConvertTo-Json -InputObject @($script:Removed) -Depth 4 | Set-Content -LiteralPath $Manifest -Encoding UTF8
}
function FreeGB { try { [math]::Round((Get-PSDrive -Name C).Free / 1GB, 2) } catch { -1 } }

# ---------------------------------------------------------------------------------------------
# WHAT GOES. Kept deliberately, with the reason, because each is load-bearing for us:
#   VBSCRIPT             - our Start-menu shortcut runs open-start-menu.vbs (guest/install-start-shortcut.ps1)
#   Notepad.System       - the harness opens notepad.exe (25 call sites); the Notepad APP goes
#   Language.Basic, DirectX.Configuration.Database, Ethernet.Client.* (NIC before PV drivers),
#   Microsoft.Edge.WebView (the inbox, CBS-serviced WebView OS components fall back to) - kept.
$CapabilityPatterns = @(
  'App.StepsRecorder~*', 'App.Support.QuickAssist~*', 'Browser.InternetExplorer~*', 'Hello.Face.*',
  'Language.Handwriting~*', 'Language.OCR~*', 'Language.Speech~*', 'Language.TextToSpeech~*',
  'MathRecognizer~*', 'Media.WindowsMediaPlayer~*', 'Microsoft.Wallpapers.Extended~*',
  'Microsoft.Windows.MSPaint~*', 'Microsoft.Windows.PowerShell.ISE~*', 'Microsoft.Windows.WordPad~*',
  'Microsoft.Windows.Wifi.Client.*', 'Microsoft.Windows.Sense.Client~*', 'OneCoreUAP.OneSync~*',
  'OpenSSH.Client~*', 'Print.Fax.Scan~*', 'Print.Management.Console~*', 'Windows.Kernel.LA57~*',
  'WMIC~*', 'XPS.Viewer~*'
)
# Disabled WITH payload removal: Enable-WindowsOptionalFeature brings them back from WU or -Source.
$FeatureNames = @(
  'Recall', 'WorkFolders-Client', 'Printing-XPSServices-Features', 'Windows-Defender-Default-Definitions',
  'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2'
)
# Provisioned apps: EVERYTHING goes except these. An allowlist, so an app a later build adds is
# removed too. Store + StorePurchaseApp + App Installer (winget) are the way apps come back;
# SecHealthUI is serviced by the cumulative update (version 1000.<build>) and stays with it.
$AppKeepPrefixes = @(
  'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller',
  'Microsoft.Winget.Source', 'Microsoft.SecHealthUI', 'Microsoft.ApplicationCompatibilityEnhancements',
  'Microsoft.VCLibs.', 'Microsoft.UI.Xaml.', 'Microsoft.NET.Native.', 'Microsoft.WindowsAppRuntime.',
  'Microsoft.Services.Store.Engagement'
)
function Test-KeepApp([string]$name) {
  foreach ($p in $AppKeepPrefixes) { if ($name.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

Log "tiny11sc strip v$Version start; C: free $(FreeGB) GB; $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
if (Test-Path -LiteralPath $Manifest) {
  # Re-running is harmless (each step only acts on what is still present), but the record of the
  # first run is what restore.ps1 needs - keep it.
  # Assigned first: 5.1's ConvertFrom-Json emits an array as one object (see restore.ps1 Get-Removed).
  try { $j = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json; foreach ($r in @($j)) { [void]$script:Removed.Add($r) } } catch { }
  Log "removed.json exists with $($script:Removed.Count) entries - this is a re-run; adding to it"
}

# ---- 1. provisioned apps ---------------------------------------------------------------------
try {
  $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
  Log "provisioned apps: $($prov.Count)"
  foreach ($p in $prov) {
    if (Test-KeepApp $p.DisplayName) { Log "  keep app $($p.DisplayName)"; continue }
    try {
      Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -ErrorAction Stop | Out-Null
      Record 'appx' $p.DisplayName $p.PackageName
      Log "  removed app $($p.DisplayName) ($($p.PackageName))"
    } catch { Log "  app $($p.DisplayName): $($_.Exception.Message)" 'ERROR' }
  }
  # Deprovisioning stops new accounts getting an app; the staged package is removed here too so
  # its files leave WindowsApps now rather than at some later maintenance run. Nobody has logged
  # on yet, so nothing is installed for a user.
  foreach ($a in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
    if ($a.IsFramework -or $a.SignatureKind -eq 'System' -or (Test-KeepApp $a.Name)) { continue }
    if (@($script:Removed | Where-Object { $_.kind -eq 'appx' -and $_.name -eq $a.Name }).Count -eq 0) { continue }
    try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop; Log "  removed staged $($a.PackageFullName)" }
    catch { Log "  staged $($a.PackageFullName): $($_.Exception.Message)" 'WARN' }
  }
} catch { Log "provisioned apps: $($_.Exception.Message)" 'ERROR' }

# ---- 2. capabilities (Features on Demand) ------------------------------------------------------
try {
  $caps = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.State -eq 'Installed' })
  Log "installed capabilities: $($caps.Count)"
  foreach ($pat in $CapabilityPatterns) {
    $hit = @($caps | Where-Object { $_.Name -like $pat })
    if ($hit.Count -eq 0) { Log "  capability pattern $pat matched nothing installed"; continue }
    foreach ($c in $hit) {
      try {
        $r = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop
        Record 'capability' $c.Name ''
        Log "  removed capability $($c.Name) (restart needed: $($r.RestartNeeded))"
      } catch { Log "  capability $($c.Name): $($_.Exception.Message)" 'ERROR' }
    }
  }
} catch { Log "capabilities: $($_.Exception.Message)" 'ERROR' }

# ---- 3. optional features --------------------------------------------------------------------
foreach ($f in $FeatureNames) {
  try {
    $st = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
    if (-not $st) { Log "  feature $f not present"; continue }
    if ($st.State -notmatch '^Enabled') { Log "  feature $f is $($st.State) - left alone"; continue }
    $r = Disable-WindowsOptionalFeature -Online -FeatureName $f -Remove -NoRestart -ErrorAction Stop
    Record 'feature' $f ''
    Log "  disabled feature $f with payload removed (restart needed: $($r.RestartNeeded))"
  } catch { Log "  feature ${f}: $($_.Exception.Message)" 'WARN' }
}

# ---- 4. Defender's scheduled tasks (its services were disabled in the image before first boot) --
try {
  foreach ($t in @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction Stop)) {
    try { Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; Record 'task' ($t.TaskPath + $t.TaskName) ''; Log "  disabled task $($t.TaskPath)$($t.TaskName)" }
    catch { Log "  task $($t.TaskName): $($_.Exception.Message)" 'WARN' }
  }
} catch { Log "Defender tasks: $($_.Exception.Message)" 'WARN' }

# ---- 5. no hibernation file, no recovery environment (Winre.wim is not in the image) ------------
& powercfg.exe /hibernate off 2>&1 | ForEach-Object { Log "  powercfg: $_" }
& reagentc.exe /disable 2>&1 | ForEach-Object { Log "  reagentc: $_" }

# ---- 6. drop the payload the removals left in WinSxS --------------------------------------------
# /ResetBase makes installed updates permanent; there are none yet. Payload of a removal that
# needs a restart is dropped by the next cleanup - Windows' own StartComponentCleanup task, or
# `restore.ps1 -Cleanup` before a golden is sealed.
Log "component cleanup start; C: free $(FreeGB) GB"
& dism.exe /Online /English /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*\[' } | ForEach-Object { Log "  dism: $_" }
if ($LASTEXITCODE -ne 0) { Log "component cleanup exit $LASTEXITCODE" 'WARN' }

$result = 'ok'
if ($script:Errors -gt 0) { $result = 'partial' }
New-Item -Path $StatusKey -Force | Out-Null
Set-ItemProperty -Path $StatusKey -Name StripVersion -Value $Version -Type DWord
Set-ItemProperty -Path $StatusKey -Name StripResult -Value $result
Set-ItemProperty -Path $StatusKey -Name StripErrors -Value $script:Errors -Type DWord
Set-ItemProperty -Path $StatusKey -Name StripRemoved -Value $script:Removed.Count -Type DWord
Set-ItemProperty -Path $StatusKey -Name StripFinished -Value (Get-Date -Format 's')
Log "tiny11sc strip done: $result, $($script:Removed.Count) removed, $($script:Errors) errors; C: free $(FreeGB) GB"
if ($script:Errors -gt 0) { exit 1 }
exit 0
