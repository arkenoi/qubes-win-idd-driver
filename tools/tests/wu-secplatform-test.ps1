# wu-secplatform-test.ps1 - runs qubes-windows-update.ps1's regions WU-SECPLATFORM-READ (how the Windows Security platform's state is read),
# WU-SECURITY-PLATFORM (the effect probe for KB5007651, decided by the PLATFORM) and then the SHIPPED verdict region WU-AGENT-VERDICT,
# against synthetic before/after registry states and a synthetic agent result, so what is checked is the row the updater writes
# (ok / state / reason), not an intermediate flag. No guest.
#
# WHY (2026-10-03): the item was decided by the SecHealthUI APP, which the updater's own fallback could provision, so a pass reported
# ALREADY CURRENT over an uninstalled platform while Windows Update kept re-offering KB5007651 (the owner: the updater was not fixed).
# The platform the installer changes is HKLM\...\Windows Security Health\Platform\CoreLocation (System32 = inbox; a versioned
# SecurityHealth\<version>-<n> folder = installed) plus Updates\wu; the app follows it ~41 s later and is information only.
#   pwsh wu-secplatform-test.ps1 [-Script <path>] [-Defect noeffect|nocurrent|unreadablefails|appcertifies]
#   -Defect noeffect         removes GUARD:secplatform (the platform's measured move is ignored) - the moved cases must FAIL.
#   -Defect nocurrent        removes GUARD:seccurrent (a platform at or past the offer is not recognised - the opposite defect, a permanent
#                            'updates available') - the already-current cases must FAIL.
#   -Defect unreadablefails  removes GUARD:secunreadable (an unreadable platform is judged anyway) - the unreadable cases must FAIL.
#   -Defect appcertifies     replaces GUARD:appnoteffect with the pre-2026-10-03 rule (the APP decides: moved = installed, at the offer's
#                            build = already current) - the concealment cases must FAIL.
param([string]$Script = '', [string]$Defect = '')
$ErrorActionPreference = 'Stop'
if (-not $Script) { $Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'guest/qubes-windows-update.ps1' }
$src = Get-Content -LiteralPath $Script -Raw
function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN[^\n]*\n(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found"; exit 2 }
    return $m.Groups[1].Value
}
$readRegion = Region 'WU-SECPLATFORM-READ'
$region = Region 'WU-SECURITY-PLATFORM'
$verdictRegion = Region 'WU-AGENT-VERDICT'
# Every knob rewrites the ONE line that carries its guard tag; the pre-fix rule for the app is textual, the others are removals.
$appRule = "          if(`$appAfter -ne `$appBefore){ `$eff = `$true } elseif(`$secOffered -and `$appAfter -and (((`$appAfter -split '\.')[1..2]) -join '.') -eq (((`$secOffered -split '\.')[2..3]) -join '.')){ `$alreadyCurrent = `$true }   # DEFECT: the app decides"
$knobs = @{ noeffect = @{ tag = 'secplatform'; with = '          # DEFECT: guard removed' }
            nocurrent = @{ tag = 'seccurrent'; with = '          # DEFECT: guard removed' }
            unreadablefails = @{ tag = 'secunreadable'; with = '          # DEFECT: guard removed' }
            appcertifies = @{ tag = 'appnoteffect'; with = $appRule } }
if ($Defect -and -not $knobs.ContainsKey($Defect)) { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (noeffect | nocurrent | unreadablefails | appcertifies)"; exit 2 }
if ($Defect) {
    $k = $knobs[$Defect]
    $d = [regex]::Replace($region, "(?m)^.*# GUARD:$($k.tag)\b.*$", $k.with.Replace('$', '$$'))
    if ($d -eq $region) { Write-Output "INSTRUMENT: GUARD:$($k.tag) not found"; exit 2 }
    $region = $d
}
$script:fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }

# One case: the platform registry before and after (loc = CoreLocation, wu = Updates\wu, host = SecurityHealthHost.exe's FileVersion in
# CoreLocation), the SecHealthUI app before and after, the agent's ResultCode/HResult and the offer's title. Returns the row's verdict,
# plus the parsed BEFORE state so the reader itself is checked, and the path the reader asked the host's version from.
function Run-Case([hashtable]$before, [hashtable]$after, [string]$appBefore, [string]$appAfter, [int]$rc, [int]$hr, [string]$title) {
    $sb = [scriptblock]::Create(@'
param($before, $after, $appBefore, $appAfter, $rc, $hr, $title, $readRegion, $region, $verdictRegion)
function Log($m) { }
$script:Reg = $before
function Get-ItemProperty { param($LiteralPath, $Path, $Name, $EA)
    $k = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($k -like '*Windows Security Health\Platform' -and $script:Reg.loc) { return [pscustomobject]@{ CoreLocation = $script:Reg.loc } }
    if ($k -like '*Windows Security Health\Updates'  -and $script:Reg.wu)  { return [pscustomobject]@{ wu = $script:Reg.wu } }
    return $null }
function Get-Item { param($LiteralPath, $Path, $EA)
    $script:HostAsked = $LiteralPath
    if ($script:Reg.host) { return [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = $script:Reg.host } } }
    return $null }
$script:App = $appBefore
function Get-AppxPackage { param([switch]$AllUsers, $Name, $EA) if ($script:App) { [pscustomobject]@{ Version = $script:App } } }
Invoke-Expression $readRegion
$probe = 'security-platform'; $kb = 'KB5007651'; $label = 'KB5007651'
$secBefore = Get-SecurityPlatformState
$script:Reg = $after; $script:App = $appAfter
$agentRc = $rc; $agentHr = $hr; $agentErr = $null; $agentOk = ($agentRc -in @(2, 3))
$eff = $false; $probeRan = $true; $alreadyCurrent = $false; $platBehind = $false; $sigBehind = $false; $missing = @(); $reboot = $false
$script:St = [ordered]@{ available = @([pscustomobject]@{ kb = 'KB5007651'; title = $title }); reboot_needed = $false }
Invoke-Expression $region
Invoke-Expression $verdictRegion
[pscustomobject]@{ eff = $eff; probeRan = $probeRan; alreadyCurrent = $alreadyCurrent; ok = $ok; state = $state; sev = [string]$sev; reason = [string]$reason; before = $secBefore; hostAsked = [string]$script:HostAsked }
'@)
    return & $sb $before $after $appBefore $appAfter $rc $hr $title $readRegion $region $verdictRegion
}
# The states measured on the German 25H2 template (2026-10-03): the inbox platform (CoreLocation System32, no Updates key, the inbox host
# 10.0.26100.9278) and the installed one (the 10.0.29628.1000-0 folder, Updates\wu written, host 10.0.29628.1000); plus synthetic ones.
$inbox       = @{ loc = '\\?\C:\Windows\System32'; wu = $null; host = '10.0.26100.9278 (WinBuild.160101.0800)' }
$inboxNoHost = @{ loc = '\\?\C:\Windows\System32'; wu = $null; host = $null }
$plat        = @{ loc = '\\?\C:\Windows\System32\SecurityHealth\10.0.29628.1000-0'; wu = '10.0.29628.1000'; host = '10.0.29628.1000' }
$ahead       = @{ loc = '\\?\C:\Windows\System32\SecurityHealth\10.0.30000.1-0'; wu = '10.0.30000.1'; host = '10.0.30000.1' }
$low         = @{ loc = '\\?\C:\Windows\System32\SecurityHealth\10.0.29000.1-0'; wu = '10.0.29000.1'; host = '10.0.29000.1' }
$noloc       = @{ loc = $null; wu = $null; host = $null }
$offer = 'Update für Windows Security platform - KB5007651 (Version 10.0.29628.1000)'
$noVer = 'Update für Windows Security platform - KB5007651'
$appOld = '1000.26100.8036.0'; $appNew = '1000.29628.1000.0'

# ---- the reader
$r = Run-Case $inbox $inbox $appOld $appOld 2 0 $offer
Check 'read-inbox: System32 reads as the inbox platform - readable, no folder version, the host version is the comparable one, Updates\wu absent' `
      ($r.before.readable -and -not $r.before.ver -and $r.before.host -eq '10.0.26100.9278' -and $r.before.cmp -eq '10.0.26100.9278' -and -not $r.before.wu -and $r.hostAsked -eq 'C:\Windows\System32\SecurityHealthHost.exe')
$r = Run-Case $plat $plat $appNew $appNew 2 0 $offer
Check 'read-versioned: the version folder reads as 10.0.29628.1000 with Updates\wu, and the host is asked for under that folder' `
      ($r.before.readable -and $r.before.ver -eq '10.0.29628.1000' -and $r.before.wu -eq '10.0.29628.1000' -and $r.before.cmp -eq '10.0.29628.1000' -and $r.hostAsked -eq 'C:\Windows\System32\SecurityHealth\10.0.29628.1000-0\SecurityHealthHost.exe')
$r = Run-Case $noloc $noloc $appOld $appOld 2 0 $offer
Check 'read-absent: no CoreLocation -> not readable' (-not $r.before.readable)

# ---- the verdict, agent ResultCode 2 unless stated
$r = Run-Case $inbox $plat $appOld $appOld 2 0 $offer
Check 'moved: inbox -> the offered platform (the app not yet moved, as measured) -> verified by effect, ok, installed' ($r.eff -and $r.ok -and $r.state -eq 'installed' -and -not $r.sev -and $r.reason -match 'verified by effect: security-platform')
$r = Run-Case $inbox $plat $appOld $appOld 2 0 $noVer
Check 'moved-noversion: the platform moved and the offer names no version -> the move is the effect, ok' ($r.eff -and $r.ok -and -not $r.sev)
$r = Run-Case $plat $plat $appNew $appNew 2 0 $offer
Check 'already-current: nothing moved and the platform is at the offer -> ALREADY CURRENT, ok, not informational' ((-not $r.eff) -and $r.alreadyCurrent -and $r.ok -and -not $r.sev -and $r.reason -match 'nothing to do')
$r = Run-Case $ahead $ahead $appNew $appNew 2 0 $offer
Check 'ahead: nothing moved and the platform is past the offer -> ALREADY CURRENT, ok' ((-not $r.eff) -and $r.alreadyCurrent -and $r.ok -and -not $r.sev)
$r = Run-Case $inbox $inbox $appOld $appOld 2 0 $offer
Check 'behind: the agent reports success but the platform stayed at inbox, below the offer -> a FAILED install, logged as a disagreement' `
      ((-not $r.eff) -and (-not $r.alreadyCurrent) -and (-not $r.ok) -and (-not $r.sev) -and $r.reason -match 'DISAGREEMENT' -and $r.reason -match 'below the offered 10\.0\.29628\.1000' -and $r.reason -match 'did NOT install')
$r = Run-Case $inbox $low $appOld $appOld 2 0 $offer
Check 'moved-behind: the platform moved but only to a version below the offer -> FAILED, the reason says where it moved' ((-not $r.eff) -and (-not $r.ok) -and $r.reason -match 'moved only to 10\.0\.29000\.1')
$r = Run-Case $inbox $inbox $appOld $appNew 2 0 $offer
Check 'concealment-app-moved: the APP moved to the offered build but the platform stayed at inbox -> FAILED (the app is not the effect)' ((-not $r.eff) -and (-not $r.ok) -and (-not $r.alreadyCurrent) -and $r.reason -match 'did NOT install')
$r = Run-Case $inbox $inbox $appNew $appNew 2 0 $offer
Check 'concealment-app-current: the APP is at the offered build over an inbox platform (the rz35 state) -> FAILED, never already current' ((-not $r.ok) -and (-not $r.alreadyCurrent) -and $r.reason -match 'did NOT install')
$r = Run-Case $inbox $inbox $appOld $appOld 2 0 $noVer
Check 'no-version-in-offer: nothing moved and the offer names no version -> FAILED for this item, and the reason says why' ((-not $r.ok) -and (-not $r.alreadyCurrent) -and $r.reason -match 'names no version')
$r = Run-Case $inboxNoHost $inboxNoHost $appOld $appOld 2 0 $offer
Check 'inbox-nohost: inbox platform whose host version cannot be read, nothing moved -> FAILED, the reason says the version is unreadable' ((-not $r.ok) -and $r.reason -match 'version unreadable')
$r = Run-Case $inbox $inbox $appOld $appOld 4 ([int]-2145124318) $offer
Check 'agent-failed: the agent reports ResultCode 4 -> FAILED with the HResult in the reason' ((-not $r.ok) -and $r.reason -match 'FAILED this update' -and $r.reason -match '0x80240022')
$r = Run-Case $inbox $noloc $appOld $appOld 2 0 $offer
Check 'unreadable: CoreLocation unreadable after the install -> the probe did not run, no verdict from it (ok from the agent, said so)' ((-not $r.probeRan) -and $r.ok -and -not $r.sev -and $r.reason -match 'DID NOT RUN')
$r = Run-Case $noloc $plat $appOld $appOld 2 0 $offer
Check 'unreadable-before: CoreLocation unreadable before the install -> the probe did not run' ((-not $r.probeRan) -and $r.ok -and -not $r.sev)

if ($script:fails -eq 0) { Write-Output 'PASS  KB5007651 is decided by the PLATFORM against the offer: moved ok, at the offer already current, otherwise FAILED; the app decides nothing'; exit 0 }
Write-Output "FAIL  $($script:fails) check(s)"; exit 1
