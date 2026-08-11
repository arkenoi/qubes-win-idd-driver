# Hypothesis-discriminator grep from the sanitizer researcher: counts + last lines for each
# stability-overhaul marker across the newest agent log.
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) $($log.Length) ==="
$pats = 'CREATEDUP','GEOMDROP','GEOMCLAMP','VCHANSLOW','VCHANWAIT','VCHANWEDGE','no CREATE was sent','gui daemon confirms screen destruction','A7DEGRADED','handler failed'
$content = Get-Content $log.FullName
foreach ($p in $pats) {
    $m = $content | Select-String -SimpleMatch $p
    Write-Output "--- '$p' = $(($m | Measure-Object).Count)"
    $m | Select-Object -Last 4 | ForEach-Object { $_.Line }
}
Write-Output '=== END ==='
