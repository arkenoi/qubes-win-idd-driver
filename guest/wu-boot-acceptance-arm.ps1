# ARM the cold-boot acceptance for the QdbDaemon startup-race fix (U12) and turn on the
# TaskScheduler Operational log (U8) so pass triggers stop being unattributable.
#
# THE FIX UNDER TEST: at early boot the QubesDB daemon is not yet serving its pipe, so qdb_open
# returns NULL and Get-QubesVmClass used to read an empty class - a TemplateVM was then treated as
# a standalone and the boot pass skipped. It now waits the daemon out (retry loop). That has never
# been exercised on a REAL cold boot; restarting the agent in a live session clears the very state
# that produces the fault.
#
# This records the pre-reboot marks; wu-boot-acceptance-check.ps1 reads the verdict after the boot.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\boot-accept-arm.txt'
$work='C:\ProgramData\Qubes\wu'
$L=@()

# U8: the TaskScheduler Operational channel is off by default, which is why nothing could say WHICH
# task started a second pass.
$ch = 'Microsoft-Windows-TaskScheduler/Operational'
$before = (& wevtutil gl $ch 2>&1 | Select-String '^\s*enabled:' | Select-Object -First 1).ToString().Trim()
& wevtutil sl $ch /e:true 2>&1 | Out-Null
$after  = (& wevtutil gl $ch 2>&1 | Select-String '^\s*enabled:' | Select-Object -First 1).ToString().Trim()
$L += ("TaskScheduler Operational log: $before -> $after")

# marks so the post-boot check reads only what the NEXT boot produced
$log = Join-Path $work 'agent.log'
$L += ("agent_log_offset=" + $(if(Test-Path $log){(Get-Item $log).Length}else{0}))
$L += ("boot_time_before=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s'))
$L += ("vm_class_now=" + $env:COMPUTERNAME)
# what the guest currently believes it is - the value the race corrupts
try {
  $qdb = 'C:\Program Files\Qubes Tools\bin\qubesdb-read.exe'
  if (Test-Path $qdb) { $L += ("qubesdb /type = '" + (& $qdb /type 2>&1) + "'") }
} catch { $L += "qubesdb read failed: $($_.Exception.Message)" }
$L | Out-File -LiteralPath $out -Encoding ASCII
Write-Output ("=== ARMED === " + ($L -join ' ; '))
