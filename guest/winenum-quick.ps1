# Dump every top-level window with the attributes the gui-agent's acceptance predicate uses.
#
# WHY: on 2026-08-30 the owner reported a Windows Update dialog reaching their display CENTRED and
# mapped OVERRIDE-REDIRECT. Override-redirect means dom0 draws no trust border, so a guest dialog
# arriving that way is a window-classification defect, not a cosmetic one. tools/winenum.cs is the
# real instrument but needs a CI build; this exists to capture the attributes WHILE the window is
# still on screen, because the evidence disappears when it closes.
#
# Dumps exactly what ShouldAcceptWindow reasons about: styles, exstyles, owner, DWM cloak state,
# layered alpha, geometry - so the window can be classified from data instead of guessed at.
$ErrorActionPreference = 'Continue'

Add-Type -Namespace W -Name N -UsingNamespace System.Text -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int size);
public struct RECT { public int L, T, R, B; }
'@

$GWL_STYLE = -16; $GWL_EXSTYLE = -20; $GW_OWNER = 4; $DWMWA_CLOAKED = 14

# Style/exstyle bits that decide acceptance and decoration.
$S = @{ POPUP = 0x80000000; CAPTION = 0x00C00000; VISIBLE = 0x10000000; DLGFRAME = 0x00400000
        BORDER = 0x00800000; SYSMENU = 0x00080000; THICKFRAME = 0x00040000; CHILD = 0x40000000 }
$X = @{ TOOLWINDOW = 0x00000080; TOPMOST = 0x00000008; LAYERED = 0x00080000
        TRANSPARENT = 0x00000020; NOACTIVATE = 0x08000000; DLGMODALFRAME = 0x00000001
        APPWINDOW = 0x00040000 }

function Bits($v, $tbl) { ($tbl.Keys | Where-Object { ($v -band $tbl[$_]) -eq $tbl[$_] } | Sort-Object) -join '|' }

$rows = New-Object System.Collections.ArrayList
$cb = [W.N+EnumWindowsProc]{
    param($h, $p)
    if (-not [W.N]::IsWindowVisible($h)) { return $true }

    $sb = New-Object System.Text.StringBuilder 512
    [void][W.N]::GetClassNameW($h, $sb, 512); $cls = $sb.ToString()
    $sb2 = New-Object System.Text.StringBuilder 512
    [void][W.N]::GetWindowTextW($h, $sb2, 512); $title = $sb2.ToString()

    $style   = [int64][W.N]::GetWindowLongPtrW($h, $GWL_STYLE)
    $exstyle = [int64][W.N]::GetWindowLongPtrW($h, $GWL_EXSTYLE)
    if (($style -band $S.CHILD) -eq $S.CHILD) { return $true }   # children are never mapped

    $r = New-Object W.N+RECT; [void][W.N]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return $true }

    $owner = [W.N]::GetWindow($h, $GW_OWNER)
    $cloaked = 0; [void][W.N]::DwmGetWindowAttribute($h, $DWMWA_CLOAKED, [ref]$cloaked, 4)

    $alpha = 255; $key = 0; $flags = 0
    if (($exstyle -band $X.LAYERED) -eq $X.LAYERED) {
        [void][W.N]::GetLayeredWindowAttributes($h, [ref]$key, [ref]$alpha, [ref]$flags)
    }

    # NOT $pid: that is PowerShell's read-only automatic variable for the CURRENT process, so
    # the assignment silently fails and every window gets attributed to powershell itself -
    # which is exactly what the first run reported (Shell_TrayWnd owned by "powershell").
    $procId = 0; [void][W.N]::GetWindowThreadProcessId($h, [ref]$procId)
    $pname = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { "pid$procId" }

    # The decisive pair for decoration: a window with no WS_CAPTION is what the agent maps
    # without a title bar, and WS_POPUP without a caption is the override-redirect shape.
    $hasCaption = (($style -band $S.CAPTION) -eq $S.CAPTION)
    $isPopup    = (($style -band $S.POPUP) -eq $S.POPUP)

    [void]$rows.Add([pscustomobject]@{
        hwnd = ('0x{0:X}' -f [int64]$h); proc = $pname; cls = $cls
        title = $title.Substring(0, [Math]::Min(48, $title.Length))
        rect = "$($r.L),$($r.T) ${w}x${ht}"
        caption = $hasCaption; popup = $isPopup; cloaked = $cloaked; alpha = $alpha
        owner = ('0x{0:X}' -f [int64]$owner)
        style = ('0x{0:X8} ' -f $style) + (Bits $style $S)
        exstyle = ('0x{0:X8} ' -f $exstyle) + (Bits $exstyle $X)
    })
    return $true
}
[void][W.N]::EnumWindows($cb, [IntPtr]::Zero)

Write-Output '=== RESULT ==='
Write-Output ("visible top-level windows: {0}" -f $rows.Count)
Write-Output ''
# Surface the suspicious ones first: no caption = no title bar = mapped without decoration.
Write-Output '--- NO CAPTION (these are what map override-redirect / borderless) ---'
foreach ($x in ($rows | Where-Object { -not $_.caption })) { $x | Format-List | Out-String | Write-Output }
Write-Output '--- WITH CAPTION (normal bordered windows) ---'
foreach ($x in ($rows | Where-Object { $_.caption })) {
    Write-Output ("  {0,-22} {1,-32} {2,-26} {3}" -f $x.proc, $x.cls, $x.rect, $x.title)
}
