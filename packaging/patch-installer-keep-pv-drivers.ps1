<#
.SYNOPSIS
Build-time patch: the MSI keeps the Xen PV driver packages on any removal while Xen's disk-unplug
latch is armed, so uninstalling QWT does not leave a qube that cannot boot (docs/ADR-boot.md 5).

.DESCRIPTION
xen.sys reads HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug at every boot start, delete-on-read,
and the running PV drivers arm it again for the next boot: DISKS present means the next boot unplugs
the emulated disks. The stock package's DIFxApp step (difxapp:Driver in PvDriversComponents.wxs)
removes every driver package on uninstall. That unbinds xenvbd from the PV disk adapter but leaves
xenbus, xenfilt and xenvbd boot-start, so the next boot unplugs the emulated disk with no PV disk
driver bound and stops with INACCESSIBLE_BOOT_DEVICE.

Two edits. Each refuses to apply twice, throws when it does not apply, and is read back:
  -WxsPath  Package.wxs gains <Property Id="QWTNG_PVDISKUNPLUG" Secure="yes"> holding a
            RegistrySearch of the latch's DISKS value (raw, 64-bit view). AppSearch runs in both
            sequences, so the property is set on install, repair and removal alike.
  -MsiPath  the BUILT installer.msi. The DIFxApp extension schedules MsiProcessDrivers with the
            condition 'VersionNT > 400' and does not let authoring override it, so its
            InstallExecuteSequence row is rewritten to
                VersionNT > 400 AND NOT (QWTNG_PVDISKUNPLUG AND REMOVE)
            No feature removal runs the driver step while the latch is armed: Control Panel's
            uninstall, a modify that drops a driver feature, or this product's removal by a later
            version's upgrade, whose own install then updates the packages. An install or repair
            (REMOVE empty) runs it as stock does, and with the latch absent every path is stock's.
            The read-back also proves the AppSearch, RegLocator and SecureCustomProperties rows the
            first edit must have produced. Run it BEFORE anything embeds the MSI (the Burn bundle).
#>
[CmdletBinding(DefaultParameterSetName = 'Wxs')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Wxs')][string]$WxsPath,
    [Parameter(Mandatory, ParameterSetName = 'Msi')][string]$MsiPath
)
$ErrorActionPreference = 'Stop'
$propertyOpen = '<Property Id="QWTNG_PVDISKUNPLUG" Secure="yes">'
$searchLine = '<RegistrySearch Id="QwtngPvDiskUnplug" Root="HKLM" Key="SYSTEM\CurrentControlSet\Services\XEN\Unplug" Name="DISKS" Type="raw" Bitness="always64" />'
$stockCondition = 'VersionNT > 400'
$keepCondition = 'VersionNT > 400 AND NOT (QWTNG_PVDISKUNPLUG AND REMOVE)'

if ($PSCmdlet.ParameterSetName -eq 'Wxs') {
    if (-not (Test-Path -LiteralPath $WxsPath)) { throw "Package.wxs not found at $WxsPath" }
    $text = Get-Content -LiteralPath $WxsPath -Raw
    $hadBom = ([IO.File]::ReadAllBytes($WxsPath) | Select-Object -First 3) -join ',' -eq '239,187,191'
    if ($text -match 'QWTNG_PVDISKUNPLUG') { throw "refusing to patch twice: QWTNG_PVDISKUNPLUG is already present in $WxsPath" }
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = @(
        '    <!-- QWT-NG (docs/ADR-boot.md 5): set while Xen will unplug the emulated disks at the next boot; a removal then',
        '         keeps the PV driver packages - the built MSI''s MsiProcessDrivers condition names this property. -->',
        "    $propertyOpen",
        "      $searchLine",
        '    </Property>'
    )
    $re = '(?m)^([ \t]*<Property Id="ARPPRODUCTICON" Value="icon\.ico" />[ \t]*)(\r?\n)'
    $n = [regex]::Matches($text, $re).Count
    if ($n -ne 1) { throw "patch did not apply: expected exactly one '<Property Id=""ARPPRODUCTICON"" .../>' line in $WxsPath, found $n" }
    $out = ([regex]$re).Replace($text, ('$1$2' + (($lines -join $nl) -replace '\$', '$$$$') + $nl), 1)
    if ($out -eq $text) { throw "patch did not apply (no change) in $WxsPath" }
    [IO.File]::WriteAllText($WxsPath, $out, (New-Object System.Text.UTF8Encoding($hadBom)))
    $check = Get-Content -LiteralPath $WxsPath -Raw
    foreach ($must in $propertyOpen, $searchLine) {
        $c = ([regex]::Matches($check, [regex]::Escape($must))).Count
        if ($c -ne 1) { throw "post-check FAILED: '$must' appears $c time(s) in $WxsPath after patching, expected 1" }
    }
    if ($check -notmatch ('(?s)' + [regex]::Escape($propertyOpen) + '\s*' + [regex]::Escape($searchLine) + '\s*</Property>')) {
        throw "post-check FAILED: the RegistrySearch is not inside the QWTNG_PVDISKUNPLUG property in $WxsPath"
    }
    Write-Host "added the secure QWTNG_PVDISKUNPLUG property (RegistrySearch of XEN\Unplug DISKS, raw, 64-bit) to $WxsPath"
    return
}

if (-not (Test-Path -LiteralPath $MsiPath)) { throw "installer.msi not found at $MsiPath" }
$query = {
    param($db, [string]$sql)
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $rows = @()
    while ($rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)) {
        $nf = [int]$rec.GetType().InvokeMember('FieldCount', 'GetProperty', $null, $rec, $null)
        $rows += , @(1..$nf | ForEach-Object { [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @([int]$_)) })
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($rec)
    }
    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    return , $rows
}
$conditionSql = "SELECT ``Condition`` FROM ``InstallExecuteSequence`` WHERE ``Action``='MsiProcessDrivers'"
$wi = New-Object -ComObject WindowsInstaller.Installer
$db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($MsiPath, 1))   # 1 = transact
$before = & $query $db $conditionSql
if ($before.Count -ne 1) { throw "InstallExecuteSequence has $($before.Count) MsiProcessDrivers row(s) in $MsiPath, expected 1" }
if ($before[0][0] -ne $stockCondition) { throw "MsiProcessDrivers condition is '$($before[0][0])', expected the DIFxApp extension's '$stockCondition' - the pinned WiX changed shape or the MSI was patched already" }
[void](& $query $db "UPDATE ``InstallExecuteSequence`` SET ``Condition``='$keepCondition' WHERE ``Action``='MsiProcessDrivers'")
[void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)

$db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($MsiPath, 0))   # 0 = read-only
$after = & $query $db $conditionSql
$search = & $query $db "SELECT ``Signature_`` FROM ``AppSearch`` WHERE ``Property``='QWTNG_PVDISKUNPLUG'"
$locator = & $query $db "SELECT ``Root``, ``Key``, ``Name``, ``Type`` FROM ``RegLocator`` WHERE ``Signature_``='QwtngPvDiskUnplug'"
$secure = & $query $db "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='SecureCustomProperties'"
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wi)
if ($after.Count -ne 1 -or $after[0][0] -ne $keepCondition) { throw "read-back FAILED: MsiProcessDrivers condition is '$($after | ForEach-Object { $_[0] })', expected '$keepCondition'" }
if ($search.Count -ne 1 -or $search[0][0] -ne 'QwtngPvDiskUnplug') { throw 'read-back FAILED: no AppSearch row sets QWTNG_PVDISKUNPLUG from QwtngPvDiskUnplug - run this script with -WxsPath on Package.wxs before the build' }
# RegLocator Root 2 = HKLM; Type 18 = raw (2) + 64-bit view (16).
if ($locator.Count -ne 1 -or ($locator[0] -join '|') -ne '2|SYSTEM\CurrentControlSet\Services\XEN\Unplug|DISKS|18') { throw "read-back FAILED: RegLocator QwtngPvDiskUnplug is '$($locator | ForEach-Object { $_ -join '|' })', expected '2|SYSTEM\CurrentControlSet\Services\XEN\Unplug|DISKS|18'" }
if ($secure.Count -ne 1 -or ($secure[0][0] -split ';') -notcontains 'QWTNG_PVDISKUNPLUG') { throw 'read-back FAILED: QWTNG_PVDISKUNPLUG is not in SecureCustomProperties' }
Write-Host "MsiProcessDrivers condition in $MsiPath is now '$keepCondition'; AppSearch, RegLocator (HKLM XEN\Unplug DISKS, raw, 64-bit) and SecureCustomProperties carry QWTNG_PVDISKUNPLUG"
