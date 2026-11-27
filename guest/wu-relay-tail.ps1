# Emit the last N lines of the relay log (default 600) for host-side gap analysis.
param([int]$Tail = 600)
$ErrorActionPreference = 'Continue'
# THE ONE LOG DIRECTORY (docs/ADR-logging.md, Decision 2026-11-01), asked of the installed log.ps1's Get-QwtLogDir
# (the one rule: the registry LogDir, else Q:\Qubes Logs, else <SystemDrive>\Qubes Logs). A moved log is its per-day files there,
# <module>-<yyyyMMdd>.log, newest last; only a guest with none of them reads the file at its old path.
function Get-MovedLogFiles([string]$Module, [string]$Old) {
    # the log directory by the one rule (docs/ADR-logging.md 1), asked of the installed log.ps1
    $d = & { . 'C:\Program Files\Qubes Tools\bin\log.ps1'; Get-QwtLogDir }
    $rx = '^' + [regex]::Escape($Module) + '-\d{8}\.log$'
    $f = @(Get-ChildItem -LiteralPath $d -Filter "$Module-*.log" -File -EA SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($f.Count -eq 0 -and $Old -and (Test-Path -LiteralPath $Old)) { $f = @($Old) }
    $f
}
$rl = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
if ($rl.Count -eq 0) { Write-Output 'NO relay log'; exit 1 }
# size over every file of the log, mtime of the newest; the tail runs across them as across the one old file
$fis = @($rl | ForEach-Object { Get-Item -LiteralPath $_ })
$fi = $fis[-1]
$size = ($fis | Measure-Object -Property Length -Sum).Sum
Write-Output ("=== RELAYLOG size=" + $size + " mtime=" + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " now=" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + " ===")
@(foreach ($p in $rl) { Get-Content -LiteralPath $p -Tail $Tail }) | Select-Object -Last $Tail
Write-Output '=== END RELAYLOG ==='
