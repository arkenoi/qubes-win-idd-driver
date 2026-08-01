# High-rate window recorder, loop fully inside C# (PowerShell delegate marshaling of
# EnumWindows callbacks proved unreliable under -NonInteractive). Writes to a file.
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class R {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
    public struct RECT { public int L, T, R, B; }
    static HashSet<string> seen = new HashSet<string>();
    static List<string> hits = new List<string>();
    static bool Cb(IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h)) return true;
        RECT r; if (!GetWindowRect(h, out r)) return true;
        int w = r.R - r.L, ht = r.B - r.T;
        if (w <= 0 || ht <= 0) return true;
        var cls = new StringBuilder(256); GetClassName(h, cls, 256);
        var cap = new StringBuilder(256); GetWindowTextW(h, cap, 256);
        int st = GetWindowLong(h, -16), ex = GetWindowLong(h, -20);
        int cloaked = 0; DwmGetWindowAttribute(h, 14, out cloaked, 4);
        uint pid; GetWindowThreadProcessId(h, out pid);
        string key = h.ToInt64() + "|" + cls + "|" + r.L + "," + r.T + "|" + w + "x" + ht + "|" + ex + "|" + cloaked;
        if (seen.Add(key))
            hits.Add(string.Format("{0:HH:mm:ss.fff} hwnd=0x{1:x} pid={2} cls=\"{3}\" cap=\"{4}\" at({5},{6}) {7}x{8} style=0x{9:x} ex=0x{10:x} cloaked={11}",
                DateTime.Now, h.ToInt64(), pid, cls, cap, r.L, r.T, w, ht, st, ex, cloaked));
        return true;
    }
    public static int Record(int seconds, string path) {
        EnumProc cb = new EnumProc(Cb);
        DateTime t0 = DateTime.Now;
        while ((DateTime.Now - t0).TotalSeconds < seconds) {
            EnumWindows(cb, IntPtr.Zero);
            System.Threading.Thread.Sleep(120);
        }
        File.WriteAllLines(path, hits.ToArray());
        return hits.Count;
    }
}
"@
$out = 'C:\Users\user\dragrec.txt'
Write-Output "RECORDING_START $((Get-Date).ToString('HH:mm:ss')) -> $out"
$n = [R]::Record(35, $out)
Write-Output "SAMPLES=$n"
Write-Output 'DRAGREC_DONE'
