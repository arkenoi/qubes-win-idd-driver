// winenum - dump every top-level window with the attributes the seamless agent's
// window-acceptance predicate turns on (CLAUDE.md Track A / 2A-chrome step 3b/3c).
//
// WHY: the Win11 25H2 "Start menu paints partially / shutdown button unreachable" and the
// "double windows" artifacts are companion HWNDs the agent maps wrongly - topmost + layered +
// frequently DWM-cloaked shell surfaces. To extend the filter correctly we must see the exact
// distinguishing attributes WHILE the broken window is on screen. Run this then, paste output.
// Same tool classifies the Office shadow-strip (must DROP) vs toast/menu (must KEEP) cases.
//
// Output: one line per top-level HWND - handle, pid, class, WS_*/WS_EX_* of interest, DWM
// cloaked state, owner, rect, visible/iconic, layered alpha (if WS_EX_LAYERED). Header first.
//
// C# 5 (compiles with the in-box Framework csc; no build infra) - matches the on-guest-compile
// approach used for qubes-updates-relay. CI can also build it into tools packaging.
using System;
using System.Runtime.InteropServices;
using System.Text;

static class WinEnum
{
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20, GW_OWNER = 4;
    const int DWMWA_CLOAKED = 14;
    const uint WS_POPUP = 0x80000000, WS_VISIBLE = 0x10000000, WS_MINIMIZE = 0x20000000, WS_CHILD = 0x40000000;
    const uint EX_TOPMOST = 0x8, EX_TRANSPARENT = 0x20, EX_TOOLWINDOW = 0x80, EX_LAYERED = 0x80000, EX_NOACTIVATE = 0x8000000, EX_APPWINDOW = 0x40000;
    const uint LWA_ALPHA = 2;

    static string S(IntPtr h, int max, bool cls)
    {
        StringBuilder sb = new StringBuilder(max);
        if (cls) GetClassName(h, sb, max); else GetWindowTextW(h, sb, max);
        return sb.ToString().Replace("|", "/");
    }

    static bool Cb(IntPtr h, IntPtr p)
    {
        uint style = (uint)GetWindowLong(h, GWL_STYLE);
        uint ex = (uint)GetWindowLong(h, GWL_EXSTYLE);
        if ((style & WS_CHILD) != 0) return true;   // top-level only, like the agent's set

        uint pid; GetWindowThreadProcessId(h, out pid);
        int cloaked = 0; try { DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4); } catch { }
        IntPtr owner = GetWindow(h, GW_OWNER);
        RECT r; GetWindowRect(h, out r);
        string alpha = "-";
        if ((ex & EX_LAYERED) != 0)
        {
            uint key, fl; byte a;
            if (GetLayeredWindowAttributes(h, out key, out a, out fl) && (fl & LWA_ALPHA) != 0) alpha = a.ToString();
            else alpha = "ulw"; // UpdateLayeredWindow surface - no queryable alpha
        }

        StringBuilder f = new StringBuilder();
        if ((style & WS_POPUP) != 0) f.Append("POPUP ");
        if ((ex & EX_TOPMOST) != 0) f.Append("TOPMOST ");
        if ((ex & EX_LAYERED) != 0) f.Append("LAYERED ");
        if ((ex & EX_TRANSPARENT) != 0) f.Append("TRANSPARENT ");
        if ((ex & EX_TOOLWINDOW) != 0) f.Append("TOOLWIN ");
        if ((ex & EX_NOACTIVATE) != 0) f.Append("NOACTIVATE ");
        if ((ex & EX_APPWINDOW) != 0) f.Append("APPWIN ");

        Console.WriteLine(string.Format(
            "0x{0:X8}|pid={1}|cls={2}|vis={3}|icon={4}|cloaked={5}|owner=0x{6:X8}|alpha={7}|flags={8}|style=0x{9:X8}|ex=0x{10:X8}|rect={11},{12},{13},{14}|title={15}",
            h.ToInt64(), pid, S(h, 96, true),
            IsWindowVisible(h) ? 1 : 0, IsIconic(h) ? 1 : 0, cloaked,
            owner.ToInt64(), alpha, f.ToString().TrimEnd(),
            style, ex, r.L, r.T, r.R, r.B, S(h, 128, false)));
        return true;
    }

    static void Main()
    {
        Console.OutputEncoding = Encoding.UTF8;
        Console.WriteLine("# winenum: top-level windows. cloaked: 0=not, 1=app,2=shell,4=inherited. " +
                          "Run WHILE the broken window is on screen. Fields pipe-delimited.");
        EnumWindows(Cb, IntPtr.Zero);
    }
}
