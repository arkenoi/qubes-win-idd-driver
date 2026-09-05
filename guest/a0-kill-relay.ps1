# a0-kill-relay.ps1 — kill the toast-bridge's --relay child(ren) WITHOUT touching the resident
# --bridge, to prove the bridge notices the dropped connection, restores banners, and reconnects.
#
# RUN AS SYSTEM (qtest pushrun -> qubes.VMShell), NOT run-as-user. Rationale (audit 2026-09-05):
#   - Under the old run-as-user LIMITED token, Get-CimInstance/Get-Process returned an empty or
#     CommandLine=NULL process list, so RELAY-KILL-PROCS was empty and KILLED-RELAY=0 was VACUOUS
#     (the harness then passed P6c/killrelay without ever severing a connection).
#   - As SYSTEM the FULL process list and every process CommandLine are visible, so the relay is
#     identified DIRECTLY and robustly: the notifhost.exe whose command line contains "--relay"
#     (spawned per-connection by ConnUp via qrexec-client-vm; see tools/notifhost/notifhost.cpp).
#     The resident bridge's command line contains "--bridge --agent-pid" instead, so the two never
#     collide and no age/mutex heuristic is needed.
#   - The Local\ singleton mutex is PER-SESSION and invisible from SYSTEM's session 0, so the old
#     mutex heuristic cannot be used from this context — CommandLine matching replaces it.
$ErrorActionPreference = 'Continue'

# CIM enumeration (as SYSTEM this fills ProcessId + CommandLine for every notifhost.exe).
$procs = @(Get-CimInstance Win32_Process -Filter "Name='notifhost.exe'" |
           Select-Object ProcessId, CommandLine, CreationDate |
           Sort-Object CreationDate)
Write-Output ("RELAY-KILL-PROCS=" + (($procs | ForEach-Object { $_.ProcessId }) -join ','))

# Direct role identification from the command line (visible as SYSTEM). Substring match via -like
# so the '--' is treated literally, not as a regex.
$relays  = @($procs | Where-Object { $_.CommandLine -like '*--relay*' })
$bridges = @($procs | Where-Object { $_.CommandLine -like '*--bridge*' })
Write-Output ("RELAY-KILL-RELAYS=" + (($relays  | ForEach-Object { $_.ProcessId }) -join ','))
Write-Output ("RELAY-KILL-BRIDGE=" + (($bridges | ForEach-Object { $_.ProcessId }) -join ','))

$victims = @()
if ($relays.Count -ge 1) {
    $victims = $relays                                   # the normal, direct path
} elseif (@($procs | Where-Object { $_.CommandLine }).Count -eq 0 -and $procs.Count -ge 2) {
    # FALLBACK — should NOT happen as SYSTEM. No CommandLine on any notifhost at all: the bridge
    # strictly predates its relay (the relay is spawned by the bridge's own ConnUp), so spare the
    # OLDEST and treat the rest as relay. Logged distinctly so a fallback kill is never mistaken
    # for a direct one, and never fires when there is only one notifhost (nothing safe to kill).
    $victims = @($procs | Select-Object -Skip 1)
    Write-Output ("RELAY-KILL-NOTE=cmdline-unavailable-age-fallback-spared=" + $procs[0].ProcessId)
} elseif ($procs.Count -lt 2) {
    Write-Output "RELAY-KILL-NOTE=no-relay-present"      # bridge only / not connected -> truthful 0
} else {
    Write-Output "RELAY-KILL-NOTE=no-relay-cmdline-match"
}

foreach ($v in $victims) { Stop-Process -Id $v.ProcessId -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 1500
# Report only CONFIRMED kills (re-check each victim is actually gone), never the attempt count.
$n = 0
foreach ($v in $victims) {
    if (Get-Process -Id $v.ProcessId -EA SilentlyContinue) {
        Write-Output ("RELAY-KILL-SURVIVOR=" + $v.ProcessId)
    } else { $n++ }
}
Write-Output ("KILLED-RELAY=" + $n)
