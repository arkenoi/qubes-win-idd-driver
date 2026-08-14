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
function Ensure-Proxy {
  & netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
  SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
  SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
  if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath $RelayExe)) { throw "relay not found at $RelayExe" }
    $env:QUBES_UPDATES_MAXCONN='256'
    Start-Process -FilePath $RelayExe -ArgumentList '--listen','8082','--target','@default','--log',$WorkDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
  }
}

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

function Get-Available {
  $s=New-Object -ComObject Microsoft.Update.Session
  $se=$s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
  $r=$se.Search("IsInstalled=0 and IsHidden=0")
  $out=@()
  foreach($u in $r.Updates){
    $kb=@($u.KBArticleIDs)|Select-Object -First 1; $kb= if($kb){"KB$kb"}else{'(no KB)'}
    $out += [ordered]@{ kb=$kb; title="$($u.Title)"; size_mb=[math]::Round($u.MaxDownloadSize/1MB,1); downloaded=[bool]$u.IsDownloaded }
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
function Install-ViaWU {
  # Delivery Optimization: no peering (99 = simple), and no background throttling. A qube's only
  # path out is the updates proxy, which is up ONLY during this pass, so there is nothing to be
  # polite to - the usual reason WU downloads slowly in the background does not apply here.
  $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
  SetV $DO 'DODownloadMode'                      99 'DWord'
  SetV $DO 'DOPercentageMaxBackgroundBandwidth' 100 'DWord'
  SetV $DO 'DOPercentageMaxForegroundBandwidth' 100 'DWord'
  SetV $DO 'DOMaxBackgroundDownloadBandwidth'     0 'DWord'   # 0 = unlimited
  SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS' 'EnableBITSMaxBandwidth' 0 'DWord'
  Log 'Delivery Optimization: simple mode, no background throttle (proxy is up only for this pass)'

  $session = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2; $searcher.Online = $true
  $script:St.phase='scan'; Save
  $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
  if ($found.Updates.Count -eq 0) { Log 'WU: nothing to install'; return @() }

  $coll = New-Object -ComObject Microsoft.Update.UpdateColl
  foreach ($u in $found.Updates) {
    if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
    [void]$coll.Add($u)
    Log ("WU: selected " + $u.Title)
  }
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
  } catch { return $false }
  # An .msu is NOT always a cabinet. Classic packages start with 'MSCF', but recent Windows 11
  # cumulative updates ship as WIM containers starting with 'MSWIM' - measured 2026-08-13:
  # KB5121003's .msu begins 4D 53 57 49 4D. A CAB-only check rejected a perfectly good 4.8 GB
  # download and looped forever, which is worse than the problem it was added for. Accept both,
  # and keep the check only for what it is actually good at: catching an HTML error page.
  $isCab = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x43 -and $magic[3] -eq 0x46)
  $isWim = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x57 -and $magic[3] -eq 0x49)
  if (-not ($isCab -or $isWim)) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is neither MSCF nor MSWIM - discarding"
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
  for($a=1;$a -le 8;$a++){
    $have=0; if(Test-Path $dst){$have=(Get-Item $dst).Length}; $o=$null; $expect=0
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($Proxy)
      $req.Timeout=60000; $req.ReadWriteTimeout=120000
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
        # Complete by the server's reckoning - but still prove it is a package before using it.
        if((Test-Msu $dst 0) -eq 'ok'){
          Log "  $([IO.Path]::GetFileName($dst)) already complete ($([math]::Round($have/1MB,1)) MB; server refused resume with 416)"
          $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
          return $true
        }
        Log "  local copy failed verification despite 416 - discarding and refetching"
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
    $script:St.installing=[ordered]@{ file=$name; state='running' }; Save
    & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
    $rc=$LASTEXITCODE; if($rc -eq 3010){$reboot=$true}
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
  return $rows
}

# ---------------------------------------------------------------------- main
try {
  $script:St.phase='ensure-proxy'; Save; Ensure-Proxy
  $script:St.phase='scan'; Save
  $avail = Get-Available
  $script:St.available=$avail; $script:St.count=$avail.Count; Save
  Log "scan: $($avail.Count) update(s) available"
  Report-Availability $avail.Count    # -> dom0 Qube Manager (default-allowed for TemplateVMs)

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
    $script:St.phase='done'; Save
    Log 'done (WU-native)'
    return
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
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$ok; files=$rows }
        Save
        # Reclaim the download: a cumulative update is GIGABYTES (5.1 GB was sitting in this
        # work dir from one pass) and keeping it buys nothing once it is installed.
        foreach($r in $rows){ if($r.rc -in $OK_RC){ Remove-Item -LiteralPath (Join-Path (Join-Path $WorkDir $u.kb) $r.file) -Force -EA SilentlyContinue } }
        Log "$($u.kb): installed=$ok"
      }
    }
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
                     Where-Object { $_.PSObject.Properties.Name -contains 'kb' -and -not $_.ok })
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
        $script:St.remaining = $after.Count; Save
        Log "post-install rescan: $($after.Count) update(s) remain"
        Report-Availability $after.Count
      } catch {
        Log "post-install rescan failed (updates are installed; availability will be re-reported by the next scan): $($_.Exception.Message)"
      }
    }
  }

  $script:St.phase='done'; Save
  Log 'done'
} catch {
  $script:St.phase='error'; $script:St.error="$($_.Exception.Message)"; Save
  Log "ERROR: $($script:St.error)"
} finally {
  Remove-Proxy   # ALWAYS restore the routeless baseline - see the Ensure-Proxy comment
  if ($script:HaveMutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
}
