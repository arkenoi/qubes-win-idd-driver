# FULLSCREEN-GATE PROBE — creates ONE window with exactly-specified styles at exactly the guest
# screen size, reports its own attributes, holds it, then destroys it.
#
# WHY A DEDICATED PROBE. SG2/SG3/SG4 all turn on the agent's `ShouldAcceptWindow` decision for a
# window that is >= ~99% of the GUEST screen, and the decision keys on `WS_CAPTION` and on
# override-redirect classification. Driving that with Notepad or a WinForms form does not work:
# neither lets you state the styles, and a WinForms borderless form is not the same window a game
# creates. Worse, "nothing appeared in dom0" is only a safeguard PASS if the surface provably
# EXISTED - otherwise the cell is INVALID-VACUOUS. So this probe prints the HWND, the styles and
# exstyles it actually got (read back with GetWindowLong, not assumed from what was requested), the
# rect, and the screen size it was sized against. That block IS the vacuity proof.
#
#   fsgate-probe.ps1 -Mode borderless        # SG2: fullscreen, NO WS_CAPTION -> must NOT map
#   fsgate-probe.ps1 -Mode overrideredirect  # SG4: fullscreen o-r          -> must NOT map, ever
#   fsgate-probe.ps1 -Mode captioned         # SG3: fullscreen WITH caption -> MUST map
#
# CONTAINMENT IS A PRECONDITION, NOT AN OPTION. -Mode captioned deliberately puts a window the size
# of the whole guest screen onto the owner's display. Run P5-3 first: on 2026-08-30 an SG3 arm
# opened at 5088x1368 and took the owner's keyboard focus mid-session. This script therefore
# REFUSES to run if the guest screen is not smaller than the host screen it is told about.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('borderless','overrideredirect','captioned')][string]$Mode,
    [int]$HoldSeconds = 30,
    [int]$HostWidth = 0,          # if given, refuse when the guest screen is not strictly smaller
    [int]$HostHeight = 0,
    # Explicit size instead of "the whole guest screen". Used to bisect where a window stops being
    # visible to dom0: measured 2026-08-30, a 1586x893 window on a 1600x900 guest is MAPPED by the
    # agent (CREATE+MAP, ovr=0) yet never appears in dom0's _NET_CLIENT_LIST, while a 1176x600
    # notepad in the same shot does.
    [int]$Width = 0,
    [int]$Height = 0,
    # Write this script's own output here. WHY: launching it as
    # `cmd /c start "" cmd /c "powershell ... > file"` gave the redirection a CONSOLE WINDOW, and
    # that console (979x512) is itself mapped by the agent. The P5 harness counted it and reported
    # "2 windows vs control 1 - a screen-sized window reached dom0" for SG2 and SG4 - a FAIL
    # manufactured entirely by the launcher, while the 1024x768 probe had in fact been denied
    # correctly. Writing our own file lets the launcher use `powershell -WindowStyle Hidden` with
    # no shell redirection and therefore no extra window.
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'

$script:OutLines = @()
function Emit($t) { $script:OutLines += $t; Write-Output $t
    if ($OutFile) { $script:OutLines | Out-File -FilePath $OutFile -Encoding ASCII } }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class FsGate {
    public delegate IntPtr WndProcDel(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASS {
        public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int ptX; public int ptY;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(
        uint ex, string cls, string name, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PeekMessageW(out MSG m, IntPtr h, uint a, uint b, uint f);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(int color);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);

    const uint WS_POPUP = 0x80000000, WS_VISIBLE = 0x10000000, WS_OVERLAPPEDWINDOW = 0x00CF0000;
    const uint WS_SYSMENU = 0x00080000;
    const uint WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x00000008;
    const uint WS_EX_APPWINDOW = 0x00040000;

    static WndProcDel _keepAlive;   // the delegate MUST outlive the window or the pump faults
    public static IntPtr Hwnd = IntPtr.Zero;

    public static IntPtr Create(string mode, int w, int h) {
        string cls = "QwtFsGate_" + mode + "_" + Environment.TickCount;
        _keepAlive = new WndProcDel(DefWindowProcW);
        WNDCLASS c = new WNDCLASS();
        c.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_keepAlive);
        c.hInstance = GetModuleHandleW(null);
        c.hbrBackground = CreateSolidBrush(0x002020C0);   // solid red-ish: obvious in a screenshot
        c.lpszClassName = cls;
        if (RegisterClassW(ref c) == 0)
            throw new Exception("RegisterClassW failed: " + Marshal.GetLastWin32Error());

        uint style, ex;
        if (mode == "captioned") {
            // A maximized-style normal app window: has WS_CAPTION, so the gate must ALWAYS allow it.
            style = WS_OVERLAPPEDWINDOW | WS_VISIBLE; ex = 0;
        } else if (mode == "overrideredirect") {
            // Toolwindow + noactivate + topmost, caption-less: the agent classifies caption-less
            // WS_POPUP as override-redirect. Fullscreen + o-r is refused UNCONDITIONALLY.
            style = WS_POPUP | WS_VISIBLE; ex = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
        } else {
            // Borderless true-fullscreen: what a game/video player creates. Gated on the feature.
            //
            // WS_SYSMENU + WS_EX_APPWINDOW ARE LOAD-BEARING, not decoration. IsPopup()
            // (main.c:1221) classifies ANY caption-less window as override-redirect unless it
            // carries WS_EX_APPWINDOW (alone, or paired with WS_SYSMENU). Without those bits this
            // probe would be classified override-redirect and denied by the MODE 1 branch
            // ("unconditionally denied, feature or not") - so the cell would report a pass while
            // never once reaching the Mode 2 borderless gate it exists to exercise. A real
            // borderless-fullscreen app does ask for a taskbar button, which is why this is also
            // the honest shape of the thing being gated.
            style = WS_POPUP | WS_SYSMENU | WS_VISIBLE; ex = WS_EX_APPWINDOW;
        }
        Hwnd = CreateWindowExW(ex, cls, "QWT fullscreen gate probe", style, 0, 0, w, h,
                               IntPtr.Zero, IntPtr.Zero, GetModuleHandleW(null), IntPtr.Zero);
        if (Hwnd == IntPtr.Zero)
            throw new Exception("CreateWindowExW failed: " + Marshal.GetLastWin32Error());
        ShowWindow(Hwnd, mode == "overrideredirect" ? 4 /*SW_SHOWNOACTIVATE*/ : 5 /*SW_SHOW*/);
        UpdateWindow(Hwnd);
        return Hwnd;
    }
    public static void Pump(int seconds) {
        MSG m; int end = Environment.TickCount + seconds * 1000;
        while (Environment.TickCount < end) {
            while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); }
            Thread.Sleep(20);
        }
    }
    public static void Destroy() { if (Hwnd != IntPtr.Zero) { DestroyWindow(Hwnd); Hwnd = IntPtr.Zero; } }
}
'@

$sw = [FsGate]::GetSystemMetrics(0); $sh = [FsGate]::GetSystemMetrics(1)

# --- containment gate ---------------------------------------------------------------------------
if ($HostWidth -gt 0 -and $HostHeight -gt 0) {
    if (-not ($sw -lt $HostWidth -and $sh -lt $HostHeight)) {
        Emit '=== RESULT ==='
        Emit ((@{ ok = $false; error = 'containment_absent'
           guest_screen = "${sw}x${sh}"; host_screen = "${HostWidth}x${HostHeight}"
           note = 'guest screen is not strictly smaller than the host - refusing to open a screen-sized window on the owner display (P5-3)' } | ConvertTo-Json -Compress))
        exit 3
    }
}

$pw = if ($Width  -gt 0) { $Width }  else { $sw }
$ph = if ($Height -gt 0) { $Height } else { $sh }
$h = [FsGate]::Create($Mode, $pw, $ph)
$style = [FsGate]::GetWindowLong($h, -16)      # GWL_STYLE
$ex    = [FsGate]::GetWindowLong($h, -20)      # GWL_EXSTYLE
$r = New-Object FsGate+RECT
[void][FsGate]::GetWindowRect($h, [ref]$r)
$vis = [FsGate]::IsWindowVisible($h)
$WS_CAPTION = 0x00C00000

# This block is the VACUITY PROOF: it shows the surface existed, was visible, carried the styles the
# cell is about, and covered the guest screen. Without it "nothing mapped" grades nothing.
Emit '=== PROBE ==='
Emit ((@{ mode = $Mode
   hwnd = ('0x{0:X}' -f $h.ToInt64())
   style = ('0x{0:X8}' -f $style); exstyle = ('0x{0:X8}' -f $ex)
   has_caption = (($style -band $WS_CAPTION) -ne 0)
   visible = [bool]$vis
   rect = "$($r.L),$($r.T) $($r.R - $r.L)x$($r.B - $r.T)"
   guest_screen = "${sw}x${sh}"
   covers_screen = (($r.R - $r.L) -ge [int]($sw * 0.99) -and ($r.B - $r.T) -ge [int]($sh * 0.99))
   hold_seconds = $HoldSeconds } | ConvertTo-Json -Compress))

[FsGate]::Pump($HoldSeconds)
[FsGate]::Destroy()
Emit '=== RESULT ==='
Emit ((@{ ok = $true; mode = $Mode; destroyed = $true } | ConvertTo-Json -Compress))
