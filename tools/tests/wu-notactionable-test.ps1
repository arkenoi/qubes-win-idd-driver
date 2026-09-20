# wu-notactionable-test.ps1 - replay the SHIPPED decision regions of guest/qubes-windows-update.ps1
# for the not-actionable classification, offline. No rig, no guest.
#
# It extracts two marked regions from the shipped script and runs them against synthetic inputs, so
# what is under test is the code that ships, not a copy of it here:
#   WU-EXE-EFFECT-*     : GUARD:notactionable - rc=0 with a probe that RAN and saw nothing is
#                         'info' / not-actionable; a NONZERO rc with the same probe result is a
#                         FAILURE; a probe that did NOT run falls back to rc.
#   WU-INFO-EXCLUDE-*   : GUARD:infoalways + GUARD:nokbinfo - informational rows are excluded from
#                         dom0's actionable count ALWAYS (not only under the ESU notice), and the
#                         exclusion keys on kb AND title so a no-KB offer is actually excluded.
#
# -Defect <knob> re-introduces a specific defect so the suite MUST fail on the check that knob
# targets. A guard never seen to fail is decoration.
param([string]$Defect = '')

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $root 'guest/qubes-windows-update.ps1'
if (-not (Test-Path $script)) { Write-Output "INSTRUMENT: $script not found"; exit 2 }
$src = Get-Content -Raw $script

function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found in the shipped script"; exit 2 }
    return $m.Groups[1].Value
}

$exeRegion  = Region 'WU-EXE-EFFECT'
$infoRegion = Region 'WU-INFO-EXCLUDE'

# Defect knobs rewrite the SHIPPED text back to its pre-fix form.
switch ($Defect) {
    'rcalone'   { $exeRegion  = $exeRegion  -replace '\$ok = \$eff', '$ok = ($p.ExitCode -eq 0) -or $eff'
                  $exeRegion  = $exeRegion  -replace "\`$sev='info'", "`$sev=`$null" }
    'noticeonly'{ $infoRegion = $infoRegion -replace '(?s)else \{ @\(\$after \| Where-Object \{ \(& \$notInfo \$_\) \}\)\.Count \}', 'else { $after.Count }' }
    'kbonly'    { $infoRegion = $infoRegion -replace '-and \(\$infoKbs -notcontains \$r\.title\)', '' }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (rcalone | noticeonly | kbonly)"; exit 2 }
}

function Log($m) { }   # the regions log; the suite does not care what they print
$pass = 0; $fail = 0
function Check($label, $got, $want) {
    if ("$got" -eq "$want") { Write-Output "PASS  $label"; $script:pass++ }
    else { Write-Output "FAIL  $label (got '$got', want '$want')"; $script:fail++ }
}

# ---------- WU-EXE-EFFECT ----------
function RunExe($probe, $probeRan, $eff, $rc) {
    $p = [pscustomobject]@{ ExitCode = $rc }
    $name = 'securityhealthsetup_x.exe'; $shBefore = 'a|b'; $detail = ''
    $ok = $false; $sev = $null; $why = $null
    Invoke-Expression $exeRegion
    return @{ ok = $ok; sev = $sev; why = $why }
}

# The measured case: securityhealthsetup.exe, rc=0, probe ran, nothing changed.
$r = RunExe 'security-platform' $true $false 0
Check "exe: rc=0 + probe ran + no effect -> severity 'info' (not actionable)" $r.sev 'info'
Check "exe: rc=0 + probe ran + no effect -> ok stays true (it is satisfied, not failed)" $r.ok 'True'
# A real failure must NOT be laundered into 'info'.
$r = RunExe 'security-platform' $true $false 1603
Check "exe: rc<>0 + probe ran + no effect -> NOT info (a real failure)" ([string]$r.sev) ''
Check "exe: rc<>0 + probe ran + no effect -> ok false" $r.ok 'False'
# A real install.
$r = RunExe 'defender-signature' $true $true 0
Check "exe: probe ran AND effect seen -> ok true, not info" "$($r.ok)/$([string]$r.sev)" 'True/'
# A probe that could not run must fall back to rc, never report a false failure.
$r = RunExe 'security-platform' $false $false 0
Check "exe: probe DID NOT run -> falls back to rc=0, ok true" $r.ok 'True'

# ---------- WU-INFO-EXCLUDE ----------
function RunCount($after, $result, $notice) {
    $script:St = [pscustomobject]@{ notice = $notice }
    $infoKbs = @($result | Where-Object { $_.severity -eq 'info' } |
                 ForEach-Object { $_.kb; if ($_.title) { $_.title } } | Where-Object { $_ })
    $reportCount = 0
    Invoke-Expression $infoRegion
    return $reportCount
}
$after = @(
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform';  content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';      content_class = 'self-contained' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$result = @(
    [pscustomobject]@{ kb = 'KB5007651'; severity = 'info' },
    [pscustomobject]@{ kb = 'KB2267602'; severity = 'info' },
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; severity = 'info' }
)
Check "count: all three informational, no ESU notice -> dom0 hears 0 (it can reach 'up to date')" (RunCount $after $result $null) 0
$result2 = @([pscustomobject]@{ kb = 'KB5007651'; severity = 'info' })
Check "count: one informational, two real -> dom0 hears 2" (RunCount $after $result2 $null) 2
Check "count: nothing informational -> dom0 hears all 3" (RunCount $after @() $null) 3

Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
