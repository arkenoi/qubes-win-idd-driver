# window-truth-survey.ps1 - for EVERY mapped top-level window, report the three things that decide
# whether our capture routing got it right:
#
#   1. STRUCTURAL   - does it have a visible cross-process child covering >=80% of it (the old
#                     detector's opinion)?
#   2. CONTENT      - does PrintWindow WITHOUT PW_RENDERFULLCONTENT (the window's OWN surface)
#                     differ from PrintWindow WITH it (the composited truth)? If the own surface is
#                     effectively empty while the composited render has content, this window's
#                     pixels do NOT live in its own surface - which is what starves WGC.
#   3. TRUTH HASH   - a cheap signature of the composited render, so the caller can compare it with
#                     what dom0 actually shows for the same window and catch BOTH error directions:
#                       missed  = own-surface empty (would starve WGC) but we left it on WGC
#                       over    = routed to PrintWindow though its own surface carries the content
#
# Everything here is READ-ONLY and returns numbers and hashes, never pixels.
#
# -Hwnds "0x1234,0x5678" FORCES those windows to be measured regardless of the filters below.
# WHY: the filters (>=200x150, non-empty title, not DWM-cloaked) were written for a survey of
# ordinary app windows, and they silently drop exactly the windows the de-slice census cares about -
# toasts, small fixtures, untitled shell surfaces. On 2026-09-26 that produced FIVE broker slots with
# NO pixel row, and the acceptance rule is that missing data FAILS, so the pixel half could not be
# graded at all. A forced hwnd bypasses the filters; any forced hwnd that is never reached is
# reported as TRUTHMISSING so its absence is explicit rather than silent.
param([string]$Hwnds = "")
$forced = @{}
foreach ($t in ($Hwnds -split "[, ]+")) {
  if ($t -match "^0?[xX]?[0-9a-fA-F]+$" -and $t.Trim() -ne "") {
    try { $forced[[int64]("0x" + ($t -replace "^0[xX]",""))] = $false } catch {}
  }
}
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;using System.Text;
public class WT {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
 [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int a,out int v,int s);
 [StructLayout(LayoutKind.Sequential)] public struct RC { public int L,T,R,B; }
}
"@
function Render([IntPtr]$h,[int]$w,[int]$ht,[uint32]$flag) {
  $bmp = New-Object System.Drawing.Bitmap($w,$ht)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
  $ok = [WT]::PrintWindow($h,$dc,$flag); $g.ReleaseHdc($dc); $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); return $null }
  # distinct colours + a coarse hash, both sampled: enough to say "empty" and to compare renders
  $colors=@{}; $acc=0
  for ($y=0; $y -lt $ht; $y+=9) { for ($x=0; $x -lt $w; $x+=9) {
    $c=$bmp.GetPixel($x,$y).ToArgb(); $colors[$c]=1; $acc = ($acc*33 -bxor $c) -band 0x7FFFFFFF } }
  $bmp.Dispose()
  return @{ colours=$colors.Count; hash=$acc }
}
$out = New-Object System.Collections.ArrayList
# MEASURE ONE WINDOW. Factored out of the enumeration callback so a FORCED window can be measured
# DIRECTLY when EnumWindows never reaches it. Forcing previously bypassed only the FILTERS, not the
# enumeration, so a window the enumerator does not yield was reported `TRUTHMISSING
# reason=not-enumerated` and could not be graded at all - measured 2026-09-26 on the toast
# (Windows.UI.Core.CoreWindow), the run's only override-redirect representative, whose frames the
# broker was demonstrably publishing (PUBSIG colours=16) while the guest side reported nothing.
function Measure-Window([IntPtr]$h, [bool]$isForced) {
  if ($isForced) { $forced[[int64]$h] = $true }
  if (-not $isForced) {
    if (-not [WT]::IsWindowVisible($h) -or [WT]::IsIconic($h)) { return $true }
  }
  $r = New-Object WT+RC; if (-not [WT]::GetWindowRect($h,[ref]$r)) { return $true }
  $w=$r.R-$r.L; $ht=$r.B-$r.T
  $ti = New-Object System.Text.StringBuilder 256; [void][WT]::GetWindowTextW($h,$ti,256)
  if (-not $isForced) {
    if ($w -lt 200 -or $ht -lt 150) { return $true }
    if ($ti.ToString().Trim() -eq '') { return $true }
    $cloak=0; [void][WT]::DwmGetWindowAttribute($h,14,[ref]$cloak,4); if ($cloak -ne 0) { return $true }
  }
  if ($w -le 0 -or $ht -le 0) { return $true }
  $cl = New-Object System.Text.StringBuilder 256; [void][WT]::GetClassName($h,$cl,256)
  $pid0=0; [void][WT]::GetWindowThreadProcessId($h,[ref]$pid0)
  $exe = try { (Get-Process -Id $pid0 -ErrorAction Stop).ProcessName } catch { '?' }
  # CANDIDATE PREDICATES, all evaluated in ONE pass over the same children, so they are scored
  # against the same ground truth on the same real windows. Iterating here costs a survey run;
  # iterating in the broker costs a build plus a deploy. Only the winner gets ported to C++.
  #   A = shipped: a visible cross-process child covering >=80% of the frame
  #   B = any visible cross-process child at all, no area threshold
  #   C = a cross-process child whose class is Windows.UI.Core.CoreWindow
  #   D = the top-level's own class is ApplicationFrameWindow
  #   E = C or D   (class-driven, ignores geometry entirely)
  $script:xproc = 'no'; $script:anyx = 'no'; $script:corew = 'no'
  $child = [WT+EnumProc]{
    param($c,$l2)
    if (-not [WT]::IsWindowVisible($c)) { return $true }
    $cp=0; [void][WT]::GetWindowThreadProcessId($c,[ref]$cp)
    if ($cp -eq 0 -or $cp -eq $pid0) { return $true }
    $script:anyx = 'yes'
    $ccl = New-Object System.Text.StringBuilder 256; [void][WT]::GetClassName($c,$ccl,256)
    if ($ccl.ToString() -eq 'Windows.UI.Core.CoreWindow') { $script:corew = 'yes' }
    $cr = New-Object WT+RC; if (-not [WT]::GetWindowRect($c,[ref]$cr)) { return $true }
    if (($cr.R-$cr.L)*100 -ge $w*80 -and ($cr.B-$cr.T)*100 -ge $ht*80) { $script:xproc='yes' }
    return $true
  }
  [void][WT]::EnumChildWindows($h,$child,[IntPtr]::Zero)
  $isAfw = if ($cl.ToString() -eq 'ApplicationFrameWindow') { 'yes' } else { 'no' }
  $predE = if ($script:corew -eq 'yes' -or $isAfw -eq 'yes') { 'yes' } else { 'no' }
  $own  = Render $h $w $ht 0
  $full = Render $h $w $ht 2
  $ownC  = if ($own)  { $own.colours }  else { -1 }
  $fullC = if ($full) { $full.colours } else { -1 }
  $fullH = if ($full) { $full.hash }    else { 0 }
  # "starves WGC": its own surface carries (almost) nothing while the composited render does
  $starves = if ($ownC -ge 0 -and $fullC -ge 0 -and $ownC -le 2 -and $fullC -gt 8) { 'yes' } else { 'no' }
  [void]$out.Add(("TRUTH`thwnd=0x{0:x}`texe={1}`tclass={2}`t{3}x{4}`tA={5}`tB={6}`tC={7}`tD={8}`tE={9}`townColours={10}`tfullColours={11}`tstarvesWgc={12}`thash={13}`ttitle={14}" -f `
    $h.ToInt64(),$exe,$cl.ToString(),$w,$ht,$script:xproc,$script:anyx,$script:corew,$isAfw,$predE,`
    $ownC,$fullC,$starves,$fullH,$ti.ToString().Substring(0,[Math]::Min(30,$ti.Length))))
  return $true
}
$cb = [WT+EnumProc]{
  param($h,$l)
  $null = Measure-Window $h ($forced.ContainsKey([int64]$h))
  return $true
}
[void][WT]::EnumWindows($cb,[IntPtr]::Zero)

# DIRECT PASS over anything the enumerator did not yield. IsWindow is the only precondition: if the
# handle is still valid the window can be rendered and measured exactly as an enumerated one is.
foreach ($k in @($forced.Keys)) {
  if ($forced[$k]) { continue }
  $hh = [IntPtr]$k
  if ([WT]::IsWindow($hh)) { $null = Measure-Window $hh $true }
}
# Absence must be explicit: a forced hwnd EnumWindows never reached is named, not omitted.
foreach ($k in $forced.Keys) {
  if (-not $forced[$k]) { [void]$out.Add(("TRUTHMISSING`thwnd=0x{0:x}`treason=not-enumerated" -f $k)) }
}
$out | ForEach-Object { Write-Output $_ }
Write-Output ("TRUTHCOUNT=" + $out.Count)
