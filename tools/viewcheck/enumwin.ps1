Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public class E {
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  public struct R { public int L,T,Rt,B; }
}
"@
$out = New-Object System.Collections.ArrayList
$cb = [E+CB]{ param($h,$l)
  if (-not [E]::IsWindowVisible($h)) { return $true }
  $r = New-Object E+R
  if (-not [E]::GetWindowRect($h,[ref]$r)) { return $true }
  $w = $r.Rt - $r.L; $ht = $r.B - $r.T
  if ($w -lt 40 -or $ht -lt 40) { return $true }
  $t = New-Object System.Text.StringBuilder 256; [E]::GetWindowText($h,$t,256) | Out-Null
  $c = New-Object System.Text.StringBuilder 256; [E]::GetClassName($h,$c,256) | Out-Null
  [void]$out.Add([pscustomobject]@{ hwnd=("0x{0:X}" -f $h.ToInt64()); title=$t.ToString(); cls=$c.ToString(); x=$r.L; y=$r.T; w=$w; h=$ht })
  return $true }
[E]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
Write-Output 'JSONSTART'
$out | ConvertTo-Json -Compress
Write-Output 'JSONEND'
