<#
.SYNOPSIS
Build-time patch: make the MSI's StartServices action conditional on a public property
(QWTNG_SERIALSTART), so Install-QwtImproved.ps1 can tell Windows Installer NOT to start QWT's
services itself and start them one at a time instead.

.DESCRIPTION
WHY (docs/ADR-boot.md 1, owner-approved 2026-10-04). The guest stall - qrexec dead, the guest
frozen - is QEMU in the stub domain no longer completing the guest's I/O requests (Xen holds a vCPU
with pause_flags=4, blocked_in_xen, waiting for the device model), and it strikes in a FRESH
domain's first minutes under CONCENTRATED guest activity. In stage 2 of a clean install the
install log stopped 4 s after msiexec returned - the instant the MSI's StartServices action had
started QdbDaemon, QrexecAgent and QubesGuiWatchdog together, each opening its own vchan and
xenstore connections to dom0 at once. The rule (Jev 0.93): in a fresh domain's first minutes,
SERIALIZE AND PACE everything that reaches QEMU/Xen - one thing at a time, each step started when
the previous one's completion is OBSERVED. For the product Jev chose (0.99): after msiexec, QWT's
services come up ONE AT A TIME, each started only when the previous one is observed running (and
ready, where that is cheaply observable), before any further device step.

WHAT THIS CHANGES, and why it is ours to change. The pinned upstream WiX sources
(QubesOS/qubes-installer-qubes-os-windows-tools, INSTALLER_SHA in qwt-full.yml) declare the three
services with <ServiceControl Start="install" Wait="yes"> (CoreComponents.wxs, GuiComponents.wxs),
and the standard StartServices action starts them inside msiexec. The source is cloned fresh at the
pinned tag in qwt-full.yml, so - exactly like patch-installer-drop-prepareprivateimg.ps1 and the
xenbus.inf monitor neutralisation - the ONLY place a change can reach a build is a patch applied
there. Two insertions into vs2022/installer/Package.wxs:

  1. <Property Id="QWTNG_SERIALSTART" Secure="yes" />
     a public (upper-case) property, listed in SecureCustomProperties so it survives the
     client->server hand-off of a per-machine install;
  2. <StartServices Condition="VersionNT AND NOT QWTNG_SERIALSTART" />   in <InstallExecuteSequence>
     WiX's default condition for StartServices is VersionNT; the property suspends the action.

Everything else is untouched: InstallServices still registers the services (auto-start, same
dependencies), StopServices/DeleteServices still run on uninstall and upgrade, and an msiexec run
WITHOUT the property behaves exactly as stock (the MSI starts the services) - so the Burn bundle
and a hand-run msiexec are unchanged. Install-QwtImproved.ps1 passes QWTNG_SERIALSTART=1, VERIFIES
before running msiexec that the MSI's StartServices row carries the condition (a package where the
patch did not ship is refused, not silently un-paced), asserts after msiexec that no service is
running, and then starts them itself in dependency order.

A patch that silently no-ops would ship the old simultaneous start under a new version number, so
every step throws when it does not apply, the script refuses to apply twice, and the post-check
requires each element to be present exactly once.

.PARAMETER WxsPath
Path to Package.wxs in the freshly cloned installer source.
#>
param(
    [Parameter(Mandatory)][string]$WxsPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $WxsPath)) { throw "Package.wxs not found at $WxsPath" }
$text = Get-Content -LiteralPath $WxsPath -Raw
# The pinned file starts with a UTF-8 BOM; it is written back the way it was read (WiX accepts both).
$hadBom = ([IO.File]::ReadAllBytes($WxsPath) | Select-Object -First 3) -join ',' -eq '239,187,191'

# Refuse a second application: two StartServices rows would be a WiX build error at best and a
# silently different sequence at worst. The identifier is ours; stock never mentions it.
if ($text -match 'QWTNG_SERIALSTART') { throw "refusing to patch twice: QWTNG_SERIALSTART is already present in $WxsPath" }

# Keep the file's own line ending for the inserted lines.
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

# --- insertion 1: the property, right after the ARP icon property (the last plain <Property> of the package) ---
$propertyLines = @(
    '    <!-- QWT-NG (docs/ADR-boot.md 1): set to 1 by Install-QwtImproved.ps1 to keep Windows Installer from starting',
    '         the services itself; the wrapper then starts them one at a time, each after the previous one is observed',
    '         running. Public and secure so the command-line value reaches the deferred execute sequence. -->',
    '    <Property Id="QWTNG_SERIALSTART" Secure="yes" />'   # GUARD:wixsecure
)
$reAnchor1 = '(?m)^([ \t]*<Property Id="ARPPRODUCTICON" Value="icon\.ico" />[ \t]*)(\r?\n)'
$m1 = [regex]::Matches($text, $reAnchor1)
if ($m1.Count -ne 1) { throw "patch 1 did not apply: expected exactly one '<Property Id=""ARPPRODUCTICON"" .../>' line in $WxsPath, found $($m1.Count)" }
$afterProp = ([regex]$reAnchor1).Replace($text, ('$1$2' + (($propertyLines -join $nl) -replace '\$', '$$$$') + $nl), 1)
if ($afterProp -eq $text) { throw "patch 1 did not apply (no change) in $WxsPath" }

# --- insertion 2: the conditioned standard action, as the first child of <InstallExecuteSequence> ---
$startServicesLine = '      <StartServices Condition="VersionNT AND NOT QWTNG_SERIALSTART" />'   # GUARD:wixcond
$sequenceLines = @(
    '      <!-- QWT-NG (docs/ADR-boot.md 1): StartServices is suspended when the wrapper asks (QWTNG_SERIALSTART=1); the',
    '           services are then started one at a time by Install-QwtImproved.ps1, in dependency order, each after the',
    '           previous one is observed running. VersionNT is WiX''s own default condition for this action. -->',
    $startServicesLine
)
$reAnchor2 = '(?m)^([ \t]*<InstallExecuteSequence>[ \t]*)(\r?\n)'
$m2 = [regex]::Matches($afterProp, $reAnchor2)
if ($m2.Count -ne 1) { throw "patch 2 did not apply: expected exactly one '<InstallExecuteSequence>' line in $WxsPath, found $($m2.Count)" }
$afterSeq = ([regex]$reAnchor2).Replace($afterProp, ('$1$2' + (($sequenceLines -join $nl) -replace '\$', '$$$$') + $nl), 1)
if ($afterSeq -eq $afterProp) { throw "patch 2 did not apply (no change) in $WxsPath" }

[IO.File]::WriteAllText($WxsPath, $afterSeq, (New-Object System.Text.UTF8Encoding($hadBom)))

# POST-CHECK: read it back. Each element exactly once, the condition names the property, the property is
# secure, and the neighbouring actions the other patches depend on are still there.
$check = Get-Content -LiteralPath $WxsPath -Raw
$nProp = ([regex]::Matches($check, '<Property Id="QWTNG_SERIALSTART" Secure="yes" />')).Count
if ($nProp -ne 1) { throw "post-check FAILED: expected exactly one secure QWTNG_SERIALSTART property after patching, found $nProp" }
$nStart = ([regex]::Matches($check, '<StartServices Condition="VersionNT AND NOT QWTNG_SERIALSTART" />')).Count
if ($nStart -ne 1) { throw "post-check FAILED: expected exactly one conditioned StartServices action after patching, found $nStart" }
if (([regex]::Matches($check, '<StartServices\b')).Count -ne 1) { throw 'post-check FAILED: more than one StartServices element - the sequence would be ambiguous' }
# The action must sit INSIDE InstallExecuteSequence (between its open and close tags).
if ($check -notmatch '(?s)<InstallExecuteSequence>.*?<StartServices Condition="VersionNT AND NOT QWTNG_SERIALSTART" />.*?</InstallExecuteSequence>') {
    throw 'post-check FAILED: the StartServices element is not inside <InstallExecuteSequence>'
}
foreach ($must in 'Id="RunInstallHelper"', '<Custom Action="RunInstallHelper"', '<ScheduleReboot After="InstallFinalize" />', '<InstallExecuteSequence>', '</InstallExecuteSequence>') {
    if ($check -notmatch [regex]::Escape($must)) { throw "post-check FAILED: '$must' is missing after patching - the patch removed more than it should" }
}
Write-Host "conditioned the StartServices action on QWTNG_SERIALSTART in $WxsPath (secure public property + <StartServices Condition=...> in InstallExecuteSequence); RunInstallHelper and ScheduleReboot intact"
