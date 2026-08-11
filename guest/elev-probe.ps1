# Elevation probe: try Register-ScheduledTask with -RunLevel Highest (CIM path, distinct
# from schtasks.exe), report outcome. If it works, run whoami /groups elevated as proof.
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}
try {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command "whoami /groups | Out-File C:\Windows\Temp\elevprobe.txt; (Get-Date).ToString() | Add-Content C:\Windows\Temp\elevprobe.txt"'
    $p = New-ScheduledTaskPrincipal -UserId 'user' -RunLevel Highest -LogonType Interactive
    $t = New-ScheduledTask -Action $a -Principal $p
    Register-ScheduledTask -TaskName 'QwtElevProbe' -InputObject $t -Force -ErrorAction Stop | Out-Null
    $r.register = 'ok'
    Start-ScheduledTask -TaskName 'QwtElevProbe'
    Start-Sleep -Seconds 5
    $r.output = (Get-Content 'C:\Windows\Temp\elevprobe.txt' -ErrorAction SilentlyContinue | Select-String 'Mandatory Label' | ForEach-Object { $_.Line })
    Unregister-ScheduledTask -TaskName 'QwtElevProbe' -Confirm:$false -ErrorAction SilentlyContinue
} catch {
    $r.register = "FAIL: $($_.Exception.Message)"
}
Write-Output '=== RESULT ==='
$r | ConvertTo-Json
