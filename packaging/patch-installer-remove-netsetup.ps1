<#
.SYNOPSIS
Build-time patch: the MSI stops and deletes the QwtngNetSetup service when the product is removed,
before it removes windows-utils.dll.

.DESCRIPTION
QwtngNetSetup ("Qubes PV NIC address applier", qwtng-netsetup.exe) is created by
Install-QwtImproved.ps1 after msiexec (guest/pvnic-selfprime.ps1: sc create + restart recovery
actions), so it is no MSI component and the stock removal leaves it registered. The removal does
delete windows-utils.dll, which the service logs through; every start after that dies of
DllNotFoundException, the SCM restarts it per its recovery actions, and the death reporter tells
dom0 each time (GWECK-STATUS row 53).

The Name column of the ServiceControl table controls a service the package did not install, and
StopServices and DeleteServices run before RemoveFiles. One element is added, beside stock's own
QdbDaemon control in vs2022/installer/CoreComponents.wxs, so it belongs to the QubesDB component
(always installed, removed only with the product):

    <ServiceControl Id="QwtngNetSetupRemove" Name="QwtngNetSetup" Stop="uninstall" Remove="uninstall" Wait="yes" />

Install and repair do not touch the service (no install-time flags). A MajorUpgrade removes the old
product, so a build carrying this row deletes the service when a later version replaces it, and
the later version's Install-QwtImproved.ps1 creates it again after its msiexec, as it does on
every install. The service does not override OnStop, so the stop returns at once and Wait never
runs out.

A patch that silently no-ops would ship the leftover service under a new version number, so the
script refuses to apply twice, throws when its anchor is not found exactly once, and reads the
element back.

.PARAMETER WxsPath
Path to CoreComponents.wxs in the freshly cloned installer source.
#>
param(
    [Parameter(Mandatory)][string]$WxsPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $WxsPath)) { throw "CoreComponents.wxs not found at $WxsPath" }
$text = Get-Content -LiteralPath $WxsPath -Raw
$hadBom = ([IO.File]::ReadAllBytes($WxsPath) | Select-Object -First 3) -join ',' -eq '239,187,191'

$element = '<ServiceControl Id="QwtngNetSetupRemove" Name="QwtngNetSetup" Stop="uninstall" Remove="uninstall" Wait="yes" />'
if ($text -match 'QwtngNetSetup') { throw "refusing to patch twice: QwtngNetSetup is already present in $WxsPath" }

$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
$re = '(?m)^([ \t]*)(<ServiceControl Name="QdbDaemon" Start="install" Stop="uninstall" Remove="uninstall" Wait="yes" />)[ \t]*(\r?\n)'
$n = [regex]::Matches($text, $re).Count
if ($n -ne 1) { throw "patch did not apply: expected exactly one stock QdbDaemon <ServiceControl> line in $WxsPath, found $n" }
$indent = [regex]::Match($text, $re).Groups[1].Value
$lines = @(
    "$indent<!-- QWT-NG: QwtngNetSetup is created by Install-QwtImproved.ps1, not by this package; stop and delete it",
    "$indent     on removal, before windows-utils.dll (which it logs through) is removed. -->",
    "$indent$element"
)
$out = ([regex]$re).Replace($text, ('$0' + (($lines -join $nl) -replace '\$', '$$$$') + $nl), 1)
if ($out -eq $text) { throw "patch did not apply (no change) in $WxsPath" }
[IO.File]::WriteAllText($WxsPath, $out, (New-Object System.Text.UTF8Encoding($hadBom)))

$check = Get-Content -LiteralPath $WxsPath -Raw
$c = ([regex]::Matches($check, [regex]::Escape($element))).Count
if ($c -ne 1) { throw "post-check FAILED: the QwtngNetSetup <ServiceControl> appears $c time(s) in $WxsPath after patching, expected 1" }
if ($check -notmatch ('(?s)Id="QubesDB"(?:(?!</Component>).)*' + [regex]::Escape($element))) {
    throw "post-check FAILED: the QwtngNetSetup <ServiceControl> is not inside the QubesDB component in $WxsPath"
}
Write-Host "added <ServiceControl Name=""QwtngNetSetup"" Stop=""uninstall"" Remove=""uninstall""> to the QubesDB component in $WxsPath"
