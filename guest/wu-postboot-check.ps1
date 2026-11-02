# After a commit boot: did the updates the pass claimed actually land, and does a fresh scan
# still offer them? Also pulls the DISM verdict for any package that failed.
$ErrorActionPreference = 'Continue'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output "build: $($cv.CurrentBuild).$($cv.UBR) $($cv.DisplayVersion)"

# THE ONE LOG DIRECTORY (docs/ADR-logging.md, Decision 2026-11-01), by log.ps1's rule, inlined because this probe runs
# without it: the registry LogDir, else <SystemDrive>\Qubes Logs. A moved log is its per-day files there,
# <module>-<yyyyMMdd>.log, newest last; only a guest with none of them reads the file at its old path.
function Get-MovedLogFiles([string]$Module, [string]$Old) {
    $d = $null
    try { $d = Get-ItemPropertyValue 'HKLM:\Software\Invisible Things Lab\Qubes Tools' LogDir -ErrorAction Stop } catch { }
    if (-not $d) { $d = Join-Path $env:SystemDrive 'Qubes Logs' }
    $rx = '^' + [regex]::Escape($Module) + '-\d{8}\.log$'
    $f = @(Get-ChildItem -LiteralPath $d -Filter "$Module-*.log" -File -EA SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($f.Count -eq 0 -and $Old -and (Test-Path -LiteralPath $Old)) { $f = @($Old) }
    $f
}
$log = @(Get-MovedLogFiles 'dism' 'C:\ProgramData\Qubes\wu\dism.log')
if ($log.Count) {
    Write-Output '--- last DISM errors ---'
    @(foreach ($p in $log) { Get-Content -LiteralPath $p -Tail 4000 }) | Select-Object -Last 4000 |
        Where-Object { $_ -match 'Error|0x8|failed' } |
        Select-Object -Last 8 |
        ForEach-Object { Write-Output ("  " + $_.Trim()) }
}

Write-Output '--- fresh scan (scan-only, installs nothing) ---'
& 'C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1' -Action scan 2>&1 |
    Select-String -Pattern 'scan:|available|proxy' | ForEach-Object { Write-Output ("  " + $_.Line) }

$st = Get-Content 'C:\ProgramData\Qubes\update-status.json' -Raw -EA SilentlyContinue | ConvertFrom-Json
Write-Output "=== RESULT ==="
Write-Output ("count=" + $st.count + " kbs=" + (@($st.available | ForEach-Object { $_.kb }) -join ','))
