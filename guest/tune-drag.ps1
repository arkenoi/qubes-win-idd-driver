# Tune the drag servo + latency knobs without a rebuild, then restart the agent through the
# service that owns it (guest/restart-gui-agent.ps1, pushed next to this script; owner 2026-10-07:
# never `Get-Process gui-agent | Stop-Process`, which raced the watchdog's own relaunch).
# All values live under the gui-agent MODULE key (the log library and perf.c both read the
# module key first - a value on the parent key is silently overridden, which cost hours).
param(
    [int]$GainPct = -1,      # InputDragServoGainPct: how much of the cursor deviation is applied per event
    [int]$TauMs = -1,        # InputDragServoTauMs: assumed announce->apply lag used by the predictor
    [int]$DeadbandPx = -1,   # InputDragServoDeadbandPx
    [int]$MonCache = -1,     # MonInfoCache: cache the monitor/display-mode query (kills the upd spikes)
    [int]$Servo = -1,        # InputDragServo master switch
    [int]$Freeze = -1,       # InputDragFreeze fallback tier
    [int]$FreezeContent = -1,# InputDragFreezeContent: send no content updates while dragging
    [int]$Slice = -1,        # InputDragSlice: feed the dragged window from the desktop framebuffer
    [int]$EvtPrio = -1       # DragEventPriority: announce at input rate during a drag (smoothness)
)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
function SetIf($name, $val) { if ($val -ge 0) { Set-ItemProperty $k -Name $name -Value $val -Type DWord } }
SetIf 'InputDragServoGainPct'    $GainPct
SetIf 'InputDragServoTauMs'      $TauMs
SetIf 'InputDragServoDeadbandPx' $DeadbandPx
SetIf 'MonInfoCache'             $MonCache
SetIf 'InputDragServo'           $Servo
SetIf 'InputDragFreeze'          $Freeze
SetIf 'InputDragFreezeContent'   $FreezeContent
SetIf 'InputDragSlice'           $Slice
SetIf 'DragEventPriority'        $EvtPrio
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json -Compress; exit 3 }
. $helper
$ra = Restart-GuiAgent
foreach ($ln in @($ra.lines)) { Write-Output $ln }
$c = Get-ItemProperty $k
Write-Output '=== RESULT ==='
@{ agent_pid = $(if ($ra.ok) { $ra.new_pid } else { $null }); restart = $ra.verdict; restart_reason = $ra.reason
   gain = $c.InputDragServoGainPct; tau = $c.InputDragServoTauMs; deadband = $c.InputDragServoDeadbandPx
   moncache = $c.MonInfoCache; servo = $c.InputDragServo; freeze = $c.InputDragFreeze
   freezecontent = $c.InputDragFreezeContent; slice = $c.InputDragSlice; evtprio = $c.DragEventPriority } | ConvertTo-Json -Compress
