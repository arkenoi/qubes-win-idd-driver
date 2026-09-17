<#
.SYNOPSIS
    Offline suite for the relay's parent watchdog (guest/qubes-updates-relay.cs, ParentWatch +
    StartParentWatchdog): the relay must not outlive the updater pass that started it. Runs under
    pwsh on Linux (or Windows); no rig, no guest, no qrexec - the parent is a throwaway sleeper
    process this suite spawns and kills.

.DESCRIPTION
    THE DEFECT (measured 2026-09-17 on win11de-gwt, findings/issues.md P1 "A KILLED UPDATE PASS
    COSTS dom0 TWO SILENT HOURS"): the Task Scheduler ended the updater's PowerShell instance hard,
    its `finally { Remove-Proxy }` never ran, and the relay kept serving 127.0.0.1:8082 for hours.
    The fix: Ensure-Proxy passes `--parent-pid $PID`; the relay checks that process every 5 s and
    exits when it is gone.

    Compiles the SHIPPED source file as-is with Add-Type (never an extracted copy), then:
      alive       ParentWatch.Alive is true for this process and for a live sleeper, false once the
                  sleeper is killed and reaped
      watchdog    StartParentWatchdog(pid, 500 ms, log, onGone) armed on a live sleeper does NOT fire
                  within 2 s; after the sleeper is killed it fires within 7 s (the production
                  interval is 5 s, checked as the constant), and the log names the pid and the reason
      wired       the updater's Start-Relay passes '--parent-pid',"$PID" and RunListen parses it and
                  arms only when it is given (no argument = the old behaviour)
    The onGone action is a ManualResetEventSlim.Set delegate - a PowerShell scriptblock cannot run on
    the watchdog's thread (no runspace there), which is also why the exit path itself
    (Environment.Exit(3)) is not exercised in-process: see NOT TESTED in the commit.
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the defect in a temp copy (the shipped file is never modified):
      1   the `// GUARD:parent-gone` line never acts - the watchdog is disabled; the fires-after-kill
          check must FAIL
    tools/tests/relay-parent-selftest.sh runs the clean leg and the knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$SourcePath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $SourcePath) { $SourcePath = Join-Path $repoRoot 'guest/qubes-updates-relay.cs' }
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
$UpdaterPath = Join-Path $repoRoot 'guest/qubes-windows-update.ps1'

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

# --- the shipped file: marker present once ---------------------------------------------------------
$lines = @(Get-Content -LiteralPath $SourcePath)
$guards = @($lines | Where-Object { $_ -match '// GUARD:parent-gone$' })
Check 'shipped: GUARD:parent-gone marker present exactly once' ($guards.Count -eq 1)
if ($guards.Count -ne 1) { Write-Host 'FAIL cannot continue without the marker'; exit 1 }

# --- defect knob: patch a temp copy, never the shipped file -------------------------------------------
switch ($Defect) {
    '' { }
    '1' {
        $lines = @($lines | ForEach-Object {
            # compiles clean (no CS0162: the compiler cannot prove intervalMs < 0) and never acts
            if ($_ -match '// GUARD:parent-gone$') { '                if (!w.Alive(out why) && intervalMs < 0) { onGone(); return; }   // DEFECT: watchdog disabled' }
            else { $_ }
        })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (1)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('relay-parent-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$srcFile = Join-Path $tmpRoot 'relay-under-test.cs'
[IO.File]::WriteAllLines($srcFile, [string[]]$lines, [Text.UTF8Encoding]::new($false))

# --- compile the whole file (the real code, not an excerpt) ----------------------------------------
try {
    $types = @(Add-Type -Path $srcFile -PassThru)
} catch {
    Write-Host "FAIL compile: $($_.Exception.Message)"
    exit 1
}
$asm = $types[0].Assembly
$T  = $asm.GetType('Relay')
$PW = $asm.GetType('Relay+ParentWatch')
Check 'compile: the shipped relay source compiles and exposes Relay+ParentWatch' ($null -ne $T -and $null -ne $PW)
if ($null -eq $T -or $null -eq $PW) { exit 1 }
$bf = [Reflection.BindingFlags]'Static,NonPublic,Public'
$interval = $T.GetField('ParentCheckMs', $bf).GetRawConstantValue()
Check 'policy: the production check interval is 5 s (ParentCheckMs = 5000)' ($interval -eq 5000)
$start = $T.GetMethod('StartParentWatchdog', $bf)
Check 'shape: StartParentWatchdog(int pid, int intervalMs, string logPath, Action onGone)' `
      ($null -ne $start -and $start.GetParameters().Count -eq 4 -and $start.GetParameters()[3].ParameterType -eq [Action])

function New-Sleeper {
    if ($IsWindows) { return Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 60') -PassThru -WindowStyle Hidden }
    return Start-Process -FilePath 'sleep' -ArgumentList @('60') -PassThru
}
function Stop-Sleeper($p) { try { $p.Kill(); $p.WaitForExit() } catch { } }

# --- 1. Alive: this process, a live sleeper, a killed sleeper ------------------------------------------
$why = ''
$wSelf = [Activator]::CreateInstance($PW, [object[]]@([int]$PID))
Check "alive: this process (pid $PID) is alive, start time known" ($wSelf.Alive([ref]$why) -and $wSelf.StartTimeKnown -and $why -eq 'alive')
$s1 = New-Sleeper
$w1 = [Activator]::CreateInstance($PW, [object[]]@([int]$s1.Id))
$aliveBefore = $w1.Alive([ref]$why)
Stop-Sleeper $s1
Start-Sleep -Milliseconds 200
$why2 = ''
$aliveAfter = $w1.Alive([ref]$why2)
Check "alive: a live sleeper (pid $($s1.Id)) is alive; once killed and reaped it is gone ($why2)" `
      ($aliveBefore -and -not $aliveAfter -and ($why2 -eq 'no such process' -or $why2 -eq 'exited'))

# --- 2. the watchdog on a live parent, then the parent dies ----------------------------------------------
$logPath = Join-Path $tmpRoot 'relay.log'
$mres = [Threading.ManualResetEventSlim]::new($false)
$onGone = [Delegate]::CreateDelegate([Action], $mres, 'Set')   # a scriptblock cannot run on the watchdog's thread
$s2 = New-Sleeper
$start.Invoke($null, [object[]]@([int]$s2.Id, [int]500, [string]$logPath, [Action]$onGone)) | Out-Null   # [Action]: unwrap the PSObject
$firedWhileAlive = $mres.Wait(2000)
Check "watchdog: armed on a live parent (pid $($s2.Id)), it does NOT fire within 2 s" (-not $firedWhileAlive)
Stop-Sleeper $s2
$sw = [Diagnostics.Stopwatch]::StartNew()
$fired = $mres.Wait(7000)
$sw.Stop()
$WATCHDOG = 'watchdog: after the parent is killed it fires within 7 s'
Check ("{0} (fired={1}, {2} ms after the kill)" -f $WATCHDOG, $fired, $sw.ElapsedMilliseconds) ($fired -and $sw.ElapsedMilliseconds -le 7000)
$log = @(); if (Test-Path -LiteralPath $logPath) { $log = @(Get-Content -LiteralPath $logPath) }
Check "watchdog: the log records the arming (pid $($s2.Id), 500 ms)" `
      (@($log | Where-Object { $_ -like "*parent watchdog armed: pid $($s2.Id)*checked every 500 ms" }).Count -eq 1)
Check "watchdog: the log names the gone parent and the reason before exiting" `
      (@($log | Where-Object { $_ -like "*parent pid $($s2.Id) is gone (*) - exiting so the proxy goes down" }).Count -eq 1)

# --- 3. wired: the updater passes it, the relay parses it, and only then arms ---------------------------
$updater = Get-Content -LiteralPath $UpdaterPath -Raw
$relay   = Get-Content -LiteralPath $SourcePath -Raw
Check 'wired: Start-Relay passes ''--parent-pid'',"$PID" to the relay' ($updater -match "'--listen','8082','--target','@default','--log',\`$WorkDir,'--parent-pid',`"\`$PID`"")
Check 'wired: RunListen parses --parent-pid and arms the watchdog only when it is given (parentPid > 0)' `
      ($relay -match 'args\[i\] == "--parent-pid"' -and $relay -match 'if \(parentPid > 0\)\s*\r?\n\s*StartParentWatchdog\(parentPid, ParentCheckMs, logPath, delegate \{ Environment\.Exit\(3\); \}\);')

Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail) { exit 1 }
exit 0
