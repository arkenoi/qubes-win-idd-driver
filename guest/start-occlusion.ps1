# guest/start-occlusion.ps1 - DOES ANOTHER WINDOW'S PIXELS LAND INSIDE THE START MENU'S CARD?
# NOT SHIPPED (rig tooling).
#
# THE RISK THIS MEASURES. Start and Search are served from a MONITOR capture, cropped to the card's
# screen rect (WGCBRK_ROUTE_MONITOR, 2026-10-17) - because those surfaces have no per-window pixel
# source at all: WGC on the window, a DWM thumbnail of it, and PrintWindow all return black, while
# the monitor capture of the same rect returns 4623/4623 non-black. Jev named the consequence the
# largest remaining risk of that route (occlusion-unmeasured 0.93): the broker crops a rect out of
# the DESKTOP, so anything drawn OVER the menu is inside that crop and would be served as the
# menu's own pixels. That is the occluder bleed the de-slice work exists to prevent.
#
# "The menu is topmost, so nothing can occlude it" is the argument, and it is not a measurement.
# A toast is also topmost and appears WITHOUT taking the foreground, so it can sit over an open
# menu - which is exactly the shape reproduced here: a WS_EX_TOPMOST | WS_EX_NOACTIVATE window,
# raised AFTER the menu is open (so it is above it in the topmost band) and never activated (so the
# menu does not close). If its colour appears inside the card's rect, bleed is real and the route
# needs a guard. If it does not, the rect is the menu's own pixels even under a hostile occluder.
#
# THE OCCLUDER'S COLOUR IS THE INSTRUMENT: a flat, unmistakable magenta (0x00FF00FF) that no part of
# the Windows shell draws. wgcprobe prints the distinct colours it found in the rect, so the answer
# is "is FF00FF in that list", not an eyeballed screenshot. Numbers only, never images.
param([ValidateSet('ctrlesc', 'shiftwin', 'win')] [string] $Opener = 'ctrlesc',
      [int] $WaitMs = 2500, [int] $TaskTimeoutSec = 120,
      [string] $WgcProbe = '')
$ErrorActionPreference = 'Continue'
$work = 'C:\startpixel'
New-Item -ItemType Directory -Force $work | Out-Null
$res = Join-Path $work 'occl.txt'
Remove-Item $res -Force -ErrorAction SilentlyContinue

$inner = Join-Path $work 'occl.ps1'
@"
`$ErrorActionPreference = 'Continue'
`$WaitMs = $WaitMs
`$Opener = '$Opener'
`$WgcProbe = '$WgcProbe'
"@ + "`n" + @'
$RES = 'C:\startpixel\occl.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
function Say($m) { $script:lines.Add($m); Set-Content -LiteralPath $RES -Value $script:lines -Encoding UTF8 }

try {
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace OC -Name W -MemberDefinition @"
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
[DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
[DllImport("gdi32.dll")] public static extern IntPtr CreateSolidBrush(uint c);
[DllImport("user32.dll")] public static extern int FillRect(IntPtr dc, ref RECT r, IntPtr br);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
[DllImport("user32.dll", EntryPoint="SetClassLongPtrW")] public static extern IntPtr SetClassLongPtrW(IntPtr h, int i, IntPtr v);
[DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr rgn, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
"@

function Find-ShellSurfaces {
    # SCRIPT SCOPE, NOT FUNCTION LOCALS: the callback below runs as a delegate and cannot see a
    # function's locals. As locals these were $null inside it and every callback silently added
    # nothing, so this returned 0 on every run and only the foreground fallback measured anything.
    $script:pids = @{}
    foreach ($n in 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost') {
        foreach ($p in (Get-Process $n -ErrorAction SilentlyContinue)) { $script:pids[[uint32]$p.Id] = $n }
    }
    $script:acc = New-Object System.Collections.Generic.List[object]
    $cb = [OC.W+EnumProc] {
        param($h, $l)
        $pid2 = [uint32]0; [void][OC.W]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($script:pids.ContainsKey($pid2) -and [OC.W]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][OC.W]::GetClassNameW($h, $sb, 256)
            $r = New-Object OC.W+RECT
            [void][OC.W]::GetWindowRect($h, [ref]$r)
            $w = $r.right - $r.left; $ht = $r.bottom - $r.top
            $cloak = 0; [void][OC.W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
            if ($w -gt 16 -and $ht -gt 16 -and $w -le 16384 -and $ht -le 16384 -and $cloak -eq 0) {
                $script:acc.Add([pscustomobject]@{ h = $h; cls = $sb.ToString(); proc = $script:pids[$pid2]; x = $r.left; y = $r.top; w = $w; ht = $ht })
            }
        }
        return $true
    }
    [void][OC.W]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:acc
}

Say ("occlusion session=" + [System.Diagnostics.Process]::GetCurrentProcess().SessionId + " user=" + (whoami))

# 0. NORMALISE FIRST, because THE OPENER TOGGLES. Ctrl+Esc on an already-open menu CLOSES it, and
#    a previous run that threw before its closing Escape leaves one open - which is exactly what
#    happened here: the run before this one found the surface, errored on a style-bits conversion,
#    and left the menu up, so this run's Ctrl+Esc shut it and reported "the menu never opened".
#    An opener that is a toggle needs a known starting state, not a hope.
Start-Sleep -Milliseconds 800
if (@(Find-ShellSurfaces).Count -gt 0) {
    Say '  pre: a shell surface was already open - pressing Escape to start from closed'
    [OC.W]::keybd_event(0x1B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    [OC.W]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 700
    if (@(Find-ShellSurfaces).Count -gt 0) { Say 'OC_STUCKOPEN a shell surface survived Escape - not measuring over an unknown state'; throw 'stuck open' }
}

# 1. OPEN THE MENU. The occluder has to go ABOVE it, and z-order in the topmost band is
#    last-raised-wins, so an occluder created first would simply end up underneath.
Start-Sleep -Milliseconds 400
switch ($Opener) {
    'ctrlesc'  { [OC.W]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [OC.W]::keybd_event(0x1B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [OC.W]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); [OC.W]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
    'shiftwin' { [OC.W]::keybd_event(0x10,0,0,[UIntPtr]::Zero); [OC.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [OC.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero); [OC.W]::keybd_event(0x10,0,2,[UIntPtr]::Zero) }
    default    { [OC.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
                 [OC.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero) }
}
$after = @(); $el = 0
while ($el -lt $WaitMs) { Start-Sleep -Milliseconds 100; $el += 100; $after = @(Find-ShellSurfaces); if ($after.Count -gt 0) { break } }
$fg = [OC.W]::GetForegroundWindow()
$fsb = New-Object System.Text.StringBuilder 256
[void][OC.W]::GetClassNameW($fg, $fsb, 256)
if ($after.Count -eq 0 -and $fsb.ToString() -eq 'Windows.UI.Core.CoreWindow') {
    $fr = New-Object OC.W+RECT; [void][OC.W]::GetWindowRect($fg, [ref]$fr)
    $after = @([pscustomobject]@{ h = $fg; cls = $fsb.ToString(); proc = 'foreground'; x = $fr.left; y = $fr.top; w = ($fr.right-$fr.left); ht = ($fr.bottom-$fr.top) })
}
if (@($after).Count -eq 0) { Say 'OC_NOSURFACE the menu never opened - nothing measured'; throw 'no surface' }
$s = @($after)[0]
Say ("SURFACE hwnd=0x{0:x} {1} {2}x{3} at {4},{5}" -f $s.h.ToInt64(), $s.proc, $s.w, $s.ht, $s.x, $s.y)

# 2. A TOPMOST, NEVER-ACTIVATED OCCLUDER over the MIDDLE of the card, raised now so it is above the
#    menu. NOACTIVATE so the menu keeps the foreground and stays open - the same way a toast does.
$ox = $s.x + [int]($s.w/4); $oy = $s.y + [int]($s.ht/4)
$ow = [int]($s.w/2);        $oh = [int]($s.ht/4)

# 2b. BEFORE: what that rect holds with the menu open and NO occluder - the baseline the A/B needs.
$beforeColors = ''
if ($WgcProbe -and (Test-Path -LiteralPath $WgcProbe)) {
    $bo = & $WgcProbe mon $ox $oy $ow $oh 2>&1
    foreach ($ln in @($bo)) { if ($ln -match 'rect=|rectcolors=') { Say ("    PRE " + $ln) } }
    $beforeColors = (@($bo) | Where-Object { $_ -match '^rectcolors=' }) -join ''
}
$WS_POPUP=[uint32]2147483648; $WS_VISIBLE=[uint32]268435456   # 0x80000000 / 0x10000000, decimal because the hex literal is Int32
$EX_TOPMOST=[uint32]0x8; $EX_NOACTIVATE=[uint32]0x8000000; $EX_TOOLWINDOW=[uint32]0x80
$occ = [OC.W]::CreateWindowExW([uint32]($EX_TOPMOST -bor $EX_NOACTIVATE -bor $EX_TOOLWINDOW), 'Static', '',
                               [uint32]($WS_POPUP -bor $WS_VISIBLE), $ox, $oy, $ow, $oh,
                               [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
if ($occ -eq [IntPtr]::Zero) { Say 'OC_NOWINDOW could not create the occluder'; throw 'no occluder' }
# HWND_TOPMOST (-1), no activation, no move/size: put it above the menu in the topmost band.
[void][OC.W]::SetWindowPos($occ, [IntPtr](-1), 0, 0, 0, 0, [uint32](0x0010 -bor 0x0001 -bor 0x0002))   # NOACTIVATE|NOSIZE|NOMOVE
# FLAT MAGENTA, a colour the shell never draws. PAINTED REPEATEDLY AND LAST: a FillRect on a
# window's DC with no WM_PAINT handler does not survive DefWindowProc's own background paint, and
# the first version of this test filled once at creation, measured the class's default F2F2F2
# instead, and would have reported a clean "no bleed" from an occluder that was never magenta. The
# positive control caught that; painting just before each read is the fix.
# THE CLASS BRUSH, not a FillRect. Two earlier versions filled the window's DC - once at creation,
# then again immediately before each read - and the positive control measured F2F2F2 both times:
# DWM composites the redirection surface that DefWindowProc fills with the CLASS background, and a
# bare GDI fill loses to it. So make the class background magenta and let DefWindowProc paint it.
$GCLP_HBRBACKGROUND = -10
$magenta = [OC.W]::CreateSolidBrush([uint32]0x00FF00FF)     # COLORREF 0x00BBGGRR -> magenta
[void][OC.W]::SetClassLongPtrW($occ, $GCLP_HBRBACKGROUND, $magenta)
function Paint-Occluder {
    # RDW_INVALIDATE|RDW_ERASE|RDW_UPDATENOW: erase with the (now magenta) class brush, synchronously.
    [void][OC.W]::RedrawWindow($occ, [IntPtr]::Zero, [IntPtr]::Zero, [uint32](0x0001 -bor 0x0004 -bor 0x0100))
}
Start-Sleep -Milliseconds 300
Paint-Occluder
Start-Sleep -Milliseconds 300
$fg2 = [OC.W]::GetForegroundWindow()
Say ("OCCLUDER hwnd=0x{0:x} at {1},{2} {3}x{4} magenta; foreground still the menu: {5}" -f `
    $occ.ToInt64(), $ox, $oy, $ow, $oh, ($fg2 -eq $s.h))

# 3. A/B ON THE SAME RECT, which needs no painting at all. Three attempts to make the occluder a
#    chosen colour all measured F2F2F2 - the class default - because DWM composites the surface
#    DefWindowProc fills and neither a FillRect nor SetClassLongPtrW on a system class beats it.
#    But the colour was never the point: the question is whether ANOTHER window's pixels appear
#    inside this window's crop. So read the occluder's rect BEFORE it exists and AFTER, and compare.
#    Before: the menu's own pixels (a blue gradient, many colours). After: if the occluder is in the
#    capture, a flat block of its colour. A change from many colours to one flat colour IS the
#    bleed, whatever that colour happens to be - and it is checked against the menu's own palette
#    rather than against a colour I failed to paint.
#    (The rect is probed before creation in step 2b, stored in $beforeColors.)

# 3b. THE POSITIVE CONTROL FIRST. "No magenta inside the card" is worthless unless the occluder IS
#    magenta and IS in the capture - and FillRect on a window's DC with no WM_PAINT handler is
#    transient, so that is a real possibility, not a pedantic one. Probe the OCCLUDER'S OWN rect:
#    magenta there means the instrument works and the card answer means something. Magenta absent
#    there means this test proves NOTHING, and it must say so rather than report a clean pass.
if ($WgcProbe -and (Test-Path -LiteralPath $WgcProbe)) {
    Paint-Occluder
    $co = & $WgcProbe mon $ox $oy $ow $oh 2>&1
    foreach ($ln in @($co)) { if ($ln -match 'rect=|rectcolors=') { Say ("    CTL " + $ln) } }
    $ctl = (@($co) | Where-Object { $_ -match '^rectcolors=' }) -join ''
    $ctlOk = ($ctl -match 'FF00FF')
    if ($ctlOk) { Say '  CONTROL ok: the occluder reads magenta in the monitor capture, so this test can detect bleed' }
    else { Say '  CONTROL FAILED: the occluder does NOT read magenta - it was never painted or never composited' }

    # 4. NOW THE CARD'S RECT - the SAME rect the broker crops for this window.
    Paint-Occluder
    $o = & $WgcProbe mon $s.x $s.y $s.w $s.ht 2>&1
    foreach ($ln in @($o)) { if ($ln -match 'rect=|rectcolors=|frameArrived') { Say ("    " + $ln) } }
    $colors = (@($o) | Where-Object { $_ -match '^rectcolors=' }) -join ''
    # THE A/B VERDICT. $ctl is the occluder's rect WITH it present; $beforeColors the same rect
    # with the menu open and no occluder. A flat single colour where there was a gradient means the
    # occluder's pixels are inside the menu's crop.
    $ctlFlat = ($ctl -match '^rectcolors=([0-9A-F]{6})$')
    $ctlColor = if ($ctlFlat) { $Matches[1] } else { '' }
    $changed = ($beforeColors -ne '' -and $ctl -ne '' -and $beforeColors -ne $ctl)
    Say ("  A/B rect $ox,$oy ${ow}x${oh}: before='" + $beforeColors + "' after='" + $ctl + "' changed=$changed flat=$ctlFlat")
    if ($beforeColors -eq '' -or $ctl -eq '') {
        Say 'OC_VACUOUS one of the two readings is missing - nothing is proved'
    } elseif ($changed -and $ctlFlat) {
        Say ("OC_BLEED YES - with a topmost non-activating window over the menu, that part of the menu's own crop reads a flat " + $ctlColor + " instead of the menu's pixels: another window IS served inside this one")
    } elseif (-not $changed) {
        Say 'OC_BLEED NO - the rect reads the same with and without the occluder, so the occluder is not in this capture'
    } else {
        Say ("OC_BLEED UNCLEAR - the rect changed but is not a flat colour: before='" + $beforeColors + "' after='" + $ctl + "'")
    }
} else { Say "OC_SKIP no wgcprobe at '$WgcProbe'" }

[void][OC.W]::DestroyWindow($occ)
[void][OC.W]::DeleteObject($magenta)
[OC.W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
[OC.W]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
Say 'OC_DONE'
}
catch { Say ("OC_ERROR " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
'@ | Set-Content -LiteralPath $inner -Encoding UTF8

$u = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $u) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'no autologon user' } | ConvertTo-Json -Compress; exit 2 }
& schtasks /delete /tn QwtStartOccl /f *>&1 | Out-Null
& schtasks /create /tn QwtStartOccl /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $inner" /sc once /st 00:00 /ru $u /it /f *>&1 | Out-Null
& schtasks /run /tn QwtStartOccl *>&1 | Out-Null
$deadline = (Get-Date).AddSeconds($TaskTimeoutSec); $got = ''; $txt = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path -LiteralPath $res) {
        $txt = (Get-Content -LiteralPath $res -ErrorAction SilentlyContinue) -join "`n"
        if ($txt -match 'OC_DONE') { $got = 'done'; break }
        if ($txt -match 'OC_ERROR|OC_NOSURFACE|OC_NOWINDOW') { $got = 'error'; break }
    }
}
& schtasks /delete /tn QwtStartOccl /f *>&1 | Out-Null
Write-Output '=== SAMPLES ==='
if ($txt) { Write-Output $txt } else { Write-Output 'NO OUTPUT AT ALL' }
Write-Output '=== RESULT ==='
@{ ok = ($got -eq 'done'); outcome = $(if ($got) { $got } else { 'timeout' }) } | ConvertTo-Json -Compress
if ($got -ne 'done') { exit 1 }
