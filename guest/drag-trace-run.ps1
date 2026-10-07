# Run ONE instrumented guest-native drag episode and hand back the raw trace lines.
#
# Two modes, and the difference matters:
#   -Sim 1  drives a SYNTHETIC drag (dragsim.c). Use it to prove the trace is alive and to
#           measure the announce cadence. It is NOT a verdict on the wobble - the owner's
#           standing rule is that scripted drags have never reproduced it (dragsim.h).
#   -Sim 0  arms the trace and waits: the HUMAN drags, and the same lines are produced by the
#           real pointer. This is the run that decides anything.
#
# Everything it configures is read at agent Init, so the agent is restarted here on purpose;
# the running binary's hash is reported so a run against the wrong build is visible rather
# than assumed.
[CmdletBinding()]
param(
    [int]$Sim = 1,
    [int]$DurationMs = 6000,
    [int]$WaitMs = 0,          # extra time to hold the trace open (hand-drag mode)
    [int]$CfgGuard = -1,       # InputDragCfgGuard: -1 leave alone, 0/1 set
    [int]$Quantise = -1,       # InputDragQuantise
    [int]$Interp = -1,         # InputDragOriginInterp
    [int]$AdoptMs = -1,
    [int]$AnnounceMs = -1,
    [int]$PerfLog = -1,        # QGAPERF per-frame lines: the load the 2026-08-16 tuning was fitted under
    [int]$ProtoFull = -1,      # full ProtoTrace (DAMAGE flood) - only for reproducing the old load
    [int]$Lines = 4000
)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
function SetIf($name, $val) { if ($val -ge 0) { Set-ItemProperty $k -Name $name -Value $val -Type DWord } }

Set-ItemProperty $k -Name ProtoTraceDrag -Value 1 -Type DWord
SetIf 'ProtoTrace'            $ProtoFull
SetIf 'PerfLog'               $PerfLog
SetIf 'InputDragCfgGuard'     $CfgGuard
SetIf 'InputDragQuantise'     $Quantise
SetIf 'InputDragOriginInterp' $Interp
SetIf 'InputDragAdoptMs'      $AdoptMs
SetIf 'InputDragAnnounceMs'   $AnnounceMs
Set-ItemProperty $k -Name DragSim   -Value $(if ($Sim) { 1 } else { 0 }) -Type DWord
Set-ItemProperty $k -Name DragSimMs -Value $DurationMs -Type DWord
Set-ItemProperty $k -Name DragSimGo -Value 0 -Type DWord

# A window to drag, started by THIS run and held by handle (owner 2026-10-07: a notepad found by
# name is someone else's - never adopted as the target). A hand-drag run drags the window this
# script brings up; nothing already open is touched or replaced.
Add-Type @"
using System;using System.Runtime.InteropServices;
public class DTR {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
$np = Start-Process notepad -PassThru -EA SilentlyContinue
$deadline = (Get-Date).AddSeconds(10)
while ($np -and (Get-Date) -lt $deadline) { try { $np.Refresh() } catch { }; if ($np.MainWindowHandle -ne 0) { break }; Start-Sleep -Milliseconds 250 }
if ($np -and $np.MainWindowHandle -eq 0) { $np = $null }
if ($np) {
    [DTR]::MoveWindow($np.MainWindowHandle, 600, 400, 900, 650, $true) | Out-Null
    [DTR]::SetForegroundWindow($np.MainWindowHandle) | Out-Null
}

# Restart the agent so the switches above are actually in force - THROUGH THE SERVICE THAT OWNS
# IT, turnover proven (guest/restart-gui-agent.ps1, pushed next to this script). The "trap" this
# comment used to record - "stopping the SERVICE would not recycle the agent" - is RETIRED: since
# 2026-10-03 (watchdog.c StopOwnAgent) the service stop ends the agent it started and the start
# launches a fresh one; the old `Get-Process gui-agent | Stop-Process` raced that relaunch (owner
# 2026-10-07: never by name).
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; Write-Output 'RESTART INVALID-INSTRUMENT helper-missing: push guest/restart-gui-agent.ps1 next to this script'; Write-Output '=== END ==='; exit 3 }
. $helper
$ra = Restart-GuiAgent
foreach ($ln in @($ra.lines)) { Write-Output $ln }
if (-not $ra.ok) { Write-Output '=== RESULT ==='; Write-Output ("RESTART INVALID-INSTRUMENT " + $ra.reason); Write-Output '=== END ==='; exit 3 }
$proc = Get-Process -Id $ra.new_pid -EA SilentlyContinue
$hash = if ($proc -and $proc.Path) { (Get-FileHash $proc.Path -Algorithm SHA256).Hash.Substring(0,16) } else { '' }

# Read only what THIS episode writes: remember the log length now (the NEW agent's log, which
# the restart proved).
$log = Get-Item -LiteralPath (Join-Path $ra.log_dir $ra.new_log) -EA SilentlyContinue
$before = 0
if ($log) { $before = @(Get-Content -LiteralPath $log.FullName -EA SilentlyContinue).Count }

if ($Sim) {
    Set-ItemProperty $k -Name DragSimGo -Value 1 -Type DWord
    Start-Sleep -Milliseconds ($DurationMs + 4000)
}
if ($WaitMs -gt 0) { Start-Sleep -Milliseconds $WaitMs }

$new = @()
if ($log) {
    $all = @(Get-Content -LiteralPath $log.FullName -EA SilentlyContinue)
    if ($all.Count -gt $before) { $new = $all[$before..($all.Count-1)] }
}
$trace = @($new | Where-Object { $_ -match 'QGAPROTO|QGADRAGSIM|QGADRAGQUANT|QGADRAGINTERP|QGADRAGCFGGUARD|QGAPROTO ' })
if ($trace.Count -gt $Lines) { $trace = $trace[0..($Lines-1)] }

Write-Output '=== RESULT ==='
Write-Output ("AGENT_HASH=" + $hash)
Write-Output ("AGENT_PID=" + $(if ($proc) { $proc.Id } else { 'none' }))
Write-Output ("HWND=" + $(if ($np) { '0x{0:X}' -f [int64]$np.MainWindowHandle } else { 'none' }))
Write-Output ("LOG=" + $(if ($log) { $log.Name } else { 'none' }))
Write-Output ("NEW_LINES=" + $new.Count)
Write-Output ("TRACE_LINES=" + $trace.Count)
Write-Output '=== TRACE ==='
$trace | ForEach-Object { Write-Output $_ }
Write-Output '=== END ==='
