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

# A window to drag. Reused if one is already open, so a hand-drag run does not have its
# target replaced underneath the person about to drag it.
Add-Type @"
using System;using System.Runtime.InteropServices;
public class DTR {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
$np = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $np) {
    Start-Process notepad
    Start-Sleep -Seconds 4
    $np = Get-Process notepad -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if ($np) {
    [DTR]::MoveWindow($np.MainWindowHandle, 600, 400, 900, 650, $true) | Out-Null
    [DTR]::SetForegroundWindow($np.MainWindowHandle) | Out-Null
}

# Restart the agent so the switches above are actually in force. The watchdog respawns it;
# stopping the SERVICE would not recycle the agent (recorded trap).
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 10
$proc = Get-Process gui-agent -EA SilentlyContinue | Select-Object -First 1
$hash = if ($proc -and $proc.Path) { (Get-FileHash $proc.Path -Algorithm SHA256).Hash.Substring(0,16) } else { '' }

# Read only what THIS episode writes: remember the log length now.
$log = Get-ChildItem 'Q:\Qubes Logs\gui-agent-*.log' -EA SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
