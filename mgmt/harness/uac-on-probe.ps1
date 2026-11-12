# uac-on-probe.ps1 - the guest half of mgmt/harness/uac-on-test.sh.
#
# It runs as SYSTEM over qrexec (the testbed's VMShell policy), one -Step per call, and prints KEY=VALUE lines that
# the host grades: the guest summarises, the host decides, because the guest is assumed hostile. Its last line is
# END=<step>, so a call cut short by a dropped qrexec reads as no data, never as a zero.
#
#   enable    UAC still off: what the earlier bridge left behind, the session user's token at the default run level
#             (the baseline: High while no token is split), then EnableLUA=1. The switch takes effect at the next boot.
#   boot      after a UAC-on boot: EnableLUA, the session user's token at the default run level (Medium once UAC is
#             in effect), the running agent's bridge lines, whether the bridge it reported ready is the same process
#             65 s later, which stale state files the agent removed at start, the bridge helper task's priority.
#   system    one notice sent as SYSTEM with --severity info, which hands it to the session user.
#   elevated  one notice sent by the session user's ELEVATED token: a task at the highest run level.
#
# NO CLOCK. Every Windows guest here boots about three hours ahead and is corrected about a minute in, so a boot
# stamp, a process StartTime and a file mtime all lie in the window this grades. What belongs to this boot is decided
# by what the process wrote - the running gui-agent's pid in each line's prefix, after that pid's QWTBIRTH line -
# and what a stimulus caused, by the bridge log's byte length taken before it. Waits use a Stopwatch.
#
# LOCALE. The reporter's image is German. Nothing here matches Windows' prose: our own log lines, which are English,
# numbers, and SIDs (S-1-16-12288 High, S-1-16-8192 Medium, S-1-5-32-545 Users).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('enable', 'boot', 'system', 'elevated')][string] $Step,
    [string] $Tag = 'manual',
    [int]    $WaitSeconds = 240
)
$ErrorActionPreference = 'Continue'
$sysKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$state  = Join-Path $env:ProgramData 'qubes-toast-bridge'
$work   = Join-Path $env:ProgramData 'qwt-uac-on'
$logDir = $null
try { $logDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir -ErrorAction Stop).LogDir } catch { }
if (-not $logDir) { $logDir = Join-Path $env:SystemDrive 'Qubes Logs' }
$blog = Join-Path $logDir 'bridge.log'
# notifhost.exe beside the RUNNING agent, which is where the agent itself starts it from (main.c, GetModuleFileName)
$agentExe = @(Get-Process -Name 'gui-agent' -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Where-Object { $_ })
$nh = if ($agentExe.Count) { Join-Path (Split-Path -Parent $agentExe[0]) 'notifhost.exe' } else { 'C:\Program Files\Qubes Tools\bin\notifhost.exe' }
$console = $null
try { $console = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
$lua = $null
try { $lua = (Get-ItemProperty -LiteralPath $sysKey -Name EnableLUA -ErrorAction Stop).EnableLUA } catch { }
New-Item -ItemType Directory -Force -Path $work | Out-Null
# the session user's own tasks write their results here: Users may modify, named by SID
icacls $work /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
"CONSOLE=$console"
"LUA=$lua"

function Get-BridgeLength {
    # from an open handle: the directory entry's size lags for a file another process holds open
    if (-not (Test-Path -LiteralPath $blog)) { return 0L }
    $fs = [IO.File]::Open($blog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try { return $fs.Length } finally { $fs.Dispose() }
}

function Read-BridgeSince([long] $From) {
    # the bridge log's lines appended since byte $From. It rotates at ~1 MB to bridge.log.old, so a file now shorter
    # than $From means the rest of the old file and then all of the new one.
    $parts = @()
    if ((Get-BridgeLength) -lt $From) { $parts += , @("$blog.old", $From); $parts += , @($blog, 0L) }
    else { $parts += , @($blog, $From) }
    $text = ''
    foreach ($p in $parts) {
        if (-not (Test-Path -LiteralPath $p[0])) { continue }
        $fs = [IO.File]::Open($p[0], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            [void]$fs.Seek([Math]::Min([long]$p[1], $fs.Length), [IO.SeekOrigin]::Begin)
            $text += (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
        } finally { $fs.Dispose() }
    }
    return @($text -split "`r?`n" | Where-Object { $_ })
}

function Get-RunningAgentLines {
    # THIS BOOT'S AGENT, by what it wrote: every line carries [yyyyMMdd.HHmmss.fff-<pid>:<tid>-L], and the running
    # process's lines start at its own QWTBIRTH line. The two newest per-day files by NAME, because a clock that moves
    # by hours at boot can put one boot's lines in two files.
    $files = @(Get-ChildItem -LiteralPath $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 2)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($agentPid in @(Get-Process -Name 'gui-agent' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) {
        $mine = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) {
            foreach ($ln in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                if ($ln -notmatch ('^\[\d{8}\.\d{6}\.\d{3}-' + $agentPid + ':')) { continue }
                if ($ln -match ('QWTBIRTH module=gui-agent .*\bpid=' + $agentPid + '\b')) { $mine.Clear() }
                $mine.Add($ln)
            }
        }
        $out.AddRange($mine)
    }
    return , $out
}

function Invoke-UserTask([string] $Name, [string] $RunLevel, [string] $Script, [string] $Done, [int] $Seconds) {
    # The session user's own token, Limited or Highest. A task with an Interactive principal is the shape SYSTEM can
    # start that runs in the user's logon with either half of a split token (as guest/uac-elev-trigger.ps1 does).
    if (-not $console) { return 'no-console-user' }
    Remove-Item -LiteralPath $Done -Force -ErrorAction SilentlyContinue
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $enc"
        $prn = New-ScheduledTaskPrincipal -UserId $console -LogonType Interactive -RunLevel $RunLevel
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $Name -Action $act -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $Name -ErrorAction Stop
    } catch { return ('error: ' + $_.Exception.Message -replace '[\r\n]+', ' ') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path -LiteralPath $Done)) { Start-Sleep -Seconds 2 }
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Done) { return 'done' }
    return 'timeout'
}

function Get-TokenLabel([string] $Path) {
    # a whoami /groups /fo csv the task saved -> its mandatory integrity label
    if (-not (Test-Path -LiteralPath $Path)) { return 'none' }
    if (Select-String -LiteralPath $Path -SimpleMatch 'S-1-16-12288' -Quiet) { return 'high' }
    if (Select-String -LiteralPath $Path -SimpleMatch 'S-1-16-8192' -Quiet) { return 'medium' }
    return 'unknown'
}

# the session user's token at the default run level: written to a temporary name and renamed, so the wait never reads
# half a file
$lim = Join-Path $work 'label-limited.txt'
$limScript = "whoami /groups /fo csv | Out-File -Encoding ascii -FilePath '$lim.tmp'; Move-Item -Force -LiteralPath '$lim.tmp' -Destination '$lim'"

switch ($Step) {
    'enable' {
        $hb = Join-Path $state 'heartbeat'
        "HB=" + [int](Test-Path -LiteralPath $hb)
        $owner = ''
        try { $owner = (Get-Acl -LiteralPath $hb -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { }
        "HBOWNER=$owner"
        "STOPFILE=" + [int](Test-Path -LiteralPath (Join-Path $state 'stop'))
        "LIMITED_TASK=" + (Invoke-UserTask 'QwtUacOnLimited' 'Limited' $limScript $lim 60)
        "LIMITED=" + (Get-TokenLabel $lim)
        try { Set-ItemProperty -LiteralPath $sysKey -Name EnableLUA -Value 1 -Type DWord -ErrorAction Stop } catch { "LUAERR=" + ($_.Exception.Message -replace '[\r\n]+', ' ') }
        "LUASET=" + (Get-ItemProperty -LiteralPath $sysKey -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
    }
    'boot' {
        "LIMITED_TASK=" + (Invoke-UserTask 'QwtUacOnLimited' 'Limited' $limScript $lim 60)
        "LIMITED=" + (Get-TokenLabel $lim)
        # three exits: the agent reported a bridge ready, it reported none ready (QGANOTIFNOTREADY, 60 s after its
        # launch), or neither within the wait
        $ready = @(); $sw = [Diagnostics.Stopwatch]::StartNew()
        do {
            $ag = Get-RunningAgentLines
            $ready = @($ag | Where-Object { $_ -match 'NOTIFBRIDGE ready \(pid \d+ ' })
            if ($ready.Count -or @($ag | Where-Object { $_ -match 'QGANOTIFNOTREADY' }).Count) { break }
            Start-Sleep -Seconds 5
        } while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds)
        "WAITED=" + [int]$sw.Elapsed.TotalSeconds
        $readyPid = ''
        if ($ready.Count -and $ready[-1] -match 'NOTIFBRIDGE ready \(pid (\d+) ') { $readyPid = $Matches[1] }
        "READYN=" + $ready.Count
        "READYPID=$readyPid"
        # ALIVE ACROSS 65 s: a bridge that finds a stale stop file exits seconds after it starts. The same process is
        # the same id with the same start time - compared to itself, never to a clock.
        $alive = 0
        if ($readyPid) {
            $p1 = Get-Process -Id ([int]$readyPid) -ErrorAction SilentlyContinue
            if ($p1 -and $p1.ProcessName -eq 'notifhost') {
                Start-Sleep -Seconds 65
                $p2 = Get-Process -Id ([int]$readyPid) -ErrorAction SilentlyContinue
                if ($p2 -and $p2.ProcessName -eq 'notifhost' -and $p2.StartTime -eq $p1.StartTime) { $alive = 1 }
            }
        }
        "ALIVE=$alive"
        $ag = Get-RunningAgentLines   # again: a QGANOTIFNOTREADY can land during those 65 s
        "AGENTLINES=" + $ag.Count
        "NOTREADY=" + @($ag | Where-Object { $_ -match 'QGANOTIFNOTREADY' }).Count
        "RETIRED=" + (@($ag | ForEach-Object { if ($_ -match 'NOTIFBRIDGE stale state file removed at start: (\S+)') { $Matches[1] } }) -join ',')
        "STOPFILE=" + [int](Test-Path -LiteralPath (Join-Path $state 'stop'))
        "PRIO_NOTIFBRIDGE=" + (Get-ScheduledTask -TaskName 'Qubes-NotifBridge' -ErrorAction SilentlyContinue).Settings.Priority
    }
    { $_ -in 'system', 'elevated' } {
        $who = if ($Step -eq 'system') { 'SYS' } else { 'ELEV' }
        $s = "QWTUACON-$who-$Tag"; $e = [regex]::Escape($s)
        $args1 = "--notify $s uac-on-regression-check --severity info"
        $from = Get-BridgeLength
        if ($Step -eq 'system') {
            $p = Start-Process -FilePath $nh -ArgumentList $args1 -Wait -PassThru -WindowStyle Hidden
            "SYS_RC=" + $p.ExitCode
        } else {
            $lab = Join-Path $work 'label-elevated.txt'; $rcf = Join-Path $work 'elevated-rc.txt'
            Remove-Item -LiteralPath $lab -Force -ErrorAction SilentlyContinue
            $script = "whoami /groups /fo csv | Out-File -Encoding ascii -FilePath '$lab'; " +
                      "`$p = Start-Process -FilePath '$nh' -ArgumentList '$args1' -Wait -PassThru -WindowStyle Hidden; " +
                      "Set-Content -Encoding ascii -LiteralPath '$rcf.tmp' -Value `$p.ExitCode; Move-Item -Force -LiteralPath '$rcf.tmp' -Destination '$rcf'"
            "ELEV_TASK=" + (Invoke-UserTask 'QwtUacOnElevated' 'Highest' $script $rcf 120)
            "ELEV_LABEL=" + (Get-TokenLabel $lab)
            "ELEV_RC=" + $(if (Test-Path -LiteralPath $rcf) { "$(Get-Content -LiteralPath $rcf -TotalCount 1)".Trim() } else { '' })
        }
        # the instance the handoff relaunched logs after the sender returns: wait for an outcome line for this summary,
        # then 10 s more, because the double this grades follows the first send by seconds
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do {
            $lines = Read-BridgeSince $from
            if (@($lines | Where-Object { $_ -match "summary=$e(\s|$)" }).Count) { break }
            Start-Sleep -Seconds 2
        } while ($sw.Elapsed.TotalSeconds -lt 45)
        Start-Sleep -Seconds 10
        $lines = Read-BridgeSince $from
        $sent = @($lines | Where-Object { $_ -match "NOTIFY one-shot: sent ok=1 summary=$e$" })
        "${who}_SENT=" + $sent.Count
        "${who}_LEVEL=" + $(if ($sent.Count -and $sent[0] -match '^\S+ \[(\w+)\]') { $Matches[1] } else { '' })
        "${who}_NEVER=" + @($lines | Where-Object { $_ -match 'never read the handoff' -and $_ -match "summary=$e$" }).Count
        "${who}_DELFAIL=" + @($lines | Where-Object { $_ -match 'NOTIFY one-shot: read .*, delete failed' }).Count
        "${who}_LOST=" + @($lines | Where-Object { $_ -match 'notification LOST' -and $_ -match "summary=$e(\s|$)" }).Count
        "${who}_DEFERRED=" + @($lines | Where-Object { $_ -match 'NOTIFY deferred' -and $_ -match "summary=$e$" }).Count
        "${who}_NOCONN=" + @($lines | Where-Object { $_ -match 'relay never connected' }).Count
        "${who}_HANDOFF=" + @($lines | Where-Object { $_ -match 'NOTIFY handoff: ran in session' }).Count
        "${who}_LINES=" + $lines.Count
    }
}
"END=$Step"
