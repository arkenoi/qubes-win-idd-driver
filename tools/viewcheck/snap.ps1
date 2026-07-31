# Capture the guest screen AND the window geometry in ONE call, so the two cannot skew.
# Running the screenshot and the enumeration as separate qrexec calls puts seconds between
# them; any window that moves in between makes every later comparison read as a rendering
# defect when the content is in fact pixel-exact. Emit geometry first, then the PNG, with the
# enumeration bracketing the capture so a window that moves mid-call is detectable.
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class E {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb c, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out R r, int s);
  public struct R { public int l,t,r,b; }
  public static List<string> Go() {
    var o = new List<string>();
    EnumWindows((h,l) => {
      if (!IsWindowVisible(h)) return true;
      R r; if (!GetWindowRect(h, out r)) return true;
      int w = r.r-r.l, ht = r.b-r.t;
      if (w < 8 || ht < 8) return true;
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      R e; if (DwmGetWindowAttribute(h, 9, out e, 16) != 0) { e = r; }   // DWMWA_EXTENDED_FRAME_BOUNDS
      o.Add(string.Format("{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}\t{7}\t{8}\t{9}\t{10}\t{11}",
        h.ToInt64(), r.l, r.t, w, ht, GetWindowLong(h,-20), t.ToString().Replace("\t"," "), c.ToString(),
        e.l, e.t, e.r-e.l, e.b-e.t));
      return true;
    }, IntPtr.Zero);
    return o;
  }
}
"@
function Emit($tag, $rows) {
  Write-Output "${tag}START"
  foreach ($r in $rows) { Write-Output $r }
  Write-Output "${tag}END"
}
$pre = [E]::Go()
$b = New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width, [System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
Add-Type -AssemblyName System.Windows.Forms
$b = New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width, [System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
$g = [System.Drawing.Graphics]::FromImage($b)
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $b.Size)
$post = [E]::Go()
$ms = New-Object System.IO.MemoryStream
$b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
Emit 'GEOPRE'  $pre
Emit 'GEOPOST' $post
Write-Output 'B64START'
Write-Output ([Convert]::ToBase64String($ms.ToArray()))
Write-Output 'B64END'
