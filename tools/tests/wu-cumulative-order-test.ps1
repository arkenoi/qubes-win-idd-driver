# wu-cumulative-order-test.ps1 - runs the SHIPPED regions of guest/qubes-windows-update.ps1 that decide the ORDER of the .msu route and
# whether a staged cumulative was REGISTERED, offline: WU-MSU-KIND (which .msu is the cumulative - DISM's identity of the file),
# WU-PASS-ORDER (Install-MsuPlan: the cumulative first and only while no restart is pending, then the other .msu in offer order),
# WU-INSTALL-MSUS (Install-Msus: the one-package rule relaxed only behind a REGISTERED cumulative; the package list read before and
# after the cumulative's DISM call), WU-CUMULATIVE-REGISTERED (Test-RollupRegistered) and WU-MSU-VERDICT (Get-MsuKbVerdict). DISM, the
# CBS settle, the package list and RebootPending are stood in by fakes that record the order they ran in; the package-list fake answers
# by STATE (what Windows would show at that moment), so a read skipped or moved by a knob is seen as such. The agent route and the
# drivers are not here: they run inline in the offer loop as before, and tools/tests/wu-notactionable-test.ps1 replays that region.
#
# WHY (2026-10-03/04, the reporter's German 25H2 template, 4.3.33, four fresh clones): in offer order .NET stages first and the shipped
# one-package rule defers the cumulative to a second restart; with that rule lifted (QUBES_UPDATES_ALLOW_MULTISTAGE=1) a cumulative
# staged behind .NET was never registered - DISM 3010 for both, no RollupFix 9457 in any state, UBR unchanged after the restart,
# re-offered - which DISM's 3010 alone would have had the updater report as staged. The cumulative FIRST and .NET second both landed at
# one restart.
#   pwsh wu-cumulative-order-test.ps1 [-Script <path>] [-Defect <knob>]
#   -Defect offerorder     GUARD:cumulativefirst - the plan is installed in offer order (4.3.33's order: .NET first, the cumulative waits for a second restart).
#   -Defect nodefer        GUARD:cumulativedefer - a pending restart does not defer the cumulative.
#   -Defect norequest      GUARD:deferrequests - the deferral requests no restart.
#   -Defect assumepending  GUARD:rpunreadable - an unreadable RebootPending is taken as pending: the cumulative is skipped silently.
#   -Defect norelax        GUARD:stagebehindcumulative - nothing may stage behind a registered cumulative (the pre-rz40 rule).
#   -Defect relaxall       GUARD:stagebehindcumulative - everything may stage behind anything.
#   -Defect nobefore       GUARD:regbefore - no package list before the DISM call: whatever is pending afterwards counts as new.
#   -Defect notnew         GUARD:rollupregistered - any InstallPending rollup counts, new or not.
#   -Defect trust3010      GUARD:unregisteredfails - an unregistered cumulative still reads as staged (rc=3010 trusted).
#   -Defect unknownok      GUARD:unreadablefails - an unreadable package list is taken as registered.
#   -Defect norelaxflag    GUARD:registeredrelaxes - a registered cumulative never relaxes the rule.
#   -Defect kindnone       GUARD:cumulativeid - no identity is recognised as the cumulative.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN[^\n]*\n(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found"; exit 2 }
    return $m.Groups[1].Value
}
$rowkeyRegion  = Region 'WU-ROWKEY'
$kindRegion    = Region 'WU-MSU-KIND'
$regRegion     = Region 'WU-CUMULATIVE-REGISTERED'
$msusRegion    = Region 'WU-INSTALL-MSUS'
$verdictRegion = Region 'WU-MSU-VERDICT'
$orderRegion   = Region 'WU-PASS-ORDER'
# Every knob rewrites the ONE line that carries its guard tag.
$knobs = @{
    offerorder    = @{ in = 'order';   tag = 'cumulativefirst';       with = '  $ordered = @($plan)   # DEFECT: offer order - 4.3.33''s: .NET first, the cumulative deferred to a second restart' }
    nodefer       = @{ in = 'order';   tag = 'cumulativedefer';       with = '      if($false){   # DEFECT: a pending restart defers nothing' }
    norequest     = @{ in = 'order';   tag = 'deferrequests';         with = '        # DEFECT: no restart requested' }
    assumepending = @{ in = 'order';   tag = 'rpunreadable';          with = '      if($null -eq $rp){ Log "DEFECT: unknown taken as pending"; continue }   # DEFECT: the cumulative is skipped silently' }
    norelax       = @{ in = 'msus';    tag = 'stagebehindcumulative'; with = '      if ($true) {   # DEFECT: nothing stages behind a stage (the pre-rz40 rule)' }
    relaxall      = @{ in = 'msus';    tag = 'stagebehindcumulative'; with = '      if ($false) {   # DEFECT: everything stages behind anything' }
    nobefore      = @{ in = 'msus';    tag = 'regbefore';             with = '    $cumBefore = @{}   # DEFECT: no baseline - whatever is pending afterwards counts as new' }
    notnew        = @{ in = 'reg';     tag = 'rollupregistered';      with = '  $newlyPending = @($after.Keys | Where-Object { $_ -match ''RollupFix'' -and $after[$_] -eq ''InstallPending'' })   # DEFECT: new or not' }
    trust3010     = @{ in = 'verdict'; tag = 'unregisteredfails';     with = '  if ($false) {   # DEFECT: rc=3010 is trusted' }
    unknownok     = @{ in = 'msus';    tag = 'unreadablefails';       with = '      $cumRow.registered = $true   # DEFECT: unknown taken as registered' }
    norelaxflag   = @{ in = 'msus';    tag = 'registeredrelaxes';     with = '      # DEFECT: a registered cumulative never relaxes the rule' }
    kindnone      = @{ in = 'kind';    tag = 'cumulativeid';          with = '  if($false){ return ''cumulative'' }   # DEFECT: nothing is the cumulative' }
}
if ($Defect -and -not $knobs.ContainsKey($Defect)) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' ($(($knobs.Keys | Sort-Object) -join ' | '))"; exit 2 }
if ($Defect) {
    $k = $knobs[$Defect]
    $target = switch ($k.in) { 'order' { $orderRegion } 'msus' { $msusRegion } 'reg' { $regRegion } 'verdict' { $verdictRegion } 'kind' { $kindRegion } }
    $d = [regex]::Replace($target, "(?m)^.*# GUARD:$($k.tag)\b.*$", $k.with.Replace('$', '$$'))
    if ($d -eq $target) { Write-Output "INSTRUMENT: GUARD:$($k.tag) not found"; exit 2 }
    switch ($k.in) { 'order' { $orderRegion = $d } 'msus' { $msusRegion = $d } 'reg' { $regRegion = $d } 'verdict' { $verdictRegion = $d } 'kind' { $kindRegion = $d } }
}

# ---- fakes. DISM is a table path -> identity/state/applicable/rc; every call that matters is recorded in order. The package list is
# the STATE Windows would show: $script:PkgNow before any DISM call, $script:PkgAfterDism once a package was handed to DISM.
$script:Calls = @(); $script:LogLines = @(); $script:Dism = @{}; $script:PkgNow = $null; $script:PkgAfterDism = $null; $script:RebootPending = $false
function Log($m) { $script:LogLines += [string]$m }
function Save { }
function Get-MsuInfo($path) {
    $d = $script:Dism[[string]$path]
    if (-not $d) { throw "INSTRUMENT: no fake DISM entry for $path" }
    return @{ applicable = $d.applicable; state = $d.state; identity = $d.identity; rc = 0 }
}
function Order-Msus($files) { return ,@($files) }
function Add-PackageCompat($f) { $script:Calls += "DISM $([IO.Path]::GetFileName($f))"; $script:PkgNow = $script:PkgAfterDism; return [int]$script:Dism[[string]$f].rc }
function Wait-CbsSettle { $script:Calls += 'SETTLE' }
function Get-CbsPackageStates { $script:Calls += 'PKGLIST'; return $script:PkgNow }
function Test-CbsRebootPending { $script:Calls += 'REBOOTPENDING'; return $script:RebootPending }
$OK_RC = @(0, 3010, 2359302)
$WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('wuorder-' + [guid]::NewGuid().ToString())
Invoke-Expression $rowkeyRegion    # Test-RowKey, as shipped
Invoke-Expression $kindRegion      # Get-MsuKindFromIdentity, Get-MsuKind
Invoke-Expression $regRegion       # Test-RollupRegistered
Invoke-Expression $msusRegion      # Install-Msus
Invoke-Expression $verdictRegion   # Get-MsuKbVerdict
Invoke-Expression $orderRegion     # Install-MsuPlan
$script:fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }

# The files and what DISM says about them (measured 2026-10-04: the combined cumulative reports 'OnePackage~~~~0.0.0.0' and 'Not
# Present', the .NET package no identity at all). Both return 3010.
$cumPath = Join-Path $WorkDir 'KB5129195\windows11.0-kb5129195-x64_abc.msu'
$netPath = Join-Path $WorkDir 'KB5126052\windows11.0-kb5126052-x64-ndp481_def.msu'
$cum2Path = Join-Path $WorkDir 'KB5199999\windows11.0-kb5199999-x64_ghi.msu'
$script:Dism[$cumPath]  = @{ identity = 'OnePackage~~~~0.0.0.0'; state = 'Not Present'; applicable = 'Yes'; rc = 3010 }
$script:Dism[$netPath]  = @{ identity = ''; state = 'Not Present'; applicable = 'Yes'; rc = 3010 }
$script:Dism[$cum2Path] = @{ identity = 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26200.9999.1.1'; state = 'Not Present'; applicable = 'Yes'; rc = 3010 }
$cumFile = 'windows11.0-kb5129195-x64_abc.msu'; $netFile = 'windows11.0-kb5126052-x64-ndp481_def.msu'
# Package lists, as the measurements saw them. Before: the previous rollup installed. Registered: the new rollup InstallPending, the
# old UninstallPending, the bundled servicing stack installed online. Dropped (the silent loss): the servicing stack pending, NO new
# rollup in any state. Stale: a rollup already pending before the call and unchanged after it.
$rfOld = 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26200.8037.1.6'
$rfNew = 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26200.9457.1.11'
$ssuOld = 'Package_for_ServicingStack_9201~31bf3856ad364e35~amd64~~26200.9201.1.0'
$ssuNew = 'Package_for_ServicingStack_9441~31bf3856ad364e35~amd64~~26200.9441.1.0'
$pkgBefore     = @{ $rfOld = 'Installed'; $ssuOld = 'Installed' }
$pkgRegistered = @{ $rfOld = 'UninstallPending'; $rfNew = 'InstallPending'; $ssuOld = 'Installed'; $ssuNew = 'Installed' }
$pkgDropped    = @{ $rfOld = 'Installed'; $ssuOld = 'Installed'; $ssuNew = 'InstallPending' }
$pkgStale      = @{ $rfOld = 'UninstallPending'; $rfNew = 'InstallPending'; $ssuOld = 'Installed' }

function Reset-World($rebootPending, $pkgNow, $pkgAfterDism, [bool]$staged = $false, [bool]$registered = $false) {
    $script:Calls = @(); $script:LogLines = @(); $script:PkgNow = $pkgNow; $script:PkgAfterDism = $pkgAfterDism
    $script:RebootPending = $rebootPending
    $script:St = [ordered]@{ phase = 'init'; result = @(); reboot_needed = $false; installing = $null }
    $script:StagedThisSession = $staged; $script:CumulativeRegisteredThisSession = $registered
    $script:MsuKindCache = @{}
}
# The .msu plan as the resolve/download loop records it, in OFFER ORDER: .NET first, the cumulative second (the reporter's offers).
function New-Plan {
    return @(
        [ordered]@{ u = [pscustomobject]@{ kb = 'KB5126052'; title = '.NET' };       label = 'KB5126052'; got = @($netPath) },
        [ordered]@{ u = [pscustomobject]@{ kb = 'KB5129195'; title = 'Cumulative' }; label = 'KB5129195'; got = @($cumPath) }
    )
}
function Index([string]$call) { return [array]::IndexOf($script:Calls, $call) }
function Row([string]$kb) { return @($script:St.result | Where-Object { $_.kb -eq $kb })[0] }

# ---------- WU-PASS-ORDER
Reset-World $false $pkgBefore $pkgRegistered
Install-MsuPlan (New-Plan)
$dismCalls = @($script:Calls | Where-Object { $_ -like 'DISM *' })
Check 'cumulative-first: offered as .NET then the cumulative - the cumulative is the FIRST package handed to DISM, .NET the second (and the install order is logged)' `
      ($dismCalls.Count -eq 2 -and $dismCalls[0] -eq "DISM $cumFile" -and $dismCalls[1] -eq "DISM $netFile" -and (@($script:LogLines | Where-Object { $_ -match '^install order \(\.msu\): KB5129195 \[cumulative\] -> KB5126052$' }).Count -eq 1))
$rc = Row 'KB5129195'; $rn = Row 'KB5126052'
Check 'both-land: the cumulative is staged AND registered, .NET stages behind it in the same pass (DISM called, rc 3010), one restart requested, nothing deferred' `
      ($rc.ok -and $rc.state -eq 'staged' -and $rc.files[0].registered -eq $true -and (Index "DISM $netFile") -gt (Index "DISM $cumFile") -and $rn.ok -and $rn.state -eq 'staged' -and $rn.files[0].rc -eq 3010 -and $script:St.reboot_needed -and (@($script:St.result | Where-Object { $_.state -eq 'deferred' }).Count -eq 0))
$pk = @(0..($script:Calls.Count - 1) | Where-Object { $script:Calls[$_] -eq 'PKGLIST' })
Check 'list-brackets-dism: the package list is read exactly twice - BEFORE the cumulative''s DISM call and AFTER the settle - and never for .NET' `
      ($pk.Count -eq 2 -and $pk[0] -lt (Index "DISM $cumFile") -and $pk[1] -gt (Index 'SETTLE') -and ((Index "DISM $netFile") -lt 0 -or $pk[1] -lt (Index "DISM $netFile")))

Reset-World $true $pkgBefore $pkgDropped
Install-MsuPlan (New-Plan)
$rc = Row 'KB5129195'
Check 'cumulative-deferred: a restart already pending - the cumulative is never handed to DISM, its row is DEFERRED with that reason, the restart is requested, and the pass goes on to the other .msu' `
      ((Index "DISM $cumFile") -lt 0 -and (-not $rc.ok) -and $rc.state -eq 'deferred' -and $rc.reason -match '^deferred: a restart is already pending \(CBS RebootPending is set' -and $rc.reason -match 'the pass after it installs the cumulative first' -and $rc.files[0].rc -eq 'deferred' -and $script:St.reboot_needed -and (Index "DISM $netFile") -ge 0)
# The cumulative ALONE behind a pending restart: nothing else in the pass can set reboot_needed, so the request must be the deferral's own.
Reset-World $true $pkgBefore $pkgDropped
Install-MsuPlan @([ordered]@{ u = [pscustomobject]@{ kb = 'KB5129195'; title = 'Cumulative' }; label = 'KB5129195'; got = @($cumPath) })
Check 'deferral-requests-restart: the cumulative alone, a restart pending - nothing reaches DISM and the deferral ITSELF requests the restart (reboot_needed) through the existing channel' `
      ($script:Calls.Count -eq 1 -and $script:Calls[0] -eq 'REBOOTPENDING' -and (Row 'KB5129195').state -eq 'deferred' -and $script:St.reboot_needed)

Reset-World $null $pkgBefore $pkgRegistered
Install-MsuPlan (New-Plan)
$rc = Row 'KB5129195'
Check 'rp-unreadable-proceeds: RebootPending unreadable - a WARNING names it, the cumulative still goes to DISM first (after the before-read) and the registration check decides' `
      ($script:Calls[0] -eq 'REBOOTPENDING' -and $script:Calls[1] -eq 'PKGLIST' -and $script:Calls[2] -eq "DISM $cumFile" -and (@($script:LogLines | Where-Object { $_ -match 'WARNING: KB5129195: CBS RebootPending could not be read' }).Count -eq 1) -and $rc.ok -and $rc.state -eq 'staged' -and $rc.files[0].registered -eq $true)

# ---------- WU-INSTALL-MSUS: the one-package rule and its single relaxation
Reset-World $false $pkgBefore $pkgRegistered $true $true
$rows = @(Install-Msus @($netPath))
Check 'others-after-registered: something is staged this pass AND the cumulative registered -> a non-cumulative package stages (DISM called, rc 3010)' `
      ((Index "DISM $netFile") -ge 0 -and $rows[0].rc -eq 3010 -and $rows[0].kind -eq 'other')
Reset-World $false $pkgBefore $pkgRegistered $true $true
$rows = @(Install-Msus @($cum2Path))
Check 'second-cumulative-deferred: something is staged this pass AND the cumulative registered -> a second cumulative is DEFERRED, naming the servicing stack; DISM and the package list are never asked' `
      ($rows[0].rc -eq 'deferred' -and $rows[0].why -match 'is a cumulative \(it carries a servicing stack' -and $script:Calls.Count -eq 0)
Reset-World $false $pkgBefore $pkgRegistered $true $false
$rows = @(Install-Msus @($netPath))
Check 'no-cumulative-old-rule: something is staged this pass and NO cumulative registered -> the next package is deferred as before' `
      ($rows[0].rc -eq 'deferred' -and $rows[0].why -eq 'another package is already staged; installing it needs a reboot first' -and $script:Calls.Count -eq 0)

# ---------- WU-INSTALL-MSUS + WU-MSU-VERDICT: the registration check
Reset-World $false $pkgBefore $pkgRegistered
$rows = @(Install-Msus @($cumPath)); $v = Get-MsuKbVerdict 'KB5129195' $rows
Check 'registered: RollupFix 9457 newly InstallPending after the call -> the row is registered, the KB is STAGED (ok), the relaxation flag is set, the restart requested, REGISTERED logged' `
      ($rows[0].rc -eq 3010 -and $rows[0].registered -eq $true -and $v.ok -and $v.state -eq 'staged' -and $script:CumulativeRegisteredThisSession -and $script:St.reboot_needed -and (@($script:LogLines | Where-Object { $_ -match '^  REGISTERED windows11\.0-kb5129195-x64_abc\.msu - newly InstallPending: ' }).Count -eq 1))
Reset-World $false $pkgBefore $pkgDropped
$rows = @(Install-Msus @($cumPath)); $v = Get-MsuKbVerdict 'KB5129195' $rows
Check 'unregistered-fails: DISM 3010 but no RollupFix newly InstallPending (only the servicing stack pending) -> the KB FAILS: DISM accepted it, Windows did not register it, NOT staged, retried after the restart; the flag stays unset; the file row keeps rc 3010' `
      ((-not $v.ok) -and $v.state -eq 'failed' -and $v.reason -match 'DISM accepted windows11\.0-kb5129195-x64_abc\.msu \(rc=3010; the cumulative\) but Windows did NOT register it: no RollupFix package is newly InstallPending' -and $v.reason -match 'It is NOT staged and will not complete at a restart' -and $v.reason -match 'the pass after the restart retries this package' -and (-not $script:CumulativeRegisteredThisSession) -and $script:St.reboot_needed -and $rows[0].rc -eq 3010 -and $rows[0].registered -eq $false)
Reset-World $false $pkgBefore $null
$rows = @(Install-Msus @($cumPath)); $v = Get-MsuKbVerdict 'KB5129195' $rows
Reset-World $false $null $pkgRegistered
$rows2 = @(Install-Msus @($cumPath)); $v2 = Get-MsuKbVerdict 'KB5129195' $rows2
Check 'unreadable-not-staged: the package list unreadable after (or before) the call -> the KB FAILS saying UNKNOWN, never staged; the flag stays unset; the ERROR is logged' `
      ((-not $v.ok) -and $v.state -eq 'failed' -and $v.reason -match 'whether Windows registered it is UNKNOWN: the package list could not be read after the DISM call' -and $v.reason -match 'NOT reported as staged' -and $rows[0].registered -eq 'unknown' -and (-not $script:CumulativeRegisteredThisSession) -and
       (-not $v2.ok) -and $v2.state -eq 'failed' -and $v2.reason -match 'could not be read before the DISM call' -and (@($script:LogLines | Where-Object { $_ -match '^  ERROR: DISM accepted .* UNKNOWN' }).Count -eq 1))
Reset-World $false $pkgStale $pkgStale
$rows = @(Install-Msus @($cumPath)); $v = Get-MsuKbVerdict 'KB5129195' $rows
Check 'stale-pending-not-new: a RollupFix already InstallPending before the call and unchanged after it is NOT this call''s registration -> the KB FAILS' `
      ((-not $v.ok) -and $v.state -eq 'failed' -and $v.reason -match 'no RollupFix package is newly InstallPending - RollupFix packages after the call: .*26200\.9457\.1\.11=InstallPending \(before: InstallPending\)' -and $rows[0].registered -eq $false)

# ---------- WU-MSU-KIND and WU-CUMULATIVE-REGISTERED as pure functions
Check 'kind: OnePackage~~~~0.0.0.0 and a RollupFix identity are the cumulative; an empty identity, a servicing stack and a .NET rollup are not' `
      ((Get-MsuKindFromIdentity 'OnePackage~~~~0.0.0.0') -eq 'cumulative' -and (Get-MsuKindFromIdentity $rfNew) -eq 'cumulative' -and (Get-MsuKindFromIdentity '') -eq 'other' -and (Get-MsuKindFromIdentity $ssuNew) -eq 'other' -and (Get-MsuKindFromIdentity 'Package_for_DotNetRollup_481~31bf3856ad364e35~amd64~~10.0.9282.1') -eq 'other')
$r1 = Test-RollupRegistered $pkgBefore $pkgRegistered; $r2 = Test-RollupRegistered $pkgBefore $pkgDropped; $r3 = Test-RollupRegistered $pkgStale $pkgStale; $r4 = Test-RollupRegistered $null $pkgRegistered
Check 'registered-check: newly pending -> ok; dropped -> not ok, known; stale -> not ok, known; an unreadable list -> not ok, NOT known' `
      ($r1.ok -and $r1.known -and (-not $r2.ok) -and $r2.known -and (-not $r3.ok) -and $r3.known -and (-not $r4.ok) -and (-not $r4.known))

if ($script:fails -eq 0) { Write-Output 'PASS  the cumulative goes first while nothing is pending, is deferred otherwise, relaxes the one-package rule only once registered, and a stage Windows did not register is a failed row - never staged'; exit 0 }
Write-Output "FAIL  $($script:fails) check(s)"; exit 1
