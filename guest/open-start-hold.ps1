# Open the Start menu and KEEP IT OPEN, with NO visible console. The interactive scheduled
# task runs wscript.exe (windowless) on a .vbs that launches a hidden powershell which
# presses the Win key ~3.5s later - so nothing flashes a terminal that would steal focus
# and dismiss Start (measured 2026-08-12: -WindowStyle Hidden on a scheduled powershell
# still flashed a conhost window; wscript+Run,0 does not).
param([ValidateSet('win', 'ctrlesc', 'shiftwin')] [string] $Opener = 'ctrlesc')
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null

# inner powershell: the actual keypress, hidden
@'
Start-Sleep -Milliseconds 3500
Add-Type -Namespace W -Name K -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
"@
__KEYS__
Set-Content 'C:\toastprobe\startkey-hold.txt' 'sent'
'@.Replace('__KEYS__', $(switch ($Opener) {
    # THE WIN KEY IS NOT ALWAYS THE OPENER. On a guest running a Start replacement it opens THAT
    # menu, and on win11de-* the native Start comes up on Ctrl+Esc - measured 2026-10-17, where a
    # Win press produced no CoreWindow at all. Ctrl+Esc is the default because no replacement
    # intercepts it; -Opener win is for deliberately exercising the replacement.
    'ctrlesc'  { "[W.K]::keybd_event(0x11,0,0,[UIntPtr]::Zero); [W.K]::keybd_event(0x1B,0,0,[UIntPtr]::Zero)`nStart-Sleep -Milliseconds 80`n[W.K]::keybd_event(0x1B,0,2,[UIntPtr]::Zero); [W.K]::keybd_event(0x11,0,2,[UIntPtr]::Zero)" }
    'shiftwin' { "[W.K]::keybd_event(0x10,0,0,[UIntPtr]::Zero); [W.K]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)`nStart-Sleep -Milliseconds 80`n[W.K]::keybd_event(0x5B,0,2,[UIntPtr]::Zero); [W.K]::keybd_event(0x10,0,2,[UIntPtr]::Zero)" }
    default    { "[W.K]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)`nStart-Sleep -Milliseconds 80`n[W.K]::keybd_event(0x5B,0,2,[UIntPtr]::Zero)" }
})) | Set-Content "$work\winkey-hold.ps1" -Encoding ASCII

# vbs launcher: wscript is windowless; Run(...,0,False) hides the powershell's conhost
@'
CreateObject("WScript.Shell").Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\toastprobe\winkey-hold.ps1""", 0, False
'@ | Set-Content "$work\winkey-hold.vbs" -Encoding ASCII

Remove-Item "$work\startkey-hold.txt" -ErrorAction SilentlyContinue
# THE AUTOLOGON USER, NOT THE LITERAL "user". /ru user ran the task as an account that does not
# exist on a guest whose user is someone else (gerd-test here), so the key was never pressed and
# this reported armed=true over nothing - measured 2026-10-17 while trying to show the menu on the
# operator's screen.
$ru = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
if (-not $ru) { $ru = 'user' }
& schtasks /create /tn QwtWinKeyHold /tr "wscript.exe //B //Nologo $work\winkey-hold.vbs" /sc once /st 00:00 /ru $ru /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinKeyHold *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true; opener = $Opener; ru = $ru } | ConvertTo-Json
