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
$npRegion   = Region 'WU-NOTPACKAGE'
$cvRegion   = Region 'WU-CATALOG-VALID'
$infoRegion = Region 'WU-INFO-EXCLUDE'

# Defect knobs rewrite the SHIPPED text back to its pre-fix form.
switch ($Defect) {
    'rcalone'   { $exeRegion  = $exeRegion  -replace '\$ok = \$eff', '$ok = ($p.ExitCode -eq 0) -or $eff'
                  $exeRegion  = $exeRegion  -replace "\`$sev='info'", "`$sev=`$null" }
    'noticeonly'{ $infoRegion = $infoRegion -replace '(?s)else \{ @\(\$after \| Where-Object \{ \(& \$notInfo \$_\) \}\)\.Count \}', 'else { $after.Count }' }
    'kbonly'    { $infoRegion = $infoRegion -replace '-and \(\$infoKbs -notcontains \$r\.title\)', '' }
    'rcinfers'  { $npRegion = $npRegion -replace '(?s)\$mum = \$null.*?\n      \}', '$mum = $null' }
    'trustzero' { $cvRegion = $cvRegion -replace '(?s)if \(\[string\]::IsNullOrWhiteSpace.*?\n  \}', '' }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (rcalone | noticeonly | kbonly | rcinfers | trustzero)"; exit 2 }
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
# BOUNDING THE BLAST RADIUS. The whole risk of this classification is that it is the SAME SHAPE as
# a silent failure, so it must be reachable only where we have a probe that actually measures the
# thing. An executable we cannot measure must NEVER be marked not-actionable, whatever it returns -
# otherwise a genuinely installable update could be quietly excluded and dom0 would go silent about
# it, which is the original field defect wearing this fix as a disguise.
$r = RunExe $null $false $false 0
Check "exe: NO probe at all -> never 'info', however it exits" ([string]$r.sev) ''
$r = RunExe $null $false $false 1603
Check "exe: NO probe, nonzero rc -> ok false, still never 'info'" "$($r.ok)/$([string]$r.sev)" 'False/'

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

# ---------- THE POSITIVE CONTROL: Patch Tuesday content must never be excluded ----------
# Ground truth we always have: a Patch Tuesday cumulative IS installable on a guest that is behind.
# If the classification can ever swallow one, dom0 goes quiet about a real update - GWeck's defect
# resurrected by its own fix. A cumulative arrives as .msu and is decided by DISM, so it cannot
# reach the exe branch at all; assert that it is counted whenever it is not itself informational.
$tuesday = @(
    [pscustomobject]@{ kb = 'KB5129195'; title = '2026-09 Cumulative';  content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform';   content_class = 'self-contained' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$infoOnlyTheUnactionable = @(
    [pscustomobject]@{ kb = 'KB5007651'; severity = 'info' },
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; severity = 'info' }
)
Check "CONTROL: a pending Patch Tuesday cumulative is STILL counted while the others are excluded" `
      (RunCount $tuesday $infoOnlyTheUnactionable $null) 1
# And the failing case this control exists to catch: if the cumulative were ever marked info, dom0
# would hear 0 with a real update pending. That must be visible as a distinct number, not hidden.
$infoIncludingCumulative = $infoOnlyTheUnactionable + @([pscustomobject]@{ kb = 'KB5129195'; severity = 'info' })
Check "CONTROL: if the cumulative were wrongly excluded dom0 would hear 0 - proving the count is what carries it" `
      (RunCount $tuesday $infoIncludingCumulative $null) 0

# ---------- WU-NOTPACKAGE: a corrupt download must never become 'informational' ----------
# Jev's defect hunt, 2026-09-20: ERROR_FILE_NOT_FOUND / ERROR_INVALID_DATA / CBS_E_INVALID_PACKAGE
# are NOT exclusive to WU-client blobs - a TRUNCATED download produces them too, and relay
# truncation on large files is a known failure mode on this path. Inferring "informational" from
# the code alone let a corrupt cumulative be filed as nothing-to-worry-about.
$script:expandOut = ''
function expand.exe { param([Parameter(ValueFromRemainingArguments=$true)]$a) $script:expandOut }
function NotPackage($rc, $expandOutput) {
    $script:expandOut = $expandOutput
    $dst = 'C:\x.msu'; $name = 'x.msu'; $OK_RC = @(0, 3010, 2359302); $notPackage = $false; $mum = $null
    Invoke-Expression $npRegion
    return $notPackage
}
$realPkg = "Microsoft (R) File Expansion Utility`nupdate.mum`nupdate.cat`npackage.cab"
$blob    = "Microsoft (R) File Expansion Utility`nwuclient.dll`nsetup.xml"
Check "notpkg: DISM invalid-data but the file CONTAINS update.mum -> NOT informational (corrupt download)" (NotPackage 13 $realPkg) 'False'
Check "notpkg: DISM invalid-data and NO update.mum -> informational (a genuine WU-client blob)"            (NotPackage 13 $blob)    'True'
Check "notpkg: DISM file-not-found but the file CONTAINS update.mum -> NOT informational"                  (NotPackage 2  $realPkg) 'False'
Check "notpkg: CBS_E_INVALID_PACKAGE on a real package -> NOT informational"                               (NotPackage -2146498555 $realPkg) 'False'
Check "notpkg: expand produced nothing readable -> NOT informational (unreadable is corruption)"           (NotPackage 13 '')       'False'
Check "notpkg: a success code is never reclassified"                                                       (NotPackage 0  $blob)    'False'

# ---------- WU-CATALOG-VALID: a broken response is not "no package" ----------
# Jev: is_defect 0.94, severity high-silently-hides-real-updates 1.00, self_corrects 0.21.
function CatalogUnresolved($content) {
    $r = [pscustomobject]@{ Content = $content }
    $kb = 'KB5129195'
    $script:CatalogUnresolved = $false
    try { Invoke-Expression $cvRegion } catch { }
    return $script:CatalogUnresolved
}
$realPage  = "<html><body><table id='ctl00_catalogBody_updateMatches'>...</table></body></html>"
$noResults = "<html><body><div id='ctl00_catalogBody_noResultText'>We did not find any results</div></body></html>"
Check "catalog: a real results page -> resolved (a zero count there is believable)"      (CatalogUnresolved $realPage)  'False'
Check "catalog: the catalog's own no-results page -> resolved (genuinely zero)"          (CatalogUnresolved $noResults) 'False'
Check "catalog: EMPTY body -> UNRESOLVED (truncated, not 'no package')"                  (CatalogUnresolved '')         'True'
Check "catalog: a truncated fragment -> UNRESOLVED"                                       (CatalogUnresolved '<html><body>') 'True'
Check "catalog: a proxy error page -> UNRESOLVED"                                         (CatalogUnresolved '<html><h1>502 Bad Gateway</h1></html>') 'True'

Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
