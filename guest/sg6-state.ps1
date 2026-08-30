# SG6 DEFECT-STATE ASSERTION — states the invisible-guest condition POSITIVELY.
# The fail-proof cannot use an in-guest control window (with autologon disarmed there is no
# interactive session to put one in), so this is what replaces it: zero Active sessions, with
# AutoAdminLogon and the guard task read back. "Zero windows mapped" alone is indistinguishable
# from the capture path being blind - which is how a broken instrument would EARN the fail-proof.
#
# WAS IN JOB SCRATCH UNTIL 2026-08-31.
$ErrorActionPreference='Continue'
$act = @(query user 2>&1 | Select-String -Pattern '\s(Active)\s')
Write-Output ("SESSIONS " + $act.Count)
$WL='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Write-Output ("AUTOLOGON " + (Get-ItemProperty $WL -Name AutoAdminLogon -EA SilentlyContinue).AutoAdminLogon)
Write-Output ("GUARD " + $(if (Get-ScheduledTask -TaskName QubesAutologonGuard -EA SilentlyContinue) {'present'} else {'ABSENT'}))
