# Open the Start menu by simulating a Win-key press FROM THE INTERACTIVE SESSION via a
# scheduled task (direct qrexec keybd_event does not open Start on 25H2 - session issue).
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null

@'
Add-Type -Namespace W -Name K -MemberDefinition @"
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
"@
[W.K]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[W.K]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
Set-Content 'C:\toastprobe\startkey.txt' 'sent'
'@ | Set-Content "$work\winkey.ps1" -Encoding ASCII

Remove-Item "$work\startkey.txt" -ErrorAction SilentlyContinue
& schtasks /create /tn QwtWinKey /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\winkey.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtWinKey *>&1 | Out-Null
$sent = $false
for ($i = 0; $i -lt 15; $i++) { Start-Sleep 1; if (Test-Path "$work\startkey.txt") { $sent = $true; break } }
& schtasks /delete /tn QwtWinKey /f *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ sent = $sent } | ConvertTo-Json
