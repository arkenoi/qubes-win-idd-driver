# wu-available-test.ps1 - runs the SHIPPED Get-Available (guest/qubes-windows-update.ps1) against a fake Windows Update session, so what is
# checked is the scan's own code, not a copy. No guest.
#
# WHY: on rz38 (2026-10-03) an edit deleted `$out=@()` and duplicated the online search line. With $out unset, `$null += [ordered]@{...}`
# made it a DICTIONARY and the next += merged two dictionaries and threw "An item with the same key has already been added. Key: kb" -
# every scan offering two or more updates died, and dom0 was never told (the TemplateVM update test, rounds 2-3 FAIL SILENT).
#   pwsh wu-available-test.ps1 [-Script <path>] [-Defect noarray|twosearch]
#   -Defect noarray    removes GUARD:outarray (the empty-array init) - every case must FAIL (one update: a bare dictionary instead of an array of rows; two or more: the duplicate-key throw).
#   -Defect twosearch  adds a second online search after GUARD:onesearch - the one-search case must FAIL.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
$m = [regex]::Match($src, '(?ms)^function Get-Available \{.*?^\}')
if (-not $m.Success) { Write-Output 'INSTRUMENT: function Get-Available not found'; exit 2 }
$fn = $m.Value
foreach ($g in 'GUARD:outarray', 'GUARD:onesearch') { if ($fn -notmatch [regex]::Escape($g)) { Write-Output "INSTRUMENT: $g not found in Get-Available"; exit 2 } }
if ($Defect -eq 'noarray') { $fn = [regex]::Replace($fn, '(?m)^.*# GUARD:outarray\s*$', '  # DEFECT: init removed') }
elseif ($Defect -eq 'twosearch') { $fn = [regex]::Replace($fn, '(?m)^(.*# GUARD:onesearch.*)$', "`$1`n  `$r=`$se.Search(`"IsInstalled=0 and IsHidden=0`")") }
elseif ($Defect) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (noarray | twosearch)"; exit 2 }

$script:searches = 0
$script:fakeUpdates = @()
function New-FakeUpdate([string]$kb, [string]$uid) {
    [pscustomobject]@{ KBArticleIDs = @($kb); Title = "Update $kb"; MaxDownloadSize = 1048576; IsDownloaded = $false
                       Identity = [pscustomobject]@{ UpdateID = $uid; RevisionNumber = 200 }; BundledUpdates = @(); DownloadContents = @() }
}
function New-FakeSession {
    $searcher = [pscustomobject]@{ ServerSelection = 0; Online = $false }
    $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value { param($q) $script:searches++; [pscustomobject]@{ Updates = $script:fakeUpdates } }
    $session = [pscustomobject]@{}
    $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $searcher }.GetNewClosure()
    return $session
}
# Get-Available creates its session with New-Object -ComObject; this function takes precedence over the cmdlet inside this test only.
function New-Object { param([string]$ComObject) if ($ComObject -eq 'Microsoft.Update.Session') { return (New-FakeSession) } throw "unexpected New-Object $ComObject" }
function Get-WuContentClass { param($u) return @{ class = 'none'; urls = @() } }
. ([scriptblock]::Create($fn))

$fails = 0
function Check([string]$name, [bool]$ok, [string]$detail) { if ($ok) { Write-Output "  ok   ${name}: $detail" } else { Write-Output "  FAIL ${name}: $detail"; $script:fails++ } }
foreach ($case in @(@{ n = 'one-update'; k = 1 }, @{ n = 'two-updates'; k = 2 }, @{ n = 'three-updates'; k = 3 })) {
    $script:fakeUpdates = @(1..$case.k | ForEach-Object { New-FakeUpdate "50000$_" "uid-$_" }); $script:searches = 0
    $rows = $null; $err = $null
    try { $rows = Get-Available } catch { $err = $_.Exception.Message }
    $ok = (-not $err) -and ($rows -is [array]) -and (@($rows).Count -eq $case.k) -and (@($rows | ForEach-Object { $_.kb }) -join ',') -eq ((1..$case.k | ForEach-Object { "KB50000$_" }) -join ',')
    Check $case.n $ok $(if ($err) { "threw: $err" } else { "rows=$(@($rows).Count) kbs=$(@($rows | ForEach-Object { $_.kb }) -join ',')" })
    if ($case.n -eq 'one-update') { Check 'one-search' ($script:searches -eq 1) "online searches per scan = $script:searches" }
}
Write-Output $(if ($fails) { "FAILED: $fails check(s)" } else { 'PASS  every check' })
exit $(if ($fails) { 1 } else { 0 })
