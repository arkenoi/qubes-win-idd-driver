# wu-do-timer-probe.ps1 - test "the ~4 s cadence is Delivery Optimization's scheduler tick".
#
# Falsifier conditions this probe must be able to FIRE (each prints an explicit line):
#   (a) DO issues requests event-driven during the relay-level silences
#   (b) no periodic ~4 s scheduler/timer callbacks aligned with burst starts
#   (c) the waits are attributed to file-write / hash-verify   -> storage fork
#   (d) no active DO job while BITS carries the payload        -> engine is not DoSvc at all
#
# HARD RULE: never hand back a verdict when nothing was downloading. An idle guest produces
# "no DO requests between ticks" trivially, which is textually identical to CONFIRMED.
# Every section is gated on a witness that a download is actually running.

param([int]$SocketSeconds = 30)

$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\Qubes\wu\doprobe'
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $out | Out-Null
$relayLog = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
function W($s) { Write-Output $s }

function Witness {
  $r = 0
  if (Test-Path -LiteralPath $relayLog) { $r = (Get-Item -LiteralPath $relayLog).Length }
  $d = 0
  try {
    $d = (Get-ChildItem -Recurse -Force -File 'C:\Windows\SoftwareDistribution\Download' `
          -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
    if ($null -eq $d) { $d = 0 }
  } catch { $d = 0 }
  return [pscustomobject]@{ Relay = [int64]$r; Dl = [int64]$d; T = Get-Date }
}
$w0 = Witness

# ---- (d) WHICH ENGINE owns the sockets to the relay? -----------------------------------------
# Cheapest decisive discriminator: whoever holds TCP connections to 127.0.0.1:8082 IS the
# downloader. svchost hosts both DoSvc and BITS, so map PID -> service name.
$svcByPid = @{}
try {
  Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.ProcessId -gt 0 } | ForEach-Object {
    $k = [int]$_.ProcessId
    if (-not $svcByPid.ContainsKey($k)) { $svcByPid[$k] = @() }
    $svcByPid[$k] += $_.Name
  }
} catch {}

$sockSamples = New-Object System.Collections.ArrayList
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $SocketSeconds) {
  $t = (Get-Date).ToString('HH:mm:ss.fff')
  $conns = @()
  try {
    $conns = @(Get-NetTCPConnection -RemotePort 8082 -ErrorAction SilentlyContinue |
               Where-Object { $_.RemoteAddress -eq '127.0.0.1' })
  } catch {}
  foreach ($c in $conns) {
    $op = [int]$c.OwningProcess
    $pname = ''; try { $pname = (Get-Process -Id $op -ErrorAction SilentlyContinue).ProcessName } catch {}
    $svc = ''; if ($svcByPid.ContainsKey($op)) { $svc = ($svcByPid[$op] -join '+') }
    [void]$sockSamples.Add([pscustomobject]@{ T=$t; State=$c.State; LocalPort=$c.LocalPort; OwnPid=$op; Proc=$pname; Svc=$svc })
  }
  if ($conns.Count -eq 0) {
    [void]$sockSamples.Add([pscustomobject]@{ T=$t; State='NONE'; LocalPort=0; OwnPid=0; Proc=''; Svc='' })
  }
  Start-Sleep -Milliseconds 250
}
$sockSamples | Export-Csv "$out\sockets.csv" -NoTypeInformation

# ---- DO job status, two samples 10 s apart ---------------------------------------------------
$doStatusOk = $true
try { Get-DeliveryOptimizationStatus -ErrorAction Stop | Format-List * > "$out\status1.txt" }
catch { $doStatusOk = $false; "Get-DeliveryOptimizationStatus FAILED: $_" | Out-File "$out\status1.txt" }
Start-Sleep -Seconds 10
try { Get-DeliveryOptimizationStatus -ErrorAction Stop | Format-List * > "$out\status2.txt" }
catch { "Get-DeliveryOptimizationStatus FAILED: $_" | Out-File "$out\status2.txt" }

# ---- DO internal log -------------------------------------------------------------------------
$doLogOk = $true
$doRows = @()
try {
  $since = (Get-Date).AddMinutes(-6)
  $doRows = @(Get-DeliveryOptimizationLog -ErrorAction Stop | Where-Object { $_.TimeCreated -gt $since })
} catch { $doLogOk = $false; "Get-DeliveryOptimizationLog FAILED: $_" | Out-File "$out\dolog-error.txt" }

if ($doLogOk -and $doRows.Count -gt 0) {
  $doRows | Select-Object TimeCreated, Function, Message | Export-Csv "$out\dolog.csv" -NoTypeInformation
  # In-guest summary: which functions recur, and with what inter-arrival period.
  $rep = New-Object System.Collections.ArrayList
  $doRows | Group-Object Function | Where-Object { $_.Count -ge 5 } | Sort-Object Count -Descending |
    Select-Object -First 40 | ForEach-Object {
      $ts = @($_.Group | Sort-Object TimeCreated | ForEach-Object { $_.TimeCreated })
      $ia = @()
      for ($i=1; $i -lt $ts.Count; $i++) { $ia += ($ts[$i] - $ts[$i-1]).TotalMilliseconds }
      if ($ia.Count -gt 0) {
        $m = ($ia | Measure-Object -Average -Minimum -Maximum)
        $sorted = $ia | Sort-Object
        $med = $sorted[[int]($sorted.Count/2)]
        [void]$rep.Add([pscustomobject]@{
          Function=$_.Name; N=$_.Count; MedianMs=[int]$med; MeanMs=[int]$m.Average
          MinMs=[int]$m.Minimum; MaxMs=[int]$m.Maximum })
      }
    }
  $rep | Sort-Object N -Descending | Format-Table -AutoSize | Out-String -Width 300 > "$out\do-periodicity.txt"
  # Requests actually issued by DO, with timestamps, so (a) can be tested.
  $doRows | Where-Object { $_.Message -match 'http://|https://|Range|SendRequest|WinHttp|ConnectionManager|Download.*piece|GetPiece' } |
    Select-Object TimeCreated, Function, Message | Export-Csv "$out\do-requests.csv" -NoTypeInformation
  # (c) storage attribution
  $doRows | Where-Object { $_.Message -match 'hash|Hash|verify|Verify|WriteFile|FileWrite|flush|Flush|disk|Disk' } |
    Select-Object TimeCreated, Function, Message | Export-Csv "$out\do-storage.csv" -NoTypeInformation
}

# ---- BITS + service evidence -----------------------------------------------------------------
& wevtutil qe Microsoft-Windows-Bits-Client/Operational /c:120 /rd:true /f:text > "$out\bits.txt" 2>&1
try {
  Get-BitsTransfer -AllUsers -ErrorAction Stop |
    Select-Object JobId,DisplayName,JobState,BytesTransferred,BytesTotal | Format-List * > "$out\bitsjobs.txt"
} catch { "Get-BitsTransfer FAILED: $_" | Out-File "$out\bitsjobs.txt" }
Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('DoSvc','BITS','wuauserv','UsoSvc') } |
  Select-Object Name,State,ProcessId,StartMode | Format-Table -AutoSize | Out-String -Width 200 > "$out\services.txt"

if (Test-Path -LiteralPath $relayLog) { Get-Content -LiteralPath $relayLog -Tail 800 > "$out\relaytail.txt" }
else { "MISSING $relayLog" | Out-File "$out\relaytail.txt" }

$w1 = Witness
$relayGrew = $w1.Relay - $w0.Relay
$dlGrew    = $w1.Dl - $w0.Dl
$active    = ($relayGrew -gt 0) -or ($dlGrew -gt 0)
@"
witness_t0=$($w0.T.ToString('HH:mm:ss.fff')) relay_len=$($w0.Relay) dl_bytes=$($w0.Dl)
witness_t1=$($w1.T.ToString('HH:mm:ss.fff')) relay_len=$($w1.Relay) dl_bytes=$($w1.Dl)
relay_log_growth_bytes=$relayGrew
softwaredistribution_download_growth_bytes=$dlGrew
download_active_during_sample=$active
do_log_available=$doLogOk rows=$($doRows.Count)
do_status_available=$doStatusOk
"@ | Out-File "$out\witness.txt"

Compress-Archive -Path "$out\*" -DestinationPath 'C:\ProgramData\Qubes\wu\doprobe.zip' -Force

W '=== RESULT ==='
W ("download_active_during_sample=" + $active)
W ("relay_log_growth_bytes=" + $relayGrew)
W ("softwaredistribution_download_growth_bytes=" + $dlGrew)
W ("do_log_available=" + $doLogOk + " rows=" + $doRows.Count)
if (-not $active) {
  W 'VERDICT UNAVAILABLE: nothing was downloading during the sample window.'
  W 'Idle counters here mean IDLE GUEST, not a BITS/DO timer. Do NOT score this run.'
}
W ('socket_samples_total=' + $sockSamples.Count)
W ('socket_samples_with_conns=' + (@($sockSamples | Where-Object { $_.State -ne 'NONE' }).Count))
$sockSamples | Where-Object { $_.State -ne 'NONE' } | Group-Object Svc | Sort-Object Count -Descending |
  ForEach-Object { W ("  owner svc=[" + $_.Name + "] samples=" + $_.Count) }
$sockSamples | Where-Object { $_.State -ne 'NONE' } | Group-Object Proc | Sort-Object Count -Descending |
  ForEach-Object { W ("  owner proc=[" + $_.Name + "] samples=" + $_.Count) }
W ('zip_size=' + (Get-Item 'C:\ProgramData\Qubes\wu\doprobe.zip' -ErrorAction SilentlyContinue).Length)
W 'DONE'
