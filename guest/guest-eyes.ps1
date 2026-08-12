# Guest-side ground truth: downscaled screenshot (base64 PNG on stdout) + top-level
# visible window list (handle, class, title, rect).
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$small = New-Object System.Drawing.Bitmap($bmp, [int]($b.Width/4), [int]($b.Height/4))
$ms = New-Object System.IO.MemoryStream
$small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output '=== SHOT-B64 ==='
[Convert]::ToBase64String($ms.ToArray())
Write-Output '=== WINDOWS ==='
Add-Type -Namespace E -Name W -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$list = New-Object System.Collections.Generic.List[string]
$cb = [E.W+EnumProc]{ param($h, $l)
    if ([E.W]::IsWindowVisible($h)) {
        $t = New-Object System.Text.StringBuilder 256; [void][E.W]::GetWindowText($h, $t, 256)
        $c = New-Object System.Text.StringBuilder 256; [void][E.W]::GetClassName($h, $c, 256)
        $r = New-Object E.W+RECT; [void][E.W]::GetWindowRect($h, [ref]$r)
        $list.Add(('0x{0:X} [{1}] "{2}" ({3},{4})-({5},{6})' -f $h.ToInt64(), $c, $t, $r.L, $r.T, $r.R, $r.B))
    }
    $true }
[void][E.W]::EnumWindows($cb, [IntPtr]::Zero)
$list
Write-Output '=== END ==='
