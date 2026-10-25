# wu-definition-class-test.ps1 - runs the SHIPPED definition classifier and the SHIPPED exclusion
# (guest/qubes-windows-update.ps1) against fake Windows Update offers. No guest.
#
# WHY: Microsoft republishes Defender signatures several times a day, so a fully-updated guest went
# back to "updates available" within minutes and stayed there forever. dom0 was telling the truth and
# the truth was useless. The flag now means "servicing work is pending". Two things have to hold for
# that to be safe, and neither is visible by reading:
#
#   1. the daily SIGNATURE definitions are excluded, and the Defender PLATFORM / engine updates are
#      NOT - they are real servicing work. A KB or a title cannot tell those apart; the WU
#      classification GUID can, and it is what the guest reads.
#   2. an offer the guest cannot classify still COUNTS. An exclusion that swallows what it failed to
#      classify would hide real updates, which is the expensive direction.
#
#   pwsh wu-definition-class-test.ps1 [-Script <path>] [-Defect titlematch|swallowunknown]
#   -Defect titlematch       replaces the structural test with an English title substring match.
#                            The German case and the platform case must then FAIL.
#   -Defect swallowunknown   makes an unclassifiable offer excluded instead of counted.
#                            The unreadable-categories case must then FAIL.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw

$md = [regex]::Match($src, '(?ms)^# ---- WU-DEFINITION-CLASS-BEGIN.*?^# ---- WU-DEFINITION-CLASS-END')
if (-not $md.Success) { Write-Output 'INSTRUMENT: WU-DEFINITION-CLASS region not found'; exit 2 }
$cls = $md.Value
if ($cls -notmatch 'e0789628-ce08-4437-be74-2495b842f43b') { Write-Output 'INSTRUMENT: the classification GUID is not in the region'; exit 2 }

$me = [regex]::Match($src, '(?ms)^  # ---- WU-DEFINITION-EXCLUDE-BEGIN.*?^  # ---- WU-DEFINITION-EXCLUDE-END')
if (-not $me.Success) { Write-Output 'INSTRUMENT: WU-DEFINITION-EXCLUDE region not found'; exit 2 }
$exc = $me.Value

if ($Defect -eq 'titlematch') {
    # The defect this project would most plausibly have shipped instead: match the English title.
    $cls = [regex]::Replace($cls, '(?ms)function Test-WuDefinitionUpdate\(\$u\)\{.*?\n\}',
      "function Test-WuDefinitionUpdate(`$u){`n  `$t=''; try { `$t=[string]`$u.Title } catch {}`n  return (`$t -like '*Definition Update*')`n}")
} elseif ($Defect -eq 'swallowunknown') {
    $cls = [regex]::Replace($cls, '(?m)^  return \$false$', '  return $true')
} elseif ($Defect) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (titlematch | swallowunknown)"; exit 2 }

. ([scriptblock]::Create($cls))

# WU's own classification GUIDs. Definitions is the one under test; Updates/Security Updates stand in
# for ordinary servicing, which must keep counting.
$DEFN = 'e0789628-ce08-4437-be74-2495b842f43b'
$UPDS = '0fa1201d-4330-4fa8-8ae9-b877473b6441'
$SECU = '0fa1201d-4330-4fa8-8ae9-b877473b6442'

function New-Offer([string]$kb, [string]$title, $cats) {
    $o = [pscustomobject]@{ KBArticleIDs=@($kb); Title=$title }
    if ($null -ne $cats) { $o | Add-Member -NotePropertyName Categories -NotePropertyValue $cats }
    return $o
}
function New-Category([string]$id, [string]$type = 'UpdateClassification') {
    [pscustomobject]@{ Type=$type; CategoryID=$id }
}
# Categories that throw on enumeration - a real COM object can, and the guest must not die on it.
function ThrowingCats {
    $c = [pscustomobject]@{}
    $c | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { throw 'COM failure' }
    return $c
}

$fails = 0
function Check([string]$name, [bool]$got, [bool]$want, [string]$why) {
    if ($got -eq $want) { Write-Output ("  ok   {0}: {1}" -f $name, $why) }
    else { Write-Output ("  FAIL {0}: got is_definition={1}, want {2} - {3}" -f $name, $got, $want, $why); $script:fails++ }
}

# --- the classifier -------------------------------------------------------------------------------
Check 'signature-en' (Test-WuDefinitionUpdate (New-Offer 'KB2267602' 'Definition Update for Microsoft Defender Antivirus - KB2267602 (Version 1.431.84.0)' @(New-Category $DEFN))) $true `
      'the daily signature offer is a definition and is excluded'
# THE CASE A TITLE MATCH CANNOT PASS. Same classification, German title - the field reporter runs a
# German 25H2 edition, and ADR section 6 forbids title text as an identity.
Check 'signature-de' (Test-WuDefinitionUpdate (New-Offer 'KB2267602' 'Definitionsupdate fuer Microsoft Defender Antivirus - KB2267602 (Version 1.431.84.0)' @(New-Category $DEFN))) $true `
      'the SAME offer with a German title is still a definition - classified structurally, not by text'
# THE DISCRIMINATING CASE. The Defender platform/engine update is real servicing work and must count,
# and its title contains the word Defender exactly as the signature offer does.
Check 'defender-platform' (Test-WuDefinitionUpdate (New-Offer 'KB4052623' 'Update for Microsoft Defender Antivirus antimalware platform - KB4052623' @(New-Category $UPDS))) $false `
      'the Defender PLATFORM update is ordinary servicing and still counts'
Check 'cumulative' (Test-WuDefinitionUpdate (New-Offer 'KB5062553' '2026-10 Cumulative Update for Windows 11' @(New-Category $SECU))) $false `
      'a cumulative counts'
# Normalisation: WU hands GUIDs back in more than one shape.
Check 'braced-uppercase' (Test-WuDefinitionUpdate (New-Offer 'KB2267602' 'x' @(New-Category ('{' + $DEFN.ToUpperInvariant() + '}')))) $true `
      'a braced, upper-case GUID is the same classification'
# A definition classification must be read only from an UpdateClassification category: the same GUID
# appearing as a Product category would not mean the same thing.
Check 'wrong-category-type' (Test-WuDefinitionUpdate (New-Offer 'KB2267602' 'x' @(New-Category $DEFN 'Product'))) $false `
      'the GUID is only a classification when it IS the UpdateClassification category'
Check 'multiple-categories' (Test-WuDefinitionUpdate (New-Offer 'KB2267602' 'x' @((New-Category 'abc' 'Company'), (New-Category $DEFN)))) $true `
      'found among several categories'
# --- the fail-safe direction ----------------------------------------------------------------------
Check 'no-categories' (Test-WuDefinitionUpdate (New-Offer 'KB999' 'x' $null)) $false `
      'an offer with NO categories counts - an exclusion must not swallow what it cannot classify'
Check 'throwing-categories' (Test-WuDefinitionUpdate (New-Offer 'KB999' 'x' (ThrowingCats))) $false `
      'categories that throw leave the offer counted, and the guest does not die'

# --- the exclusion: what dom0 actually reads ------------------------------------------------------
# Run the SHIPPED exclusion region over a synthetic scan result.
$script:St = [ordered]@{ available=$null; count=$null; definitions_excluded=$null }
function Save {}
function Log { param([string]$m, [string]$lvl = 'INFO') $script:logged += @($m) }
$script:logged = @()
$avail = @(
  [ordered]@{ kb='KB5062553'; is_definition=$false },
  [ordered]@{ kb='KB2267602'; is_definition=$true  },
  [ordered]@{ kb='KB4052623'; is_definition=$false },
  [ordered]@{ kb='KB2310138'; is_definition=$true  }
)
. ([scriptblock]::Create($exc))

if ($script:St.count -eq 2) { Write-Output '  ok   count: dom0 reads 2 of 4 offers - the two definitions are excluded' }
else { Write-Output "  FAIL count: dom0 reads $($script:St.count), want 2"; $fails++ }
if (@($script:St.available).Count -eq 4) { Write-Output '  ok   available: all 4 offers kept - the install path looks offers up here BY KB' }
else { Write-Output "  FAIL available: $(@($script:St.available).Count) offer(s) kept, want 4 - filtering this stops definitions INSTALLING"; $fails++ }
if ($script:St.definitions_excluded -eq 2) { Write-Output '  ok   disclosure: the excluded count is recorded, not inferred from a smaller number' }
else { Write-Output "  FAIL disclosure: definitions_excluded=$($script:St.definitions_excluded), want 2"; $fails++ }
if (($script:logged -join ' ') -match 'KB2267602' -and ($script:logged -join ' ') -match 'KB2310138') {
    Write-Output '  ok   log: names which offers were excluded'
} else { Write-Output "  FAIL log: did not name the excluded offers: $($script:logged -join ' | ')"; $fails++ }

# An all-definitions scan must report ZERO, which is the whole point.
$script:St = [ordered]@{ available=$null; count=$null; definitions_excluded=$null }
$avail = @([ordered]@{ kb='KB2267602'; is_definition=$true })
. ([scriptblock]::Create($exc))
if ($script:St.count -eq 0) { Write-Output '  ok   definitions-only: a scan finding only definitions reports 0 to dom0' }
else { Write-Output "  FAIL definitions-only: reported $($script:St.count), want 0"; $fails++ }

if ($fails) { Write-Output "FAILED: $fails check(s)"; exit 1 }
Write-Output 'PASS  every check'
exit 0
