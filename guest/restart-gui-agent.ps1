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
# THE PROOF (missing data FAILS, .claude/skills/experimenter rule 3). A file NAME is not an agent,
# and the log is one file per module per day - the name carries no pid and a restart produces no new
# file - so identity comes only from CONTENT: the "LogInit: ... process ID: N" line each instance
# writes (the bracket prefix holds the THREAD id, so that is the only in-content pid). All three are
# required, each with its own INVALID reason:
#   1. the LAST init record in the file: its pid, and its line timestamp at or after the service
#      start (no-new-init otherwise - an older record is the previous instance's, same file);
#   2. the PROCESS behind it: Get-Process -Id N exists (pid-not-alive), its Path is the exe the owner
#      launches (pid-reused-path), and its StartTime lies between the service start and that init
#      line - a process younger than its own init line is a reused pid (pid-reused-start);
#   3. SERVING: "Awaiting for a vchan client" or "A vchan client has connected" AFTER that init line
#      (not-serving otherwise). The position matters: a previous instance's connected line is in the
#      same file and would pass for this one.
# The OLD agent is held by the same identity and must be gone once the service reports Stopped; a
# survivor is REPORTED, never killed. Every wait is a bounded failure detector, not a timer.
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
#   OLDLOG <name|none> pid=<init-record pid> initline=<line no> alive=<0|1>
#   WDSTART <service status> <start error, if any>
#   TURNOVER stage=<ok|no-new-init|no-init-record|init-timestamp-unreadable|pid-not-alive|pid-reused-path|pid-start-unreadable|pid-reused-start|not-serving> <detail>
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

function Get-GuiAgentLastInit([string]$Path) {
    # The LAST init record ("LogInit: ... process ID: N"), because instances share one file per day
    # and the head would give the pid of whichever one created the file this morning.
    #   .pid 0 when no init record is present   .at from the line's own prefix   .line 1-based
    $r = [ordered]@{ pid = 0; at = $null; line = 0 }
    try { $lines = Get-Content -LiteralPath $Path -ErrorAction Stop } catch { return $r }
    $n = 0
    foreach ($ln in $lines) {
        $n++
        if ($ln -match 'process ID: (\d+)') {
            $r.pid = [int]$Matches[1]
            $r.line = $n
            $r.at = $null
            if ($ln -match '^﻿?\[(\d{8})\.(\d{6})\.(\d{3})-') {
                try {
                    $r.at = [datetime]::ParseExact("$($Matches[1])$($Matches[2]).$($Matches[3])",
                        'yyyyMMddHHmmss.fff', [Globalization.CultureInfo]::InvariantCulture)
                } catch { $r.at = $null }
            }
        }
    }
    return $r
}

function Test-GuiAgentServing([string]$Path, [int]$AfterLine = 0) {
    # The post-Init marker only a running agent writes (main.c): 'awaiting' (listening for dom0's daemon),
    # 'connected' (the daemon is on the vchan), '' (neither - started but not serving, or dead on arrival).
    # ONLY LINES AFTER -AfterLine COUNT: a previous instance's 'connected' line is in this file.
    try { $lines = Get-Content -LiteralPath $Path -ErrorAction Stop } catch { return '' }
    $n = 0
    $serving = ''
    foreach ($ln in $lines) {
        $n++
        if ($n -le $AfterLine) { continue }
        if ($ln -match 'A vchan client has connected') { return 'connected' }
        if ($ln -match 'Awaiting for a vchan client') { $serving = 'awaiting' }
    }
    return $serving
}

function Test-GuiAgentProcess {
    # Is the pid an init record names the agent that wrote it? By id, never by name: the process must
    # exist, run the exe the owner launches, and have started no earlier than -NotBefore (the service
    # start) and no later than -InitAt, when it wrote that init line. -InitAt replaces the file's
    # creation time, which means nothing once every instance appends to one file.
    param([int]$ProcId, [string]$ExpectedExe, [datetime]$NotBefore = [datetime]::MinValue, [datetime]$InitAt = [datetime]::MaxValue)
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
    if ($r.start -gt $InitAt) { $r.reason = 'pid-reused-start'; return $r }
    $r.ok = $true
    return $r
}

function Get-GuiAgentIdentity {
    # The agent a log describes, by CONTENT ALONE: the LAST init record's pid, and whether the process
    # behind it is that agent. No name pid to cross-check any more, so 'log-pid-mismatch' is gone.
    param($Log, [string]$ExpectedExe)
    $id = [ordered]@{ log = ''; init_pid = 0; init_at = $null; init_line = 0; alive = $false; proc = $null; reason = 'no-log' }
    if (-not $Log) { return $id }
    $id.log = $Log.Name
    $init = Get-GuiAgentLastInit $Log.FullName
    $id.init_pid = $init.pid; $id.init_at = $init.at; $id.init_line = $init.line
    if ($id.init_pid -le 0) { $id.reason = 'no-init-record'; return $id }
    $t = Test-GuiAgentProcess -ProcId $id.init_pid -ExpectedExe $ExpectedExe
    $id.proc = $t.proc; $id.alive = $t.ok; $id.reason = $(if ($t.ok) { 'ok' } else { $t.reason })
    return $id
}

function Resolve-GuiAgentTurnover {
    # ONE evaluation of the three facts against the newest log (the caller polls it under a bound):
    # stage names the first fact that is NOT established, so the INVALID reason is specific.
    # A restart produces no new FILE, so the turnover is a new INIT RECORD: the last one, written at
    # or after the service start, by a pid that is not the one already running. -OldLog is kept for
    # the message only; the name cannot distinguish two instances.
    param([string]$LogDir, [string]$OldLog, [string]$ExpectedExe, [datetime]$NotBefore = [datetime]::MinValue, [int]$OldPid = 0)
    $r = [ordered]@{ ok = $false; stage = 'no-new-init'; detail = ''; log = ''; init_pid = 0; init_at = $null; init_line = 0; proc = $null; serving = '' }
    $nl = Get-NewestGuiAgentLog $LogDir
    if (-not $nl) { $r.detail = 'no gui-agent log in the log directory at all'; return $r }
    $r.log = $nl.Name
    $init = Get-GuiAgentLastInit $nl.FullName
    $r.init_pid = $init.pid; $r.init_at = $init.at; $r.init_line = $init.line
    if ($r.init_pid -le 0) {
        $r.stage = 'no-init-record'; $r.detail = "$($nl.Name) carries no 'process ID:' init record"; return $r
    }
    # Before our start, or the pid already running: the previous instance's, which is the normal
    # state of this shared file until the new one inits.
    if (-not $init.at) {
        $r.detail = "the init record for pid $($r.init_pid) in $($nl.Name) carries no readable timestamp, so it cannot be placed against the service start"
        $r.stage = 'init-timestamp-unreadable'; return $r
    }
    if ($init.at -lt $NotBefore -or ($OldPid -gt 0 -and $r.init_pid -eq $OldPid)) {
        $r.detail = "the newest init record is pid $($r.init_pid) at $($init.at.ToString('s')), before the service start $($NotBefore.ToString('s'))$(if ($OldPid -gt 0 -and $r.init_pid -eq $OldPid) { " and is the pid that was already running" })"
        return $r
    }
    $t = Test-GuiAgentProcess -ProcId $r.init_pid -ExpectedExe $ExpectedExe -NotBefore $NotBefore -InitAt $init.at
    if (-not $t.ok) {
        $r.stage = $t.reason
        $r.detail = "pid $($r.init_pid): path '$($t.path)' (expected '$ExpectedExe'), start $(if ($t.start) { $t.start.ToString('s') } else { 'unreadable' }), service start $($NotBefore.ToString('s')), init line $($init.line) at $($init.at.ToString('s'))"
        return $r
    }
    $r.proc = $t.proc
    $r.serving = Test-GuiAgentServing -Path $nl.FullName -AfterLine $init.line
    if (-not $r.serving) { $r.stage = 'not-serving'; $r.detail = "pid $($r.init_pid) is alive but $($nl.Name) carries no 'Awaiting for a vchan client' / 'A vchan client has connected' line after its init at line $($init.line)"; return $r }
    $r.ok = $true; $r.stage = 'ok'; $r.detail = "pid $($r.init_pid), $($nl.Name) line $($init.line), $($r.serving)"
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
        log_dir = ''; expected_exe = ''; old_log = ''; old_pid = 0; old_init_line = 0; old_alive_before = $false; old_gone = $true
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
    $r.old_log = $oldId.log; $r.old_pid = $oldId.init_pid; $r.old_init_line = $oldId.init_line
    $r.old_alive_before = $oldId.alive
    if (-not $oldId.alive) { $oldProc = $null }
    & $say ("OLDLOG " + $(if ($r.old_log) { $r.old_log } else { 'none' }) + " pid=" + $r.old_pid + " initline=" + $r.old_init_line + " alive=" + $(if ($oldProc) { 1 } else { 0 }))

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
    $tv = [ordered]@{ ok = $false; stage = 'no-new-init'; detail = ''; log = ''; init_pid = 0; serving = '' }
    if ($r.service -ne 'absent' -and $r.log_dir -and $r.expected_exe) {
        while ($true) {
            $tv = Resolve-GuiAgentTurnover -LogDir $r.log_dir -OldLog $r.old_log -ExpectedExe $r.expected_exe -NotBefore $startedAt -OldPid $r.old_pid
            if ($tv.ok -or $sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    $r.wait_s = [int]$sw.Elapsed.TotalSeconds
    $r.turnover = $tv.stage
    if ($tv.ok) { $r.new_log = $tv.log; $r.new_pid = [int]$tv.init_pid; $r.serving = $tv.serving }
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
