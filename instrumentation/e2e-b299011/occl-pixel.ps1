# Decisive occlusion test for a PER-WINDOW-capture build: check-occlusion.py's screen-slice
# clipping invariant does not apply to a window with its own WGC buffer, so the criterion is
# the one that survives the architecture change - BASE's dom0 pixmap must contain none of
# COVER's pixels. BASE is white, COVER is pure red (255,0,0); any red inside BASE's PNG is
# bleed. Keeps the windows up for 60 s so the host can capture dom0 while they overlap.
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = New-Object System.Windows.Forms.Form
$base.Text='OCCLUSION-BASE'; $base.StartPosition='Manual'
$base.Location=New-Object System.Drawing.Point(100,100)
$base.Size=New-Object System.Drawing.Size(600,400)
$base.BackColor='White'
$base.Show(); $base.Refresh()

$cover = New-Object System.Windows.Forms.Form
$cover.Text='OCCLUSION-COVER'; $cover.StartPosition='Manual'
$cover.Location=New-Object System.Drawing.Point(400,100)
$cover.Size=New-Object System.Drawing.Size(300,400)
$cover.BackColor=[System.Drawing.Color]::FromArgb(255,0,0)
$cover.Show(); $cover.Refresh()
$cover.TopMost=$true; $cover.BringToFront(); $cover.Refresh()
Start-Sleep 3
Write-Output ("RESULT=BASEHWND {0} COVERHWND {1}" -f $base.Handle.ToInt64(),$cover.Handle.ToInt64())
Write-Output "RESULT=WINDOWS-UP"
$sw=[Diagnostics.Stopwatch]::StartNew()
while($sw.Elapsed.TotalSeconds -lt 60){
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 200
}
$cover.Close(); $base.Close()
Write-Output "RESULT=WINDOWS-DOWN"
