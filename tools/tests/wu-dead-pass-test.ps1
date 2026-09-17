<#
.SYNOPSIS
    Offline suite for the dead-pass detection in guest/wu-update.ps1's poll loop - the handler stock
    `qubes-vm-update` (and so the Qubes Update GUI) reaches through vmupdate-shim.ps1. Runs under
    pwsh on Linux or Windows PowerShell 5.1; no rig, no guest, no Task Scheduler. The scheduler, the
    status writer, the clock and the proxy teardown are the hooks the suite replaces.

.DESCRIPTION
    THE DEFECT (measured 2026-09-17 on win11de-gwt, German Windows 11 25H2, findings/issues.md P1
    "A KILLED UPDATE PASS COSTS dom0 TWO SILENT HOURS"): the Task Scheduler ended the
    QubesWindowsUpdateRun instance 90 s into a pass (LastTaskResult 0x41306), update-status.json
    froze at phase=scan, and the handler tailed it for its full 2 h bound before telling dom0
    `update did not complete (last phase: scan)`. The task-state check that existed sat at the
    bottom of the loop body behind four `continue`s and was never reached on the polls that mattered.

    The suite extracts the WU-POLL region by its marker lines (never by brace-hunting) and runs it
    in a CHILD pwsh per scenario - the region exits the process by contract - under a scripted
    scheduler (Get-ScheduledTask / Get-ScheduledTaskInfo), a scripted writer (the real status file,
    rewritten per tick), a clock (Start-Sleep advances the tick and ends a scenario that is still
    polling with exit 42) and recording teardown stubs (netsh, registry, Get-Process). Live de-DE
    culture. Asserts, per scenario, the exit code, the DIED line and the teardown calls:
      running     task Running + phase scan on every poll        -> still polling after 5 polls, no DIED
      completes   the pass finishes (Ready + done on poll 3)     -> the loop ends normally at phase done
      killed      the measured case: Running+scan, then Ready+0x41306 with the status unchanged
                                                                 -> DIED with 0x41306, the stale ts and
                                                                    phase scan, teardown ran, exit 1 on
                                                                    the FIRST poll that shows it
      nostatus    Ready on both polls, nothing ever written      -> DIED on poll 2, "no status was written"
      foreign     only a foreign scan's `done` is on disk        -> DIED names it as an earlier operation
      grace       Ready on poll 1 (start latency), Running after -> no DIED, still polling
      blind       Get-ScheduledTask returns nothing              -> one WUDEADPASSBLIND line, no verdict,
                                                                    still polling
      contract    the DIED and leftovers lines never end in a bare number (dom0 float-parses stderr)
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the defect in the extracted copy (the shipped file is never modified):
      1   the `# GUARD:deadpass` verdict is disabled - the loop never looks at the task, as before
          2026-09-17. The killed / nostatus / foreign scenarios must then poll to the sentinel.
    tools/tests/wu-dead-pass-selftest.sh runs the clean leg and the knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'guest/wu-update.ps1' }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- extract the region by its marker lines ------------------------------------------------------
$lines = @(Get-Content -LiteralPath $ScriptPath)
function Get-Region([string]$name) {
    $begins = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $ends   = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $begins[0] -ge $ends[0]) {
        Write-Host "FAIL marker extraction ${name}: expected exactly one BEGIN before one END, got $($begins.Count)/$($ends.Count)"
        exit 1
    }
    return ,@($lines[($begins[0] + 1)..($ends[0] - 1)])
}
$region = Get-Region 'WU-POLL'
Check 'extract: the WU-POLL region contains the loop, the verdict guard and the teardown' `
      (@($region | Where-Object { $_ -match '^\s*while \(\(Get-Date\) -lt \$deadline\)' }).Count -eq 1 -and
       @($region | Where-Object { $_ -match '# GUARD:deadpass$' }).Count -eq 1 -and
       @($region | Where-Object { $_ -match '^function Remove-DeadPassLeftovers' }).Count -eq 1)
Check 'shipped: the old bottom-of-loop task check is gone (the verdict is taken at the top of every poll)' `
      (@($region | Where-Object { $_ -match 'stop tailing a corpse' }).Count -eq 0)

switch ($Defect) {
    '' { }
    '1' {
        $hit = @($region | Where-Object { $_ -match '# GUARD:deadpass$' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect 1: expected exactly 1 '# GUARD:deadpass' line, found $($hit.Count)"; exit 1 }
        $region = @($region | ForEach-Object {
            if ($_ -match '# GUARD:deadpass$') { '    if ($false) {   # DEFECT: pre-2026-09-17 - the loop never looks at the task' }
            else { $_ } })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (1)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wu-deadpass-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

# --- the harness around the region ------------------------------------------------------------------
# Everything the region reads from the handler's preamble is defined here exactly as the handler
# defines it (SilentlyContinue included - the guards' semantics depend on it), plus the hooks:
#   Start-Sleep          advances the tick: applies the plan's task state + result, rewrites (or removes)
#                        the status file, and ends a scenario still polling past $MaxTicks with exit 42
#   Get-ScheduledTask    the plan's state for this tick; 'ABSENT' returns nothing (the blind case)
#   Get-ScheduledTaskInfo the plan's LastTaskResult
#   netsh / New-ItemProperty / Remove-ItemProperty / Get-Process   record to stdout, never touch the machine
$preamble = @'
$ErrorActionPreference = 'SilentlyContinue'
[cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentUICulture = [cultureinfo]::GetCultureInfo('de-DE')
$Task = 'QubesWindowsUpdateRun'
$Status = '__STATUS__'
$Err = [Console]::Error
$script:LastP = -1
$script:SentMsgs = @{}
function Prog([double]$p) { if ($p -gt $script:LastP) { $script:LastP = $p; $Err.WriteLine([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $p)) } }
function Msg([string]$m) { if ($m -and -not $script:SentMsgs.ContainsKey($m)) { $script:SentMsgs[$m] = $true; $Err.WriteLine($m) } }
$script:StartedAt = (Get-Date).AddSeconds(-2)
function Call([string]$s) { [Console]::Out.WriteLine('CALL ' + $s) }
$script:Plan = __PLAN__
$MaxTicks = __MAXTICKS__
$script:Tick = 0
$script:TaskState = 'Ready'; $script:TaskResult = 0
function Write-Status($obj) {
    if ($null -eq $obj) { Remove-Item -LiteralPath $Status -Force -EA SilentlyContinue; return }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Status -Encoding UTF8
}
function Start-Sleep { [CmdletBinding()] param($Seconds)
    $script:Tick++
    if ($script:Tick -gt $MaxTicks) { [Console]::Out.WriteLine("SENTINEL still polling after $MaxTicks polls"); exit 42 }
    $step = $script:Plan[[Math]::Min($script:Tick, $script:Plan.Count) - 1]
    $script:TaskState = $step.state; $script:TaskResult = $step.result
    Write-Status $step.status
}
function Get-ScheduledTask { [CmdletBinding()] param($TaskName)
    Call "Get-ScheduledTask $TaskName"
    if ($script:TaskState -eq 'ABSENT') { return $null }
    return [pscustomobject]@{ TaskName = $TaskName; State = $script:TaskState }
}
function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskName)
    Call "Get-ScheduledTaskInfo $TaskName"
    return [pscustomobject]@{ TaskName = $TaskName; LastTaskResult = [uint32]$script:TaskResult }
}
function netsh { Call ('netsh ' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
function New-ItemProperty { [CmdletBinding()] param($Path, $Name, $Value, $PropertyType, [switch]$Force) Call "New-ItemProperty $Name=$Value" }
function Remove-ItemProperty { [CmdletBinding()] param($Path, $Name) Call "Remove-ItemProperty $Name" }
$script:RelayAlive = $true
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)]$Name)
    Call "Get-Process $Name"
    if (-not $script:RelayAlive) { return @() }
    $p = [pscustomobject]@{ Id = 4711; ProcessName = 'qubes-updates-relay' }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:RelayAlive = $false; Call 'Kill 4711' }
    return ,$p
}
'@
$postamble = @'
[Console]::Out.WriteLine("POSTLOOP phase=$($st.phase) polls=$($script:Polls)")
exit 0
'@

function Status([string]$phase, [string]$action = 'full', [string]$ts = '') {
    if (-not $ts) { $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    return @{ action = $action; phase = $phase; ts = $ts; count = 0; available = @(); result = @(); reboot_needed = $false; error = $null }
}
function Step([string]$state, [uint32]$result, $status) { return @{ state = $state; result = $result; status = $status } }
# The plan crosses into the child as PowerShell source, so it is rendered as literal hashtables.
function Render($v) {
    if ($null -eq $v) { return '$null' }
    if ($v -is [string]) { return "'" + ($v -replace "'", "''") + "'" }
    if ($v -is [bool]) { if ($v) { return '$true' } else { return '$false' } }
    if ($v -is [hashtable]) { return '@{ ' + (@($v.Keys | ForEach-Object { $_ + ' = ' + (Render $v[$_]) }) -join '; ') + ' }' }
    if ($v -is [array]) { return '@(' + (@($v | ForEach-Object { Render $_ }) -join ', ') + ')' }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v)
}

function Run-Scenario([string]$name, [array]$plan, [int]$maxTicks) {
    $dir = Join-Path $tmpRoot $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $statusFile = Join-Path $dir 'update-status.json'
    $planSrc = '@(' + (@($plan | ForEach-Object { Render $_ }) -join ', ') + ')'
    $src = $preamble.Replace('__STATUS__', $statusFile.Replace("'", "''")).Replace('__PLAN__', $planSrc).Replace('__MAXTICKS__', "$maxTicks")
    $file = Join-Path $dir 'scenario.ps1'
    [IO.File]::WriteAllLines($file, [string[]](@($src) + $region + @($postamble)), [Text.UTF8Encoding]::new($false))
    $out = Join-Path $dir 'stdout.txt'; $errf = Join-Path $dir 'stderr.txt'
    $p = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-File', $file) -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $out -RedirectStandardError $errf
    $so = @(); if (Test-Path $out) { $so = @(Get-Content -LiteralPath $out) }
    $se = @(); if (Test-Path $errf) { $se = @(Get-Content -LiteralPath $errf) }
    foreach ($l in $se) { Write-Host "       $name err> $l" }
    return [pscustomobject]@{
        rc = $p.ExitCode; out = $so; err = $se
        died = @($se | Where-Object { $_ -like 'update pass DIED:*' })
        left = @($se | Where-Object { $_ -like 'leftovers:*' })
        blind = @($se | Where-Object { $_ -like 'WUDEADPASSBLIND:*' })
        taskReads = @($so | Where-Object { $_ -like 'CALL Get-ScheduledTask *' }).Count
        calls = @($so | Where-Object { $_ -like 'CALL *' } | ForEach-Object { $_.Substring(5) })
        post = @($so | Where-Object { $_ -like 'POSTLOOP *' })
    }
}

# --- 1. running: nothing to detect ---------------------------------------------------------------------
$r = Run-Scenario 'running' @((Step 'Running' 0x41301 (Status 'scan'))) 5
Check 'running: task Running + phase scan on every poll -> still polling after 5 polls (sentinel exit 42)' ($r.rc -eq 42)
Check 'running: no DIED line, no teardown' ($r.died.Count -eq 0 -and $r.left.Count -eq 0 -and $r.calls -notcontains 'netsh winhttp reset proxy')
Check 'running: the task was read on every poll (5 reads for 5 polls)' ($r.taskReads -eq 5)

# --- 2. completes: the normal end ------------------------------------------------------------------------
$r = Run-Scenario 'completes' @((Step 'Running' 0x41301 (Status 'scan')), (Step 'Running' 0x41301 (Status 'install')), (Step 'Ready' 0 (Status 'done'))) 6
Check 'completes: Ready + phase done on poll 3 -> the loop ends normally (exit 0, POSTLOOP phase=done polls=3)' `
      ($r.rc -eq 0 -and $r.post.Count -eq 1 -and $r.post[0] -eq 'POSTLOOP phase=done polls=3')
Check 'completes: no DIED line for a pass that finished' ($r.died.Count -eq 0 -and $r.left.Count -eq 0)

# --- 3. killed: the measured case -------------------------------------------------------------------------
$staleTs = '2026-09-17T20:46:24'
# the status was written by OUR pass (ts after the handler started: the harness starts the handler
# clock 2 s back, and a ts in the future of the child's StartedAt passes the freshness guard)
$freshTs = (Get-Date).AddSeconds(30).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
$r = Run-Scenario 'killed' @((Step 'Running' 0x41301 (Status 'scan' 'full' $freshTs)), (Step 'Ready' 0x41306 (Status 'scan' 'full' $freshTs))) 6
$KILLED = 'killed: Running+scan then Ready+0x41306 with the status unchanged -> DIED with 0x41306 and exit 1'
Check $KILLED ($r.rc -eq 1 -and $r.died.Count -eq 1 -and $r.died[0] -like '*last result 0x41306 (terminated by the scheduler on request*')
Check 'killed: the DIED line names the task, its state, the stale ts and the phase' `
      ($r.died.Count -eq 1 -and $r.died[0] -like "update pass DIED: task QubesWindowsUpdateRun is Ready, *status stale since $freshTs at phase scan")
Check 'killed: the verdict came on the FIRST poll that showed it (2 task reads: poll 1 Running, poll 2 Ready)' ($r.taskReads -eq 2 -and $r.post.Count -eq 0)
Check 'killed: teardown mirrors Remove-Proxy - winhttp reset, wininet ProxyEnable=0 + ProxyServer removed, relay killed' `
      ($r.calls -contains 'netsh winhttp reset proxy' -and $r.calls -contains 'New-ItemProperty ProxyEnable=0' -and
       $r.calls -contains 'Remove-ItemProperty ProxyServer' -and $r.calls -contains 'Kill 4711')
Check 'killed: the leftovers line reports the relay stopped and the baseline restored' `
      ($r.left.Count -eq 1 -and $r.left[0] -like '*relay pid 4711 stopped*' -and $r.left[0] -like '* - offline baseline restored')
Check 'contract: the DIED and leftovers lines do not end in a bare number (dom0 float-parses the last token)' `
      (@(($r.died + $r.left) | Where-Object { $_ -match '\s[0-9]+([.,][0-9]+)?$' }).Count -eq 0 -and ($r.died.Count + $r.left.Count) -eq 2)

# --- 4. nostatus: killed before the first Save --------------------------------------------------------------
$r = Run-Scenario 'nostatus' @((Step 'Ready' 0x41303 $null), (Step 'Ready' 0x41306 $null)) 6
Check 'nostatus: Ready on polls 1 and 2 with nothing ever written -> DIED on poll 2, "no status was written at all", exit 1' `
      ($r.rc -eq 1 -and $r.taskReads -eq 2 -and $r.died.Count -eq 1 -and $r.died[0] -like '*0x41306*no status was written at all')

# --- 5. foreign: only a foreign scan's status is on disk (the poll that used to `continue` past the check) --------
$r = Run-Scenario 'foreign' @((Step 'Running' 0x41301 (Status 'done' 'scan' $staleTs)), (Step 'Ready' 0x41306 (Status 'done' 'scan' $staleTs))) 6
Check 'foreign: a foreign scan''s `done` on disk never masks the verdict -> DIED names it as an earlier operation, exit 1' `
      ($r.rc -eq 1 -and $r.died.Count -eq 1 -and $r.died[0] -like "*0x41306*the only status on disk is from an earlier operation (action scan, ts $staleTs, phase done)")

# --- 6. grace: task start is asynchronous ------------------------------------------------------------------
$r = Run-Scenario 'grace' @((Step 'Ready' 0x41303 $null), (Step 'Running' 0x41301 (Status 'scan'))) 4
Check 'grace: Ready on poll 1 (schtasks /run returned before the instance existed), Running after -> no verdict, still polling' `
      ($r.rc -eq 42 -and $r.died.Count -eq 0 -and $r.taskReads -eq 4)

# --- 7. blind: the task cannot be read -------------------------------------------------------------------------
$r = Run-Scenario 'blind' @((Step 'ABSENT' 0 (Status 'scan'))) 3
Check 'blind: Get-ScheduledTask returns nothing -> exactly one WUDEADPASSBLIND line, no verdict, still polling' `
      ($r.rc -eq 42 -and $r.blind.Count -eq 1 -and $r.died.Count -eq 0)

Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail) { exit 1 }
exit 0
