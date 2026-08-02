# Genuine joint owner+child motion probe.
#
# Win10's #32768 menu does NOT travel with its owner (jointmove.ps1 measured that: the owner
# moved 234px while the menu stayed at 408,350), so a Notepad menu can never exercise the
# "pure joint owner+child move pushes nothing" path. This builds the condition explicitly:
# an owned, caption-less (=> override_redirect => synthesis-eligible) child form that is
# repositioned in LOCKSTEP with its owner, so the child's owner-relative rect is constant.
#
# Expected if the SynthFlushMasks design holds: QGADRAG,ev=maskpush fires ONCE at synthesis
# activation and then NOT AGAIN for the duration of the joint motion.
$ErrorActionPreference='SilentlyContinue'

Get-Process notepad -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$log=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGFILE {0}" -f $log.Name)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Stamp { (Get-Date).ToString('yyyyMMdd.HHmmss.fff') }

$own = New-Object System.Windows.Forms.Form
$own.Text='JOINT-OWNER'; $own.StartPosition='Manual'
$own.Location=New-Object System.Drawing.Point(300,200)
$own.Size=New-Object System.Drawing.Size(700,500)
$own.BackColor='White'
$own.Show(); $own.Refresh()
Start-Sleep 2

$kid = New-Object System.Windows.Forms.Form
$kid.FormBorderStyle='None'          # no caption -> agent IsPopup() -> override_redirect
$kid.ShowInTaskbar=$false
$kid.StartPosition='Manual'
$kid.Location=New-Object System.Drawing.Point(400,300)   # inside the owner
$kid.Size=New-Object System.Drawing.Size(240,180)
$kid.BackColor=[System.Drawing.Color]::FromArgb(0,128,255)
$kid.Owner=$own
$kid.Show(); $kid.Refresh()
Start-Sleep 4
[System.Windows.Forms.Application]::DoEvents()

Write-Output ("RESULT=OWNERHWND {0}" -f $own.Handle.ToInt64())
Write-Output ("RESULT=CHILDHWND {0}" -f $kid.Handle.ToInt64())
$off = New-Object System.Drawing.Point(($kid.Location.X - $own.Location.X), ($kid.Location.Y - $own.Location.Y))
Write-Output ("RESULT=OFFSET {0},{1}" -f $off.X,$off.Y)
Start-Sleep 3

Write-Output ("PHASE joint {0}" -f (Stamp))
Write-Output "TRACKSTART"
for($i=0;$i -lt 40;$i++){
  $x = 300 + ($i*6); $y = 200 + ($i*3)
  $own.Location = New-Object System.Drawing.Point($x,$y)
  $kid.Location = New-Object System.Drawing.Point(($x+$off.X),($y+$off.Y))
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 60
  Write-Output ("STEP {0} t={1} owner={2},{3} child={4},{5} rel={6},{7}" -f $i,(Stamp),
    $own.Location.X,$own.Location.Y,$kid.Location.X,$kid.Location.Y,
    ($kid.Location.X-$own.Location.X),($kid.Location.Y-$own.Location.Y))
}
Write-Output "TRACKEND"
Write-Output ("PHASE joint-end {0}" -f (Stamp))
Start-Sleep 3

Write-Output "DRAGSTART"
Get-Content $log.FullName | Select-String 'QGADRAG,' | ForEach-Object { $_.Line }
Write-Output "DRAGEND"
Write-Output "TRACESTART"
Get-Content $log.FullName | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
$kid.Close(); $own.Close()
Write-Output "RESULT=JOINT2DONE"
