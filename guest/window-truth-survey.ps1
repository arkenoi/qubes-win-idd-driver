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
param([string]$Hwnds = "", [string]$Cards = "")
$forced = @{}
# -Cards "0x1234:x:y:w:h,..." = the CARD the agent requested for each window (the broker peek's crop=x,y and
# req=wxh). The broker publishes only that sub-rect of the window, so a truth grid over the WHOLE window is
# offset and rescaled against it wherever the card is cropped: measured 2026-09-27, the toast host (card
# 364x326 at 16,~29 of 396x369) scored MAD 13.7 whole-window and 6.3 once re-aligned on the same data. The
# card grid is cut from the SAME render as the full one, so the stability test below covers both.
# NOT $cards: PowerShell variable names are case-INSENSITIVE, so a table named $cards IS the -Cards
# parameter and assigning it erased the string before it was parsed (every card came back cardFit=none).
$cardMap = @{}
foreach ($t in ($Cards -split "[, ]+")) {
  if ($t -match "^0?[xX]?([0-9a-fA-F]+):(\d+):(\d+):(\d+):(\d+)$") {
    try { $cardMap[[int64]("0x" + $matches[1])] = @([int]$matches[2],[int]$matches[3],[int]$matches[4],[int]$matches[5]) } catch {}
  }
}
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
# A 32x32 grid of per-tile mean RGB over the sub-rect (rx,ry,rw,rh) of a BGRA buffer.
function TileGrid([byte[]]$buf,[int]$stride,[int]$rx,[int]$ry,[int]$rw,[int]$rh) {
  $T = 32
  $tiles = New-Object byte[] ($T*$T*3)
  for ($ty=0; $ty -lt $T; $ty++) {
    $y0 = $ry + [int]([int64]$ty*$rh/$T); $y1 = $ry + [int]([int64]($ty+1)*$rh/$T)
    if ($y1 -le $y0) { $y1 = $y0+1 }; if ($y1 -gt $ry+$rh) { $y1 = $ry+$rh }
    for ($tx=0; $tx -lt $T; $tx++) {
      $x0 = $rx + [int]([int64]$tx*$rw/$T); $x1 = $rx + [int]([int64]($tx+1)*$rw/$T)
      if ($x1 -le $x0) { $x1 = $x0+1 }; if ($x1 -gt $rx+$rw) { $x1 = $rx+$rw }
      $sr=0; $sg=0; $sb=0; $n=0
      for ($yy=$y0; $yy -lt $y1; $yy+=2) {
        $ro2 = $yy*$stride
        for ($xx=$x0; $xx -lt $x1; $xx+=2) {
          $o2 = $ro2 + $xx*4
          $sb += [int]$buf[$o2]; $sg += [int]$buf[$o2+1]; $sr += [int]$buf[$o2+2]; $n++ } }
      $o = (($ty*$T)+$tx)*3
      if ($n -gt 0) { $tiles[$o]=[byte]($sr/$n); $tiles[$o+1]=[byte]($sg/$n); $tiles[$o+2]=[byte]($sb/$n) }
    }
  }
  return [Convert]::ToBase64String($tiles)
}
function Render([IntPtr]$h,[int]$w,[int]$ht,[uint32]$flag,$card = $null) {
  $bmp = New-Object System.Drawing.Bitmap($w,$ht)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
  $ok = [WT]::PrintWindow($h,$dc,$flag); $g.ReleaseHdc($dc); $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); return $null }
  # ONE LockBits READ INSTEAD OF PER-PIXEL GetPixel. The tile grid below samples on the order of
  # 100k points on a large window, and GetPixel crosses into GDI+ on every call - measured cost on a
  # 1115x628 window would be seconds per render, several windows and two renders each, against a 340 s
  # census budget. Reading the bitmap once into a byte array makes the whole pass arithmetic.
  $rect = New-Object System.Drawing.Rectangle 0,0,$w,$ht
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $buf = New-Object byte[] ([Math]::Abs($stride) * $ht)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
  $bmp.UnlockBits($data)
  # distinct colours + a coarse hash, both sampled: enough to say "empty" and to compare renders.
  # BGRA in memory; the hash keeps using the ARGB int so it stays comparable with earlier records.
  $colors=@{}; $acc=0
  for ($y=0; $y -lt $ht; $y+=9) {
    $ro = $y*$stride
    for ($x=0; $x -lt $w; $x+=9) {
      $o = $ro + $x*4
      $c = ([int]$buf[$o+3] -shl 24) -bor ([int]$buf[$o+2] -shl 16) -bor ([int]$buf[$o+1] -shl 8) -bor [int]$buf[$o]
      $colors[$c]=1; $acc = ($acc*33 -bxor $c) -band 0x7FFFFFFF } }
  # A 32x32 GRID OF PER-TILE MEAN RGB, the same reduction the broker publishes for the frame it
  # actually delivered (ABI 13 PubTiles). Both sides normalise to this fixed grid regardless of their
  # own dimensions - but that makes them comparable only where the two cover the SAME region. The
  # broker publishes the agent's CARD, a crop of the window; against a cropped card the whole-window
  # grid is offset and rescaled (measured 2026-09-27: toast host MAD 13.7 whole-window, 6.3 re-aligned).
  # So the card is now passed in (-Cards) and graded on its own grid; the full grid stays for the rest. A distinct-colour count cannot tell a correct frame from the same
  # palette arranged wrongly, a shifted image, or a blank region; 1024 tile means can. ALPHA IS
  # EXCLUDED deliberately - the two sides need not agree on it and the GUI protocol carries none.
  # Jev chose this instrument at confidence 1.00.
  $full = TileGrid $buf $stride 0 0 $w $ht
  # The card grid, when the agent's card for this window is known and lies inside the render. A card
  # outside it is reported as such (cardFit=no), never silently replaced by the whole-window grid.
  $cardT = ''; $cardFit = 'none'; $cardC = -1
  if ($card) {
    $cx,$cy,$cw,$ch = $card
    if ($cw -gt 0 -and $ch -gt 0 -and $cx -ge 0 -and $cy -ge 0 -and ($cx+$cw) -le $w -and ($cy+$ch) -le $ht) {
      $cardT = TileGrid $buf $stride $cx $cy $cw $ch; $cardFit = 'yes'
      # The card's distinct-colour count, sampled exactly as the broker samples the card it publishes
      # (every 9th pixel from the card's own origin) - the whole-window count this was compared with
      # passed the toast's stale two-card frame (26 vs 28) and failed its correct card (15 vs 28).
      $cc=@{}
      for ($y=$cy; $y -lt $cy+$ch; $y+=9) { $ro = $y*$stride
        for ($x=$cx; $x -lt $cx+$cw; $x+=9) { $o = $ro + $x*4
          $cc[(([int]$buf[$o+3] -shl 24) -bor ([int]$buf[$o+2] -shl 16) -bor ([int]$buf[$o+1] -shl 8) -bor [int]$buf[$o])]=1 } }
      $cardC = $cc.Count
    } else { $cardFit = 'no' }
  }
  $bmp.Dispose()
  return @{ colours=$colors.Count; hash=$acc; tiles=$full; cardTiles=$cardT; cardFit=$cardFit; cardColours=$cardC }
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
  # FREEZE-THEN-COMPARE. A transient surface - a toast above all - can change WHILE it is being measured,
  # and the broker's grid is sampled at a different instant, so a fidelity comparison against a single
  # render of a moving surface measures the motion, not the delivery. Rendering twice and requiring the
  # two reductions to be IDENTICAL establishes that the surface was momentarily STILL, which is the only
  # state in which comparing it to a frame captured at another instant says anything. (CORRECTED
  # 2026-09-27: this was first justified by the toast's MAD 13.7. That score was NOT motion - it repeated
  # to the decimal on three cold boots with the surface proven still (tilesStable=1); it was the whole-
  # window grid graded against the cropped card, see -Cards. The check stays as a precaution.) Up to three attempts; the row
  # carries tilesStable so the caller can refuse to grade an unstable surface rather than score noise.
  # Jev chose this over best-of-N sampling and a timestamped grid (0.76).
  $card = $cardMap[[int64]$h]
  $full = Render $h $w $ht 2 $card
  $stable = 0
  for ($try = 0; $try -lt 3 -and $stable -eq 0; $try++) {
    $again = Render $h $w $ht 2 $card
    if ($full -and $again -and $full.tiles -eq $again.tiles) { $stable = 1 }
    if ($again) { $full = $again }
  }
  $ownC  = if ($own)  { $own.colours }  else { -1 }
  $fullC = if ($full) { $full.colours } else { -1 }
  $fullH = if ($full) { $full.hash }    else { 0 }
  # The COMPOSITED render's tile grid is what gets compared against the broker's delivered frame.
  # Emitted as its own tab field so the row stays parseable, and omitted (not faked) when the render
  # failed - a missing grid must read as missing, never as a match.
  $fullT = if ($full) { $full.tiles }   else { '' }
  $cardTiles = if ($full) { $full.cardTiles } else { '' }
  $cardFit   = if ($full) { $full.cardFit }   else { 'none' }
  $cardColours = if ($full) { $full.cardColours } else { -1 }
  # "starves WGC": its own surface carries (almost) nothing while the composited render does
  $starves = if ($ownC -ge 0 -and $fullC -ge 0 -and $ownC -le 2 -and $fullC -gt 8) { 'yes' } else { 'no' }
  [void]$out.Add(("TRUTH`thwnd=0x{0:x}`texe={1}`tclass={2}`t{3}x{4}`tA={5}`tB={6}`tC={7}`tD={8}`tE={9}`townColours={10}`tfullColours={11}`tstarvesWgc={12}`thash={13}`ttilesFull={15}`ttilesStable={16}`ttilesCard={17}`tcardFit={18}`tcardColours={19}`ttitle={14}" -f `
    $h.ToInt64(),$exe,$cl.ToString(),$w,$ht,$script:xproc,$script:anyx,$script:corew,$isAfw,$predE,`
    $ownC,$fullC,$starves,$fullH,$ti.ToString().Substring(0,[Math]::Min(30,$ti.Length)),$fullT,$stable,$cardTiles,$cardFit,$cardColours))
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
  else {
    # MEASURED, NOT ASSUMED. A handle the enumerator did not yield AND which IsWindow now rejects is a
    # window that was DESTROYED between the route census reading the slots and this survey running - a
    # transient, not a statement about the relay. Reporting that as plain missing data made a closed
    # Terminal window read as a fidelity failure. The distinction is only ever drawn from IsWindow
    # returning false here; a handle that is still valid is never called "gone" (Jev 0.64, on the
    # explicit condition that it be measured).
    [void]$out.Add(("TRUTHMISSING`thwnd=0x{0:x}`treason=window-gone" -f $k))
  }
}
# Absence must be explicit: a forced hwnd EnumWindows never reached is named, not omitted.
foreach ($k in $forced.Keys) {
  if (-not $forced[$k]) { [void]$out.Add(("TRUTHMISSING`thwnd=0x{0:x}`treason=not-enumerated" -f $k)) }
}
$out | ForEach-Object { Write-Output $_ }
Write-Output ("TRUTHCOUNT=" + $out.Count)
