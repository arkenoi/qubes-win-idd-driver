# Stage 2 one-shot probe (PLAN-updates-proxy.md): the qrexec HANDLER for a single
# qubes.UpdatesProxy call. Its stdin/stdout ARE the vchan (8-bit clean). It writes one
# absolute-URI HTTP proxy request to stdout (-> proxy) and copies stdin (proxy's reply)
# to a file, so the caller can tell ALLOWED+proxied (HTTP response present) from
# DENIED/no-proxy (empty). No listener, no relay - the simplest thing that proves the
# qrexec byte path reaches a real updates proxy under stock TemplateVM policy.
$ErrorActionPreference = 'SilentlyContinue'
$outFile    = 'C:\Users\Public\up-oneshot-reply.bin'
$markerFile = 'C:\Users\Public\up-oneshot-marker.txt'
# FIRST action, before any vchan I/O: prove the handler was actually spawned. Its presence
# vs absence separates "policy denied / handler never ran" from "ran but proxy silent".
"handler started $(Get-Date -Format o)" | Set-Content -LiteralPath $markerFile
Remove-Item -LiteralPath $outFile -Force -EA SilentlyContinue

$vout = [Console]::OpenStandardOutput()
$vin  = [Console]::OpenStandardInput()

# tinyproxy expects the absolute-URI form for plain HTTP. ctldl (cert trust list) is a
# small, always-available, plain-HTTP:80 endpoint - ideal to prove forwarding.
$req = "GET http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab HTTP/1.1`r`n" +
       "Host: ctldl.windowsupdate.com`r`n" +
       "Proxy-Connection: close`r`n`r`n"
$rb = [System.Text.Encoding]::ASCII.GetBytes($req)
$vout.Write($rb, 0, $rb.Length); $vout.Flush()

# Read the reply until EOF or a short idle, capture to file.
$fs = [System.IO.File]::Open($outFile, 'Create', 'Write')
$buf = New-Object byte[] 65536
$total = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($sw.Elapsed.TotalSeconds -lt 50) {   # tinyproxy->Tor->CDN can be slow
        $n = $vin.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $fs.Write($buf, 0, $n); $total += $n
        if ($total -ge 4096) { break }   # enough to see status line + headers
    }
} catch {}
$fs.Close()
