# Deterministic occlusion regression test.
#
# The damage-clipping fix has two failure directions, and both ship silently:
#   over-clip  - something that is NOT visibly on top suppresses damage for the window below,
#                which makes that window go partially blank. A hidden window doing exactly
#                this was introduced by the clipping fix and found by code review, not by any
#                test, which is why this file exists.
#   under-clip - a window that IS on top does not suppress damage, so the daemon paints the
#                upper window's pixels into the lower window (corrupted menus, overlap debris).
#
# Both are tested here against known geometry rather than waiting for a menu to happen to open.
#
#   BASE   at (100,100) 600x400   - repaints its whole client area on demand
#   COVER  at (400,100) 300x400   - overlaps BASE's right 300px (BASE-relative x 300..600)
#
#   phase 'visible' : COVER shown  -> BASE damage must NOT reach past BASE-relative x=300
#   phase 'hidden'  : COVER hidden -> BASE damage MUST reach past x=300
$ErrorActionPreference = 'SilentlyContinue'

Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 14
$log = (Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log' |
        Sort-Object LastWriteTime -Desc | Select-Object -First 1)
Write-Output "LOGFILE $($log.Name)"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$base = New-Object System.Windows.Forms.Form
$base.Text = 'OCCLUSION-BASE'
$base.StartPosition = 'Manual'
$base.Location = New-Object System.Drawing.Point(100,100)
$base.Size = New-Object System.Drawing.Size(600,400)
$base.BackColor = 'White'
$base.Show(); $base.Refresh()

$cover = New-Object System.Windows.Forms.Form
$cover.Text = 'OCCLUSION-COVER'
$cover.StartPosition = 'Manual'
$cover.Location = New-Object System.Drawing.Point(400,100)
$cover.Size = New-Object System.Drawing.Size(300,400)
$cover.BackColor = 'Red'
$cover.Show(); $cover.Refresh()
Start-Sleep 4

Write-Output ("BASEHWND {0}" -f $base.Handle.ToInt64())
Write-Output ("COVERHWND {0}" -f $cover.Handle.ToInt64())

function Repaint-Base {
    param([int]$times = 6)
    for ($i = 0; $i -lt $times; $i++) {
        # alternate the colour so the whole client area genuinely changes every time
        $base.BackColor = @('White','LightYellow')[$i % 2]
        $base.Invalidate(); $base.Update(); $base.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 350
    }
}

# --- phase 1: COVER visible and on top
$cover.TopMost = $true
$cover.BringToFront(); $cover.Refresh()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep 2
Write-Output "PHASE visible"
Repaint-Base
Start-Sleep 2

# --- phase 2: COVER hidden
$cover.Hide()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep 3
Write-Output "PHASE hidden"
Repaint-Base
Start-Sleep 2

Write-Output "TRACESTART"
Get-Content $log.FullName | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
$cover.Close(); $base.Close()
