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
# task fires, so this retries, and it says WHICH exit it took - the time arrived, this script was
# called wrongly, or the deadline passed with the agent still unreachable. A clock left unset is an
# ERROR line in the guest's own log, never silence. It does NOT claim dom0 refused anything: the
# client it calls writes the request to the local agent and exits without reading a response, so a
# refusal by dom0 happens where no exit code of its can report it.
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
# THE BOUND IS MONOTONIC, BECAUSE THIS LOOP CAN STRADDLE THE CLOCK CORRECTION IT CAUSES.
# The pull is fire-and-forget: a request that succeeds hands dom0's date to a SEPARATE set-time.ps1
# process, which may set the clock while this loop is still running. A wall-clock bound then breaks
# in both directions - a guest corrected BACKWARD by dom0's offset (three hours, measured) would
# loop for three hours past its own limit, and one corrected forward would exit instantly.
# Stopwatch is QueryPerformanceCounter and a clock set cannot move it. The clock READINGS below stay
# wall-clock on purpose: comparing dom0's stamp against our own clock IS the measurement.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exit = 'deadline'
$lastErr = ''
while ($sw.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
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
    # ONLY WHAT THE CLIENT CAN ACTUALLY TELL US. Every return path in
    # core-agent/src/qrexec-client-vm/qrexec-client-vm.c is one of three things:
    #   * ERROR_INVALID_PARAMETER (87) for its own usage/argument errors - lines 64 and 82;
    #   * ERROR_OUTOFMEMORY (14) - line 86;
    #   * otherwise a win_perror/win_perror2 pass-through while converting its arguments, OPENING
    #     the local agent pipe (line 104) or WRITING the request into it (lines 110-134).
    #
    # THE CLIENT NEVER READS A RESPONSE. It writes the request to this guest's own qrexec agent and
    # exits at line 140; whether dom0 then allows or refuses the service happens afterwards, between
    # the agent and dom0, where this process cannot see it. So NO exit code from this client can
    # mean "dom0 refused" - and the branch that read ACCESS_DENIED (5) as a dom0 refusal was
    # claiming something the source cannot support. 0x2 was read the same way, and that is what
    # killed the feature: FILE_NOT_FOUND on line 104 is the local agent pipe not being there yet,
    # the ordinary state early in boot, and grading it terminal left the loop on its first attempt.
    # Measured on one build, 2026-10-14: one boot logged "dom0 refused ... open agent pipe failed
    # with error 0x2" while another logged the clock pulled successfully. A race, not a refusal.
    #
    # So the only terminal condition is the one that says THIS SCRIPT is wrong, which waiting cannot
    # fix and which floods the log if retried (34 of 36 error lines once came from exactly that).
    # Everything else is the local agent not being reachable YET: retried until the deadline, then
    # reported by the deadline exit, which carries the rc and the client's own output.
    if ($rc -eq 87 -or $out -match 'wmain: Usage:') { $exit = 'bad-invocation'; break }
    $lastErr = "$lastErr (the local qrexec agent is not reachable yet - retrying until the deadline)"
    Start-Sleep -Seconds $IntervalSeconds
}

$after = (Get-Date).ToUniversalTime()

# ---- WHICH CONVENTION DOES THIS QUBE'S RTC FOLLOW? Decided from an INDEPENDENT witness. -------
# RealTimeIsUniversal declares whether Windows reads the emulated RTC as UTC (1) or as local time
# (0). Only one is true for a given qube and the guest cannot be told which: dom0 sets the qube's
# `timezone` feature after we report in, which changes what the RTC holds at the next domain
# creation, and a subject can also be CREATED with that feature unset.
#
# THE FIRST VERSION OF THIS COMPARED THE GUEST'S CLOCK WITH ITSELF. It took the clock before the
# pull and the clock after it, and concluded "fits" whenever they agreed - but a pull that changes
# nothing makes those the same number, and this script cannot see whether the pull did anything:
# qrexec pipes dom0's date straight into set-time.ps1 and that script's exit code does not come back
# through the client (see the comment on the pull above, which says so). Measured on run 11: it
# reported "RealTimeIsUniversal=1 matches this qube's RTC convention" four times on a guest that was
# three hours out. A test whose reference is the thing under test cannot fail.
#
# THE WITNESS IS set-time.ps1, WHICH DID SEE DOM0'S VALUE. It logs, on every successful set:
#   SETTIME clock set to 2026-10-15T09:24:50.0000000Z (was -10821.2 s out, now 0 s; guest zone FLE
#   Standard Time, offset 02:00:00)
# That line carries everything this decision needs, all of it measured BEFORE the clock was touched:
#   * dom0's own UTC             - the reference, from outside this guest
#   * `was <skew> s out`         - dom0_utc MINUS the guest's clock, so the pre-set clock is
#                                  recoverable exactly (skew is negative when the guest ran ahead)
#   * `offset <hh:mm:ss>`        - the guest's zone offset at that moment
# From those, what the RTC held before anything wrote to it:
#   RealTimeIsUniversal=1  ->  RTC = clock_before
#   RealTimeIsUniversal=0  ->  RTC = clock_before + offset
# and the RTC holds true UTC when that equals dom0's value, or dom0 LOCAL when it equals dom0's
# value plus the offset. Each case names the value Windows should carry.
#
# NO WITNESS MEANS NO DECISION. If there is no SETTIME line from this boot, or it cannot be parsed,
# this says so and changes nothing - which is the behaviour the old version lacked.
function Get-ClockWitness {
    # The newest SETTIME line BY THE DOM0 TIMESTAMP IT CARRIES, as a hashtable, or $null.
    #
    # CHOSEN BY CONTENT, NOT BY FILE ORDER, AND NEVER BY MTIME. This used to sort the files by
    # LastWriteTime descending and then take the LAST match the pipeline emitted - which is the
    # newest line of the OLDEST file, not the newest line overall. It also anchored freshness on
    # guest file timestamps, which this very script moves backwards by hours when it corrects the
    # clock. dom0's own UTC, carried inside the line, is the only monotone reference available here.
    $dir = $null
    try { $dir = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir -ErrorAction Stop).LogDir } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path $tools 'log' }
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $best = $null
    $inv  = [Globalization.CultureInfo]::InvariantCulture
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'set-time.ps1-*.log' -ErrorAction Stop)) {
            foreach ($hit in @(Select-String -LiteralPath $f.FullName -Pattern 'SETTIME clock set to ' -ErrorAction SilentlyContinue)) {
                $mm = [regex]::Match($hit.Line, 'SETTIME clock set to (?<utc>\S+) \(was (?<skew>-?[0-9.]+) s out, now (?<res>-?[0-9.]+) s; guest zone (?<zone>.+?), offset (?<off>[-0-9:.]+)\)')
                if (-not $mm.Success) { continue }
                [datetime]$u = [datetime]::MinValue
                if (-not [datetime]::TryParse($mm.Groups['utc'].Value, $inv,
                        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal), [ref]$u)) { continue }
                [timespan]$o = [timespan]::Zero
                if (-not [timespan]::TryParse($mm.Groups['off'].Value, $inv, [ref]$o)) { continue }
                if ($null -ne $best -and $u -le $best.Dom0Utc) { continue }
                $best = @{
                    Dom0Utc = [datetime]::SpecifyKind($u, [DateTimeKind]::Utc)
                    SkewS   = [double]$mm.Groups['skew'].Value
                    Offset  = $o
                }
            }
        }
    } catch { }
    return $best
}

function Wait-ClockWitness {
    # THE PULL IS FIRE-AND-FORGET, SO THE WITNESS LANDS AFTER WE ASKED FOR IT. The client writes the
    # request to this guest's own qrexec agent and exits; dom0 then pipes its date into a SEPARATE
    # set-time.ps1 process, which writes the SETTIME line whenever it gets there. Reading the log
    # immediately afterwards therefore finds the PREVIOUS boot's line, or nothing at all - measured
    # on run 13's first cell, where CLOCKCONV refused at 14:18:14.479 while the line it needed was
    # written at 14:18:14.305, 174 ms earlier (CLOCKWITNESSMISSEDONFIRSTBOOT). That refusal was read
    # as "no witness exists", which is a different fact from "it has not landed yet".
    #
    # FRESHNESS IS JUDGED ON CONTENT, NOT ON A CLOCK THIS SCRIPT IS MOVING. A witness from this boot
    # carries dom0's UTC as it was moments ago, and the pull has just made our own clock agree with
    # dom0 - so this boot's witness sits close to our clock while an earlier boot's is hours or days
    # off. The clock is RE-READ on every attempt, because set-time.ps1 may correct it DURING the
    # wait, which is the whole reason for waiting.
    #
    # THREE EXITS: a fresh witness, the deadline with nothing on disk, or the deadline with only a
    # stale line - and the last two are reported rather than guessed around. Bounded, because a
    # witness that never arrives must not hold up the boot.
    # THE BOUND IS MONOTONIC AND THE FRESHNESS TEST IS NOT, and that split is the point. This wait
    # exists to span the moment set-time.ps1 sets the clock, so a wall-clock bound is exactly the
    # wrong instrument: a backward correction of dom0's offset - three hours, measured - would leave
    # the limit unreached for three hours and hang the boot. Stopwatch cannot be moved by a clock
    # set. The freshness comparison below MUST stay on the wall clock, because comparing dom0's own
    # stamp against our just-corrected clock is the measurement being made.
    param([int]$TimeoutSeconds = 20, [int]$ToleranceSeconds = 120)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stale = $null
    while ($true) {
        $cand = Get-ClockWitness
        if ($null -ne $cand) {
            $age = [math]::Abs(((Get-Date).ToUniversalTime() - $cand.Dom0Utc).TotalSeconds)
            if ($age -le $ToleranceSeconds) { return $cand }
            $stale = $cand
        }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Seconds 1
    }
    if ($null -ne $stale) {
        LogWarning ("CLOCKCONV the only SETTIME witness on disk is from an earlier boot (dom0 time " +
                    $stale.Dom0Utc.ToString('o') + " against this guest's " +
                    (Get-Date).ToUniversalTime().ToString('o') + ") - waited $TimeoutSeconds s for " +
                    "this boot's line and it did not arrive, so the convention was NOT decided")
    }
    return $null
}

if ($exit -eq 'set') {
    try {
        $w = Wait-ClockWitness
        if ($null -eq $w) {
            LogWarning ('CLOCKCONV no usable SETTIME witness arrived within the wait, so the RTC convention was NOT decided - ' +
                        'RealTimeIsUniversal is untouched and the clock stays as the pull left it. This script cannot ' +
                        'see dom0 time itself: qrexec hands it to set-time.ps1, whose exit code does not come back.')
        } else {
            $key   = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
            $cur   = $null
            try { $cur = (Get-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -ErrorAction Stop).RealTimeIsUniversal } catch { $cur = 0 }
            if ($null -eq $cur) { $cur = 0 }
            # THE OFFSET MUST BE THE ONE IN EFFECT, NOT THE ZONE'S BASE. set-time.ps1 logs
            # `(Get-TimeZone).BaseUtcOffset`, which for FLE Standard Time is 02:00:00 all year - while
            # the offset actually in effect under DST is 03:00:00. Using the base value made a real
            # three-hour displacement match NEITHER hypothesis, so the convention was never flipped:
            # measured on run 12's first cell - "the RTC fits NEITHER convention unambiguously: it held
            # 13:34:15Z, dom0 said 10:34:06Z, this guest's offset is 02:00:00". Derived here instead,
            # for the instant dom0's value belongs to, which is DST-aware by construction.
            $off = [TimeZoneInfo]::Local.GetUtcOffset($w.Dom0Utc)
            # The clock as it stood BEFORE set-time touched it: dom0's value minus the skew it measured.
            $clockBefore = $w.Dom0Utc.AddSeconds(-1 * $w.SkewS)
            $rtc  = if ($cur -eq 1) { $clockBefore } else { $clockBefore + $off }
            $tol  = 90
            $fitsUtc   = ([Math]::Abs(($rtc - $w.Dom0Utc).TotalSeconds) -lt $tol)
            $fitsLocal = ([Math]::Abs((($rtc - $off) - $w.Dom0Utc).TotalSeconds) -lt $tol)
            $want = $null
            if ($fitsUtc -and -not $fitsLocal)     { $want = 1 }
            elseif ($fitsLocal -and -not $fitsUtc) { $want = 0 }
            # A zero offset makes the two tests identical: there is nothing to tell apart, so nothing
            # is decided. Saying "it matches" there is how the old version justified itself.
            elseif ($fitsUtc -and $fitsLocal)      { $want = $null }
            if ($null -eq $want) {
                LogWarning ("CLOCKCONV the RTC fits NEITHER convention unambiguously: it held $($rtc.ToString('o')), " +
                            "dom0 said $($w.Dom0Utc.ToString('o')), the clock was $($w.SkewS) s out, " +
                            "this guest's effective offset is $off (the zone's base is $($w.Offset)). " +
                            "With a zero offset the two conventions are the same arithmetic and there is nothing to " +
                            "choose; otherwise the RTC carries the history of earlier clock writes, which Xen persists " +
                            "per VM. RealTimeIsUniversal left at $cur - diagnose, do not guess.")
            } elseif ($want -ne $cur) {
                New-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -PropertyType DWord -Value $want -Force -ErrorAction Stop | Out-Null
                $back = (Get-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -ErrorAction Stop).RealTimeIsUniversal
                if ($back -eq $want) {
                    LogWarning ("CLOCKCONV RealTimeIsUniversal was $cur and this qube's RTC says $want (the RTC held " +
                                "$($rtc.ToString('o')), dom0 said $($w.Dom0Utc.ToString('o')), effective offset $off " +
                                "(the zone's base is $($w.Offset)), " +
                                "the clock was $($w.SkewS) s out) - corrected; it takes effect at the next boot")
                } else {
                    LogError "CLOCKCONV RealTimeIsUniversal did not read back as $want (got '$back') - this guest will keep needing a pull every boot"
                }
            } else {
                LogInfo ("CLOCKCONV RealTimeIsUniversal=$cur matches what the RTC held ($($rtc.ToString('o')) against " +
                         "dom0's $($w.Dom0Utc.ToString('o')), effective offset $off, clock was $($w.SkewS) s out)")
            }
        }
    } catch {
        LogWarning "CLOCKCONV could not decide the RTC convention ($($_.Exception.Message)) - the clock is pulled, the setting is untouched"
    }
}

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
    default {
        LogError "CLOCKSYNC no time from dom0 within $DeadlineSeconds s (last: $lastErr) - the clock stays at $($after.ToString('o')) and every log window on this guest is suspect"
        exit 1
    }
}
