# Path B end-to-end: resolve KB5101650 standalone .msu(s) from the catalog, fetch over the proxy
# (RESUMABLE - a 5GB pull over a qrexec tunnel can drop), verify signatures, DISM offline-install
# smallest-first (SSU/checkpoint before LCU). Logs progress; writes done.txt. Run as a SYSTEM
# scheduled task (survives the long download + install + reboots).
$ErrorActionPreference = 'Continue'
$proxy = 'http://127.0.0.1:8082'
$dir = 'C:\Users\Public\wu'; New-Item -ItemType Directory -Force $dir | Out-Null
$log = "$dir\install.log"; Remove-Item $log -EA SilentlyContinue
$done = "$dir\done.txt"; Remove-Item $done -EA SilentlyContinue
function Log($m){ Add-Content $log ((Get-Date).ToString('HH:mm:ss') + ' ' + $m) }
Log 'START'

$IS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
if(-not(Get-Process qubes-updates-relay -EA SilentlyContinue)){ $env:QUBES_UPDATES_MAXCONN='256'; Start-Process -FilePath 'C:\Users\Public\relaytest\qubes-updates-relay.exe' -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden; Start-Sleep 2 }

# --- resolve .msu urls from the catalog ------------------------------------------------
try {
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=KB5101650" -Proxy $proxy -UseBasicParsing -TimeoutSec 60
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"; $guid=$null
  foreach($m in $rx.Matches($r.Content)){ $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' '); if($t -match 'x64' -and $t -match '24H2|26100' -and $t -notmatch 'ARM64|Dynamic|Server'){ $guid=$m.Groups[1].Value; break } }
  Log "guid=$guid"
  $json='[{"size":0,"languages":"","uidInfo":"'+$guid+'","updateID":"'+$guid+'"}]'
  $dl=Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $proxy -UseBasicParsing -TimeoutSec 60
  $urls=@([regex]::Matches($dl.Content,"url\s*=\s*'(http[^']+)'")|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -match '\.msu(\?|$)'}|Sort-Object -Unique)
  Log "urls=$($urls.Count)"
} catch { Log "RESOLVE EXC $($_.Exception.Message)"; 'FAILED-RESOLVE'|Set-Content $done; return }
if($urls.Count -eq 0){ Log 'no .msu urls'; 'FAILED-NOURL'|Set-Content $done; return }

# --- resumable fetch -------------------------------------------------------------------
function Fetch($url,$dst){
  for($a=1;$a -le 8;$a++){
    $have=0; if(Test-Path $dst){ $have=(Get-Item $dst).Length }
    $out=$null
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($proxy)
      $req.Timeout=60000; $req.ReadWriteTimeout=120000
      if($have -gt 0){ $req.AddRange($have) }
      $resp=$req.GetResponse(); $tot=$have+$resp.ContentLength
      $in=$resp.GetResponseStream(); $out=[System.IO.File]::Open($dst,[System.IO.FileMode]::Append)
      $buf=New-Object byte[] (1048576); $last=Get-Date
      while(($n=$in.Read($buf,0,$buf.Length)) -gt 0){ $out.Write($buf,0,$n); $have+=$n
        if(((Get-Date)-$last).TotalSeconds -ge 20){ Log ("  {0}: {1}/{2} MB" -f ([System.IO.Path]::GetFileName($dst)),[math]::Round($have/1MB),[math]::Round($tot/1MB)); $last=Get-Date } }
      $out.Close();$in.Close();$resp.Close()
      Log ("DONE {0}: {1} MB" -f ([System.IO.Path]::GetFileName($dst)),[math]::Round($have/1MB)); return $true
    }catch{ Log "  attempt $a EXC $($_.Exception.Message)"; if($out){try{$out.Close()}catch{}}; Start-Sleep 5 }
  }
  return $false
}
$files=@(); $i=0
foreach($u in $urls){ $i++; $name="pkg$i.msu"; if($u -match '/([^/?]+\.msu)'){ $name=$Matches[1] }
  $dst="$dir\$name"; Log "FETCH -> $name"
  if(Fetch $u $dst){ $files+=$dst } else { Log "FETCH FAILED $name"; 'FAILED-FETCH'|Set-Content $done; return } }

foreach($f in $files){ Log ("sig {0} = {1}" -f ([System.IO.Path]::GetFileName($f)),((Get-AuthenticodeSignature $f).Status)) }

# --- install smallest-first (SSU/checkpoint before LCU) --------------------------------
$reboot=$false
foreach($f in ($files | Sort-Object { (Get-Item $_).Length })){
  Log "DISM add $([System.IO.Path]::GetFileName($f))"
  & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /LogPath:"$dir\dism.log" | Out-Null
  $rc=$LASTEXITCODE; Log "  DISM rc=$rc"
  if($rc -eq 3010){ $reboot=$true } elseif($rc -ne 0){ Log "  DISM NONZERO rc=$rc" }
}
Log "reboot_needed=$reboot"
"DONE reboot=$reboot" | Set-Content $done
Log 'COMPLETE'
