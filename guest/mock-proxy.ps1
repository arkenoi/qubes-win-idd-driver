# Stage 1 kill-probe listener (PLAN-updates-proxy.md). Pure loopback, no qrexec, no network.
# Answers the ONE question that can invalidate the whole approach: with zero NICs, does
# wuauserv/DO actually open TCP to a configured loopback proxy, or does NLM gate it out?
#
# Per connection: log the first request line + any Host/CONNECT target to a file, return a
# minimal 502, close. A connection naming a real WU endpoint = the dial happened (R1 dead);
# silence during a scan = NLM hard-gate (go to Stage 1b). Runs for -Seconds then exits and
# prints the collected log so qtest can capture it.
param([int]$Port = 8082, [int]$Seconds = 300, [string]$LogFile = "C:\Users\Public\mock-proxy.log")
$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Output "MOCKPROXY listening 127.0.0.1:$Port for ${Seconds}s"
$deadline = (Get-Date).AddSeconds($Seconds)
$count = 0
try {
    while ((Get-Date) -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 2000
            $ns = $client.GetStream()
            $buf = New-Object byte[] 4096
            Start-Sleep -Milliseconds 60   # let the request head arrive
            $n = 0
            try { $n = $ns.Read($buf, 0, $buf.Length) } catch {}
            $req = if ($n -gt 0) { [System.Text.Encoding]::ASCII.GetString($buf, 0, $n) } else { '' }
            $firstLine = ($req -split "`r`n")[0]
            $hostLine  = ($req -split "`r`n" | Where-Object { $_ -match '^Host:' } | Select-Object -First 1)
            $stamp = (Get-Date).ToString('HH:mm:ss.fff')
            $line = "$stamp CONN#$count | $firstLine | $hostLine"
            Add-Content -LiteralPath $LogFile -Value $line
            $count++
            $resp = "HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $rb = [System.Text.Encoding]::ASCII.GetBytes($resp)
            try { $ns.Write($rb, 0, $rb.Length) } catch {}
        } finally { $client.Close() }
    }
} finally { $listener.Stop() }
Write-Output "MOCKPROXY done: $count connections"
Write-Output "=== MOCKLOG ==="
if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile } else { Write-Output "(no connections)" }
Write-Output "=== ENDLOG ==="
