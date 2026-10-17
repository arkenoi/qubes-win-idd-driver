# guest/start-pixelsource.ps1 - CAN THE START MENU'S PIXELS BE READ AT ALL?
# NOT SHIPPED (rig tooling).
#
# THE QUESTION, and why it is the only one worth asking next. Measured 2026-10-17 across every
# capture on this rig: 26 of 26 broker frames for shell CoreWindows came back black
# (QGASLICEBLACK nonblack=0/9400, 0/10000, 105/10000, 0/7371), while ordinary windows on the same
# WGC path publish content normally. The agent then either maps the window unpainted on a 719 ms
# deadline (QGAHELDMAP reason=timeout) or never shows it at all (QGADIRECTSUPPRESS "never received
# a frame"), and it logs "the app's surface itself is dark" - a cause it has NOT established (Jev
# dark_claim_established: not-established 1.00). Black frames are equally consistent with a capture
# path that cannot see this window class, and those two have opposite fixes.
#
# So: capture the SAME window the broker failed on, through the agent's OTHER existing path -
# PrintWindow(PW_RENDERFULLCONTENT), the one polled for override-redirect menus - and count pixels.
#   content from PrintWindow + black from WGC  => the surface IS painted; the WGC path is the defect
#   black from both                            => nothing can read it; the surface really is dark
# Jev chose this probe over three alternatives at 0.96 (printwindow-the-same-window).
#
# WINDOWLESS AND INTERACTIVE, because the subject is destroyed by observation: ANY console flash
# takes the foreground and the Start menu closes (capture-start-render.ps1's constraint). So the
# whole body runs as one scheduled task in the logged-on session with no window, and the result is
# read back afterwards from a file.
#
# NUMBERS ONLY, NEVER IMAGES. pixel-equality.ps1's rule: the guest is untrusted and this returns
# data. It also keeps a guest desktop out of a public repo by construction.
#
# TWO SAMPLES PER WINDOW, 500 ms apart, because "black now" and "black for good" are different
# findings: WGC publishes on surface CHANGE, so a surface that never changes again can never
# produce a painted frame however long the agent waits (Jev starved-no-change-events 0.94).
#
# THREE THINGS THE FIRST TWO RUNS TAUGHT, each now mechanical rather than remembered:
#  1. THE WIN KEY IS NOT THE NATIVE OPENER HERE. This guest runs Open-Shell, which hooks VK_LWIN
#     and opens its own menu (class CMenuContainer, not a CoreWindow). Run 1 pressed Win, found
#     zero CoreWindows, and would have read as "the Start menu has no pixels" when the native menu
#     had simply never opened. Default is Ctrl+Esc, which no replacement intercepts; -Opener win
#     deliberately measures the replacement instead.
#  2. GetPixel IN A LOOP IS NOT A SAMPLER. Run 2 timed out: a visible CoreWindow can be 5120x1392,
#     and tens of thousands of GetPixel calls from PowerShell do not finish inside a minute. The
#     bitmap is now read once with LockBits and sampled out of a byte array.
#  3. A RESULT WRITTEN ONLY AT THE END IS NO RESULT. Run 2's timeout produced an empty file and no
#     clue. Every stage flushes, exceptions are caught and written, and SP_DONE means completed -
#     so a partial run is still evidence of where it stopped.
param([ValidateSet('ctrlesc', 'shiftwin', 'win')] [string] $Opener = 'ctrlesc',
      [int] $WaitMs = 2500, [int] $SecondSampleMs = 500, [int] $TaskTimeoutSec = 90)
$ErrorActionPreference = 'Continue'
$work = 'C:\startpixel'
New-Item -ItemType Directory -Force $work | Out-Null
$res = Join-Path $work 'result.txt'
Remove-Item $res -Force -ErrorAction SilentlyContinue

$inner = Join-Path $work 'inner.ps1'
@"
`$ErrorActionPreference = 'Continue'
`$WaitMs = $WaitMs
`$SecondSampleMs = $SecondSampleMs
`$Opener = '$Opener'
"@ + "`n" + @'
$RES = 'C:\startpixel\result.txt'
$script:lines = New-Object System.Collections.Generic.List[string]
function Say($m) { $script:lines.Add($m); Set-Content -LiteralPath $RES -Value $script:lines -Encoding UTF8 }

try {
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace PX -Name W -MemberDefinition @"
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
"@

# ONE LockBits READ, then sample the bytes. 32bppArgb, so 4 bytes per pixel and the stride may
# exceed width*4 - index by stride, never by width (indexing by width reads the next row's pixels
# and makes a painted window look patterned).
function Sample-Window([IntPtr]$h, [int]$w, [int]$ht) {
    $bmp = New-Object System.Drawing.Bitmap($w, $ht, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    # PW_RENDERFULLCONTENT (2) - the flag the agent uses; without it a DirectComposition surface
    # renders empty even when the window is painted.
    $dc = $g.GetHdc()
    $ok = [PX.W]::PrintWindow($h, $dc, 2)
    $g.ReleaseHdc($dc); $g.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $ht
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $bd.Stride
    $bytes = New-Object byte[] ($stride * $ht)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($bd)
    $step = 8; $tot = 0; $nb = 0; $max = 0
    $minx = $w; $miny = $ht; $maxx = -1; $maxy = -1
    for ($y = 0; $y -lt $ht; $y += $step) {
        $row = $y * $stride
        for ($x = 0; $x -lt $w; $x += $step) {
            $i = $row + ($x * 4)
            $b = $bytes[$i]; $gr = $bytes[$i+1]; $r = $bytes[$i+2]
            $m = [Math]::Max($r, [Math]::Max($gr, $b))
            $tot++
            if ($m -gt $max) { $max = $m }
            if ($m -gt 8) {
                $nb++
                if ($x -lt $minx) { $minx = $x }
                if ($x -gt $maxx) { $maxx = $x }
                if ($y -lt $miny) { $miny = $y }
                if ($y -gt $maxy) { $maxy = $y }
            }
        }
    }
    $bmp.Dispose()
    $bb = if ($maxx -ge 0) { "{0},{1} {2}x{3}" -f $minx, $miny, ($maxx - $minx + $step), ($maxy - $miny + $step) } else { 'none' }
    return @{ ok = $ok; nonblack = $nb; total = $tot; maxchannel = $max; bbox = $bb }
}

# SCOPED TO THE SHELL HOSTS, the way probe-start-windows.ps1 scopes: a bare "every visible
# CoreWindow" sweep pulls in unrelated UWP windows (and the 5120x1392 one that caused the timeout).
function Find-ShellSurfaces {
    $pids = @{}
    foreach ($n in 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost') {
        foreach ($p in (Get-Process $n -ErrorAction SilentlyContinue)) { $pids[[uint32]$p.Id] = $n }
    }
    $acc = New-Object System.Collections.Generic.List[object]
    $cb = [PX.W+EnumProc] {
        param($h, $l)
        $pid2 = [uint32]0; [void][PX.W]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pids.ContainsKey($pid2) -and [PX.W]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][PX.W]::GetClassNameW($h, $sb, 256)
            $r = New-Object PX.W+RECT
            [void][PX.W]::GetWindowRect($h, [ref]$r)
            $w = $r.right - $r.left; $ht = $r.bottom - $r.top
            # DWM cloak state: a cloaked window is the Start menu's persistent phantom, not an
            # opening - probe-start-windows.ps1 exists to tell those apart.
            $cloak = 0; [void][PX.W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
            # NO SIZE FILTER BEYOND A SANITY CAP. A shell CoreWindow is as large as the whole
            # virtual desktop (measured here: 5120x1392) and the menu is drawn as a CARD inside it -
            # the agent's own card walk reports exactly that shape. A 4096 cap excluded the real
            # subject, and the probe then said "no surfaces" in the same run where the FOREGROUND
            # window was one of them.
            if ($w -gt 16 -and $ht -gt 16 -and $w -le 16384 -and $ht -le 16384) {
                $acc.Add([pscustomobject]@{ h = $h; cls = $sb.ToString(); proc = $pids[$pid2];
                                            cloak = $cloak; x = $r.left; y = $r.top; w = $w; ht = $ht })
            }
        }
        return $true
    }
    [void][PX.W]::EnumWindows($cb, [IntPtr]::Zero)
    return $acc
}

Say ("startpixel session=" + [System.Diagnostics.Process]::GetCurrentProcess().SessionId + " user=" + (whoami) + " opener=" + $Opener)

# BEFORE: what exists with no menu open. The Start menu keeps a persistent, usually cloaked
# CoreWindow, so a surface in this list is NOT evidence of an opening.
$before = Find-ShellSurfaces
Say "BEFORE count=$($before.Count)"
foreach ($s in $before) { Say ("  B hwnd=0x{0:x} {1} {2} {3}x{4} at {5},{6} cloak={7}" -f $s.h.ToInt64(), $s.proc, $s.cls, $s.w, $s.ht, $s.x, $s.y, $s.cloak) }

Start-Sleep -Milliseconds 1200          # the task has just started - let the shell hold focus
switch ($Opener) {
    'ctrlesc'  { [PX.W]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [PX.W]::keybd_event(0x1B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [PX.W]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); [PX.W]::keybd_event(0x11,0,2,[UIntPtr]::Zero) }
    'shiftwin' { [PX.W]::keybd_event(0x10,0,0,[UIntPtr]::Zero); [PX.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)
                 Start-Sleep -Milliseconds 80
                 [PX.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero); [PX.W]::keybd_event(0x10,0,2,[UIntPtr]::Zero) }
    default    { [PX.W]::keybd_event(0x5B,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
                 [PX.W]::keybd_event(0x5B,0,2,[UIntPtr]::Zero) }
}

# POLL for an UNCLOAKED surface rather than sampling once after a guessed delay: the menu takes
# 560-580 ms to exist on this class of guest.
$after = @(); $elapsed = 0
while ($elapsed -lt $WaitMs) {
    Start-Sleep -Milliseconds 100; $elapsed += 100
    $after = @(Find-ShellSurfaces | Where-Object { $_.cloak -eq 0 })
    if ($after.Count -gt 0) { break }
}

# WHAT ACTUALLY TOOK THE FOREGROUND. Without this, "no CoreWindow" cannot be told apart from "a
# different menu opened" - and on this guest that difference is the whole answer.
$fg = [PX.W]::GetForegroundWindow()
$fsb = New-Object System.Text.StringBuilder 256
[void][PX.W]::GetClassNameW($fg, $fsb, 256)
$fpid = [uint32]0; [void][PX.W]::GetWindowThreadProcessId($fg, [ref]$fpid)
$fproc = (Get-Process -Id $fpid -ErrorAction SilentlyContinue)
Say ("FOREGROUND hwnd=0x{0:x} class={1} proc={2}" -f $fg.ToInt64(), $fsb.ToString(), $(if ($fproc) { $fproc.ProcessName } else { "pid$fpid" }))
Say "AFTER count=$($after.Count) opener=$Opener found_after_ms=$elapsed"

# SAMPLE WHAT ACTUALLY OPENED, even if the enumeration missed it. The foreground window is the
# one the user is looking at; if it is a shell CoreWindow it belongs in the list whatever the
# enumeration thought. Deduped by handle.
if ($fsb.ToString() -eq 'Windows.UI.Core.CoreWindow' -and -not ($after | Where-Object { $_.h -eq $fg })) {
    $fr = New-Object PX.W+RECT
    [void][PX.W]::GetWindowRect($fg, [ref]$fr)
    $fcloak = 0; [void][PX.W]::DwmGetWindowAttribute($fg, 14, [ref]$fcloak, 4)
    $after = @($after) + @([pscustomobject]@{ h = $fg; cls = $fsb.ToString();
        proc = $(if ($fproc) { $fproc.ProcessName } else { "pid$fpid" }); cloak = $fcloak;
        x = $fr.left; y = $fr.top; w = ($fr.right - $fr.left); ht = ($fr.bottom - $fr.top) })
    Say "  + added the FOREGROUND CoreWindow to the sample list (the enumeration had missed it)"
}
# MISSING DATA FAILS. No surface means the menu never opened, and a clean SP_DONE over zero
# samples would read as "measured, nothing wrong".
if (@($after).Count -eq 0) { Say 'SP_NOSURFACE no shell CoreWindow after the opener - nothing was measured'; throw 'no surface to sample' }

$t0 = @{}
foreach ($s in $after) {
    $r1 = Sample-Window $s.h $s.w $s.ht
    $t0[$s.h.ToInt64()] = $r1
    Say ("  T0 hwnd=0x{0:x} {1} {2} {3}x{4} at {5},{6} cloak={7} visible={8} pw_ok={9} nonblack={10}/{11} maxchannel={12} content_bbox={13}" -f `
        $s.h.ToInt64(), $s.proc, $s.cls, $s.w, $s.ht, $s.x, $s.y, $s.cloak, [PX.W]::IsWindowVisible($s.h), $r1.ok, $r1.nonblack, $r1.total, $r1.maxchannel, $r1.bbox)
}

Start-Sleep -Milliseconds $SecondSampleMs
foreach ($s in $after) {
    $r2 = Sample-Window $s.h $s.w $s.ht
    $d = $t0[$s.h.ToInt64()]
    Say ("  T1 hwnd=0x{0:x} {1} pw_ok={2} nonblack={3}/{4} maxchannel={5} content_bbox={6} (t0 was {7}/{8})" -f `
        $s.h.ToInt64(), $s.proc, $r2.ok, $r2.nonblack, $r2.total, $r2.maxchannel, $r2.bbox, $d.nonblack, $d.total)
}

# CLOSE IT, so the subject does not sit open on the operator's screen.
[PX.W]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[PX.W]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
Say 'SP_DONE'
}
catch { Say ("SP_ERROR " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
'@ | Set-Content -LiteralPath $inner -Encoding UTF8

$u = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $u) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'no autologon user' } | ConvertTo-Json -Compress; exit 2 }
& schtasks /delete /tn QwtStartPixel /f *>&1 | Out-Null
& schtasks /create /tn QwtStartPixel /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $inner" /sc once /st 00:00 /ru $u /it /f *>&1 | Out-Null
& schtasks /run /tn QwtStartPixel *>&1 | Out-Null

# Wait for a TERMINAL marker, never a fixed sleep and never "the file exists" - it is flushed at
# every stage now, so its presence says nothing about completion.
$deadline = (Get-Date).AddSeconds($TaskTimeoutSec); $got = ''; $txt = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path -LiteralPath $res) {
        $txt = (Get-Content -LiteralPath $res -ErrorAction SilentlyContinue) -join "`n"
        if ($txt -match 'SP_DONE') { $got = 'done'; break }
        if ($txt -match 'SP_ERROR') { $got = 'error'; break }
    }
}
& schtasks /delete /tn QwtStartPixel /f *>&1 | Out-Null
Write-Output '=== SAMPLES ==='
if ($txt) { Write-Output $txt } else { Write-Output 'NO OUTPUT AT ALL - the task wrote nothing' }
Write-Output '=== RESULT ==='
@{ ok = ($got -eq 'done'); outcome = $(if ($got) { $got } else { 'timeout' }); user = $u; opener = $Opener } | ConvertTo-Json -Compress
if ($got -ne 'done') { exit 1 }
