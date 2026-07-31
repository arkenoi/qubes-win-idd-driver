# Ground truth: what Windows ACTUALLY has on screen, captured inside the guest.
# Compare against dom0's local.WinScreenshot to see what the agent/daemon delivered.
param([string]$Out = 'C:\Windows\Temp\guestshot.png', [string]$Window = '')
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public class G {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  public struct RC { public int L,T,R,B; }
}
"@
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("SAVED=" + $Out + " " + $b.Width + "x" + $b.Height)
