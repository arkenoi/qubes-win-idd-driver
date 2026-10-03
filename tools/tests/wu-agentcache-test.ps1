# wu-agentcache-test.ps1 - runs the SHIPPED regions of guest/qubes-windows-update.ps1 behind Install-ViaAgentCache, offline, against fake
# Windows Update agent objects: WU-LEAF-SELECT (which leaves of an offer's bundle tree the agent still needs, and whether their content is
# static), WU-AGENT-INSTALL (fetch, CopyToCache, the agent's installer - never its downloader), WU-DEFENDER-SIGNATURE (the signature
# comparison with the offer) and WU-AGENT-VERDICT (the row decided from the agent's result AND the effect probe). No guest, no COM.
#
# WHY (2026-10-03): the updater ran vendor .exe files itself with a switch it chose ('/q' - a no-op for securityhealthsetup.exe, so
# KB5007651 silently failed every pass from 2026-09-20). Installer-type updates are now installed by the agent's own installer from content
# we supply through IUpdate2.CopyToCache (measured on four offered updates, all succeeding by effect). A one-level bundle walk left
# KB2267602 'not downloaded' (its MpSigStub leaf sits at depth 2); routeless, the agent's downloader goes to BITS and hung for 30 min;
# CopyToCache with an empty file list throws E_INVALIDARG.
#   pwsh wu-agentcache-test.ps1 [-Script <path>] [-Defect <knob>]
#   -Defect onelevel        GUARD:leafrecurse walks one level only - the depth-2 leaf is missed (and so is its fetch failure).
#   -Defect fetchinstalled  GUARD:leafneeded fetches installed / already-cached leaves too.
#   -Defect acceptexpress   GUARD:leafstatic accepts any URL as static content.
#   -Defect downloader      GUARD:nodownloader calls the agent's downloader when the update is not downloaded.
#   -Defect emptycache      GUARD:emptycache hands an empty file list to CopyToCache.
#   -Defect sigbehindinfo   GUARD:sigbehind: a signature below the offer after an agent success is not flagged.
#   -Defect trustagent      GUARD:agentdisagree: the agent's success stands even when the probe shows the artefact below the offer.
#   -Defect rcignored       GUARD:agentfailed: an agent failure is not a failed row.
#   -Defect agentcurrent    GUARD:agentcurrent: an artefact already at the offer is not recognised.
#   -Defect nomissing       GUARD:notdownloadedfails: a not-downloaded update does not name its missing leaves.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN[^\n]*\n(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found"; exit 2 }
    return $m.Groups[1].Value
}
function Func([string]$name) {   # a whole top-level function, by its own name
    $m = [regex]::Match($src, "(?m)^function $name\(.*?\n\}", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: function $name not found"; exit 2 }
    return $m.Value
}
$leafRegion = Region 'WU-LEAF-SELECT'
$installRegion = Region 'WU-AGENT-INSTALL'
$sigRegion = Region 'WU-DEFENDER-SIGNATURE'
$verdictRegion = Region 'WU-AGENT-VERDICT'
$classFn = Func 'Get-WuContentClass'
$probeFn = Func 'Get-EffectProbe'
# Every knob rewrites the ONE line that carries its guard tag.
$knobs = @{
    onelevel       = @{ in = 'leaf';    tag = 'leafrecurse';        with = '  if($nb -gt 0 -and $depth -eq 0){ foreach($c in $n.BundledUpdates){ Add-WuLeaves $c ($depth+1) $acc } }   # DEFECT: one level only' }
    fetchinstalled = @{ in = 'leaf';    tag = 'leafneeded';         with = '    if($true){   # DEFECT: installed and cached leaves are fetched too' }
    acceptexpress  = @{ in = 'leaf';    tag = 'leafstatic';         with = '          if($url){ $static += $url }   # DEFECT: any url counts as static' }
    downloader     = @{ in = 'install'; tag = 'nodownloader';       with = '  if(-not $downloaded){ $null = $session.CreateUpdateDownloader().Download()   # DEFECT: the downloader is called' }
    emptycache     = @{ in = 'install'; tag = 'emptycache';         with = '    # DEFECT: guard removed' }
    sigbehindinfo  = @{ in = 'sig';     tag = 'sigbehind';          with = '            # DEFECT: guard removed' }
    trustagent     = @{ in = 'verdict'; tag = 'agentdisagree';      with = '    } elseif($false){   # DEFECT: the agent is trusted over the probe' }
    rcignored      = @{ in = 'verdict'; tag = 'agentfailed';        with = '  } elseif($false){   # DEFECT: an agent failure is ignored' }
    agentcurrent   = @{ in = 'verdict'; tag = 'agentcurrent';       with = '    if($false){   # DEFECT: already-current is not recognised' }
    nomissing      = @{ in = 'verdict'; tag = 'notdownloadedfails'; with = '  if($false){   # DEFECT: not-downloaded falls through' }
}
if ($Defect -and -not $knobs.ContainsKey($Defect)) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' ($(($knobs.Keys | Sort-Object) -join ' | '))"; exit 2 }
if ($Defect) {
    $k = $knobs[$Defect]
    $target = switch ($k.in) { 'leaf' { $leafRegion } 'install' { $installRegion } 'sig' { $sigRegion } 'verdict' { $verdictRegion } }
    $d = [regex]::Replace($target, "(?m)^.*# GUARD:$($k.tag)\b.*$", $k.with.Replace('$', '$$'))
    if ($d -eq $target) { Write-Output "INSTRUMENT: GUARD:$($k.tag) not found"; exit 2 }
    switch ($k.in) { 'leaf' { $leafRegion = $d } 'install' { $installRegion = $d } 'sig' { $sigRegion = $d } 'verdict' { $verdictRegion = $d } }
}
function Log($m) { }
Invoke-Expression $leafRegion     # Get-WuNeededLeaves / Add-WuLeaves
Invoke-Expression $classFn
Invoke-Expression $probeFn
$script:fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }

# ---- fake agent objects. A node of the bundle tree: Title, Identity, IsInstalled, IsDownloaded, DownloadContents (objects with
# DownloadUrl), BundledUpdates, and CopyToCache, which records its calls and throws on an empty list as the real one does
# (E_INVALIDARG, measured 2026-10-03). The root's IsDownloaded is what the agent reports: true once every needed leaf is cached.
function New-FakeNode([string]$title, [string]$uid, [string[]]$urls, [bool]$installed, [bool]$downloaded, [object[]]$children) {
    $o = [pscustomobject]@{ Title = $title; Identity = [pscustomobject]@{ UpdateID = $uid; RevisionNumber = 200 }; IsInstalled = $installed; IsDownloaded = $downloaded
                             DownloadContents = @(@($urls | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ DownloadUrl = $_ } })
                             BundledUpdates = @(@($children) | Where-Object { $_ }); Cached = $false; CopyCalls = 0; EmptyCalls = 0 }
    $o | Add-Member -MemberType ScriptMethod -Name CopyToCache -Value { param($files)
        if ($files.Count -eq 0) { $this.EmptyCalls++; throw 'E_INVALIDARG: an empty file list' }
        $this.CopyCalls++; $this.Cached = $true }
    return $o
}
$cdn = 'https://download.windowsupdate.com/d/msdownload/update/software/defu/2026/10/'
function New-Tree([string]$variant) {
    $engineUrl = switch ($variant) { 'fetchfail' { $cdn + 'am_engine_FAIL.exe' } 'nostatic' { 'https://other.example.invalid/am_engine_bbbb.exe' } default { $cdn + 'am_engine_bbbb.exe' } }
    $dl = ($variant -eq 'downloaded')
    $stub   = New-FakeNode 'MpSigStub 1.1.26080.3' 'stub-uid' @($cdn + 'mpsigstub_aaaa.exe') $false $dl @()
    $engine = New-FakeNode 'AM Engine 1.1.26080.3' 'engine-uid' @($engineUrl) $false $dl @()
    $bases  = New-FakeNode 'Bases 1.459.0.0' 'bases-uid' @($cdn + 'am_base_cccc.exe') $true $false @()
    $delta  = New-FakeNode 'Full Deltas 1.459.526.0' 'delta-uid' @($cdn + 'am_delta_dddd.exe') $false $dl @()
    $hidden1 = New-FakeNode 'HIDDEN: Defender stub' 'h1-uid' @() $false $false @($stub)
    $hidden2 = New-FakeNode 'HIDDEN: Defender engine' 'h2-uid' @() $false $false @($engine)
    $leaves = @($stub, $engine, $bases, $delta)
    if ($variant -eq 'express') {
        $exp = New-FakeNode 'Express streams' 'exp-uid' @('https://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc-def?P1=1') $false $false @()
        $leaves += $exp
    }
    $children = @($hidden1, $hidden2, $bases, $delta) + @(if ($variant -eq 'express') { $exp })
    $root = New-FakeNode 'Security Intelligence-Update KB2267602' 'root-uid' @() $false $false $children
    $script:FakeLeaves = $leaves
    $root | Add-Member -Force -MemberType ScriptProperty -Name IsDownloaded -Value {
        @($script:FakeLeaves | Where-Object { -not $_.IsInstalled -and -not $_.IsDownloaded -and -not $_.Cached }).Count -eq 0 }
    return $root
}
$script:FakeRc = 2; $script:FakeHr = 0; $script:DownloaderCalled = $false
function New-FakeSession {
    $s = [pscustomobject]@{}
    $s | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value {
        $inst = [pscustomobject]@{ Updates = $null }
        $inst | Add-Member -MemberType ScriptMethod -Name Install -Value {
            $res = [pscustomobject]@{ ResultCode = $script:FakeRc; HResult = $script:FakeHr; RebootRequired = $false }
            $res | Add-Member -MemberType ScriptMethod -Name GetUpdateResult -Value { param($i) [pscustomobject]@{ ResultCode = $script:FakeRc; HResult = $script:FakeHr } } -PassThru
        } -PassThru
    }
    $s | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value {
        $script:DownloaderCalled = $true
        [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Download -Value { [pscustomobject]@{ ResultCode = 4 } } -PassThru
    }
    return $s
}

# ---------- WU-LEAF-SELECT: what the agent still needs
$lv = Get-WuNeededLeaves (New-Tree 'ok'); $cls = Get-WuContentClass (New-Tree 'ok')
$stubLeaf = @($lv.needed | Where-Object { $_.Title -like 'MpSigStub*' })
Check 'leaf-depth: the MpSigStub leaf under a content-less HIDDEN node is found at depth 2 and is needed' ($stubLeaf.Count -eq 1 -and $stubLeaf[0].Depth -eq 2)
Check 'leaf-installed: the installed 204 MB Bases leaf is NOT needed (never fetched)' (@($lv.needed | Where-Object { $_.Title -like 'Bases*' }).Count -eq 0)
Check 'leaf-static: every needed leaf is a plain download.windowsupdate.com file -> nothing missing, the update is self-contained' ($lv.missing.Count -eq 0 -and $cls.class -eq 'self-contained')
Check 'leaf-delta: the Defender delta leaf IS needed and IS static (the old exclusion of deltas is gone)' (@($lv.needed | Where-Object { $_.Title -like 'Full Deltas*' -and $_.Urls.Count -eq 1 -and $_.Bad.Count -eq 0 }).Count -eq 1)
$lvx = Get-WuNeededLeaves (New-Tree 'express'); $clsx = Get-WuContentClass (New-Tree 'express')
Check 'leaf-express: an express stream leaf is not static content -> named as missing, the update is NOT self-contained (class express)' (@($lvx.missing | Where-Object { $_.Title -eq 'Express streams' }).Count -eq 1 -and $lvx.express -and $clsx.class -eq 'express')
$lvd = Get-WuNeededLeaves (New-Tree 'downloaded'); $clsd = Get-WuContentClass (New-Tree 'downloaded')
Check 'leaf-downloaded: leaves the agent already holds are not needed; an update with everything cached is self-contained with nothing to fetch' ($lvd.needed.Count -eq 0 -and $clsd.class -eq 'self-contained' -and $clsd.urls.Count -eq 0)
Check 'probe-map: KB5007651 -> security-platform, an MpSigStub leaf -> defender-signature, an unknown package -> no probe (probe=none, never implied)' `
      ((Get-EffectProbe 'KB5007651' @()) -eq 'security-platform' -and (Get-EffectProbe '(no KB)' @('mpsigstub_aaaa.exe')) -eq 'defender-signature' -and (Get-EffectProbe 'KB4052623' @()) -eq 'defender-platform' -and $null -eq (Get-EffectProbe 'KB5999999' @('whatever_x.exe')))

# ---------- WU-AGENT-INSTALL: fetch, CopyToCache, the agent's installer
function Run-Install([string]$variant) {
    $sb = [scriptblock]::Create(@'
param($variant, $region)
function Log($m) { }
function Save { }
function New-WuComObject([string]$progId) { New-Object System.Collections.ArrayList }
function Fetch-Msu($url, $dst, $kb) { if ($url -match 'FAIL') { return $false }; Set-Content -LiteralPath $dst -Value 'payload'; return $true }
$script:DownloaderCalled = $false
$session = New-FakeSession
$update = New-Tree $variant
$label = 'KB2267602'
$dir = Join-Path ([IO.Path]::GetTempPath()) ('agentcache-' + [guid]::NewGuid().ToString()); New-Item -ItemType Directory -Force $dir | Out-Null
$script:St = [ordered]@{ installing = $null }
$lv = Get-WuNeededLeaves $update
Invoke-Expression $region
Remove-Item -Recurse -Force $dir -EA SilentlyContinue
[pscustomobject]@{ agentRc = $agentRc; files = @($files).Count; missing = @($missing); downloaderCalled = [bool]$script:DownloaderCalled
                   copyCalls = [int](@($script:FakeLeaves | ForEach-Object { $_.CopyCalls }) | Measure-Object -Sum).Sum
                   emptyCalls = [int](@($script:FakeLeaves | ForEach-Object { $_.EmptyCalls }) | Measure-Object -Sum).Sum }
'@)
    return & $sb $variant $installRegion
}
$r = Run-Install 'ok'
Check 'install-ok: three needed leaves fetched and handed to the agent, the update reads downloaded, the agent installs (ResultCode 2), its downloader is never called' `
      ($r.agentRc -eq 2 -and $r.files -eq 3 -and $r.copyCalls -eq 3 -and $r.missing.Count -eq 0 -and -not $r.downloaderCalled -and $r.emptyCalls -eq 0)
$r = Run-Install 'fetchfail'
Check 'install-fetchfail: a leaf whose fetch failed is NOT handed over empty, the update stays not downloaded, the agent is not asked, the downloader is never called, the missing leaf is named' `
      ($null -eq $r.agentRc -and ($r.missing -join ';') -match 'AM Engine 1\.1\.26080\.3: fetch failed \(am_engine_FAIL\.exe\)' -and -not $r.downloaderCalled -and $r.emptyCalls -eq 0)
$r = Run-Install 'nostatic'
Check 'install-nostatic: a needed leaf with no static content is named as missing; nothing is fetched for it, the downloader is never called' `
      ($null -eq $r.agentRc -and ($r.missing -join ';') -match 'AM Engine 1\.1\.26080\.3: no static content' -and -not $r.downloaderCalled)

# ---------- WU-DEFENDER-SIGNATURE: the signature compared with the offer when nothing moved
function Run-Sig([string]$before, [string]$after, $offered) {
    $sb = [scriptblock]::Create(@'
param($before, $after, $offered, $region)
function Log($m) { }
$sigBefore = $before; $sigAfter = $after; $eff = ($sigAfter -ne $sigBefore); $alreadyCurrent = $false; $sigBehind = $false
Invoke-Expression $region
[pscustomobject]@{ eff = $eff; alreadyCurrent = $alreadyCurrent; sigBehind = $sigBehind }
'@)
    return & $sb $before $after $offered $sigRegion
}
$r = Run-Sig '1.459.523.0' '1.459.523.0' '1.459.523.0'
Check 'sig-current: nothing moved and the signature is at the offer -> already current' ((-not $r.eff) -and $r.alreadyCurrent -and -not $r.sigBehind)
$r = Run-Sig '1.459.520.0' '1.459.520.0' '1.459.523.0'
Check 'sig-behind: nothing moved and the signature is below the offer -> flagged behind (the verdict fails it as a disagreement)' ((-not $r.eff) -and (-not $r.alreadyCurrent) -and $r.sigBehind)
$r = Run-Sig '1.459.520.0' '1.459.520.0' $null
Check 'sig-noversion: nothing moved and the offer names no version -> neither current nor behind' ((-not $r.eff) -and (-not $r.alreadyCurrent) -and -not $r.sigBehind)

# ---------- WU-AGENT-VERDICT: the row, from the agent's result and the probe
function Run-Verdict([bool]$notDownloaded, [int]$rc, [int]$hr, [string]$probe, [bool]$probeRan, [bool]$eff, [bool]$alreadyCurrent, [bool]$platBehind, [bool]$sigBehind, [string[]]$missing, [bool]$reboot) {
    $sb = [scriptblock]::Create(@'
param($notDownloaded, $rc, $hr, $probe, $probeRan, $eff, $alreadyCurrent, $platBehind, $sigBehind, $missing, $reboot, $region)
function Log($m) { }
$label = 'KB2267602'; $agentErr = $null; $secWhy = $null
$agentRc = if ($notDownloaded) { $null } else { $rc }
$agentHr = if ($notDownloaded) { $null } else { $hr }
$agentOk = ($null -ne $agentRc) -and ($agentRc -in @(2, 3))
$script:St = [ordered]@{ reboot_needed = $false }
Invoke-Expression $region
[pscustomobject]@{ ok = $ok; state = $state; sev = [string]$sev; reason = [string]$reason; rebootNeeded = [bool]$script:St.reboot_needed }
'@)
    return & $sb $notDownloaded $rc $hr $probe $probeRan $eff $alreadyCurrent $platBehind $sigBehind $missing $reboot $verdictRegion
}
$r = Run-Verdict $false 2 0 'defender-signature' $true $true $false $false $false @() $false
Check 'verdict-ok-effect: agent succeeded and the probe saw the effect -> installed, verified by effect' ($r.ok -and $r.state -eq 'installed' -and -not $r.sev -and $r.reason -match 'verified by effect: defender-signature')
$r = Run-Verdict $false 2 0 '' $false $false $false $false $false @() $false
Check 'verdict-ok-noprobe: agent succeeded and no probe exists -> installed, the row says probe=none' ($r.ok -and $r.state -eq 'installed' -and $r.reason -match 'probe=none')
$r = Run-Verdict $false 2 0 'mrt-version' $false $false $false $false $false @() $false
Check 'verdict-ok-unread: agent succeeded, the probe could not read its artefact -> installed on the agent, the row says the probe DID NOT RUN' ($r.ok -and $r.reason -match 'DID NOT RUN')
$r = Run-Verdict $false 4 ([int]-2145124318) 'defender-signature' $true $false $false $false $false @() $false
Check 'verdict-failed: the agent failed (ResultCode 4) -> FAILED, the HResult in the reason' ((-not $r.ok) -and $r.state -eq 'failed' -and $r.reason -match 'FAILED this update' -and $r.reason -match '0x80240022')
$r = Run-Verdict $false 2 0 'defender-signature' $true $false $false $false $true @() $false
Check 'verdict-disagree: agent succeeded but the signature did not move and is below the offer -> FAILED, logged as a disagreement' ((-not $r.ok) -and $r.reason -match 'DISAGREEMENT' -and $r.reason -match 'did NOT install')
$r = Run-Verdict $false 2 0 'defender-platform' $true $false $false $true $false @() $false
Check 'verdict-disagree-plat: agent succeeded but the Defender platform is behind the offer -> FAILED' ((-not $r.ok) -and $r.reason -match 'DISAGREEMENT')
$r = Run-Verdict $false 2 0 'defender-signature' $true $false $true $false $false @() $false
Check 'verdict-current: agent succeeded, nothing moved, the artefact is already at the offer -> ok, nothing to do' ($r.ok -and $r.state -eq 'installed' -and -not $r.sev -and $r.reason -match 'nothing to do')
$r = Run-Verdict $false 2 0 'defender-signature' $true $false $false $false $false @() $false
Check 'verdict-nocompare: agent succeeded, nothing moved, no offered version to compare -> the agent stands, the row says the effect is NOT verified' ($r.ok -and -not $r.sev -and $r.reason -match 'NOT verified')
$r = Run-Verdict $true 0 0 'defender-signature' $true $false $false $false $false @('AM Engine: fetch failed (am_engine.exe)') $false
Check 'verdict-notdownloaded: not downloaded after CopyToCache -> FAILED, the reason names the missing leaf and says the downloader is never called' ((-not $r.ok) -and $r.reason -match 'missing: AM Engine: fetch failed' -and $r.reason -match 'downloader is never called')
$r = Run-Verdict $false 2 0 '' $false $false $false $false $false @() $true
Check 'verdict-reboot: RebootRequired -> staged, reboot_needed set' ($r.ok -and $r.state -eq 'staged' -and $r.rebootNeeded)
$r = Run-Verdict $false 3 0 '' $false $false $false $false $false @() $false
Check 'verdict-rc-three: ResultCode 3 (succeeded with errors) counts as the agent succeeding' ($r.ok -and $r.state -eq 'installed')

if ($script:fails -eq 0) { Write-Output 'PASS  the agent installs from content we supply: the needed leaves are selected recursively and statically, the downloader is never called, and the row is the agent result judged with the effect probe'; exit 0 }
Write-Output "FAIL  $($script:fails) check(s)"; exit 1
