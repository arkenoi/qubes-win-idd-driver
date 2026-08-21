# U10: does an UNPERTURBED cumulative finalize work on a brand-new install?
#
# The question this settles: the old win10-tpl ended unbootable after repeated force-kills MID
# INSTALL, which left two candidates - (a) my force-kills broke it, or (b) the finalize path is
# probabilistically unstable on its own. win10-clean already drained 2965 -> 6456 with every
# finalize succeeding and was never force-killed, which leans hard to (a); this is the clean-room
# re-proof on a guest installed minutes ago and touched by nothing else.
#
# STAGE ONLY here. The reboot is done from outside, gracefully, and NOTHING interrupts it - that is
# the whole point. Verification is UBR moving, not a DISM exit code: rc=3010 means "staged", not
# "installed", and mistaking one for the other is exactly the error this project keeps catching.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\u10-stage.txt'
New-Item -ItemType Directory -Force 'C:\ProgramData\Qubes' | Out-Null
$msu = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\kb5066791.msu'
$L=@()
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$L += ("BEFORE build=" + $v.CurrentBuild + "." + $v.UBR)
$L += ("msu present=" + (Test-Path $msu) + " size=" + $(if(Test-Path $msu){(Get-Item $msu).Length}else{0}))
if (-not (Test-Path $msu)) { $L | Out-File -LiteralPath $out -Encoding ASCII; exit 1 }

# This .msu is a COMBINED SSU+LCU package (it carries SSU-19041.6449-x64.cab beside the CU).
# DISM /Online /Add-Package refuses that combination with rc=50 ERROR_NOT_SUPPORTED - measured, in
# 2 seconds. wusa.exe is the native handler for .msu and applies the SSU then the LCU in order.
$sw=[Diagnostics.Stopwatch]::StartNew()
$p = Start-Process wusa.exe -ArgumentList "`"$msu`"",'/quiet','/norestart' -Wait -PassThru
$sw.Stop()
$L += ("wusa rc=" + $p.ExitCode + " secs=" + [math]::Round($sw.Elapsed.TotalSeconds,0) + "   (3010 = STAGED, needs the reboot; 0 = applied)")
$L += ("CBS RebootPending=" + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
$L += ("pending.xml=" + (Test-Path 'C:\Windows\WinSxS\pending.xml'))
$L | Out-File -LiteralPath $out -Encoding ASCII
Write-Output ("=== STAGED === " + ($L -join ' | '))
