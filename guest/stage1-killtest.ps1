# Stage 1 self-contained kill-test (PLAN-updates-proxy.md). ONE process, no detached
# children (start /b dies with the qrexec session), no log-file attribution ambiguity:
# a loopback listener runs on a background runspace capturing every connection's first
# request line in memory; this process then triggers a WU scan (COM) and reports what the
# listener saw. Assumes the 3 proxy planes are already set (wu-proxy-config.ps1 -Enable).
#
# VERDICT: connections naming a WU endpoint => wuauserv dials the loopback proxy even with
# zero NICs (R1 dead). Zero connections + the no-proxy HRESULT => NLM hard-gate (Stage 1b).
param([int]$Port = 8082, [int]$ListenSeconds = 90)
$ErrorActionPreference = 'Stop'

# Shared, thread-safe sink for captured request lines.
$hits = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('hits', $hits)
$rs.SessionStateProxy.SetVariable('Port', $Port)
$rs.SessionStateProxy.SetVariable('ListenSeconds', $ListenSeconds)
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $l.Start()
    $deadline = (Get-Date).AddSeconds($ListenSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not $l.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $c = $l.AcceptTcpClient()
        try {
            $c.ReceiveTimeout = 1500
            $ns = $c.GetStream(); $buf = New-Object byte[] 2048
            Start-Sleep -Milliseconds 40
            $n = 0; try { $n = $ns.Read($buf, 0, $buf.Length) } catch {}
            $txt = if ($n -gt 0) { [System.Text.Encoding]::ASCII.GetString($buf, 0, $n) } else { '<no-bytes>' }
            $first = ($txt -split "`r`n")[0]
            $hostl = ($txt -split "`r`n" | Where-Object { $_ -match '^Host:' } | Select-Object -First 1)
            $hits.Enqueue("$((Get-Date).ToString('HH:mm:ss.fff')) | $first | $hostl")
            $resp = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            try { $ns.Write($resp, 0, $resp.Length) } catch {}
        } finally { $c.Close() }
    }
    $l.Stop()
})
$async = $ps.BeginInvoke()
Start-Sleep -Milliseconds 500   # let the listener bind

# In-process WU scan through the (already configured) planes.
$scan = [ordered]@{ ok = $false; hresult_hex = $null; count = $null }
try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $searcher.ServerSelection = 2; $searcher.Online = $true
    $r = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $scan.ok = $true; $scan.hresult_hex = '0x00000000'; $scan.count = $r.Updates.Count
} catch {
    $hr = if ($_.Exception.InnerException) { $_.Exception.InnerException.HResult } else { $_.Exception.HResult }
    $scan.hresult_hex = ('0x{0:X8}' -f ($hr -band 0xFFFFFFFF))
}

# Control A: EXPLICIT-proxy client MUST appear in hits (proves the listener captures).
try {
    $wc = [System.Net.WebClient]::new()
    $wc.Proxy = [System.Net.WebProxy]::new("127.0.0.1:$Port")
    try { $wc.DownloadString('http://selftest.invalid/probe') } catch {}
} catch {}
# Control B: DEFAULT-system-proxy client to a WU-looking host. If THIS reaches the mock, the
# machine proxy planes route correctly and any WU abstention is WU/NLM-specific, not a plane bug.
try {
    $req = [System.Net.WebRequest]::Create('http://sysproxytest.update.microsoft.com/probe')
    $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $req.Timeout = 4000
    try { $req.GetResponse().Close() } catch {}
} catch {}

Start-Sleep -Seconds 3
# Drain the listener (give WU's async DO/BITS a moment), then stop.
$captured = @(); $x = ''
while ($hits.TryDequeue([ref]$x)) { $captured += $x }
try { $ps.Stop() } catch {}
$rs.Close()

$selftest = @($captured | Where-Object { $_ -match 'selftest\.invalid' }).Count
$sysproxy = @($captured | Where-Object { $_ -match 'sysproxytest' }).Count
$wu = @($captured | Where-Object { $_ -match 'sls\.|fe[23]\.|delivery\.mp|dl\.delivery|windowsupdate\.com|\.update\.microsoft' }).Count
$out = [ordered]@{
    scan = $scan
    connections = $captured.Count
    selftest_seen = ($selftest -gt 0)     # control A: listener provably captures
    sysproxy_routes = ($sysproxy -gt 0)   # control B: machine proxy planes route to the mock
    wu_endpoint_hits = $wu                 # the verdict: did wuauserv itself dial
    captured = $captured
}
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress -Depth 4))
