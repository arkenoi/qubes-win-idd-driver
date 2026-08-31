# Disarm QubesWindowsUpdateScan and stop any live relay, then PROVE it.
#
# WHY IT IS ITS OWN REPO FILE. p4-run.sh created this inline in its own temp dir and p5-run.sh
# called it from "$TMP" - which, once TMP became a per-run mktemp -d, no longer existed. P5 then
# refused with "scan not disarmed" on a guest that was perfectly fine. That is protocol 0.8b rule 4:
# every guest script a harness calls must live in the repo, or the harness breaks the moment its
# sibling is not run first.
#
# The disarm itself is a P3 precondition: a boot+2min scan raises the proxy and churns qrexec, which
# is a named wedge trigger under rendering load. Disabling the task does NOT stop a pass that is
# already running, so a live relay is killed too.
$ErrorActionPreference = 'Continue'
$t = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if (-not $t) { Write-Output 'SCAN_TASK ABSENT'; Write-Output 'DISARMED True'; exit 0 }
$i = Get-ScheduledTaskInfo -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_BEFORE state=' + $t.State + ' nextrun=' + $i.NextRunTime)
& schtasks /change /tn QubesWindowsUpdateScan /disable *>$null
$p = Get-Process qubes-updates-relay -EA SilentlyContinue
if ($p) { Write-Output ('RELAY_RUNNING ' + @($p).Count + ' - stopping'); $p | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep -Seconds 2
$t2 = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_AFTER state=' + $t2.State)
Write-Output ('RELAY_AFTER ' + @(Get-Process qubes-updates-relay -EA SilentlyContinue).Count)
Write-Output ('DISARMED ' + ($t2.State -eq 'Disabled'))
