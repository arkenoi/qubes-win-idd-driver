<#
.SYNOPSIS
  Qubes Windows Update agent (QWT-NG). Windows Update over the Qubes UpdatesProxy with ZERO guest
  networking.

.DESCRIPTION
  Windows' online update engine (DO -> BITS) gates on IsNetworkAlive and refuses to run on a
  routeless guest (error 0x80200010) - and no loopback/NCSI trick satisfies it (proven). So this
  agent uses "Path B", the offline-servicing route, which has no such gate:

     scan (WU COM search, proxy-aware)  ->  resolve the standalone .msu from the Microsoft Update
     Catalog (over the proxy)  ->  fetch it over the proxy (resumable)  ->  install offline (DISM).

  Everything rides the qubes-updates-relay (127.0.0.1:8082 -> qrexec qubes.UpdatesProxy), so the
  guest needs no IP networking. Throughout, it writes a structured status JSON (availability +
  progress) for dom0 to poll - the north-star: report availability + progress to dom0, non-blocking.

.NOTES
  Consolidates the proven prototype scripts (wu-enumerate / wu-catalog-get / wu-full-install).
  dom0 reporting (qubes.NotifyUpdates + a progress channel) is a thin layer on top of the status
  file - added once the dom0 policy is placed.

.PARAMETER Action  scan | download | install | full
#>
[CmdletBinding()]
param(
  [ValidateSet('scan','resolve','download','install','full','wuinstall')][string]$Action = 'scan',
  [string]$Proxy      = 'http://127.0.0.1:8082',
  [string]$RelayExe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$WorkDir    = 'C:\ProgramData\Qubes\wu',
  [string]$StatusFile = 'C:\ProgramData\Qubes\update-status.json',
  # Restrict a pass to specific KBs (e.g. -OnlyKb KB5120710). Diagnostic control, not a policy
  # knob: a normal dom0-driven pass passes nothing and takes everything offered. It exists so a
  # multi-gigabyte cumulative and a small package can be tested one at a time rather than as an
  # all-or-nothing batch - the batch is precisely what made the 24H2 failure unattributable.
  [string[]]$OnlyKb   = @(),
  # Force the catalog to answer in a given language, e.g. -AcceptLanguage de-DE. Diagnostic.
  # Exists because the catalog's response language is NOT under our control and has been measured
  # varying by itself (same KB, same guest, German at 09:54 and English at 10:21 on 2026-08-14),
  # while the row-picking logic matches on title text. A real user runs a German edition, so
  # "does resolution still pick the same FILE when the titles are German" has to be answerable on
  # an English guest - this is what makes it answerable.
  [string]$AcceptLanguage = ''
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $StatusFile) | Out-Null

# ONE update operation at a time. The scheduled scan, the dom0-driven run and the download task
# are separate tasks writing ONE status file and sharing ONE proxy, and they collided for real
# (2026-08-13): the 6-hourly scan fired 6 minutes into a dom0-driven install, rewrote the status
# file with its own `done`, and the rpc handler tailing that file reported the update finished -
# with an empty result - while DISM was still installing. The scan's Remove-Proxy also tears down
# the proxy the other pass is downloading through.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\QubesWindowsUpdate')
$waitMs = if ($Action -eq 'scan') { 0 } else { 900000 }   # a scan yields; real work waits 15 min
$script:HaveMutex = $false
try { $script:HaveMutex = $script:Mutex.WaitOne($waitMs) } catch [System.Threading.AbandonedMutexException] { $script:HaveMutex = $true }
if (-not $script:HaveMutex) {
    Write-Host "another Qubes update operation is in progress - skipping this $Action"
    exit 0
}
New-Item -ItemType Directory -Force $WorkDir | Out-Null
# Legacy flat layout: .msu directly in the work dir. They are what DISM dragged into an unrelated
# servicing session, and they belong to no known KB now, so drop them once.
foreach($stale in @(Get-ChildItem (Join-Path $WorkDir '*.msu') -EA SilentlyContinue)) {
    Remove-Item -LiteralPath $stale.FullName -Force -EA SilentlyContinue
}
# WHICH catalog package applies is a property of THIS guest, not a constant. Hardcoding
# "x64 + 24H2|26100" made KB5120708 unresolvable on 25H2, where the applicable entry is titled
# "... for Windows 11, version 25H2 for x64" - the scan offered it and nothing could install it.
$__cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
$OsVer   = $__cv.DisplayVersion          # e.g. 25H2
$OsBuild = $__cv.CurrentBuild            # e.g. 26200
$OsArch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

$IS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'

$script:St = [ordered]@{ action=$Action; phase='init'; ts=$null; count=0; available=@();
                         downloading=$null; installing=$null; result=@(); reboot_needed=$false; error=$null }
function Save { $script:St.ts=(Get-Date).ToString('s'); ($script:St | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile -Encoding UTF8 }
# Write-Host alone is lost under the scheduled task, which is why every download failure so far
# had to be reconstructed from DISM's log instead of ours. Tee to a file.
function Log($m){
  $line = (Get-Date -Format 'HH:mm:ss')+' '+$m
  Write-Host $line
  try { Add-Content -LiteralPath (Join-Path $WorkDir 'agent.log') -Value $line -EA SilentlyContinue } catch {}
}
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# The proxy is up ONLY for the duration of a pass. Leaving the system-wide WinHTTP proxy set
# turns the relay into an always-on escape hatch: every Windows background HTTP client (telemetry,
# Edge/Defender update checks, NCSI, DO) discovers it and phones home, each connection spawning a
# qrexec qubes.UpdatesProxy call - measured 147 dom0 policy hits in one afternoon on an "offline"
# guest, still dripping hours after the last scan. Remove-Proxy in the finally below restores the
# routeless baseline; update traffic is the only traffic that ever gets a path out.
function Test-RelayListening {
  # Does something ACCEPT a TCP connection on 127.0.0.1:8082 within 3 s? A relay PROCESS existing
  # does not prove the port is being serviced (a hung/dead relay, or a squatter, yields
  # 0x80072EFD ERROR_INTERNET_CANNOT_CONNECT). This catches the proven-once failure the old
  # process-exists check missed.
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', 8082, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(3000)
    $res = ($ok -and $c.Connected)
    $c.Close(); return $res
  } catch { return $false }
}
function Start-Relay {
  if (-not (Test-Path -LiteralPath $RelayExe)) { throw "relay not found at $RelayExe" }
  $env:QUBES_UPDATES_MAXCONN='256'
  Start-Process -FilePath $RelayExe -ArgumentList '--listen','8082','--target','@default','--log',$WorkDir -WindowStyle Hidden
  Start-Sleep -Seconds 2
}
function Ensure-Proxy {
  & netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
  SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
  SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
  if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) { Start-Relay }
  # Serviceability probe: if nothing is accepting connections on 8082, kill any relay-named process
  # and respawn - a relay that exists but is not listening would otherwise fail the pass 0x80072EFD.
  if (-not (Test-RelayListening)) {
    Log 'relay not accepting connections on 127.0.0.1:8082 - killing any relay process and respawning' 'WARN'
    Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Relay
    if (-not (Test-RelayListening)) { throw 'relay still not accepting connections on 127.0.0.1:8082 after respawn' }
  }
}

# REVOCATION SYNC - without this, every pass on a guest whose CTL cache has expired dies at
# 0x80072F8F before its first byte of update metadata. Measured + root-caused 2026-08-19:
# schannel REQUIRES revocation on the WU endpoints, and Microsoft-rooted chains use
# AUTO-UPDATE (CTL) revocation - the chain elements carry CERT_TRUST_AUTO_UPDATE_*_REVOCATION
# and the engine wants a FRESH disallowedcertstl from ctldl.windowsupdate.com, NOT the CDP
# CRLs (store-imported, KeyID-matched, time-valid CRLs were measured to change nothing).
# CryptoAPI's own fetches go DIRECT (never through the relay; no DNS on a proxy-only guest),
# so the CTLs can only arrive if WE carry them: fetch through the relay (ctldl is on its
# domain allowlist; plain-HTTP rides the verified/retried path built for exactly these files
# on 2026-08-14), mirror them locally, point AuthRoot\AutoUpdate!RootDirURL at the mirror,
# and flush the chain cache. The cabs are Microsoft-SIGNED CTL containers - Windows validates
# them at use, so a corrupted/hostile body is inert, not a poisoning vector.
# Side effect, accepted: OS root-store auto-update now sources from the mirror, i.e. new
# Microsoft roots arrive when a pass refreshes the mirror (before this, they never arrived).
function Sync-Revocation {
  $dir = 'C:\ProgramData\QubesCTL'
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $proxy = 'http://127.0.0.1:8082'
  $got = 0
  foreach ($f in 'disallowedcertstl.cab','authrootstl.cab','pinrulesstl.cab') {
    # 2 attempts, 3 s apart: the relay's accept loop can lag its Start-Process by a few
    # seconds (warm-channel pool), and one connect-refused was measured to cost a whole pass.
    foreach ($try in 1..2) {
      try {
        Invoke-WebRequest -Uri "http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/$f" `
          -Proxy $proxy -OutFile "$dir\$f.new" -UseBasicParsing -TimeoutSec 60
        Move-Item "$dir\$f.new" "$dir\$f" -Force
        $got++
        break
      } catch {
        Remove-Item "$dir\$f.new" -Force -EA SilentlyContinue
        if ($try -eq 2) { Log "Sync-Revocation: $f fetch failed ($($_.Exception.Message)) - keeping existing copy" 'WARN' }
        else { Start-Sleep -Seconds 3 }
      }
    }
  }
  SetV 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' 'RootDirURL' "file://$dir" 'String'
  foreach ($v in 'DisallowedCertLastSyncTime','LastSyncTime','PinRulesLastSyncTime') {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name $v -EA SilentlyContinue
  }
  # quoted deliberately: bare @now is PowerShell splatting and silently drops the argument
  & certutil -setreg 'chain\ChainCacheResyncFiletime' '@now' | Out-Null
  Log "Sync-Revocation: $got/3 CTLs refreshed through the relay, chain cache flushed"
}

# TEMPORAL GATE - still required, and not superseded by the relay's positional one.
# The relay now refuses any caller that is not the update process, which closes the leak this
# comment block describes. That check lives in our code and depends on our own process-identity
# logic being right; this teardown does not. Keeping both means a mistake in either one is
# bounded by the other: a wrong allowlist is still limited to the minutes a pass runs, and a
# pass left open still serves nobody but the update. Do not remove this because the other exists.
function Remove-Proxy {
  & netsh winhttp reset proxy | Out-Null
  SetV $IS 'ProxyEnable' 0 'DWord'
  Remove-ItemProperty -Path $IS -Name 'ProxyServer' -EA SilentlyContinue
  Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
  Log 'proxy removed, relay stopped (offline baseline restored)'
}

# Report the available-update count to dom0's qubes.NotifyUpdates (target: bare dom0).
# THIS build of qrexec-client-vm.exe takes ONE pipe-delimited command line "domain|service|user|
# local program [args]" and TRIGGERS the service, running the local program whose STDOUT is the
# vchan to the service - so the count is EMITTED by the local program (cmd /c echo N), NOT piped
# to stdin (stdin never crosses). dom0's qubes-notify-updates .strip()s the line so CRLF is fine.
#
# CRITICAL quoting: qrexec-client-vm's GetArgument() splits the RAW command line on '|' and does
# NOT strip quotes. Wrapping the whole "domain|...|prog" in double quotes therefore leaks a literal
# quote into the target field -> domain parses as "dom0, a VM that does not exist, and the daemon
# REFUSES it (proven: quoted -> HandleServiceRefused; unquoted -> accepted, flag set). PowerShell
# re-quotes any single arg containing spaces, so pass SPLIT tokens: the first (no spaces) is emitted
# verbatim with literal pipes; '/c' 'echo' $count append space-separated -> field4 = "cmd /c echo N".
function Report-Availability($count){
  $qr='C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe'
  if(-not(Test-Path $qr)){ Log 'qrexec-client-vm.exe not found - cannot report to dom0'; return }
  try { & $qr 'dom0|qubes.NotifyUpdates|user|cmd' '/c' 'echo' "$count" 2>&1 | Out-Null
        Log "reported $count update(s) to dom0 qubes.NotifyUpdates (exit $LASTEXITCODE)" }
  catch { Log "qubes.NotifyUpdates report failed: $($_.Exception.Message)" }
}

# Classify an offered IUpdate by the SHAPE of its published download content, WITHOUT a network
# round-trip, so the router can decide whether it is installable NLA-free. Proven separable on live
# scan data (scratchpad/dc-probe.ps1, 2026-08-20): self-contained updates carry a static
# download.windowsupdate.com URL with no query string (Defender mpam-fe.exe, MSRT, SSU, .NET .cab);
# express/UUP cumulatives (KB5071959) carry thousands of time-signed
# tlu.dl.delivery.mp.microsoft.com/filestreamingservice delta streams that ONLY Delivery Optimization
# can assemble - and DO refuses routeless (measured 0x80D03805), so those are terminally classified,
# not chased. Static WINS if any static URL exists; the walk is bounded (a self-contained payload
# appears in the first handful) so an express update's 8496 streams are never enumerated.
function Get-WuContentClass($u){
  $static=@(); $expressSeen=$false; $total=0
  $items=@($u); try{ $items += @($u.BundledUpdates) }catch{}
  foreach($b in $items){
    $dcc=$null; try{ $dcc=$b.DownloadContents }catch{}
    if(-not $dcc){ continue }
    $n=0
    foreach($dc in $dcc){
      $n++; $total++
      $url=$null; try{ $url=$dc.DownloadUrl }catch{}
      if($url){
        if($url -match 'filestreamingservice|tlu\.dl\.delivery\.mp\.microsoft\.com'){ $expressSeen=$true }
        else{
          # A DELTA patch (Defender am_delta_patch_*.exe) is NOT self-contained: it needs the current
          # engine as its base and cannot self-apply offline (measured 0x80070002 for bare run AND /q;
          # the FULL mpam-fe is DO-only, MpCmdRun -SignatureUpdate uses DO). Exclude it so Defender is
          # classified terminally (honest) rather than fail-attempting an unapplicable patch. WU's
          # IsDeltaCompressedContent is FALSE for these, so filter on the name too.
          $isDelta=$false; try{ $isDelta=[bool]$dc.IsDeltaCompressedContent }catch{}
          if((-not $isDelta) -and $url -notmatch 'delta' -and $url -match '^https?://[^/]*download\.windowsupdate\.com/' -and $url -notmatch '\?'){ $static += $url }
        }
      }
      if($n -ge 64){ break }
    }
    if($static.Count -gt 0 -and $expressSeen){ break }
  }
  if($static.Count -gt 0){ return @{ class='self-contained'; urls=@($static | Sort-Object -Unique) } }
  if($expressSeen -or $total -gt 50){ return @{ class='express'; urls=@() } }
  return @{ class='none'; urls=@() }
}

function Get-Available {
  $s=New-Object -ComObject Microsoft.Update.Session
  $se=$s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
  $r=$se.Search("IsInstalled=0 and IsHidden=0")
  $out=@()
  foreach($u in $r.Updates){
    $kb=@($u.KBArticleIDs)|Select-Object -First 1; $kb= if($kb){"KB$kb"}else{'(no KB)'}
    $cls = Get-WuContentClass $u    # content class + any static URLs, computed while the IUpdate is live
    $out += [ordered]@{ kb=$kb; title="$($u.Title)"; size_mb=[math]::Round($u.MaxDownloadSize/1MB,1); downloaded=[bool]$u.IsDownloaded; content_class=$cls.class; direct_urls=@($cls.urls) }
  }
  return ,$out
}

# WU-NATIVE INSTALL - RETAINED AS A FALLBACK ONLY. Do not restore it as the default.
#
# CORRECTED 2026-08-14. This block used to say the catalog+DISM path "cannot service every image",
# citing KB5121003 being staged (rc=3010) and then ROLLED BACK at boot with 0x80070490 /
# CBS_E_INVALID_PACKAGE, and calling kb5043080 its "checkpoint prerequisite". That diagnosis was
# WRONG and the conclusion drawn from it was backwards. kb5043080 is not a prerequisite: it is a
# SUPERSEDED 2024-09 cumulative that the catalog bundles with the download, DISM rejects as not
# applicable (rc=552), and whose rejection poisons the CBS transaction the real cumulative then
# rides into. Dropping it BEFORE download makes the same image, the same package and the same DISM
# path install cleanly: verified 26100.8875 -> 26100.9168 with KB5043080 never present.
#
# So the catalog path does decide correctly which package an image needs - it just must not hand
# CBS the ones it does not.
#
# The searcher already runs online through our proxy (Get-Available), so the same session's
# downloader and installer can too. Delivery Optimization is forced into simple mode first,
# because DO does its own peer/CDN transport and does not reliably honour the WinHTTP proxy that
# Ensure-Proxy sets - and a qube has no other way out.
# Put Delivery Optimization back exactly as it was. MUST be reachable from every exit of
# Install-ViaWU: the first version restored it just before building the result rows, and the
# "WU: nothing to install" early return skipped it - measured, DODownloadMode=99 was still set
# on the guest afterwards. A policy this code sets for its own convenience must not outlive it.
function Restore-DoPolicy {
  if (-not $script:DoRestore) { return }
  try {
    if ($script:DoRestore.Had) { SetV $script:DoRestore.Key 'DODownloadMode' $script:DoRestore.Value 'DWord' }
    else { Remove-ItemProperty -LiteralPath $script:DoRestore.Key -Name 'DODownloadMode' -Force -EA SilentlyContinue }
    Log 'Delivery Optimization: restored'
  } catch { Log "could not restore DODownloadMode: $($_.Exception.Message)" }
  $script:DoRestore = $null
}

function Install-ViaWU {
  # $OnlyKbs limits the pass to specific KBs. Used as the FALLBACK for updates the Update
  # Catalog cannot serve: Defender definitions and the Malicious Software Removal Tool are not
  # .msu packages at all, so Resolve-Catalog will never find them, and without this they are
  # reported failed on every pass forever - dom0 keeps showing updates that can never clear.
  param([string[]]$OnlyKbs = @(), [bool]$TunePolicies = $true)
  # Delivery Optimization: no peering (99 = simple), and no background throttling. A qube's only
  # path out is the updates proxy, which is up ONLY during this pass, so there is nothing to be
  # polite to - the usual reason WU downloads slowly in the background does not apply here.
  #
  # These are MACHINE-WIDE POLICY writes and they persist. That was an acceptable price when
  # this function was an opt-in path for multi-gigabyte cumulatives. It is NOT acceptable on the
  # non-catalog fallback, which fires on almost every pass - Defender definitions are published
  # several times a day - and would leave every guest's Delivery Optimization and BITS policy
  # rewritten as a side effect of routine definition updates. The fallback passes $false: a few
  # megabytes of definitions do not need the transport tuned.
  # $TunePolicies=$false was a blunt answer to "do not leave machine policy rewritten": it also
  # gave up DODownloadMode=99, and Delivery Optimization does NOT reliably honour the WinHTTP
  # proxy in its default mode - which is the whole reason this block exists. A qube has no other
  # way out, so an unset DO can simply fail to download. Set the policy for the duration of the
  # pass and PUT IT BACK afterwards: reliability without a permanent change.
  $script:DoRestore = $null
  if (-not $TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $prev = $null
    try { $prev = (Get-ItemProperty -LiteralPath $DO -Name DODownloadMode -EA Stop).DODownloadMode } catch { }
    $script:DoRestore = @{ Key = $DO; Had = ($null -ne $prev); Value = $prev }
    SetV $DO 'DODownloadMode' 99 'DWord'
    Log 'Delivery Optimization: DODownloadMode=99 for THIS pass only (restored at the end)'
  }
  if ($TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    SetV $DO 'DODownloadMode'                      99 'DWord'
    SetV $DO 'DOPercentageMaxBackgroundBandwidth' 100 'DWord'
    SetV $DO 'DOPercentageMaxForegroundBandwidth' 100 'DWord'
    SetV $DO 'DOMaxBackgroundDownloadBandwidth'     0 'DWord'   # 0 = unlimited
    SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS' 'EnableBITSMaxBandwidth' 0 'DWord'
    Log 'Delivery Optimization: simple mode, no background throttle (proxy is up only for this pass)'
  }

  try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2; $searcher.Online = $true
    $script:St.phase='scan'; Save
    $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
    if ($found.Updates.Count -eq 0) { Log 'WU: nothing to install'; return @() }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
      if ($OnlyKbs.Count -gt 0) {
        $kbs = @($u.KBArticleIDs) | ForEach-Object { "KB$_" }
        if (-not (@($kbs | Where-Object { $OnlyKbs -contains $_ }).Count -gt 0)) { continue }
      }
      if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
      [void]$coll.Add($u)
      Log ("WU: selected " + $u.Title)
    }
    if ($coll.Count -eq 0) { Log 'WU: nothing matched the requested KBs'; return @() }
    $script:St.count = $coll.Count; Save

    $script:St.phase='download'; Save
    $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $coll
    # dpHigh: WU downloads at background priority by default and paces itself accordingly -
    # measured bursts every ~3.5 s with idle gaps, while each connection sustained ~840 KB/s.
    try { $downloader.Priority = 3 } catch { Log '  (downloader does not accept Priority)' }
    Log "WU: downloading $($coll.Count) update(s) through the proxy"
    $dres = $downloader.Download()
    Log "WU: download ResultCode=$($dres.ResultCode) HResult=$($dres.HResult)"

    # Install only what actually downloaded; asking WU to install a missing payload just fails.
    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $coll) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
    if ($ready.Count -eq 0) { Log 'WU: nothing downloaded - not installing'; return @() }

    $script:St.phase='install'; Save
    $installer = $session.CreateUpdateInstaller(); $installer.Updates = $ready
    Log "WU: installing $($ready.Count) update(s)"
    $ires = $installer.Install()
    Log "WU: install ResultCode=$($ires.ResultCode) RebootRequired=$($ires.RebootRequired)"
    if ($ires.RebootRequired) { $script:St.reboot_needed = $true }

    # ResultCode: 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted.
    $rows = @()
    for ($i = 0; $i -lt $ready.Count; $i++) {
      $u = $ready.Item($i)
      $r = $ires.GetUpdateResult($i)
      $kb = @($u.KBArticleIDs) | Select-Object -First 1
      $rows += [ordered]@{ kb = $(if ($kb) { "KB$kb" } else { '(no KB)' })
                           ok = ($r.ResultCode -in @(2, 3))
                           files = @([ordered]@{ file = "$($u.Title)"; rc = $r.ResultCode; hr = $r.HResult }) }
      Log ("WU:   $($u.Title) -> ResultCode=$($r.ResultCode) HResult=$($r.HResult)")
    }
    return ,$rows
  } finally { Restore-DoPolicy }

}

# KB -> standalone .msu URLs from the Update Catalog (over the proxy), for THIS guest's
# architecture and Windows version.
#
# THE DECISION IS MADE ON THE FILENAME, NOT ON THE TITLE. Rewritten 2026-08-14 because the old
# version chose a row by matching ENGLISH words in its title, and the catalog's response language
# is not ours to choose: asking for fr-FR returned an ITALIAN title, and the same KB on the same
# guest came back German at 09:54 and English at 10:21. A real user runs a German edition. So the
# title is now used only to NARROW and RANK candidates by tokens nobody translates - the arch
# ("x64"/"arm64") and the build/version number - while the actual accept/reject test is run against
# the .msu filename the catalog hands back, which is language-invariant by construction.
#
# Two ambiguities the old title matching could not survive, both real:
#   * DisplayVersion alone does not identify a product: Windows 10 AND Windows 11 both shipped a
#     "22H2". CurrentBuild does (19045 vs 22621), so the BUILD is ranked above the version now.
#   * Build alone does not separate client from server: Windows Server 2025 and Windows 11 24H2
#     are BOTH build 26100.
#
# CORRECTED 2026-08-14, measured: the filename family does NOT separate client from server.
# Server packages are ALSO named windows11.0-* - "Cumulative Update for Microsoft server operating
# system version 24H2 ... (KB5120233)" ships windows11.0-kb5120233-x64_9344....msu. An earlier
# version of this comment claimed Server 2025 used windows10.0-*; that was an assumption and it was
# wrong. What the family check DOES buy is separating Windows 10 packages from Windows 11 ones.
#
# The real client/server separator is the KB NUMBER, which is product-specific: the 24H2 cumulative
# is KB5121003 for client and KB5120233 for server; the .NET one is KB5120710 client, KB5120708
# server. So a KB-specific search returns product-specific rows - measured, KB5121003 returns four
# rows, all client (24H2/25H2 x x64/arm64), no server row at all. The English `Server` keyword was
# never what kept server packages out.
#
# Dynamic Updates cannot reach us either, for two measured reasons: they ship .cab, not .msu (the
# `\.msu` filter below drops them outright), and they carry their OWN KB numbers - Safe OS Dynamic
# Update is KB5121002 and Setup Dynamic Update is KB5106084, neither of which is KB5121003.
#
# Nothing here is pinned to a Windows version: arch, build, version and product family are all read
# from the running guest. Hardcoding "x64 + 24H2|26100" once made KB5120708 unresolvable on 25H2.
function Resolve-Catalog($kb){
  $hdr = @{}
  if ($AcceptLanguage) { $hdr['Accept-Language'] = $AcceptLanguage }
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
  $digits = $kb -replace '\D',''

  # Expected filename family for THIS guest, derived - never assumed. InstallationType is 'Client'
  # or 'Server'/'Server Core' and is not localized; 22000 is the Windows 11 build boundary, a
  # number rather than a name. Used as a PREFERENCE, not a hard requirement, so an unforeseen
  # future family degrades to "still picks a correctly-named package for this arch and KB".
  $instType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).InstallationType
  $wantFamily = if ($instType -like 'Client*' -and [int]$OsBuild -ge 22000) { 'windows11.0' } else { 'windows10.0' }

  # Rank candidates on untranslated tokens only. Arch is mandatory; build outranks version; the
  # old English keywords survive ONLY as a tie-breaker nudge and can no longer reject anything.
  $ranked = @()
  $all = @()
  foreach($m in $rx.Matches($r.Content)){
    $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
    $all += $t
    if($t -notmatch [regex]::Escape($OsArch)){ continue }
    $score = 0
    if($OsBuild -and $t -match [regex]::Escape($OsBuild)){ $score += 4 }
    if($OsVer   -and $t -match [regex]::Escape($OsVer))  { $score += 2 }
    if($score -eq 0){ continue }
    # Ranking hint ONLY - this can no longer reject anything, so a locale it fails to cover costs
    # ordering, not correctness. Stems, because the shared prefix is what survives translation:
    # 'Dynami' covers Dynamic/Dynamisch/dinamico/dynamique, and -match is case-insensitive so
    # 'Server' already catches German "Serverbetriebssystem" and Italian "sistema operativo
    # server" - but NOT French "serveur" or Spanish "servidor", hence those spelled out.
    # 'server operating system' is dropped as dead weight: 'Server' already matches it.
    #
    # ASCII ONLY, deliberately. A CJK stem here was mangled to '?a??a?' in transit and broke the
    # parse (ps-syntax-check caught it) - this file crosses qrexec/qtest and is written as ASCII,
    # so a non-ASCII literal is a syntax error waiting to happen. Since this is only a ranking
    # nudge, losing a script we cannot spell costs ordering, never correctness.
    if($t -match 'Dynami|Server|Serveur|Servidor|servidore'){ $score -= 3 }
    $ranked += [pscustomobject]@{ guid=$m.Groups[1].Value; title=$t; score=$score }
  }
  $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true})

  $fallback = $null
  foreach($c in $ranked){
    $json='[{"size":0,"languages":"","uidInfo":"'+$c.guid+'","updateID":"'+$c.guid+'"}]'
    try{
      $dl=Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
    }catch{ Log ("  candidate rejected (download dialog failed): " + $c.title); continue }
    $files=@([regex]::Matches($dl.Content,"url\s*=\s*'(http[^']+)'")|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -match '\.msu(\?|$)'}|Sort-Object -Unique)
    if(-not $files.Count){ Log ("  candidate rejected (no .msu): " + $c.title); continue }

    # THE test: does this candidate actually carry a package named for this KB and this arch?
    $named = @($files | Where-Object { $_ -match $digits -and $_ -match [regex]::Escape($OsArch) })
    if(-not $named.Count){
      Log ("  candidate rejected (no file named for $kb/$OsArch): " + $c.title)
      foreach($f in $files){ Log ("      had: " + (& { if($f -match '/([^/?]+\.msu)'){$Matches[1]} else {$f} })) }
      continue
    }
    $family = @($named | Where-Object { $_ -match [regex]::Escape($wantFamily) })
    if($family.Count){
      Log ("  catalog pick: " + $c.title)
      Log ("    matched on filename family $wantFamily + $kb + $OsArch (title language is irrelevant)")
      return $files
    }
    # Right KB and arch, wrong/unknown product family - keep as a fallback and look for better.
    if(-not $fallback){ $fallback = [pscustomobject]@{ files=$files; title=$c.title } }
    Log ("  candidate deferred (no $wantFamily file): " + $c.title)
  }

  if($fallback){
    Log ("  catalog pick (FALLBACK - no $wantFamily package found for this KB): " + $fallback.title)
    return $fallback.files
  }
  # Log every candidate: a resolution miss is otherwise invisible and looks like "no updates".
  Log "  no catalog entry matches arch=$OsArch ver=$OsVer build=$OsBuild family=$wantFamily; candidates:"
  foreach($c in $all){ Log "    - $c" }
  return @()
}

# Resumable fetch with progress into the status file, and with the two checks whose absence
# produced an unusable 5 GB file (2026-08-13, template): CBS rejected both packages with
# CBS_E_INVALID_PACKAGE, DISM logged "Failed to open ESD ... 0x8007000d" and a DPX range error
# 0xca00a005 - i.e. the bytes on disk were not a package at all.
#
# WHY IT COULD HAPPEN: the old version sent a Range header and then ALWAYS appended the response.
# A server (or the relay) that ignores the range and answers 200 with the WHOLE body appends a
# full copy onto the partial one, producing a file of plausible size and corrupt content. Nothing
# checked afterwards, so it went to DISM, "succeeded" with 3010, and was rolled back at boot.
#
# Now: a ranged request that comes back 200 restarts the file instead of appending; the expected
# total is taken from Content-Range when the server does honour the range; and the finished file
# is verified for BOTH size and the CAB magic (an .msu is a cabinet - "MSCF"), which is what
# catches an HTML error page or a truncated download. A file that fails verification is DELETED,
# never resumed - resuming corrupt bytes can only produce more corrupt bytes.
# Returns 'ok' | 'short' | 'bad'. The distinction matters more than it looks: treating a SHORT
# file as corrupt turns every dropped connection into a restart from zero, and a 4.8 GB package
# over a relay that drops around 3 GB then never completes - measured 2026-08-13, the download
# looped 3.18 GB -> deleted -> 0 bytes -> repeat.
function Test-Msu($path, $expect) {
  if (-not (Test-Path -LiteralPath $path)) { return 'bad' }
  $len = (Get-Item -LiteralPath $path).Length
  if ($len -eq 0) { return 'bad' }
  try {
    $fs = [IO.File]::OpenRead($path)
    $magic = New-Object byte[] 4
    $null = $fs.Read($magic, 0, 4)
    $fs.Close()
  } catch { return 'bad' }   # an UNREADABLE file is corrupt, not success: 'bad' (was $false, which matched no case)
  # An .msu is NOT always a cabinet. Classic packages start with 'MSCF', but recent Windows 11
  # cumulative updates ship as WIM containers starting with 'MSWIM' - measured 2026-08-13:
  # KB5121003's .msu begins 4D 53 57 49 4D. A CAB-only check rejected a perfectly good 4.8 GB
  # download and looped forever, which is worse than the problem it was added for. Accept both,
  # and keep the check only for what it is actually good at: catching an HTML error page.
  $isCab = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x43 -and $magic[3] -eq 0x46)
  $isWim = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x57 -and $magic[3] -eq 0x49)
  # A self-contained WU update can also be an executable (Defender mpam-fe.exe, MSRT
  # windows-kb890830-*.exe) - a valid PE starts 'MZ' (4D 5A). Accept it: an HTML error page still
  # begins '<' (0x3C), so this keeps catching garbage while letting Install-SelfContained fetch exes.
  $isExe = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A)
  if (-not ($isCab -or $isWim -or $isExe)) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is not MSCF/MSWIM/MZ - discarding"
    return 'bad'          # an HTML error page or garbage: resuming it can only make it worse
  }
  if ($expect -gt 0 -and $len -lt $expect) { return 'short' }   # incomplete: RESUME, do not delete
  if ($expect -gt 0 -and $len -gt $expect) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is $len bytes, expected $expect - discarding"
    return 'bad'          # longer than advertised = a body appended onto a partial
  }
  return 'ok'
}

function Get-UrlSize($url){
  # Size WITHOUT fetching a body, so "what would this cost" is answerable before committing to it.
  # Two ways, because CDNs are inconsistent: HEAD first, then a one-byte ranged GET whose
  # Content-Range trailer carries the full length. Returns -1 when neither works - callers must
  # print that as unknown rather than silently reporting 0, which would read as "free".
  foreach($method in 'HEAD','GET'){
    try{
      $r=[System.Net.HttpWebRequest]::Create($url); $r.Proxy=New-Object System.Net.WebProxy($Proxy)
      $r.Timeout=30000; $r.Method=$method
      if($method -eq 'GET'){ $r.AddRange(0,0) }
      $resp=$r.GetResponse()
      $len=-1
      $cr=$resp.Headers['Content-Range']
      if($cr -and $cr -match '/(\d+)\s*$'){ $len=[int64]$Matches[1] }
      elseif($resp.ContentLength -gt 0){ $len=[int64]$resp.ContentLength }
      $resp.Close()
      if($len -ge 0){ return $len }
    }catch{ }
  }
  return -1
}

function Fetch-Msu($url,$dst,$kb){
  # Throughput is a first-class output here, not a nicety: every rate figure recorded for this
  # tunnel so far was taken while the guest was also talking to telemetry endpoints the proxy
  # allowlist now blocks, so none of them describe the shipping configuration. Log bytes and
  # wall time per attempt and let the numbers come from the real workload.
  # Measured against what was on disk when this call began, so a resumed download reports the
  # bytes IT moved rather than crediting itself with an earlier attempt's progress.
  $tStart = Get-Date
  $startLen = if (Test-Path $dst) { (Get-Item $dst).Length } else { 0 }
  # 14 attempts, not 8: the relay intermittently churns its warm channel and a fresh GetResponse can
  # time out with zero bytes (measured on the 85 MB MSRT self-contained fetch - attempts stalled, then
  # resumed 16 -> 32 MB). Since each attempt RESUMES from bytes-on-disk, a large file completes across
  # more attempts even when individual ones abort. GetResponse timeout raised 60->90s to give a slow
  # relay response more room before aborting an otherwise-good attempt.
  for($a=1;$a -le 14;$a++){
    $have=0; if(Test-Path $dst){$have=(Get-Item $dst).Length}; $o=$null; $expect=0
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($Proxy)
      $req.Timeout=90000; $req.ReadWriteTimeout=180000
      $asked=$false; if($have -gt 0){ $req.AddRange($have); $asked=$true }
      $resp=$req.GetResponse()

      # Did the server honour the range? 206 = yes, resume. Anything else = start over.
      $status=[int]$resp.StatusCode
      $append=$false
      if($asked -and $status -eq 206){
        $append=$true
        $cr=$resp.Headers['Content-Range']
        if($cr -and $cr -match '/(\d+)\s*$'){ $expect=[int64]$Matches[1] } else { $expect=$have+$resp.ContentLength }
      } else {
        if($asked){ Log "  server ignored the resume range (HTTP $status) - restarting the download" }
        $have=0; $expect=$resp.ContentLength
      }

      $mode = if($append){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
      $in=$resp.GetResponseStream()
      $o=[System.IO.File]::Open($dst,$mode); $buf=New-Object byte[] (1048576); $last=Get-Date
      while(($n=$in.Read($buf,0,$buf.Length)) -gt 0){ $o.Write($buf,0,$n); $have+=$n
        if(((Get-Date)-$last).TotalSeconds -ge 3){ $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($expect/1MB,1);pct=[math]::Round(100*$have/[math]::Max($expect,1),1)}; Save; $last=Get-Date } }
      $o.Close();$in.Close();$resp.Close()

      $verdict = Test-Msu $dst $expect
      if($verdict -eq 'bad'){
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue   # never resume corrupt bytes
        Log "  attempt ${a}: file is not a package - discarded, restarting"
        Start-Sleep 5
        continue
      }
      if($verdict -eq 'short'){
        Log "  attempt ${a}: stream ended early at $([math]::Round($have/1MB,1)) of $([math]::Round($expect/1MB,1)) MB - resuming"
        Start-Sleep 5
        continue                                                    # keep the bytes, resume them
      }
      $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
      $bytesThisRun = $have - $startLen
      $secs = [math]::Max(((Get-Date) - $tStart).TotalSeconds, 0.001)
      Log ("  THROUGHPUT {0}: {1:N1} MB fetched in {2:N0}s = {3:N0} KB/s (file now {4:N1} MB, {5} attempt(s))" -f `
           [IO.Path]::GetFileName($dst), ($bytesThisRun/1MB), $secs, ($bytesThisRun/1KB/$secs), ($have/1MB), $a)
      return $true
    }catch{
      if($o){try{$o.Close()}catch{}}
      # A complete local copy makes the server refuse the resume range with 416. That is
      # "already downloaded", not a failure - measured 2026-08-13: a re-run after a successful
      # pass burned all 8 attempts on 416 and reported the update as unresolvable.
      # PowerShell wraps a failing method call in a MethodInvocationException, so $_.Exception is
      # NOT the WebException - it is the wrapper. Unwrap it, and keep a text fallback: this check
      # silently did nothing the first time precisely because of that wrapping.
      $code=$null; $we=$_.Exception
      if($we -isnot [System.Net.WebException] -and $we.InnerException){ $we=$we.InnerException }
      if($we -is [System.Net.WebException] -and $we.Response){ $code=[int]$we.Response.StatusCode }
      if(-not $code -and $_.Exception.Message -match '\(416\)'){ $code=416 }
      if($code -eq 416 -and $have -gt 0){
        # Complete by the server's reckoning - but PROVE it. expect=0 skipped the SIZE check, so an
        # over-long corrupt-append file with valid leading magic slipped through. Verify magic AND
        # size against the server's true total (Get-UrlSize; -1 => magic-only, best effort).
        $srvTotal = Get-UrlSize $url
        if((Test-Msu $dst $srvTotal) -eq 'ok'){
          Log "  $([IO.Path]::GetFileName($dst)) already complete ($([math]::Round($have/1MB,1)) MB; server refused resume with 416)"
          $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
          return $true
        }
        Log "  local copy failed verification despite 416 (magic/size) - discarding and refetching"
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue
        continue
      }
      Log "  fetch attempt ${a}: $($we.Message)"; Start-Sleep 5 }
  }
  return $false
}

# DISM outcomes that mean "this package is now on the system": success, success-pending-reboot,
# and already-installed (0x240006). Anything else is a real failure for that FILE - though not
# necessarily for the KB, see the per-KB rule at the call site.
#
# NOTE: this definition was once deleted by a careless region replacement (the Fetch-Msu rewrite
# above), leaving $OK_RC undefined - so `$_.rc -in $OK_RC` was always false and EVERY install
# reported failure, including one that had returned 3010. Keep it adjacent to its only consumers.
$OK_RC = @(0, 3010, 2359302)
# Set the moment any package is STAGED (rc=3010). CBS applies exactly one staged session per
# boot; a second package staged behind the first is silently discarded, so the pass stops
# staging once this is true and the next pass picks up the rest after the reboot.
# Set QUBES_UPDATES_ALLOW_MULTISTAGE=1 to stage several packages anyway - Windows DOES aggregate
# packages per reboot normally, so the one-per-session rule rests on a single observation and must
# stay falsifiable. That variable is how the aggregation question gets re-tested.
# TEST HOOKS, same convention as the agent's SoloFaultInject: the multistage-defer guard only
# fires when a session has already staged a reboot-requiring package AND a non-catalog KB is
# still pending, and that combination cannot be summoned on a guest that is already up to date.
#   QUBES_UPDATES_FAKE_STAGED=1        pretend this session staged something
#   QUBES_UPDATES_FAKE_FALLBACK_KB=KB. pretend that KB needs the Windows Update fallback
# Both are dead code when unset.
$script:StagedThisSession = ($env:QUBES_UPDATES_FAKE_STAGED -eq '1')
if ($script:StagedThisSession) { Log 'QUBES_UPDATES_FAKE_STAGED=1 - pretending a reboot-requiring package is already staged' }

# ASK DISM WHETHER A PACKAGE APPLIES, BEFORE INSTALLING IT.
# Measured 2026-08-13/14 on a 24H2 image: the catalog returns SEVERAL .msu per KB, and we ran all
# of them. kb5043080 came back rc=552 and DISM's own log said "Not applicable ... Feature:
# CumulativeUpdate_KB5043080"; the real cumulative then staged (3010) and was ROLLED BACK at boot
# with 0x80070490 / CBS_E_INVALID_PACKAGE. Running an inapplicable package is not free - it can
# leave the servicing session in a state the applicable one cannot complete from.
#
# /Get-PackageInfo answers the question directly and changes nothing. Returns a hashtable:
#   applicable : Yes | No | unknown        state : Installed | Not Present | Install Pending | ...
#   identity   : the CBS package identity, which also tells us what KIND of package it is
function Get-MsuInfo($path){
  $out = & DISM /Online /Get-PackageInfo /PackagePath:"$path" /English 2>&1
  $info = @{ applicable='unknown'; state='unknown'; identity=''; rc=$LASTEXITCODE }
  foreach($l in $out){
    if($l -match '^\s*Applicable\s*:\s*(\S+)')       { $info.applicable = $Matches[1] }
    elseif($l -match '^\s*State\s*:\s*(.+?)\s*$')     { $info.state      = $Matches[1] }
    elseif($l -match '^\s*Package Identity\s*:\s*(\S+)'){ $info.identity  = $Matches[1] }
  }
  return $info
}

# Servicing order matters: a servicing-stack update must be installed BEFORE the cumulative that
# requires it, and the file size we used to sort by is only a proxy for that. The CBS identity
# names the kind, so order by it and fall back to size.
function Order-Msus($files){
  $ranked = @()
  foreach($f in $files){
    $id = ''
    try { $id = (Get-MsuInfo $f).identity } catch { $id = '' }
    $rank = 2                                             # default: everything else
    if($id -match 'ServicingStack|SSU')   { $rank = 0 }   # servicing stack first
    elseif($id -match 'Checkpoint')       { $rank = 1 }   # then any checkpoint package
    elseif($id -match 'RollupFix|LCU')    { $rank = 3 }   # cumulative last
    $ranked += [pscustomobject]@{ path=$f; rank=$rank; size=(Get-Item $f).Length; id=$id }
  }
  return ,@($ranked | Sort-Object rank, size | ForEach-Object { $_.path })
}

# DISM cannot ingest .msu on Win10 (measured 2026-08-19: rc=50 'request is not supported' on
# 19045 for both the LCU and the .NET package; the same call works on Win11 26100, where the
# whole catalog+DISM path was built and proven). And the WU-native path cannot replace it on
# a netvm-less guest: BITS/DO refuse jobs outright with no network interface present
# (0x80200010 BG_E_NETWORK_DISCONNECTED / 0x80D03805 - NLM sees no NIC; the loopback proxy
# does not count). So on rc=50 the .msu is EXPANDED (an .msu is a cab archive) and the inner
# .cab payloads go to DISM directly - the classic Win10 servicing shape. WSUSSCAN.cab is
# metadata, not a package; SSU-named cabs rank first (combined LCUs usually carry the SSU
# inside the main cab, where CBS orders it itself). rc reduction across cabs: any real
# failure wins, else 3010 if anything staged, else 0.
function Add-PackageCompat($f){
  & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
  $rc=$LASTEXITCODE
  if($rc -ne 50){ return $rc }
  $name=[IO.Path]::GetFileName($f)
  Log "  $name : DISM rc=50 (.msu unsupported on this OS) - expanding to cabs"
  $tmp = Join-Path $WorkDir ('msux-' + [IO.Path]::GetFileNameWithoutExtension($f).Substring(0, [Math]::Min(40, [IO.Path]::GetFileNameWithoutExtension($f).Length)))
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  & expand.exe -F:* "$f" "$tmp" | Out-Null
  $cabs = @(Get-ChildItem $tmp -Filter '*.cab' | Where-Object { $_.Name -ine 'WSUSSCAN.cab' } |
            Sort-Object @{e={ if($_.Name -match 'SSU'){0}else{1} }}, Length)
  if($cabs.Count -eq 0){ Log "  $name : expand produced no cabs"; Remove-Item $tmp -Recurse -Force -EA SilentlyContinue; return 50 }
  $worst=0; $staged=$false
  foreach($c in $cabs){
    & DISM /Online /Add-Package /PackagePath:"$($c.FullName)" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
    $crc=$LASTEXITCODE
    Log ("  cab " + $c.Name + " rc=" + $crc)
    if($crc -eq 3010 -or $crc -eq 2359302){ $staged=$true }
    elseif($crc -ne 0){ $worst=$crc }
  }
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  if($worst -ne 0){ return $worst }
  if($staged){ return 3010 }
  return 0
}

# Does this guest have a REAL default route (i.e. a netvm)? Loopback/blackhole adapters do not count.
# Templates have none by design; only netvm-attached standalones do. Used to gate the DO/BITS-based
# Install-ViaWU rung, which fails routeless (measured DO 0x80D03805 / BITS 0x80200010) and must never
# run on a netvm-free guest where it only produces phantom failures.
function Test-HasDefaultRoute {
  try {
    return @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
             Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }).Count -gt 0
  } catch { return $false }
}

# Best-effort ESU (Extended Security Updates) entitlement status, for the honesty gate on post-EOS
# Win10 (19045). Not load-bearing - purely informational for dom0 - so it never throws.
function Get-EsuStatus {
  try {
    $esu = @(Get-CimInstance -ClassName SoftwareLicensingProduct -EA SilentlyContinue |
             Where-Object { $_.Name -match 'ESU|Extended Security' -and $_.LicenseStatus -eq 1 })
    if ($esu.Count -gt 0) { return 'entitled' }
    return 'not-enrolled'
  } catch { return 'unknown' }
}

# Build a human-readable INFORMATIONAL diagnosis for the post-end-of-support / ESU-gated state, so dom0
# sees WHY the newest security cumulative is not being installed - a licensing ceiling, not a transport
# failure. Returns $null when there is nothing to report (ESU-entitled, or not the post-EOS Win10 case).
# Keyed off the OS build + entitlement, NOT a live-clock comparison, so it is deterministic. $avail rows
# carry content_class/title from Get-Available; used only to name the phantom OOB if one is offered.
function Get-ServicingNotice($avail, $esu) {
  if ("$OsBuild" -ne '19045') { return $null }   # only Windows 10 22H2 is post-end-of-support in this fleet
  if ($esu -eq 'entitled')    { return $null }   # entitled -> the catalog CU installs; nothing to report
  $exprCU = @($avail | Where-Object { $_.content_class -eq 'express' -and "$($_.title)" -match 'Cumulative Update' })
  $offer = if ($exprCU.Count -gt 0) {
    ' Windows Update currently offers only the ESU-enrollment out-of-band (' +
    (($exprCU | ForEach-Object { $_.kb }) -join ',') + '), which carries no new security content.'
  } else { '' }
  return ('Windows 10 22H2 (build 19045) reached end-of-support on 2025-10-14 and this guest is NOT ' +
    'enrolled in Extended Security Updates (ESU=' + $esu + '). Post-end-of-support security updates ' +
    'therefore cannot be INSTALLED: the current monthly security cumulative update IS published in the ' +
    'Microsoft Update Catalog and the updater can fetch it through the proxy, but Windows (CBS) refuses ' +
    'to apply it without ESU entitlement.' + $offer + ' To resume security servicing, enroll this guest ' +
    'in ESU with a volume Multiple Activation Key (MAK, offline-activatable). INFORMATIONAL, not an error.')
}

# Install a KB that Windows Update offers as a self-contained STATIC file (Defender defs and MSRT ship
# as .exe; some updates as .msu), fetched through the proxy and installed with NO Delivery Optimization
# / BITS / NLA. This is the routeless-clean replacement for handing these KBs to the DO-gated
# Install-ViaWU, the class that actually failed every pass on a netvm-free guest. Proven mechanism:
# scan carries the static URL (dc-probe.ps1), Fetch-Msu pulls it through 127.0.0.1:8082 (harvest-proof.ps1).
function Install-SelfContained($kb,$urls){
  $dir = Join-Path $WorkDir ("wu-direct\" + $kb)
  New-Item -ItemType Directory -Force $dir | Out-Null
  $rows=@()
  foreach($url in @($urls)){
    $name = if($url -match '/([^/?]+\.(?:msu|exe|cab))(\?|$)'){ $Matches[1] } else { "$kb.bin" }
    $dst = Join-Path $dir $name
    if(-not (Fetch-Msu $url $dst $kb)){ $rows += [ordered]@{ kb=$kb; file=$name; rc='fetch-failed'; ok=$false }; continue }
    $ext = [IO.Path]::GetExtension($name).ToLower()
    if($ext -eq '.exe'){
      # Verify BY EFFECT, not by exit code: Defender mpam-fe advances AntivirusSignatureVersion; MSRT
      # advances HKLM\...\RemovalTools\MRT\Version. rc=0 alone has read as success on a no-op before.
      $sigBefore=''; $mrtBefore=''
      try{ $sigBefore=(Get-MpComputerStatus).AntivirusSignatureVersion }catch{}
      try{ $mrtBefore=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version }catch{}
      $p = Start-Process $dst -ArgumentList '/q' -Wait -PassThru -WindowStyle Hidden
      $eff=$false
      try{ if($sigBefore){ $eff = $eff -or ((Get-MpComputerStatus).AntivirusSignatureVersion -ne $sigBefore) } }catch{}
      try{ if($name -match 'kb890830'){ $eff = $eff -or ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version -ne $mrtBefore) } }catch{}
      $ok = ($p.ExitCode -eq 0) -or $eff
      Log ("  $name : exe rc=$($p.ExitCode) verified_by_effect=$eff")
      $rows += [ordered]@{ kb=$kb; file=$name; rc=$p.ExitCode; ok=$ok; verified_by_effect=$eff }
    } elseif($ext -eq '.msu' -or $ext -eq '.cab'){
      # DISM decides: a self-contained CBS package (.msu wrapper, or a .cab WITH update.mum at root
      # like KB5001716) installs; a payload-only .cab (e.g. the .NET ndp481 cab, WinSxS components with
      # no update.mum) is cleanly REJECTED with DISM Error 13 (0xD) before applying anything - so this
      # is honest, not a poison: rc=13 -> ok=false, loud. No blanket refusal, no false success.
      $rc = Add-PackageCompat $dst
      Log ("  $name : DISM rc=$rc")
      $rows += [ordered]@{ kb=$kb; file=$name; rc=$rc; ok=($rc -in $OK_RC) }
      if($rc -eq 3010){ $script:St.reboot_needed=$true; $script:StagedThisSession=$true }
    } else {
      Log ("  $name : unrecognised self-contained artifact type - failing loudly")
      $rows += [ordered]@{ kb=$kb; file=$name; rc='unknown-artifact'; ok=$false }
    }
  }
  return ,$rows
}

function Install-Msus($files){
  $reboot=$false; $rows=@()
  foreach($f in (Order-Msus $files)){
    $name = [IO.Path]::GetFileName($f)
    $pi = Get-MsuInfo $f
    Log "  $name applicable=$($pi.applicable) state=$($pi.state) id=$($pi.identity)"
    if($pi.applicable -eq 'No'){
      # SKIPPED, not failed: this package was never meant for this image. Recording it as a
      # failure is what made a whole KB look broken when only a catalog sibling was irrelevant.
      $rows += [ordered]@{ file=$name; rc='skipped'; why="not applicable to this image" }
      continue
    }
    if($pi.state -eq 'Installed'){
      $rows += [ordered]@{ file=$name; rc='skipped'; why="already installed" }
      continue
    }
    # ONE REBOOT-REQUIRING PACKAGE PER SERVICING SESSION.
    #
    # Measured 2026-08-14 on a pristine 26100.8875 clone: the pass staged KB5120710 (rc=3010) and
    # then KB5121003 (rc=3010) without a reboot in between. After the reboot KB5120710 was
    # state=112 Installed and KB5121003 had ZERO CBS package entries - never registered, no
    # rollback logged, shutdown 77 s instead of the 6.3 min a real apply takes. CBS applied the
    # first staged package and silently discarded the second, while DISM returned 3010 for both.
    # The 11:47 success is the control: it installed the cumulative ALONE on an image where the
    # .NET update was already installed AND rebooted.
    #
    # So once something is staged, stop. The remaining packages stay on disk and the next pass -
    # after the reboot this one forces - picks them up. Slower, and the only way the second package
    # actually lands.
    if ($script:StagedThisSession -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
      $rows += [ordered]@{ file=$name; rc='deferred'
                           why='another package is already staged; installing it needs a reboot first' }
      Log "  DEFER $name - a reboot-requiring package is already staged this session"
      continue
    }
    $script:St.installing=[ordered]@{ file=$name; state='running' }; Save
    $rc = Add-PackageCompat $f
    if($rc -eq 3010){ $reboot=$true; $script:StagedThisSession = $true }
    # Re-ask DISM what the package's state is NOW. rc=3010 only means "staged"; the state tells us
    # whether CBS actually took it, which is the thing that was silently false before.
    $after = Get-MsuInfo $f
    $rows += [ordered]@{ file=$name; rc=$rc; state_after=$after.state }
    Log "  DISM $name rc=$rc state_after=$($after.state)"
  }
  # STICKY, never assigned: Install-Msus runs once per KB, so assigning would let a later KB
  # that needs no reboot erase an earlier one that does. Measured 2026-08-13 on the template:
  # KB5120710 returned 3010 (reboot required), KB5121003 then returned 0, and the pass ended
  # claiming reboot_needed=false while Windows had CBS RebootPending set.
  if ($reboot) { $script:St.reboot_needed = $true }

  # SETTLE BEFORE DECLARING ANYTHING. DISM returning 3010 does NOT mean CBS has finished
  # registering the package: TiWorker keeps working after the exit code. Measured 2026-08-14 - the
  # pass reported done, the qube shut down 22 s later, the shutdown took 77 s where a real apply
  # takes 6.3 min, and the cumulative ended with ZERO CBS entries. A staged package that has not
  # reached "reboot pending" is not staged yet, and rebooting there loses it.
  #
  # NOTE this is also the test that decides WHY it was lost. Windows aggregates many packages per
  # reboot routinely, so "CBS only applies one staged package" is a weak claim on one observation.
  # If RebootPending appears here and the package is still discarded at boot, the aggregation story
  # is real; if RebootPending never appears, the loss was this race and serialising was treating a
  # symptom.
  if ($reboot) {
    $rp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $deadline = (Get-Date).AddMinutes(10)
    $seen = $false
    while ((Get-Date) -lt $deadline) {
      if (Test-Path $rp) { $seen = $true; break }
      Start-Sleep -Seconds 5
    }
    $ti = @(Get-Process TiWorker, TrustedInstaller -EA SilentlyContinue).Count
    Log ("  settle: CBS RebootPending={0} after staging, servicing processes still up={1}" -f $seen, $ti)
    $script:St.reboot_pending_confirmed = $seen
    if (-not $seen) {
      Log '  WARNING: staged but CBS never reported RebootPending - a reboot now would lose it'
    }
    # Let TiWorker finish its post-DISM work; rebooting mid-registration is what loses a package.
    $q = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $q -and @(Get-Process TiWorker -EA SilentlyContinue).Count -gt 0) { Start-Sleep -Seconds 10 }
    Log ("  settle: TiWorker idle={0}" -f (@(Get-Process TiWorker -EA SilentlyContinue).Count -eq 0))
  }
  return $rows
}

# AUTOLOGON PROTECTION AT EVERY PASS END (measured 2026-08-19: three HARNESS-driven reboots
# around staged servicing consumed DefaultPassword and left win10-clean at the sign-in screen
# - unreachable for qrexec, needing a manual login. ensure-autologon.ps1 was wired only to
# the vmupdate/dom0-driven REBOOT path, so any other rebooter - a harness, a human, CBS
# itself - bypassed it). Running the prevention whenever THIS pass staged reboot-requiring
# work removes the dependency on who reboots afterwards. Prevention only: if the password is
# already consumed there is nothing this can restore (see ensure-autologon.ps1's header).
function Protect-Autologon {
  # Fire whenever a reboot is pending OR a package was staged this session (a stage can precede the
  # reboot_needed flag, and a throw between the two must not skip re-arming autologon).
  if (-not ($script:St.reboot_needed -or $script:StagedThisSession)) { return }
  $ea = 'C:\Program Files\Qubes Tools\vmupdate-shim\ensure-autologon.ps1'
  if (-not (Test-Path $ea)) { Log 'reboot staged but ensure-autologon.ps1 is not deployed - autologon may be consumed by the coming reboots' 'WARN'; return }
  try {
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ea 2>&1 |
      ForEach-Object { Log "  autologon: $_" }
  } catch { Log "ensure-autologon failed: $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------------- main
# VM-CLASS CLASSIFICATION, guest-side. The qubes.UpdatesProxy updater is a TEMPLATE-ONLY
# mechanism: dom0-driven updates for a VM that is otherwise offline. It must run ONLY on a
# TemplateVM. A StandaloneVM - networked OR offline - updates ITSELF via normal Windows Update and
# must NEVER raise the proxy ("offline" does not make a standalone a template). An AppVM/DispVM has
# a volatile root and must do nothing (updates are its template's business).
#
# The class is read LIVE from qubesdb, exactly as the Linux agent does. The earlier "vm-type is
# unreadable in a Windows guest" claim was a BUG in the PowerShell glue, NOT a real limit: the C
# agent reads qubesdb fine, qubesdb-client.dll is in SYSTEM32, and the P/Invoke merely needed the
# correct Cdecl/Ansi marshaling (measured 2026-08-19). Keys are written by core-admin:
#   /type                 - the exact Python class name (StandaloneVM/TemplateVM/AppVM/DispVM).
#                           The ONLY key that separates StandaloneVM from AppVM; /qubes-vm-type
#                           collapses both to 'AppVM'.
#   /qubes-vm-type        - TemplateVM | AppVM | NetVM | ProxyVM (fallback template test).
#   /qubes-vm-updateable  - True (Template/Standalone) | False (AppVM/DispVM) (fallback splitter).
# No deploy-time stamp is needed and this works on ANY template however it was built. The old
# VmClass/RootIdentity stamp fallback is RETIRED - the read is proven reliable, so if we cannot
# classify we refuse to proxy (skipped-unknown) rather than trust a stale stamp. NOTE:
# /qubes-service/yum-proxy-setup carries dom0's updates-proxy-setup feature if
# an operator ever wants to opt a specific standalone in; we deliberately do not honour it here
# (the requirement is template-ONLY).
function Get-QubesDbValue([string]$path) {
  try {
    if (-not ('QubesDb' -as [type])) {
      Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QubesDb {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
    }
    $h = [QubesDb]::qdb_open([IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
      $len = [uint32]0
      $p = [QubesDb]::qdb_read($h, $path, [ref]$len)
      if ($p -eq [IntPtr]::Zero) { return $null }
      # value is heap-allocated by qubesdb-client; a few bytes leak per read (no qdb_free
      # exported and calling the CRT free from PS is unsafe) - fine for a short-lived pass.
      return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
    } finally { [QubesDb]::qdb_close($h) }
  } catch { return $null }
}
function Get-QubesVmClass {
  # WAIT for the qubesdb daemon to finish starting. This is a service-startup ORDERING race, not a random
  # flake: qdb_open connects to the qubesdb-daemon service (which, at boot, syncs the database from dom0
  # over vchan). A boot-triggered pass can run before that daemon is serving its pipe, so qdb_open returns
  # NULL *deterministically* in that window and BOTH /type and /qubes-vm-type read empty. Measured
  # 2026-08-20: in steady state the read is rock solid (25/25 returned the class); only the early-boot run
  # read empty. The old code concluded "not a TemplateVM (VmClass='')" on that first empty read and SKIPPED
  # the whole pass on a real template (doing nothing for a full boot). Retry ONLY while qubesdb is
  # unreachable (both keys empty) so we wait out the daemon's startup; a populated value returns
  # immediately, so a steady-state read costs nothing.
  for ($try = 1; $try -le 8; $try++) {
    $t = Get-QubesDbValue '/type'
    if ($t) { return $t }                            # exact class name - best signal
    $vt = Get-QubesDbValue '/qubes-vm-type'
    if ($vt) {
      if ($vt -eq 'TemplateVM') { return 'TemplateVM' }
      if ((Get-QubesDbValue '/qubes-vm-updateable') -eq 'True') { return 'StandaloneVM' }
      return 'AppVM'
    }
    if ($try -lt 8) { Start-Sleep -Seconds 2 }       # qubesdb not reachable yet - wait out the boot race
  }
  return $null                                       # still unreadable after ~14s -> caller uses fallback
}
function Test-DirectInternet {
  foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt','http://www.msn.com/') {
    try {
      $req = [System.Net.HttpWebRequest]::Create($u)
      $req.Proxy = $null                 # explicitly DIRECT - ignore any system/WinHTTP proxy
      $req.Timeout = 8000
      $resp = $req.GetResponse()
      $ok = ([int]$resp.StatusCode -lt 400)
      $resp.Close()
      if ($ok) { return $true }
    } catch { }
  }
  return $false
}
$vmClassLive = Get-QubesVmClass
if (-not $vmClassLive) {
  # qubesdb is the authority and is reliably readable (qubesdb-client.dll is in SYSTEM32). If we
  # genuinely cannot classify, REFUSE to proxy rather than guess - never proxy a VM we cannot
  # confirm is a template. This is an anomaly to investigate, NOT a case to paper over with a
  # deploy-time stamp (the old VmClass/RootIdentity stamp fallback is retired: the read is proven).
  Log 'CANNOT classify VM from qubesdb - refusing to proxy; nothing done. Investigate qubesdb.' 'WARN'
  $script:St.phase='skipped-unknown'; Save
  exit 0
}
Log "VM class (live from qubesdb): $vmClassLive"
if ($vmClassLive -eq 'TemplateVM') {
  # the proxy updater's home - fall through to Ensure-Proxy below
} elseif ($vmClassLive -eq 'StandaloneVM') {
  if (Test-DirectInternet) {
    Log 'StandaloneVM with direct internet - it updates ITSELF via Windows Update. The qubes proxy updater is template-only: disabled. Undoing NoAutoUpdate=1.'
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -EA SilentlyContinue
  } else {
    Log 'StandaloneVM, offline - the qubes proxy updater is template-only and never runs here; this VM must update itself. Doing nothing.'
  }
  $script:St.phase='skipped-standalone'; Save
  exit 0
} else {
  Log "$vmClassLive - not a template; updates are the template's business. Exiting before any proxy activity."
  $script:St.phase='skipped-appvm'; Save
  exit 0
}
try {
  $script:St.phase='ensure-proxy'; Save; Ensure-Proxy
  $script:St.phase='sync-revocation'; Save; Sync-Revocation
  $script:St.phase='scan'; Save
  # A LOSSY PASS MUST NEVER BE REPORTED AS "NOTHING TO UPDATE".
  # Measured 2026-08-15: five consecutive scans reported 0 updates on a guest that had three.
  # Windows Update was reachable the whole time - what failed were small plain-HTTP metadata
  # fetches through the relay, which returned nothing at all. WU cannot describe an offer it
  # could not download, so it answers "no updates", and the guest then tells dom0 it is current.
  # That is the worst possible failure: silent, and it looks like success.
  # So: watch the relay's own log across the scan. If it gave up on any fetch (complete=False)
  # AND the scan found nothing, the result is UNKNOWN, not zero - retry once, then refuse to
  # report a number nobody can stand behind.
  $relayLog = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
  function Get-RelayGiveUps([long]$fromOffset) {
    if (-not (Test-Path $relayLog)) { return 0 }
    try {
      $fs = [IO.File]::Open($relayLog, 'Open', 'Read', 'ReadWrite')
      try {
        if ($fromOffset -gt $fs.Length) { $fromOffset = 0 }
        [void]$fs.Seek($fromOffset, 'Begin')
        $sr = New-Object IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
      } finally { $fs.Dispose() }
      return ([regex]::Matches($text, 'complete=False')).Count
    } catch { return 0 }
  }
  $relayOffset = if (Test-Path $relayLog) { (Get-Item $relayLog).Length } else { 0 }

  $avail = Get-Available
  # TEST HOOK, same reasoning as the agent's SoloFaultInject: this guard only fires when a scan
  # finds nothing WHILE the transport was dropping fetches, and once Windows Update has cached
  # its metadata that state cannot be summoned on demand. QUBES_UPDATES_FAKE_EMPTY_SCAN=1 makes
  # the scan look empty so the guard can be SEEN to fire. Absent, this is dead code.
  if ($env:QUBES_UPDATES_FAKE_EMPTY_SCAN -eq '1') {
    Log 'QUBES_UPDATES_FAKE_EMPTY_SCAN=1 - pretending the scan found nothing' 'WARN'
    $avail = @()
  }
  $giveUps = Get-RelayGiveUps $relayOffset
  if ($avail.Count -eq 0 -and $giveUps -gt 0) {
    Log "scan returned 0 but the relay gave up on $giveUps fetch(es) - the result is UNKNOWN, rescanning" 'WARN'
    $relayOffset = if (Test-Path $relayLog) { (Get-Item $relayLog).Length } else { 0 }
    Start-Sleep -Seconds 5
    $avail = Get-Available
    $giveUps = Get-RelayGiveUps $relayOffset
  }
  if ($avail.Count -eq 0 -and $giveUps -gt 0) {
    $script:St.phase='scan-failed'; $script:St.error = "transport lost $giveUps fetch(es); update availability unknown"; Save
    Log "SCAN FAILED: the relay gave up on $giveUps fetch(es) and Windows Update found nothing. Not reporting 0 to dom0 - a scan that could not fetch its metadata is not the same as a guest with no updates." 'ERROR'
    exit 75
  }

  $script:St.available=$avail; $script:St.count=$avail.Count; Save
  # Post-end-of-support / ESU diagnosis: INFORMATIONAL, computed on every pass from the fresh scan so a
  # bare `scan` surfaces it too. Explains WHY the newest security cumulative is not installable here.
  if ("$OsBuild" -eq '19045') {
    $script:St.esu = Get-EsuStatus
    $script:St.notice = Get-ServicingNotice $avail $script:St.esu
  }
  # dom0's "updates available" marker should reflect ACTIONABLE updates. Under the ESU notice, the
  # express/ESU-gated offers are informational (in St.notice), not installable - do not count them, or
  # dom0 would show a permanent "updates available" for a phantom the guest can never apply.
  $reportCount = $avail.Count
  if ($script:St.notice) { $reportCount = @($avail | Where-Object { $_.content_class -ne 'express' }).Count }
  $script:St.remaining = $reportCount; Save
  Log ("scan: $($avail.Count) update(s) offered" + $(if($script:St.notice){ "; $reportCount actionable (" + ($avail.Count - $reportCount) + " ESU-gated/express informational - see notice)" }else{ '' }))
  if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
  Report-Availability $reportCount    # -> dom0 Qube Manager (default-allowed for TemplateVMs)

  # Applied AFTER reporting: dom0 must always hear the true number of available updates. -OnlyKb
  # narrows what THIS pass acts on, it does not narrow what the guest admits to.
  if ($OnlyKb.Count -gt 0) {
    $before = $avail.Count
    $avail = @($avail | Where-Object { $k = $_.kb; @($OnlyKb | Where-Object { $k -match $_ }).Count -gt 0 })
    Log ("-OnlyKb " + ($OnlyKb -join ',') + ": acting on $($avail.Count) of $before offered update(s)")
    # A KB that is no longer OFFERED (because it is already installed) can still be interrogated -
    # that is how you price a package after the fact. Allowed for `resolve` ONLY: resolve reads
    # catalog metadata and sizes, it downloads and installs nothing, so this can never push an
    # update onto a guest that Windows did not offer.
    if ($avail.Count -eq 0 -and $Action -eq 'resolve') {
      foreach ($k in $OnlyKb) {
        if ($k -match '^(KB\d+)$') {
          $avail += [pscustomobject]@{ kb = $Matches[1]; title = '(forced resolve - not currently offered)' }
        }
      }
      Log ("forced resolve of " + ($avail | ForEach-Object { $_.kb }) -join ',')
    }
  }

  if ($Action -eq 'wuinstall') {
    $script:St.result = Install-ViaWU
    Protect-Autologon
    $script:St.phase='done'; Save
    Log 'done (WU-native)'
    return
  }

  # KBs the catalog cannot serve; handed to the Windows Update installer after the loop.
  $script:WuFallbackKbs = @()
  # KBs Windows Update publishes ONLY as Delivery-Optimization express streams (KB5071959-class):
  # not installable on a netvm-free guest, terminally classified, reported honestly after the loop.
  $script:WuOnlyExpressKbs = @()
  if ($env:QUBES_UPDATES_FAKE_FALLBACK_KB) {
    $script:WuFallbackKbs += $env:QUBES_UPDATES_FAKE_FALLBACK_KB
    Log ("QUBES_UPDATES_FAKE_FALLBACK_KB=" + $env:QUBES_UPDATES_FAKE_FALLBACK_KB + " - pretending that KB needs the Windows Update fallback")
  }
  if ($Action -in 'resolve','download','full','install') {
    foreach($u in $avail){
      if($u.kb -notmatch '^KB\d+'){ Log "skip (no KB): $($u.title)"; continue }
      $script:St.phase='resolve'; Save
      $urls = Resolve-Catalog $u.kb
      Log "$($u.kb): $($urls.Count) catalog .msu"
      # ASK BEFORE DOWNLOADING. The catalog's DownloadDialog returns every file bundled with an
      # update, including SUPERSEDED cumulatives: for KB5121003 it returns kb5043080 (2024-09)
      # alongside the one we want. On a 26100.8875 image the older one is not applicable, DISM
      # rejects it with rc=552, and feeding it to CBS first preceded the cumulative being rolled
      # back at boot with 0x80070490. The KB is in the URL, so this costs no bytes to decide.
      # /Get-PackageInfo cannot help here - measured: it reports the superseded package as
      # "Applicable: Yes, State: Installed, identity OnePackage~~~~0.0.0.0", i.e. nothing usable.
      # Deliberately ABOVE the resolve-only branch: the decision is pure string work on URLs, so
      # `-Action resolve` is a genuine zero-byte dry run of exactly what a download would fetch.
      $digits = ($u.kb -replace '\D', '')
      $matching = @($urls | Where-Object { $_ -match $digits })
      if ($matching.Count -gt 0 -and $matching.Count -lt $urls.Count) {
        Log ("  " + $u.kb + ": " + ($urls.Count - $matching.Count) + " of " + $urls.Count +
             " catalog file(s) are for other KBs - not downloading them")
        # Size the dropped files on a resolve pass. This is the ONLY exact figure for what the
        # filter saves - the payload's internal waste is not knowable from a URL - and it costs
        # one HEAD each, no body.
        foreach ($drop in ($urls | Where-Object { $_ -notmatch $digits })) {
          $nm = if ($drop -match '/([^/?]+\.msu)') { $Matches[1] } else { $drop }
          if ($Action -eq 'resolve') {
            $sz = Get-UrlSize $drop
            Log ("    DROP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB avoided" -f ($sz/1MB) } else { 'size unknown' }))
          } else { Log ("    DROP " + $nm) }
        }
        $urls = $matching
      } elseif ($matching.Count -eq 0) {
        Log ("  " + $u.kb + ": no catalog file names mention the KB - keeping all " + $urls.Count)
      }
      $got=@()
      if ($Action -eq 'resolve') {
        Log "$($u.kb): resolve-only, would fetch $($urls.Count) package(s)"
        $keepTotal = 0
        foreach ($url in $urls) {
          $nm = if ($url -match '/([^/?]+\.msu)') { $Matches[1] } else { $url }
          $sz = Get-UrlSize $url
          if ($sz -ge 0) { $keepTotal += $sz }
          Log ("    KEEP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB" -f ($sz/1MB) } else { 'size unknown' }))
        }
        Log ("  " + $u.kb + ": would transfer {0:N1} MB" -f ($keepTotal/1MB))
        continue
      }
      if ($Action -in 'download','full') {
        $script:St.phase='download'; Save
        # ONE DIRECTORY PER KB. DISM treats the folder holding a package as a source set: with a
        # flat work dir it pulled kb5054156-25h2-ekb.msu - a 25H2 enablement package left by an
        # earlier session - into a 24H2 servicing session (dism.log "LocalSources"). Isolating
        # each KB makes that impossible and keeps resume/reuse working.
        $kbDir = Join-Path $WorkDir $u.kb
        New-Item -ItemType Directory -Force $kbDir | Out-Null
        $i=0; foreach($url in $urls){ $i++; $name="$($u.kb)_$i.msu"; if($url -match '/([^/?]+\.msu)'){$name=$Matches[1]}
          $dst=Join-Path $kbDir $name; if(Fetch-Msu $url $dst $u.kb){ $got+=$dst } }
      } else { $got = @(Get-ChildItem (Join-Path (Join-Path $WorkDir $u.kb) '*.msu') -EA SilentlyContinue | ForEach-Object FullName) }
      # An offered KB that yields NO installable file is a FAILED update, not a quiet success.
      # Measured 2026-08-13: KB5120708 (.NET Framework) resolved to zero catalog .msu on a 25H2
      # guest - Resolve-Catalog is written around the x64/24H2/26100 client build - and because
      # nothing was downloaded there was no result row, so the pass reported "count=1" and exit 0
      # while installing nothing. dom0 must hear about that.
      if ($Action -in 'install','full' -and $got.Count -eq 0) {
        $why = if ($urls.Count -eq 0) { 'no catalog entry matches this Windows version/architecture' }
               else { "resolved $($urls.Count) package(s) from the catalog but none could be downloaded" }
        # Before calling it failed: some updates have no .msu for the DISM path to install.
        # CHECKED against the Update Catalog on 2026-08-15 rather than assumed:
        #   KB890830  (Malicious Software Removal Tool) IS in the catalog - 26 rows - but ships
        #             as an .exe, and Resolve-Catalog accepts only .msu because DISM does.
        #   KB2267602 (Defender definitions) is NOT in the catalog at all ("We did not find any
        #             results"); it is delivered through Windows Update / the security
        #             intelligence mpam-fe.exe.
        # Neither is a defect - it is how those products are packaged - but both would be
        # reported failed on every pass, leaving dom0 showing updates that never clear.
        # Hand exactly those to WU's own installer after this loop.
        if ($urls.Count -eq 0) {
          # The catalog has no .msu for this KB. Route by the content class computed at scan time
          # (Get-WuContentClass) instead of blindly handing it to the DO-gated Install-ViaWU, which
          # fails routeless. Three outcomes:
          $cls = $u.content_class
          $directUrls = @($u.direct_urls)
          if ($cls -eq 'self-contained' -and $directUrls.Count -gt 0) {
            # Defender defs / MSRT / SSU published as a static file: fetch through the proxy and
            # install natively, NLA-free. This is the class that failed EVERY pass before.
            Log "$($u.kb): not in the catalog, but Windows Update offers it as a self-contained static file - installing directly through the proxy (no DO/BITS/NLA)"
            $script:St.phase='install'; Save
            $rows = Install-SelfContained $u.kb $directUrls
            $ok = @($rows | Where-Object { $_.ok }).Count -gt 0
            $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
            $script:St.result += [ordered]@{ kb=$u.kb; ok=$ok; state=$(if($staged){'staged'}elseif($ok){'installed'}else{'failed'}); files=$rows }
            Save
            Log "$($u.kb): self-contained install ok=$ok"
            continue
          }
          if ($cls -eq 'express') {
            # KB5071959-class: published ONLY as Delivery-Optimization delta streams. Not installable
            # on a netvm-free guest and it carries no content the catalog CU does not. Classify it
            # terminally - never chase it into the DO/BITS path that would fail forever.
            $script:WuOnlyExpressKbs += $u.kb
            Log "$($u.kb): published only as Delivery-Optimization express/UUP streams - terminally classified (not installable netvm-free, not chased)"
            continue
          }
          # class 'none'/unknown: only a guest that actually has a route may try the WU installer.
          $script:WuFallbackKbs += $u.kb
          Log "$($u.kb): no catalog .msu and no static WU URL - deferring to the Windows Update installer (route permitting)"
          continue
        }
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$false; files=@(); reason=$why }
        Save
        Log "$($u.kb): NO installable package resolved - reporting as failed"
      }
      if ($Action -in 'install','full' -and $got.Count -gt 0) {
        $script:St.phase='install'; Save
        # One catalog KB can yield SEVERAL .msu (build/architecture variants, prerequisites), and
        # the ones that do not apply to this image fail by design - a 24H2 cumulative returns
        # rc=552 on a 25H2 guest. So a KB counts as installed when AT LEAST ONE of its files
        # succeeds, and results are grouped PER KB and APPENDED. This used to be a plain
        # assignment of a flat row list, so each KB silently erased the previous KB's outcome.
        $rows = Install-Msus $got
        $ok = @($rows | Where-Object { $_.rc -in $OK_RC }).Count -gt 0
        # STAGED IS NOT INSTALLED. rc=3010 means CBS accepted the package and will apply it during
        # the next boot - it is not proof that it landed, and on 2026-08-14 a package that returned
        # 3010 ended up with ZERO CBS entries after the reboot while this code reported
        # "installed=True". Say which it is, so a discarded package can never read as a success.
        $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
        $applied = @($rows | Where-Object { $_.rc -eq 0 }).Count -gt 0
        $deferred = @($rows | Where-Object { $_.rc -eq 'deferred' }).Count -gt 0
        $state = if ($staged) { 'staged' } elseif ($applied) { 'installed' }
                 elseif ($deferred) { 'deferred' } else { 'failed' }
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$ok; state=$state; files=$rows }
        Save
        # Reclaim the download ONLY once the package is truly applied. A STAGED package still has
        # to survive a reboot, and if it does not, the next pass must be able to retry it without
        # re-fetching gigabytes - deleting it here is what made a failed apply expensive.
        if (-not $staged) {
          foreach($r in $rows){ if($r.rc -in $OK_RC){ Remove-Item -LiteralPath (Join-Path (Join-Path $WorkDir $u.kb) $r.file) -Force -EA SilentlyContinue } }
        }
        Log "$($u.kb): $state (ok=$ok)"
      }
    }
  }
  # Updates that are not catalog packages: install them the only way they CAN be installed.
  #
  # NOT if this session already staged something. CBS applies exactly ONE staged session per
  # boot and silently discards anything staged behind it (measured twice, 2026-08-14, with
  # RebootPending confirmed and TiWorker idle - it is not a shutdown race). The catalog path
  # already stops for that reason; letting Windows Update install into the same session
  # afterwards would walk straight back into it, and the discarded package would be reported
  # as installed. dom0 drives a second pass, which is where these belong.
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and
      ($script:StagedThisSession -or $script:St.reboot_needed) -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
    foreach ($kb in $script:WuFallbackKbs) {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                       reason='deferred: a reboot-requiring package is already staged this session; the next pass installs this' }
    }
    Save
    Log ("Windows Update fallback DEFERRED for " + ($script:WuFallbackKbs -join ',') +
         " - something is already staged this session and CBS would discard a second one")
    $script:WuFallbackKbs = @()
  }
  # The Windows Update installer (Install-ViaWU) downloads through Delivery Optimization / BITS, which
  # REFUSE on a guest with no route (measured DO 0x80D03805 / BITS 0x80200010) - so on a netvm-free
  # guest this rung only manufactures phantom 0x80240022 failures. Run it ONLY when a real default
  # route exists (a netvm-attached standalone) or when explicitly forced for diagnosis. On a
  # netvm-free guest, report these KBs honestly instead of failing into DO/BITS.
  $canWuNative = (Test-HasDefaultRoute) -or ($env:QUBES_UPDATES_ALLOW_WU_NATIVE -eq '1')
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and -not $canWuNative) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuFallbackKbs) {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
        reason='no catalog .msu and no static Windows Update file; the WU-native (DO/BITS) installer is disabled on a netvm-free guest because it fails routeless' }
    }
    Save
    Log ("Windows Update native installer SKIPPED for " + ($script:WuFallbackKbs -join ',') +
         " - no default route; DO/BITS would fail routeless (set QUBES_UPDATES_ALLOW_WU_NATIVE=1 to force)")
    $script:WuFallbackKbs = @()
  }
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    Log ("Windows Update fallback for " + ($script:WuFallbackKbs -join ',') + " (no .msu for the DISM path)")
    try {
      $wuRows = Install-ViaWU -OnlyKbs $script:WuFallbackKbs -TunePolicies $false
      foreach ($row in $wuRows) { $script:St.result += $row }
      $done = @($wuRows | Where-Object { $_.ok }).Count
      Log "Windows Update fallback: $done of $($script:WuFallbackKbs.Count) installed"
      # Install-ViaWU sets St.reboot_needed when Windows asks for one. Say so here too: a
      # definition update normally needs no reboot, and if one of these ever does, that is
      # exactly the fact the next pass has to know about.
      if ($script:St.reboot_needed) { Log 'Windows Update fallback: a reboot is required to finish' }
      # Anything the fallback did not cover is still a failure, and dom0 must hear it.
      foreach ($kb in $script:WuFallbackKbs) {
        if (-not (@($wuRows | Where-Object { $_.kb -eq $kb }).Count -gt 0)) {
          $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                           reason='no .msu for the DISM path, and the Windows Update installer did not offer it either' }
        }
      }
      Save
    } catch {
      Log "Windows Update fallback failed: $($_.Exception.Message)" 'ERROR'
      foreach ($kb in $script:WuFallbackKbs) {
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@(); reason="Windows Update fallback failed: $($_.Exception.Message)" }
      }
      Save
    }
  }

  # Terminal honesty gate for express-only KBs (KB5071959-class). These are published only as
  # Delivery-Optimization delta streams and are not installable on a netvm-free guest by ANY path -
  # so report them once, deterministically, as a fixed ceiling, instead of failing them forever. On
  # post-EOS Win10 (19045) the underlying reason is the ESU entitlement gate at CBS install time
  # (the real Nov CU, KB5068781, IS in the catalog and installs via the existing path ONCE entitled);
  # surface that as a stable status so dom0 sees the ceiling rather than a phantom transport failure.
  if ($Action -in 'install','full' -and $script:WuOnlyExpressKbs.Count -gt 0) {
    $script:WuOnlyExpressKbs = @($script:WuOnlyExpressKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuOnlyExpressKbs) {
      # severity='info' marks this as INFORMATIONAL, not a failure: it is excluded from the failed/
      # remaining count reported to dom0 (see below), so a KB the guest can never apply routeless does
      # not read as a broken update forever. The St.notice (set at scan time) carries the ESU diagnosis.
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; severity='info'
        reason='wu-only-express: Windows Update offers this KB only through Delivery Optimization (express streams and/or a delta patch that needs a base); no catalog .msu and no self-contained static installer, so it is not installable on a netvm-free guest. INFORMATIONAL - not a failure.' }
    }
    if ("$OsBuild" -eq '19045' -and -not $script:St.esu) { $script:St.esu = Get-EsuStatus }
    Save
    Log ("wu-only-express (informational, terminally classified): " + ($script:WuOnlyExpressKbs -join ',') +
         $(if($script:St.esu){ " ; ESU=$($script:St.esu)" }else{ '' }))
  }

  # Re-report availability at the END of an install pass, so dom0's "updates available" marker
  # reflects reality instead of the pre-install scan. Two cases:
  #  - a reboot is pending: Windows keeps offering the KB until it boots, so any count now would
  #    be a lie. We are rebooting anyway, and the boot scan task (BootTrigger + 2 min) reports
  #    the truth - the same shape as Linux's upgrades-status-notify after an update.
  #  - nothing pending: rescan now and report, or the flag stays set until the next 6-hourly scan.
  if ($Action -in 'install','full') {
    if ($script:St.reboot_needed) {
      # Everything offered was applied; the reboot is ours to perform and happens immediately
      # after this pass. Windows keeps listing the KB as "available" until it boots, but that is
      # a Windows artefact - from dom0's point of view the update IS applied, so clear the flag
      # now rather than leaving the qube marked for minutes. Anything that did NOT install is
      # still reported, and the boot scan re-reports the truth either way, so a wrong guess here
      # self-corrects within ~2 minutes of the restart.
      $failedKbs = @($script:St.result |
                     Where-Object { $_.PSObject.Properties.Name -contains 'kb' -and -not $_.ok -and $_.severity -ne 'info' })
      $script:St.remaining = $failedKbs.Count; Save
      Log "reboot pending; reporting $($failedKbs.Count) remaining to dom0 (boot scan will confirm)"
      Report-Availability $failedKbs.Count
    } else {
      # Best-effort: this is a REPORT, not the work. It needs the proxy, and if anything has
      # taken the proxy away (measured: a concurrent scan's Remove-Proxy) Get-Available throws
      # 0x80240438 - which used to propagate and mark a pass that had installed everything
      # successfully as phase=error.
      try {
        $after = Get-Available
        # Refresh the ESU diagnosis from the post-install scan, and report only ACTIONABLE updates so an
        # ESU-gated/express phantom does not leave dom0 permanently marked "updates available".
        if ("$OsBuild" -eq '19045') { $script:St.esu = Get-EsuStatus; $script:St.notice = Get-ServicingNotice $after $script:St.esu }
        $reportCount = if ($script:St.notice) { @($after | Where-Object { $_.content_class -ne 'express' }).Count } else { $after.Count }
        $script:St.remaining = $reportCount; Save
        Log ("post-install rescan: $($after.Count) offered; $reportCount actionable to dom0" + $(if($script:St.notice){ ' (ESU-gated informational - see notice)' }else{ '' }))
        if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
        Report-Availability $reportCount
      } catch {
        Log "post-install rescan failed (updates are installed; availability will be re-reported by the next scan): $($_.Exception.Message)"
      }
    }
  }

  Protect-Autologon
  $script:St.phase='done'; Save
  Log 'done'
} catch {
  $script:St.phase='error'; $script:St.error="$($_.Exception.Message)"; Save
  Log "ERROR: $($script:St.error)"
} finally {
  # Re-arm autologon on ANY exit path that staged a reboot - INCLUDING a throw AFTER staging (e.g.
  # Resolve-Catalog/Fetch failing once a package was already applied rc=3010). Previously this ran
  # only on the success paths, so a staged-then-threw pass left the guest reboot-pending with
  # autologon unarmed = the sign-in lockout (qrexec rc=117, unmanageable qube). Idempotent + guarded.
  Protect-Autologon
  Remove-Proxy   # ALWAYS restore the routeless baseline - see the Ensure-Proxy comment
  if ($script:HaveMutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
}
# Exit-code contract: a pass that errored must NOT exit 0. A dom0 wrapper or a scheduled task's
# LastTaskResult that trusts the exit code would otherwise misread failure as clean success.
if ($script:St.phase -eq 'error') { exit 1 }
