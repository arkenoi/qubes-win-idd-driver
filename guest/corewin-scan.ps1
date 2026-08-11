# Brute-force handle scan (EnumWindows is band-filtered): dump every visible
# Windows.UI.Core.CoreWindow with rect + the attributes IsShellToastWindow gates on.
$ErrorActionPreference = 'Continue'
Add-Type -Namespace C -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int m);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int m);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
Write-Output '=== RESULT ==='
for ($h = 0x10000; $h -lt 0x400000; $h += 2) {
    $p = [IntPtr]$h
    if (-not [C.W]::IsWindow($p)) { continue }
    if (-not [C.W]::IsWindowVisible($p)) { continue }
    $cls = New-Object Text.StringBuilder 128
    [void][C.W]::GetClassName($p, $cls, 128)
    if ($cls.ToString() -ne 'Windows.UI.Core.CoreWindow') { continue }
    $r = New-Object C.W+RECT; [void][C.W]::GetWindowRect($p, [ref]$r)
    $style = [C.W]::GetWindowLong($p, -16); $ex = [C.W]::GetWindowLong($p, -20)
    $cloak = 0; [void][C.W]::DwmGetWindowAttribute($p, 14, [ref]$cloak, 4)
    $procId = 0; [void][C.W]::GetWindowThreadProcessId($p, [ref]$procId)
    $pn = (Get-Process -Id $procId -ErrorAction SilentlyContinue).Name
    $txt = New-Object Text.StringBuilder 128
    [void][C.W]::GetWindowTextW($p, $txt, 128)
    Write-Output ("CW h=0x{0:X} proc={1} rect={2},{3} {4}x{5} style=0x{6:X8} ex=0x{7:X8} topmost={8} noredir={9} owner=0x{10:X} cloak={11} txt='{12}'" -f `
        $h, $pn, $r.L, $r.T, ($r.R-$r.L), ($r.B-$r.T), $style, $ex,
        [bool]($ex -band 0x8), [bool]($ex -band 0x200000),
        [C.W]::GetWindow($p,4).ToInt64(), $cloak, $txt.ToString())
}
Write-Output '=== END ==='
