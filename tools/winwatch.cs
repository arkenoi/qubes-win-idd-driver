// winwatch - CONTINUOUS monitor for popup/override-redirect surfaces, and what the seamless
// agent will decide about each one. Companion to winenum.cs, which is a one-shot dump.
//
// WHY: complex apps (Office, Explorer) create transient companion HWNDs - menus, flyouts,
// shadow strips, task panes - that appear and vanish faster than a human can run a dumper.
// The interesting ones are exactly the ones you cannot catch by hand. Leave this running,
// drive the app, then read the log.
//
// It does NOT just list attributes. For every surface it evaluates the agent's OWN predicates
// and flags the cases that produce visible breakage:
//
//   DEMOTED  - style says popup (menu/flyout, no caption), but it is >= a screen dimension or
//              over 90% of the screen area, so IsPopup() forces it back to a MANAGED window.
//              dom0 then decorates a menu: border and title where none belongs. This is the
//              ugly failure mode; Office task panes and full-height flyouts are candidates.
//   NOSYNTH  - popup that cannot be composited into its owner because it is not contained
//              within the owner's rect (+SYNTH_OVERHANG_MAX). It becomes its own announced
//              window; measured cost on Edge's 3-dot menu was 46 FULL-window damage events/s.
//   SHADOW   - layered + transparent + noactivate, owned: the Office shadow-strip shape that
//              must be DROPPED (CLAUDE.md 2A-chrome). alpha=0 makes it near-certain.
//   CLOAKED  - DWM says cloaked while the window is visible: usually must not be mapped.
//   TOAST    - topmost + layered + owned by a shell process: must be KEPT (same attributes as
//              SHADOW, opposite desired outcome - that is the whole difficulty of the filter).
//
// C# 5, in-box Framework csc, no build infra - same approach as winenum.cs.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class WinWatch
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
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20, GW_OWNER = 4;
    const int DWMWA_CLOAKED = 14;
    const int SM_CXSCREEN = 0, SM_CYSCREEN = 1;
    const uint WS_POPUP = 0x80000000, WS_CHILD = 0x40000000;
    const uint WS_CAPTION = 0x00C00000, WS_SYSMENU = 0x00080000;
    const uint EX_TOPMOST = 0x8, EX_TRANSPARENT = 0x20, EX_TOOLWINDOW = 0x80,
               EX_LAYERED = 0x80000, EX_NOACTIVATE = 0x8000000, EX_APPWINDOW = 0x40000;
    const uint LWA_ALPHA = 2;

    // agent constants, mirrored (main.c): synthesis overhang, and the daemon's 90% rule
    const int SYNTH_OVERHANG_MAX = 12;
    const long OVERRIDE_MAX_PCT = 90;

    static int scrW, scrH;
    static TextWriter log;

    class Info
    {
        public string Line;      // the emitted description
        public string Verdict;   // flags, for change detection
    }

    static string S(IntPtr h, int max, bool cls)
    {
        StringBuilder sb = new StringBuilder(max);
        if (cls) GetClassName(h, sb, max); else GetWindowTextW(h, sb, max);
        return sb.ToString().Replace("|", "/");
    }

    // Mirror of the agent's IsPopup() (main.c). Returns the popup verdict and, when a size
    // guard overrode a style-popup, why - because THAT is the case that renders wrongly.
    static bool IsPopup(uint style, uint ex, int w, int h, out string demoteReason)
    {
        demoteReason = null;
        // ALL-bits semantics, matching the agent's HasFlags(v,f) == ((v & f) == f). Using
        // any-bit here made a plain WS_BORDER menu (#32768, style 0x94800000) look like it had
        // a caption, so the tool reported ovr=0 for a window the agent correctly maps
        // override-redirect. WS_CAPTION is WS_BORDER|WS_DLGFRAME - both are required.
        bool isPopup = !(((style & WS_CAPTION) == WS_CAPTION) ||
                         (((style & WS_SYSMENU) == WS_SYSMENU) && ((ex & EX_APPWINDOW) == EX_APPWINDOW)));
        if (!isPopup) return false;
        if (scrW > 0 && scrH > 0)
        {
            if (w >= scrW || h >= scrH)
            {
                demoteReason = "ge-screen-dim";
                return false;
            }
            if ((long)w * h * 100L > (long)scrW * scrH * OVERRIDE_MAX_PCT)
            {
                demoteReason = "over-90pct";
                return false;
            }
        }
        return true;
    }

    static bool Contained(RECT c, RECT o)
    {
        return c.L >= o.L - SYNTH_OVERHANG_MAX && c.T >= o.T - SYNTH_OVERHANG_MAX &&
               c.R <= o.R + SYNTH_OVERHANG_MAX && c.B <= o.B + SYNTH_OVERHANG_MAX;
    }

    static Dictionary<long, Info> seen = new Dictionary<long, Info>();
    static Dictionary<long, Info> pass;

    static bool Cb(IntPtr h, IntPtr p)
    {
        uint style = (uint)GetWindowLong(h, GWL_STYLE);
        uint ex = (uint)GetWindowLong(h, GWL_EXSTYLE);
        if ((style & WS_CHILD) != 0) return true;
        if (!IsWindowVisible(h)) return true;

        RECT r; GetWindowRect(h, out r);
        int w = r.R - r.L, hh = r.B - r.T;
        if (w <= 0 || hh <= 0) return true;

        uint pid; GetWindowThreadProcessId(h, out pid);
        int cloaked = 0; try { DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4); } catch { }
        IntPtr owner = GetWindow(h, GW_OWNER);
        string alpha = "-";
        if ((ex & EX_LAYERED) != 0)
        {
            uint key, fl; byte a;
            if (GetLayeredWindowAttributes(h, out key, out a, out fl) && (fl & LWA_ALPHA) != 0)
                alpha = a.ToString(CultureInfo.InvariantCulture);
            else alpha = "ulw";
        }

        string demote;
        bool popup = IsPopup(style, ex, w, hh, out demote);

        // synthesis containment against the owner
        string synth = "-";
        if (owner != IntPtr.Zero)
        {
            RECT orc;
            if (GetWindowRect(owner, out orc))
                synth = Contained(r, orc) ? "yes" : "NO";
        }

        StringBuilder f = new StringBuilder();
        if (demote != null) f.Append("DEMOTED(" + demote + ") ");
        if (popup && synth == "NO") f.Append("NOSYNTH ");
        if ((ex & EX_LAYERED) != 0 && (ex & EX_TRANSPARENT) != 0 &&
            (ex & EX_NOACTIVATE) != 0 && owner != IntPtr.Zero) f.Append("SHADOW ");
        if (alpha == "0") f.Append("ALPHA0 ");
        if (cloaked != 0) f.Append("CLOAKED ");
        if ((ex & EX_TOPMOST) != 0 && (ex & EX_LAYERED) != 0 && owner != IntPtr.Zero) f.Append("TOAST? ");
        string verdict = f.ToString().TrimEnd();

        StringBuilder g = new StringBuilder();
        if ((style & WS_POPUP) != 0) g.Append("POPUP ");
        if ((ex & EX_TOPMOST) != 0) g.Append("TOPMOST ");
        if ((ex & EX_LAYERED) != 0) g.Append("LAYERED ");
        if ((ex & EX_TRANSPARENT) != 0) g.Append("TRANSPARENT ");
        if ((ex & EX_TOOLWINDOW) != 0) g.Append("TOOLWIN ");
        if ((ex & EX_NOACTIVATE) != 0) g.Append("NOACTIVATE ");
        if ((ex & EX_APPWINDOW) != 0) g.Append("APPWIN ");

        string line = string.Format(CultureInfo.InvariantCulture,
            "0x{0:X8}|pid={1}|cls={2}|ovr={3}|synth={4}|rect={5},{6} {7}x{8}|owner=0x{9:X8}|alpha={10}|cloaked={11}|styleflags={12}|style=0x{13:X8}|ex=0x{14:X8}|title={15}",
            h.ToInt64(), pid, S(h, 64, true), popup ? 1 : 0, synth,
            r.L, r.T, w, hh, owner.ToInt64(), alpha, cloaked,
            g.ToString().TrimEnd(), style, ex, S(h, 96, false));

        Info info = new Info();
        info.Line = line;
        info.Verdict = verdict + "|" + w + "x" + hh + "|" + (popup ? 1 : 0) + "|" + synth;
        pass[h.ToInt64()] = info;
        return true;
    }

    static void Emit(string kind, string verdict, string line)
    {
        string stamp = DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture);
        string s = stamp + " " + kind + " " + (verdict.Length > 0 ? "[" + verdict + "] " : "") + line;
        Console.WriteLine(s);
        if (log != null) { log.WriteLine(s); log.Flush(); }
    }

    static void Main(string[] argv)
    {
        int seconds = 600;
        string path = @"C:\winwatch.log";
        if (argv.Length > 0) int.TryParse(argv[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds);
        if (argv.Length > 1) path = argv[1];

        scrW = GetSystemMetrics(SM_CXSCREEN);
        scrH = GetSystemMetrics(SM_CYSCREEN);
        log = new StreamWriter(path, true);
        Emit("#", "", "winwatch start screen=" + scrW + "x" + scrH +
                      " overhang=" + SYNTH_OVERHANG_MAX + " maxpct=" + OVERRIDE_MAX_PCT +
                      " | ovr=1 means the agent maps it override-redirect (borderless);" +
                      " DEMOTED means a menu-shaped window gets DECORATED by dom0");

        DateTime end = DateTime.Now.AddSeconds(seconds);
        bool first = true;
        while (DateTime.Now < end)
        {
            pass = new Dictionary<long, Info>();
            EnumWindows(Cb, IntPtr.Zero);

            foreach (KeyValuePair<long, Info> kv in pass)
            {
                Info old;
                if (!seen.TryGetValue(kv.Key, out old))
                {
                    // Suppress the initial inventory as "new" noise, but keep anything flagged.
                    if (!first || kv.Value.Verdict.Split('|')[0].Length > 0)
                        Emit(first ? "=" : "+", kv.Value.Verdict.Split('|')[0], kv.Value.Line);
                }
                else if (old.Verdict != kv.Value.Verdict)
                {
                    Emit("~", kv.Value.Verdict.Split('|')[0], kv.Value.Line);
                }
            }
            foreach (KeyValuePair<long, Info> kv in seen)
                if (!pass.ContainsKey(kv.Key))
                    Emit("-", "", kv.Value.Line);

            seen = pass;
            first = false;
            System.Threading.Thread.Sleep(100);
        }
        Emit("#", "", "winwatch end");
        log.Close();
    }
}
