# wu-ceiling-probe.ps1 -- measure the TRANSPORT CEILING through the relay, independent of Windows
# Update. Answers exactly one question: right now, in this session, how fast can bytes move over
#     guest HTTP client -> qubes-updates-relay (127.0.0.1:8082) -> qrexec qubes.UpdatesProxy
#     -> tinyproxy in the proxy qube -> CDN
# It exists because no WU throughput number can be attributed to anything without a same-session
# ceiling measured on the same path.
#
# Two URLs are fetched when possible:
#   REF  - a fixed public 100 MB file, also measured from the dev qube directly on the same day,
#          so relay-vs-direct is a matched comparison and the ceiling number is calibrated.
#   WU   - the last real GET seen in the relay log, so the ceiling is also measured against the
#          actual CDN host WU uses. Skipped (loudly) if the log holds no GET line.
#
# Prints machine-parsable lines. Any failure prints a FAIL line and keeps going; a missing
# measurement is reported as missing and never substituted.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::DefaultConnectionLimit = 64

$wu      = 'C:\ProgramData\Qubes\wu'
$log     = Join-Path $wu 'qubes-updates-relay.log'
$relay   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$refUrl  = 'http://speedtest.tele2.net/100MB.zip'

Write-Output "=== CEILING PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ==="

# ---- 1. relay must be listening -------------------------------------------------------------
$proc = Get-Process qubes-updates-relay -ErrorAction SilentlyContinue
if (-not $proc) {
  if (-not (Test-Path -LiteralPath $relay)) { Write-Output "FAIL: relay exe missing at $relay"; exit 1 }
  Start-Process -FilePath $relay -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
  Start-Sleep -Seconds 3
  $proc = Get-Process qubes-updates-relay -ErrorAction SilentlyContinue
  Write-Output "relay_started=$([bool]$proc)"
} else {
  Write-Output "relay_already_running=1 pid=$($proc.Id)"
}
if (-not $proc) { Write-Output 'FAIL: relay not running and could not be started'; exit 1 }

# mark the log so the after-window can be sliced exactly at this point
$logMark = 0
if (Test-Path -LiteralPath $log) { $logMark = (Get-Item -LiteralPath $log).Length }
Write-Output "log_mark_bytes=$logMark"

# ---- 2. pick the WU URL out of the relay log ------------------------------------------------
$wuUrl = $null
if (Test-Path -LiteralPath $log) {
  $m = Select-String -Path $log -Pattern 'req=\[GET (http://[^ ]+) HTTP' | Select-Object -Last 1
  if ($m) { $wuUrl = $m.Matches[0].Groups[1].Value }
}
if ($wuUrl) { Write-Output "wu_url=$wuUrl" } else { Write-Output 'wu_url=NONE (no GET line in relay log; WU leg SKIPPED, not substituted)' }

# ---- 3. the fetcher -------------------------------------------------------------------------
$fetch = {
  param($u, $from, $len, $tag)
  try {
    $req = [System.Net.HttpWebRequest]::Create($u)
    # BypassOnLocal=$false: never let the client decide to skip the relay. The whole point is to
    # measure the relay path, and a silent bypass would report the guest's (nonexistent) direct
    # route as if it were the proxy path.
    $req.Proxy = New-Object System.Net.WebProxy('http://127.0.0.1:8082', $false)
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 60000
    $req.KeepAlive = $false
    if ($len -gt 0) { $req.AddRange([long]$from, [long]($from + $len - 1)) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $req.GetResponse()
    $ttfb = $sw.ElapsedMilliseconds
    $code = [int]$resp.StatusCode
    $s = $resp.GetResponseStream()
    $buf = New-Object byte[] 65536
    $tot = 0
    while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
      $tot += $n
      if ($sw.ElapsedMilliseconds -gt 120000) { break }
    }
    $sw.Stop(); $resp.Close()
    $ms = [Math]::Max(1, $sw.ElapsedMilliseconds)
    $kbps = [math]::Round($tot / 1024.0 / ($ms / 1000.0), 1)
    "$tag code=$code bytes=$tot ttfb_ms=$ttfb ms=$ms KBps=$kbps"
  } catch {
    "$tag FAIL: $($_.Exception.Message)"
  }
}

# ---- 4. single stream, 32 MB ----------------------------------------------------------------
Write-Output '--- SINGLE STREAM 32MB ---'
Write-Output (& $fetch $refUrl 0 33554432 'single_ref')
if ($wuUrl) { Write-Output (& $fetch $wuUrl 0 33554432 'single_wu') }

# ---- 5. three parallel streams, 16 MB each, disjoint ranges ---------------------------------
# Use the WU host when we have it. The Qubes updates proxy may filter hosts, and if the public
# reference host is denied the parallel leg would move 0 bytes and the verdict would read
# INCONCLUSIVE for a reason that has nothing to do with the ceiling. The WU host is known-allowed
# because WU already fetched through this exact proxy.
$parUrl = if ($wuUrl) { $wuUrl } else { $refUrl }
Write-Output "--- 3 PARALLEL x 16MB (host: $(([Uri]$parUrl).Host)) ---"
# In-process runspaces, NOT Start-Job. Start-Job spawns child powershell.exe processes, which is
# an extra failure mode under a qrexec-invoked non-interactive session; a job that fails to start
# would read as "the path moved no bytes" and falsify the hypothesis for the wrong reason.
$pool = [RunspaceFactory]::CreateRunspacePool(1, 4)
$pool.Open()
$shells = @()
$swp = [Diagnostics.Stopwatch]::StartNew()
foreach ($k in 0..2) {
  $ps = [PowerShell]::Create()
  $ps.RunspacePool = $pool
  [void]$ps.AddScript($fetch.ToString()).AddArgument($parUrl).AddArgument($k * 16777216).AddArgument(16777216).AddArgument("par$k")
  $shells += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
}
$totBytes = 0
foreach ($sh in $shells) {
  $r = ''
  try {
    if ($sh.handle.AsyncWaitHandle.WaitOne(200000)) { $r = ($sh.ps.EndInvoke($sh.handle) | Out-String).Trim() }
    else { $r = 'TIMEOUT after 200s' }
  } catch { $r = "FAIL: $($_.Exception.Message)" }
  if (-not $r) { $r = 'NO OUTPUT' }
  Write-Output "  $r"
  if ($r -match 'bytes=(\d+)') { $totBytes += [int]$matches[1] }
  $sh.ps.Dispose()
}
$pool.Close(); $pool.Dispose()
$swp.Stop()
$pms = [Math]::Max(1, $swp.ElapsedMilliseconds)
Write-Output ("parallel_wall_ms={0} parallel_bytes={1} aggregate_KBps={2}" -f $pms, $totBytes, [math]::Round($totBytes/1024.0/($pms/1000.0),1))
if ($totBytes -eq 0) { Write-Output 'FAIL: parallel leg moved ZERO bytes' }

# ---- 6. relay-side cross-check: the CONN lines this probe just wrote -------------------------
Write-Output '--- RELAY LOG (lines written during this probe) ---'
if (Test-Path -LiteralPath $log) {
  $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
  try {
    if ($logMark -gt 0 -and $logMark -le $fs.Length) { $fs.Position = $logMark }
    $sr = New-Object IO.StreamReader($fs)
    $tail = $sr.ReadToEnd()
  } finally { $fs.Close() }
  if ([string]::IsNullOrWhiteSpace($tail)) { Write-Output 'FAIL: relay wrote NO new log lines during the probe' }
  else { $tail.TrimEnd() -split "`r?`n" | ForEach-Object { Write-Output "  $_" } }
} else {
  Write-Output "FAIL: relay log missing at $log"
}
Write-Output '=== END ==='
