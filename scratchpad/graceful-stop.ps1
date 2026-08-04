# Stop gui-agent.exe the way it was DESIGNED to be stopped: signal Global\QGA_SHUTDOWN, which
# is watchedEvents[0] in WatchForEvents (main.c:3483, name in include/common.h:46) and sets
# exitLoop, so the agent runs its real exit path including libvchan_close.
#
# Every harness in this project so far used Stop-Process -Force / taskkill /F, i.e.
# TerminateProcess - no user-mode cleanup, vchan never closed. taskkill WITHOUT /F does not
# work either: it posts WM_CLOSE and gui-agent is windowless, so it simply ignores it
# (measured: still running after 20 s). The named event is the supported route.
#
# Then let the watchdog respawn the agent and report whether the NEW instance gets a vchan
# client - i.e. whether gui-daemon survived.
param([int]$WaitExitSec = 30, [int]$WaitRespawnSec = 60)

$ErrorActionPreference = 'Continue'
$logdir = 'C:\Program Files\Qubes Tools\log'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Ev {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetEvent(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@

function AgentPid { $p = Get-Process gui-agent -ErrorAction SilentlyContinue; if ($p) { $p.Id } else { 0 } }
function LatestLog { Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

$pid0 = AgentPid
$log0 = LatestLog
if ($pid0 -eq 0) { Write-Output 'RESULT status=FAIL reason=no_agent_running'; exit 1 }
Write-Output ("STEP0 pid=$pid0 log=" + $log0.Name + " maps=" + @(Select-String -Path $log0.FullName -Pattern 'SendWindowMap').Count)

# EVENT_MODIFY_STATE = 0x0002
$h = [Ev]::OpenEvent(0x0002, $false, 'Global\QGA_SHUTDOWN')
if ($h -eq [IntPtr]::Zero) {
  Write-Output ("RESULT status=FAIL reason=OpenEvent_failed err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  exit 1
}
$ok = [Ev]::SetEvent($h)
[void][Ev]::CloseHandle($h)
Write-Output "STEP1 signalled=$ok event=Global\QGA_SHUTDOWN"

$exited = $false
for ($i = 1; $i -le $WaitExitSec; $i++) {
  Start-Sleep -Seconds 1
  if ((AgentPid) -ne $pid0) { $exited = $true; break }
}
Write-Output "STEP2 exited=$exited after_s=$i"
if (-not $exited) { Write-Output 'RESULT status=FAIL reason=agent_ignored_shutdown_event'; exit 1 }

# did it close the vchan on the way out?
$tail = Get-Content $log0.FullName -Tail 40
$closed = @($tail | Select-String -Pattern 'libvchan_close|VchanClose|vchan disconnected|Shutdown').Count
Write-Output ("STEP3 exit_markers=$closed")
$tail | Select-String -Pattern 'libvchan|Shutdown|exit|Stopping' | Select-Object -Last 6 | ForEach-Object { Write-Output ("  | " + $_.Line) }

$new = 0
for ($i = 1; $i -le $WaitRespawnSec; $i++) {
  Start-Sleep -Seconds 1
  $new = AgentPid
  if ($new -ne 0 -and $new -ne $pid0) { break }
}
Start-Sleep -Seconds 12
$log1 = LatestLog
$maps     = @(Select-String -Path $log1.FullName -Pattern 'SendWindowMap').Count
$awaiting = @(Select-String -Path $log1.FullName -Pattern 'Awaiting for a vchan client').Count
$conn     = @(Select-String -Path $log1.FullName -Pattern 'vchan client has connected|client connected').Count

Write-Output ("STEP4 respawned_pid=$new new_log=" + ($log1.Name -ne $log0.Name) + " log=" + $log1.Name)
Write-Output ("STEP5 maps=$maps awaiting=$awaiting connected=$conn")
Write-Output ("RESULT status=OK method=graceful_event respawned=$new maps=$maps connected=$conn")
