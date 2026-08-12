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
$dm.dmSize = [short][System.Runtime.InteropServices.Marshal]::SizeOf([type][R.D+DEVMODE])
[void][R.D]::EnumDisplaySettings($null, -1, [ref]$dm)   # ENUM_CURRENT_SETTINGS
$was = "$($dm.dmPelsWidth)x$($dm.dmPelsHeight)"
$dm.dmPelsWidth = $Width; $dm.dmPelsHeight = $Height
$dm.dmFields = 0x80000 -bor 0x100000    # DM_PELSWIDTH | DM_PELSHEIGHT
$rc = [R.D]::ChangeDisplaySettings([ref]$dm, 0)   # CDS_UPDATEREGISTRY not needed
Start-Sleep 3
$cur = New-Object R.D+DEVMODE
$cur.dmSize = $dm.dmSize
[void][R.D]::EnumDisplaySettings($null, -1, [ref]$cur)
Write-Output '=== RESULT ==='
@{ was = $was; rc = $rc; now = "$($cur.dmPelsWidth)x$($cur.dmPelsHeight)" } | ConvertTo-Json -Compress
