# Occlusion choreography for the WM-managed Start (armed-task pattern: all guest actions
# happen AFTER this script exits, so nothing steals focus from the open menu).
# Timeline (from arm): t=3.5s Win key (Start opens); t=7s Notepad moved UNDER the Start
# region (overlap); t=10s marker A; t=12s the Start WINDOW ITSELF moved +400,+150
# programmatically (tests move-stickiness for Start); t=15s marker B; t=17s Esc (Start
# closes); t=19s marker C. The caller takes dom0 fullshots at ~t=11, ~t=16, ~t=20.
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\occl-*.txt" -ErrorAction SilentlyContinue
@'
$ErrorActionPreference = 'Continue'
Start-Sleep -Milliseconds 3500
Add-Type -Namespace W -Name K -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr a, int x, int y, int w, int hh, uint f);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, System.IntPtr l);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
"@
# open Start
[W.K]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
[W.K]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 3500
# move Notepad under the Start region (Start sits near 5,56 832x736)
$np = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($np) { [void][W.K]::SetWindowPos($np.MainWindowHandle, [IntPtr]::Zero, 60, 200, 0, 0, 0x4015) } # NOZORDER|NOSIZE|NOACTIVATE|ASYNC
Start-Sleep -Milliseconds 3000
Set-Content 'C:\toastprobe\occl-A.txt' 'a'
Start-Sleep -Milliseconds 2000
# find the Start card hwnd: a visible StartMenuExperienceHost window of card-ish size
$smePids = @(Get-Process StartMenuExperienceHost -EA SilentlyContinue | ForEach-Object { [uint32]$_.Id })
$script:startHwnd = [IntPtr]::Zero
$cb = [W.K+EnumProc]{ param($h, $l)
    if ([W.K]::IsWindowVisible($h)) {
        $pid2 = [uint32]0; [void][W.K]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($smePids -contains $pid2) {
            $r = New-Object W.K+RECT; [void][W.K]::GetWindowRect($h, [ref]$r)
            $w = $r.R - $r.L; $hh = $r.B - $r.T
            if ($w -gt 400 -and $w -lt 1200 -and $hh -gt 400 -and $hh -lt 1100) { $script:startHwnd = $h; return $false }
        }
    }
    $true }
[void][W.K]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:startHwnd -ne [IntPtr]::Zero) {
    $r0 = New-Object W.K+RECT; [void][W.K]::GetWindowRect($script:startHwnd, [ref]$r0)
    [void][W.K]::SetWindowPos($script:startHwnd, [IntPtr]::Zero, $r0.L + 400, $r0.T + 150, 0, 0, 0x4015)
    Start-Sleep -Milliseconds 500
    $r1 = New-Object W.K+RECT; [void][W.K]::GetWindowRect($script:startHwnd, [ref]$r1)
    Set-Content 'C:\toastprobe\occl-B.txt' ("moved {0},{1} -> {2},{3}" -f $r0.L, $r0.T, $r1.L, $r1.T)
} else {
    Set-Content 'C:\toastprobe\occl-B.txt' 'no start hwnd found'
}
Start-Sleep -Milliseconds 2500
# close Start
[W.K]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[W.K]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 1500
Set-Content 'C:\toastprobe\occl-C.txt' 'c'
'@ | Set-Content "$work\occl-inner.ps1" -Encoding ASCII
& schtasks /create /tn QwtOcclProbe /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\occl-inner.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtOcclProbe *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true } | ConvertTo-Json
