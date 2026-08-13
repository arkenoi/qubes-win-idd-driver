# Find QWT's qrexec-agent log and show what dom0 asked for during the update window.
$ErrorActionPreference = 'Continue'
$dirs = @('C:\Program Files\Qubes Tools\log', 'C:\ProgramData\Qubes', 'C:\ProgramData\Qubes\log',
          'C:\Windows\Temp', 'C:\Program Files\Qubes Tools')
$logs = @()
foreach ($d in $dirs) {
    if (Test-Path $d) {
        $logs += Get-ChildItem -LiteralPath $d -Filter *.log -Recurse -EA SilentlyContinue |
                 Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-6) }
    }
}
Write-Output '=== recent .log files ==='
foreach ($l in ($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 12)) {
    Write-Output ("{0}  {1,10} bytes  {2}" -f $l.LastWriteTime.ToString('HH:mm:ss'), $l.Length, $l.FullName)
}

# The qrexec agent log is the one that records service requests from dom0.
$qr = $logs | Where-Object { $_.Name -match 'qrexec' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($qr) {
    Write-Output ''
    Write-Output "=== $($qr.FullName): lines mentioning VMExec/VMShell around the update ==="
    Get-Content -LiteralPath $qr.FullName -EA SilentlyContinue |
        Where-Object { $_ -match 'VMExec|VMShell|exit|status' } |
        Select-Object -Last 40 | ForEach-Object { Write-Output $_ }
}
