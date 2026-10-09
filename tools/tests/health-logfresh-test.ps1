# health-logfresh-test.ps1 - the agent-log freshness anchor, run offline against a fake log tree.
#
# WHY. agent_log_healthy counted gui-agent logs "newer than Win32_OperatingSystem.LastBootUpTime".
# MEASURED 2026-10-09 on win11-acc: the guest boots with a clock ~3 h ahead (this rig's local
# offset), Windows stamps LastBootUpTime in that window, our clock sync corrects the RUNNING clock
# to real UTC, and the stamp is never corrected - (Get-Date) - LastBootUpTime read -10576 s, a boot
# "in the future". "Newer than boot" was then empty on healthy guests and failed FIVE of the eight
# cells of the 4.3.36 release gate (agent pid 7648 running, watchdog Running), which also dragged
# idd_agent_identified down because it reads this boot's log.
# Jev: where_to_fix = the-check-must-not-anchor-on-lastbootuptime 0.99;
# check_can_still_catch_a_silent_agent 0.81; is_the_goal_breached 0.09.
#   pwsh health-logfresh-test.ps1 -Script <path-to-health-check.ps1>
#   env LOGFRESH_DEFECT=bootonly  restores the old unconditional boot filter - must then FAIL.
param([Parameter(Mandatory)][string]$Script)
$ErrorActionPreference = 'Continue'
$src = Get-Content -LiteralPath $Script -Raw
$m = [regex]::Match($src, "# ---- AGENT-LOG-FRESHNESS-BEGIN[^\n]*\n(.*?)# ---- AGENT-LOG-FRESHNESS-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: region AGENT-LOG-FRESHNESS not found"; exit 2 }
$region = $m.Groups[1].Value
if ($region -notmatch 'Init:') { Write-Output "INSTRUMENT: the region no longer anchors on the agent's Init line"; exit 2 }
if ($env:LOGFRESH_DEFECT -eq 'bootonly') {
    $region = '$bootSkewS = $null; $bootUsable = $true; $allAgentLogs = @($logDirs | ForEach-Object { Get-ChildItem $_ -Filter ''gui-agent-*.log'' -ErrorAction SilentlyContinue }); $logsThisBoot = @($allAgentLogs | Where-Object { $boot -and $_.LastWriteTime -gt $boot })'
}

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$ev='') {
  if ($ok) { $script:pass++; Write-Output "  ok   $what" }
  else { $script:fail++; Write-Output "  FAIL $what$(if($ev){" [$ev]"})" }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('logfresh-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function mklog([string]$name, [datetime]$mtime, [bool]$withInit) {
  $f = Join-Path $tmp $name
  Set-Content -LiteralPath $f -Value $(if ($withInit) { "[x] Init: WGCBROKER gate enabled`nsome work" } else { "some work only" })
  (Get-Item $f).LastWriteTime = $mtime
  return $f
}
$logDirs = @($tmp)
$now = Get-Date

# ---- 1. A SANE CLOCK behaves exactly as before: only logs after boot count ---------------------
Get-ChildItem $tmp -Filter '*.log' | Remove-Item -Force
[void](mklog 'gui-agent-old.log'  $now.AddHours(-5) $true)
[void](mklog 'gui-agent-this.log' $now.AddMinutes(-2) $true)
$boot = $now.AddMinutes(-10)
. ([scriptblock]::Create($region))
Check 'sane clock: the boot stamp is used and reads usable' ($bootUsable -eq $true) "usable=$bootUsable"
Check 'sane clock: only the log written after boot is counted' ($logsThisBoot.Count -eq 1 -and $logsThisBoot[0].Name -eq 'gui-agent-this.log') `
      "count=$($logsThisBoot.Count) names=$(($logsThisBoot | ForEach-Object Name) -join ',')"

# ---- 2. A BOOT IN THE FUTURE: the measured failure. The healthy guest must still be judged -----
$boot = $now.AddHours(3)
. ([scriptblock]::Create($region))
Check 'boot in the future: the stamp is reported UNUSABLE, not obeyed' ($bootUsable -eq $false) "usable=$bootUsable"
Check 'boot in the future: the skew is reported so the clock defect is visible' ($bootSkewS -lt -3000) "skew=$bootSkewS"
Check 'boot in the future: the newest log carrying an Init is still found (no false NONE)' `
      ($logsThisBoot.Count -eq 1 -and $logsThisBoot[0].Name -eq 'gui-agent-this.log') `
      "count=$($logsThisBoot.Count) names=$(($logsThisBoot | ForEach-Object Name) -join ',')"

# ---- 3. A GENUINELY SILENT AGENT STILL FAILS, with the stamp unusable --------------------------
Get-ChildItem $tmp -Filter '*.log' | Remove-Item -Force
. ([scriptblock]::Create($region))
Check 'silent agent, unusable stamp: NO log at all is still nothing (the real failure mode survives)' `
      ($logsThisBoot.Count -eq 0) "count=$($logsThisBoot.Count)"

# ---- 4. a log with NO Init is not accepted as an instance --------------------------------------
[void](mklog 'gui-agent-noinit.log' $now.AddMinutes(-1) $false)
. ([scriptblock]::Create($region))
Check 'unusable stamp: a log with no Init line is NOT taken for the current instance' `
      ($logsThisBoot.Count -eq 0) "count=$($logsThisBoot.Count) names=$(($logsThisBoot | ForEach-Object Name) -join ',')"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Output ""
if ($fail -eq 0) { Write-Output "PASS  the freshness anchor survives a corrected clock and still catches a silent agent"; exit 0 }
Write-Output "FAIL  $fail check(s)"; exit 1
