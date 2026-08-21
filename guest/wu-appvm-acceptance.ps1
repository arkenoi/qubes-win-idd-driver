# U6: the AppVM branch of the VM-class router, never yet run on a REAL AppVM.
#
# Expected (qubes-windows-update.ps1:1172-1176): an AppVM is not a template, so the updater must log
# the class, set phase=skipped-appvm and exit 0 BEFORE Ensure-Proxy - i.e. an AppVM must never get a
# proxy, never start the relay, and never touch WinHTTP/IE proxy settings. That last part is the
# security-relevant half: the proxy is a template-only capability.
#
# Emits === RESULT === JSON.
$ErrorActionPreference='Continue'
$agent='C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1'
$exe  ='C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$tmp  ='C:\ProgramData\Qubes\appvm-test'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$status = Join-Path $tmp 'status.json'
$r=[ordered]@{}
$r['host']=$env:COMPUTERNAME
$r['agent_present']=Test-Path $agent
if(-not $r['agent_present']){ Write-Output ("=== RESULT === " + ($r|ConvertTo-Json -Compress)); exit 1 }
# does this build carry today's fixes? (proves template->AppVM propagation too)
$r['agent_hash16']=(Get-FileHash $agent -Algorithm SHA256).Hash.Substring(0,16)
$r['agent_has_debounce']=[bool](Select-String -Path $agent -Pattern 'prevAnswered' -Quiet -EA SilentlyContinue)

# what the guest believes it is
$qdb='C:\Program Files\Qubes Tools\bin\qubesdb-read.exe'
if(Test-Path $qdb){ $r['qubesdb_type']=(& $qdb /type 2>&1 | Out-String).Trim() }

# BEFORE state - the things an AppVM must NOT acquire
$IS='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$r['proxy_before']= (Get-ItemProperty $IS -EA SilentlyContinue).ProxyServer
$r['relay_running_before']=[bool](Get-Process qubes-updates-relay -EA SilentlyContinue)

Remove-Item -LiteralPath $status -Force -EA SilentlyContinue
$sw=[Diagnostics.Stopwatch]::StartNew()
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agent -Action scan -Scheduled `
    -StatusFile $status -WorkDir (Join-Path $tmp 'wu') 2>&1 | Out-Null
$r['exit_code']=$LASTEXITCODE
$sw.Stop(); $r['secs']=[math]::Round($sw.Elapsed.TotalSeconds,1)

if(Test-Path $status){
  $j=Get-Content -Raw $status | ConvertFrom-Json
  $r['phase']=$j.phase
} else { $r['phase']='(no status file written)' }

# AFTER state - nothing may have changed
$r['proxy_after']=(Get-ItemProperty $IS -EA SilentlyContinue).ProxyServer
$r['relay_running_after']=[bool](Get-Process qubes-updates-relay -EA SilentlyContinue)
$r['proxy_unchanged']=($r['proxy_before'] -eq $r['proxy_after'])
$r['no_relay_started']=(-not $r['relay_running_after'])
# and the agent log line that proves WHY it stopped
$log = Join-Path $tmp 'wu\agent.log'
if(Test-Path $log){
  $m = Select-String -Path $log -Pattern 'VM class \(live from qubesdb\)|not a template|skipped' -EA SilentlyContinue | Select-Object -Last 3
  $r['log_lines']=(@($m | ForEach-Object { $_.Line.Trim() }) -join ' || ')
}
# The EXPECTED branch depends on the class this qube actually is, so the same acceptance can be run
# on an AppVM, a DispVM (which falls through to the same branch) and a StandaloneVM. What must hold
# for ALL non-template classes is the security-relevant half: no proxy, no relay, exit 0.
$cls = $null
if ($r['log_lines'] -match 'VM class \(live from qubesdb\):\s*(\w+)') { $cls = $Matches[1] }
$r['class_detected'] = $cls
$expected = switch ($cls) {
  'TemplateVM'   { 'ensure-proxy-or-later' }
  'StandaloneVM' { 'skipped-standalone' }
  default        { 'skipped-appvm' }      # AppVM, DispVM, anything else non-template
}
$r['phase_expected'] = $expected
$r['phase_correct']  = ($r['phase'] -eq $expected)
$r['ok'] = ($r['exit_code'] -eq 0) -and $r['phase_correct'] -and $r['proxy_unchanged'] -and $r['no_relay_started']
Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress))
