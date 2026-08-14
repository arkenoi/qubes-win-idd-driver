# Print the doprobe artefacts to stdout with split markers, so the dev qube can slice them
# without a binary transfer. Text only; bounded per file so one huge CSV cannot swamp the pipe.
param([int]$MaxLines = 4000)
$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\Qubes\wu\doprobe'
if (-not (Test-Path -LiteralPath $out)) { Write-Output "=== MISSING $out ==="; exit 1 }
foreach ($n in @('witness.txt','services.txt','status1.txt','status2.txt','do-periodicity.txt',
                 'bitsjobs.txt','sockets.csv','do-requests.csv','do-storage.csv','bits.txt',
                 'dolog-error.txt','relaytail.txt')) {
  $p = Join-Path $out $n
  Write-Output ("<<<<FILE " + $n + ">>>>")
  if (Test-Path -LiteralPath $p) {
    $c = Get-Content -LiteralPath $p -ErrorAction SilentlyContinue
    $tot = @($c).Count
    if ($tot -gt $MaxLines) {
      Write-Output ("[truncated: " + $tot + " lines, showing last " + $MaxLines + "]")
      $c | Select-Object -Last $MaxLines
    } else { $c }
  } else { Write-Output "[absent]" }
  Write-Output ("<<<<ENDFILE " + $n + ">>>>")
}
Write-Output '=== PULLDONE ==='
