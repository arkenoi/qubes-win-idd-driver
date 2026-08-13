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
  [ValidateSet('scan','resolve','download','install','full')][string]$Action = 'scan',
  [string]$Proxy      = 'http://127.0.0.1:8082',
  [string]$RelayExe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$WorkDir    = 'C:\ProgramData\Qubes\wu',
  [string]$StatusFile = 'C:\ProgramData\Qubes\update-status.json'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $StatusFile) | Out-Null
New-Item -ItemType Directory -Force $WorkDir | Out-Null
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
function Log($m){ Write-Host ((Get-Date -Format 'HH:mm:ss')+' '+$m) }
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

# KB -> standalone .msu URLs from the Update Catalog (over the proxy), for THIS guest's
# architecture and Windows version. Titles look like:
#   "2026-08 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 25H2 for x64"
#   "... for Microsoft server operating system version 24H2 for x64"   <- excluded (Server)
# Client entries are preferred over server ones and the version token comes from the running OS.
function Resolve-Catalog($kb){
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"; $guid=$null
  $cands=@()
  foreach($m in $rx.Matches($r.Content)){ $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ')
    $cands += $t
    if($t -notmatch [regex]::Escape($OsArch)){ continue }
    if($t -match 'Dynamic|Server|server operating system'){ continue }
    if($OsVer   -and $t -match [regex]::Escape($OsVer))  { $guid=$m.Groups[1].Value; Log "  catalog pick: $t"; break }
    if($OsBuild -and $t -match [regex]::Escape($OsBuild)){ $guid=$m.Groups[1].Value; Log "  catalog pick: $t"; break }
  }
  if(-not $guid){
    # Log every candidate: a resolution miss is otherwise invisible and looks like "no updates".
    Log "  no catalog entry matches arch=$OsArch ver=$OsVer build=$OsBuild; candidates:"
    foreach($c in $cands){ Log "    - $c" }
    return @()
  }
  $json='[{"size":0,"languages":"","uidInfo":"'+$guid+'","updateID":"'+$guid+'"}]'
  $dl=Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60
  return @([regex]::Matches($dl.Content,"url\s*=\s*'(http[^']+)'")|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -match '\.msu(\?|$)'}|Sort-Object -Unique)
}

# resumable fetch with progress into the status file
function Fetch-Msu($url,$dst,$kb){
  for($a=1;$a -le 8;$a++){
    $have=0; if(Test-Path $dst){$have=(Get-Item $dst).Length}; $o=$null
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($Proxy)
      $req.Timeout=60000; $req.ReadWriteTimeout=120000; if($have -gt 0){$req.AddRange($have)}
      $resp=$req.GetResponse(); $tot=$have+$resp.ContentLength; $in=$resp.GetResponseStream()
      $o=[System.IO.File]::Open($dst,[System.IO.FileMode]::Append); $buf=New-Object byte[] (1048576); $last=Get-Date
      while(($n=$in.Read($buf,0,$buf.Length)) -gt 0){ $o.Write($buf,0,$n); $have+=$n
        if(((Get-Date)-$last).TotalSeconds -ge 3){ $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($tot/1MB,1);pct=[math]::Round(100*$have/$tot,1)}; Save; $last=Get-Date } }
      $o.Close();$in.Close();$resp.Close()
      $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
      return $true
    }catch{
      if($o){try{$o.Close()}catch{}}
      # A complete local copy makes the server refuse the resume range with 416. That is
      # "already downloaded", not a failure - measured 2026-08-13: a re-run after a successful
      # pass burned all 8 attempts on 416 and reported the update as unresolvable.
      $code=$null; $we=$_.Exception
      if($we -is [System.Net.WebException] -and $we.Response){ $code=[int]$we.Response.StatusCode }
      if($code -eq 416 -and $have -gt 0){
        Log "  $([IO.Path]::GetFileName($dst)) already complete ($([math]::Round($have/1MB,1)) MB; server refused resume with 416)"
        $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
        return $true
      }
      Log "  fetch attempt ${a}: $($we.Message)"; Start-Sleep 5 }
  }
  return $false
}

# DISM outcomes that mean "this package is now on the system": success, success-pending-reboot,
# and already-installed (0x240006). Anything else is a real failure for that FILE - though not
# necessarily for the KB, see the per-KB rule at the call site.
$OK_RC = @(0, 3010, 2359302)

function Install-Msus($files){
  $reboot=$false; $rows=@()
  foreach($f in ($files | Sort-Object { (Get-Item $_).Length })){   # smallest-first: SSU/checkpoint before LCU
    $script:St.installing=[ordered]@{ file=[IO.Path]::GetFileName($f); state='running' }; Save
    & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
    $rc=$LASTEXITCODE; if($rc -eq 3010){$reboot=$true}
    $rows += [ordered]@{ file=[IO.Path]::GetFileName($f); rc=$rc }
    Log "  DISM $([IO.Path]::GetFileName($f)) rc=$rc"
  }
  $script:St.reboot_needed=$reboot
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

  if ($Action -in 'resolve','download','full','install') {
    foreach($u in $avail){
      if($u.kb -notmatch '^KB\d+'){ Log "skip (no KB): $($u.title)"; continue }
      $script:St.phase='resolve'; Save
      $urls = Resolve-Catalog $u.kb
      Log "$($u.kb): $($urls.Count) catalog .msu"
      $got=@()
      if ($Action -eq 'resolve') { Log "$($u.kb): resolve-only, $($urls.Count) package(s)"; continue }
      if ($Action -in 'download','full') {
        $script:St.phase='download'; Save
        $i=0; foreach($url in $urls){ $i++; $name="$($u.kb)_$i.msu"; if($url -match '/([^/?]+\.msu)'){$name=$Matches[1]}
          $dst="$WorkDir\$name"; if(Fetch-Msu $url $dst $u.kb){ $got+=$dst } }
      } else { $got = @(Get-ChildItem "$WorkDir\$($u.kb)_*.msu","$WorkDir\windows*.msu" -EA SilentlyContinue | ForEach-Object FullName) }
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
        foreach($r in $rows){ if($r.rc -in $OK_RC){ Remove-Item -LiteralPath (Join-Path $WorkDir $r.file) -Force -EA SilentlyContinue } }
        Log "$($u.kb): installed=$ok"
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
}
