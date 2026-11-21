<#
.SYNOPSIS
  tiny11sc restore - add back, from the command line, anything strip.ps1 removed.

.DESCRIPTION
  Run from an ELEVATED PowerShell (apps via winget need a signed-in user's elevated shell, not
  SYSTEM). C:\Windows\tiny11sc\tiny11sc.cmd forwards here.

    tiny11sc -List                         what was removed, and its state now
    tiny11sc -Name Language.OCR*           re-add every removed item matching the wildcard
    tiny11sc -Name *Calculator*            an app: installed from the Store with winget
    tiny11sc -Name * -Source D:\fod -LimitAccess   capabilities/features from a local source only
    tiny11sc -Component Defender           Defender's services, tasks, definitions, Windows Security tray
    tiny11sc -Component Edge|WebView2|OneDrive|Telemetry
    tiny11sc -StoreId 9WZDNCRFHVN5         any Store app by product id
    tiny11sc -Winget Mozilla.Firefox       any winget package (winget source), e.g. a browser now Edge is gone
    tiny11sc -Cleanup                      drop superseded payload (run once before sealing a golden)

  NETWORK. Capabilities, features and Store apps are fetched from Microsoft. A qube with a netvm
  has that; a template has no netvm - run this in a qube made from it, give it a netvm for the
  duration, or point -Source at a mounted "Languages and Optional Features" ISO / a WIM:...:N
  source. The updater's relay is not used: it serves only update passes (ADR-updater section 5).

  Windows PowerShell 5.1 syntax only.
#>
[CmdletBinding()]
param(
  [switch]$List,
  [string]$Name,
  [ValidateSet('Defender', 'Edge', 'WebView2', 'OneDrive', 'Telemetry')][string]$Component,
  [string]$StoreId,
  [string]$Winget,
  [string]$Source,
  [switch]$LimitAccess,
  [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Join-Path $env:WINDIR 'tiny11sc'
$Manifest = Join-Path $Root 'removed.json'
$ServicesOrig = Join-Path $Root 'services.orig'
$script:Failed = 0
$script:Reboot = $false

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'tiny11sc: run this from an elevated (Administrator) PowerShell.'; exit 2
}

# Store product ids for the apps strip.ps1 removes. Only ids that resolve to that app; an app not
# listed here gets a `winget search` hint instead of a guess.
$StoreIds = @{
  'Microsoft.WindowsCalculator' = '9WZDNCRFHVN5'; 'Microsoft.WindowsNotepad' = '9MSMLRH6LZF3'
  'Microsoft.Paint' = '9PCFS5B6T72H'; 'Microsoft.Windows.Photos' = '9WZDNCRFJBH4'
  'Microsoft.ScreenSketch' = '9MZ95KL8MR0L'; 'Microsoft.WindowsTerminal' = '9N0DX20HK701'
  'Microsoft.WindowsCamera' = '9WZDNCRFJBBG'; 'Microsoft.WindowsSoundRecorder' = '9WZDNCRFHWKN'
  'Microsoft.WindowsAlarms' = '9WZDNCRFJ3PR'; 'Microsoft.ZuneMusic' = '9WZDNCRFJ3PT'
  'Microsoft.MicrosoftStickyNotes' = '9NBLGGH4QGHW'; 'Microsoft.YourPhone' = '9NMPJ99VJBWV'
  'Microsoft.Todos' = '9NBLGGH5R558'; 'Microsoft.BingWeather' = '9WZDNCRFJ3Q2'
  'Microsoft.WindowsFeedbackHub' = '9NBLGGH4R32N'; 'MicrosoftCorporationII.QuickAssist' = '9P7BP5VNWKX5'
  'Microsoft.HEIFImageExtension' = '9PMMSR1CGPWG'; 'Microsoft.VP9VideoExtensions' = '9N4D0MSMP0PT'
  'Microsoft.WebpImageExtension' = '9PG2DK419DRG'; 'Microsoft.RawImageExtension' = '9NCTDW2W1BH8'
  'Microsoft.AV1VideoExtension' = '9MVZQVXJBQ9V'; 'Microsoft.WebMediaExtensions' = '9N5TDP8VCMHS'
  'Clipchamp.Clipchamp' = '9P1J8S7CCWWT'; 'Microsoft.MicrosoftSolitaireCollection' = '9WZDNCRFHWD2'
  'Microsoft.OutlookForWindows' = '9NRX63209R7B'; 'Microsoft.GamingApp' = '9MV0B5HZVK9Z'
}

function Say([string]$m) { Write-Host "tiny11sc: $m" }
function Fail([string]$m) { Write-Host "tiny11sc: FAILED: $m"; $script:Failed++ }

function Get-Removed {
  if (-not (Test-Path -LiteralPath $Manifest)) { return @() }
  # Assigned first: in 5.1 ConvertFrom-Json emits a JSON array as ONE object, and @( pipeline )
  # would wrap it - .Count 1, a single "item" that is the whole list.
  $j = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
  return @($j)
}

function Get-Winget {
  $c = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  # On a fresh install the `winget` alias appears only once App Installer is registered for this
  # user, which Windows otherwise leaves to the Store's first update - and a template has no network
  # for that. Registering the provisioned package by family name is what the Store would do.
  try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { Say 'registered App Installer for this user'; return $c.Source }
  } catch { Say "App Installer registration: $($_.Exception.Message)" }
  $d = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
       Sort-Object Name -Descending | Select-Object -First 1
  if ($d -and (Test-Path -LiteralPath (Join-Path $d.FullName 'winget.exe'))) { return (Join-Path $d.FullName 'winget.exe') }
  return $null
}

function Invoke-Winget([string[]]$wargs) {
  $w = Get-Winget
  if (-not $w) { Fail 'winget (App Installer) not found - it is kept in this image; sign in as a user and retry from that session'; return }
  Say ("winget " + ($wargs -join ' '))
  & $w @wargs --accept-package-agreements --accept-source-agreements --disable-interactivity
  if ($LASTEXITCODE -ne 0) { Fail "winget exit $LASTEXITCODE" }
}

function Add-Source([hashtable]$p) {
  if ($Source) { $p['Source'] = $Source }
  if ($LimitAccess) { $p['LimitAccess'] = $true }
  return $p
}

function Restore-Item($r) {
  switch ($r.kind) {
    'capability' {
      Say "capability $($r.name)"
      $p = Add-Source @{ Online = $true; Name = $r.name }
      try { $x = Add-WindowsCapability @p; if ($x.RestartNeeded) { $script:Reboot = $true } }
      catch { Fail "$($r.name): $($_.Exception.Message)" }
    }
    'feature' {
      Say "feature $($r.name)"
      $p = Add-Source @{ Online = $true; FeatureName = $r.name; All = $true; NoRestart = $true }
      try { $x = Enable-WindowsOptionalFeature @p; if ($x.RestartNeeded) { $script:Reboot = $true } }
      catch { Fail "$($r.name): $($_.Exception.Message)" }
    }
    'appx' {
      $sid = $StoreIds[$r.name]
      if ($sid) { Invoke-Winget @('install', '--id', $sid, '--source', 'msstore', '--exact') }
      else { Say "app $($r.name): no Store id on file - find it with:  winget search --source msstore `"$($r.name -replace '^.*\.','')`"  then  tiny11sc -StoreId <id>" }
    }
    'task' {
      Say "task $($r.name)"
      $i = $r.name.LastIndexOf('\')
      try { Enable-ScheduledTask -TaskPath $r.name.Substring(0, $i + 1) -TaskName $r.name.Substring($i + 1) | Out-Null }
      catch { Fail "$($r.name): $($_.Exception.Message)" }
    }
    default { Say "unknown kind '$($r.kind)' for $($r.name) - skipped" }
  }
}

# Write a service Start value. Defender's service keys may refuse even an elevated administrator;
# then the same write runs once as TrustedInstaller through a one-shot scheduled task.
function Set-ServiceStart([string]$svc, [int]$start) {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (-not (Test-Path -LiteralPath $key)) { Say "service $svc does not exist - skipped"; return }
  try { Set-ItemProperty -LiteralPath $key -Name Start -Value $start -Type DWord; Say "service $svc Start=$start"; return }
  catch { Say "service ${svc}: direct write refused ($($_.Exception.Message)) - retrying as TrustedInstaller" }
  $tn = "tiny11sc-svc-$svc"
  $cmd = "add `"HKLM\SYSTEM\CurrentControlSet\Services\$svc`" /v Start /t REG_DWORD /d $start /f"
  try {
    Start-Service TrustedInstaller -ErrorAction SilentlyContinue
    $act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\reg.exe" -Argument $cmd
    Register-ScheduledTask -TaskName $tn -Action $act -User 'NT SERVICE\TrustedInstaller' -Force | Out-Null
    Start-ScheduledTask -TaskName $tn
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 500; if ((Get-ScheduledTask -TaskName $tn).State -ne 'Running') { break } }
    Unregister-ScheduledTask -TaskName $tn -Confirm:$false
  } catch { Fail "service ${svc} as TrustedInstaller: $($_.Exception.Message)"; return }
  $now = (Get-ItemProperty -LiteralPath $key -Name Start).Start
  if ($now -eq $start) { Say "service $svc Start=$start (as TrustedInstaller)" } else { Fail "service ${svc}: Start is still $now" }
}

function Restore-Services([string]$group) {
  if (-not (Test-Path -LiteralPath $ServicesOrig)) { Fail "$ServicesOrig missing - the build did not record the original start values"; return }
  foreach ($line in Get-Content -LiteralPath $ServicesOrig) {
    $f = $line.Trim() -split '\s+'
    if ($f.Count -ne 3 -or $f[0] -ne $group) { continue }
    Set-ServiceStart $f[1] ([int]$f[2])
  }
  $script:Reboot = $true
}

function Restore-Component([string]$c) {
  switch ($c) {
    'Defender' {
      Restore-Services 'defender'
      foreach ($r in @(Get-Removed | Where-Object { $_.kind -eq 'task' -and $_.name -like '\Microsoft\Windows\Windows Defender\*' })) { Restore-Item $r }
      foreach ($r in @(Get-Removed | Where-Object { $_.kind -eq 'feature' -and $_.name -eq 'Windows-Defender-Default-Definitions' })) { Restore-Item $r }
      Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue
      Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction SilentlyContinue
      Remove-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' -Recurse -ErrorAction SilentlyContinue
      New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name SecurityHealth -PropertyType ExpandString -Value '%windir%\system32\SecurityHealthSystray.exe' -Force | Out-Null
      Say 'Defender restored as far as Windows allows; it starts after a restart. Smart App Control stays OFF:'
      Say 'Windows can turn it back on only with a reinstall.'
    }
    'Telemetry' { Restore-Services 'telemetry'; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowTelemetry -ErrorAction SilentlyContinue }
    'Edge'      { Invoke-Winget @('install', '--id', 'Microsoft.Edge', '--source', 'winget', '--exact') }
    'WebView2'  { Invoke-Winget @('install', '--id', 'Microsoft.EdgeWebView2Runtime', '--source', 'winget', '--exact') }
    'OneDrive'  {
      $s = Join-Path $env:WINDIR 'System32\OneDriveSetup.exe'
      if (Test-Path -LiteralPath $s) { Say "running $s for this user"; Start-Process -FilePath $s -Wait } else { Invoke-Winget @('install', '--id', 'Microsoft.OneDrive', '--source', 'winget', '--exact') }
    }
  }
}

if ($List) {
  $caps = @{}; try { foreach ($c in Get-WindowsCapability -Online) { $caps[$c.Name] = [string]$c.State } } catch { }
  foreach ($r in Get-Removed) {
    $now = ''
    switch ($r.kind) {
      'capability' { $now = $caps[$r.name] }
      'feature'    { try { $now = [string](Get-WindowsOptionalFeature -Online -FeatureName $r.name).State } catch { } }
      'appx'       { if (Get-AppxPackage -AllUsers -Name $r.name -ErrorAction SilentlyContinue) { $now = 'Installed' } else { $now = 'absent' } }
      'task'       { $i = $r.name.LastIndexOf('\'); try { $now = [string](Get-ScheduledTask -TaskPath $r.name.Substring(0, $i + 1) -TaskName $r.name.Substring($i + 1)).State } catch { } }
    }
    '{0,-11} {1,-60} {2}' -f $r.kind, $r.name, $now
  }
  'components (tiny11sc -Component <name>): Defender, Edge, WebView2, OneDrive, Telemetry'
  exit 0
}

$did = $false
if ($Name) {
  $hits = @(Get-Removed | Where-Object { $_.name -like $Name })
  if ($hits.Count -eq 0) { Say "nothing removed matches '$Name' (tiny11sc -List shows what was)"; exit 1 }
  foreach ($r in $hits) { Restore-Item $r }
  $did = $true
}
if ($Component) { Restore-Component $Component; $did = $true }
if ($StoreId) { Invoke-Winget @('install', '--id', $StoreId, '--source', 'msstore', '--exact'); $did = $true }
if ($Winget) { Invoke-Winget @('install', '--id', $Winget, '--source', 'winget', '--exact'); $did = $true }
if ($Cleanup) {
  & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
  if ($LASTEXITCODE -ne 0) { Fail "component cleanup exit $LASTEXITCODE" }
  $did = $true
}
if (-not $did) { Get-Help $PSCommandPath -Detailed; exit 2 }
if ($script:Reboot) { Say 'a restart completes this.' }
if ($script:Failed -gt 0) { Say "$($script:Failed) step(s) failed."; exit 1 }
exit 0
