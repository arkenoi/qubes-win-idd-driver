# Pull the QGAPROTO drag trace WITHOUT touching the agent.
#
# Deliberately separate from drag-trace-run.ps1: that script RESTARTS the agent to apply its
# switches, which would destroy the very episode being collected. Pulling must never disturb
# the subject.
[CmdletBinding()]
param([int]$Tail = 6000)
$ErrorActionPreference = 'Continue'

$proc = Get-Process gui-agent -EA SilentlyContinue | Select-Object -First 1
$hash = if ($proc -and $proc.Path) { (Get-FileHash $proc.Path -Algorithm SHA256).Hash.Substring(0,16) } else { '' }
$log = Get-ChildItem 'Q:\Qubes Logs\gui-agent-*.log' -EA SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Output '=== RESULT ==='
Write-Output ("AGENT_HASH=" + $hash)
Write-Output ("AGENT_PID=" + $(if ($proc) { $proc.Id } else { 'none' }))
Write-Output ("LOG=" + $(if ($log) { $log.Name } else { 'none' }))
if (-not $log) { Write-Output 'NO LOG'; exit 1 }

$all = @(Get-Content -LiteralPath $log.FullName -EA SilentlyContinue)
Write-Output ("LOG_LINES=" + $all.Count)
$trace = @($all | Where-Object { $_ -match 'QGAPROTO|QGADRAGSIM|QGADRAG' })
Write-Output ("TRACE_LINES=" + $trace.Count)
if ($trace.Count -gt $Tail) { $trace = $trace[($trace.Count-$Tail)..($trace.Count-1)] }
Write-Output '=== TRACE ==='
$trace | ForEach-Object { Write-Output $_ }
Write-Output '=== END ==='
