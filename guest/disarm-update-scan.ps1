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
# already running, so a RUNNING pass is ended through its TASK - the owner of its relay, which exits
# with it (--parent-pid). The relay itself is never stopped by name (owner 2026-10-07: that was any
# process so named, a Run-task pass's included); what listens on 8082 afterwards is read by PORT
# and reported, never touched.
$ErrorActionPreference = 'Continue'
$t = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if (-not $t) { Write-Output 'SCAN_TASK ABSENT'; Write-Output 'DISARMED True'; exit 0 }
$i = Get-ScheduledTaskInfo -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_BEFORE state=' + $t.State + ' nextrun=' + $i.NextRunTime)
& schtasks /change /tn QubesWindowsUpdateScan /disable *>$null
if ("$($t.State)" -eq 'Running') { Write-Output 'SCAN_RUNNING - ending the task (its relay leaves with it)'; & schtasks /end /tn QubesWindowsUpdateScan *>$null }
Start-Sleep -Seconds 2
$t2 = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_AFTER state=' + $t2.State)
$owner = 0
try { $l = @(Get-NetTCPConnection -LocalPort 8082 -State Listen -ErrorAction SilentlyContinue); if ($l.Count) { $owner = [int]$l[0].OwningProcess } } catch { $owner = -1 }
Write-Output ('RELAY_AFTER ' + $(if ($owner -gt 0) { "port 8082 served by pid $owner - not this script's to stop" } elseif ($owner -eq 0) { '0' } else { 'unreadable' }))
Write-Output ('DISARMED ' + ($t2.State -eq 'Disabled'))
