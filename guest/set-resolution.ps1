# Set the guest display mode (benchmark-comparison helper). The agent's adopt-applied
# path (RESDRIFT) follows the change and re-announces/re-grants at the new size.
param([int]$Width = 1920, [int]$Height = 1080)
$ErrorActionPreference = 'Continue'
Add-Type -Namespace R -Name D -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    public int dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType,
        dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}
[DllImport("user32.dll")] public static extern int EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
[DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
'@
$dm = New-Object R.D+DEVMODE
# [int16], NOT [short]. `[short]` is not a PowerShell type accelerator - Windows PowerShell 5.1
# raises "Unable to find type [short]" here, the assignment never happens, dmSize stays 0, and
# EnumDisplaySettings/ChangeDisplaySettings are then called with an invalid DEVMODE. Because
# $ErrorActionPreference defaults to Continue the script kept going and still printed its
# "=== RESULT ===" banner, so a caller reading only the banner would believe the resolution had
# been set. Found 2026-08-30 while applying the SG0.2 sub-host containment.
# SizeOf on the INSTANCE, not on the Type. The Type overload does not resolve reliably under
# Windows PowerShell 5.1 here - it yielded no value at all, and the [int16] cast of that produced
# dmSize=124 for a struct whose measured field offsets prove it is 156 bytes (dmPanningHeight at
# 152 + 4). EnumDisplaySettings rejects a DEVMODE whose dmSize is wrong, which is why it returned 0
# and left the struct empty. Verified by reading Marshal::OffsetOf for every boundary field.
# dmSize is set to the MEASURED unmanaged size, not to Marshal::SizeOf.
# Marshal::SizeOf returns 124 for this struct under Windows PowerShell 5.1 - on both the Type and
# the instance overload - while Marshal::OffsetOf places dmPanningHeight (the final DWORD) at 152,
# which makes the true size 156, the documented sizeof(DEVMODEA). EnumDisplaySettings validates
# dmSize and returns 0 when it is wrong, leaving the struct empty; that is what made this script
# silently do nothing. The offsets are the authority here because they are what the marshaller
# actually uses to lay the struct out.
$dm.dmSize = [int16]156
# CHECK THE RETURN. This was `[void]`, so a total failure of EnumDisplaySettings was invisible and
# the script went on to print a "=== RESULT ===" banner that read like success. Measured
# 2026-08-30: {"rc":-2,"was":"0x0","now":"0x0"} - EnumDisplaySettings had returned 0, the DEVMODE
# was never populated, and ChangeDisplaySettings was handed an empty mode (rc -2 = BADMODE). A
# caller reading the banner would have believed the guest was contained at a sub-host resolution
# when nothing had changed - which is exactly the containment SG0.2 relies on.
$enumOk = [R.D]::EnumDisplaySettings($null, -1, [ref]$dm)
if (-not $enumOk -or $dm.dmPelsWidth -eq 0) {
    Write-Output '=== RESULT ==='
    @{ ok = $false; error = 'EnumDisplaySettings failed or returned an empty DEVMODE'
       enum_rc = $enumOk; dmSize = $dm.dmSize; was = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)" } | ConvertTo-Json -Compress
    exit 2
}
$was = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)"
$dm.dmPelsWidth = $Width; $dm.dmPelsHeight = $Height
$dm.dmFields = 0x80000 -bor 0x100000    # DM_PELSWIDTH | DM_PELSHEIGHT
$rc = [R.D]::ChangeDisplaySettings([ref]$dm, 0)   # CDS_UPDATEREGISTRY not needed
Start-Sleep 3
$cur = New-Object R.D+DEVMODE
$cur.dmSize = $dm.dmSize
[void][R.D]::EnumDisplaySettings($null, -1, [ref]$cur)
$now = "$($cur.dmPelsWidth)x$($cur.dmPelsHeight)"
$want = "${Width}x${Height}"
# The VERDICT is the read-back, not the return code: assert the mode the guest is actually in.
$ok = ($rc -eq 0 -and $now -eq $want)
Write-Output '=== RESULT ==='
@{ ok = $ok; was = $was; rc = $rc; now = $now; wanted = $want } | ConvertTo-Json -Compress
if (-not $ok) { exit 1 }
