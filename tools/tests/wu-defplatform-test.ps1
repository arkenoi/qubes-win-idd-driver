# wu-defplatform-test.ps1 - runs qubes-windows-update.ps1's region WU-DEFENDER-PLATFORM (the effect probe for the Defender antimalware
# platform update, KB4052623 / updateplatform.amd64fre_*.exe) and then the SHIPPED verdict region WU-EXE-EFFECT against synthetic
# before/after states, so what is checked is the row the updater writes (ok / severity / reason), not an intermediate flag. No guest.
#
# WHY: until 2026-10-03 the platform update was counted from its exit code alone ("probe=none (ok from rc only)"), and the exclusion
# audit would not accept dom0's silence about an item nothing had verified - it failed the rz35 release gate on exactly this row.
#   pwsh wu-defplatform-test.ps1 [-Script <path>] [-Defect noeffect|behindinfo|nopending]
#   -Defect noeffect    disables GUARD:defplatform (the measured effect is ignored, as before 2026-10-03) - the effect cases must FAIL.
#   -Defect behindinfo  disables GUARD:platbehind (a platform left BELOW the offer reads as 'informational' - a failed install concealed
#                       behind the reason "cannot establish the version the offer carries") - the behind case must FAIL.
#   -Defect nopending   disables GUARD:platpending (a platform an earlier pass of THIS boot staged, awaiting the service's switch, is not
#                       recognised) - the pending case must FAIL.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN[^\n]*\n(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found"; exit 2 }
    return $m.Groups[1].Value
}
$region = Region 'WU-DEFENDER-PLATFORM'
$exeRegion = Region 'WU-EXE-EFFECT'
$knob = @{ noeffect = 'defplatform'; behindinfo = 'platbehind'; nopending = 'platpending' }[$Defect]
if ($Defect -and -not $knob) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (noeffect | behindinfo | nopending)"; exit 2 }
if ($knob) {
    $d = [regex]::Replace($region, "(?m)^.*# GUARD:$knob\s*$", '          # DEFECT: guard removed')
    if ($d -eq $region) { Write-Output "INSTRUMENT: GUARD:$knob not found"; exit 2 }
    $region = $d
}
$script:fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }

# One case: the platform before/after, the folders before/after, the installer's rc, the offer's title, and which folders were created
# in THIS boot (every other folder predates it). Returns the row's verdict.
function Run-Case([string]$before, [string]$after, [string[]]$dirsBefore, [string[]]$dirsAfter, [int]$rc, [string]$title, [string[]]$newThisBoot = @()) {
    $sb = [scriptblock]::Create(@'
param($before, $after, $dirsBefore, $dirsAfter, $rc, $title, $region, $exeRegion, $newThisBoot)
function Log($m) { }
function Get-MpComputerStatus { [pscustomobject]@{ AMProductVersion = $script:AfterVer } }
$script:BootAt = [datetime]'2026-10-03T08:00:00'
function Get-CimInstance { param($ClassName, $EA) [pscustomobject]@{ LastBootUpTime = $script:BootAt } }
function Get-ChildItem { param($LiteralPath, [switch]$Directory, $EA)
    foreach ($n in $script:DirsAfter) { [pscustomobject]@{ Name = $n; CreationTime = $(if ($script:NewThisBoot -contains $n) { $script:BootAt.AddMinutes(20) } else { $script:BootAt.AddDays(-2) }) } } }
$script:AfterVer = $after; $script:DirsAfter = $dirsAfter; $script:NewThisBoot = @($newThisBoot | Where-Object { $_ })
$probe = 'defender-platform'; $kb = 'KB4052623'; $name = 'updateplatform.amd64fre_x.exe'; $shBefore = ''
$platBefore = $before; $platDirsBefore = @($dirsBefore | Where-Object { $_ })
$p = [pscustomobject]@{ ExitCode = $rc }
$eff = $false; $probeRan = $true; $alreadyCurrent = $false
$script:St = [ordered]@{ available = @([pscustomobject]@{ kb = 'KB4052623'; title = $title }) }
Invoke-Expression $region
$ok = $false; $sev = $null; $why = $null; $detail = ''
Invoke-Expression $exeRegion
[pscustomobject]@{ eff = $eff; probeRan = $probeRan; alreadyCurrent = $alreadyCurrent; ok = $ok; sev = [string]$sev; why = [string]$why }
'@)
    return & $sb $before $after $dirsBefore $dirsAfter $rc $title $region $exeRegion $newThisBoot
}
$offer = 'Update für Microsoft Defender Antivirus Antischadsoftwareplattform – KB4052623 (Version 4.18.26080.4) – Aktueller Kanal (Breit)'
$noVer = 'Update für Microsoft Defender Antivirus Antischadsoftwareplattform – KB4052623 – Aktueller Kanal (Breit)'

$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0') @('4.18.25080.5-0', '4.18.26080.4-0') 0 $offer
Check 'staged: a NEW folder for the offered version appeared (the service has not switched yet) -> verified by effect, ok' ($r.eff -and $r.ok -and -not $r.sev)
$r = Run-Case '4.18.25080.5' '4.18.26080.4' @('4.18.25080.5-0') @('4.18.25080.5-0') 0 $offer
Check 'moved: AMProductVersion moved -> verified by effect, ok' ($r.eff -and $r.ok -and -not $r.sev)
$r = Run-Case '4.18.26080.4' '4.18.26080.4' @('4.18.26080.4-0') @('4.18.26080.4-0') 0 $offer
Check 'already-current: nothing moved, the folder already existed, the platform is at the offer -> ok, already current, not informational' ((-not $r.eff) -and $r.alreadyCurrent -and $r.ok -and -not $r.sev)
$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0') @('4.18.25080.5-0') 0 $offer
Check 'behind: rc=0, nothing moved or staged, the platform is below the offer -> a FAILED install (ok false, not informational)' ((-not $r.eff) -and (-not $r.alreadyCurrent) -and (-not $r.ok) -and (-not $r.sev) -and $r.why -match 'did NOT install')
$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0', '4.18.26080.4-0') @('4.18.25080.5-0', '4.18.26080.4-0') 0 $offer @('4.18.26080.4-0')
Check 'pending: the offered folder was staged by an earlier pass of THIS boot and the service has not switched -> staged, ok (not a failure)' ($r.eff -and $r.ok -and -not $r.sev)
$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0', '4.18.26080.4-0') @('4.18.25080.5-0', '4.18.26080.4-0') 0 $offer
Check 'switch-never-happened: the offered folder predates this boot and the service still runs the older platform -> a FAILED install' ((-not $r.eff) -and (-not $r.ok) -and (-not $r.sev) -and $r.why -match 'did NOT install')
$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0') @('4.18.25080.5-0') 0 $noVer
Check 'no version in the offer: nothing moved and the offered version cannot be established -> informational (asserts neither)' ((-not $r.eff) -and $r.ok -and $r.sev -eq 'info')
$r = Run-Case '4.18.25080.5' '4.18.25080.5' @('4.18.25080.5-0') @('4.18.25080.5-0') 1603 $offer
Check 'nonzero rc and nothing moved -> a FAILED install' ((-not $r.eff) -and (-not $r.ok) -and (-not $r.sev))
$r = Run-Case '' '' @() @() 0 $offer
Check 'unreadable: nothing could be read -> the probe did not run (unknown, not a negative): ok from rc, not informational' ((-not $r.probeRan) -and $r.ok -and -not $r.sev)

if ($script:fails -eq 0) { Write-Output 'PASS  the Defender platform row is decided by its measured effect: moved/staged ok, at the offer ok, behind FAILED'; exit 0 }
Write-Output "FAIL  $($script:fails) check(s)"; exit 1
