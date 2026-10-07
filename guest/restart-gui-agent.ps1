# guest/restart-gui-agent.ps1 - THE ONE WAY a harness or developer script restarts the GUI agent.
# NOT SHIPPED (packaging/make-setup.ps1 stages named files only; this is rig tooling).
#
# WHY THIS EXISTS (owner, 2026-10-07: "if you terminate something that relaunches you need to make
# sure it STOPS relaunching beforehand ... thats why we do not kill processes by name"). Every
# harness and dev script used to restart the agent with `Get-Process gui-agent | Stop-Process -Force`
# (or .Kill(), or taskkill /im) while the QubesGuiWatchdog service - the agent's relauncher - was
# still armed, or stopped the service and then ALSO killed by name. The kill raced the service's
# relaunch and the test measured whichever instance won; two harnesses grew INVALID-INSTRUMENT
# branches for "the old agent survived Stop-Process" instead of fixing the cause.
#
# THE MECHANISM. The agent's lifetime is owned by the QubesGuiWatchdog service: since 2026-10-03
# (agent/watchdog/watchdog.c StopOwnAgent) a service stop asks the agent IT started to exit through
# its own stop event, waits on the HANDLE it holds, and reports STOPPED only once that agent is gone;
# a service start launches a fresh agent from the exe named by HKLM\...\Qubes Tools\GuiAgentPath
# (watchdog.c REG_CONFIG_AGENT_PATH_VALUE, written by the MSI). So a restart is: stop the service,
# start the service. Nothing here finds a process by name, nothing here kills.
#
# THE PROOF (missing data FAILS, .claude/skills/experimenter rule 3). A file NAME is not an agent
# (Jev review 2026-10-07, false_pass 0.34 / log-name-trust 0.60: a newer log can belong to a process
# that already died, and the pid in a name can have been reused by anything). The agent writes
# <LogDir>\gui-agent-<yyyyMMdd>-<HHmmss>-<pid>.log at init (qubes-windows-utils log.c, the pid last),
# and its first lines carry "LogInit: Running as user: ..., process ID: N" - the bracket prefix of
# every line holds the THREAD id, so the header text is the only in-content pid. The success path
# requires ALL THREE, each with its own INVALID reason:
#   1. IDENTITY from the log's CONTENT: the header pid must agree with the file name's pid
#      (log-pid-mismatch otherwise - a disagreement is never tie-broken);
#   2. the PROCESS behind it: Get-Process -Id N exists (pid-not-alive), its Path is the exe the owner
#      launches (pid-reused-path), and its StartTime lies between the service start and the log's
#      creation - a process younger than its own log is a reused pid (pid-reused-start);
#   3. SERVING, not merely started: the new agent's own post-Init marker in that log - "Awaiting for a
#      vchan client" (main.c, written once init is complete and the agent listens for dom0) or
#      "A vchan client has connected" (not-serving otherwise: started-but-dead-on-arrival, the case the
#      old Stop-Process harnesses could not tell apart).
# The OLD agent is held by the same identity (header pid, exe path) and must be gone after the service
# reports Stopped; a survivor means the installed watchdog predates the stop-own-agent change and is
# REPORTED, never killed. Every wait is a bounded failure detector; nothing here sleeps on a timer.
#
# USE. Dot-source for the functions:   . "$PSScriptRoot\restart-gui-agent.ps1"; $r = Restart-GuiAgent
#        A script that must SWAP the binary between the stop and the start (swap-agent.ps1 and the
#        deploy-*.ps1 scripts) calls the two phases itself:
#            $s = Stop-GuiAgentOwner; <copy the files>; $r = Start-GuiAgentOwner -Stopped $s
#        Restart-GuiAgent is exactly those two in sequence. Each record carries .lines (the marker
#        lines below) for the caller to print, and .ok/.verdict/.reason to grade on.
#      Run directly (pushrun / -File):  emits the marker lines below and one === RESULT === JSON line.
# Marker lines (the harnesses grep these; keep them stable):
#   SVCSTOP service=<Stopped|NOT stopped|absent> pid=<scm pid> process=<gone|STILL RUNNING|none>
#   OLDLOG <name|none> pid=<name pid> header=<header pid> alive=<0|1>
#   WDSTART <service status> <start error, if any>
#   TURNOVER stage=<ok|no-new-log|log-pid-mismatch|pid-not-alive|pid-reused-path|pid-start-unreadable|pid-reused-start|not-serving> <detail>
#   AGENTPID <new pid|0> after <n>s
#   OLDALIVE <0|1>
#   NEWLOG <name|none>
#   SERVING <awaiting|connected|none>
#   RESTART ok new=<pid> log=<name> serving=<marker>   |   RESTART INVALID-INSTRUMENT <reason>
param([int]$TimeoutSec = 45)

function Get-GuiAgentLogDir {
    # The agent's log directory, from the same registry value the agent reads. '' when unreadable.
    try {
        $d = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction Stop).LogDir
        if ($d -and (Test-Path -LiteralPath $d)) { return [string]$d }
    } catch { }
    return ''
}

function Get-GuiAgentExpectedExe {
    # The exe the OWNER launches: HKLM\...\Qubes Tools\GuiAgentPath (watchdog.c REG_CONFIG_AGENT_PATH_VALUE,
    # installed by the MSI) - the value the shipped installer's Get-QwtBinDir reads too. Fallback: gui-agent.exe
    # beside the watchdog service's own image (Win32_Service.PathName). '' when neither can be read.
    foreach ($k in 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools', 'HKLM:\SOFTWARE\WOW6432Node\Invisible Things Lab\Qubes Tools') {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($p -and ($p.PSObject.Properties.Name -contains 'GuiAgentPath') -and $p.GuiAgentPath) { return [string]$p.GuiAgentPath }
    }
    try {
        $pn = [string](Get-CimInstance Win32_Service -Filter "Name='QubesGuiWatchdog'" -ErrorAction SilentlyContinue).PathName
        if ($pn -match '^"?([^"]+?\.exe)') { return (Join-Path (Split-Path -Parent $Matches[1]) 'gui-agent.exe') }
    } catch { }
    return ''
}

function Get-NewestGuiAgentLog([string]$Dir) {
    if (-not $Dir) { return $null }
    return @(Get-ChildItem -LiteralPath $Dir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1) | Select-Object -First 1
}

function Get-GuiAgentLogPid([string]$Name) {
    # gui-agent-<yyyyMMdd>-<HHmmss>-<pid>.log -> pid; 0 when the name is not that shape
    if ($Name -match '^gui-agent-\d{8}-\d{6}-(\d+)\.log$') { return [int]$Matches[1] }
    return 0
}

function Get-GuiAgentLogHeaderPid([string]$Path) {
    # The pid the agent itself wrote at init: "LogInit: Running as user: <who>, process ID: N" (log.c LogInit),
    # within the first lines. 0 when it is not there (a truncated, foreign or still-empty file).
    try { $head = @(Get-Content -LiteralPath $Path -TotalCount 40 -ErrorAction Stop) } catch { return 0 }
    foreach ($ln in $head) { if ($ln -match 'process ID: (\d+)') { return [int]$Matches[1] } }
    return 0
}

function Test-GuiAgentServing([string]$Path) {
    # The post-Init marker only a running agent writes (main.c): 'awaiting' (listening for dom0's daemon),
    # 'connected' (the daemon is on the vchan), '' (neither - started but not serving, or dead on arrival).
    try { $txt = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return '' }
    if ($txt -match 'A vchan client has connected') { return 'connected' }
    if ($txt -match 'Awaiting for a vchan client') { return 'awaiting' }
    return ''
}

function Test-GuiAgentProcess {
    # Is the pid a log names the agent that wrote it? By id, never by name: the process must exist, run the exe
    # the owner launches, and have started no earlier than -NotBefore (the service start) and no later than the
    # log's creation (the agent creates its log AFTER it starts; a process younger than the log is a reused pid).
    param([int]$ProcId, [string]$ExpectedExe, [datetime]$NotBefore = [datetime]::MinValue, [datetime]$LogCreated = [datetime]::MaxValue)
    $r = [ordered]@{ ok = $false; reason = ''; proc = $null; path = ''; start = $null }
    if ($ProcId -le 0) { $r.reason = 'pid-not-alive'; return $r }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { $r.reason = 'pid-not-alive'; return $r }
    $r.proc = $p
    try { $r.path = [string]$p.Path } catch { $r.path = '' }
    if (-not $ExpectedExe -or -not $r.path -or ($r.path -ne $ExpectedExe)) { $r.reason = 'pid-reused-path'; return $r }
    try { $r.start = $p.StartTime } catch { $r.start = $null }
    if (-not $r.start) { $r.reason = 'pid-start-unreadable'; return $r }
    if ($r.start -lt $NotBefore) { $r.reason = 'pid-reused-start'; return $r }
    if ($r.start -gt $LogCreated) { $r.reason = 'pid-reused-start'; return $r }
    $r.ok = $true
    return $r
}

function Get-GuiAgentIdentity {
    # The agent a log file describes, by CONTENT: name pid, header pid, and whether the process behind the
    # name is that agent (Test-GuiAgentProcess). .alive is true only when all of that holds.
    param($Log, [string]$ExpectedExe)
    $id = [ordered]@{ log = ''; name_pid = 0; header_pid = 0; agree = $false; created = $null; alive = $false; proc = $null; reason = 'no-log' }
    if (-not $Log) { return $id }
    $id.log = $Log.Name
    $id.name_pid = Get-GuiAgentLogPid $Log.Name
    $id.header_pid = Get-GuiAgentLogHeaderPid $Log.FullName
    try { $id.created = $Log.CreationTime } catch { $id.created = $null }
    $id.agree = ($id.name_pid -gt 0 -and $id.name_pid -eq $id.header_pid)
    if (-not $id.agree) { $id.reason = 'log-pid-mismatch'; return $id }
    $t = Test-GuiAgentProcess -ProcId $id.name_pid -ExpectedExe $ExpectedExe
    $id.proc = $t.proc; $id.alive = $t.ok; $id.reason = $(if ($t.ok) { 'ok' } else { $t.reason })
    return $id
}

function Resolve-GuiAgentTurnover {
    # ONE evaluation of the three facts against the newest log (the caller polls it under a bound):
    # stage names the first fact that is NOT established, so the INVALID reason is specific.
    param([string]$LogDir, [string]$OldLog, [string]$ExpectedExe, [datetime]$NotBefore = [datetime]::MinValue)
    $r = [ordered]@{ ok = $false; stage = 'no-new-log'; detail = ''; log = ''; name_pid = 0; header_pid = 0; created = $null; proc = $null; serving = '' }
    $nl = Get-NewestGuiAgentLog $LogDir
    if (-not $nl -or $nl.Name -eq $OldLog) { $r.detail = "newest log is $(if ($nl) { $nl.Name } else { 'none' })"; return $r }
    $r.log = $nl.Name
    $r.name_pid = Get-GuiAgentLogPid $nl.Name
    $r.header_pid = Get-GuiAgentLogHeaderPid $nl.FullName
    try { $r.created = $nl.CreationTime } catch { $r.created = $null }
    if ($r.name_pid -le 0 -or $r.header_pid -ne $r.name_pid) {
        $r.stage = 'log-pid-mismatch'; $r.detail = "name says pid $($r.name_pid), the LogInit header says $($r.header_pid)"; return $r
    }
    $created = $(if ($r.created) { $r.created } else { [datetime]::MaxValue })
    $t = Test-GuiAgentProcess -ProcId $r.name_pid -ExpectedExe $ExpectedExe -NotBefore $NotBefore -LogCreated $created
    if (-not $t.ok) {
        $r.stage = $t.reason
        $r.detail = "pid $($r.name_pid): path '$($t.path)' (expected '$ExpectedExe'), start $(if ($t.start) { $t.start.ToString('s') } else { 'unreadable' }), service start $($NotBefore.ToString('s')), log created $(if ($r.created) { $r.created.ToString('s') } else { 'unreadable' })"
        return $r
    }
    $r.proc = $t.proc
    $r.serving = Test-GuiAgentServing $nl.FullName
    if (-not $r.serving) { $r.stage = 'not-serving'; $r.detail = "pid $($r.name_pid) is alive but $($nl.Name) carries no 'Awaiting for a vchan client' / 'A vchan client has connected' line yet"; return $r }
    $r.ok = $true; $r.stage = 'ok'; $r.detail = "pid $($r.name_pid), $($nl.Name), $($r.serving)"
    return $r
}

function Stop-GuiAgentOwner {
    # PHASE 1: stop the QubesGuiWatchdog service and prove the agent it owned is gone - by the handle of the
    # agent the newest log describes (content identity, never a name). Returns the record Start-GuiAgentOwner continues.
    param([int]$TimeoutSec = 45)
    $svcName = 'QubesGuiWatchdog'
    $r = [ordered]@{
        ok = $false; verdict = ''; reason = ''
        service = 'absent'; svc_pid = 0; svc_stopped = $false; svc_process = 'none'
        log_dir = ''; expected_exe = ''; old_log = ''; old_pid = 0; old_header_pid = 0; old_alive_before = $false; old_gone = $true
        wd_status = ''; wd_error = ''
        new_log = ''; new_pid = 0; serving = ''; turnover = ''; wait_s = 0
    }
    # The marker lines are RETURNED (in .lines), never written from inside the function: a function
    # that writes to the output stream hands its caller the strings mixed into the record.
    $lines = New-Object System.Collections.Generic.List[string]
    $say = { param($s) $lines.Add($s) }

    $r.log_dir = Get-GuiAgentLogDir
    $r.expected_exe = Get-GuiAgentExpectedExe
    $oldLog = Get-NewestGuiAgentLog $r.log_dir
    $oldId = Get-GuiAgentIdentity -Log $oldLog -ExpectedExe $r.expected_exe
    $oldProc = $oldId.proc
    $r.old_log = $oldId.log; $r.old_pid = $oldId.name_pid; $r.old_header_pid = $oldId.header_pid
    $r.old_alive_before = $oldId.alive
    if (-not $oldId.alive) { $oldProc = $null }
    & $say ("OLDLOG " + $(if ($r.old_log) { $r.old_log } else { 'none' }) + " pid=" + $r.old_pid + " header=" + $r.old_header_pid + " alive=" + $(if ($oldProc) { 1 } else { 0 }))

    # ---- stop the SERVICE (the owner) and wait for its own process, then for the agent it owned
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        & $say "SVCSTOP service=absent pid=0 process=none"
    } else {
        $r.service = "$($svc.Status)"
        try { $r.svc_pid = [int](Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).ProcessId } catch { $r.svc_pid = 0 }
        $svcProc = $null
        if ($r.svc_pid -gt 0) { $svcProc = Get-Process -Id $r.svc_pid -ErrorAction SilentlyContinue }
        if ($svc.Status -ne 'Stopped') {
            try { Stop-Service -Name $svcName -Force -ErrorAction Stop } catch { $r.reason = "Stop-Service threw: $($_.Exception.Message)" }
            try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSec)) } catch { }
        }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $r.svc_stopped = (-not $svc) -or ($svc.Status -eq 'Stopped')
        if ($svcProc) {
            $gone = $false
            try { $gone = $svcProc.WaitForExit($TimeoutSec * 1000) } catch { $gone = [bool]$svcProc.HasExited }
            $r.svc_process = $(if ($gone) { 'gone' } else { 'STILL RUNNING' })
        }
        & $say ("SVCSTOP service=" + $(if ($r.svc_stopped) { 'Stopped' } else { 'NOT stopped' }) + " pid=" + $r.svc_pid + " process=" + $r.svc_process)
        # The agent the service owned: gone by HANDLE, or reported. Never killed from here - a
        # survivor means the installed watchdog predates StopOwnAgent (pre-4.3.34) and the guest
        # needs that fix, not another by-name kill.
        if ($oldProc) {
            $og = $false
            try { $og = $oldProc.WaitForExit($TimeoutSec * 1000) } catch { $og = [bool]$oldProc.HasExited }
            $r.old_gone = $og
        }
    }
    # Carried to the start phase: the handle (to re-check the survivor) and the lines so far.
    $r['oldProc'] = $oldProc
    $r['lines'] = $lines
    return $r
}

function Start-GuiAgentOwner {
    # PHASE 2: start the service and prove a NEW, SERVING agent - the three facts of Resolve-GuiAgentTurnover,
    # polled under the bound; the reason reported is the first fact still missing when the bound expires.
    param([Parameter(Mandatory)]$Stopped, [int]$TimeoutSec = 45)
    $svcName = 'QubesGuiWatchdog'
    $r = $Stopped
    $lines = $r['lines']
    $oldProc = $r['oldProc']
    $say = { param($s) $lines.Add($s) }

    # ---- start the SERVICE; it launches the new agent. Anything that starts is younger than this instant
    # (a 2 s allowance for clock granularity, never more: an older process is a reused pid).
    $r.wd_error = ''
    $startedAt = (Get-Date).AddSeconds(-2)
    if ($r.service -ne 'absent') {
        try { Start-Service -Name $svcName -ErrorAction Stop } catch { $r.wd_error = $_.Exception.Message }
        $s2 = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $r.wd_status = $(if ($s2) { "$($s2.Status)" } else { 'absent' })
    } else { $r.wd_status = 'absent' }
    & $say ("WDSTART " + $r.wd_status + " " + $r.wd_error)

    # ---- the turnover: identity from the log's content, the process behind it, and its serving marker
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tv = [ordered]@{ ok = $false; stage = 'no-new-log'; detail = ''; log = ''; name_pid = 0; serving = '' }
    if ($r.service -ne 'absent' -and $r.log_dir -and $r.expected_exe) {
        while ($true) {
            $tv = Resolve-GuiAgentTurnover -LogDir $r.log_dir -OldLog $r.old_log -ExpectedExe $r.expected_exe -NotBefore $startedAt
            if ($tv.ok -or $sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    $r.wait_s = [int]$sw.Elapsed.TotalSeconds
    $r.turnover = $tv.stage
    if ($tv.ok) { $r.new_log = $tv.log; $r.new_pid = [int]$tv.name_pid; $r.serving = $tv.serving }
    $oldStill = $false
    if ($oldProc) { try { $oldStill = -not $oldProc.HasExited } catch { $oldStill = $false } }
    if ($oldStill) { $r.old_gone = $false }
    & $say ("TURNOVER stage=" + $tv.stage + " " + $tv.detail)
    & $say ("AGENTPID " + $r.new_pid + " after " + $r.wait_s + "s")
    & $say ("OLDALIVE " + $(if ($oldStill) { 1 } else { 0 }))
    & $say ("NEWLOG " + $(if ($r.new_log) { $r.new_log } else { 'none' }))
    & $say ("SERVING " + $(if ($r.serving) { $r.serving } else { 'none' }))

    # ---- the verdict: every missing fact is INVALID-INSTRUMENT, never a guess
    $why = ''
    if ($r.service -eq 'absent')              { $why = 'service-absent: no QubesGuiWatchdog service owns the agent on this guest; this helper never starts or stops an agent by hand' }
    elseif (-not $r.log_dir)                  { $why = 'logdir-unreadable: the agent log directory (HKLM Qubes Tools\LogDir) cannot be read, so the turnover cannot be proven' }
    elseif (-not $r.expected_exe)             { $why = 'owner-path-unreadable: neither HKLM Qubes Tools\GuiAgentPath nor the QubesGuiWatchdog service image can be read, so the process behind a log cannot be checked' }
    elseif (-not $r.svc_stopped)              { $why = "service-not-stopped: QubesGuiWatchdog did not reach Stopped within ${TimeoutSec}s" }
    elseif ($oldStill)                        { $why = "old-agent-survived-service-stop: gui-agent pid $($r.old_pid) ($($r.old_log)) is still running after the service reported Stopped - the installed watchdog does not stop its own agent (pre-4.3.34); not killed" }
    elseif ($r.wd_status -ne 'Running')       { $why = "service-not-running-after-start: QubesGuiWatchdog is '$($r.wd_status)' after Start-Service $($r.wd_error)".Trim() }
    elseif (-not $tv.ok)                      { $why = "$($tv.stage): $($tv.detail) - within ${TimeoutSec}s of the service start (old log $(if ($r.old_log) { $r.old_log } else { 'none' }))" }
    if ($why) {
        $r.verdict = 'INVALID-INSTRUMENT'; $r.reason = $why
        & $say ("RESTART INVALID-INSTRUMENT " + $why)
    } else {
        $r.ok = $true; $r.verdict = 'ok'
        & $say ("RESTART ok new=" + $r.new_pid + " log=" + $r.new_log + " serving=" + $r.serving)
    }
    $r.Remove('oldProc')
    $r['lines'] = @($lines)
    return $r
}

function Restart-GuiAgent {
    param([int]$TimeoutSec = 45)
    return (Start-GuiAgentOwner -Stopped (Stop-GuiAgentOwner -TimeoutSec $TimeoutSec) -TimeoutSec $TimeoutSec)
}

# Run directly (pushrun, -File, &): do the restart and report. Dot-sourced: only define the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Continue'
    $res = Restart-GuiAgent -TimeoutSec $TimeoutSec
    foreach ($ln in @($res.lines)) { Write-Output $ln }
    $res.Remove('lines')
    Write-Output '=== RESULT ==='
    Write-Output ($res | ConvertTo-Json -Compress)
    if ($res.ok) { exit 0 } else { exit 3 }
}
