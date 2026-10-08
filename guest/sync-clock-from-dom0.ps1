# sync-clock-from-dom0.ps1 - pull the time from dom0 and set this guest's clock, at every boot.
#
# WHY THIS EXISTS. The product already had the PUSH half: dom0 calls qubes.SetDateTime, which runs
# qubes-rpc-services\set-time.ps1. Nothing ever ran the PULL half at startup - update-time.bat has
# been in the tree the whole time and is called by nothing but qubes.SuspendPostAll (resume) - so a
# guest whose clock was wrong stayed wrong until dom0 happened to push, or for ever.
#
# MEASURED 2026-10-08 on win11r-logvol: the clock was THREE HOURS ahead of the host's with the
# timezone set to UTC, so the guest believed that was UTC. Every --since log window on it silently
# admitted three hours of older lines, which made a clean boot read as two errors, and no amount of
# fixing the agent would have fixed that.
#
# THE WAIT IS A BOUNDED FAILURE DETECTOR, not a fix for a race: qrexec is not up the instant the
# task fires, so this retries, and it says WHICH exit it took - the time arrived, dom0 refused, or
# the deadline passed. A clock left unset is an ERROR line in the guest's own log, never silence.
param(
    [int]$DeadlineSeconds = 180,
    [int]$IntervalSeconds = 10
)
$ErrorActionPreference = 'Continue'

$tools = $env:QUBES_TOOLS
if (-not $tools) {
    try { $tools = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction Stop).InstallDir } catch { }
}
if (-not $tools -or -not (Test-Path -LiteralPath $tools)) {
    Write-Output "CLOCKSYNC FATAL: QUBES_TOOLS is not set and InstallDir is unreadable - cannot find qrexec-client-vm"
    exit 2
}
$svc = Join-Path $tools 'qubes-rpc-services\log.ps1'
if (Test-Path -LiteralPath $svc) { . $svc } else {
    function LogInfo([string]$m) { Write-Output "INFO  $m" }
    function LogError([string]$m) { Write-Output "ERROR $m" }
    function LogWarning([string]$m) { Write-Output "WARN  $m" }
}
$client = Join-Path $tools 'bin\qrexec-client-vm.exe'
$setter = Join-Path $tools 'qubes-rpc-services\set-time.ps1'
foreach ($p in @($client, $setter)) {
    if (-not (Test-Path -LiteralPath $p)) { LogError "CLOCKSYNC FATAL: $p is missing"; exit 2 }
}

$before = (Get-Date).ToUniversalTime()
$deadline = (Get-Date).AddSeconds($DeadlineSeconds)
$exit = 'deadline'
$lastErr = ''
while ((Get-Date) -lt $deadline) {
    # UNQUOTED arguments: qrexec-client-vm takes domain|service as ONE argv entry and quoting it
    # makes the service name part of the literal (memory: qrexec-client-vm arg quoting).
    $out = & $client '@default|qubes.GetDate' 2>&1
    $rc = $LASTEXITCODE
    $line = @($out | Where-Object { $_ -is [string] -and $_.Trim() }) | Select-Object -First 1
    if ($rc -eq 0 -and $line) {
        # set-time.ps1 does the parsing, the UTC handling, the verification and its own logging.
        $line | & powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $setter
        if ($LASTEXITCODE -eq 0) { $exit = 'set' } else { $exit = 'setter-refused' }
        break
    }
    $lastErr = "rc=$rc out='$(($out | Out-String).Trim() -replace '\s+', ' ')'"
    if ($rc -ne 0 -and $out -match 'denied|refused|no such domain') { $exit = 'dom0-refused'; break }
    Start-Sleep -Seconds $IntervalSeconds
}

$after = (Get-Date).ToUniversalTime()
switch ($exit) {
    'set' {
        LogInfo "CLOCKSYNC the clock was pulled from dom0 at boot (was $($before.ToString('o')), now $($after.ToString('o')))"
        exit 0
    }
    'setter-refused' {
        LogError "CLOCKSYNC dom0 gave the time but set-time.ps1 refused it - see its SETTIME line; the clock is UNCHANGED at $($after.ToString('o'))"
        exit 1
    }
    'dom0-refused' {
        LogError "CLOCKSYNC dom0 refused qubes.GetDate ($lastErr) - the clock stays at $($after.ToString('o')) and every log window on this guest is suspect"
        exit 1
    }
    default {
        LogError "CLOCKSYNC no time from dom0 within $DeadlineSeconds s (last: $lastErr) - the clock stays at $($after.ToString('o')) and every log window on this guest is suspect"
        exit 1
    }
}
