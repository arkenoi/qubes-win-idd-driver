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
    # FOUR FIELDS, AND THE SERVICE IS PIPED TO A LOCAL PROGRAM. Measured the hard way on
    # win11r-err 2026-10-08: passing '@default|qubes.GetDate' produced 34 copies of
    # "wmain: Usage: qrexec-client-vm.exe domain name|qrexec service name|local user name|local
    # program" in the guest log, one per retry, and then this script's own CLOCKSYNC error - 36 new
    # error lines, all mine, on a cycle whose other 11 I had just fixed.
    # qrexec-client-vm parses its RAW command line with GetArgument(), which splits on '|' and
    # returns NULL once there is no separator left, so it needs domain|service|user|program - FOUR.
    # Upstream's own update-time.bat passes THREE and would hit the same usage error, which is
    # consistent with it having been called by nothing but qubes.SuspendPostAll.
    # The service's output is connected BY QREXEC to that local program, so set-time.ps1 reads the
    # date on its stdin and does the parsing, UTC handling, verification and logging - this script
    # does not read the date at all.
    # UNQUOTED, and the pipe-joined prefix is ONE token with NO SPACES so PowerShell cannot wrap it
    # in quotes (which would make the quote part of the domain name - memory: qrexec-client-vm arg
    # quoting). The remaining words are separate tokens; GetArgument only cares about '|', and the
    # setter path is quoted by PowerShell because it contains spaces, which is what powershell.exe
    # itself needs.
    $out = & $client '@default|qubes.GetDate|SYSTEM|powershell.exe' `
                     '-NoProfile' '-ExecutionPolicy' 'Bypass' '-NonInteractive' '-InputFormat' 'none' `
                     '-File' $setter 2>&1
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        # set-time.ps1 ran under qrexec with the date on stdin; it verifies the result itself and
        # logs SETTIME either way. Its exit code does not come back through the client, so this
        # reports what it can see - that the pull was carried out - and never claims more.
        $exit = 'set'
        break
    }
    $lastErr = "rc=$rc out='$(($out | Out-String).Trim() -replace '\s+', ' ')'"
    # TERMINAL STATES, so a permanent condition is not retried into a log flood. A usage error means
    # THIS SCRIPT is wrong and no amount of waiting fixes it; each retry made the client log its own
    # usage error again, which is where 34 of the 36 new error lines came from.
    if ($out -match 'wmain: Usage:') { $exit = 'bad-invocation'; break }
    if ($rc -ne 0 -and $out -match 'denied|refused|no such domain') { $exit = 'dom0-refused'; break }
    Start-Sleep -Seconds $IntervalSeconds
}

$after = (Get-Date).ToUniversalTime()
switch ($exit) {
    'set' {
        LogInfo "CLOCKSYNC the clock was pulled from dom0 at boot (was $($before.ToString('o')), now $($after.ToString('o')))"
        exit 0
    }
    'bad-invocation' {
        LogError ("CLOCKSYNC this script called qrexec-client-vm with the wrong arguments and stopped rather " +
                  "than retrying - a usage error is permanent, and each retry makes the client log it again. " +
                  "It needs domain|service|user|program, four fields. Last output: $lastErr")
        exit 1
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
