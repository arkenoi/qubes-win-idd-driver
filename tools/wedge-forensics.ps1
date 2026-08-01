# Post-recovery forensics for a starvation/wedge episode (run via qtest pushrun after
# reboot). Args: start/end of the suspect window, local guest time, 'yyyy-MM-dd HH:mm'.
param(
    [string]$From = '2026-08-01 23:40',
    [string]$To   = '2026-08-02 00:25'
)
$f = [datetime]::ParseExact($From, 'yyyy-MM-dd HH:mm', $null)
$t = [datetime]::ParseExact($To,   'yyyy-MM-dd HH:mm', $null)

Write-Output "=== gui-agent log census (new file per process start; many files in window = respawn loop) ==="
$logs = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime
Write-Output "CENSUS total=$($logs.Count)"
foreach ($l in $logs | Select-Object -Last 40) {
    "LOG $($l.Name) size=$($l.Length) created=$($l.CreationTime.ToString('o')) lastwrite=$($l.LastWriteTime.ToString('o'))"
}
$inwin = @($logs | Where-Object { $_.CreationTime -ge $f -and $_.CreationTime -le $t })
Write-Output "CENSUS_IN_WINDOW=$($inwin.Count)   # >5 = respawn loop; 0-1 = single process spinning"

Write-Output "=== watchdog log tail ==="
Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter '*watchdog*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 2 | ForEach-Object {
        "WDLOG $($_.Name) size=$($_.Length)"
        Get-Content $_.FullName -Tail 60 | ForEach-Object { "WD $_" }
    }

Write-Output "=== last agent log before/at wedge: final 40 lines ==="
$lastwedge = $logs | Where-Object { $_.LastWriteTime -le $t } | Select-Object -Last 1
if ($lastwedge) {
    "WEDGELOG $($lastwedge.Name)"
    Get-Content $lastwedge.FullName -Tail 40 | ForEach-Object { "GA $_" }
}

Write-Output "=== system+application events in window (errors/warnings + service control) ==="
foreach ($ln in 'System','Application') {
    Get-WinEvent -FilterHashtable @{LogName=$ln; StartTime=$f; EndTime=$t} -MaxEvents 400 -ErrorAction SilentlyContinue |
        Where-Object { $_.Level -le 3 -or $_.ProviderName -match 'Service Control|Windows Error' } |
        Sort-Object TimeCreated | Select-Object -Last 60 | ForEach-Object {
            "EVT $ln $($_.TimeCreated.ToString('MM-dd HH:mm:ss')) lvl=$($_.Level) $($_.ProviderName) id=$($_.Id) $((($_.Message -split "`n")[0]) -replace ',',';')"
        }
}

Write-Output "=== WER crash dumps for qubes binaries ==="
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue','C:\ProgramData\Microsoft\Windows\WER\ReportArchive' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'gui-agent|qrexec|qga|watchdog' } | Select-Object -First 20 |
    ForEach-Object { "WER $($_.FullName)" }

Write-Output "=== housekeeping: QubesIncoming path (handoff step 5.3 record) ==="
Get-ChildItem 'C:\Users\user\Documents\QubesIncoming' -ErrorAction SilentlyContinue |
    ForEach-Object { "INCOMING C:\Users\user\Documents\QubesIncoming\$($_.Name)" }

Write-Output "=== current processes / uptime sanity ==="
"BOOT $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'))"
Get-Process gui-agent,gui-watchdog,qrexec-agent -ErrorAction SilentlyContinue |
    ForEach-Object { "PROC $($_.Name) pid=$($_.Id) start=$($_.StartTime.ToString('o')) cpu=$([int]$_.CPU)s" }
Write-Output "RESULT=FORENSICS_DONE"
