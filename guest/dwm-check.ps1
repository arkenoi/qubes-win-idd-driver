# DWM health probe: process uptime, recent app-crash events, current display mode.
$ErrorActionPreference = 'Continue'
Write-Output '=== DWM ==='
Get-Process dwm -ErrorAction SilentlyContinue | ForEach-Object { "dwm pid=$($_.Id) start=$($_.StartTime.ToString('HH:mm:ss'))" }
Write-Output '=== CRASHES (last 8, id 1000/1001) ==='
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001} -MaxEvents 8 -ErrorAction SilentlyContinue |
    ForEach-Object { $_.TimeCreated.ToString('HH:mm:ss') + ' ' + (($_.Message -split "`r?`n")[0]) + ' ' + (($_.Message -split "`r?`n")[1]) }
Write-Output '=== MODE ==='
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.DeviceName) $($_.Bounds.Width)x$($_.Bounds.Height) primary=$($_.Primary)" }
Write-Output '=== END ==='
