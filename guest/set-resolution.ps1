# Set (or enumerate) the guest display mode. Used to establish SUB-HOST CONTAINMENT before any
# P5 safeguard cell: a probe sized "fullscreen" against a guest that is silently still at host
# size is not a fullscreen probe at all, and the cell grades nothing (P5-3).
#
#   set-resolution.ps1 -List                 # every mode the adapter offers
#   set-resolution.ps1 -Width 1280 -Height 800
#   set-resolution.ps1 -Contain              # pick the largest offered mode strictly inside the host
#
# WHY THIS IS WRITTEN WITH RAW OFFSETS AND NOT A STRUCT.
# The previous version declared DEVMODE as a managed struct with `CharSet=CharSet.Ansi` and
# `UnmanagedType.ByValTStr`. Two consequences, both silent:
#   * `ByValTStr SizeConst=32` under Ansi occupies 32 BYTES, not 32 WCHARs, so the declaration
#     described DEVMODEA (156 bytes) while `string` + the default DllImport binding resolved
#     `EnumDisplaySettingsW`, which expects DEVMODEW (220 bytes). Every field past dmDeviceName
#     was read from the wrong offset.
#   * `Marshal::SizeOf` disagreed with `Marshal::OffsetOf` on this struct, and the fix committed on
#     2026-08-30 was to hard-code `dmSize = 156` to match the OFFSETS. That made the numbers
#     self-consistent and the call still wrong, because the mismatch was never the size - it was
#     ANSI-vs-WIDE. Hard-coding a constant to silence a disagreement between two measurements of
#     the same thing is how a broken instrument gets a green banner.
# Marshalling by explicit offset into unmanaged memory removes the entire class: there is no
# layout to get wrong, and the offsets below are the documented DEVMODEW ones.
#
# AND IT ADDRESSES THE ACTIVE ADAPTER BY NAME, NEVER BY NULL.
# Measured 2026-08-30 on win10-p46: the guest has TWO display devices, and the desktop is on
# `\\.\DISPLAY2` (EnumDisplaySettings rc=1, 5120x1440, 7 modes). `\\.\DISPLAY1` publishes 29
# modes but has NO current mode (rc=0) - attached and inactive. Passing lpszDeviceName = NULL, which
# the old script did, returned FALSE, and `EnumDisplayDevices` enumerates nothing at all here, so
# there was no cheap way to notice. That single wrong argument is the whole defect: DEVMODE
# marshalling was never involved, as `EnumDisplaySettings("\\.\DISPLAY1", 0, dm)` proves by
# returning 640x480 read from offsets 172/176 of the very same 220-byte buffer.
#
# AND IT VALIDATES ITSELF BEFORE IT IS TRUSTED (H5). After reading the current mode it compares
# dmPelsWidth/dmPelsHeight against GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN). Those are two
# independent paths to the same fact; if they disagree the offsets are wrong, and the script exits
# `instrument_invalid` instead of reporting a resolution. A read path that cannot be shown correct
# may not be used to certify a write path.
param(
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$List,
    [switch]$Contain,
    [int]$SettleSec = 4
)
$ErrorActionPreference = 'Continue'

Add-Type -Namespace Res -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplaySettingsW")]
public static extern int EnumDisplaySettings(string dev, int mode, IntPtr dm);
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsExW")]
public static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr wnd, int flags, IntPtr param);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
'@

# --- documented DEVMODEW offsets (bytes) -------------------------------------------------------
$DM_SIZE_BYTES   = 220     # sizeof(DEVMODEW)
$OFF_DMSIZE      = 68      # WORD  dmSize
$OFF_DMFIELDS    = 72      # DWORD dmFields
$OFF_BITSPERPEL  = 168     # DWORD dmBitsPerPel
$OFF_PELSWIDTH   = 172     # DWORD dmPelsWidth
$OFF_PELSHEIGHT  = 176     # DWORD dmPelsHeight
$OFF_DISPLAYFREQ = 184     # DWORD dmDisplayFrequency
$DM_PELSWIDTH    = 0x00080000
$DM_PELSHEIGHT   = 0x00100000
$DM_BITSPERPEL   = 0x00040000
$ENUM_CURRENT    = -1
$CDS_UPDATEREGISTRY = 0x00000001

function New-Devmode {
    $p = [Runtime.InteropServices.Marshal]::AllocHGlobal($DM_SIZE_BYTES)
    for ($i = 0; $i -lt $DM_SIZE_BYTES; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($p, $i, 0) }
    [Runtime.InteropServices.Marshal]::WriteInt16($p, $OFF_DMSIZE, [int16]$DM_SIZE_BYTES)
    return $p
}
function Read-Mode($p) {
    [pscustomobject]@{
        w    = [Runtime.InteropServices.Marshal]::ReadInt32($p, $OFF_PELSWIDTH)
        h    = [Runtime.InteropServices.Marshal]::ReadInt32($p, $OFF_PELSHEIGHT)
        bpp  = [Runtime.InteropServices.Marshal]::ReadInt32($p, $OFF_BITSPERPEL)
        freq = [Runtime.InteropServices.Marshal]::ReadInt32($p, $OFF_DISPLAYFREQ)
    }
}
function Free-Devmode($p) { if ($p -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($p) } }

function Fail($reason, $extra) {
    Write-Output '=== RESULT ==='
    $o = @{ ok = $false; error = $reason }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    $o | ConvertTo-Json -Compress
}

# --- 1. find the ACTIVE display device, and PROVE the read path before trusting it -------------
function Get-CurrentMode($dev) {
    $p = New-Devmode
    $rc = [Res.Native]::EnumDisplaySettings($dev, $ENUM_CURRENT, $p)
    $m = Read-Mode $p
    Free-Devmode $p
    if ($rc -eq 0) { return $null }
    return $m
}
$active = $null; $activeMode = $null; $scanned = @()
foreach ($n in 1..8) {
    $dev = "\\.\DISPLAY$n"
    $m = Get-CurrentMode $dev
    $scanned += "${dev}:$(if ($m) { "$($m.w)x$($m.h)" } else { 'no-current-mode' })"
    if ($m -and $m.w -gt 0 -and -not $active) { $active = $dev; $activeMode = $m }
}
if (-not $active) {
    Fail 'no display device reports a current mode' @{ scanned = $scanned }
    exit 2
}
$cur = $activeMode

$mx = [Res.Native]::GetSystemMetrics(0); $my = [Res.Native]::GetSystemMetrics(1)
$instrumentOk = ($cur.w -eq $mx -and $cur.h -eq $my -and $cur.w -gt 0)
if (-not $instrumentOk) {
    # Two independent reads of one fact disagree => the offsets are wrong, or the device picked is
    # not the one carrying the desktop. Refuse to report either way.
    Fail 'instrument_invalid: DEVMODE read disagrees with GetSystemMetrics' `
         @{ device = $active; devmode = "$($cur.w)x$($cur.h)"; metrics = "${mx}x${my}"; scanned = $scanned
            note = 'do NOT trust any resolution this script reports' }
    exit 3
}

# --- 2. enumerate the adapter's mode list ------------------------------------------------------
$modes = @(); $i = 0
while ($true) {
    $q = New-Devmode
    if ([Res.Native]::EnumDisplaySettings($active, $i, $q) -eq 0) { Free-Devmode $q; break }
    $m = Read-Mode $q; Free-Devmode $q
    if ($m.bpp -ge 32) { $modes += $m }
    $i++
    if ($i -gt 4096) { break }   # the adapter is misbehaving; do not spin forever
}
$uniq = $modes | Sort-Object -Property w, h -Unique

if ($List) {
    Write-Output '=== RESULT ==='
    @{ ok = $true; device = $active; scanned = $scanned
       current = "$($cur.w)x$($cur.h)"; instrument_validated = $true
       mode_count = $uniq.Count
       modes = @($uniq | ForEach-Object { "$($_.w)x$($_.h)" }) } | ConvertTo-Json -Compress
    exit 0
}

# --- 3. choose the target ----------------------------------------------------------------------
if ($Contain) {
    # Largest offered mode strictly smaller than the current screen in BOTH axes. "Strictly" is the
    # point: a mode equal to host size in either axis leaves a probe able to span the owner's display.
    $cand = $uniq | Where-Object { $_.w -lt $cur.w -and $_.h -lt $cur.h } |
            Sort-Object -Property @{ Expression = { $_.w * $_.h } } -Descending
    if (-not $cand -or $cand.Count -eq 0) {
        Fail 'no offered mode is strictly smaller than the current screen in both axes' `
             @{ current = "$($cur.w)x$($cur.h)"; offered = @($uniq | ForEach-Object { "$($_.w)x$($_.h)" }) }
        exit 4
    }
    $Width = $cand[0].w; $Height = $cand[0].h
}
if ($Width -le 0 -or $Height -le 0) { Fail 'give -Width/-Height, or -Contain, or -List' $null; exit 2 }

$want = "${Width}x${Height}"
$offered = @($uniq | Where-Object { $_.w -eq $Width -and $_.h -eq $Height })
if ($offered.Count -eq 0) {
    # The Basic Display Adapter publishes a FIXED mode list; an unoffered size returns BADMODE and
    # would otherwise read as "the change failed" rather than "that size does not exist here".
    Fail "requested mode is not in the adapter's list" `
         @{ wanted = $want; current = "$($cur.w)x$($cur.h)"
            offered = @($uniq | ForEach-Object { "$($_.w)x$($_.h)" }) }
    exit 4
}

# --- 4. apply -----------------------------------------------------------------------------------
$p = New-Devmode
[void][Res.Native]::EnumDisplaySettings($active, $ENUM_CURRENT, $p)
[Runtime.InteropServices.Marshal]::WriteInt32($p, $OFF_PELSWIDTH,  $Width)
[Runtime.InteropServices.Marshal]::WriteInt32($p, $OFF_PELSHEIGHT, $Height)
[Runtime.InteropServices.Marshal]::WriteInt32($p, $OFF_DMFIELDS, ($DM_PELSWIDTH -bor $DM_PELSHEIGHT -bor $DM_BITSPERPEL))
$rc = [Res.Native]::ChangeDisplaySettingsEx($active, $p, [IntPtr]::Zero, $CDS_UPDATEREGISTRY, [IntPtr]::Zero)
Free-Devmode $p
Start-Sleep -Seconds $SettleSec

# --- 5. the verdict is the READ-BACK, never the return code -------------------------------------
$p2 = New-Devmode
[void][Res.Native]::EnumDisplaySettings($active, $ENUM_CURRENT, $p2)
$now = Read-Mode $p2
Free-Devmode $p2
$mx2 = [Res.Native]::GetSystemMetrics(0); $my2 = [Res.Native]::GetSystemMetrics(1)

$rcName = switch ($rc) { 0 {'SUCCESSFUL'} 1 {'RESTART'} -1 {'FAILED'} -2 {'BADMODE'} -3 {'NOTUPDATED'} -4 {'BADFLAGS'} -5 {'BADPARAM'} default {"rc$rc"} }
$ok = ($now.w -eq $Width -and $now.h -eq $Height -and $mx2 -eq $Width -and $my2 -eq $Height)

Write-Output '=== RESULT ==='
@{ ok = $ok; device = $active; was = "$($cur.w)x$($cur.h)"; wanted = $want
   now = "$($now.w)x$($now.h)"; metrics = "${mx2}x${my2}"
   rc = $rc; rc_name = $rcName; instrument_validated = $true } | ConvertTo-Json -Compress
if (-not $ok) { exit 1 }
