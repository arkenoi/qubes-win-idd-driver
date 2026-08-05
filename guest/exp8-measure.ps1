# Experiment 8 measurement (PLAN-trackb-t2-modes.md §4 D0 / §7 #8): monitor count, virtual
# desktop bounding box, and display device inventory. One MEASURE line, machine-parseable.
# Runs in session 1 via qtest (verified: display APIs work there on this guest).
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms

# Monitor count via WMI (the metric Phase 1B never reported)
$wmi = @(Get-WmiObject -Namespace root\wmi -Class WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
$wmiCount = $wmi.Count

# Screen objects (session view)
$screens = [System.Windows.Forms.Screen]::AllScreens
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

# Display devices + IDD presence
$devs = @()
$idd = 0
Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'IddSample|Indirect' } | ForEach-Object { $idd++; $devs += $_.Name }

# Video controllers
$vcs = @(Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue)

Write-Output ("MEASURE wmi_monitors=$wmiCount screens=" + $screens.Count +
    " vscreen=" + $vs.Width + "x" + $vs.Height + "@" + $vs.X + "," + $vs.Y +
    " idd_pnp_nodes=$idd video_controllers=" + $vcs.Count)
$vcs | ForEach-Object { Write-Output ("VC name=" + $_.Name + " status=" + $_.Status + " conf=" + $_.ConfigManagerErrorCode) }
$devs | ForEach-Object { Write-Output ("IDDNODE $_") }
