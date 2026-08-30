# CONTINUOUS TOP-LEVEL SURFACE SAMPLER — the instrument RND-3/RND-4/SG cells needed and did not have.
#
# WHY THIS EXISTS. On 2026-08-30 I recorded "the toast never rendered" from an ad-hoc probe. The
# owner was watching the screen: the toast WAS there. Three faults, and this script exists to make
# each of them impossible:
#
#   1. POINT SAMPLING. The probe looked once, a few seconds after firing a scheduled task with its
#      own start latency. A toast lives ~5 s. One sample either side of an unmeasured delay is not
#      a search. -> This SAMPLES CONTINUOUSLY and reports coverage gaps, like reboot-dialog-watch.
#   2. A NARROW FILTER. It required the owning process to be ShellExperienceHost et al., or the
#      class to match CoreWindow|Toast|Flyout. Anything presenting otherwise was invisible, and a
#      filter miss was read as an absence. -> This records EVERY visible top-level window and
#      filters at ANALYSIS time, where a wrong filter can be corrected without re-running the guest.
#   3. NO VALIDATION. The detector had never been seen to fire on a known-present instance, yet its
#      silence was used as evidence. The protocol demands seen-to-fail proof of the product's
#      checks; I exempted my own. -> -SelfTest creates a window with known attributes and PROVES
#      the sampler sees it. A negative from this script is only citable when detector_fires=true
#      was recorded in the same session.
#
# Output: JSONL, one record per sample, each a full snapshot. -Summary analyses an existing log.
#
#   guest/surface-watch.ps1 -DurationSeconds 120 -IntervalSeconds 1
#   guest/surface-watch.ps1 -SelfTest
#   guest/surface-watch.ps1 -Summary [-Match 'regex']
param(
    [string]$OutFile         = 'C:\qwt-improved-setup\surface-watch.jsonl',
    [int]   $IntervalSeconds = 1,
    [int]   $DurationSeconds = 120,     # BOUNDED. Never runs forever.
    [switch]$Summary,
    [switch]$SelfTest,
    [string]$Match           = ''
)
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class SurfEnum {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  // CharSet.Unicode is load-bearing: with Ansi, GetWindowText truncated every title to one
  // character for an entire session on this rig.
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int  GetWindowLongW(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

function Get-Surfaces {
    $rows = New-Object System.Collections.ArrayList
    $cb = [SurfEnum+EnumProc]{
        param($h, $l)
        # EVERY visible top-level window. No subject filter here, deliberately.
        if ([SurfEnum]::IsWindowVisible($h)) {
            $t = New-Object Text.StringBuilder 512; [void][SurfEnum]::GetWindowTextW($h, $t, 512)
            $c = New-Object Text.StringBuilder 512; [void][SurfEnum]::GetClassNameW($h, $c, 512)
            $pid = 0; [void][SurfEnum]::GetWindowThreadProcessId($h, [ref]$pid)
            $pn = ''
            try { $pn = (Get-Process -Id $pid -ErrorAction Stop).ProcessName } catch { $pn = '?' }
            $style = [SurfEnum]::GetWindowLongW($h, -16)
            $ex    = [SurfEnum]::GetWindowLongW($h, -20)
            $r = New-Object SurfEnum+RECT; [void][SurfEnum]::GetWindowRect($h, [ref]$r)
            $cloaked = 0; [void][SurfEnum]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)   # DWMWA_CLOAKED
            $alpha = 255
            if ($ex -band 0x80000) { $k=0; [byte]$a=0; $f=0; if ([SurfEnum]::GetLayeredWindowAttributes($h,[ref]$k,[ref]$a,[ref]$f)) { $alpha = $a } }
            [void]$rows.Add([ordered]@{
                hwnd    = ('0x{0:X}' -f $h.ToInt64())
                cls     = $c.ToString()
                title   = $t.ToString()
                proc    = $pn
                style   = ('0x{0:X8}' -f $style)
                ex      = ('0x{0:X8}' -f $ex)
                rect    = ('{0},{1} {2}x{3}' -f $r.L, $r.T, ($r.R-$r.L), ($r.B-$r.T))
                owner   = ('0x{0:X}' -f ([SurfEnum]::GetWindow($h,4)).ToInt64())
                topmost = [bool]($ex -band 0x8)
                layered = [bool]($ex -band 0x80000)
                transp  = [bool]($ex -band 0x20)
                toolwin = [bool]($ex -band 0x80)
                appwin  = [bool]($ex -band 0x40000)
                noact   = [bool]($ex -band 0x8000000)
                caption = [bool]($style -band 0x00C00000)
                popup   = [bool]($style -band 0x80000000)
                cloaked = $cloaked
                alpha   = $alpha
            })
        }
        return $true
    }
    [void][SurfEnum]::EnumWindows($cb, [IntPtr]::Zero)
    return $rows
}

# ---------------------------------------------------------------- SELFTEST
if ($SelfTest) {
    # Prove the sampler SEES a window with known attributes. Without this a silence from this
    # script means nothing, and citing it would repeat the exact error it was written for.
    $OutFile = [IO.Path]::ChangeExtension($OutFile, '.selftest.jsonl')
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Type -AssemblyName System.Windows.Forms
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'QWT-SURFACE-SELFTEST'; $f.Width = 320; $f.Height = 120
    $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.Show(); $f.Refresh()
    Start-Sleep -Milliseconds 700
    $seen = @(Get-Surfaces | Where-Object { $_.title -eq 'QWT-SURFACE-SELFTEST' })
    $f.Close(); $f.Dispose()
    $res = [ordered]@{
        detector_fires = ($seen.Count -gt 0)
        matched        = @($seen | ForEach-Object { $_.hwnd + ' ' + $_.cls + ' topmost=' + $_.topmost })
        file           = $OutFile
        note           = 'a negative from surface-watch is only citable when this is true in the same session'
    }
    ($res | ConvertTo-Json -Compress) | Set-Content -LiteralPath $OutFile -Encoding ASCII
    Write-Output ('=== SURFACEWATCH-SELFTEST === ' + ($res | ConvertTo-Json -Compress))
    if ($res.detector_fires) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------- SUMMARY
if ($Summary) {
    if (-not (Test-Path -LiteralPath $OutFile)) {
        Write-Output ('=== SURFACEWATCH === ' + (@{ ok=$false; reason=("no log at " + $OutFile) } | ConvertTo-Json -Compress)); exit 1
    }
    $lines = Get-Content -LiteralPath $OutFile
    $samples = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
    if ($samples.Count -eq 0) {
        Write-Output ('=== SURFACEWATCH === ' + (@{ ok=$false; reason='log present but no parsable samples' } | ConvertTo-Json -Compress)); exit 1
    }
    # Coverage gaps: a sampler that stalled cannot support a negative.
    $times = @($samples | ForEach-Object { [datetime]$_.ts })
    $gaps = @()
    for ($i=1; $i -lt $times.Count; $i++) {
        $d = ($times[$i] - $times[$i-1]).TotalSeconds
        if ($d -gt ($IntervalSeconds * 4)) { $gaps += ('{0:N1}s at {1:o}' -f $d, $times[$i-1]) }
    }
    $allw = @($samples | ForEach-Object { $_.windows } | Where-Object { $_ })
    $hits = @()
    if ($Match) { $hits = @($allw | Where-Object { $_.title -match $Match -or $_.cls -match $Match -or $_.proc -match $Match }) }
    $distinct = @($allw | Group-Object hwnd | ForEach-Object {
        $w = $_.Group[0]
        [ordered]@{ hwnd=$w.hwnd; cls=$w.cls; title=$w.title; proc=$w.proc; topmost=$w.topmost;
                    layered=$w.layered; transp=$w.transp; toolwin=$w.toolwin; cloaked=$w.cloaked;
                    alpha=$w.alpha; caption=$w.caption; rect=$w.rect; seen_in_samples=$_.Count }
    })
    $res = [ordered]@{
        ok             = ($gaps.Count -eq 0)
        samples        = $samples.Count
        first          = $times[0].ToString('o')
        last           = $times[-1].ToString('o')
        coverage_gaps  = $gaps
        distinct_hwnds = $distinct.Count
        match          = $Match
        match_hits     = $hits.Count
        reason         = if ($gaps.Count) { 'coverage gaps - a negative from this run is NOT citable' } else { 'continuous coverage' }
    }
    Write-Output ('=== SURFACEWATCH === ' + ($res | ConvertTo-Json -Compress -Depth 4))
    foreach ($d in $distinct) { Write-Output ('  W ' + ($d | ConvertTo-Json -Compress)) }
    exit 0
}

# ---------------------------------------------------------------- SAMPLE
$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $deadline) {
    $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); windows = @(Get-Surfaces) }
    ($rec | ConvertTo-Json -Compress -Depth 4) | Add-Content -LiteralPath $OutFile -Encoding ASCII
    Start-Sleep -Seconds $IntervalSeconds
}
Write-Output ('=== SURFACEWATCH-DONE === ' + $OutFile)
