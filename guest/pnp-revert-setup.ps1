# Register the QubesIddPnpRevert boot task (experiment 7). Copies devcon + the action script
# from QubesIncoming into C:\qubes-idd and registers a SYSTEM onstart scheduled task.
$ErrorActionPreference = 'Stop'
$dir = 'C:\qubes-idd'
$inc = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item (Join-Path $inc 'devcon.exe') $dir -Force
Copy-Item (Join-Path $inc 'pnp-revert-action.ps1') $dir -Force

# cmd /c wrappers: a native stderr write under ErrorActionPreference=Stop raises
# NativeCommandError even when redirected (PS 5.1), so keep schtasks noise inside cmd.
cmd /c "schtasks /delete /tn QubesIddPnpRevert /f >nul 2>nul"
cmd /c "schtasks /create /tn QubesIddPnpRevert /sc onstart /ru SYSTEM /rl HIGHEST /tr `"powershell -NoProfile -ExecutionPolicy Bypass -File $dir\pnp-revert-action.ps1`" >nul"
$t = schtasks /query /tn QubesIddPnpRevert /fo list 2>&1 | Out-String
if ($t -match 'QubesIddPnpRevert') { Write-Output 'SETUP=OK task=QubesIddPnpRevert' }
else { Write-Output 'SETUP=FAIL'; exit 1 }
