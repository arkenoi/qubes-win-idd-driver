# toast-uia-tree.ps1 — dump the UIA element tree of the live toast banner WITH bounding
# rectangles, so the crop target is chosen from measurement instead of from a class name.
#
# WHY: toastcrop.c measures FlexibleToastView/ToastView and crops to it. On the collapsed
# 396x133 banner that was right (16/30/16/13). On the EXPANDED 396x332 banner it is WRONG -
# measured on the guest 2026-08-11 after deploying the CI build: the announced rect became
# 1540,730 364x289, which CLIPS the toast's header row (the ... and X buttons) and leaves a
# strip of desktop wallpaper along the bottom. So FlexibleToastView is the CONTENT element,
# not the visible card. This dumps every descendant with its rect so the right element (the
# one whose bounds equal the drawn card) can be identified by number.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TT {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# Find the banner the same way toastcrop.c's classifier does: a visible, unowned
# Windows.UI.Core.CoreWindow that is WS_POPUP + TOPMOST + NOREDIRECTIONBITMAP.
$target = $null; $targetRect = $null
$cb = [TT+EnumProc]{
    param($h, $p)
    if (-not [TT]::IsWindowVisible($h)) { return $true }
    $cn = New-Object System.Text.StringBuilder 256
    [void][TT]::GetClassNameW($h, $cn, 256)
    if ($cn.ToString() -ne 'Windows.UI.Core.CoreWindow') { return $true }
    $ex = ([TT]::GetWindowLongPtr($h, -20)).ToInt64()
    if (($ex -band 0x8) -eq 0) { return $true }          # WS_EX_TOPMOST
    $r = New-Object TT+RECT; [void][TT]::GetWindowRect($h, [ref]$r)
    if (($r.Right - $r.Left) -le 1) { return $true }     # the parked 1x1 Start CoreWindow
    $script:target = $h; $script:targetRect = $r
    return $true
}
[void][TT]::EnumWindows($cb, [IntPtr]::Zero)

if (-not $target) { Write-Output 'NO-TOAST-WINDOW'; exit 0 }

$r = $script:targetRect
Write-Output ("WINDOW hwnd=0x{0:x} rect=({1},{2})-({3},{4}) size={5}x{6}" -f `
    $target.ToInt64(), $r.Left, $r.Top, $r.Right, $r.Bottom, ($r.Right-$r.Left), ($r.Bottom-$r.Top))

$el = [System.Windows.Automation.AutomationElement]::FromHandle($target)
if (-not $el) { Write-Output 'NO-UIA-ELEMENT'; exit 0 }

# Walk the whole subtree, printing each element's class and bounds as INSETS relative to the
# window rect - which is exactly the form toastcrop.c needs.
$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
function Walk($e, $depth) {
    if (-not $e -or $depth -gt 6) { return }
    try {
        $b = $e.Current.BoundingRectangle
        if ($b.Width -gt 0 -and $b.Height -gt 0) {
            Write-Output ("{0}{1,-28} cls={2,-24} rect=({3},{4}) {5}x{6}  insets L={7} T={8} R={9} B={10}" -f `
                ('  ' * $depth), $e.Current.Name.PadRight(0).Substring(0, [Math]::Min(26, $e.Current.Name.Length)),
                $e.Current.ClassName, [int]$b.Left, [int]$b.Top, [int]$b.Width, [int]$b.Height,
                ([int]$b.Left - $r.Left), ([int]$b.Top - $r.Top),
                ($r.Right - [int]($b.Left + $b.Width)), ($r.Bottom - [int]($b.Top + $b.Height)))
        }
    } catch { Write-Output ("{0}<error reading element>" -f ('  ' * $depth)) }

    $child = $walker.GetFirstChild($e)
    while ($child) {
        Walk $child ($depth + 1)
        $child = $walker.GetNextSibling($child)
    }
}
Walk $el 0
