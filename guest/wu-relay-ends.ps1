# Show the newly instrumented CONN lines: how many bytes moved and WHY each direction stopped.
# The question this answers: is a truncated plain-HTTP response an orderly EOF (upstream said it
# was done) or a broken pipe (something reset mid-body)? The old bare `catch {}` made the two
# indistinguishable, which is why three hypotheses were chased and refuted on no evidence.
param([int]$Tail = 14)
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
$log = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
Write-Output '=== RESULT ==='
if ($log.Count -eq 0) { Write-Output 'no relay log'; exit 1 }
$conn = @(Get-Content -LiteralPath $log -EA SilentlyContinue | Where-Object { $_ -match 'CONN ' -and $_ -match 'upEnd=' })
Write-Output ("instrumented CONN lines = {0}" -f $conn.Count)
foreach ($l in ($conn | Select-Object -Last $Tail)) {
    # keep it readable: time, bytes, end reasons, and the request
    # the time: an old line's first token, or HH:mm:ss.fff out of the new prefix [yyyyMMdd.HHmmss.fff-pid:tid-L]
    $t   = ($l -split ' ')[0]
    if ($l -match '^\[\d{8}\.(\d\d)(\d\d)(\d\d)\.(\d{3})-') { $t = $Matches[1] + ':' + $Matches[2] + ':' + $Matches[3] + '.' + $Matches[4] }
    $dn  = if ($l -match 'down=(\d+)')    { $Matches[1] } else { '?' }
    $ue  = if ($l -match 'upEnd=(\S+)')   { $Matches[1] } else { '?' }
    $de  = if ($l -match 'downEnd=(\S+)') { $Matches[1] } else { '?' }
    $eof = if ($l -match ' eof=(\w+)')    { $Matches[1] } else { '?' }
    $rq  = if ($l -match 'req=\[([^\]]*)') { $Matches[1] } else { '' }
    if ($rq.Length -gt 60) { $rq = $rq.Substring(0, 60) }
    Write-Output ("{0}  down={1,-7} eof={2,-7} upEnd={3,-28} downEnd={4,-28} {5}" -f $t, $dn, $eof, $ue, $de, $rq)
}
