# Open the Start menu and KEEP IT OPEN, with NO visible console. The interactive scheduled
# task runs wscript.exe (windowless) on a .vbs that launches a hidden powershell which
# presses the Win key ~3.5s later - so nothing flashes a terminal that would steal focus
# and dismiss Start (measured 2026-08-12: -WindowStyle Hidden on a scheduled powershell
# still flashed a conhost window; wscript+Run,0 does not).
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null

# inner powershell: the actual keypress, hidden
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

# vbs launcher: wscript is windowless; Run(...,0,False) hides the powershell's conhost
@'
CreateObject("WScript.Shell").Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\toastprobe\winkey-hold.ps1""", 0, False
'@ | Set-Content "$work\winkey-hold.vbs" -Encoding ASCII

Remove-Item "$work\startkey-hold.txt" -ErrorAction SilentlyContinue
& schtasks /create /tn QwtWinKeyHold /tr "wscript.exe //B //Nologo $work\winkey-hold.vbs" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinKeyHold *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true } | ConvertTo-Json
