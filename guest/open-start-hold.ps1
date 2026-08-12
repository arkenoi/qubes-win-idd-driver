# Open the Start menu and KEEP IT OPEN: arm an interactive scheduled task that fires the
# Win key ~1s AFTER this script has exited, so no guest process activity (which steals
# focus and dismisses Start) happens while the menu is open. Cleanup of the task happens
# on the NEXT invocation (/f overwrites) or via open-start-cleanup.
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
@'
Start-Sleep -Milliseconds 3500
Add-Type -Namespace W -Name K -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
"@
[W.K]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[W.K]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Set-Content 'C:\toastprobe\startkey-hold.txt' 'sent'
'@ | Set-Content "$work\winkey-hold.ps1" -Encoding ASCII
Remove-Item "$work\startkey-hold.txt" -ErrorAction SilentlyContinue
& schtasks /create /tn QwtWinKeyHold /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\winkey-hold.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinKeyHold *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true } | ConvertTo-Json
