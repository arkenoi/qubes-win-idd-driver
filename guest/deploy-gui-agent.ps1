# Swap in a newer gui-agent.exe on a guest whose QWT predates a fix, without reinstalling QWT.
# Established pattern (CLAUDE.md Phase 1A): stop the service, keep a .orig backup, swap, restart.
# The agent is launched by the QubesGuiWatchdog SERVICE (gui-watchdog.exe spawns gui-agent.exe), so
# the watchdog must be stopped first or it will respawn the old binary mid-swap.
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

# stop the watchdog SERVICE first, then the agent it supervises
try { Stop-Service QubesGuiWatchdog -Force -EA Stop; $r['watchdog_stopped']=$true } catch { $r['watchdog_stopped']="err: $($_.Exception.Message)" }
Start-Sleep 2
Get-Process gui-agent -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep 3
$r['agent_running_after_stop']=[bool](Get-Process gui-agent -EA SilentlyContinue)

# keep the original ONCE - never overwrite a good backup with an already-swapped binary
$bak = $dst + '.orig'
if(-not (Test-Path $bak)){ Copy-Item -LiteralPath $dst -Destination $bak -Force -EA SilentlyContinue; $r['backup_made']=$true }
else { $r['backup_made']='already existed (kept)' }

Copy-Item -LiteralPath $src -Destination $dst -Force -EA SilentlyContinue
$r['dst_size']=(Get-Item $dst).Length
$r['dst_hash16']=(Get-FileHash $dst -Algorithm SHA256).Hash.Substring(0,16)
$r['swapped']=($r['dst_size'] -eq $r['new_size'])

try { Start-Service QubesGuiWatchdog -EA Stop; $r['watchdog_started']=$true } catch { $r['watchdog_started']="err: $($_.Exception.Message)" }
# POLL, do not sleep-and-peek. The watchdog restarts the agent on its own polling interval, so a
# fixed 8 s wait reported agent_running=false on a deploy that had in fact worked - a FALSE NEGATIVE
# that would have sent the next reader chasing a non-existent failure. Measured: the agent appeared
# ~30 s after the service start.
$ga=$null
for($i=0; $i -lt 30; $i++){
    $ga=Get-Process gui-agent -EA SilentlyContinue
    if($ga){ break }
    Start-Sleep 3
}
$r['agent_wait_secs']=$i*3
$r['agent_running']=[bool]$ga
$r['agent_pid']=if($ga){($ga.Id -join ',')}else{$null}
# prove the RUNNING binary is the new one, not a leftover
if($ga){ try { $r['running_image_size']=(Get-Item $ga.Path).Length } catch {} }
$r['ok']=($r['swapped'] -and $r['agent_running'])
Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress))
