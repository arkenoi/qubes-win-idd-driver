# Do the two pixel sources agree? (hybrid-capture-design.md section 2.4)
#
# WHY THIS IS A SHIP BLOCKER, not a curiosity.
# DDA-sourced capture copies a window's pixels out of the COMPOSITED desktop. PrintWindow
# renders the window itself, unblended. The design named this as its main risk and prescribed
# measuring it BEFORE implementing; that was skipped, and the first implementation "handled" it
# by re-capturing from PrintWindow every 2 s - which turned any difference into a visible 0.5 Hz
# flicker (observed: window cycling normal -> wrong -> normal).
#
# Removing the periodic re-establish removed the flicker, and that made the risk WORSE, not
# better: a systematic difference now shows as persistently wrong content for as long as the
# window stays DDA-sourced, with nothing to signal it. Better benchmark, worse failure mode.
#
# So: capture the same window both ways, in the same instant as far as possible, and report
# where and how much they differ. Numbers only - the guest is untrusted and this returns data,
# not images.
#
# Candidate differences the design calls out, and what each looks like here:
#   alpha byte        -> RGB identical, alpha differs (harmless: the daemon composites RGB)
#   rounded corners   -> differences confined to ~8x8 px at the four corners
#   DWM effects       -> differences on the title bar / frame only
#   composited cursor -> a small cluster wherever the pointer is
#   something else    -> differences spread across the client area == DO NOT SHIP
[CmdletBinding()]
param([string]$WindowTitle = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class PX {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")]  public static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, int rop);
    public struct RECT { public int L, T, R, B; }
}
"@

$hwnd = [PX]::GetForegroundWindow()
if ($WindowTitle) {
    $p = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" } | Select-Object -First 1
    if ($p) { $hwnd = $p.MainWindowHandle }
}
$sb = New-Object System.Text.StringBuilder 256
[void][PX]::GetWindowTextW($hwnd, $sb, 256)
$r = New-Object PX+RECT
[void][PX]::GetWindowRect($hwnd, [ref]$r)
$w = $r.R - $r.L; $h = $r.B - $r.T
Write-Output ("WINDOW=" + $sb.ToString().Replace(' ','_') + " rect=" + $r.L + "," + $r.T + "," + $r.R + "," + $r.B + " size=${w}x${h}")
if ($w -le 0 -or $h -le 0) { Write-Output "RESULT=FAIL bad window rect"; exit 1 }

# A: PrintWindow - the window rendered by itself
$bmpP = New-Object System.Drawing.Bitmap $w, $h
$gP = [System.Drawing.Graphics]::FromImage($bmpP)
$hdcP = $gP.GetHdc()
$okP = [PX]::PrintWindow($hwnd, $hdcP, 2)   # PW_RENDERFULLCONTENT
$gP.ReleaseHdc($hdcP); $gP.Dispose()
Write-Output ("PRINTWINDOW_OK=" + $okP)

# B: the composited desktop, same rect - what DDA would copy
$bmpS = New-Object System.Drawing.Bitmap $w, $h
$gS = [System.Drawing.Graphics]::FromImage($bmpS)
$gS.CopyFromScreen($r.L, $r.T, 0, 0, $bmpS.Size)
$gS.Dispose()

function Lock($bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                       [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = [Math]::Abs($d.Stride)
    $buf = New-Object byte[] ($stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $buf.Length)
    $bmp.UnlockBits($d)
    @{ b = $buf; stride = $stride }
}
$A = Lock $bmpP; $B = Lock $bmpS
$bmpP.Dispose(); $bmpS.Dispose()

$diffRGB = 0; $diffA = 0; $total = 0; $maxd = 0
$edge = 0; $corner = 0; $interior = 0
$CORNER = 10; $EDGE = 3
for ($y = 0; $y -lt $h; $y++) {
    $rowA = $y * $A.stride; $rowB = $y * $B.stride
    for ($x = 0; $x -lt $w; $x += 2) {          # every 2nd pixel: plenty for a verdict
        $oa = $rowA + $x * 4; $ob = $rowB + $x * 4
        $total++
        $db = [Math]::Abs([int]$A.b[$oa]   - [int]$B.b[$ob])
        $dg = [Math]::Abs([int]$A.b[$oa+1] - [int]$B.b[$ob+1])
        $dr = [Math]::Abs([int]$A.b[$oa+2] - [int]$B.b[$ob+2])
        $da = [Math]::Abs([int]$A.b[$oa+3] - [int]$B.b[$ob+3])
        if ($da -ne 0) { $diffA++ }
        $m = [Math]::Max($db, [Math]::Max($dg, $dr))
        if ($m -ne 0) {
            $diffRGB++
            if ($m -gt $maxd) { $maxd = $m }
            $nearL = ($x -lt $CORNER); $nearR = ($x -ge $w - $CORNER)
            $nearT = ($y -lt $CORNER); $nearB = ($y -ge $h - $CORNER)
            if (($nearL -or $nearR) -and ($nearT -or $nearB)) { $corner++ }
            elseif ($x -lt $EDGE -or $x -ge $w-$EDGE -or $y -lt $EDGE -or $y -ge $h-$EDGE) { $edge++ }
            else { $interior++ }
        }
    }
}
$pct = if ($total) { $diffRGB / $total * 100 } else { 0 }
Write-Output ("SAMPLED=$total")
Write-Output ("RGB_DIFF=$diffRGB ({0:N3}%)" -f $pct)
Write-Output ("ALPHA_DIFF=$diffA")
Write-Output ("MAX_CHANNEL_DELTA=$maxd")
Write-Output ("WHERE corner=$corner edge=$edge interior=$interior")
if ($diffRGB -eq 0) {
    Write-Output "RESULT=IDENTICAL - the two sources agree; DDA capture is safe on this content"
} elseif ($interior -eq 0) {
    Write-Output "RESULT=EDGES_ONLY - differences confined to the frame/corners (rounded corners or DWM chrome)"
} else {
    Write-Output "RESULT=INTERIOR_DIFFERS - client area disagrees; DDA capture would show wrong content. DO NOT SHIP."
}
