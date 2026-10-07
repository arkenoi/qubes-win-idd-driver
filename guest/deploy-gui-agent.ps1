# Swap in a newer gui-agent.exe on a guest whose QWT predates a fix, without reinstalling QWT.
# Established pattern (CLAUDE.md Phase 1A): stop the service, keep a .orig backup, swap, restart.
# The agent is launched by the QubesGuiWatchdog SERVICE (gui-watchdog.exe spawns gui-agent.exe), so
# the watchdog must be stopped first or it will respawn the old binary mid-swap - and since
# 2026-10-03 the service stop ENDS the agent it started, by handle (watchdog.c StopOwnAgent).
# Push guest/restart-gui-agent.ps1 next to this script: Stop-GuiAgentOwner stops the service and
# proves the old agent gone, Start-GuiAgentOwner starts it and proves the NEW agent by its log
# turnover. Owner 2026-10-07: never `Get-Process gui-agent | .Kill()`, which was any process so
# named and raced the watchdog's own relaunch.
# Emits === RESULT === JSON.
$ErrorActionPreference='Continue'
$src='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\gui-agent.exe'
$dst='C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$r=[ordered]@{}
$r['host']=$env:COMPUTERNAME
if(-not (Test-Path $src)){ $r['error']='new gui-agent.exe not pushed'; $r['ok']=$false
  Write-Output ("=== RESULT === " + ($r|ConvertTo-Json -Compress)); exit 1 }
$r['new_size']=(Get-Item $src).Length
$r['old_size']=if(Test-Path $dst){(Get-Item $dst).Length}else{0}
$r['old_hash16']=if(Test-Path $dst){(Get-FileHash $dst -Algorithm SHA256).Hash.Substring(0,16)}else{'none'}

# stop the watchdog SERVICE (the owner); it ends the agent it supervises, proven gone by handle
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { $r['error']='restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)'; $r['ok']=$false
  Write-Output ("=== RESULT === " + ($r|ConvertTo-Json -Compress)); exit 3 }
. $helper
$st = Stop-GuiAgentOwner
$r['watchdog_stopped']=$st.svc_stopped
$r['agent_running_after_stop']=(-not $st.old_gone)

# keep the original ONCE - never overwrite a good backup with an already-swapped binary
$bak = $dst + '.orig'
if(-not (Test-Path $bak)){ Copy-Item -LiteralPath $dst -Destination $bak -Force -EA SilentlyContinue; $r['backup_made']=$true }
else { $r['backup_made']='already existed (kept)' }

Copy-Item -LiteralPath $src -Destination $dst -Force -EA SilentlyContinue
$r['dst_size']=if(Test-Path $dst){(Get-Item $dst).Length}else{0}
$r['dst_hash16']=if(Test-Path $dst){(Get-FileHash $dst -Algorithm SHA256).Hash.Substring(0,16)}else{'none'}
$r['swapped']=($r['dst_size'] -eq $r['new_size'])

# Start the service; the NEW agent is proven by its own log turnover (a newer gui-agent-<ts>-<pid>.log
# with a live pid), bounded - never a fixed sleep (a fixed 8 s wait once reported agent_running=false
# on a deploy that had worked; measured: the agent appeared ~30 s after the service start).
$ra = Start-GuiAgentOwner -Stopped $st
foreach ($ln in @($ra.lines)) { Write-Output $ln }
$r['watchdog_started']=($ra.wd_status -eq 'Running')
$r['agent_wait_secs']=$ra.wait_s
$r['agent_running']=$ra.ok
$r['agent_pid']=if($ra.ok){$ra.new_pid}else{$null}
$r['restart']=$ra.verdict; $r['restart_reason']=$ra.reason
# prove the RUNNING binary is the new one, not a leftover
$ga=$null
if($ra.ok){ $ga=Get-Process -Id $ra.new_pid -EA SilentlyContinue }
if($ga){ try { $r['running_image_size']=(Get-Item $ga.Path).Length } catch {} }
$r['ok']=($r['swapped'] -and $r['agent_running'])
Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress))
