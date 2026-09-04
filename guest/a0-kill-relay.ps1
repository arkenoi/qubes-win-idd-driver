# a0-kill-relay.ps1 — kill the toast-bridge's --relay child (the qrexec/vchan splice) without
# touching the resident --bridge, to prove the bridge notices the dropped connection, restores
# banners, and auto-reconnects. Run as the user (both processes live in the user session).
#
# Do NOT select by CommandLine: the relay is spawned by the qrexec-agent service, so its
# Win32_Process CommandLine reads NULL from this limited-token session — a `-match '--relay'`
# filter matches nothing and KILLED-RELAY=0 let P6c pass vacuously (audit 2026-09-05).
# Discriminate by ROLE instead, from facts in tools/notifhost/notifhost.cpp:
#   - only BridgeMain holds the named mutex 'Local\QubesToastBridgeSingleton' (and rewrites
#     the heartbeat); the relay holds no mutex and touches no files;
#   - the bridge strictly PREDATES any relay — the relay is spawned by the bridge's own
#     ConnUp (via qrexec-client-vm -> qrexec-agent), so with the bridge mutex live the OLDEST
#     notifhost.exe is the bridge and everything younger is relay(s).
# Kill the non-bridge processes, then RE-CHECK they are gone and report only CONFIRMED kills
# (the old `$n++` after `Stop-Process -EA SilentlyContinue` counted failed kills too).
$ErrorActionPreference = 'Continue'

# CIM for enumeration + CreationDate (the WMI provider fills these even where a direct
# process-handle StartTime query would be refused); Stop-Process for the kill itself.
$procs = @(Get-CimInstance Win32_Process -Filter "Name='notifhost.exe'" |
           Sort-Object CreationDate)
Write-Output ("RELAY-KILL-PROCS=" + (($procs | ForEach-Object { $_.ProcessId }) -join ','))

$bridgeUp = $false
$m = $null
try {
    if ([System.Threading.Mutex]::TryOpenExisting('Local\QubesToastBridgeSingleton', [ref]$m)) {
        $bridgeUp = $true; $m.Dispose()
    }
} catch { $bridgeUp = $true }   # open failed but the mutex EXISTS => a bridge is alive
Write-Output ("RELAY-KILL-BRIDGEMUTEX=" + $(if ($bridgeUp) { 'live' } else { 'absent' }))

$victims = @()
if ($bridgeUp -and $procs.Count -ge 2) {
    $victims = @($procs | Select-Object -Skip 1)   # spare the oldest: that is the bridge
    Write-Output ("RELAY-KILL-SPARED=" + $procs[0].ProcessId)
} elseif (-not $bridgeUp) {
    # no live bridge => nothing is safely identifiable as ITS relay; report 0 truthfully
    # (the harness turns KILLED-RELAY=0 into an INSTRUMENT verdict, not a pass)
    Write-Output "RELAY-KILL-NOTE=no-bridge-mutex"
}

foreach ($v in $victims) { Stop-Process -Id $v.ProcessId -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 1500
$n = 0
foreach ($v in $victims) {
    if (Get-Process -Id $v.ProcessId -EA SilentlyContinue) {
        Write-Output ("RELAY-KILL-SURVIVOR=" + $v.ProcessId)
    } else { $n++ }
}
Write-Output ("KILLED-RELAY=" + $n)
