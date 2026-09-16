<#
.SYNOPSIS
Build-time patch: remove the stock PreparePrivateImg custom action from the installer's
Package.wxs, so the MSI never touches disks. Install-QwtImproved.ps1 owns Q: now.

.DESCRIPTION
WHY. Stock QWT 4.2.2 creates the private volume from a deferred custom action that runs an
8-line script: ONE cold `Get-Disk -Number 1`, and only if that disk is RAW and stock-named does
it format it as Q:. Otherwise it silently does nothing, and the action is Return="ignore", so
msiexec reports success regardless. Measured 2026-09-16: 4 of 28 clean Win10 installs finished
with no Q: that way, 3 of them graded ok:true. The script also cannot tell the private disk
from the volatile (both RAW 'QEMU HARDDISK' on the emulated path it runs on) - a volatile at #1
would be formatted as Q: and every profile lost at the next reboot.

Install-QwtImproved.ps1 (Wait-PrivateDiskReady) now identifies the private disk by SERIAL -
measured on both the emulated (QM00002) and PV (0001) paths - and creates Q: on it BEFORE
msiexec, with the same two calls stock makes, verifying the result. That makes the stock
action a no-op at best and, with the volatile at #1, a not-quite-no-op (it would still put a
partition table on the scratch disk and then fail on the taken drive letter). Owner,
2026-09-16: "if it is no op, drop it." So it is dropped here, at build time, the way every
other change to upstream sources reaches a build in this repo (the windows-utils interactive-
logon patch, the xenbus.inf monitor neutralisation): the installer source is cloned fresh at
the pinned tag in qwt-full.yml, so an edit to the read-only mirror under upstream/ro/ would
never ship.

WHAT IT REMOVES, from vs2022/installer/Package.wxs, all three or it FAILS THE BUILD:
  1. <SetProperty Id="PreparePrivateImg" ... />      the CustomActionData (the powershell line)
  2. <CustomAction Id="PreparePrivateImg" ... />     the WixQuietExec action, Return="ignore"
  3. <Custom Action="PreparePrivateImg" ... />        its InstallExecuteSequence entry
The prepare-private-img.ps1 File component is left in place: an unreferenced script in bin\
is harmless, and removing a component changes component GUID bookkeeping across upgrades.

A patch that silently no-ops would ship the defect under a new version number, so every step
throws when it does not apply, and the post-check requires the identifier to be GONE from the
file entirely.

.PARAMETER WxsPath
Path to Package.wxs in the freshly cloned installer source.
#>
param(
    [Parameter(Mandatory)][string]$WxsPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $WxsPath)) { throw "Package.wxs not found at $WxsPath" }
$text = Get-Content -LiteralPath $WxsPath -Raw

# 1. the SetProperty block (multi-line element, closed by "/>")
$afterSet = [regex]::Replace($text, '(?s)\s*<SetProperty\s+Id="PreparePrivateImg"\s+.*?/>', '', 1)
if ($afterSet -eq $text) { throw "patch 1 did not apply: no <SetProperty Id=""PreparePrivateImg"" .../> in $WxsPath" }

# 2. the CustomAction block
$afterCa = [regex]::Replace($afterSet, '(?s)\s*<CustomAction\s+Id="PreparePrivateImg"\s+.*?/>', '', 1)
if ($afterCa -eq $afterSet) { throw "patch 2 did not apply: no <CustomAction Id=""PreparePrivateImg"" .../> in $WxsPath" }

# 3. the sequence entry (single line)
$afterSeq = [regex]::Replace($afterCa, '(?m)^[ \t]*<Custom\s+Action="PreparePrivateImg"[^>]*/>[ \t]*\r?\n', '', 1)
if ($afterSeq -eq $afterCa) { throw "patch 3 did not apply: no <Custom Action=""PreparePrivateImg"" .../> in InstallExecuteSequence of $WxsPath" }

Set-Content -LiteralPath $WxsPath -Value $afterSeq -NoNewline -Encoding UTF8

# POST-CHECK: read it back; the identifier must be gone, and the neighbouring actions must remain.
$check = Get-Content -LiteralPath $WxsPath -Raw
if ($check -match 'PreparePrivateImg') { throw "post-check FAILED: 'PreparePrivateImg' still present in $WxsPath after patching" }
foreach ($must in 'Id="RunInstallHelper"', 'Id="PrepareAutologon"', '<Custom Action="PrepareAutologon"', '<InstallExecuteSequence>') {
    if ($check -notmatch [regex]::Escape($must)) { throw "post-check FAILED: '$must' is missing after patching - the patch removed more than it should" }
}
Write-Host "dropped the stock PreparePrivateImg action from $WxsPath (SetProperty + CustomAction + sequence entry); PrepareAutologon and RunInstallHelper intact"
