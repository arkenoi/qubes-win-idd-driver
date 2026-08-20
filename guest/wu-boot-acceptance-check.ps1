# Post-cold-boot verdict for the QdbDaemon startup-race fix (U12), plus the first read of the
# TaskScheduler Operational log (U8) now that it is enabled.
#
# PASS means: the guest really did reboot, a boot-triggered pass ran, and it classified this VM
# CORRECTLY from qubesdb - i.e. "VM class (live from qubesdb): TemplateVM", not the empty read that
# used to make a template look like a standalone and skip the pass.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\boot-accept-check.txt'
$work='C:\ProgramData\Qubes\wu'
$log = Join-Path $work 'agent.log'
$L=@()
$res=[ordered]@{}

$arm = @{}
foreach($line in (Get-Content 'C:\ProgramData\Qubes\boot-accept-arm.txt' -EA SilentlyContinue)){
  if($line -match '^(\w+)=(.*)$'){ $arm[$Matches[1]] = $Matches[2] }
}
$bootNow = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$res['boot_before'] = $arm['boot_time_before']
$res['boot_now']    = $bootNow.ToString('s')
$res['rebooted']    = ($arm['boot_time_before'] -ne $bootNow.ToString('s'))
$res['uptime_min']  = [math]::Round(((Get-Date)-$bootNow).TotalMinutes,1)

# only the slice written since the reboot
$offset = 0; if($arm['agent_log_offset']){ $offset = [int64]$arm['agent_log_offset'] }
$txt=''
try { $fs=[IO.File]::Open($log,'Open','Read','ReadWrite'); try{ if($offset -le $fs.Length){[void]$fs.Seek($offset,'Begin')}; $txt=(New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() } } catch {}
$res['new_log_bytes'] = $txt.Length

$cls = [regex]::Matches($txt,'VM class \(live from qubesdb\):\s*(\S*)')
$res['class_lines'] = $cls.Count
$vals = @(); foreach($m in $cls){ $vals += $m.Groups[1].Value }
$res['classes_seen'] = ($vals -join ',')
$res['class_correct'] = [bool](($vals.Count -gt 0) -and ($vals -notcontains '') -and ($vals -contains 'TemplateVM'))
$res['saw_empty_class'] = [bool]($vals -contains '')
$res['refused_to_classify'] = [bool]($txt -match 'CANNOT classify VM from qubesdb')
$res['skipped_as_standalone'] = [bool]($txt -match 'StandaloneVM')
# did the qubesdb retry loop actually have to wait? (evidence the race was live at boot)
$res['qdb_retry_evidence'] = [bool]($txt -match 'qubesdb|QubesDB' )

# U8: what actually started tasks this boot
try {
  $ev = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; StartTime=$bootNow} -EA SilentlyContinue |
        Where-Object { $_.Id -in 100,102,201 -and $_.Message -match 'Qubes' } | Select-Object -First 12
  $res['tasksched_events'] = @($ev).Count
  foreach($e in @($ev)){ $L += ("  TASKSCHED " + $e.TimeCreated.ToString('HH:mm:ss') + " id=" + $e.Id + " " + (($e.Message -split "`n")[0])) }
} catch { $res['tasksched_events'] = "error: $($_.Exception.Message)" }

$res['ok'] = ($res['rebooted'] -and $res['class_correct'] -and -not $res['saw_empty_class'])
$L = @("=== RESULT === " + ($res | ConvertTo-Json -Compress)) + $L
$L | Out-File -LiteralPath $out -Encoding ASCII
$L | ForEach-Object { Write-Output $_ }
