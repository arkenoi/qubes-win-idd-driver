# Tune the drag servo + latency knobs without a rebuild, then restart the agent.
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
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 8
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
$c = Get-ItemProperty $k
Write-Output '=== RESULT ==='
@{ agent_pid = if ($p) { $p.Id } else { $null }
   gain = $c.InputDragServoGainPct; tau = $c.InputDragServoTauMs; deadband = $c.InputDragServoDeadbandPx
   moncache = $c.MonInfoCache; servo = $c.InputDragServo; freeze = $c.InputDragFreeze
   freezecontent = $c.InputDragFreezeContent; slice = $c.InputDragSlice; evtprio = $c.DragEventPriority } | ConvertTo-Json -Compress
