# Generic FPS test - a plain GDI+ animation with NO dependency on our instrumentation, so it
# runs identically on stock QWT and on ours and is genuinely CROSS-SIDE comparable. Every
# other frame-rate figure we have (QGAPERF) exists only on our side by construction.
#
# It reports two different things, and the distinction is the whole point:
#   rendered_fps   frames the application actually painted in the guest
#   (dom0 side)    distinct frames that reached dom0 - measured separately by the harness
# The RATIO is what matters. A guest can paint 200 fps while dom0 sees 12; that gap is the
# agent's capture/send path, which is exactly what this project changes. Rendered fps alone
# would mostly measure Windows' GDI, not us.
#
# MUST run in the INTERACTIVE session. Under a session-0 task there is no compositor, the
# form never becomes visible, and both sides read a meaningless number.
param(
    [int]$Seconds = 10,
    [int]$Width   = 800,
    [int]$Height  = 600,
    [string]$Mode = 'move'   # move = moving block (dirty-rect friendly), full = full repaint
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Refuse to produce a number that cannot mean anything, rather than emitting a plausible one.
$sid = (Get-Process -Id $PID).SessionId
if ($sid -eq 0) {
    Write-Output "FPSRESULT {""error"":""running in session 0 - no interactive desktop, refusing to measure""}"
    exit 2
}

$form              = New-Object System.Windows.Forms.Form
$form.Text         = 'QubesFpsTest'
$form.Width        = $Width
$form.Height       = $Height
$form.StartPosition = 'Manual'
$form.Location     = New-Object System.Drawing.Point(40, 40)
$form.BackColor    = [System.Drawing.Color]::Black
$form.TopMost      = $true

$script:frames = 0
# Per-frame intervals are the DELAY half of this measurement. Throughput alone hides
# stutter: 300 fps average with a 90 ms hitch every second feels worse than a steady
# 120 fps, and it is the p95/p99 tail a user actually perceives.
$script:ivals = New-Object System.Collections.Generic.List[double]
$script:x      = 0
$script:dir    = 7
$brush         = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 200, 255))

$form.Add_Paint({
    param($s, $e)
    if ($Mode -eq 'full') {
        # Full repaint: worst case for a capture path that sends whole frames.
        $c = [System.Drawing.Color]::FromArgb(($script:frames * 7) % 256,
                                              ($script:frames * 13) % 256,
                                              ($script:frames * 3) % 256)
        $e.Graphics.Clear($c)
    } else {
        # Moving block: small dirty rectangle, the case dirty-rect batching should win on.
        $e.Graphics.Clear([System.Drawing.Color]::Black)
        $e.Graphics.FillRectangle($brush, $script:x, 100, 120, 120)
    }
    $script:frames++
})

$form.Show()
$form.Activate()
[System.Windows.Forms.Application]::DoEvents()

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$last = $sw.Elapsed.TotalMilliseconds
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $script:x += $script:dir
    if ($script:x -lt 0 -or $script:x -gt ($Width - 160)) { $script:dir = -$script:dir }
    $form.Invalidate()
    $form.Update()                                   # force a synchronous paint
    [System.Windows.Forms.Application]::DoEvents()
    $now = $sw.Elapsed.TotalMilliseconds
    $script:ivals.Add($now - $last)
    $last = $now
}
$sw.Stop()
$form.Close()

$fps = [math]::Round($script:frames / $sw.Elapsed.TotalSeconds, 2)
function Pct([double[]]$a, [double]$p) {
    if ($a.Count -eq 0) { return $null }
    $srt = $a | Sort-Object
    $i = [int][math]::Floor(($a.Count - 1) * $p)
    return [math]::Round($srt[$i], 3)
}
$iv = $script:ivals.ToArray()
$obj = [ordered]@{
    mode         = $Mode
    seconds      = [math]::Round($sw.Elapsed.TotalSeconds, 3)
    frames       = $script:frames
    rendered_fps = $fps
    frame_ms_p50 = Pct $iv 0.50
    frame_ms_p95 = Pct $iv 0.95
    frame_ms_p99 = Pct $iv 0.99
    frame_ms_max = $(if ($iv.Count) { [math]::Round(($iv | Measure-Object -Maximum).Maximum, 3) } else { $null })
    intervals    = $iv.Count
    width        = $Width
    height       = $Height
    session_id   = $sid
}
Write-Output ("FPSRESULT " + ($obj | ConvertTo-Json -Compress))
