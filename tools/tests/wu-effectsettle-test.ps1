# wu-effectsettle-test.ps1 - runs the SHIPPED regions WU-REGWATCH (Get-EffectWatchKey, Test-EffectWouldFail) and WU-EFFECT-SETTLE of
# guest/qubes-windows-update.ps1 offline: when the agent reports success but the effect probe's artefact has not moved, the pass waits for
# the artefact (a registry change notification, armed before every read) and reads it again - for the verdict's DISAGREEMENT rows only,
# never past the deadline, and the expiry never passes a row. The probe reads inside the loop (WU-EFFECT-SETTLE-READ: the probes' own
# regions, replayed by wu-agentcache / wu-defplatform / wu-secplatform) are stood in by a scripted sequence; the registry watch by a fake
# that records arm / wait / stop. The cross-check runs the REAL WU-AGENT-VERDICT region: the wait and the verdict must agree on its rows.
#
# WHY (2026-10-03): the rz38b validation pass installed KB5007651 through the agent (Install() ResultCode 2 in 2 s), read the platform 1 s
# later - still the inbox one - and failed an update that had installed: the platform switched within 10 s, after the agent returned.
#   pwsh wu-effectsettle-test.ps1 [-Script <path>] [-Defect <knob>]
#   -Defect nowait         GUARD:settlewait never waits - the row is decided on the read right after the agent returned (the rz38b defect).
#   -Defect widen          GUARD:settlewhen waits on rows the verdict does not fail (a not-moved MRT row waits out the deadline).
#   -Defect dropsig        GUARD:settlewhen forgets the signature rows - the wait and the verdict disagree.
#   -Defect passonexpiry   GUARD:settledeadline counts the expiry as the effect (a timeout as a fix).
#   -Defect silentunarmed  GUARD:settleunarmed: a wait that could not be armed is not reported.
#   -Defect noarm          GUARD:settlearm arms nothing before the read.
#   -Defect bound          GUARD:settlebound is not the decided 60 s.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN[^\n]*\n(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found"; exit 2 }
    return $m.Groups[1].Value
}
$regRegion = Region 'WU-REGWATCH'
$settleRegion = Region 'WU-EFFECT-SETTLE'
$verdictRegion = Region 'WU-AGENT-VERDICT'
# The probes' reads are stood in: everything between the READ markers becomes one scripted read.
$fakeRead = @'
      $script:Reads++
      $script:ReadArmed += [bool]($watch -and $watch.armed)
      $st = $script:Seq[[Math]::Min($script:Reads - 1, $script:Seq.Count - 1)]
      $eff = [bool]$st.eff; $probeRan = [bool]$st.ran; $alreadyCurrent = [bool]$st.cur; $platBehind = [bool]$st.pb; $sigBehind = [bool]$st.sb; $secWhy = $null
'@
$m = [regex]::Match($settleRegion, "(?s)# ---- WU-EFFECT-SETTLE-READ-BEGIN.*?# ---- WU-EFFECT-SETTLE-READ-END[^\n]*\n")
if (-not $m.Success) { Write-Output 'INSTRUMENT: the READ markers inside WU-EFFECT-SETTLE were not found'; exit 2 }
$settleRegion = $settleRegion.Remove($m.Index, $m.Length).Insert($m.Index, $fakeRead + "`n")
# Every knob rewrites the ONE line that carries its guard tag.
$knobs = @{
    nowait        = @{ in = 'settle'; tag = 'settlewait';     with = '      break   # DEFECT: never waits' }
    widen         = @{ in = 'reg';    tag = 'settlewhen';     with = '    $true)   # DEFECT: every not-moved row waits' }
    dropsig       = @{ in = 'reg';    tag = 'settlewhen';     with = '    (($probe -eq ''security-platform'') -or ($probe -eq ''defender-platform'' -and $platBehind)))   # DEFECT: signature rows forgotten' }
    passonexpiry  = @{ in = 'settle'; tag = 'settledeadline'; with = '      if($ms -le 0){ $eff = $true   # DEFECT: the expiry counts as the effect' }
    silentunarmed = @{ in = 'settle'; tag = 'settleunarmed';  with = '      if(-not $watch.armed){ break   # DEFECT: not reported' }
    noarm         = @{ in = 'settle'; tag = 'settlearm';      with = '    $watch = $null   # DEFECT: nothing armed' }
    bound         = @{ in = 'reg';    tag = 'settlebound';    with = '$EffectSettleSec = 5   # DEFECT: not the decided bound' }
}
if ($Defect -and -not $knobs.ContainsKey($Defect)) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' ($(($knobs.Keys | Sort-Object) -join ' | '))"; exit 2 }
if ($Defect) {
    $k = $knobs[$Defect]
    $target = if ($k.in -eq 'reg') { $regRegion } else { $settleRegion }
    $d = [regex]::Replace($target, "(?m)^.*# GUARD:$($k.tag)\b.*$", $k.with.Replace('$', '$$'))
    if ($d -eq $target) { Write-Output "INSTRUMENT: GUARD:$($k.tag) not found"; exit 2 }
    if ($k.in -eq 'reg') { $regRegion = $d } else { $settleRegion = $d }
}
$script:LogLines = @()
function Log($m) { $script:LogLines += [string]$m }
Invoke-Expression $regRegion   # Get-EffectWatchKey, Test-EffectWouldFail and the real watch functions (replaced below - no registry here)
$shippedSec = $EffectSettleSec
function Start-RegistryWatch([string]$rel, [bool]$subtree) { $script:Arms++; [pscustomobject]@{ armed = -not $script:Unarmable; why = 'fake: cannot arm'; key = $null; ev = $null } }
function Wait-RegistryWatch($w, [int]$ms) { $script:Waits += $ms; if ($script:Wake) { return $true }; Start-Sleep -Milliseconds ([Math]::Max(0, $ms)); return $false }
function Stop-RegistryWatch($w) { if ($w) { $script:Stops++ } }
$script:fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }

# One run of the settle loop. $seq: the reads in order (the last one repeats); $wake: a wait returns as if the key changed.
function Run-Settle([string]$probe, [bool]$agentOk, [object[]]$seq, [bool]$wake, [bool]$unarmable, [int]$sec = 1) {
    $script:Reads = 0; $script:Arms = 0; $script:Stops = 0; $script:Waits = @(); $script:ReadArmed = @(); $script:LogLines = @()
    $script:Seq = $seq; $script:Wake = $wake; $script:Unarmable = $unarmable
    $EffectSettleSec = $sec; $label = 'KB5007651'
    $t0 = Get-Date
    Invoke-Expression $settleRegion
    [pscustomobject]@{ eff = [bool]$eff; reads = $script:Reads; arms = $script:Arms; stops = $script:Stops; waits = @($script:Waits).Count
                       armedAtEveryRead = (@($script:ReadArmed | Where-Object { -not $_ }).Count -eq 0); secs = ((Get-Date) - $t0).TotalSeconds
                       log = ($script:LogLines -join "`n") }
}
$notMoved = @{ eff = $false; ran = $true; cur = $false; pb = $false; sb = $false }
$moved    = @{ eff = $true;  ran = $true; cur = $false; pb = $false; sb = $false }
$current  = @{ eff = $false; ran = $true; cur = $true;  pb = $false; sb = $false }
$sigLow   = @{ eff = $false; ran = $true; cur = $false; pb = $false; sb = $true }
$platLow  = @{ eff = $false; ran = $true; cur = $false; pb = $true;  sb = $false }

$r = Run-Settle 'security-platform' $true @($notMoved, $moved) $true $false
Check 'lands: the platform has not moved on the first read, the wait is armed BEFORE every read, wakes, and the second read sees it moved - the latency is logged' `
      ($r.eff -and $r.reads -eq 2 -and $r.waits -eq 1 -and $r.armedAtEveryRead -and $r.arms -eq 2 -and $r.stops -eq 2 -and $r.log -match 'security-platform artefact moved [\d.,]+ s after the agent returned')
$r = Run-Settle 'security-platform' $true @($notMoved) $false $false 1
Check 'never: nothing moves - the wait ends at the deadline, the artefact is read once more AFTER it, the expiry decides nothing (still not moved) and says so' `
      (-not $r.eff -and $r.reads -ge 2 -and $r.waits -ge 1 -and $r.secs -ge 0.9 -and $r.secs -lt 5 -and $r.log -match 'did not move within 1 s of the agent returning')
$r = Run-Settle 'security-platform' $true @($current) $false $false
Check 'current: an artefact already at the offer is decided on the first read - no wait' ($r.reads -eq 1 -and $r.waits -eq 0 -and $r.log -notmatch 'waiting for it')
$r = Run-Settle 'security-platform' $true @($moved) $false $false
Check 'moved: an artefact that moved before the first read - no wait' ($r.eff -and $r.reads -eq 1 -and $r.waits -eq 0 -and $r.log -notmatch 'waiting for it')
$r = Run-Settle 'security-platform' $false @($notMoved) $false $false
Check 'agentfail: an agent failure is decided on the first read - nothing armed, no wait' ($r.reads -eq 1 -and $r.arms -eq 0 -and $r.waits -eq 0)
$r = Run-Settle 'security-platform' $true @($notMoved) $false $true
Check 'unarmed: a wait that cannot be armed is an ERROR naming why, the read decides, nothing polls in its place' `
      ($r.reads -eq 1 -and $r.waits -eq 0 -and $r.log -match 'ERROR: KB5007651 : the security-platform effect wait could not be armed on HKLM\\SOFTWARE\\Microsoft\\Windows Security Health \(fake: cannot arm\)')
$r = Run-Settle 'defender-signature' $true @($sigLow, $moved) $true $false
Check 'sigbehind: a signature row below the offer waits and is re-read' ($r.eff -and $r.reads -eq 2 -and $r.waits -eq 1)
$r = Run-Settle 'defender-platform' $true @($platLow, $moved) $true $false
Check 'platbehind: a Defender platform row below the offer waits and is re-read' ($r.eff -and $r.reads -eq 2 -and $r.waits -eq 1)
$r = Run-Settle 'mrt-version' $true @($notMoved) $false $false 1
Check 'mrt: a not-moved MRT row is not a DISAGREEMENT row - decided on the first read, no wait' ($r.reads -eq 1 -and $r.waits -eq 0)
$r = Run-Settle '' $true @($notMoved) $false $false
Check 'noprobe: an update with no effect probe arms nothing and does not wait' ($r.reads -eq 1 -and $r.arms -eq 0 -and $r.waits -eq 0)

# ---------- the wait and the REAL verdict agree: a row waits exactly when WU-AGENT-VERDICT would call it a DISAGREEMENT
function Verdict-Says([string]$probe, [bool]$agentOk, [bool]$ran, [bool]$eff, [bool]$cur, [bool]$pb, [bool]$sb) {
    $sb2 = [scriptblock]::Create(@'
param($probe, $agentOk, $probeRan, $eff, $alreadyCurrent, $platBehind, $sigBehind, $region)
function Log($m) { }
$script:St = [ordered]@{ reboot_needed = $false }
$agentRc = if ($agentOk) { 2 } else { 4 }; $agentHr = 0; $agentErr = $null; $missing = @(); $reboot = $false; $label = 'KBx'; $secWhy = $null
Invoke-Expression $region
[string]$reason
'@)
    return (& $sb2 $probe $agentOk $ran $eff $cur $pb $sb $verdictRegion)
}
$disagree = 0; $mismatch = @()
foreach ($probe in 'security-platform', 'defender-platform', 'defender-signature', 'mrt-version', '') {
  foreach ($agentOk in $true, $false) { foreach ($ran in $true, $false) { foreach ($eff in $true, $false) { foreach ($cur in $true, $false) {
    foreach ($pb in $true, $false) { foreach ($sb in $true, $false) {
      $v = (Verdict-Says $probe $agentOk $ran $eff $cur $pb $sb) -match '^DISAGREEMENT'
      if ($v) { $disagree++ }
      $w = Test-EffectWouldFail $agentOk $probe $ran $eff $cur $pb $sb
      if ($w -ne $v) { $mismatch += "$probe agentOk=$agentOk ran=$ran eff=$eff cur=$cur pb=$pb sb=$sb wait=$w verdict-disagree=$v" }
  } } } } } }
}
Check "agree: over 320 combinations the wait fires exactly on the verdict's DISAGREEMENT rows ($disagree of them)$(if ($mismatch.Count) { ' - first mismatch: ' + $mismatch[0] })" `
      ($mismatch.Count -eq 0 -and $disagree -gt 0)
Check 'bound: the shipped deadline is the decided 60 s (Jev 0.55, latency bracketed 1-10 s)' ($shippedSec -eq 60)

if ($script:fails -eq 0) { Write-Output 'PASS  the effect is waited for where the row would fail, armed before every read, bounded, and the expiry passes nothing'; exit 0 }
Write-Output "FAIL  $($script:fails) check(s)"; exit 1
