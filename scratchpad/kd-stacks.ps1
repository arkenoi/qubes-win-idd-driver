# kd stack extraction from the newest kernel dump. Copies the dump aside first
# (a later bugcheck overwrites MEMORY.DMP), then walks all CPUs.
param([string]$Dump = 'C:\Windows\MEMORY.DMP', [string]$Tag = 'latest')
$inc = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$keep = "C:\qubes-idd\wedge-$Tag.dmp"
Copy-Item $Dump $keep -Force
Copy-Item C:\Windows\System32\ntoskrnl.exe "$inc\ntkrnlmp.exe" -Force -ErrorAction SilentlyContinue
$cmds = @"
.exepath $inc;C:\Windows\System32;C:\Windows\System32\drivers
.symopt+ 0x40
.reload
~0s
k 25
~1s
k 25
~2s
k 25
~3s
k 25
q
"@
Set-Content "$inc\kd.cmds" -Value $cmds -Encoding ascii
& "$inc\kd.exe" -z $keep -cf "$inc\kd.cmds" 2>&1 | Out-File "C:\qubes-idd\kd-$Tag.txt" -Encoding ascii
Write-Output ("KDDONE lines=" + (Get-Content "C:\qubes-idd\kd-$Tag.txt").Count + " dump=$keep")
