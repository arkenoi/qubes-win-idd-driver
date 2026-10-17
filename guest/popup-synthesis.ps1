# guest/popup-synthesis.ps1 - CAN THE OWNER'S OWN CAPTURE CONTAIN ITS POPUP?
# NOT SHIPPED (rig tooling).
#
# THE PROBLEM. A WinUI popup (Microsoft.UI.Content.PopupWindowSiteBridge - a tooltip, a flyout, a
# teaching tip) is its own TOP-LEVEL HWND. The owner's capture excludes it, so the agent announces
# it to dom0 as a separate window, and dom0 marks every window it is given with the qube's 2 px
# label border. The result, photographed 2026-10-17 on a Notepad teaching tip: a red rectangle
# drawn INSIDE the Notepad window, around a popup that lies wholly within it.
#
# Cutting is already as tight as a rectangle can be - the broker measures the opaque box on the WGC
# path too now, and the left/right black rims are gone in a capture. But that popup has a callout
# BEAK: the rows beside the beak are transparent, transparency ships as opaque black, and no
# rectangle can exclude them. The remaining black is structural for a rectangular window.
#
# THE ALTERNATIVE IS SYNTHESIS - put the popup INTO the parent instead of announcing it - and
# Windows may already do it for free. GraphicsCaptureSession.IncludeSecondaryWindows composites
# owned windows into the owner's frames with their real transparency. If that works here, the agent
# needs no compositing code at all: it simply stops announcing a popup that lies wholly inside a
# tracked owner, and the owner's existing capture carries it.
#
# SO THIS MEASURES BEFORE ANY OF THAT IS BUILT. One Notepad, one teaching tip, two captures of the
# SAME owner window, sampled at the SAME rectangle - the popup's rect expressed relative to the
# owner - once with IncludeSecondaryWindows off and once on:
#   off: the rect should hold the parent's own pixels (no popup)
#   on : if it holds the popup's pixels, synthesis is free and the answer is yes
# A difference between the two readings is the whole result; neither alone proves anything, which
# is why both are taken in one run against one window.
param([string] $WgcProbe = '', [int] $TaskTimeoutSec = 150)
$ErrorActionPreference = 'Continue'
$work = 'C:\startpixel'
New-Item -ItemType Directory -Force $work | Out-Null
$res = Join-Path $work 'synth.txt'
Remove-Item $res -Force -ErrorAction SilentlyContinue

$inner = Join-Path $work 'synth.ps1'
@"
`$ErrorActionPreference = 'Continue'
`$WgcProbe = '$WgcProbe'
"@ + "`n" + @'
$RES = 'C:\startpixel\synth.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
function Say($m) { $script:lines.Add($m); Set-Content -LiteralPath $RES -Value $script:lines -Encoding UTF8 }

try {
Add-Type -Namespace SY -Name W -MemberDefinition @"
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
"@

# Every visible top-level window of the notepad processes, with class and rect.
function Find-NotepadWindows {
    $script:np = @{}
    foreach ($p in (Get-Process notepad -ErrorAction SilentlyContinue)) { $script:np[[uint32]$p.Id] = $p.Id }
    $script:acc = New-Object System.Collections.Generic.List[object]
    $cb = [SY.W+EnumProc] {
        param($h, $l)
        $pid2 = [uint32]0; [void][SY.W]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($script:np.ContainsKey($pid2) -and [SY.W]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][SY.W]::GetClassNameW($h, $sb, 256)
            $r = New-Object SY.W+RECT
            [void][SY.W]::GetWindowRect($h, [ref]$r)
            $w = $r.right - $r.left; $ht = $r.bottom - $r.top
            if ($w -gt 8 -and $ht -gt 8) {
                $script:acc.Add([pscustomobject]@{ h = $h; cls = $sb.ToString(); x = $r.left; y = $r.top; w = $w; ht = $ht })
            }
        }
        return $true
    }
    [void][SY.W]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:acc
}

Start-Sleep -Milliseconds 1500
$wins = @(Find-NotepadWindows)
Say ("WINDOWS count=" + $wins.Count)
foreach ($x in $wins) { Say ("  W hwnd=0x{0:x} class={1} {2}x{3} at {4},{5}" -f $x.h.ToInt64(), $x.cls, $x.w, $x.ht, $x.x, $x.y) }

$popup = $wins | Where-Object { $_.cls -match 'PopupWindowSiteBridge|Xaml_WindowedPopup' } | Select-Object -First 1
$owner = $wins | Where-Object { $_.cls -notmatch 'PopupWindowSiteBridge|Xaml_WindowedPopup' } |
         Sort-Object { $_.w * $_.ht } -Descending | Select-Object -First 1
if (-not $popup) { Say 'SY_NOPOPUP no WinUI popup present - nothing to measure (the teaching tip shows on a FIRST notepad run)'; throw 'no popup' }
if (-not $owner) { Say 'SY_NOOWNER no owner window'; throw 'no owner' }

# CONTAINMENT, the precondition for synthesis at all.
$inside = ($popup.x -ge $owner.x) -and ($popup.y -ge $owner.y) -and
          (($popup.x + $popup.w) -le ($owner.x + $owner.w)) -and
          (($popup.y + $popup.ht) -le ($owner.y + $owner.ht))
Say ("POPUP hwnd=0x{0:x} {1}x{2} at {3},{4} | OWNER hwnd=0x{5:x} {6}x{7} at {8},{9} | fully inside: {10}" -f `
    $popup.h.ToInt64(), $popup.w, $popup.ht, $popup.x, $popup.y,
    $owner.h.ToInt64(), $owner.w, $owner.ht, $owner.x, $owner.y, $inside)

# The popup's rect RELATIVE TO THE OWNER - a window capture's texture is the owner's window.
$rx = $popup.x - $owner.x; $ry = $popup.y - $owner.y
Say ("SAMPLE rect (owner-relative) = {0},{1} {2}x{3}" -f $rx, $ry, $popup.w, $popup.ht)

if ($WgcProbe -and (Test-Path -LiteralPath $WgcProbe)) {
    $hex = '{0:x}' -f $owner.h.ToInt64()
    foreach ($mode in @('off','on')) {
        $argsList = @($hex, $rx, $ry, $popup.w, $popup.ht)
        if ($mode -eq 'on') { $argsList += 'sec' }
        $o = & $WgcProbe @argsList 2>&1
        Say ("--- IncludeSecondaryWindows " + $mode)
        foreach ($ln in @($o)) {
            if ($ln -match 'secondaryWindows |rect=|rectcolors=|frameArrived|IsSupported') { Say ("      " + $ln) }
        }
    }
    Say 'SY_MEASURED compare the two rectcolors lines: if they differ, the owner capture carries the popup'
} else { Say "SY_SKIP no wgcprobe at '$WgcProbe'" }
Say 'SY_DONE'
}
catch { Say ("SY_ERROR " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
'@ | Set-Content -LiteralPath $inner -Encoding UTF8

$u = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $u) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'no autologon user' } | ConvertTo-Json -Compress; exit 2 }
& schtasks /delete /tn QwtSynth /f *>&1 | Out-Null
& schtasks /create /tn QwtSynth /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $inner" /sc once /st 00:00 /ru $u /it /f *>&1 | Out-Null
& schtasks /run /tn QwtSynth *>&1 | Out-Null
$deadline = (Get-Date).AddSeconds($TaskTimeoutSec); $got = ''; $txt = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path -LiteralPath $res) {
        $txt = (Get-Content -LiteralPath $res -ErrorAction SilentlyContinue) -join "`n"
        if ($txt -match 'SY_DONE') { $got = 'done'; break }
        if ($txt -match 'SY_ERROR|SY_NOPOPUP|SY_NOOWNER') { $got = 'error'; break }
    }
}
& schtasks /delete /tn QwtSynth /f *>&1 | Out-Null
Write-Output '=== SAMPLES ==='
if ($txt) { Write-Output $txt } else { Write-Output 'NO OUTPUT AT ALL' }
Write-Output '=== RESULT ==='
@{ ok = ($got -eq 'done'); outcome = $(if ($got) { $got } else { 'timeout' }) } | ConvertTo-Json -Compress
if ($got -ne 'done') { exit 1 }
