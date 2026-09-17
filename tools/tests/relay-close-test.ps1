<#
.SYNOPSIS
    Offline suite for the relay's close/refusal contract (guest/qubes-updates-relay.cs, file header
    "THE RELAY SERVES OR REFUSES"): no silent close, no keep-alive lie, no transient answer to a
    sanctioned request, denied svchosts named by the services they host. Runs under pwsh on Linux;
    no rig, no guest, no qrexec - the far side is an in-process TcpListener or a fake
    qrexec-client-vm script, and the SCM enumerator is a scripted delegate.

.DESCRIPTION
    THE DEFECT (measured 2026-09-17 on the German 25H2 template, findings/issues.md P1 "A KILLED
    UPDATE PASS COSTS dom0 TWO SILENT HOURS"): Windows Update logged 21 aborted connections
    (80072EFE = reset by this side) and the relay log had NO line for any of them; WU then classed
    the failure as a network transient, and on a NIC-less guest waited for a network event that
    never comes. Three ways a client could be reset without a response and without a line existed:
    the read-first bare close, the CONNECT no-channel bare close, and one-request-per-connection
    with the upstream's Connection: keep-alive relayed verbatim.

    Compiles the SHIPPED file as-is with Add-Type (never an excerpt), then drives the real
    HandleInbound with real loopback sockets, under live de-DE culture:
      keepalive-buffered   a warm channel answers with Connection: keep-alive -> the client gets
                           Connection: close (once), the same status/body/other headers, and the
                           upstream request is untouched
      keepalive-streamed   the same past the 16 MB spill mark (the header block written at the spill)
      openchan             no warm channel -> the relay spawns the (fake) qrexec-client-vm, takes the
                           connect-back, and SERVES the request
      readfirst            a connection that sent nothing -> CLOSE reason=read-first-empty peer=...
      nochannel-plain      qrexec-client-vm cannot be started -> 403 + X-Qubes-Relay: no-channel +
                           Connection: close + CLOSE reason=no-channel peer=... line; no 5xx
      nochannel-connect    the same on the CONNECT path (this used to be a bare close)
      deny                 18 denials of one caller in a minute -> 1 line, then `x17 suppressed`
                           when the window ends (by the next caller and by DenyFlush); the denied
                           svchost's line lists EVERY service its pid hosts; the SCM is asked only
                           when a line is written
      selftest             Relay.SelfTest (the canned framing contract) still passes
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the original bug in a temp copy (the shipped file is never modified):
      silent      the four `// GUARD:close-*` / `// GUARD:deny-count` lines revert to bare closes and
                  uncounted repeats -> readfirst, nochannel-*, deny must FAIL
      keepalive   the two `// GUARD:conn-close*` lines pass the upstream header block through
                  -> keepalive-* (and the selftest's spilled-header case) must FAIL
    tools/tests/relay-close-selftest.sh runs the clean leg and both knobs and requires each outcome.
#>
[CmdletBinding()]
param([string]$SourcePath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

if (-not $SourcePath) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
    $SourcePath = Join-Path $repoRoot 'guest/qubes-updates-relay.cs'
}
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- the shipped file: every guard marker present the expected number of times --------------------------
$lines = @(Get-Content -LiteralPath $SourcePath)
function CountMarker([string]$m) { return @($lines | Where-Object { $_ -match ('// ' + [regex]::Escape($m) + '$') }).Count }
$markers = @{ 'GUARD:close-readfirst' = 1; 'GUARD:close-nochannel' = 1; 'GUARD:close-nochannel-plain' = 1
              'GUARD:conn-close' = 1; 'GUARD:conn-close-spill' = 1; 'GUARD:deny-count' = 2 }
$markersOk = $true
foreach ($m in $markers.Keys) { if ((CountMarker $m) -ne $markers[$m]) { $markersOk = $false; Write-Host "     marker $m : $(CountMarker $m) (want $($markers[$m]))" } }
Check 'shipped: the six guard markers are present exactly as expected' $markersOk
if (-not $markersOk) { Write-Host 'FAIL cannot continue without the markers'; exit 1 }
Check 'shipped: no 5xx status and no Retry-After is ever written to a client (code lines, not comments)' `
      (@($lines | Where-Object { $_.Trim() -notlike '//*' -and ($_ -match '"HTTP/1\.1 5\d\d' -or $_ -match 'Retry-After') }).Count -eq 0)
function Has([string]$s, [string]$sub) { return ($s.IndexOf($sub, [StringComparison]::Ordinal) -ge 0) }   # -like would read [ ] as a class

# --- defect knob: patch a temp copy, never the shipped file -------------------------------------------
switch ($Defect) {
    '' { }
    'silent' {
        $lines = @($lines | ForEach-Object {
            if ($_ -match '// GUARD:close-readfirst$')       { '            /* DEFECT silent: the pre-2026-09-17 bare close, no line */' }
            elseif ($_ -match '// GUARD:close-nochannel$')   { '                /* DEFECT silent: the pre-2026-09-17 bare close */' }
            elseif ($_ -match '// GUARD:close-nochannel-plain$') { '                    /* DEFECT silent: nothing written, the using disposes the socket */' }
            elseif ($_ -match '// GUARD:deny-count$')        { '            /* DEFECT silent: repeats never counted */' }
            else { $_ } })
    }
    'keepalive' {
        $lines = @($lines | ForEach-Object {
            if ($_ -match '// GUARD:conn-close$')            { '                    byte[] outb = best.Bytes;   // DEFECT keepalive: upstream header block passed through' }
            elseif ($_ -match '// GUARD:conn-close-spill$')  { '                byte[] all = buf.ToArray();   // DEFECT keepalive: upstream header block passed through' }
            else { $_ } })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (silent|keepalive)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('relay-close-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$srcFile = Join-Path $tmpRoot 'relay-under-test.cs'
[IO.File]::WriteAllLines($srcFile, [string[]]$lines, [Text.UTF8Encoding]::new($false))

# --- compile the whole file (the real code, not an excerpt) ----------------------------------------
try {
    $types = @(Add-Type -Path $srcFile -PassThru)
} catch {
    Write-Host "FAIL compile: $($_.Exception.Message)"
    exit 1
}
$asm = $types[0].Assembly
$T = $asm.GetType('Relay')
Check 'compile: the shipped relay source compiles and exposes Relay' ($null -ne $T)
if ($null -eq $T) { exit 1 }
$bf = [Reflection.BindingFlags]'NonPublic,Public,Static'
$M = @{}
foreach ($n in 'HandleInbound', 'DenyLog', 'DenyFlush', 'HostedSuffix') {
    $M[$n] = $T.GetMethod($n, $bf)
    if ($null -eq $M[$n]) { Write-Host "FAIL reflection: Relay.$n not found"; exit 1 }
}
$ReadyT = $asm.GetType('Relay+Ready')
$pool = $T.GetField('_pool', $bf).GetValue($null)
$poolEnqueue = $pool.GetType().GetMethod('Enqueue')
$latin1 = [Text.Encoding]::GetEncoding('iso-8859-1')

# --- socket helpers ----------------------------------------------------------------------------------
function New-Pair {
    # a connected loopback pair: 'client' is what Windows Update would hold, 'server' what the relay accepted
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    $s = $l.AcceptTcpClient()
    $l.Stop()
    return [pscustomobject]@{ client = $c; server = $s }
}
function Send-Bytes([System.Net.Sockets.TcpClient]$c, [string]$text) {
    $b = $latin1.GetBytes($text); $st = $c.GetStream(); $st.Write($b, 0, $b.Length); $st.Flush()
}
function Read-All([System.Net.Sockets.TcpClient]$c, [int]$timeoutMs) {
    # everything until the peer closes, or the read timeout (a relay that never closes shows up as a short/late read)
    $ms = [IO.MemoryStream]::new()
    try {
        $st = $c.GetStream(); $st.ReadTimeout = $timeoutMs
        $buf = [byte[]]::new(65536)
        while ($true) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $ms.Write($buf, 0, $n) }
    } catch { }
    return ,$ms.ToArray()
}
function Read-Head([System.Net.Sockets.TcpClient]$c, [int]$timeoutMs) {
    $acc = ''
    try {
        $st = $c.GetStream(); $st.ReadTimeout = $timeoutMs
        $buf = [byte[]]::new(4096)
        while ($acc.IndexOf("`r`n`r`n") -lt 0) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $acc += $latin1.GetString($buf, 0, $n) }
    } catch { }
    return $acc
}
function Split-Response([byte[]]$b) {
    $s = $latin1.GetString($b)
    $i = $s.IndexOf("`r`n`r`n")
    if ($i -lt 0) { return [pscustomobject]@{ head = $s; body = ''; headers = @() } }
    $head = $s.Substring(0, $i)
    return [pscustomobject]@{ head = $head; body = $s.Substring($i + 4); headers = @($head -split "`r`n") }
}
function Invoke-Handle($server, [string]$peer, [string]$log, [string]$self = '/nonexistent/self.exe') {
    return $M['HandleInbound'].Invoke($null, [object[]]@($server, $peer, $self, '@default', 'SYSTEM', [string]$log))
}
# reflection's Invoke binds arguments strictly: a PSObject-wrapped string does not convert, so every
# string handed to Invoke below is cast with [string]
function New-Log([string]$name) { $p = Join-Path $tmpRoot "$name.log"; Set-Content -LiteralPath $p -Value '' -NoNewline; return [string]$p }
function Invoke-Deny([string]$log, [string]$who, [int]$peerPid, [DateTime]$now) { $M['DenyLog'].Invoke($null, [object[]]@([string]$log, [string]$who, [int]$peerPid, [DateTime]$now)) }
function Invoke-DenyFlush([string]$log, [DateTime]$now) { $M['DenyFlush'].Invoke($null, [object[]]@([string]$log, [DateTime]$now)) }
function Log-Lines([string]$p) { if (Test-Path -LiteralPath $p) { return @(Get-Content -LiteralPath $p | Where-Object { $_ }) } else { return @() } }
function Add-WarmChannel {
    # a pooled channel whose far end is an in-process listener: what a warm qrexec handler looks like to HandlePlainHttp
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $up = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    $upServer = $l.AcceptTcpClient()
    $l.Stop()
    $ready = [Activator]::CreateInstance($ReadyT)
    $ReadyT.GetField('Relay').SetValue($ready, $up)
    $ReadyT.GetField('Stream').SetValue($ready, $up.GetStream())
    $ReadyT.GetField('Token').SetValue($ready, 'warm-' + $port)
    $ReadyT.GetField('Born').SetValue($ready, [DateTime]::UtcNow)
    [void]$poolEnqueue.Invoke($pool, [object[]]@($ready))
    return $upServer
}
$env:QREXEC_CLIENT_VM = '/nonexistent/qrexec-client-vm.exe'   # OpenChannel must FAIL unless a case says otherwise
$GET = "GET http://download.windowsupdate.com/d/msdownload/update/x.cab HTTP/1.1`r`nHost: download.windowsupdate.com`r`nUser-Agent: Windows-Update-Agent`r`nConnection: Keep-Alive`r`n`r`n"

# --- 1. keepalive-buffered: the header block handed to the client says close ------------------------------
$log = New-Log 'keepalive-buffered'
$pair = New-Pair
$upServer = Add-WarmChannel
Send-Bytes $pair.client $GET
$task = Invoke-Handle $pair.server 'peer-ka' $log
$upReq = Read-Head $upServer 10000
Send-Bytes $upServer "HTTP/1.1 200 OK`r`nContent-Length: 5`r`nConnection: keep-alive`r`nKeep-Alive: timeout=5`r`nX-Test: kept`r`n`r`nhello"
$task.Wait(20000) | Out-Null
$resp = Split-Response (Read-All $pair.client 10000)
$connHdrs = @($resp.headers | Where-Object { $_ -match '^Connection:' })
Check 'keepalive-buffered: a warm channel answered Connection: keep-alive -> the client got Connection: close, exactly once' `
      ($connHdrs.Count -eq 1 -and $connHdrs[0] -ceq 'Connection: close')
Check 'keepalive-buffered: status line, the other headers and the body reach the client unchanged' `
      ($resp.headers[0] -ceq 'HTTP/1.1 200 OK' -and $resp.headers -ccontains 'X-Test: kept' -and $resp.headers -ccontains 'Content-Length: 5' -and $resp.body -ceq 'hello')
Check 'keepalive-buffered: the upstream request is untouched (still asks for Keep-Alive)' ($upReq -clike "GET http://download.windowsupdate.com/*Connection: Keep-Alive*")
$ll = Log-Lines $log
Check 'keepalive-buffered: logged as one complete PLAIN exchange, no CLOSE line' `
      (@($ll | Where-Object { $_ -like '*PLAIN tries=1 *complete=True*' }).Count -eq 1 -and @($ll | Where-Object { $_ -like '*CLOSE reason=*' }).Count -eq 0)
$pair.client.Close(); $upServer.Close()

# --- 2. keepalive-streamed: the same past the spill mark (the header block goes out at the spill) -------------
$log = New-Log 'keepalive-streamed'
$pair = New-Pair
$upServer = Add-WarmChannel
Send-Bytes $pair.client $GET
$task = Invoke-Handle $pair.server 'peer-ks' $log
$upReq = Read-Head $upServer 10000
$bigLen = 17 * 1024 * 1024
$hdr = $latin1.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $bigLen`r`nConnection: keep-alive`r`n`r`n")
$big = [byte[]]::new($hdr.Length + $bigLen)
[Buffer]::BlockCopy($hdr, 0, $big, 0, $hdr.Length)
$upStream = $upServer.GetStream()
$writeTask = $upStream.WriteAsync($big, 0, $big.Length)   # async: the relay drains it while this thread reads the client
$got = Read-All $pair.client 20000
$task.Wait(20000) | Out-Null
$writeTask.Wait(5000) | Out-Null
$resp = Split-Response $got
$connHdrs = @($resp.headers | Where-Object { $_ -match '^Connection:' })
Check "keepalive-streamed: a 17 MB response (spilled) reaches the client with Connection: close, once, and the whole body ($($got.Length - $resp.head.Length - 4)/$bigLen)" `
      ($connHdrs.Count -eq 1 -and $connHdrs[0] -ceq 'Connection: close' -and ($got.Length - $resp.head.Length - 4) -eq $bigLen)
$ll = Log-Lines $log
Check 'keepalive-streamed: logged as streamed=True complete=True, no CLOSE line' `
      (@($ll | Where-Object { $_ -like '*PLAIN tries=1 *complete=True streamed=True*' }).Count -eq 1 -and @($ll | Where-Object { $_ -like '*CLOSE reason=*' }).Count -eq 0)
$pair.client.Close(); $upServer.Close()

# --- 3. openchan: no warm channel -> the relay OPENS one (fake qrexec-client-vm) and serves --------------------
# The fake receives what qrexec-client-vm would: "<target>|<service>|<user>|<self>" --relay <cport> <token> [--log <dir>]
# and does what the spawned handler does - connect back, send the token line - then answers the request itself.
$fake = Join-Path $tmpRoot 'fake-qrexec-client-vm.sh'
$fakeSrc = @'
#!/usr/bin/env bash
cport="$3"; token="$4"
exec 3<>"/dev/tcp/127.0.0.1/$cport"
printf '%s\n' "$token" >&3
while IFS= read -r line <&3; do line="${line%$'\r'}"; [ -z "$line" ] && break; done
printf 'HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: keep-alive\r\nX-Via: fake-qrexec\r\n\r\nvia-openchan' >&3
exec 3>&-
'@
[IO.File]::WriteAllText($fake, $fakeSrc.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
chmod +x $fake
$env:QREXEC_CLIENT_VM = $fake
$log = New-Log 'openchan'
$pair = New-Pair
Send-Bytes $pair.client $GET
$task = Invoke-Handle $pair.server 'peer-oc' $log
$task.Wait(30000) | Out-Null
$resp = Split-Response (Read-All $pair.client 10000)
Check 'openchan: no warm channel -> OpenChannel spawned the (fake) qrexec-client-vm, took the connect-back and the request was SERVED (200, body via-openchan)' `
      ($resp.headers.Count -gt 0 -and $resp.headers[0] -ceq 'HTTP/1.1 200 OK' -and $resp.body -ceq 'via-openchan' -and $resp.headers -ccontains 'X-Via: fake-qrexec')
$ll = Log-Lines $log
Check 'openchan: logged as one complete PLAIN exchange, no CLOSE line, no CHAN error' `
      (@($ll | Where-Object { $_ -like '*PLAIN tries=1 *complete=True*' }).Count -eq 1 -and @($ll | Where-Object { $_ -like '*CLOSE reason=*' -or $_ -like '*CHAN token=* error*' -or $_ -like '*never connected back*' }).Count -eq 0)
$pair.client.Close()
$env:QREXEC_CLIENT_VM = '/nonexistent/qrexec-client-vm.exe'

# --- 4. readfirst: a connection that sent nothing is closed - and logged ------------------------------------------
$log = New-Log 'readfirst'
$pair = New-Pair
$pair.client.Close()
$task = Invoke-Handle $pair.server 'svchost (pid 4242)' $log
$task.Wait(20000) | Out-Null
$ll = Log-Lines $log
Check 'readfirst: a connection that sent nothing -> exactly one CLOSE reason=read-first-empty line naming the peer' `
      (@($ll | Where-Object { $_ -like '*CLOSE reason=read-first-empty peer=svchost (pid 4242)' }).Count -eq 1)
Check 'readfirst: the relay closed its side (nothing waits on an empty connection)' (-not $pair.server.Connected)

# --- 5. nochannel-plain: qrexec-client-vm cannot be started -> 403 + reason header + line, no 5xx --------------
$log = New-Log 'nochannel-plain'
$pair = New-Pair
Send-Bytes $pair.client $GET
$task = Invoke-Handle $pair.server 'svchost hosting wuauserv (pid 8908)' $log
$task.Wait(30000) | Out-Null
$resp = Split-Response (Read-All $pair.client 10000)
$ll = Log-Lines $log
Check 'nochannel-plain: no channel can be opened -> the client gets HTTP/1.1 403 Forbidden + X-Qubes-Relay: no-channel + Connection: close (not a bare close, not a 5xx)' `
      ($resp.headers.Count -gt 0 -and $resp.headers[0] -ceq 'HTTP/1.1 403 Forbidden' -and $resp.headers -ccontains 'X-Qubes-Relay: no-channel' -and $resp.headers -ccontains 'Connection: close')
Check 'nochannel-plain: one CLOSE reason=no-channel line naming the peer and the request' `
      (@($ll | Where-Object { Has $_ 'CLOSE reason=no-channel peer=svchost hosting wuauserv (pid 8908) - 403 to client req=[GET http://download.windowsupdate.com/' }).Count -eq 1)

# --- 6. nochannel-connect: the CONNECT path, which used to bare-close here ------------------------------------
$log = New-Log 'nochannel-connect'
$pair = New-Pair
Send-Bytes $pair.client "CONNECT fe3cr.delivery.mp.microsoft.com:443 HTTP/1.1`r`nHost: fe3cr.delivery.mp.microsoft.com:443`r`n`r`n"
$task = Invoke-Handle $pair.server 'svchost hosting wuauserv (pid 8908)' $log
$task.Wait(30000) | Out-Null
$resp = Split-Response (Read-All $pair.client 10000)
$ll = Log-Lines $log
Check 'nochannel-connect: CONNECT with no channel -> HTTP/1.1 403 Forbidden + X-Qubes-Relay: no-channel + Connection: close' `
      ($resp.headers.Count -gt 0 -and $resp.headers[0] -ceq 'HTTP/1.1 403 Forbidden' -and $resp.headers -ccontains 'X-Qubes-Relay: no-channel' -and $resp.headers -ccontains 'Connection: close')
Check 'nochannel-connect: one CLOSE reason=no-channel line naming the peer and the CONNECT request' `
      (@($ll | Where-Object { Has $_ 'CLOSE reason=no-channel peer=svchost hosting wuauserv (pid 8908) - 403 to client req=[CONNECT fe3cr.delivery.mp.microsoft.com:443' }).Count -eq 1)

# --- 7. deny: suppression counted, denied svchost named by its services, SCM asked only per written line ------------
$script:scmCalls = 0
$script:scmThrow = $false
$svcOfPid = [Func[int, string[]]]{
    param([int]$p)
    $script:scmCalls++
    if ($script:scmThrow) { throw [InvalidOperationException]::new('SCM unavailable (scripted)') }
    if ($p -eq 3468) { return [string[]]@('BITS', 'wuauserv') }
    return [string[]]@()
}
$T.GetField('_servicesOfPid', $bf).SetValue($null, $svcOfPid)
$log = New-Log 'deny'
$t0 = [DateTime]::new(2026, 9, 17, 20, 46, 23, [DateTimeKind]::Utc)
for ($i = 0; $i -lt 18; $i++) { Invoke-Deny $log 'svchost (pid 3468)' 3468 $t0.AddSeconds($i * 0.2) }
$ll = Log-Lines $log
Check 'deny: 18 denials of one caller inside 4 s -> exactly ONE line' (@($ll | Where-Object { $_ -like '*DENY *' }).Count -eq 1)
Check 'deny: the denied svchost is named by EVERY service its pid hosts ("svchost (pid 3468) hosting [BITS, wuauserv]")' `
      (@($ll | Where-Object { Has $_ 'DENY svchost (pid 3468) hosting [BITS, wuauserv] - not part of the update.' }).Count -eq 1)
Check 'deny: the SCM was asked once (per written line), not 18 times' ($script:scmCalls -eq 1)
Invoke-Deny $log 'svchost (pid 3468)' 3468 $t0.AddSeconds(61)
$ll = Log-Lines $log
$DENYCOUNT = 'deny: the next denial after the 60 s window -> "x17 suppressed" for the window that closed, then a fresh DENY line'
$idxCount = -1; $idxNext = -1
for ($i = 0; $i -lt $ll.Count; $i++) {
    if ($ll[$i] -like '*DENY svchost (pid 3468) x17 suppressed - repeats within 60 s of the last DENY line for this caller') { $idxCount = $i }
    elseif ($idxCount -ge 0 -and $idxNext -lt 0 -and (Has $ll[$i] 'DENY svchost (pid 3468) hosting [BITS, wuauserv] - not part of the update.')) { $idxNext = $i }
}
Check $DENYCOUNT ($idxCount -ge 0 -and $idxNext -gt $idxCount -and $script:scmCalls -eq 2)
# a burst that nothing follows: only the periodic flush can count it
for ($i = 0; $i -lt 5; $i++) { Invoke-Deny $log 'OneDrive (pid 9)' 9 $t0.AddSeconds(100 + $i) }
Invoke-DenyFlush $log $t0.AddSeconds(130)
$before = @(Log-Lines $log | Where-Object { $_ -like '*OneDrive (pid 9) x*' }).Count
Invoke-DenyFlush $log $t0.AddSeconds(161)
$ll = Log-Lines $log
Check 'deny: a burst nothing follows -> DenyFlush writes "x4 suppressed" once the window is 60 s old, and not before' `
      ($before -eq 0 -and @($ll | Where-Object { $_ -like '*DENY OneDrive (pid 9) x4 suppressed - repeats within 60 s of the last DENY line for this caller' }).Count -eq 1)
Check 'deny: a caller with no hosted services carries no "hosting" suffix' `
      (@($ll | Where-Object { $_ -like '*DENY OneDrive (pid 9) - not part of the update.*' }).Count -eq 1)
$script:scmThrow = $true
$suffix = $M['HostedSuffix'].Invoke($null, [object[]]@([int]3468))
Check "deny: an SCM failure is named on the line, never thrown into the accept loop ('$suffix')" `
      ($suffix -clike ' (hosted services unreadable: *Exception)')   # the delegate's throw reaches C# wrapped by PowerShell; the NAME of the wrapper is what the line carries
$script:scmThrow = $false

# --- 8. the relay's own canned framing contract, case 1 (the spilled header block) --------------------------
# Relay.SelfTest as a whole needs Windows (U5 drives the TCP-table P/Invoke), so its first case is replayed
# here byte-for-byte through the same ReadResponse(Stream, Stream) with the same expectations the shipped
# --selftest now asserts: whole body, header block 5 bytes shorter (keep-alive -> close), says close.
$rr = $T.GetMethod('ReadResponse', $bf, $null, [Type[]]@([IO.Stream], [IO.Stream]), $null)
$bigN = 20 * 1024 * 1024
$in1 = $latin1.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $bigN`r`nConnection: keep-alive`r`n`r`n")
$r1in = [byte[]]::new($in1.Length + $bigN); [Buffer]::BlockCopy($in1, 0, $r1in, 0, $in1.Length)
$c1 = [IO.MemoryStream]::new()
$r1 = $rr.Invoke($null, [object[]]@([IO.MemoryStream]::new($r1in), $c1)).Result
$c1b = $c1.ToArray()
$c1hdr = $latin1.GetString($c1b, 0, [Math]::Min($c1b.Length, 200))
Check "selftest-large: the canned 20 MB spill delivers the whole response with the header block rewritten ($($c1b.Length)/$($r1in.Length - 5), streamed=$($r1.Streamed))" `
      ($r1.Streamed -and $r1.Complete -and $c1b.Length -eq ($r1in.Length - 5) -and $c1hdr.IndexOf("`r`nConnection: close`r`n") -gt 0 -and $c1hdr.IndexOf('keep-alive') -lt 0)

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("--- {0} checks, {1} failed (culture {2}, defect '{3}')" -f $script:run, $script:fail, [cultureinfo]::CurrentCulture.Name, $Defect)
if ($script:fail -gt 0) { exit 1 }
exit 0
