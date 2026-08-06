# Minimal, side-agnostic performance probe: how much CPU does gui-agent burn while the
# desktop is under a FIXED synthetic load, and how much when idle?
#
# Why this metric: it is the only meaningful number that exists on BOTH sides. Stock QWT's
# gui-agent carries no instrumentation at all (verified: zero QGAPERF strings in ITL's
# binary), so the fork's per-frame telemetry cannot be compared against it. Process CPU
# time is measured by Windows for both, identically.
#
# Usage: cpu-bench.ps1 [-LoadSec 40] [-IdleSec 30]
# Emits BENCH lines; the caller runs it once per side with the same arguments.
param([int]$LoadSec = 40, [int]$IdleSec = 30)
$ErrorActionPreference = 'Continue'

function AgentCpu {
    $p = Get-Process gui-agent -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return [double]$p.CPU        # total processor seconds since start
}

$a0 = AgentCpu
if ($null -eq $a0) { Write-Output 'BENCH error=no_agent'; exit 1 }

# --- idle baseline -----------------------------------------------------------
$t0 = Get-Date
Start-Sleep -Seconds $IdleSec
$a1 = AgentCpu
$idleWall = ((Get-Date) - $t0).TotalSeconds
$idleCpu  = $a1 - $a0
Write-Output ("BENCH idle_cpu_s={0:N2} idle_wall_s={1:N1} idle_pct={2:N2}" -f $idleCpu, $idleWall, (100*$idleCpu/$idleWall))

# --- fixed synthetic load: a window dragged in a circle while repainting -----
# (instrumentation/activity-gen.ps1 is the project's existing deterministic scene)
$gen = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\activity-gen.ps1'
if (-not (Test-Path $gen)) { Write-Output 'BENCH error=no_activity_gen'; exit 1 }
$t0 = Get-Date
$a0 = AgentCpu
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$gen`"",'-Seconds',"$LoadSec" -WindowStyle Minimized
Start-Sleep -Seconds ($LoadSec + 3)
$a1 = AgentCpu
$loadWall = ((Get-Date) - $t0).TotalSeconds
$loadCpu  = $a1 - $a0
Write-Output ("BENCH load_cpu_s={0:N2} load_wall_s={1:N1} load_pct={2:N2}" -f $loadCpu, $loadWall, (100*$loadCpu/$loadWall))
Write-Output ("BENCH agent_hash=" + (Get-FileHash 'C:\Program Files\Qubes Tools\bin\gui-agent.exe').Hash.Substring(0,16))
