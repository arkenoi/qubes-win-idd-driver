<#
.SYNOPSIS
  End-to-end: run the REAL rpc handler under a German culture and check what dom0 would receive.

.DESCRIPTION
  Every locale check so far tested a primitive in isolation. This drives the shipped
  wu-update.ps1 itself - the agent->status-file->handler->stderr chain that dom0 actually consumes -
  with CurrentCulture forced to de-DE, and asserts the progress lines are parseable by Python's
  float().

  Made safe deliberately:
    * a DUMMY scheduled task stands in for the updater, so no update is started;
    * the synthetic status file carries reboot_needed=false and an empty result, and the handler
      only calls shutdown.exe when reboot_needed is true (verified in the source), so this cannot
      reboot the guest;
    * everything is written to TEMP and the real update-status.json is backed up and restored.

  The control matters as much as the result: the same run also formats the OLD culture-bound way,
  which must produce a comma under de-DE. If it does not, the culture was not actually applied and
  the test proves nothing.
#>
param([string]$Culture = 'de-DE')
$ErrorActionPreference = 'Continue'
$handler = 'C:\Program Files\Qubes Tools\qubes-rpc-services\wu-update.ps1'
$status  = 'C:\ProgramData\Qubes\update-status.json'
$backup  = "$status.locale-e2e-backup"
$task    = 'QwtLocaleE2EDummy'
$errFile = Join-Path $env:TEMP 'wu-handler-e2e.err'
Write-Output '=== RESULT ==='
if (-not (Test-Path $handler)) { Write-Output "handler not deployed at $handler"; exit 1 }

# A stand-in for the updater task: stays Running long enough for the handler to poll, does nothing.
$dummy = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG test stand-in - does nothing, just occupies a Running state</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT5M</ExecutionTimeLimit><AllowHardTerminate>true</AllowHardTerminate></Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -Command "Start-Sleep -Seconds 25"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'qwt-locale-dummy.xml'
[IO.File]::WriteAllText($f, $dummy, [Text.Encoding]::Unicode)
& schtasks /create /tn $task /xml "$f" /f | Out-Null

if (Test-Path $status) { Copy-Item $status $backup -Force }

function Write-Status($phase) {
    $st = [ordered]@{
        action='full'; phase=$phase; ts=(Get-Date).ToString('s'); count=1
        available=@(@{ kb='KB5121003'; title='2026-08 Cumulative Update'; size_mb=4867.4; downloaded=$false })
        downloading=$(if ($phase -eq 'download') { [ordered]@{ kb='KB5121003'; file='x.msu'; mb=2000.5; total_mb=4867.4; pct=42.5 } } else { $null })
        installing=$null; result=@(); reboot_needed=$false; error=$null
    }
    ($st | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $status -Encoding UTF8
}
Write-Status 'download'

# Flip the status to 'done' shortly after the handler starts, so it terminates on its own.
$flip = Start-Job -ScriptBlock {
    param($status)
    Start-Sleep -Seconds 9
    $st = [ordered]@{ action='full'; phase='done'; ts=(Get-Date).ToString('s'); count=1
        available=@(); downloading=$null; installing=$null; result=@(); reboot_needed=$false; error=$null }
    ($st | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $status -Encoding UTF8
} -ArgumentList $status

# Run the REAL handler in its OWN process with stderr redirected to a file.
#
# `& $handler 2>&1` does NOT work here, and the reason is the point of the exercise: the handler
# writes progress with [Console]::Error.WriteLine(), which goes straight to the process's stderr
# HANDLE and bypasses PowerShell's redirection operators entirely - the lines appeared on the
# console and the harness captured nothing. dom0 reads that same handle, so capturing it at the
# process level is also the only faithful simulation of what dom0 sees.
$wrapper = Join-Path $env:TEMP 'wu-locale-e2e-wrapper.ps1'
@"
[Threading.Thread]::CurrentThread.CurrentCulture   = [Globalization.CultureInfo]::GetCultureInfo('$Culture')
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('$Culture')
& '$handler' -Task '$task'
"@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
$control = "{0:0.0}" -f 35.5     # the OLD way, in this culture - the test's own control
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

Remove-Item -LiteralPath $errFile -Force -EA SilentlyContinue
& cmd.exe /c "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" 2> `"$errFile`"" | Out-Null
$lines = @(Get-Content -LiteralPath $errFile -EA SilentlyContinue)

Receive-Job $flip -ErrorAction SilentlyContinue | Out-Null; Remove-Job $flip -Force -EA SilentlyContinue
& schtasks /end    /tn $task | Out-Null
& schtasks /delete /tn $task /f | Out-Null
if (Test-Path $backup) { Move-Item $backup $status -Force } else { Remove-Item $status -Force -EA SilentlyContinue }

Write-Output ("culture              = {0}" -f $Culture)
Write-Output ("control old-style    = '{0}'  (must contain a comma, or the culture never applied)" -f $control)
Write-Output '--- what the handler wrote (this is what dom0 parses) ---'
foreach ($l in $lines) { Write-Output ("    " + $l) }

# dom0 does float(line). A comma-formatted number is the failure this test exists for.
$numeric = @($lines | Where-Object { $_ -match '^\s*\d+([.,]\d+)?\s*$' })
$commas  = @($numeric | Where-Object { $_ -match ',' })
Write-Output ("numeric progress lines = {0}, of which comma-formatted = {1}" -f $numeric.Count, $commas.Count)
if ($control -notmatch ',') { Write-Output 'INCONCLUSIVE: culture not applied - test proves nothing'; exit 2 }
if ($numeric.Count -eq 0)   { Write-Output 'INCONCLUSIVE: handler emitted no progress lines'; exit 2 }
if ($commas.Count -gt 0)    { Write-Output 'FAIL: dom0 would receive comma-formatted progress and could not parse it'; exit 1 }
Write-Output 'PASS: every progress line is float()-parseable under a German culture'
