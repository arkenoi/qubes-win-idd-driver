# Feasibility probe for WM-managed (movable) shell surfaces: take the toast banner HWND
# from the agent's own log (ToastCropLookup line), then try SetWindowPos and report whether
# the move stuck. Answers: can dom0-WM drags be applied to shell-band windows at all?
$ErrorActionPreference = 'Continue'
Add-Type -Namespace P -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$r = [ordered]@{}
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$line = Get-Content $log.FullName | Select-String 'ToastCropLookup: (0x[0-9a-fA-F]+):' | Select-Object -Last 1
$r.log_line = if ($line) { $line.Line } else { $null }
if (-not $line) { Write-Output '=== RESULT ==='; $r | ConvertTo-Json; exit }
$h = [IntPtr][Convert]::ToInt64(($line.Matches[0].Groups[1].Value), 16)
$r.hwnd = '0x{0:X}' -f $h.ToInt64()
$r.is_window = [P.W]::IsWindow($h)
$r.visible = [P.W]::IsWindowVisible($h)
if (-not $r.is_window) { Write-Output '=== RESULT ==='; $r | ConvertTo-Json; exit }

$rc = New-Object P.W+RECT
[void][P.W]::GetWindowRect($h, [ref]$rc)
$r.rect = "$($rc.L),$($rc.T) $($rc.R-$rc.L)x$($rc.B-$rc.T)"

# SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_ASYNCWINDOWPOS = 0x0001|0x0004|0x0010|0x4000
$ok = [P.W]::SetWindowPos($h, [IntPtr]::Zero, $rc.L - 200, $rc.T - 200, 0, 0, 0x4015)
$r.setwindowpos_ok = $ok
$r.setwindowpos_err = if (-not $ok) { [Runtime.InteropServices.Marshal]::GetLastWin32Error() } else { 0 }
Start-Sleep -Milliseconds 500
$rc2 = New-Object P.W+RECT
[void][P.W]::GetWindowRect($h, [ref]$rc2)
$r.rect_after = "$($rc2.L),$($rc2.T) $($rc2.R-$rc2.L)x$($rc2.B-$rc2.T)"
$r.move_stuck = ($rc2.L -eq $rc.L - 200)
# put it back
[void][P.W]::SetWindowPos($h, [IntPtr]::Zero, $rc.L, $rc.T, 0, 0, 0x4015)
Write-Output '=== RESULT ==='
$r | ConvertTo-Json
