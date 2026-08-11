# win-start-probe.ps1 — S1a/S1b repro driver: simulate Win-key presses to exercise the
# Start menu under the live gui-agent. Modes:
#   -Count 1               single open (S1b dialog hunt: one MSG_CREATE of the Start surface)
#   -Count N -DelayMs 500  toggle storm (S1a capture-thread wedge repro from 24H2)
# Prints a start/end timestamp so the agent log can be correlated, and the tail of the
# newest gui-agent log afterwards.
param(
    [int]$Count = 1,
    [int]$DelayMs = 500,
    [int]$LogTail = 60
)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace W -Name K -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
$VK_LWIN = 0x5B; $KEYUP = 2

Write-Output ("PROBE-START {0:yyyy-MM-dd HH:mm:ss.fff} count={1} delay={2}" -f (Get-Date), $Count, $DelayMs)
for ($i = 0; $i -lt $Count; $i++) {
    [W.K]::keybd_event($VK_LWIN, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W.K]::keybd_event($VK_LWIN, 0, $KEYUP, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds $DelayMs
}
Write-Output ("PROBE-END   {0:yyyy-MM-dd HH:mm:ss.fff}" -f (Get-Date))

# LogDir per HKLM\Software\Invisible Things Lab\Qubes Tools (Q:\Qubes Logs on this rig)
$logdir = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'C:\Program Files\Qubes Tools\log' }
$log = Get-ChildItem $logdir -Filter 'gui-agent*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) {
    Write-Output ("LOG {0}" -f $log.FullName)
    Get-Content $log.FullName -Tail $LogTail
} else {
    Write-Output "LOG none-found"
}
