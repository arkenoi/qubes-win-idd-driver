# WHERE does an idle Windows desktop repaint? Measured INSIDE the guest.
#
# WHY IN-GUEST AND NOT FROM dom0.
# Two dom0-side attempts failed for instructive reasons:
#   - `qtest fullshot` returns the whole dom0 DESKTOP (5120x1440 here), so a diff of it is
#     dominated by whatever else is on the host screen - terminals, clocks, other qubes. It
#     measured the operator, not the guest.
#   - `qtest shot` returns only the guest's MAPPED WINDOWS, and in seamless mode with no app
#     window open that is an empty set. dom0 never sees the guest's wallpaper or taskbar.
# But the agent captures the guest's whole composited desktop through Desktop Duplication, so
# ambient repaint of surfaces dom0 never displays still costs us a present and a capture. The
# only instrument that sees what DDA sees is one running in the guest.
#
# Output is NUMBERS ONLY - bounding boxes and counts - not images. That keeps the transfer
# small enough to come back over qrexec stdout, and the untrusted guest returns data that is
# parsed rather than rendered.
[CmdletBinding()]
param(
    [int]$Samples = 40,
    # UNIFORM SAMPLING ALIASES. At a fixed 1500 ms this probe reported "zero changed cells"
    # on a desktop that had a BLINKING Windows Update notification on it: every sample landed
    # at the same phase of the blink, so the change was invisible. A periodic signal needs a
    # sampling interval that is short relative to its period AND jittered so it cannot lock on.
    [int]$GapMs = 250,
    [int]$JitterMs = 150,
    # Coarse grid: comparing every pixel of a 3440x1440 desktop in PowerShell would itself load
    # the guest enough to change what we are measuring. A 16 px cell is far finer than any
    # surface we are trying to tell apart (taskbar strip vs widget flyout vs window).
    [int]$Cell = 16
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Output ("SCREEN={0},{1},{2},{3}" -f $b.X, $b.Y, $b.Width, $b.Height)

# Window rects first, so a changed box can be attributed rather than eyeballed.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WEnum {
    public delegate bool Cb(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    public struct RECT { public int L, T, R, B; }
}
"@
$rows = New-Object System.Collections.ArrayList
$cb = [WEnum+Cb]{
    param($h, $p)
    if ([WEnum]::IsWindowVisible($h)) {
        $r = New-Object WEnum+RECT
        if ([WEnum]::GetWindowRect($h, [ref]$r)) {
            if (($r.R - $r.L) -gt 0 -and ($r.B - $r.T) -gt 0) {
                $cls = New-Object System.Text.StringBuilder 256
                [void][WEnum]::GetClassNameW($h, $cls, 256)
                $ttl = New-Object System.Text.StringBuilder 256
                [void][WEnum]::GetWindowTextW($h, $ttl, 256)
                # NOT $pid: that is a read-only PowerShell automatic variable and assigning
                # to it throws SessionStateUnauthorizedAccessException, which surfaces as a
                # misleading "Exception calling EnumWindows".
                $procId = 0; [void][WEnum]::GetWindowThreadProcessId($h, [ref]$procId)
                $pn = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '?' }
                [void]$rows.Add(("WIN {0} {1} {2},{3},{4},{5} {6}" -f $pn, $cls.ToString(),
                                 $r.L, $r.T, $r.R, $r.B, $ttl.ToString().Replace(' ', '_')))
            }
        }
    }
    return $true
}
[void][WEnum]::EnumWindows($cb, [IntPtr]::Zero)
$rows | ForEach-Object { Write-Output $_ }

function Grab {
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp
}

# Downsample to a grid of cell hashes. Reading pixels one at a time through GetPixel would be
# far too slow, so lock the bits once and walk the buffer.
function CellHashes([System.Drawing.Bitmap]$bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    # Stride can legitimately be NEGATIVE (bottom-up DIB) and is usually padded beyond
    # width*4. Both facts break naive base = y*stride indexing, which is what produced an
    # IndexOutOfRangeException here. Take the absolute value and walk rows from the correct
    # end rather than assuming a top-down, unpadded buffer.
    $stride = [Math]::Abs($data.Stride)
    $topDown = ($data.Stride -gt 0)
    $len = $stride * $bmp.Height
    $bytes = [byte[]]::new($len)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $len)
    $bmp.UnlockBits($data)

    $cols  = [int][Math]::Ceiling($bmp.Width  / [double]$Cell)
    $rowsN = [int][Math]::Ceiling($bmp.Height / [double]$Cell)
    # [int[]]::new is unambiguous; "New-Object int[] n" is parsed as constructor arguments
    # and does not reliably mean "an array of n elements".
    $h = [int[]]::new($cols * $rowsN)
    $maxPix = [int][Math]::Floor(($stride - 4) / 4)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $srcY = if ($topDown) { $y } else { $bmp.Height - 1 - $y }
        $cy = [int][Math]::Floor($y / [double]$Cell)
        $base = $srcY * $stride
        for ($x = 0; $x -lt $bmp.Width -and $x -le $maxPix; $x += 4) {
            $o = $base + $x * 4
            if ($o + 2 -ge $len) { break }
            $v = [int]$bytes[$o] -bxor ([int]$bytes[$o + 1] * 3) -bxor ([int]$bytes[$o + 2] * 7)
            $i = $cy * $cols + [int][Math]::Floor($x / [double]$Cell)
            if ($i -ge 0 -and $i -lt $h.Length) {
                $h[$i] = [int]((([long]$h[$i] * 31 + $v) -band 0x7FFFFFFF))
            }
        }
    }
    Write-Verbose ("geom w={0} h={1} stride={2} topdown={3} cols={4} rows={5} len={6}" -f `
                   $bmp.Width, $bmp.Height, $data.Stride, $topDown, $cols, $rowsN, $len)
    @{ h = $h; cols = $cols; rows = $rowsN }
}

$prev = $null
for ($s = 1; $s -le $Samples; $s++) {
    $bmp = Grab
    $cur = CellHashes $bmp
    $bmp.Dispose()
    if ($prev) {
        $minx = [int]::MaxValue; $miny = [int]::MaxValue; $maxx = -1; $maxy = -1; $n = 0
        for ($i = 0; $i -lt $cur.h.Length; $i++) {
            if ($cur.h[$i] -ne $prev.h[$i]) {
                $n++
                $cx = $i % $cur.cols; $cy = [int]($i / $cur.cols)
                if ($cx -lt $minx) { $minx = $cx }; if ($cx -gt $maxx) { $maxx = $cx }
                if ($cy -lt $miny) { $miny = $cy }; if ($cy -gt $maxy) { $maxy = $cy }
            }
        }
        if ($maxx -lt 0) {
            Write-Output ("DIFF {0} cells=0 box=none" -f $s)
        } else {
            Write-Output ("DIFF {0} cells={1} box={2},{3},{4},{5}" -f $s, $n,
                          ($minx * $Cell), ($miny * $Cell), (($maxx + 1) * $Cell), (($maxy + 1) * $Cell))
        }
    }
    $prev = $cur
    # jittered so a periodic repaint cannot alias to "nothing changed"
    Start-Sleep -Milliseconds ($GapMs + (Get-Random -Minimum 0 -Maximum ([Math]::Max(1,$JitterMs))))
}
Write-Output ("=== RESULT === samples={0} cell={1} gap={2}+jitter{3}ms" -f $Samples, $Cell, $GapMs, $JitterMs)
