# Generate continuous desktop damage so Desktop Duplication (ddaprobe / the gui-agent)
# has real frames + dirty/move rects to measure, instead of an idle-desktop timeout storm.
# Runs entirely in the interactive session (no elevation). Opens a small form and, for
# -Seconds, drags it in a circle (produces MOVE rects if the compositor emits them) while
# repainting its client area (produces DIRTY rects). Self-closes.
param([int]$Seconds = 30, [int]$Fps = 60)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'iddtest-activity'
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'FixedSingle'
$form.Width = 400; $form.Height = 300
$form.TopMost = $true
$tick = 0
$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $c = [System.Drawing.Color]::FromArgb(255, ($tick * 7) % 256, ($tick * 13) % 256, ($tick * 3) % 256)
    $g.Clear($c)
    $g.DrawString("$tick", (New-Object System.Drawing.Font('Consolas', 48)),
                  [System.Drawing.Brushes]::White, 20, 20)
})
$form.Show()

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cx = 300; $cy = 300; $r = 200
$period = [int](1000 / $Fps)
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $a = $sw.Elapsed.TotalSeconds * 2.0
    $form.Left = [int]($cx + $r * [Math]::Cos($a))
    $form.Top  = [int]($cy + $r * [Math]::Sin($a))
    $tick++
    $form.Invalidate()          # force a WM_PAINT -> dirty rect
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds $period
}
$form.Close()
Write-Output "activity-gen done: $tick frames over $([int]$sw.Elapsed.TotalSeconds)s"
