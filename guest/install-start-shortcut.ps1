# Install the Start-menu opener + all-users .lnk (mirrors the Install-QwtImproved.ps1
# stage-2 block). Everything is WINDOWLESS: wscript has no console, so nothing flashes a
# a powershell launcher, even -WindowStyle Hidden, flashes a conhost window and kills Start).
# The keypress is VK_LWIN injected GUEST-side, so it is unaffected by the agent's
# BlockMenuKey filter (which drops the dom0-forwarded Super key).
$ErrorActionPreference = 'Continue'
$qtBin = 'C:\Program Files\Qubes Tools\bin'
$vbsPath = Join-Path $qtBin 'open-start-menu.vbs'
@'
' Open the Windows Start menu (dom0 qube-app shortcut target).
' wscript.exe is windowless and Run(...,0) hides the powershell console, so nothing ever
' flashes a window - a console flash steals focus and dismisses the very menu we open
' (measured 2026-08-12). VK_LWIN is injected GUEST-side, so the agent's BlockMenuKey
' filter (which drops the dom0-forwarded Super key) does not apply.
Dim sh, fso, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
ps = fso.GetSpecialFolder(2) & "\qwt-winkey.ps1"
Dim f
Set f = fso.CreateTextFile(ps, True)
f.WriteLine "Add-Type -Namespace W -Name K -MemberDefinition '[DllImport(\"user32.dll\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);'"
f.WriteLine "Start-Sleep -Milliseconds 400"
f.WriteLine "[W.K]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)"
f.WriteLine "Start-Sleep -Milliseconds 80"
f.WriteLine "[W.K]::keybd_event(0x5B,0,2,[UIntPtr]::Zero)"
f.Close
sh.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps & """", 0, False
'@ | Set-Content -LiteralPath $vbsPath -Encoding ASCII

$lnkDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
$lnkPath = Join-Path $lnkDir 'Start Menu.lnk'
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
$lnk.Arguments = "//B //Nologo `"$vbsPath`""
$lnk.WorkingDirectory = $qtBin
$lnk.Description = 'Open the Windows Start menu'
$lnk.Save()
Write-Output '=== RESULT ==='
@{ vbs = (Test-Path $vbsPath); lnk = (Test-Path $lnkPath) } | ConvertTo-Json -Compress
