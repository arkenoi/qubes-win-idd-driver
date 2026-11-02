# Why did an offline .msu install fail? Pull the decisive lines out of DISM's own log and CBS,
# per package, instead of guessing from an exit code.
$ErrorActionPreference = 'Continue'
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
$dism = @(Get-MovedLogFiles 'dism' 'C:\ProgramData\Qubes\wu\dism.log')

function Section($t) { Write-Output ''; Write-Output "=== $t ===" }

Section 'DISM: per-package outcome lines'
if ($dism.Count) {
    Get-Content -LiteralPath $dism |
        Where-Object { $_ -match 'Add-Package|PackagePath|Failed processing|The operation completed|hrResult|Error DISM' } |
        Select-Object -Last 25 | ForEach-Object { Write-Output ("  " + $_.Trim()) }
} else { Write-Output '  (no DISM log: no dism-<yyyyMMdd>.log in the log directory, none at the old path)' }

Section 'DISM: first error after each package start'
if ($dism.Count) {
    $lines = @(Get-Content -LiteralPath $dism)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'kb504308|kb512100|ndp481') {
            Write-Output ("  @" + $i + ": " + $lines[$i].Trim())
        }
    }
}

Section 'CBS: why the boot-time servicing rolled back'
$cbs = 'C:\Windows\Logs\CBS\CBS.log'
if (Test-Path $cbs) {
    Get-Content $cbs -Tail 4000 |
        Where-Object { $_ -match '0x80070490|Failed to|rollback|Startup Processing|checkpoint|missing' } |
        Select-Object -Last 20 | ForEach-Object { Write-Output ("  " + $_.Trim()) }
} else { Write-Output '  (no CBS.log)' }

Section 'pending servicing state right now'
Write-Output ("  CBS RebootPending : " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
Write-Output ("  WU RebootRequired : " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
$sess = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
$incomplete = @(Get-ChildItem $sess -EA SilentlyContinue |
                Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).Complete -ne 1 })
Write-Output ("  CBS incomplete sessions : " + $incomplete.Count + "   (key existence proves nothing)")
Write-Output '=== RESULT === done'
