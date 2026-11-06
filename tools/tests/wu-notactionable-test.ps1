# wu-notactionable-test.ps1 - replay the SHIPPED decision regions of guest/qubes-windows-update.ps1
# for the not-actionable classification, offline. No rig, no guest.
#
# It extracts two marked regions from the shipped script and runs them against synthetic inputs, so
# what is under test is the code that ships, not a copy of it here:
#   (the verdict on an installer-type update moved to WU-AGENT-VERDICT on 2026-10-03, when the updater stopped running vendor .exe
#   files itself; tools/tests/wu-agentcache-test.ps1 replays it. The WU-NOTPACKAGE region went with the DISM-on-static-content path.)
#   WU-INFO-EXCLUDE-*   : what drops out of dom0's post-install count (ADR-updater section 2): an offer this pass
#                         INSTALLED and proved installed (point 3, Test-RowInstalled; keyed on kb AND title so an
#                         installed no-KB driver drops out), and St.unroutable - the offers THIS pass verified have
#                         no route (WU-ROUTE-PROOF, point 5); the regions consume that set, the proof itself (a
#                         Catalog ask) runs outside them. An informational row is still COUNTED (point 2).
#   Resolve-Catalog     : a THROW from the Catalog search is UNRESOLVED, memoised for the pass, never 'no package'.
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
$rpRegion   = Region 'WU-ROUTE-PROOF'

# Defect knobs rewrite the SHIPPED text back to its pre-fix form.
switch ($Defect) {
    # Literal .Replace, not -replace: '$' is regex end-of-anchor and PowerShell also interpolates it
    # inside double quotes, and between them the old pattern silently matched NOTHING once the code
    # it targeted moved. A knob that matches nothing reports the guard as decoration.
    'kbonly'    { $infoRegion = $infoRegion -replace '-and \(\$installedKeys -notcontains \$r\.title\)', '' }
    'trustzero' { $cvRegion = $cvRegion -replace '(?s)if \(\[string\]::IsNullOrWhiteSpace.*?\n  \}', '' }
    # drops the catalog-by-title route - the state before 2026-09-21, where a KB-less offer with
    # no direct URL was always excluded even when the catalog held a package for this architecture.
    'notitle'   { $nkRegion = $nkRegion.Replace('$drv = Resolve-DriverByTitle $nokb', '$drv = $null') }
    'shapeskip' { $nkRegion = $nkRegion -replace '(?s)if\(\$nokbUrls\.Count -gt 0.*?\n        \}', '' }
    # restores the pre-2026-09-20 rule: nothing a pass INSTALLED drops out, so dom0 never reaches "up to date".
    'infoonly'  { $infoRegion = $infoRegion.Replace('$installedKeys = @(Get-InstalledKeys)', '$installedKeys = @()') }
    # treats a STAGED row as done - dom0 then hears 0 while a cumulative waits for a reboot
    'stageddone'{ $infoRegion = $infoRegion.Replace('$installedKeys = @(Get-InstalledKeys)', '$installedKeys = @($script:St.result | Where-Object { $_.ok -eq $true } | ForEach-Object { $_.kb; $_.title } | Where-Object { $_ })').Replace('if ($stagedN -gt $reportCount) { $reportCount = $stagedN }', '') }
    # Ignores the offer identity entirely - the state before GUARD:offeridentity, where a scan
    # re-counted an offer the previous pass had resolved and proved.
    'satignore' { $scRegion = $scRegion.Replace('@($avail | Where-Object { (& $notPriorSat $_) -and (& $notUnroutable $_) }).Count', '@($avail | Where-Object { (& $notUnroutable $_) }).Count') }
    # Drops the carry-forward: the scan consumes the identities and writes an empty list back, so
    # the knowledge lasts exactly one scan.
    'satdrop'   { $scRegion = $scRegion.Replace('$script:St.satisfied = @($priorSat)', '') }
    # the 2026-10-07 concealment, restored: report only what we can INSTALL, so an offer we cannot place
    # makes dom0 say "no updates available" while Windows goes on offering it (GWeck, forum #175)
    'scanhide'  { $scRegion = $scRegion.Replace('$reportCount = @($avail | Where-Object { (& $notPriorSat $_) -and (& $notUnroutable $_) }).Count', '$reportCount = $actionableCount') }
    # restores the pre-2026-11-06 route proof for a no-KB offer: the title search is never answered at scan, so the offer is 'unknown'
    # and COUNTED for ever, even when every identically-titled package was inspected and none fits this architecture.
    'nokbroute' { $rpRegion = $rpRegion.Replace('$drv = Resolve-DriverByTitle $title', '$drv = @{ unresolved = $true }') }
    # restores the bare skip: a candidate whose download dialog lists no .cab package was passed over as if inspected, so a page of
    # such candidates ended as 'no candidate declares this architecture' - a VERIFIED miss the scan (since 2026-11-06) drops from dom0's count.
    'nocabskip' { $src = $src.Replace('if(-not $url){ $uninspected++; Log "    $uid : the download dialog lists no .cab package - not inspected"; continue }', 'if(-not $url){ continue }') }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (kbonly | trustzero | shapeskip | infoonly | scanhide | satignore | satdrop | stageddone | notitle | nokbroute | nocabskip)"; exit 2 }
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
function RunCount($after, $result, $notice, $available, $rebootNeeded = $false, $unroutable = @()) {
    # The stub must be the REAL shape: the shipped $script:St is an [ordered]@{}, the region writes
    # $script:St.satisfied, and it now reads $script:St.result and .reboot_needed. A PSCustomObject
    # cannot take a new property, and a stub missing .result makes the region compute over nothing
    # - which is how the staged-pending defect went untested: $infoKbs was built HERE, by the test,
    # so the shipped construction was never exercised at all. It is built inside the region now.
    $script:St = [ordered]@{ notice = $notice; available = @($available); satisfied = @();
                             result = @($result); reboot_needed = $rebootNeeded; unroutable = @($unroutable) }
    $reportCount = 0
    Invoke-Expression $infoRegion
    return $reportCount
}
# The informational rows in the shapes their writers produce: the express gate (KB5071959) and the fallback gate (KB4023057), both
# ok=$false, and the WU-NOKB skip (ok=$false state='not-actionable').
$after = @(
    [pscustomobject]@{ kb = 'KB5071959'; title = 'ESU enrollment';     content_class = 'express' },
    [pscustomobject]@{ kb = 'KB4023057'; title = 'Update Service components'; content_class = 'none' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$result = @(
    [pscustomobject]@{ kb = 'KB5071959'; ok = $false; severity = 'info' },
    [pscustomobject]@{ kb = 'KB4023057'; ok = $false; severity = 'info' },
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; ok = $false; state = 'not-actionable'; severity = 'info' }
)
# ADR-updater section 2 point 2 (amended 2026-11-01): an informational row is still COUNTED; point 5 - the offers THIS pass
# verified have no route (St.unroutable) - is the one exception. Since 2026-11-06 the route proof names the no-KB driver by its exact
# TITLE (point 5 extended); the two checks after the next leave it out by that key, and never by the '(no KB)' placeholder.
Check "count: three informational rows, none verified this pass -> all 3 COUNTED (point 2)" (RunCount $after $result $null) 3
Check "count: two of them in this pass's verified set -> only the no-KB driver is COUNTED" `
      (RunCount $after $result $null @() $false @('KB5071959','KB4023057')) 1
Check "count: the no-KB driver verified by its TITLE this pass (point 5 extended 2026-11-06) -> dom0 hears 0" `
      (RunCount $after $result $null @() $false @('KB5071959','KB4023057','AudioProcessingObject Driver Update')) 0
Check "count: the '(no KB)' placeholder in the verified set names nothing -> the driver is still COUNTED" `
      (RunCount $after $result $null @() $false @('KB5071959','KB4023057','(no KB)')) 1
$result2 = @([pscustomobject]@{ kb = 'KB5071959'; ok = $false; severity = 'info' })
Check "count: one verified no-route offer, two real -> dom0 hears 2" (RunCount $after $result2 $null @() $false @('KB5071959')) 2
Check "count: nothing informational -> dom0 hears all 3" (RunCount $after @() $null) 3

# ---------- THE POSITIVE CONTROL: Patch Tuesday content must never be excluded ----------
# Ground truth we always have: a Patch Tuesday cumulative IS installable on a guest that is behind.
# If the classification can ever swallow one, dom0 goes quiet about a real update - GWeck's defect
# resurrected by its own fix. A cumulative arrives as .msu and is decided by DISM, so it cannot
# reach the exe branch at all; assert that it is counted whenever it is not itself informational.
$tuesday = @(
    [pscustomobject]@{ kb = 'KB5129195'; title = '2026-09 Cumulative';  content_class = 'none' },
    [pscustomobject]@{ kb = 'KB5071959'; title = 'ESU enrollment';      content_class = 'express' },
    [pscustomobject]@{ kb = '';          title = 'AudioProcessingObject Driver Update'; content_class = 'none' }
)
$infoOnlyTheUnactionable = @(
    [pscustomobject]@{ kb = 'KB5071959'; ok = $false; severity = 'info' },
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; ok = $false; state = 'not-actionable'; severity = 'info' }
)
Check "CONTROL: a pending Patch Tuesday cumulative is STILL counted beside a verified no-route offer (and the no-KB driver)" `
      (RunCount $tuesday $infoOnlyTheUnactionable $null @() $false @('KB5071959')) 2
# And the failing case this control exists to catch: if the cumulative were ever in the verified set, dom0
# would hear only the driver with a real update pending. That must be visible as a distinct number, not hidden.
$infoIncludingCumulative = $infoOnlyTheUnactionable + @([pscustomobject]@{ kb = 'KB5129195'; ok = $false; severity = 'info' })
Check "CONTROL: if the cumulative were wrongly in the verified set dom0 would hear 1 - proving the count is what carries it" `
      (RunCount $tuesday $infoIncludingCumulative $null @() $false @('KB5071959','KB5129195')) 1

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
# A THROW from the search (run 9 on win10-tup: the Catalog refused 403 through the proxy ended the pass at 'resolve').
$rcFn = [regex]::Match($src, '(?s)function Resolve-Catalog\(\$kb\)\{.*?\n\}\r?\n').Value
$pnFn = [regex]::Match($src, '(?s)function Test-CatalogProvedNoPackage\(\$kb\)\{.*?\n\}\r?\n').Value
if (-not $rcFn -or -not $pnFn) { Write-Output "INSTRUMENT: Resolve-Catalog / Test-CatalogProvedNoPackage not found in the shipped script"; exit 2 }
Invoke-Expression $rcFn; Invoke-Expression $pnFn
function Resolve-CatalogUncached($kb) { $script:uncachedCalls++; throw 'The remote server returned an error: (403) Forbidden.' }
$script:CatalogAsked = $null; $script:uncachedCalls = 0; $script:CatalogUnresolved = $false
$thrown = @(Resolve-Catalog 'KB4023057')
Check "catalog: a THROW from the search -> no URLs and UNRESOLVED, the pass goes on" "$($thrown.Count)/$($script:CatalogUnresolved)" '0/True'
Check "catalog: ...and it is not 'no package' (an informational row needs a valid page)" (Test-CatalogProvedNoPackage 'KB4023057') 'False'
$script:CatalogUnresolved = $false; $thrown = @(Resolve-Catalog 'KB4023057')
Check "catalog: ...NOT memoised (a throw is no answer): asked again, UNRESOLVED again" "$($script:uncachedCalls)/$($script:CatalogUnresolved)" '2/True'

# A CANDIDATE WHOSE DOWNLOAD DIALOG NEVER ANSWERED is not "no package" (ADR-updater section 2 point 5). Until 2026-11-02 the shipped
# Resolve-CatalogUncached caught a refused DownloadDialog POST itself and returned a VERIFIED miss: replayed with KB5127648, the
# Win11 cumulative the Catalog serves, on a routeless guest it went to St.unroutable and out of dom0's count. The REAL functions run
# here; only the network is stubbed.
$rcuFn = [regex]::Match($src, '(?s)function Resolve-CatalogUncached\(\$kb\)\{.*?\n\}\r?\n').Value
$rdtFn = [regex]::Match($src, '(?s)function Resolve-DriverByTitle\(\$title\)\{.*?\n\}\r?\n').Value
if (-not $rcuFn -or -not $rdtFn) { Write-Output "INSTRUMENT: Resolve-CatalogUncached / Resolve-DriverByTitle not found in the shipped script"; exit 2 }
Invoke-Expression $rcuFn; Invoke-Expression $rdtFn
if (-not $env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE = 'AMD64' }   # pwsh on Linux has none; Resolve-DriverByTitle reads it
$OsArch = 'x64'; $OsBuild = '26200'; $OsVer = '25H2'; $Proxy = 'http://127.0.0.1:8082'; $AcceptLanguage = $null
$WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('wunotact-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $WorkDir | Out-Null
$script:CatPage = "<html><body><table id='ctl00_catalogBody_updateMatches'><a id='0a1b2c3d-0000-1111-2222-333344445555_link' href='#'>2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5127648)</a></table></body></html>"
function Invoke-WebRequest { param($Uri, $Method, $Body, $Proxy, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    if ($Uri -like '*Search.aspx*') {
        if ($script:SearchMode -eq 'throw') { throw 'The remote server returned an error: (403) Forbidden.' }
        return [pscustomobject]@{ Content = $script:CatPage } }
    switch ($script:DialogMode) {
        'throw' { throw 'The remote server returned an error: (403) Forbidden.' }
        'empty' { return [pscustomobject]@{ Content = '' } }
        'nomsu' { return [pscustomobject]@{ Content = "<html>downloadInformation[0].files = [];</html>" } }
        'msu'   { return [pscustomobject]@{ Content = "<html>downloadInformation[0].files[0].url = 'http://dl/windows11.0-kb5127648-x64_aa.msu';</html>" } }
        'cab'   { return [pscustomobject]@{ Content = "<html>url = 'http://dl/drv-amd64_aa.cab'</html>" } }
        'nocab' { return [pscustomobject]@{ Content = "<html>url = 'http://dl/drv-amd64_aa.exe'</html>" } }   # a package that is not a .cab: nothing this route can inspect
    } }
function Fetch-Msu($u, $f) { if ($script:FetchOk) { Set-Content -LiteralPath $f -Value 'x' } }
function Get-PackageArch($f) { return 'arm64' }   # never this guest's: a fetched candidate is inspected and does not match
function CatalogAfterDialog($mode) {
    $script:SearchMode = ''; $script:DialogMode = $mode; $script:CatalogAsked = $null; $script:CatalogUnresolved = $false
    $u = @(Resolve-Catalog 'KB5127648')
    return "{0}/{1}/{2}" -f $u.Count, $script:CatalogUnresolved, (Test-CatalogProvedNoPackage 'KB5127648')
}
Check "catalog: the download dialog REFUSED (403) -> UNRESOLVED, not proved 'no package'"  (CatalogAfterDialog 'throw') '0/True/False'
Check "catalog: the download dialog answered an EMPTY body -> UNRESOLVED, not proved"       (CatalogAfterDialog 'empty') '0/True/False'
Check "catalog: the dialog ANSWERED with no package -> a proved 'no package' (unchanged)"   (CatalogAfterDialog 'nomsu') '0/False/True'
Check "catalog: the dialog answered with this KB's .msu -> picked"                          (CatalogAfterDialog 'msu')   '1/False/False'
# The no-KB title route, the same rule: an unanswered search or an uninspected candidate is UNRESOLVED (WU-NOKB keeps the offer
# outstanding), and only a valid page with every candidate inspected may end in "no candidate for this architecture" ($null).
function TitleRoute($search, $dialog, $fetchOk) {
    $script:SearchMode = $search; $script:DialogMode = $dialog; $script:FetchOk = $fetchOk
    $script:TitleAsked = $null   # each scenario is its own pass: the per-pass title memo (one ask per title per pass) starts empty
    Remove-Item (Join-Path $WorkDir '*') -EA SilentlyContinue
    $d = Resolve-DriverByTitle 'AudioProcessingObject Driver Update'
    if ($null -eq $d) { return 'null' }; if ($d.unresolved) { return 'unresolved' }; return 'match'
}
$script:CatPage = "<html><body><table id='ctl00_catalogBody_updateMatches'><a id='0a1b2c3d-0000-1111-2222-333344445555_link' href='#'>AudioProcessingObject Driver Update</a></table></body></html>"
Check "title: the catalog search THREW -> unresolved (it ended the pass until 2026-11-02)"   (TitleRoute 'throw' '' $false) 'unresolved'
Check "title: a candidate's download dialog refused -> unresolved, not 'no candidate'"      (TitleRoute '' 'throw' $false) 'unresolved'
Check "title: a candidate's dialog answered empty -> unresolved"                           (TitleRoute '' 'empty' $false) 'unresolved'
Check "title: a candidate's package could not be fetched -> unresolved"                    (TitleRoute '' 'cab' $false)   'unresolved'
Check "title: a candidate's dialog lists no .cab package -> unresolved, not 'no candidate'" (TitleRoute '' 'nocab' $true) 'unresolved'
Check "title: every candidate inspected, none for this architecture -> null (a real miss)" (TitleRoute '' 'cab' $true)    'null'
$script:CatPage = '<html><h1>502 Bad Gateway</h1></html>'
Check "title: the search answered a proxy error page -> unresolved"                        (TitleRoute '' 'cab' $true)    'unresolved'
Remove-Item function:Invoke-WebRequest; Remove-Item -Recurse -Force $WorkDir -EA SilentlyContinue

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
    if ($script:DrvUnresolved) { return @{ unresolved = $true } }
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
# The title search itself unanswered (a throw, or not the Catalog's results page): Resolve-DriverByTitle says UNRESOLVED.
$script:DrvUnresolved = $true
Check "nokb: the catalog TITLE SEARCH unanswered -> an outstanding ok=false row, never the informational skip" `
      ("{0}/ok={1}" -f (NoKbDrv 'AudioProcessingObject Driver Update' $false), [string]@($script:St.result)[0].ok) 'False///drv=False/ok=False'
$script:DrvUnresolved = $false
Check "nokb: has a URL but the action is only 'resolve' -> not installed, not excluded as a lie" `
      (NoKb 'Some driver' @('https://dl.example/x.exe') 'resolve') 'False/not-actionable/info'

# ---------- WU-ROUTE-PROOF: an offer WITHOUT a KB is verified by its exact TITLE (ADR-updater section 2 point 5, extended 2026-11-06) ----------
# The shipped Test-OfferRoute / Measure-Unroutable / Get-NoRouteReason run here; Resolve-DriverByTitle is the stub above (DrvFound /
# DrvUnresolved) and the default route is a flag. Until 2026-11-06 a no-KB offer was 'unknown' at scan and COUNTED for ever, because
# point 5 needed a KB page.
$nrFn = [regex]::Match($src, '(?s)function Get-NoRouteReason\(\$kb, \$contentClass\) \{.*?\n\}\r?\n').Value
if (-not $nrFn) { Write-Output "INSTRUMENT: Get-NoRouteReason not found in the shipped script"; exit 2 }
Invoke-Expression $nrFn
Invoke-Expression $rpRegion
function RouteVerdicts($offers, $hasRoute, $found, $unresolved) {
    $script:HasDefaultRoute = $hasRoute; $script:DrvFound = $found; $script:DrvUnresolved = $unresolved; $script:CatalogAsked = $null
    $r = Measure-Unroutable $offers
    return "none=$(@($r.none) -join ',');unknown=$(@($r.unknown) -join ',')"
}
$drvOffer = [pscustomobject]@{ kb = '(no KB)'; title = 'AudioProcessingObject Driver Update'; content_class = 'none'; direct_urls = @() }
Check "route: a no-KB title MISS on a routeless guest -> VERIFIED no route, keyed by the TITLE" `
      (RouteVerdicts @($drvOffer) $false $false $false) 'none=AudioProcessingObject Driver Update;unknown='
Check "route: the same miss on a guest WITH a default route -> wu-native, COUNTED (in neither set)" `
      (RouteVerdicts @($drvOffer) $true $false $false) 'none=;unknown='
Check "route: the title search UNRESOLVED -> unknown, COUNTED, named in route_unknown" `
      (RouteVerdicts @($drvOffer) $false $false $true) 'none=;unknown=AudioProcessingObject Driver Update'
Check "route: the catalog HAS a package for this architecture -> the catalog route, COUNTED and installable" `
      (RouteVerdicts @($drvOffer) $false $true $false) 'none=;unknown='
Check "route: a no-KB offer WITH a direct URL is static (the agent's installer), never asked by title" `
      (RouteVerdicts @([pscustomobject]@{ kb = '(no KB)'; title = 'X'; content_class = 'none'; direct_urls = @('https://dl.example/x.exe') }) $false $false $false) 'none=;unknown='
Check "route: an offer with neither KB nor title cannot be verified -> COUNTED, in neither set" `
      (RouteVerdicts @([pscustomobject]@{ kb = '(no KB)'; title = ''; content_class = 'none'; direct_urls = @() }) $false $false $false) 'none=;unknown='
Check "route: the reason names the title and this architecture, in the dom0 user's words" `
      ((Get-NoRouteReason 'AudioProcessingObject Driver Update' 'none') -like "*valid results page for the title 'AudioProcessingObject Driver Update'*declares x64*no default route*") $true
# ...and the scan count takes the verified set by the same key: the title, never the '(no KB)' placeholder.
function ScanCountRoute($avail, $unroutable) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @(); unroutable = @($unroutable) }
    $script:PrevStatus = (@{ result = @(); not_actionable = @(); satisfied = @(); satisfied_rule = 'installed' } | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    $reportCount = -1
    Invoke-Expression $scRegion
    return $reportCount
}
$scanAvailDrv = @($drvOffer, [pscustomobject]@{ kb = 'KB5129195'; title = 'cumulative'; content_class = 'none' })
Check "scan: the no-KB driver verified by TITLE this pass is left out -> dom0 hears 1 (the cumulative)" (ScanCountRoute $scanAvailDrv @('AudioProcessingObject Driver Update')) 1
Check "scan: '(no KB)' in the set is not a key -> both COUNTED" (ScanCountRoute $scanAvailDrv @('(no KB)')) 2
Check "scan: nothing verified -> both COUNTED" (ScanCountRoute $scanAvailDrv @()) 2

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
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; ok = $false; state = 'not-actionable'; severity = 'info' }
)
# KB2267602's row has ok and no state - the shape Install-ViaWU writes (the agent's ResultCode 2/3) - and is installed too.
Check "actioned: installed rows drop out (state 'installed' and the stateless ok row) - only the no-KB driver, informational, is COUNTED" `
      (RunCount $afterC $resultC $null) 1
$resultCdrv = @($resultC[0], $resultC[1],
    [pscustomobject]@{ kb = 'AudioProcessingObject Driver Update'; title = 'AudioProcessingObject Driver Update'; ok = $true; state = 'installed' })
Check "actioned: an INSTALLED no-KB driver drops out by its TITLE -> dom0 reaches 0 (up to date)" (RunCount $afterC $resultCdrv $null) 0
# ...and the control that must survive it: a DEFERRED cumulative is ok=false and stays counted.
$afterD = @([pscustomobject]@{ kb = 'KB5129195'; title = 'cumulative'; content_class = 'self-contained' }) + $afterC
$resultD = $resultC + @([pscustomobject]@{ kb = 'KB5129195'; ok = $false; state = 'deferred' })
Check "actioned: a DEFERRED cumulative is ok=false and STAYS counted -> dom0 hears 2 (it and the no-KB driver)" (RunCount $afterD $resultD $null) 2

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

# THE ONE MEASURED EXCEPTION (ADR-updater section 2, point 5, amended 2026-11-01). Until then this case asserted the
# class rule: "under the ESU notice only self-contained offers count" - a blacklist by class on build 19045. Owner: "do we
# de-select ESU updates by class? that sucks ... select updates based on actual availability". Now an offer is left out of
# dom0's count only when THIS pass VERIFIED it has no route (a valid Catalog page with no package, no self-contained content,
# no default route) - the proof runs outside the region and lands in St.unroutable for this pass only; the region consumes it.
function ScanCountUnroutable($avail, $unroutable) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @(); unroutable = @($unroutable) }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscanU-" + [guid]::NewGuid().ToString() + ".json")
    $script:PrevStatus = $null
    $reportCount = -1; $actionableCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return @{ reported = $reportCount; actionable = $actionableCount }
}
$esuAvail = @(
    [pscustomobject]@{ kb = 'KB5071959'; title = 'ESU enrollment OOB';  content_class = 'express' },
    [pscustomobject]@{ kb = 'KB2267602'; title = 'Defender defs';       content_class = 'self-contained' }
)
Check "scan: an offer THIS pass VERIFIED has no route is left out of dom0's count"            (ScanCountUnroutable $esuAvail @('KB5071959')).reported 1
Check "scan: ...and out of the actionable split"                                             (ScanCountUnroutable $esuAvail @('KB5071959')).actionable 1
Check "scan: the SAME express offer with NO verification this pass is COUNTED (a class is not a verdict)" (ScanCountUnroutable $esuAvail @()).reported 2
Check "scan: a verification naming a KB that is not offered excludes nothing"                 (ScanCountUnroutable $esuAvail @('KB5068781')).reported 2

# GUARD:offeridentity. The oscillation that failed the bar on 2026-09-20: a pass installed a
# Defender signature and PROVED it by effect, dom0 went empty, and a scan 30 seconds later counted
# the very same offer again and put dom0 back to 1. A KB cannot decide this (signatures really are
# republished under one KB), so the offer's own UpdateID+RevisionNumber decides it.
function ScanCountId($avail, $satisfied) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan3-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = @(); satisfied = $satisfied; satisfied_rule = 'installed' } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
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
# A list an OLDER agent wrote (no satisfied_rule) held informational identities too (WUINFOIDENTITYREMEMBERED, run 9: dom0 told 0
# where the scan's own line said 2). It survives the upgrade in the status file, so the scan discards it once and measures again.
function ScanCountLegacy($avail, $satisfied) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @() }
    $script:PrevStatus = (@{ result = @(); not_actionable = @(); satisfied = $satisfied } | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    $reportCount = -1
    Invoke-Expression $scRegion
    return "$reportCount/$(@($script:St.satisfied) -join ',')"
}
Check "scan: a satisfied list with NO satisfied_rule (an older agent's) is discarded - both offers counted, nothing carried" `
      (ScanCountLegacy $idAvail @('aaaa-1111:204')) '2/'
# DURABILITY. A scan writes its own status; if it does not write `satisfied` back, the knowledge
# survives exactly one scan and the next one re-counts. Measured on the guest 2026-09-21: the pass
# wrote two identities and the consuming scan wrote satisfied=[] straight back.
function ScanCarry($avail, $satisfied) {
    $script:St = [ordered]@{ notice = $null; not_actionable = @(); satisfied = @() }
    $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("wuscan4-" + [guid]::NewGuid().ToString() + ".json")
    (@{ result = @(); not_actionable = @(); satisfied = $satisfied; satisfied_rule = 'installed' } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatusFile
    $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
    $reportCount = -1
    Invoke-Expression $scRegion
    Remove-Item $StatusFile -EA SilentlyContinue
    return (@($script:St.satisfied) -join ',')
}
Check "scan: the identities are CARRIED FORWARD, so a second scan still excludes" `
      (ScanCarry $idAvail @('aaaa-1111:204')) 'aaaa-1111:204' 

# ROUTED FOLD (ADR-updater section 2 point 5, third fact). The express gate writes its "no default route" row only on a routeless
# guest; where the Windows Update installer CAN run ($canWuNative: a measured default route, or the install loop's own knob
# QUBES_UPDATES_ALLOW_WU_NATIVE=1) the express-only offers join its set instead. Jev 2026-11-01: the only configuration that
# runs this code with a route is a TemplateVM given a netvm, which the rig may not create (templates stay netvm=''), so the
# fold is replayed here from the shipped text - extracted by its own first line, no marker added to the product.
$foldM = [regex]::Match($src, '(?s)\n  if \(\$canWuNative -and \$script:WuOnlyExpressKbs\.Count -gt 0\) \{.*?\n  \}')
if (-not $foldM.Success) { Write-Output "INSTRUMENT: the routed fold was not found in the shipped script"; exit 2 }
$foldRegion = $foldM.Value
function Fold($canWuNative, $hasRoute, $expressKbs) {
    $script:WuOnlyExpressKbs = @($expressKbs); $script:WuFallbackKbs = @('KB1111111'); $script:HasDefaultRoute = $hasRoute
    $script:foldLog = ''
    function Log($m) { $script:foldLog += "$m`n" }
    Invoke-Expression $foldRegion
    return @{ fallback = (@($script:WuFallbackKbs) -join ','); express = (@($script:WuOnlyExpressKbs) -join ','); log = $script:foldLog }
}
$r = Fold $true $true @('KB5071959')
Check "fold: with a default route an express-only offer joins the Windows Update installer's set"  $r.fallback 'KB1111111,KB5071959'
Check "fold: ...and leaves the express gate nothing to exclude"                                     $r.express ''
Check "fold: ...and the log names the measured route as the reason"                                 ($r.log -like '*this guest has a default route*') $true
$r = Fold $true $false @('KB5071959')
Check "fold: under the knob without a route the log names the knob, not a route"                    ($r.log -like '*QUBES_UPDATES_ALLOW_WU_NATIVE=1 forces*') $true
Check "fold: ...and the offer still joins the installer's set"                                      $r.fallback 'KB1111111,KB5071959'
$r = Fold $false $false @('KB5071959')
Check "fold: routeless and no knob: nothing folds, the express gate keeps the offer"                $r.express 'KB5071959'
Check "fold: ...and the installer's set is untouched"                                               $r.fallback 'KB1111111'

Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
