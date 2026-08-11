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
  [ValidateSet('scan','download','install','full')][string]$Action = 'scan',
  [string]$Proxy      = 'http://127.0.0.1:8082',
  [string]$RelayExe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$WorkDir    = 'C:\ProgramData\Qubes\wu',
  [string]$StatusFile = 'C:\ProgramData\Qubes\update-status.json'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $StatusFile) | Out-Null
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$IS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'

$script:St = [ordered]@{ action=$Action; phase='init'; ts=$null; count=0; available=@();
                         downloading=$null; installing=$null; result=$null; reboot_needed=$false; error=$null }
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

# KB -> standalone .msu URLs from the Update Catalog (over the proxy). x64/24H2/26100 client build.
function Resolve-Catalog($kb){
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"; $guid=$null
  foreach($m in $rx.Matches($r.Content)){ $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ')
    if($t -match 'x64' -and $t -match '24H2|26100' -and $t -notmatch 'ARM64|Dynamic|Server'){ $guid=$m.Groups[1].Value; break } }
  if(-not $guid){ return @() }
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
    }catch{ Log "  fetch attempt ${a}: $($_.Exception.Message)"; if($o){try{$o.Close()}catch{}}; Start-Sleep 5 }
  }
  return $false
}

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

  if ($Action -in 'download','full','install') {
    foreach($u in $avail){
      if($u.kb -notmatch '^KB\d+'){ Log "skip (no KB): $($u.title)"; continue }
      $script:St.phase='resolve'; Save
      $urls = Resolve-Catalog $u.kb
      Log "$($u.kb): $($urls.Count) catalog .msu"
      $got=@()
      if ($Action -in 'download','full') {
        $script:St.phase='download'; Save
        $i=0; foreach($url in $urls){ $i++; $name="$($u.kb)_$i.msu"; if($url -match '/([^/?]+\.msu)'){$name=$Matches[1]}
          $dst="$WorkDir\$name"; if(Fetch-Msu $url $dst $u.kb){ $got+=$dst } }
      } else { $got = @(Get-ChildItem "$WorkDir\$($u.kb)_*.msu","$WorkDir\windows*.msu" -EA SilentlyContinue | ForEach-Object FullName) }
      if ($Action -in 'install','full' -and $got.Count -gt 0) {
        $script:St.phase='install'; Save
        $script:St.result=Install-Msus $got; Save
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
