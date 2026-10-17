# guest/start-windowsource.ps1 - IS THERE ANY PER-WINDOW SOURCE FOR THE START MENU AT ALL?
# NOT SHIPPED (rig tooling).
#
# WHY THIS EXISTS. The claim "these surfaces have no per-window pixel source" is currently resting
# on three probes that all aimed at ONE handle - the StartMenuExperienceHost CoreWindow itself:
# WGC CreateForWindow on it (black), WGC on a DWM thumbnail of it (black), and
# PrintWindow(PW_RENDERFULLCONTENT) on it (maxchannel=0). That claim is what justifies sourcing the
# menu from a MONITOR capture, i.e. cutting it out of the desktop - a path this project retired on
# purpose ("desktop-copy is slicing in disguise", owner 2026-09-30).
#
# A claim that costs an architectural rule should be tested harder than three shots at one handle.
# A shell host owns several top-level windows, and the 2026-09-02 finding was specifically about
# the CoreWindow CLASS - it says nothing about the host's other windows. So: enumerate EVERY
# top-level window of StartMenuExperienceHost, SearchHost and ShellExperienceHost while the menu is
# open, and run a real WGC CreateForWindow session against each one. If any of them delivers a
# non-blank frame, a per-window source exists, the monitor route is unnecessary, and the rule stands
# untouched.
#
# Windowless and interactive for the usual reason: a console taking the foreground closes the menu.
# wgcprobe is a console program, so it runs from inside this task, never over qrexec.
param([ValidateSet('ctrlesc', 'shiftwin', 'win')] [string] $Opener = 'ctrlesc',
      [int] $WaitMs = 2500, [int] $TaskTimeoutSec = 180,
      [string] $WgcProbe = '')
$ErrorActionPreference = 'Continue'
$work = 'C:\startpixel'
New-Item -ItemType Directory -Force $work | Out-Null
$res = Join-Path $work 'winsrc.txt'
Remove-Item $res -Force -ErrorAction SilentlyContinue

$inner = Join-Path $work 'winsrc.ps1'
@"
`$ErrorActionPreference = 'Continue'
`$WaitMs = $WaitMs
`$Opener = '$Opener'
`$WgcProbe = '$WgcProbe'
"@ + "`n" + @'
$RES = 'C:\startpixel\winsrc.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
function Say($m) { $script:lines.Add($m); Set-Content -LiteralPath $RES -Value $script:lines -Encoding UTF8 }

try {
Add-Type -Namespace WS -Name W -MemberDefinition @"
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
"@

# EVERY top-level window of the shell hosts, visible or not: the point is to find a handle WGC can
# serve, and "not visible" is not the same as "not capturable".
function Find-HostWindows {
    $script:hp = @{}
    foreach ($n in 'StartMenuExperienceHost', 'SearchHost', 'ShellExperienceHost') {
        foreach ($p in (Get-Process $n -ErrorAction SilentlyContinue)) { $script:hp[[uint32]$p.Id] = $n }
    }
    $script:found = New-Object System.Collections.Generic.List[object]
    $cb = [WS.W+EnumProc] {
        param($h, $l)
        $pid2 = [uint32]0; [void][WS.W]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($script:hp.ContainsKey($pid2)) {
            $cn = New-Object System.Text.StringBuilder 256
            [void][WS.W]::GetClassNameW($h, $cn, 256)
            $r = New-Object WS.W+RECT
            [void][WS.W]::GetWindowRect($h, [ref]$r)
            $cloak = 0; [void][WS.W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
            $script:found.Add([pscustomobject]@{
                h = $h; proc = $script:hp[$pid2]; cls = $cn.ToString()
                vis = [WS.W]::IsWindowVisible($h); cloak = $cloak
                x = $r.left; y = $r.top; w = ($r.right-$r.left); ht = ($r.bottom-$r.top) })
        }
        return $true
    }
    [void][WS.W]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:found
}

Say ("windowsource session=" + [System.Diagnostics.Process]::GetCurrentProcess().SessionId + " user=" + (whoami))

# The opener TOGGLES, so start from a known closed state.
Start-Sleep -Milliseconds 800
if (@(Find-HostWindows | Where-Object { $_.vis -and $_.cloak -eq 0 -and $_.w -gt 16 }).Count -gt 0) {
    [WS.W]::keybd_event(0x1B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    [WS.W]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 700
}
switch ($Opener) {
    'ctrlesc'  { [WS.W]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [WS.W]::keybd_event(0x1B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [WS.W]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); [WS.W]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
    'shiftwin' { [WS.W]::keybd_event(0x10,0,0,[UIntPtr]::Zero); [WS.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [WS.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero); [WS.W]::keybd_event(0x10,0,2,[UIntPtr]::Zero) }
    default    { [WS.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
                 [WS.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero) }
}
Start-Sleep -Milliseconds $WaitMs

$all = @(Find-HostWindows)
Say ("HOSTWINDOWS count=" + $all.Count)
foreach ($x in $all) {
    Say ("  W hwnd=0x{0:x} {1} class={2} vis={3} cloak={4} {5}x{6} at {7},{8}" -f `
        $x.h.ToInt64(), $x.proc, $x.cls, $x.vis, $x.cloak, $x.w, $x.ht, $x.x, $x.y)
}
if ($all.Count -eq 0) { Say 'WS_NOWINDOWS no shell-host windows at all - nothing measured'; throw 'none' }

# A REAL WGC SESSION PER HANDLE. wgcprobe's own exit says whether the item was created and whether
# a NON-BLANK frame arrived, so a handle that works is unmistakable.
if ($WgcProbe -and (Test-Path -LiteralPath $WgcProbe)) {
    $any = $false
    foreach ($x in $all) {
        if ($x.w -le 16 -or $x.ht -le 16) { Say ("  SKIP 0x{0:x} degenerate {1}x{2}" -f $x.h.ToInt64(), $x.w, $x.ht); continue }
        $hex = '{0:x}' -f $x.h.ToInt64()
        $o = & $WgcProbe $hex 2>&1
        $line = (@($o) | Where-Object { $_ -match '^frameArrived=' }) -join ''
        Say ("  PROBE 0x{0}  {1}  <- {2} {3}" -f $hex, $line, $x.proc, $x.cls)
        if ($line -match 'nonBlank=1') { $any = $true; Say ("  *** 0x$hex DELIVERS A NON-BLANK PER-WINDOW FRAME") }
    }
    if ($any) { Say 'WS_PERWINDOW YES - at least one shell-host window is capturable per-window' }
    else      { Say 'WS_PERWINDOW NO - no shell-host window delivered a non-blank per-window frame' }
} else { Say "WS_SKIP no wgcprobe at '$WgcProbe'" }

[WS.W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[WS.W]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
Say 'WS_DONE'
}
catch { Say ("WS_ERROR " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
'@ | Set-Content -LiteralPath $inner -Encoding UTF8

$u = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $u) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'no autologon user' } | ConvertTo-Json -Compress; exit 2 }
& schtasks /delete /tn QwtWinSrc /f *>&1 | Out-Null
& schtasks /create /tn QwtWinSrc /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $inner" /sc once /st 00:00 /ru $u /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinSrc *>&1 | Out-Null
$deadline = (Get-Date).AddSeconds($TaskTimeoutSec); $got = ''; $txt = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path -LiteralPath $res) {
        $txt = (Get-Content -LiteralPath $res -ErrorAction SilentlyContinue) -join "`n"
        if ($txt -match 'WS_DONE') { $got = 'done'; break }
        if ($txt -match 'WS_ERROR|WS_NOWINDOWS') { $got = 'error'; break }
    }
}
& schtasks /delete /tn QwtWinSrc /f *>&1 | Out-Null
Write-Output '=== SAMPLES ==='
if ($txt) { Write-Output $txt } else { Write-Output 'NO OUTPUT AT ALL' }
Write-Output '=== RESULT ==='
@{ ok = ($got -eq 'done'); outcome = $(if ($got) { $got } else { 'timeout' }) } | ConvertTo-Json -Compress
if ($got -ne 'done') { exit 1 }
