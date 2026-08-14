# Price a KB exactly: what the catalog would hand us, what the filter keeps, what it drops, in
# BYTES - via HEAD / one-byte ranged GET, so no payload is transferred. Detached and file-reported,
# like every other pass here.
param([Parameter(Mandatory=$true)][string]$Kb)
$ErrorActionPreference = 'Continue'
$bin   = 'C:\Program Files\Qubes Tools\bin'
$agent = Join-Path $bin 'qubes-windows-update.ps1'
$relay = Join-Path $bin 'qubes-updates-relay.exe'
$out   = "C:\ProgramData\Qubes\wu\price-$Kb.txt"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Remove-Item -LiteralPath $out -Force -EA SilentlyContinue

$worker = @"
& '$agent' -Action resolve -OnlyKb '$Kb' -RelayExe '$relay' *>&1 |
    ForEach-Object { Add-Content -LiteralPath '$out' -Value `$_ }
Add-Content -LiteralPath '$out' -Value 'DONE'
"@
$wp = "C:\ProgramData\Qubes\wu\price-$Kb-worker.ps1"
Set-Content -LiteralPath $wp -Value $worker -Encoding ASCII

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG diagnostic: price a KB from the catalog (no payload transfer)</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$wp"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'wu-price.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
& schtasks /create /tn QwtPriceKb /xml "$f" /f | Out-Null
& schtasks /run /tn QwtPriceKb | Out-Null
Write-Output ("=== RESULT ===`narmed (rc {0}); poll {1}" -f $LASTEXITCODE, $out)
