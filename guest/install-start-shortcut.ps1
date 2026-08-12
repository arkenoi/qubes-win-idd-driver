# Install the Start Menu opener + all-users .lnk on a rig that never ran the full
# installer (mirrors the Install-QwtImproved.ps1 stage-2 block, same content).
$ErrorActionPreference = 'Continue'
$qtBin = 'C:\Program Files\Qubes Tools\bin'
$openStart = Join-Path $qtBin 'open-start-menu.ps1'
@'
# Open the guest Start menu (dom0 appmenu entry target). Relays VK_LWIN from an
# interactive scheduled task that fires AFTER this launcher exits: any process activity
# while Start is open steals focus and dismisses it (measured 2026-08-12), so the task
# is armed, the launcher exits, and the stale task is retired on the NEXT invocation.
$ErrorActionPreference = 'SilentlyContinue'
$work = Join-Path $env:TEMP 'qwt-open-start'
New-Item -ItemType Directory -Force $work | Out-Null
$inner = Join-Path $work 'winkey.ps1'
$vbs = Join-Path $work 'winkey.vbs'
@"
Start-Sleep -Milliseconds 2500
Add-Type -Namespace W -Name K -MemberDefinition '[DllImport(`"user32.dll`")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);'
[W.K]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[W.K]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)
"@ | Set-Content $inner -Encoding ASCII
"CreateObject(""WScript.Shell"").Run ""powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """"$inner"""" "", 0, False" | Set-Content $vbs -Encoding ASCII
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }
& schtasks /create /tn QwtOpenStart /tr "wscript.exe //B //Nologo `"$vbs`"" /sc once /st 00:00 /ru $user /it /f | Out-Null
& schtasks /run /tn QwtOpenStart | Out-Null
'@ | Set-Content -LiteralPath $openStart -Encoding ASCII
$lnkDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
$lnkPath = Join-Path $lnkDir 'Start Menu.lnk'
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$openStart`""
$lnk.WorkingDirectory = $qtBin
$lnk.Description = 'Open the Windows Start menu'
$lnk.Save()
Write-Output '=== RESULT ==='
@{ helper = (Test-Path $openStart); lnk = (Test-Path $lnkPath) } | ConvertTo-Json -Compress
