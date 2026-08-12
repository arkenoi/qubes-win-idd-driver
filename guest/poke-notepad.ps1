# Revive-probe: type text into Notepad (real keystrokes via SendKeys), then nudge the window
# 1px and back (forces move + damage). Prints rects before/after.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace P -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output '=== RESULT ==='; @{ error='no notepad' } | ConvertTo-Json; exit }
$h = $p.MainWindowHandle
$r0 = New-Object P.W+RECT; [void][P.W]::GetWindowRect($h, [ref]$r0)
[void][P.W]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait("QWT CONTENT PROBE 123")
Start-Sleep -Milliseconds 600
[void][P.W]::SetWindowPos($h, [IntPtr]::Zero, $r0.L+1, $r0.T, 0, 0, 0x0005) # NOSIZE|NOZORDER
Start-Sleep -Milliseconds 300
[void][P.W]::SetWindowPos($h, [IntPtr]::Zero, $r0.L, $r0.T, 0, 0, 0x0005)
Start-Sleep -Milliseconds 300
$r1 = New-Object P.W+RECT; [void][P.W]::GetWindowRect($h, [ref]$r1)
Write-Output '=== RESULT ==='
@{ hwnd = '0x{0:X}' -f $h.ToInt64(); before = "$($r0.L),$($r0.T)"; after = "$($r1.L),$($r1.T)" } | ConvertTo-Json
