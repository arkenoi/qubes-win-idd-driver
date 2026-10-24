# sup-crash-numbering.ps1 - ADR-supervision item 2, the half L8 does not measure.
#
#   L8 measures a death injected DURING a shutdown - the case Jev named as the one unmeasured thing
#   that would most change the release verdict (0.89). What it does NOT measure, and the ADR says so:
#   "A forced crash WHILE THE GUEST IS UP, and the death-1/death-2 numbering across two crashes".
#
# Run as SYSTEM with the guest UP. No shutdown, no detach: the channel survives, so the harness
# drives it directly and reads the transcript back.
#
# HYPOTHESIS: ending gui-agent.exe while the machine runs makes the watchdog notice the death, write
#   our 4001, and the reporter deliver EXACTLY ONE dom0 notification for it with ONE `DEATH #N NEW`
#   line; the watchdog then relaunches the agent, and a SECOND death is reported as a DISTINCT,
#   HIGHER number. REFUTED by: zero notifications (concealment), two for one death (a double - a P1
#   by the owner's rule), or a second death that reuses the first one's number.
# BASELINE: the counts before each kill, read from the reporter's own log, and the verdict is the
#   DELTA. The log is per-day and accumulates across every injection in the routine - L8 has already
#   put deaths in it - so an absolute count cannot answer "what did THIS kill produce". That is the
#   same defect measured on 2026-10-24, where one correct report read as 2 because an earlier run's
#   row sat in the same file.
# VARIABLE: one kill, then one more. Nothing else changes between them.
# INSTRUMENT: this transcript. Validated on a known-good subject by its own baseline reads, and it
#   can FAIL: a kill that does not land leaves `killed` absent and every delta at 0, which the
#   harness grades INVALID rather than PASS.
# BUDGET: ~90 s per kill (the watchdog's relaunch plus the reporter's task). Deadline 240 s each,
#   with three exits: the delta appeared / the agent never came back (terminal) / the deadline.
#
# WHAT THIS STIMULUS DOES *NOT* GUARANTEE, stated rather than demanded. The ADR's item also names
# Application 1000 (+1001). Those are WINDOWS ERROR REPORTING events for a faulting process, and
# Process.Kill() is an abnormal TERMINATION, not a fault - so 1000/1001 are not guaranteed by this
# stimulus and are RECORDED here, never required. This project's rule is that the kind of
# declaration is decided by whether the stimulus GUARANTEES the line (Jev 0.90), never by who caused
# the condition; demanding 1000 from a kill would be a cell that fails on correct behaviour.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Out,
    [int]$DeadlineSec = 240
)

$ErrorActionPreference = 'Continue'

function T($k, $v) {
    $line = "L11|$k|$v"
    try { $line | Out-File -LiteralPath $Out -Append -Encoding ASCII } catch { }
    Write-Output $line
}

$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
T 'logdir' $logdir
if (-not $logdir) { T 'terminal' 'no LogDir in the registry - nothing to read'; T 'verdict' 'TERMINAL'; return }

function Death-Rows {
    # The reporter's own words: one row per notification it delivered to dom0.
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $n += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                Where-Object { $_ -match 'notified to dom0 as' }).Count
    }
    return $n
}
function Death-New {
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $n += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                Where-Object { $_ -match 'DEATH #\d+ NEW' }).Count
    }
    return $n
}
function Death-Again {
    # THE `AGAIN` TAG, which is ADR-supervision item 2's last unmeasured clause. The reporter opens a
    # death as `DEATH #n NEW` and sends ONE notification; every FURTHER record of that same death -
    # the watchdog's record joining the agent's, which guest/qwt-report-death.ps1 calls "a CROSS-
    # EXECUTABLE JOIN" - is logged `DEATH #n AGAIN`, advances the watermark and sends NOTHING. So
    # AGAIN is the positive evidence that the dedupe ran, as opposed to there having been only one
    # record to begin with. Counted, and its death NUMBERS returned, so an AGAIN belonging to some
    # other death cannot be read as this one's.
    $n = 0; $nums = @()
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue),
                                         'DEATH #(\d+) AGAIN'))) {
            $n++; $nums += [int]$m.Groups[1].Value
        }
    }
    return @{ count = $n; nums = ($nums | Sort-Object -Unique) }
}
function Agent-Suffixes {
    # THE NUMBERING, as the product spells it: `<component>.death-<n>`. Returned for gui-agent only,
    # because L8 has already produced wgcbroker rows in this same log and a global count cannot tell
    # the two components' numbering apart.
    $s = @()
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue),
                                         'gui-agent\.death-(\d+)'))) {
            $s += [int]$m.Groups[1].Value
        }
    }
    return ($s | Sort-Object -Unique)
}
function Agent-Pid {
    # BY LITERAL PID FROM THE AGENT'S OWN LOG, never by image name - L8's discipline, for the same
    # reason: a name matches whatever happens to be running, including a process this cell did not
    # mean. The birth line is the agent saying which pid it is; the process is then VERIFIED to still
    # exist and to be gui-agent.exe before anything is ended.
    $last = $null
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue |
                   Sort-Object LastWriteTimeUtc) {
        foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue),
                                         'QWTBIRTH module=gui-agent ver=[0-9.]+ pid=(\d+)'))) {
            $last = [int]$m.Groups[1].Value
        }
    }
    if (-not $last) { return $null }
    $p = Get-Process -Id $last -EA SilentlyContinue
    if (-not $p) { return $null }
    if ($p.ProcessName -ne 'gui-agent') { return $null }
    return $p
}

for ($round = 1; $round -le 2; $round++) {
    T "round${round}_rows_before"  (Death-Rows)
    T "round${round}_new_before"   (Death-New)
    $agBefore = Death-Again
    T "round${round}_again_before" $agBefore.count
    T "round${round}_suffixes_before" ((Agent-Suffixes) -join ',')
    $before = Death-Rows
    $sufBefore = @(Agent-Suffixes)

    $p = Agent-Pid
    if (-not $p) {
        T "round${round}_terminal" 'no live gui-agent.exe whose pid the log reports - the stimulus cannot be applied'
        T 'verdict' 'TERMINAL'
        return
    }
    T "round${round}_pid" $p.Id
    $t0 = (Get-Date).AddSeconds(-5)
    try { $p.Kill(); T "round${round}_killed" (Get-Date -Format 'HH:mm:ss.fff') }
    catch { T "round${round}_error" ("could not end the agent: " + $_.Exception.Message); T 'verdict' 'TERMINAL'; return }

    # THREE EXITS, each named: the report appeared / the agent never came back (terminal) / deadline.
    $why = ''
    $d = (Get-Date).AddSeconds($DeadlineSec)
    while ($true) {
        Start-Sleep -Seconds 5
        if ((Death-Rows) -gt $before) { $why = 'the reporter delivered'; break }
        if ((Get-Date) -gt $d) { $why = "the deadline ($DeadlineSec s) expired"; break }
    }
    T "round${round}_wait_exit" $why
    T "round${round}_rows_after" (Death-Rows)
    T "round${round}_new_after"  (Death-New)
    $agAfter = Death-Again
    T "round${round}_again_after" $agAfter.count
    T "round${round}_again_nums"  (($agAfter.nums -join ',') + '')
    $sufAfter = @(Agent-Suffixes)
    T "round${round}_suffixes_after" ($sufAfter -join ',')
    T "round${round}_suffix_added" (($sufAfter | Where-Object { $sufBefore -notcontains $_ }) -join ',')
    # OURS: 4001 is the watchdog's death event. Recorded as a count in the window, which is what the
    # chain above rests on - without it a missing report could be the reporter's fault or the
    # watchdog's and the cell could not say which.
    T "round${round}_events_4001" @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=4001; StartTime=$t0} -EA SilentlyContinue).Count
    # RECORDED, NOT REQUIRED - see the header: a Kill is not a fault, so WER need not write these.
    T "round${round}_events_1000" @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=$t0} -EA SilentlyContinue).Count
    T "round${round}_events_1001" @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1001; StartTime=$t0} -EA SilentlyContinue).Count

    # THE AGENT MUST BE BACK BEFORE THE SECOND ROUND, or round 2 measures nothing and would report a
    # missing death as a product failure.
    if ($round -eq 1) {
        $d2 = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $d2 -and -not (Agent-Pid)) { Start-Sleep -Seconds 5 }
        $back = Agent-Pid
        T 'relaunched_pid' $(if ($back) { $back.Id } else { 'NONE' })
        if (-not $back) {
            T 'terminal' 'the watchdog did not bring gui-agent back, so a second death cannot be injected'
            T 'verdict' 'TERMINAL'
            return
        }
    }
}
T 'done' (Get-Date).ToUniversalTime().ToString('s')
