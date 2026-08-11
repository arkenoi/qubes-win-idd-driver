# render-truth.ps1 — GUEST-SIDE ground truth for rendering correctness.
#
# WHY: every existing check asks the agent whether it thinks it drew something. That is the
# wrong question - "RecreateDuplication: recovered - windows kept" was logged while every dom0
# window was frozen. The only honest question is whether dom0's PIXELS match the guest's own
# screen. This produces the guest half of that comparison; tools/rendercheck does the compare.
#
# Emits one line of JSON metadata (screen size + every mapped top-level window) followed by the
# full-desktop PNG as base64 between markers. Everything is DATA: the caller parses it, nothing
# from here is executed.
[CmdletBinding()]
param([switch]$NoImage)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# CharSet=Unicode is REQUIRED on the string calls: with the default (Ansi) marshalling the W
# entry points get a UTF-16 buffer read as ANSI, so every title came back as its first
# character ("Untitled - Notepad" -> "U"). Measured 2026-08-11 on the first run of this script.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RT {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# Load Forms BEFORE touching the type: referencing it first throws TypeNotFound, and the throw
# happens at parse time of the sub-expression, so a try/catch fallback never runs.
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen

$wins = New-Object System.Collections.ArrayList
$cb = [RT+EnumProc]{
    param($h, $p)
    if (-not [RT]::IsWindowVisible($h)) { return $true }
    # Use DWMWA_EXTENDED_FRAME_BOUNDS (9), NOT GetWindowRect: on Win11 GetWindowRect includes the
    # ~7 px invisible resize border, so it reported 1440x753 for a Notepad the agent announces (and
    # dom0 renders) as 1426x746. Comparing against the wrong rect would flag every window as a
    # size mismatch. Fall back to GetWindowRect when DWM has no bounds (non-composited windows).
    $r = New-Object RT+RECT
    if ([RT]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) {
        [void][RT]::GetWindowRect($h, [ref]$r)
    }
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder 512
    [void][RT]::GetWindowTextW($h, $sb, 512); $title = $sb.ToString()
    $cn = New-Object System.Text.StringBuilder 256
    [void][RT]::GetClassNameW($h, $cn, 256)
    $cloaked = 0; [void][RT]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)
    [void]$wins.Add([pscustomobject]@{
        hwnd    = ('0x{0:x}' -f $h.ToInt64())
        title   = $title
        class   = $cn.ToString()
        x = $r.Left; y = $r.Top; w = $w; h = $ht
        style   = ('0x{0:x8}' -f ([RT]::GetWindowLongPtr($h, -16)).ToInt64())
        exstyle = ('0x{0:x8}' -f ([RT]::GetWindowLongPtr($h, -20)).ToInt64())
        cloaked = $cloaked
        owner   = ('0x{0:x}' -f ([RT]::GetWindow($h, 4)).ToInt64())
    })
    return $true
}
[void][RT]::EnumWindows($cb, [IntPtr]::Zero)

$meta = [pscustomobject]@{
    ts     = (Get-Date).ToUniversalTime().ToString('o')
    screen = @{ x = $screen.X; y = $screen.Y; w = $screen.Width; h = $screen.Height }
    windows = $wins
}
Write-Output ('RTMETA ' + ($meta | ConvertTo-Json -Depth 5 -Compress))

if ($NoImage) { return }

$bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($screen.X, $screen.Y, 0, 0, $bmp.Size)
$g.Dispose()
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output 'RTIMG-BEGIN'
Write-Output ([Convert]::ToBase64String($ms.ToArray()))
Write-Output 'RTIMG-END'
