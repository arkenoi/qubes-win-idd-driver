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
param([string]$Defect = '', [string]$ScriptPath = '')

$ErrorActionPreference = 'Stop'
# -ScriptPath lets the SAME suite run against the file that is actually INSTALLED ON A GUEST, not
# only the repo copy - which is the difference between "the logic is right" and "the artefact that
# shipped executes it".
if ($ScriptPath) { $script = $ScriptPath }
else {
  $root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script = Join-Path $root 'guest/qubes-windows-update.ps1'
}
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
$nkRegion   = Region 'WU-NOKB'
$scRegion   = Region 'WU-SCAN-COUNT'
$infoRegion = Region 'WU-INFO-EXCLUDE'

# Defect knobs rewrite the SHIPPED text back to its pre-fix form.
switch ($Defect) {
    # Literal .Replace, not -replace: '$' is regex end-of-anchor and PowerShell also interpolates it
    # inside double quotes, and between them the old pattern silently matched NOTHING once the code
    # it targeted moved. A knob that matches nothing reports the guard as decoration.
    'rcalone'   { $exeRegion  = $exeRegion.Replace('$ok = $eff', '$ok = ($p.ExitCode -eq 0) -or $eff').Replace('$ok=$false', '$ok=($p.ExitCode -eq 0)') }
    'noticeonly'{ $infoRegion = $infoRegion -replace '(?s)else \{ @\(\$after \| Where-Object \{ \(& \$notInfo \$_\) \}\)\.Count \}', 'else { $after.Count }' }
    'kbonly'    { $infoRegion = $infoRegion -replace '-and \(\$infoKbs -notcontains \$r\.title\)', '' }
    'rcinfers'  { $npRegion = $npRegion -replace '(?s)\$mum = \$null.*?\n      \}', '$mum = $null' }
    'trustzero' { $cvRegion = $cvRegion -replace '(?s)if \(\[string\]::IsNullOrWhiteSpace.*?\n  \}', '' }
    'shapeskip' { $nkRegion = $nkRegion -replace '(?s)if\(\$nokbUrls\.Count -gt 0.*?\n        \}', '' }
    'infoonly'  { $script:InfoOnly = $true }
    # Re-introduces the classification corrected on 2026-09-20: a negative probe with rc=0 read as
    # "nothing to do on this image" instead of as a failed install. The two exe checks above must
    # then fail - that is what makes them evidence rather than decoration.
    'infobenign'{ $exeRegion  = $exeRegion.Replace('$ok=$false', '$sev=''info''; $ok=$true') }
    # Ignores the offer identity entirely - the state before GUARD:offeridentity, where a scan
    # re-counted an offer the previous pass had resolved and proved.
    'satignore' { $scRegion = $scRegion.Replace('-and (& $notPriorSat $r)', '') }
    # Drops the carry-forward: the scan consumes the identities and writes an empty list back, so
    # the knowledge lasts exactly one scan.
    'satdrop'   { $scRegion = $scRegion.Replace('$script:St.satisfied = @($priorSat)', '') }
    'scanall'   { $scRegion = $scRegion -replace '\$reportCount = @\(\$avail \| Where-Object \{ \(& \$notPriorInfo \$_\) \}\)\.Count', '$reportCount = $avail.Count' }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (rcalone | noticeonly | kbonly | rcinfers | trustzero | shapeskip | infoonly | scanall | infobenign | satignore | satdrop)"; exit 2 }
}

function Log($m) { }   # the regions log; the suite does not care what they print
# The SHIPPED Test-RowKey, extracted from the same file rather than re-implemented here - the
# regions call it, and without it they throw straight into their own catch and silently behave as
# if there were no prior state at all. That is how a passing-looking suite can test nothing.
$rkRegion = [regex]::Match($src, "function Test-RowKey.*?# ---- WU-ROWKEY-END", 'Singleline').Value
if (-not $rkRegion) { Write-Output "INSTRUMENT: Test-RowKey not found in the shipped script"; exit 2 }
Invoke-Expression ($rkRegion -replace '# ---- WU-ROWKEY-END', '')
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
# CORRECTED 2026-09-20 - these two checks encoded the WRONG behaviour and passed on it. The
# shipped code used to read its own negative probe as "the image is already current" and mark the
# row info/ok. For the item this was written for that inference is false: the offered installer
# carries Microsoft.SecHealthUI 1000.29628.1000.0, the guest has 1000.26100.8036.0 in both the
# installed AND the provisioned package, and the payload is applicable to this build. rc=0 with
# nothing moved is a FAILED INSTALL and stays actionable. (Jev: concealed-failure 0.87.)
Check "exe: rc=0 + probe ran + no effect -> NOT informational (a silent failure)" $r.sev ''
Check "exe: rc=0 + probe ran + no effect -> ok FALSE (nothing landed, so nothing succeeded)" $r.ok 'False'
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
function RunCount($after, $result, $notice, $available) {
    # The shipped $script:St is an [ordered]@{} and the region now also WRITES $script:St.satisfied
    # (GUARD:offeridentity). A PSCustomObject cannot take a new property, so the stub must be the
    # real shape - otherwise the test fails for the wrong reason, which is how a stub of the wrong
    # type already cost a debugging round on this same suite.
    $script:St = [ordered]@{ notice = $notice; available = @($available); satisfied = @() }
    # infoonly restores the pre-fix rule: only severity='info' drops out, so an update this pass
    # actually INSTALLED still counts and dom0 never reaches "up to date".
    $infoKbs = @($result | Where-Object { $_.severity -eq 'info' -or ((-not $script:InfoOnly) -and $_.ok -eq $true) } |
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

# ---------- WU-NOKB: a no-KB offer with a URL is INSTALLABLE, not 'not actionable' ----------
# Jev put 0.80 on a genuinely installable update legitimately lacking a KB. Get-Available computes
# direct_urls for EVERY offer, so a no-KB offer can be self-contained with a working URL - the old
# code skipped on the SHAPE of the KB field before looking, and threw that away.
$script:installCalled = $false
function Install-SelfContained($kb, $urls) { $script:installCalled = $true; return @(@{ ok = $true }) }
function NoKb($title, $urls, $action) {
    $script:installCalled = $false
    $script:St = [pscustomobject]@{ result = @() }
    $u = [pscustomobject]@{ kb = '(no KB)'; title = $title; direct_urls = $urls }
    $Action = $action
    function Save { }
    # The extracted region ends with `continue`. OUTSIDE A LOOP THAT SILENTLY TERMINATES THE
    # SCRIPT - the suite exited here with rc=0 before printing its own tally, and every defect knob
    # then reported "did not break the suite". Give `continue` a loop to belong to.
    foreach ($once in 1) { Invoke-Expression $nkRegion }
    $row = @($script:St.result)[0]
    return "$($script:installCalled)/$($row.state)/$([string]$row.severity)"
}
Check "nokb: HAS a direct URL on an install action -> INSTALLED, never excluded" `
      (NoKb 'AudioProcessingObject Driver Update' @('https://dl.example/x.exe') 'install') 'True/installed/'
Check "nokb: NO direct URL -> informational, with a measured reason" `
      (NoKb 'AudioProcessingObject Driver Update' @() 'install') 'False/not-actionable/info'
Check "nokb: has a URL but the action is only 'resolve' -> not installed, not excluded as a lie" `
      (NoKb 'Some driver' @('https://dl.example/x.exe') 'resolve') 'False/not-actionable/info'

if ($pass + $fail -eq 0) { Write-Output "INSTRUMENT: no checks ran at all"; exit 2 }
# ---------- GUARD:actioned: what the ADMIN must still do, not what WU keeps offering ----------
# Measured on the guest: a pass INSTALLED KB5007651 and found the Defender signatures current, both
# were still offered, both still counted, and dom0 sat at "updates available" for finished work.
$afterC = @(
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';     content_class = 'self-contained' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$resultC = @(
    [pscustomobject]@{ kb = 'KB5007651'; ok = $true;  state = 'installed' },
    [pscustomobject]@{ kb = 'KB2267602'; ok = $true;  severity = 'ok' },
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; ok = $true; severity = 'info' }
)
Check "actioned: everything installed/satisfied/unactionable -> dom0 reaches 0 (up to date)" (RunCount $afterC $resultC $null) 0
# ...and the control that must survive it: a DEFERRED cumulative is ok=false and stays counted.
$afterD = @([pscustomobject]@{ kb = 'KB5129195'; title = 'cumulative'; content_class = 'self-contained' }) + $afterC
$resultD = $resultC + @([pscustomobject]@{ kb = 'KB5129195'; ok = $false; state = 'deferred' })
Check "actioned: a DEFERRED cumulative is ok=false and STAYS counted -> dom0 hears 1" (RunCount $afterD $resultD $null) 1

# ---------- WU-SCAN-COUNT: a scan must not re-inflate what a pass already settled ----------
# Measured on the guest: an install pass drove dom0 to EMPTY, and the very next BOOT SCAN reported
# 3 again - the no-route driver plus two offers WU re-presents forever. dom0 oscillated 0 -> 3.
function ScanCount($avail, $prevResult) {
    # the shipped $script:St is an [ordered]@{} - the region ADDS a key to it, which a
    # PSCustomObject cannot take. Match the real shape or the test fails for the wrong reason.
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan-" + [guid]::NewGuid().ToString() + ".json")
    if ($null -ne $prevResult) { (@{ result = $prevResult } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile }
    $script:PrevStatus = if (Test-Path $StatusFile) { Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json } else { $null }
    $reportCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return $reportCount
}
$scanAvail = @(
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';     content_class = 'self-contained' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$priorNoRoute = @(
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; severity = 'info' }
)
Check "scan: no prior status -> every offer counts (a fresh guest must not be silenced)" (ScanCount $scanAvail $null) 3
Check "scan: a KB a previous pass proved NOT ACTIONABLE is excluded"                      (ScanCount $scanAvail $priorNoRoute) 2
# The conservative half: 'installed last time' must NOT silence a fresh offer on a scan.
$priorInstalled = @([pscustomobject]@{ kb = 'KB5007651'; ok = $true; state = 'installed' })
Check "scan: a KB merely INSTALLED last pass still counts on a scan (only a pass may judge that)" (ScanCount $scanAvail $priorInstalled) 3
# DURABLE: a scan writes result=[], so knowledge kept only in result rows survives one scan. The
# carry-forward field must keep it. Simulate the SECOND scan: no result rows, but not_actionable set.
function ScanCount2($avail, $notActionable) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan2-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = $notActionable } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
    $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
    $reportCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return $reportCount
}
Check "scan: the SECOND scan still excludes - the classification is durable, not one-shot" `
      (ScanCount2 $scanAvail @('AudioProcessingObject Driver Update')) 2

# GUARD:offeridentity. The oscillation that failed the bar on 2026-09-20: a pass installed a
# Defender signature and PROVED it by effect, dom0 went empty, and a scan 30 seconds later counted
# the very same offer again and put dom0 back to 1. A KB cannot decide this (signatures really are
# republished under one KB), so the offer's own UpdateID+RevisionNumber decides it.
function ScanCountId($avail, $satisfied) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan3-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = @(); satisfied = $satisfied } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
    $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
    $reportCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return $reportCount
}
$idAvail = @(
    [pscustomobject]@{ kb='KB2267602'; title='Defender defs'; content_class='self-contained'; uid='aaaa-1111'; rev=204 },
    [pscustomobject]@{ kb='KB5007651'; title='Security platform'; content_class='self-contained'; uid='bbbb-2222'; rev=7 }
)
Check "scan: the SAME offer identity a pass resolved is excluded" (ScanCountId $idAvail @('aaaa-1111:204')) 1
Check "scan: a NEW REVISION of that offer counts again (only the identity is trusted)" `
      (ScanCountId $idAvail @('aaaa-1111:203')) 2
Check "scan: an identity for a DIFFERENT offer excludes nothing here" (ScanCountId $idAvail @('zzzz-9999:1')) 2
Check "scan: offers with NO identity fall back to counting" (ScanCountId $scanAvail @('aaaa-1111:204')) 3
# DURABILITY. A scan writes its own status; if it does not write `satisfied` back, the knowledge
# survives exactly one scan and the next one re-counts. Measured on the guest 2026-09-21: the pass
# wrote two identities and the consuming scan wrote satisfied=[] straight back.
function ScanCarry($avail, $satisfied) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @(); satisfied = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan4-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = @(); satisfied = $satisfied } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
    $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
    $reportCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return (@($script:St.satisfied) -join ',')
}
Check "scan: the identities are CARRIED FORWARD, so a second scan still excludes" `
      (ScanCarry $idAvail @('aaaa-1111:204')) 'aaaa-1111:204' 

Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
