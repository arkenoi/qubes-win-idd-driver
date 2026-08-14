# Apply the consumer-nag silencer exactly the way the packaged installer now does it:
# run it once, keep a persistent copy, and register the boot guard that re-asserts it.
# Mirrors the block in packaging/setup/Install-QwtImproved.ps1 so this test validates THAT code
# path rather than a bespoke one.
param([string]$SetupRoot = $PSScriptRoot)
$ErrorActionPreference = 'Continue'
$bin = 'C:\Program Files\Qubes Tools\bin'
$src = Join-Path $SetupRoot 'quiet-desktop.ps1'
Write-Output '=== RESULT ==='
if (-not (Test-Path $src)) { Write-Output "quiet-desktop.ps1 not found at $src"; exit 1 }

foreach ($l in @(& $src 2>&1)) { if ($l -match '^(SET|WARN|===)') { Write-Output $l } }

New-Item -ItemType Directory -Force $bin | Out-Null
$qBin = Join-Path $bin 'quiet-desktop.ps1'
Copy-Item -LiteralPath $src -Destination $qBin -Force
Write-Output "persisted -> $qBin"

$qXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: re-assert the consumer-nag policies at boot (feature updates and new user profiles undo them)</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$qBin"</Arguments></Exec></Actions>
</Task>
"@
$qf = Join-Path $env:TEMP 'qubes-quiet-desktop.xml'
[IO.File]::WriteAllText($qf, $qXml, [Text.Encoding]::Unicode)
$qr = & schtasks /create /tn QubesQuietDesktopGuard /xml "$qf" /f 2>&1
Write-Output ("boot guard rc=$LASTEXITCODE : " + ($qr -join ' '))
