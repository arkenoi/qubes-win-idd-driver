# Pre-attach instrumentation for the fair two-boot netvm test (run in-guest via
# qtest pushrun BEFORE attaching the netvm). While the guest is starved qrexec is dead,
# so a SYSTEM scheduled task (at startup + every 2 min) appends netforensics output to
# C:\netforensics-boot.log; collect the file on a later healthy boot.
#   -Remove  : unregister the task and leave logs in place.
param([switch]$Remove)
$ErrorActionPreference = 'Continue'
$task = 'QubesNetForensics'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "RESULT=REMOVED"
    exit 0
}

# stage the collector next to the log (QubesIncoming gets wiped by pushes)
$src = Join-Path $PSScriptRoot 'netforensics.ps1'
if (-not (Test-Path $src)) { Write-Output "RESULT=ERROR no netforensics.ps1 beside this script"; exit 1 }
Copy-Item $src 'C:\netforensics.ps1' -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `
    '-NoProfile -ExecutionPolicy Bypass -Command "& C:\netforensics.ps1 2>&1 | Out-File -Append -Encoding utf8 C:\netforensics-boot.log"'
$trig = New-ScheduledTaskTrigger -AtStartup
$rep  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 7)
$trig.Repetition = $rep.Repetition
$prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trig,$rep -Principal $prin -Force | Out-Null

# prove it runs at all before we go blind
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 8
if (Test-Path 'C:\netforensics-boot.log') {
    $n = (Get-Content 'C:\netforensics-boot.log' | Select-String 'NETFORENSICS').Count
    Write-Output "RESULT=OK samples=$n"
} else {
    Write-Output "RESULT=ERROR task registered but no log produced"
}
