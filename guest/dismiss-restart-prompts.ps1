# Answer the driver installers' "restart to complete installation" modal, in the background,
# for the duration of the payload install.
#
# WHY. Stock QWT's PV driver install shows:
#   "Xen PV Storage Host Adapter needs to restart the system to complete installation.
#    Press 'Yes' to restart the system now or 'No' if you plan to restart the system later."
# It is MODAL and it blocks the rest of firstboot. Worse, qrexec does not answer while it is
# up - the guest is unreachable, so it cannot be clicked from outside. A run hits it and simply
# stops, and the only way out is destroying the domain from dom0.
#
# Answers NO, deliberately. "Yes" would reboot mid-payload, before the remaining install steps
# run. "No" defers, the payload completes, and the harness reboots on its own terms afterwards -
# which is what it already does.
#
# Runs for a bounded time and exits, so it cannot linger and swallow a dialog a human wanted.
[CmdletBinding()]
param([int]$Minutes = 45)

Add-Type @"
using System;using System.Runtime.InteropServices;using System.Text;
public class DR {
  public delegate bool Cb(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowExW(IntPtr p, IntPtr c, string cls, string win);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@

$deadline = (Get-Date).AddMinutes($Minutes)
$hit = 0
while ((Get-Date) -lt $deadline) {
    $dialogs = New-Object System.Collections.ArrayList
    $cb = [DR+Cb]{ param($h,$p)
        if ([DR]::IsWindowVisible($h)) {
            $c = New-Object System.Text.StringBuilder 64
            [void][DR]::GetClassNameW($h,$c,64)
            if ($c.ToString() -eq '#32770') {
                $t = New-Object System.Text.StringBuilder 512
                [void][DR]::GetWindowTextW($h,$t,512)
                [void]$dialogs.Add(@{ h = $h; title = $t.ToString() })
            }
        }
        return $true }
    [void][DR]::EnumWindows($cb, [IntPtr]::Zero)

    foreach ($d in $dialogs) {
        # IDNO = 7. WM_COMMAND = 0x0111.
        [void][DR]::SendMessageW($d.h, 0x0111, [IntPtr]7, [IntPtr]::Zero)
        $hit++
        Write-Output ("DISMISSED '" + $d.title + "' at " + (Get-Date -Format HH:mm:ss))
    }
    Start-Sleep -Seconds 2
}
Write-Output ("=== RESULT === dismissed=$hit minutes=$Minutes")
