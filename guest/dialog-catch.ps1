# Watch for NEW top-level windows and record the attributes the gui-agent classifies on.
#
# WHY: the Windows Update restart dialog reached the owner's display as an OVERRIDE-REDIRECT
# window - centred, and with no dom0 trust border. The rule that demotes it is IsPopup() in
# gui-agent/main.c: a visible top-level window with no WS_CAPTION (and not WS_SYSMENU +
# WS_EX_APPWINDOW) is classified as an override-redirect popup. Modern Windows dialogs are
# custom-drawn and carry no standard caption, so a real dialog is treated like a menu.
#
# The rule to implement (owner, 2026-08-30): "all dialogs should be normal unless it is either
# toast or part of synthetic window". That is an INVERSION of the current predicate, and writing
# the discriminator without the real window's styles would be guesswork - the project rule is
# instrument first. Hence this: it captures the exact style/exstyle/owner/cloak/class of the
# dialog when it appears, so the new predicate can be written against measured attributes and
# checked against controls (a menu and a toast must STAY override-redirect).
#
# Records only windows it has not seen before, so the log is the arrival event rather than a
# repeated census. Writes through on every record: the guest may be rebooted by the very update
# that raises the dialog, and a buffered log would lose exactly the record that matters.
[CmdletBinding()]
param(
    [int]$Minutes = 120,
    [int]$IntervalSec = 3,
    [string]$LogPath = 'C:\dialog-catch.log'
)
$ErrorActionPreference = 'Continue'

Add-Type -Namespace D -Name N -MemberDefinition @'
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

$fs = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                                  [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::WriteThrough)
$sw = [System.IO.StreamWriter]::new($fs); $sw.AutoFlush = $true
function Rec([string]$line) { $sw.WriteLine($line); $sw.Flush(); $fs.Flush($true); Write-Host $line }

Rec ("=== dialog-catch start {0} interval={1}s minutes={2} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $IntervalSec, $Minutes)

$seen = @{}
$deadline = (Get-Date).AddMinutes($Minutes)
$GWL_STYLE = -16; $GWL_EXSTYLE = -20; $GW_OWNER = 4; $DWMWA_CLOAKED = 14
$WS_CAPTION = 0x00C00000; $WS_POPUP = 0x80000000; $WS_SYSMENU = 0x00080000; $WS_CHILD = 0x40000000
$WSEX_APPWINDOW = 0x00040000; $WSEX_TOOLWINDOW = 0x80; $WSEX_NOACTIVATE = 0x08000000
$WSEX_TOPMOST = 0x8; $WSEX_LAYERED = 0x00080000; $WSEX_TRANSPARENT = 0x20

while ((Get-Date) -lt $deadline) {
    $cb = [D.N+EnumWindowsProc]{
        param($h, $p)
        if (-not [D.N]::IsWindowVisible($h)) { return $true }
        $style = [int64][D.N]::GetWindowLongPtrW($h, $GWL_STYLE)
        if (($style -band $WS_CHILD) -eq $WS_CHILD) { return $true }

        $sb = New-Object System.Text.StringBuilder 512
        [void][D.N]::GetClassNameW($h, $sb, 512); $cls = $sb.ToString()
        $sb2 = New-Object System.Text.StringBuilder 512
        [void][D.N]::GetWindowTextW($h, $sb2, 512); $title = $sb2.ToString()

        $r = New-Object D.N+RECT; [void][D.N]::GetWindowRect($h, [ref]$r)
        # Key on identity + geometry: a dialog that moves or resizes is still the same arrival,
        # but a REUSED hwnd showing different content is a new event worth recording.
        $key = "$cls|$title|$($r.R-$r.L)x$($r.B-$r.T)"
        if ($seen.ContainsKey($key)) { return $true }
        $seen[$key] = 1

        $exstyle = [int64][D.N]::GetWindowLongPtrW($h, $GWL_EXSTYLE)
        $owner = [D.N]::GetWindow($h, $GW_OWNER)
        $cloaked = 0; [void][D.N]::DwmGetWindowAttribute($h, $DWMWA_CLOAKED, [ref]$cloaked, 4)
        $alpha = 255; $key2 = 0; $flags = 0
        if (($exstyle -band $WSEX_LAYERED) -eq $WSEX_LAYERED) {
            [void][D.N]::GetLayeredWindowAttributes($h, [ref]$key2, [ref]$alpha, [ref]$flags)
        }
        $procId = 0; [void][D.N]::GetWindowThreadProcessId($h, [ref]$procId)
        $pname = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { "pid$procId" }

        $hasCaption = (($style -band $WS_CAPTION) -eq $WS_CAPTION)
        $sysApp = ((($style -band $WS_SYSMENU) -eq $WS_SYSMENU) -and (($exstyle -band $WSEX_APPWINDOW) -eq $WSEX_APPWINDOW))
        # Exactly the verdict gui-agent's IsPopup() would reach today.
        $agentWouldOverrideRedirect = (-not ($hasCaption -or $sysApp))

        # NOTE the outer parentheses around the concatenation. PowerShell's -f binds TIGHTER
        # than +, so ("a" + "b" -f args) formats ONLY "b" and emits "a" with its {0} placeholders
        # intact - which is exactly what the first run printed. Measured, not theorised.
        Rec ((("{0} NEW proc={1} cls='{2}' title='{3}' rect={4},{5} {6}x{7} style=0x{8:X8} exstyle=0x{9:X8} " +
             "caption={10} sysmenu+appwindow={11} popupbit={12} toolwin={13} noactivate={14} topmost={15} " +
             "layered={16} transparent={17} alpha={18} cloaked={19} owner=0x{20:X} => AGENT_OR={21}") -f `
            (Get-Date -Format 'HH:mm:ss'), $pname, $cls, $title, $r.L, $r.T, ($r.R-$r.L), ($r.B-$r.T),
            $style, $exstyle, $hasCaption, $sysApp,
            ((($style -band $WS_POPUP) -eq $WS_POPUP)),
            ((($exstyle -band $WSEX_TOOLWINDOW) -eq $WSEX_TOOLWINDOW)),
            ((($exstyle -band $WSEX_NOACTIVATE) -eq $WSEX_NOACTIVATE)),
            ((($exstyle -band $WSEX_TOPMOST) -eq $WSEX_TOPMOST)),
            ((($exstyle -band $WSEX_LAYERED) -eq $WSEX_LAYERED)),
            ((($exstyle -band $WSEX_TRANSPARENT) -eq $WSEX_TRANSPARENT)),
            $alpha, $cloaked, [int64]$owner, $agentWouldOverrideRedirect))
        return $true
    }
    [void][D.N]::EnumWindows($cb, [IntPtr]::Zero)
    Start-Sleep -Seconds $IntervalSec
}
Rec "=== dialog-catch end ==="
