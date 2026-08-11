# render-watch.ps1 — resident guest-truth sampler that does NOT disturb what it measures.
#
# WHY THIS EXISTS. guest/render-truth.ps1 is run on demand over qrexec, and launching a process that
# way STEALS FOCUS: it closes the Start menu and dismisses transient popups. Measured 2026-08-11 —
# and it produced a wrong conclusion (a "ghost window" that was really just a menu my own query had
# closed, retracted the same day). Any guest-truth reading of a focus-sensitive surface taken by a
# fresh qrexec process is untrustworthy by construction.
#
# The fix is to decouple SAMPLING from RETRIEVAL. This script is started ONCE (that start may steal
# focus - it happens before the scene is set up, so it does not matter), then runs hidden and
# detached, writing a timestamped sample every -IntervalSec into -OutDir. Later, a qrexec call
# fetches the samples: by then the interesting sample is already on disk, and the focus theft caused
# by fetching cannot retroactively change it. Pair a dom0 `qtest fullshot` with the sample whose
# timestamp is nearest - which is only meaningful with the clocks synced, so run `qtest synctime`
# after every VM start (the guest RTC is re-derived from dom0 LOCAL time at each domain start).
#
# Samples are metadata only by default: a full-desktop PNG every 2 s would be far more disturbance
# (and disk) than the question is worth. -WithImage adds one.
[CmdletBinding()]
param(
    [int]$IntervalSec = 2,
    [int]$Keep = 60,
    [string]$OutDir = 'C:\ProgramData\Qubes\rendertruth',
    [switch]$WithImage,
    [int]$MaxMinutes = 60
)

$ErrorActionPreference = 'Stop'
# System.Windows.Forms is deliberately NOT loaded: loading it creates a message window on this
# thread, and a thread that owns a window can no longer SetThreadDesktop (measured 2026-08-11:
# "SetThreadDesktop failed"). The virtual-screen metrics it would have provided come from
# GetSystemMetrics below instead. System.Drawing is loaded lazily, only for -WithImage.

# CharSet=Unicode is REQUIRED: with default (Ansi) marshalling the W entry points get a UTF-16
# buffer read as ANSI and every title comes back as its first character only.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RW {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // The enumeration MUST run on a thread that owns no windows, because SetThreadDesktop fails
    // for any thread that does - and PowerShell's own host thread always owns one (measured
    // 2026-08-11: "SetThreadDesktop failed" even with System.Windows.Forms unloaded). A fresh
    // thread is the only way to see the same desktop the gui-agent attaches to, and therefore the
    // same window set it announces to dom0.
    public static string DesktopWarning = "";

    public static string SampleJson() {
        string result = "[]";
        System.Threading.Thread t = new System.Threading.Thread(delegate() {
            IntPtr desk = OpenInputDesktop(0, false, 0x0041);
            if (desk == IntPtr.Zero) { DesktopWarning = "OpenInputDesktop failed"; }
            else if (!SetThreadDesktop(desk)) { DesktopWarning = "SetThreadDesktop failed"; }
            else { DesktopWarning = ""; }

            IntPtr fg = GetForegroundWindow();
            StringBuilder json = new StringBuilder("[");
            bool first = true;
            EnumWindows(delegate(IntPtr h, IntPtr p) {
                if (!IsWindowVisible(h)) return true;
                RECT raw; GetWindowRect(h, out raw);
                RECT dwm;
                if (DwmGetWindowAttribute(h, 9, out dwm, Marshal.SizeOf(typeof(RECT))) != 0) dwm = raw;
                int w = dwm.Right - dwm.Left, ht = dwm.Bottom - dwm.Top;
                if (w <= 0 || ht <= 0) return true;
                StringBuilder tb = new StringBuilder(512); GetWindowTextW(h, tb, 512);
                StringBuilder cb2 = new StringBuilder(256); GetClassNameW(h, cb2, 256);
                int cloaked = 0; DwmGetWindowAttribute(h, 14, out cloaked, 4);
                if (!first) json.Append(",");
                first = false;
                json.AppendFormat(System.Globalization.CultureInfo.InvariantCulture,
                    "{{\"hwnd\":\"0x{0:x}\",\"title\":{1},\"class\":{2},\"x\":{3},\"y\":{4},\"w\":{5},\"h\":{6},"
                    + "\"rawx\":{7},\"rawy\":{8},\"raww\":{9},\"rawh\":{10},\"style\":\"0x{11:x8}\",\"exstyle\":\"0x{12:x8}\","
                    + "\"cloaked\":{13},\"owner\":\"0x{14:x}\",\"foreground\":{15}}}",
                    h.ToInt64(), Quote(tb.ToString()), Quote(cb2.ToString()),
                    dwm.Left, dwm.Top, w, ht,
                    raw.Left, raw.Top, raw.Right - raw.Left, raw.Bottom - raw.Top,
                    GetWindowLongPtr(h, -16).ToInt64(), GetWindowLongPtr(h, -20).ToInt64(),
                    cloaked, GetWindow(h, 4).ToInt64(), (h == fg) ? "true" : "false");
                return true;
            }, IntPtr.Zero);
            json.Append("]");
            result = json.ToString();
            if (desk != IntPtr.Zero) CloseDesktop(desk);
        });
        t.SetApartmentState(System.Threading.ApartmentState.STA);
        t.Start();
        t.Join();
        return result;
    }

    static string Quote(string s) {
        StringBuilder o = new StringBuilder("\"");
        foreach (char c in s) {
            if (c == '"' || c == '\\') { o.Append('\\').Append(c); }
            else if (c < 0x20) { o.AppendFormat("\\u{0:x4}", (int)c); }
            else o.Append(c);
        }
        return o.Append("\"").ToString();
    }
}
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# SM_XVIRTUALSCREEN=76 SM_YVIRTUALSCREEN=77 SM_CXVIRTUALSCREEN=78 SM_CYVIRTUALSCREEN=79
$screen = [pscustomobject]@{
    X = [RW]::GetSystemMetrics(76); Y = [RW]::GetSystemMetrics(77)
    Width = [RW]::GetSystemMetrics(78); Height = [RW]::GetSystemMetrics(79)
}
$deadline = (Get-Date).AddMinutes($MaxMinutes)

while ((Get-Date) -lt $deadline) {
    # All enumeration happens inside RW.SampleJson(), on a windowless thread attached to the input
    # desktop - see the comment on that method. It returns finished JSON, so nothing here can
    # re-order or lose fields.
    $winsJson = [RW]::SampleJson()

    $now = Get-Date
    $stamp = $now.ToString('yyyyMMdd-HHmmss-fff')
    $sample = [pscustomobject]@{
        ts = $now.ToUniversalTime().ToString('o')
        ts_local = $now.ToString('o')
        desktop_warning = [RW]::DesktopWarning
        screen = @{ x = $screen.X; y = $screen.Y; w = $screen.Width; h = $screen.Height }
    }
    # windows is spliced in as raw JSON rather than re-serialised: ConvertTo-Json would have to
    # round-trip it through objects, and that is where field loss and type drift creep in.
    $head = ($sample | ConvertTo-Json -Depth 3 -Compress)
    $doc = $head.Substring(0, $head.Length - 1) + ',"windows":' + $winsJson + '}'
    $doc | Set-Content -Path (Join-Path $OutDir "s-$stamp.json") -Encoding UTF8

    if ($WithImage) {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($screen.X, $screen.Y, 0, 0, $bmp.Size)
        $g.Dispose()
        $bmp.Save((Join-Path $OutDir "s-$stamp.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }

    # Bounded ring: this runs unattended for up to an hour, and filling the guest disk would be a
    # worse bug than the one it is here to catch.
    Get-ChildItem $OutDir -Filter 's-*.json' | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem $OutDir -Filter 's-*.png'  | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force -EA SilentlyContinue

    Start-Sleep -Seconds $IntervalSec
}
