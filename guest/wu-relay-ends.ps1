# Show the newly instrumented CONN lines: how many bytes moved and WHY each direction stopped.
# The question this answers: is a truncated plain-HTTP response an orderly EOF (upstream said it
# was done) or a broken pipe (something reset mid-body)? The old bare `catch {}` made the two
# indistinguishable, which is why three hypotheses were chased and refuted on no evidence.
param([int]$Tail = 14)
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
Write-Output '=== RESULT ==='
if (-not (Test-Path $log)) { Write-Output 'no relay log'; exit 1 }
$conn = @(Get-Content $log -EA SilentlyContinue | Where-Object { $_ -match 'CONN ' -and $_ -match 'upEnd=' })
Write-Output ("instrumented CONN lines = {0}" -f $conn.Count)
foreach ($l in ($conn | Select-Object -Last $Tail)) {
    # keep it readable: time, bytes, end reasons, and the request
    $t   = ($l -split ' ')[0]
    $dn  = if ($l -match 'down=(\d+)')    { $Matches[1] } else { '?' }
    $ue  = if ($l -match 'upEnd=(\S+)')   { $Matches[1] } else { '?' }
    $de  = if ($l -match 'downEnd=(\S+)') { $Matches[1] } else { '?' }
    $eof = if ($l -match ' eof=(\w+)')    { $Matches[1] } else { '?' }
    $rq  = if ($l -match 'req=\[([^\]]*)') { $Matches[1] } else { '' }
    if ($rq.Length -gt 60) { $rq = $rq.Substring(0, 60) }
    Write-Output ("{0}  down={1,-7} eof={2,-7} upEnd={3,-28} downEnd={4,-28} {5}" -f $t, $dn, $eof, $ue, $de, $rq)
}
