<#
.SYNOPSIS
  Deploy the QWT-NG Windows Update agent and register its scheduled scan (north-star: report
  update availability to dom0, non-blocking).

.DESCRIPTION
  Idempotent. Run elevated by the QWT installer (writes to Program Files) or standalone for test
  with -BinDir to a writable dir. Three steps:
    1. compile the relay from qubes-updates-relay.cs with the in-box csc (no build infra, matching
       the winenum.cs convention) -> <BinDir>\qubes-updates-relay.exe
    2. place qubes-windows-update.ps1 -> <BinDir>
    3. register scheduled task QubesWindowsUpdateScan (SYSTEM; at boot + every -Interval) that runs
       `-Action scan` only. Scan REPORTS availability; download/install stay on-demand so the task
       never blocks or reboots the guest on its own.

.PARAMETER SetupRoot  Dir holding qubes-updates-relay.cs and qubes-windows-update.ps1 (default: this script's dir).
.PARAMETER BinDir     Install dir for the exe + agent script.
.PARAMETER Interval   Scan cadence as an ISO-8601 duration (default PT6H).
#>
[CmdletBinding()]
param(
  [string]$SetupRoot = $PSScriptRoot,
  [string]$BinDir    = 'C:\Program Files\Qubes Tools\bin',
  [string]$Interval  = 'PT6H'
)
$ErrorActionPreference = 'Stop'
function Log($m){ Write-Output ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) }

New-Item -ItemType Directory -Force $BinDir | Out-Null

# 1. compile the relay with the in-box csc
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$src = Join-Path $SetupRoot 'qubes-updates-relay.cs'
$exe = Join-Path $BinDir 'qubes-updates-relay.exe'
if (-not (Test-Path $csc)) { throw "in-box csc not found at $csc" }
if (-not (Test-Path $src)) { throw "relay source not found at $src" }
& $csc /nologo /optimize /target:exe /out:"$exe" "$src" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "relay compile failed (csc rc=$LASTEXITCODE)" }
Log "compiled relay -> $exe"

# 2. place the agent script
$agent = Join-Path $BinDir 'qubes-windows-update.ps1'
Copy-Item (Join-Path $SetupRoot 'qubes-windows-update.ps1') $agent -Force
Log "placed agent -> $agent"

# 3. register the scheduled scan task. Past StartBoundary is fine - the repetition schedules the
#    next occurrence. Runs as SYSTEM/HighestAvailable so it works with no user logged on.
$cmd  = 'powershell.exe'
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$agent`" -Action scan -RelayExe `"$exe`""
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: scan Windows Update over the Qubes proxy and report availability to dom0</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></BootTrigger>
    <TimeTrigger><Enabled>true</Enabled><StartBoundary>2026-01-01T03:00:00</StartBoundary><Repetition><Interval>$Interval</Interval></Repetition></TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT20M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>$cmd</Command><Arguments>$args</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'qubes-wu-scan.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateScan /xml "$f" /f 2>&1
Log ("REGISTER QubesWindowsUpdateScan rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register failed (rc=$LASTEXITCODE)" }
Log 'updater agent deployed'
