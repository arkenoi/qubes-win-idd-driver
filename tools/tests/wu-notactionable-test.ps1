# wu-notactionable-test.ps1 - replay the SHIPPED decision regions of guest/qubes-windows-update.ps1
# for the not-actionable classification, offline. No rig, no guest.
#
# It extracts two marked regions from the shipped script and runs them against synthetic inputs, so
# what is under test is the code that ships, not a copy of it here:
#   (the verdict on an installer-type update moved to WU-AGENT-VERDICT on 2026-10-03, when the updater stopped running vendor .exe
#   files itself; tools/tests/wu-agentcache-test.ps1 replays it. The WU-NOTPACKAGE region went with the DISM-on-static-content path.)
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

$cvRegion   = Region 'WU-CATALOG-VALID'
$nkRegion   = Region 'WU-NOKB'
$scRegion   = Region 'WU-SCAN-COUNT'
$infoRegion = Region 'WU-INFO-EXCLUDE'

# Defect knobs rewrite the SHIPPED text back to its pre-fix form.
switch ($Defect) {
    # Literal .Replace, not -replace: '$' is regex end-of-anchor and PowerShell also interpolates it
    # inside double quotes, and between them the old pattern silently matched NOTHING once the code
    # it targeted moved. A knob that matches nothing reports the guard as decoration.
    'noticeonly'{ $infoRegion = $infoRegion -replace '(?s)else \{ @\(\$after \| Where-Object \{ \(& \$notInfo \$_\) \}\)\.Count \}', 'else { $after.Count }' }
    'kbonly'    { $infoRegion = $infoRegion -replace '-and \(\$infoKbs -notcontains \$r\.title\)', '' }
    'trustzero' { $cvRegion = $cvRegion -replace '(?s)if \(\[string\]::IsNullOrWhiteSpace.*?\n  \}', '' }
    # drops the catalog-by-title route - the state before 2026-09-21, where a KB-less offer with
    # no direct URL was always excluded even when the catalog held a package for this architecture.
    'notitle'   { $nkRegion = $nkRegion.Replace('$drv = Resolve-DriverByTitle $nokb', '$drv = $null') }
    'shapeskip' { $nkRegion = $nkRegion -replace '(?s)if\(\$nokbUrls\.Count -gt 0.*?\n        \}', '' }
    # restores the pre-fix rule: only severity='info' drops out, so an update this pass
    # actually INSTALLED still counts and dom0 never reaches "up to date".
    'infoonly'  { $infoRegion = $infoRegion.Replace('($_.ok -eq $true -and ((-not (Test-RowKey $_ ''state'')) -or ($doneStates -contains [string]$_.state)))', '$false') }
    # treats a STAGED row as done - dom0 then hears 0 while a cumulative waits for a reboot
    'stageddone'{ $infoRegion = $infoRegion.Replace('($_.ok -eq $true -and ((-not (Test-RowKey $_ ''state'')) -or ($doneStates -contains [string]$_.state)))', '$_.ok -eq $true').Replace('if ($stagedN -gt $reportCount) { $reportCount = $stagedN }', '') }
    # Ignores the offer identity entirely - the state before GUARD:offeridentity, where a scan
    # re-counted an offer the previous pass had resolved and proved.
    'satignore' { $scRegion = $scRegion.Replace('@($avail | Where-Object { (& $notPriorSat $_) }).Count', '@($avail).Count') }
    # Drops the carry-forward: the scan consumes the identities and writes an empty list back, so
    # the knowledge lasts exactly one scan.
    'satdrop'   { $scRegion = $scRegion.Replace('$script:St.satisfied = @($priorSat)', '') }
    # the 2026-10-07 concealment, restored: report only what we can INSTALL, so an offer we cannot place
    # makes dom0 say "no updates available" while Windows goes on offering it (GWeck, forum #175)
    'scanhide'  { $scRegion = $scRegion.Replace('$reportCount = @($avail | Where-Object { (& $notPriorSat $_) }).Count', '$reportCount = $actionableCount') }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (noticeonly | kbonly | trustzero | shapeskip | infoonly | scanall | satignore | satdrop | stageddone | notitle)"; exit 2 }
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

# ---------- WU-INFO-EXCLUDE ----------
function RunCount($after, $result, $notice, $available, $rebootNeeded = $false) {
    # The stub must be the REAL shape: the shipped $script:St is an [ordered]@{}, the region writes
    # $script:St.satisfied, and it now reads $script:St.result and .reboot_needed. A PSCustomObject
    # cannot take a new property, and a stub missing .result makes the region compute over nothing
    # - which is how the staged-pending defect went untested: $infoKbs was built HERE, by the test,
    # so the shipped construction was never exercised at all. It is built inside the region now.
    $script:St = [ordered]@{ notice = $notice; available = @($available); satisfied = @();
                             result = @($result); reboot_needed = $rebootNeeded }
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
# Since 2026-10-03 that route is the agent's own installer (Install-ViaAgentCache, stubbed here); the region's decision is the same.
$script:installCalled = $false
function Install-ViaAgentCache($u) { $script:installCalled = $true; return [ordered]@{ kb = $u.title; ok = $true; state = 'installed'; files = @() } }
# The no-KB region now also tries the CATALOG BY TITLE when there is no direct URL, so the suite
# has to supply those two. $script:DrvFound decides whether the catalog has a package for this
# guest's architecture; $script:drvInstalled records that the driver path was taken.
function Resolve-DriverByTitle($title) {
    if ($script:DrvFound) { return @{ uid = 'test-uid'; url = 'https://dl.example/x.cab'; file = 'x.cab'; arch = 'amd64' } }
    return $null
}
function Install-DriverCab($cab, $label) {
    $script:drvInstalled = $true
    return [ordered]@{ file = 'x.inf'; rc = 0; ok = $true; verified_by_effect = $true; probe = 'pnputil-enum' }
}
function NoKb($title, $urls, $action) {
    $script:installCalled = $false; $script:drvInstalled = $false
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
function NoKbDrv($title, $found) { $script:DrvFound = $found; $r = NoKb $title @() 'install'; return "$r/drv=$($script:drvInstalled)" }
Check "nokb: HAS a direct URL on an install action -> INSTALLED, never excluded" `
      (NoKb 'AudioProcessingObject Driver Update' @('https://dl.example/x.exe') 'install') 'True/installed/'
$script:DrvFound = $false
Check "nokb: NO direct URL and no catalog match -> informational, with a MEASURED reason" `
      (NoKbDrv 'AudioProcessingObject Driver Update' $false) 'False/not-actionable/info/drv=False'
# The gap this closes: the catalog does hold such offers under their title, in per-architecture
# variants whose titles and product strings are byte-identical. When one matches THIS guest's
# architecture the item is installed, not excluded - and the row says installed, not info.
Check "nokb: no direct URL but the CATALOG has a package for this arch -> INSTALLED via the driver path" `
      (NoKbDrv 'AudioProcessingObject Driver Update' $true) 'False/installed//drv=True'
$script:DrvFound = $false
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

# GUARD:stagedpending. Measured 2026-09-21 on the PRE-TUESDAY CONTROL and invisible on an
# already-updated guest: a cumulative came back ok=true state=staged with reboot_needed=true, the
# bare `$_.ok -eq $true` rule swept it into the excluded set, and dom0 was told the template was UP
# TO DATE while the update sat waiting for a reboot. That is the field report's own defect, let in
# through the door opened to fix its opposite.
$afterS = @(
    [pscustomobject]@{ kb = 'KB5129195'; title = 'Cumulative'; content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; content_class = 'self-contained' }
)
$resultS = @(
    [pscustomobject]@{ kb = 'KB5129195'; title = 'Cumulative'; ok = $true; state = 'staged' },
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; ok = $true; state = 'installed' }
)
Check "staged: an ok=true STAGED cumulative is NOT done - dom0 still hears it" `
      (RunCount $afterS $resultS $null @() $true) 1
Check "staged: ...and an INSTALLED row beside it is still excluded" `
      (RunCount $afterS $resultS $null @() $true) 1
# The floor: whatever the per-row arithmetic says, a pending reboot is never "up to date".
$resultAllDone = @(
    [pscustomobject]@{ kb = 'KB5129195'; title = 'Cumulative'; ok = $true; state = 'installed' },
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; ok = $true; state = 'installed' }
)
# WITHDRAWN 2026-09-21: an earlier draft forced >=1 whenever a reboot was pending, even with every
# row done. That would pin a guest carrying a stale CBS RebootPending at "updates available"
# forever - the inverse defect the owner reported. The rule is exactly "count what is not applied".
Check "staged: reboot pending but every row DONE -> dom0 still reaches 0 (no blanket floor)" `
      (RunCount $afterS $resultAllDone $null @() $true) 0
Check "staged: no reboot pending and every row done -> dom0 does reach 0" `
      (RunCount $afterS $resultAllDone $null @() $false) 0

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
    $reportCount = -1; $actionableCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return @{ reported = $reportCount; actionable = $actionableCount; offered = $script:St.offered }
}
$scanAvail = @(
    [pscustomobject]@{ kb = 'KB5007651'; title = 'Security platform'; content_class = 'self-contained' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';     content_class = 'self-contained' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$priorNoRoute = @(
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; severity = 'info' }
)
Check "scan: no prior status -> every offer counts (a fresh guest must not be silenced)" (ScanCount $scanAvail $null).reported 3
# THE CONTRACT CHANGED ON 2026-10-07, and this suite had encoded the defect: it asserted that an offer a
# previous pass called not-actionable is SUBTRACTED from what dom0 is told, which is what made GWeck's Qube
# Manager say "no updates available" while his own Windows Update window listed KB5101684. dom0 hears the
# TRUE number of offers; the split is recorded for the pass's report (Jev: is_concealment 0.89,
# true-count-always 0.87). What we cannot install is not the same as nothing being available.
Check "scan: an offer a previous pass proved NOT ACTIONABLE is still COUNTED to dom0"     (ScanCount $scanAvail $priorNoRoute).reported 3
Check "scan: ...and the actionable split is recorded rather than hidden inside the count" (ScanCount $scanAvail $priorNoRoute).actionable 2
Check "scan: the offered count is recorded too"                                           (ScanCount $scanAvail $priorNoRoute).offered 3
# The conservative half: 'installed last time' must NOT silence a fresh offer on a scan.
$priorInstalled = @([pscustomobject]@{ kb = 'KB5007651'; ok = $true; state = 'installed' })
Check "scan: a KB merely INSTALLED last pass still counts on a scan (only a pass may judge that)" (ScanCount $scanAvail $priorInstalled).reported 3
# DURABLE: a scan writes result=[], so knowledge kept only in result rows survives one scan. The
# carry-forward field must keep it. Simulate the SECOND scan: no result rows, but not_actionable set.
function ScanCount2($avail, $notActionable) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan2-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = $notActionable } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
    $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
    $reportCount = -1; $actionableCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return @{ reported = $reportCount; actionable = $actionableCount; offered = $script:St.offered }
}
Check "scan: the SECOND scan still knows it is not actionable - the classification is durable, not one-shot" `
      (ScanCount2 $scanAvail @('AudioProcessingObject Driver Update')).actionable 2
Check "scan: ...and dom0 still hears all three, because durability must not become concealment" `
      (ScanCount2 $scanAvail @('AudioProcessingObject Driver Update')).reported 3

# THE OWNER'S STANDING EXCEPTION, kept: under the ESU servicing notice (netvm-free Win10 22H2, post-EOS) only
# self-contained updates are actionable AND that is what dom0 hears - "a Win10 22H2 guest reporting 0
# actionable updates with ESU items as info is CORRECT" (findings/updates.md). Jev confirmed the change above
# does not disturb it (0.28).
function ScanCountNotice($avail, $prevResult) {
    $script:St = [ordered]@{ notice = 'Windows 10 22H2 is past end of servicing (ESU)'; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscanN-" + [guid]::NewGuid().ToString() + ".json")
    if ($null -ne $prevResult) { (@{ result = $prevResult } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile }
    $script:PrevStatus = if (Test-Path $StatusFile) { Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json } else { $null }
    $reportCount = -1; $actionableCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return @{ reported = $reportCount; actionable = $actionableCount }
}
$esuAvail = @(
    [pscustomobject]@{ kb = 'KB5068781'; title = 'ESU cumulative';  content_class = 'express' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';   content_class = 'self-contained' }
)
Check "scan: under the ESU notice dom0 hears the ACTIONABLE count, as the owner ruled" (ScanCountNotice $esuAvail $null).reported 1

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
