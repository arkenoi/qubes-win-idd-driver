# A1 AUDIT: is the staging framebuffer grant actually being returned?
#
# capture.c grants ~7200 pages once per AGENT START (StagingEnsure) and revokes it in exactly ONE
# place - CaptureStagingRevokeOnExit, at the tail of WatchForEvents, i.e. the GRACEFUL exit path,
# best effort. A crash, a kill, or a watchdog respawn never reaches it; and even the graceful path
# leaks if dom0 still maps the pages.
#
# So the leak is measurable from the agent's own logs:
#     grants  = "STAGING granted N pages"
#     returns = "STAGING revoked on exit (N pages)"
#     loud leaks = "STAGING revoke failed on exit"
#     silent leaks = grants - returns - loud     (agent died without reaching the exit path)
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\gui-staging-audit.txt'
$L=@()

$ld='Q:\Qubes Logs'
if(-not (Test-Path $ld)){ $ld='C:\Program Files\Qubes Tools\log' }
$L += ("log dir: " + $ld + " exists=" + (Test-Path $ld))
$logs = Get-ChildItem $ld -Filter 'gui-agent*.log' -EA SilentlyContinue | Sort-Object LastWriteTime
$L += ("gui-agent log files: " + @($logs).Count)
if(@($logs).Count){
  $L += ("  oldest: " + $logs[0].Name + "  " + $logs[0].LastWriteTime)
  $L += ("  newest: " + $logs[-1].Name + "  " + $logs[-1].LastWriteTime)
}

$grant=0; $revoked=0; $failed=0; $pages=0
$perFile=@()
foreach($f in $logs){
  $txt = Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue
  if(-not $txt){ continue }
  $g = ([regex]::Matches($txt,'STAGING granted (\d+) pages'))
  $r = ([regex]::Matches($txt,'STAGING revoked on exit'))
  $x = ([regex]::Matches($txt,'STAGING revoke failed on exit'))
  $grant += $g.Count; $revoked += $r.Count; $failed += $x.Count
  foreach($m in $g){ $pages += [int]$m.Groups[1].Value }
  if($g.Count -or $r.Count -or $x.Count){
    $perFile += ("    " + $f.Name + "  granted=" + $g.Count + " revoked=" + $r.Count + " failed=" + $x.Count)
  }
}
$L += "--- per-log ---"
$L += $perFile | Select-Object -Last 12
$L += "--- totals across all logs on this guest ---"
$L += ("  agent starts that granted staging : " + $grant + "   (" + $pages + " pages total)")
$L += ("  clean returns (revoked on exit)   : " + $revoked)
$L += ("  loud leaks (revoke FAILED)        : " + $failed)
$silent = $grant - $revoked - $failed
$L += ("  silent leaks (died before exit)   : " + $silent)
$leakedPages = ($silent + $failed) * 7200
$L += ("  ESTIMATED leaked pages            : " + $leakedPages + "  (~" + [math]::Round($leakedPages*4096/1MB,1) + " MB of grant refs)")
$L += ("  NOTE: logs may predate the current boot; a rotated/cleaned log dir under-counts.")

# current state
$ga = Get-Process gui-agent -EA SilentlyContinue
$L += ("gui-agent running now: " + $(if($ga){'pid ' + ($ga.Id -join ',')}else{'no'}))
$L += ("gui-watchdog running now: " + [bool](Get-Process gui-watchdog -EA SilentlyContinue))
$L += ("uptime_min: " + [math]::Round(((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes,1))
# how many agent starts happened THIS boot
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$thisBoot = @($logs | Where-Object { $_.LastWriteTime -ge $boot })
$L += ("gui-agent logs written since boot: " + $thisBoot.Count)
foreach($f in $thisBoot){ $L += ("    " + $f.Name) }
$L | Out-File -LiteralPath $out -Encoding ASCII
