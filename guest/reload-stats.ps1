<#
.SYNOPSIS
    Count how often the agent's mode RELOAD took the IOCTL path, and how often it fell back to a
    PnP device restart - from this guest's own agent logs.

.DESCRIPTION
    The PnP device restart is the riskiest device operation our agent performs at runtime (Jev
    2026-09-23: 0.79 among our runtime paths), and by construction it is only reached when the
    QIDD control interface is missing or dead - an old driver generation, a device that is not
    started, a dead UMDF host, or the identical-bytes-restage breakage (0xC0000476). So the
    question "how often does it fire, and why" is answerable from the logs, and it must be
    ANSWERED rather than deduced: on a healthy current build the count should be zero.

    Emits one RELOADSTATS line plus the matching log lines, so a zero is distinguishable from
    "no logs were found" - a count of zero over zero logs is not evidence of anything.
#>
$ErrorActionPreference = 'Continue'
$dirs = @()
try {
    $cfg = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name 'LogDir' -EA Stop).LogDir
    if ($cfg) { $dirs += $cfg }
} catch { }
$dirs += 'Q:\Qubes Logs'
$dirs += 'C:\Program Files\Qubes Tools\log'
$dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)

$logs = @()
foreach ($d in $dirs) { if (Test-Path $d) { $logs += Get-ChildItem $d -Filter 'gui-agent*.log' -EA SilentlyContinue } }

$pat = @{
    ioctl_ok       = 'QIDD ioctl-reload ok'
    fallback       = 'ioctl-reload unavailable'
    pnp_replugged  = 'replugged Qubes IDD device'
    throttled      = 'M7THROTTLE'
    modeset_write  = 'M0BLINK obtain-start'
}
$counts = @{}
foreach ($k in $pat.Keys) { $counts[$k] = 0 }
$hits = @()
foreach ($l in $logs) {
    $c = Get-Content $l.FullName -EA SilentlyContinue
    if (-not $c) { continue }
    foreach ($k in $pat.Keys) {
        $m = @($c | Select-String -SimpleMatch $pat[$k])
        $counts[$k] += $m.Count
        if ($k -in @('fallback','pnp_replugged') -and $m.Count -gt 0) {
            $hits += ($m | Select-Object -Last 4 | ForEach-Object { "$($l.Name): $($_.Line)" })
        }
    }
}
Write-Output ("RELOADSTATS logs={0} ioctl_ok={1} fallback={2} pnp_replugged={3} throttled={4} modeset_obtains={5}" -f `
    $logs.Count, $counts.ioctl_ok, $counts.fallback, $counts.pnp_replugged, $counts.throttled, $counts.modeset_write)
foreach ($h in $hits) { Write-Output ("RELOADHIT " + $h) }
if ($logs.Count -eq 0) { Write-Output "RELOADSTATS WARNING no gui-agent logs found - a zero above means NOTHING" }
