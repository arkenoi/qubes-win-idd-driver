# Did the plain-HTTP verify+retry path actually engage, and what did it see?
# Answers the question the full-pass failure raises: the CTL fetch either never reached the relay
# (so the retry could not help) or it did and still failed. Quoting this through qtest/cmd fails on
# the pipes and quotes, hence a script.
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
$log = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
Write-Output '=== RESULT ==='
if ($log.Count -eq 0) { Write-Output 'no relay log'; exit 1 }
$lines = @(Get-Content -LiteralPath $log -EA SilentlyContinue)
Write-Output ("total lines      = {0}" -f $lines.Count)
$plain = @($lines | Where-Object { $_ -match 'PLAIN' })
$ctldl = @($lines | Where-Object { $_ -match 'ctldl' })
$deny  = @($lines | Where-Object { $_ -match 'DENY' })
Write-Output ("PLAIN lines      = {0}   (verify/retry path engaged)" -f $plain.Count)
Write-Output ("ctldl requests   = {0}" -f $ctldl.Count)
Write-Output ("DENY lines       = {0}" -f $deny.Count)
Write-Output '--- first PLAIN lines ---'
foreach ($l in ($plain | Select-Object -First 10)) { Write-Output ("  " + $l) }
Write-Output '--- any ctldl activity ---'
foreach ($l in ($ctldl | Select-Object -First 6)) { Write-Output ("  " + $l.Substring(0, [Math]::Min(150, $l.Length))) }
Write-Output '--- denied hosts (allowlist) ---'
foreach ($l in ($deny | Select-Object -First 6)) { Write-Output ("  " + $l.Substring(0, [Math]::Min(120, $l.Length))) }
