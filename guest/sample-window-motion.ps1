# GROUND TRUTH for the drag wobble: sample the real window position in-guest at 10 ms for
# -Seconds, from a windowless scheduled task (no console, no focus theft), into a file that
# is retrieved LATER. Compared against the agent's announce stream this answers the only
# question left: does the WINDOW physically move backward during a drag (input/injection
# problem), or does it move smoothly while the AGENT announces backward values (read/report
# problem)? Every fix attempted so far assumed one or the other without measuring it.
param([int]$Seconds = 25)
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\winmotion.txt" -ErrorAction SilentlyContinue

@"
`$ErrorActionPreference = 'Continue'
Add-Type -Namespace M -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
[StructLayout(LayoutKind.Sequential)] public struct PT { public int X,Y; }
'@
`$p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { `$_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not `$p) { Set-Content 'C:\toastprobe\winmotion.txt' 'no notepad'; exit }
`$h = `$p.MainWindowHandle
`$out = New-Object System.Collections.Generic.List[string]
`$sw = [System.Diagnostics.Stopwatch]::StartNew()
while (`$sw.ElapsedMilliseconds -lt ($Seconds * 1000)) {
    `$wr = New-Object M.W+RECT; [void][M.W]::GetWindowRect(`$h, [ref]`$wr)
    `$dr = New-Object M.W+RECT; [void][M.W]::DwmGetWindowAttribute(`$h, 9, [ref]`$dr, 16)
    `$c  = New-Object M.W+PT;   [void][M.W]::GetCursorPos([ref]`$c)
    `$out.Add(('{0} win={1},{2} dwm={3},{4} cur={5},{6} utc={7}' -f `$sw.ElapsedMilliseconds, `$wr.L, `$wr.T, `$dr.L, `$dr.T, `$c.X, `$c.Y, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')))
    Start-Sleep -Milliseconds 10
}
`$out | Set-Content 'C:\toastprobe\winmotion.txt'
"@ | Set-Content "$work\winmotion-inner.ps1" -Encoding ASCII

@'
CreateObject("WScript.Shell").Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\toastprobe\winmotion-inner.ps1""", 0, False
'@ | Set-Content "$work\winmotion.vbs" -Encoding ASCII

& schtasks /create /tn QwtWinMotion /tr "wscript.exe //B //Nologo $work\winmotion.vbs" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinMotion *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true; seconds = $Seconds } | ConvertTo-Json
