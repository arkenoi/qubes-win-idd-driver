<#
.SYNOPSIS
  Fetch the same URL through qubes.UpdatesProxy with OUR RELAY REMOVED FROM THE PATH.

.DESCRIPTION
  The relay's instrumentation says it is faithful, but the relay is still our code. This drives
  qrexec-client-vm directly with a primitive local program (proxy-probe.exe: synchronous, no pool,
  no drain, no teardown race), so a short response here cannot be blamed on anything we wrote.

  Run BEFORE reporting anything upstream. The two outcomes are opposite:
    * truncation persists -> the loss is in qubes.UpdatesProxy / tinyproxy, independent of QWT
    * truncation disappears -> it is our relay after all, and the handler instrumentation misled us

  Reports the FULL body length, and separately the length of the HTTP body after the headers, so a
  short read cannot hide behind header bytes. The reference length is what the same file is served
  as elsewhere: 80043 body bytes.
#>
param([int]$Repeats = 6, [string]$Target = '@default')
$ErrorActionPreference = 'Continue'
$wu    = 'C:\ProgramData\Qubes\wu'
$probe = Join-Path $wu 'proxy-probe.exe'
$qrx   = 'C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe'
if (-not (Test-Path $qrx)) { $qrx = (Get-ChildItem 'C:\Program Files\Qubes Tools' -Recurse -Filter 'qrexec-client-vm.exe' -EA SilentlyContinue | Select-Object -First 1).FullName }
Write-Output '=== RESULT ==='
if (-not (Test-Path $probe)) { Write-Output "proxy-probe.exe missing at $probe"; exit 1 }
if (-not $qrx -or -not (Test-Path $qrx)) { Write-Output 'qrexec-client-vm.exe not found'; exit 1 }
Write-Output ("qrexec-client-vm: {0}" -f $qrx)

# Plain-HTTP proxy request, exactly the shape Windows' CTL fetch uses. Connection: close so the
# upstream signals end-of-body by closing - removing keep-alive framing from the equation.
$host0 = 'ctldl.windowsupdate.com'
$path0 = '/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
$req   = "GET http://$host0$path0 HTTP/1.1`r`nHost: $host0`r`nUser-Agent: qwt-probe`r`nConnection: close`r`n`r`n"
$reqFile = Join-Path $wu 'probe-req.txt'
[IO.File]::WriteAllText($reqFile, $req, (New-Object Text.ASCIIEncoding))

$sizes = @(); $bodies = @(); $fails = 0
for ($i = 1; $i -le $Repeats; $i++) {
    $out  = Join-Path $wu ("probe-resp-$i.bin")
    Remove-Item -LiteralPath $out, ($out + '.meta') -Force -EA SilentlyContinue
    # Pipe-delimited, UNQUOTED as a whole: qrexec-client-vm splits the RAW command line on '|' and
    # does not strip quotes, so wrapping it leaks a quote into the target field.
    $argline = "$Target|qubes.UpdatesProxy|user|`"$probe`" `"$reqFile`" `"$out`""
    $p = Start-Process -FilePath $qrx -ArgumentList $argline -NoNewWindow -Wait -PassThru
    Start-Sleep -Milliseconds 400
    if (Test-Path $out) {
        $len = (Get-Item $out).Length
        $sizes += $len
        # Split headers from body so a short body cannot hide behind header bytes.
        $bytes = [IO.File]::ReadAllBytes($out)
        $txt = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(2048, $bytes.Length))
        $sep = $txt.IndexOf("`r`n`r`n")
        $bodyLen = if ($sep -ge 0) { $bytes.Length - ($sep + 4) } else { -1 }
        $bodies += $bodyLen
        $status = if ($txt -match '^HTTP/\S+ (\d+)') { $Matches[1] } else { '?' }
        Write-Output ("run {0}: rc={1} total={2,-8} http={3} body={4}" -f $i, $p.ExitCode, $len, $status, $bodyLen)
    } else {
        $fails++
        Write-Output ("run {0}: rc={1} NO OUTPUT FILE" -f $i, $p.ExitCode)
    }
    Remove-Item -LiteralPath $out -Force -EA SilentlyContinue
}
Write-Output '--- summary (relay NOT in the path) ---'
Write-Output ("distinct total sizes : {0}" -f (($sizes | Sort-Object -Unique) -join ', '))
Write-Output ("distinct BODY sizes  : {0}" -f (($bodies | Sort-Object -Unique) -join ', '))
Write-Output ("failures = {0} of {1}   reference body length = 80043" -f $fails, $Repeats)
$full = @($bodies | Where-Object { $_ -eq 80043 }).Count
Write-Output ("full-length bodies = {0}/{1}" -f $full, $Repeats)
if ($full -eq $Repeats) { Write-Output 'CLEAN without our relay => the relay IS implicated after all' }
else { Write-Output 'TRUNCATED without our relay => the loss is in qubes.UpdatesProxy / tinyproxy' }
