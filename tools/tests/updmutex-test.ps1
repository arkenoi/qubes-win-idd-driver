<#
.SYNOPSIS
    Offline suite for the Global\QubesWindowsUpdate wait in guest/install-updater-agent.ps1
    (installer audit item 16: "15 min = hung" against a PT2H pass limit). Runs under pwsh on
    Linux or Windows PowerShell 5.1; no rig, no guest, no Task Scheduler - the task-limit reader
    and the mutex primitive are the two hooks the suite replaces.

.DESCRIPTION
    Extracts the region between `# ---- UPDMUTEX-WAIT-BEGIN` and `# ---- UPDMUTEX-WAIT-END`
    (by marker lines, never by brace-hunting), dot-sources it, and pins:
      duration    ConvertFrom-TaskDuration: PT2H/PT20M/PT1H30M/PT90S/P1DT2H/PT0S, and refusals
      derivation  Get-UpdaterPassBoundSeconds: the bound is the LONGEST ExecutionTimeLimit among
                  the registered tasks and the declared limits; PT0S and unreadable limits are
                  reported and contribute nothing; nothing registered -> declared
      wait        Wait-UpdaterMutex with a MOCKED primitive: free at once -> no bounded wait; held
                  -> the bounded wait is asked for exactly (limit+grace) ms and returns when the
                  primitive does; abandoned -> ours; held past the bound -> THROWS QWTUPDMUTEXHELD
                  and never returns a value the caller could proceed on; no limit -> throws at once
      real mutex  a System.Threading.Mutex held by a second runspace thread: the wait returns when
                  the holder releases (not at the deadline), and a holder outliving the bound is
                  thrown, not waited out
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the original bug in the extracted copy (the shipped file is never modified):
      fixed15min  the `# GUARD:ownlimit` line becomes the old constant 900000 ms - the bound no
                  longer derives from the holder's limit; the derivation-into-the-wait check must FAIL
      proceed     the `# GUARD:failloud` throw is deleted - a mutex held past the bound is returned
                  instead of thrown; the fail-loud checks must FAIL
    tools/tests/updmutex-selftest.sh runs the clean leg and both knobs and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0   # what the installer's `&` invocation inherits (see the script's own header)

if (-not $ScriptPath) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
    $ScriptPath = Join-Path $repoRoot 'guest/install-updater-agent.ps1'
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}
function CheckEq([string]$name, $got, $want) {
    $script:run++
    $ok = ("$got" -eq "$want")
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host ("{0} {1,-72} want {2,-14} got {3}" -f $tag, $name, $want, $got)
}

# --- extract the region by its marker lines --------------------------------------------------------
$lines = @(Get-Content -LiteralPath $ScriptPath)
$begins = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '# ---- UPDMUTEX-WAIT-BEGIN*' })
$ends   = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '# ---- UPDMUTEX-WAIT-END*' })
if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $begins[0] -ge $ends[0]) {
    Write-Host "FAIL marker extraction: expected exactly one BEGIN before one END, got $($begins.Count)/$($ends.Count)"
    exit 1
}
$region = @($lines[($begins[0] + 1)..($ends[0] - 1)])

switch ($Defect) {
    '' { }
    'fixed15min' {
        $hit = @($region | Where-Object { $_ -match '# GUARD:ownlimit$' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect fixed15min: expected exactly 1 '# GUARD:ownlimit' line, found $($hit.Count)"; exit 1 }
        $region = @($region | ForEach-Object { if ($_ -match '# GUARD:ownlimit$') { '    $boundMs = [long]900000   # DEFECT: the pre-2026-09-16 constant' } else { $_ } })
    }
    'proceed' {
        $hit = @($region | Where-Object { $_ -match '# GUARD:failloud$' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect proceed: expected exactly 1 '# GUARD:failloud' line, found $($hit.Count)"; exit 1 }
        $region = @($region | Where-Object { $_ -notmatch '# GUARD:failloud$' })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (fixed15min | proceed)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('updmutex-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$regionFile = Join-Path $tmpRoot 'updmutex-region.ps1'
[IO.File]::WriteAllLines($regionFile, [string[]]$region)
. $regionFile
Check 'region defines ConvertFrom-TaskDuration, Get-UpdaterPassBoundSeconds, Wait-UpdaterMutex' `
      ((Get-Command ConvertFrom-TaskDuration -EA SilentlyContinue) -and (Get-Command Get-UpdaterPassBoundSeconds -EA SilentlyContinue) -and (Get-Command Wait-UpdaterMutex -EA SilentlyContinue))

# The shipped file must still register the limits the derivation reads (one source, not two).
$shipped = Get-Content -LiteralPath $ScriptPath -Raw
Check 'shipped: scan task XML carries $ScanTaskLimit'  ($shipped -match '<ExecutionTimeLimit>\$ScanTaskLimit</ExecutionTimeLimit>')
Check 'shipped: run task XML carries $PassTaskLimit'   ($shipped -match '<ExecutionTimeLimit>\$PassTaskLimit</ExecutionTimeLimit>')
Check 'shipped: declared limits are PT20M (scan) and PT2H (pass)' (($shipped -match "\`$ScanTaskLimit\s*=\s*'PT20M'") -and ($shipped -match "\`$PassTaskLimit\s*=\s*'PT2H'"))
Check 'shipped: the wait is handed both declared limits' ($shipped -match '-DeclaredLimits @\(\$ScanTaskLimit, \$PassTaskLimit\)')
Check 'shipped: no 15-minute constant survives in the wait'  (-not ($shipped -match 'WaitOne\(900000\)'))
Check 'shipped: no "proceeding" branch survives'            (-not ($shipped -match 'proceeding to replace the relay'))

# --- 1. duration parsing ---------------------------------------------------------------------------
CheckEq 'duration PT2H'    (ConvertFrom-TaskDuration 'PT2H')    7200
CheckEq 'duration PT20M'   (ConvertFrom-TaskDuration 'PT20M')   1200
CheckEq 'duration PT1H30M' (ConvertFrom-TaskDuration 'PT1H30M') 5400
CheckEq 'duration PT90S'   (ConvertFrom-TaskDuration 'PT90S')   90
CheckEq 'duration P1DT2H'  (ConvertFrom-TaskDuration 'P1DT2H')  93600
CheckEq 'duration PT0S (no limit) -> 0' (ConvertFrom-TaskDuration 'PT0S') 0
CheckEq 'duration " PT5M " trimmed'     (ConvertFrom-TaskDuration ' PT5M ') 300
Check   'duration empty -> $null'       ($null -eq (ConvertFrom-TaskDuration ''))
Check   'duration $null -> $null'       ($null -eq (ConvertFrom-TaskDuration $null))
Check   'duration "15" -> $null'        ($null -eq (ConvertFrom-TaskDuration '15'))
Check   'duration "2h" -> $null'        ($null -eq (ConvertFrom-TaskDuration '2h'))
Check   'duration "PT" (no component) -> $null' ($null -eq (ConvertFrom-TaskDuration 'PT'))
Check   'duration "P" (no component) -> $null'  ($null -eq (ConvertFrom-TaskDuration 'P'))
Check   'duration "PT2H5" (dangling number) -> $null' ($null -eq (ConvertFrom-TaskDuration 'PT2H5'))
CheckEq 'duration P1D (no time part)'   (ConvertFrom-TaskDuration 'P1D') 86400

# --- 2. bound derivation with a mocked task reader --------------------------------------------------
$script:limits = @{}
$reader = { param($tn) $script:limits[$tn] }
function Bound([string[]]$declared) { Get-UpdaterPassBoundSeconds -ReadTaskLimit $reader -DeclaredLimits $declared }

$script:limits = @{ QubesWindowsUpdateScan = 'PT20M'; QubesWindowsUpdateRun = 'PT2H'; QubesWindowsUpdateDownload = 'PT2H' }
$b = Bound @('PT20M', 'PT2H')
CheckEq 'derive: registered {20M,2H,2H} + declared {20M,2H} -> 7200'          $b.Seconds 7200
CheckEq 'derive: ... source is the registered task that carries it'            $b.Source  'QubesWindowsUpdateRun'
CheckEq 'derive: ... nothing unbounded'                                          (@($b.Unbounded).Count) 0
CheckEq 'derive: ... nothing unparsed'                                           (@($b.Unparsed).Count) 0

$script:limits = @{}
$b = Bound @('PT20M', 'PT2H')
CheckEq 'derive: nothing registered (fresh install) -> declared 7200'           $b.Seconds 7200
CheckEq 'derive: ... source declared'                                            $b.Source  'declared'

$script:limits = @{ QubesWindowsUpdateRun = 'PT4H' }
$b = Bound @('PT20M', 'PT2H')
CheckEq 'derive: old install registered PT4H, declared PT2H -> the longer, 14400' $b.Seconds 14400
CheckEq 'derive: ... source QubesWindowsUpdateRun'                               $b.Source  'QubesWindowsUpdateRun'

$script:limits = @{ QubesWindowsUpdateRun = 'PT1H' }
$b = Bound @('PT20M', 'PT2H')
CheckEq 'derive: registered PT1H, declared PT2H -> the longer, 7200 (declared)'  $b.Seconds 7200
CheckEq 'derive: ... source declared'                                            $b.Source  'declared'

$script:limits = @{ QubesWindowsUpdateScan = 'PT20M'; QubesWindowsUpdateRun = 'PT0S'; QubesWindowsUpdateDownload = 'PT2H' }
$b = Bound @('PT30M')
CheckEq 'derive: a PT0S task is reported as Unbounded'                           (@($b.Unbounded) -join ',') 'QubesWindowsUpdateRun'
CheckEq 'derive: ... and contributes nothing: max of the rest = 7200'            $b.Seconds 7200

$script:limits = @{ QubesWindowsUpdateScan = 'twenty'; QubesWindowsUpdateRun = 'PT2H' }
$b = Bound @('PT30M')
CheckEq 'derive: an unreadable limit is reported as Unparsed (task=value)'       (@($b.Unparsed) -join ',') 'QubesWindowsUpdateScan=twenty'
CheckEq 'derive: ... and contributes nothing: 7200'                              $b.Seconds 7200

$script:limits = @{}
$b = Bound @()
CheckEq 'derive: nothing registered, nothing declared -> 0 / none'               ("$($b.Seconds)/$($b.Source)") '0/none'

$script:limits = @{}
$b = Bound @('PT2H', 'bogus')
CheckEq 'derive: an unreadable DECLARED limit is reported (declared=value)'      (@($b.Unparsed) -join ',') 'declared=bogus'

# The default reader is the one Windows dependency: it must name the cmdlet already proven on the
# rig (wu-update.ps1, wu-task-add-scheduled.ps1) with -ErrorAction SilentlyContinue, so an absent
# task reads as "not registered" rather than killing the deploy under ErrorActionPreference=Stop.
$defText = (Get-Command Get-UpdaterPassBoundSeconds).ScriptBlock.ToString()
Check 'default reader uses Get-ScheduledTask -TaskName ... -ErrorAction SilentlyContinue' ($defText -match 'Get-ScheduledTask -TaskName \$tn -ErrorAction SilentlyContinue')
Check 'default reader returns Settings.ExecutionTimeLimit'                                 ($defText -match 'Settings\.ExecutionTimeLimit')
Check 'default task list is Scan, Run, Download'                                           ($defText -match "'QubesWindowsUpdateScan', 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload'")

# --- 3. the wait with a mocked mutex primitive ------------------------------------------------------
$script:calls = New-Object System.Collections.ArrayList
$script:logLines = New-Object System.Collections.ArrayList
$log = { param($m) [void]$script:logLines.Add($m) }
function Reset-Wait { $script:calls.Clear(); $script:logLines.Clear() }
function LogHas([string]$needle) { return (@($script:logLines | Where-Object { $_ -like "*$needle*" }).Count -gt 0) }
$script:limits = @{ QubesWindowsUpdateScan = 'PT20M'; QubesWindowsUpdateRun = 'PT2H'; QubesWindowsUpdateDownload = 'PT2H' }
$bound2h = { Get-UpdaterPassBoundSeconds -ReadTaskLimit $reader -DeclaredLimits @('PT20M', 'PT2H') }
$script:boundEvaluated = 0
$boundCounting = { $script:boundEvaluated++; & $bound2h }

# 3a. free at once: owned, no bounded wait, the bound is never even derived
Reset-Wait; $script:boundEvaluated = 0
$mockFree = { param($ms) [void]$script:calls.Add($ms); $true }
$r = Wait-UpdaterMutex -WaitOne $mockFree -Bound $boundCounting -GraceSeconds 300 -Log $log
CheckEq 'wait: free at once -> $true'                          $r $true
CheckEq 'wait: ... exactly one WaitOne(0), no bounded wait'    (@($script:calls) -join ',') '0'
CheckEq 'wait: ... the bound was not derived (no task queries)' $script:boundEvaluated 0

# 3b. held, released during the bounded wait: the bounded wait is asked for exactly limit+grace
Reset-Wait
$mockFreeAfterWait = { param($ms) [void]$script:calls.Add($ms); ($ms -ne 0) }
$r = Wait-UpdaterMutex -WaitOne $mockFreeAfterWait -Bound $bound2h -GraceSeconds 300 -Log $log
CheckEq 'wait: held then released -> $true'                                         $r $true
CheckEq 'wait: the bounded wait asks for (7200+300)*1000 ms - the holder''s limit'  ($script:calls[1]) 7500000
CheckEq 'wait: ... two primitive calls: WaitOne(0) then the bounded one'            (@($script:calls).Count) 2
Check   'wait: ... says which limit bounds it (source + seconds)'                    (LogHas 'bounded by its own ExecutionTimeLimit: 7200 s (QubesWindowsUpdateRun) + 300 s grace = 7500 s')

# 3c. held past the bound: THROWS QWTUPDMUTEXHELD, never returns
Reset-Wait
$mockHeld = { param($ms) [void]$script:calls.Add($ms); $false }
$returned = 'not-returned'; $threw = $null
try { $returned = Wait-UpdaterMutex -WaitOne $mockHeld -Bound $bound2h -GraceSeconds 300 -Log $log } catch { $threw = $_ }
Check   'failloud: held past the bound -> throws'                                     ($null -ne $threw)
Check   'failloud: ... the exception is QWTUPDMUTEXHELD: ...'                         ($null -ne $threw -and $threw.Exception.Message -match '^QWTUPDMUTEXHELD: ')
Check   'failloud: ... nothing is returned to proceed on'                             ($returned -eq 'not-returned')
Check   'failloud: ... the log carries the same QWTUPDMUTEXHELD line'                 (LogHas 'QWTUPDMUTEXHELD: Global\QubesWindowsUpdate still held after 7500 s')
Check   'failloud: ... names the limit and its source'                                (LogHas '(7200 s from QubesWindowsUpdateRun)')
Check   'failloud: ... says nothing was changed'                                      (LogHas 'nothing was changed')

# 3d. abandoned during the bounded wait (holder killed at its limit) -> ours
Reset-Wait
$mockAbandonedOnWait = { param($ms) [void]$script:calls.Add($ms); if ($ms -eq 0) { return $false }; throw (New-Object System.Threading.AbandonedMutexException) }
$r = Wait-UpdaterMutex -WaitOne $mockAbandonedOnWait -Bound $bound2h -GraceSeconds 300 -Log $log
CheckEq 'wait: abandoned during the bounded wait -> $true (ours now)' $r $true
Check   'wait: ... logged as stopped at its limit'                       (LogHas 'ended without releasing')

# 3e. abandoned on the first probe -> ours, no bounded wait
Reset-Wait
$mockAbandonedAtOnce = { param($ms) [void]$script:calls.Add($ms); throw (New-Object System.Threading.AbandonedMutexException) }
$r = Wait-UpdaterMutex -WaitOne $mockAbandonedAtOnce -Bound $bound2h -GraceSeconds 300 -Log $log
CheckEq 'wait: abandoned on WaitOne(0) -> $true'   $r $true
CheckEq 'wait: ... one primitive call'              (@($script:calls).Count) 1

# 3f. held and NO limit anywhere: throws at once, no bounded wait (missing data fails)
Reset-Wait
$script:limits = @{}
$boundNone = { Get-UpdaterPassBoundSeconds -ReadTaskLimit $reader -DeclaredLimits @() }
$threw = $null
try { [void](Wait-UpdaterMutex -WaitOne $mockHeld -Bound $boundNone -GraceSeconds 300 -Log $log) } catch { $threw = $_ }
Check   'nolimit: held with no registered/declared limit -> throws QWTUPDMUTEXHELD' ($null -ne $threw -and $threw.Exception.Message -match '^QWTUPDMUTEXHELD: .*no ExecutionTimeLimit')
CheckEq 'nolimit: ... only WaitOne(0) was called - no wait on an unbounded holder'   (@($script:calls) -join ',') '0'

# 3g. PT0S / unreadable limits are said out loud before waiting
Reset-Wait
$script:limits = @{ QubesWindowsUpdateScan = 'twenty'; QubesWindowsUpdateRun = 'PT0S'; QubesWindowsUpdateDownload = 'PT2H' }
$r = Wait-UpdaterMutex -WaitOne $mockFreeAfterWait -Bound { Get-UpdaterPassBoundSeconds -ReadTaskLimit $reader -DeclaredLimits @('PT20M') } -GraceSeconds 300 -Log $log
Check 'report: PT0S task named in the log'        (LogHas 'NO ExecutionTimeLimit (PT0S), contributing nothing to the bound: QubesWindowsUpdateRun')
Check 'report: unreadable limit named in the log' (LogHas 'unreadable, contributing nothing to the bound: QubesWindowsUpdateScan=twenty')
CheckEq 'report: ... and the bound is still the readable max (7200+300)' ($script:calls[1]) 7500000

# 3h. a huge limit clamps to Int32 instead of throwing at WaitOne
Reset-Wait
$script:limits = @{ QubesWindowsUpdateRun = 'P30D' }
$r = Wait-UpdaterMutex -WaitOne $mockFreeAfterWait -Bound { Get-UpdaterPassBoundSeconds -ReadTaskLimit $reader -DeclaredLimits @('PT2H') } -GraceSeconds 300 -Log $log
CheckEq 'clamp: P30D -> WaitOne asked for Int32.MaxValue ms' ($script:calls[1]) ([int]::MaxValue)

# --- 4. a REAL mutex held by another thread -------------------------------------------------------
# The mock proves the contract; this proves the primitive: WaitOne on a mutex owned by a different
# thread blocks until that thread releases, and returns THEN - not at the deadline.
function Start-Holder([System.Threading.Mutex]$m, [int]$holdMs) {
    $ready = New-Object System.Threading.ManualResetEvent($false)
    $rs = [runspacefactory]::CreateRunspace(); $rs.ThreadOptions = 'UseNewThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({ param($mx, $r, $ms) [void]$mx.WaitOne(); [void]$r.Set(); Start-Sleep -Milliseconds $ms; $mx.ReleaseMutex() }).AddArgument($m).AddArgument($ready).AddArgument($holdMs)
    $h = $ps.BeginInvoke()
    if (-not $ready.WaitOne(10000)) { throw 'holder thread did not acquire the mutex within 10 s' }
    return [pscustomobject]@{ Ps = $ps; Rs = $rs; Handle = $h }
}
function Stop-Holder($holder) { $holder.Ps.EndInvoke($holder.Handle); $holder.Ps.Dispose(); $holder.Rs.Close(); $holder.Rs.Dispose() }

# 4a. holder releases after 1.5 s, bound 10 s: returns when released
Reset-Wait
$mx = New-Object System.Threading.Mutex($false)
$holder = Start-Holder $mx 1500
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Wait-UpdaterMutex -WaitOne { param($ms) $mx.WaitOne($ms) } -Bound { Get-UpdaterPassBoundSeconds -ReadTaskLimit { param($tn) $null } -DeclaredLimits @('PT10S') } -GraceSeconds 0 -Log $log
$elapsed = $sw.ElapsedMilliseconds
if ($r -eq $true) { $mx.ReleaseMutex() }
Stop-Holder $holder
CheckEq 'real: held 1.5 s, bound 10 s -> $true'                        $r $true
Check   "real: ... returned on release, not at the deadline ($elapsed ms: 1000..8000)" ($elapsed -ge 1000 -and $elapsed -lt 8000)
Check   'real: ... waited, per the log, bounded by 10 s'                (LogHas '10 s (declared) + 0 s grace = 10 s')

# 4b. holder outlives the bound (holds 8 s, bound 1 s): thrown, not waited out
Reset-Wait
$mx2 = New-Object System.Threading.Mutex($false)
$holder2 = Start-Holder $mx2 8000
$sw = [Diagnostics.Stopwatch]::StartNew()
$returned = 'not-returned'; $threw = $null
try { $returned = Wait-UpdaterMutex -WaitOne { param($ms) $mx2.WaitOne($ms) } -Bound { Get-UpdaterPassBoundSeconds -ReadTaskLimit { param($tn) $null } -DeclaredLimits @('PT1S') } -GraceSeconds 0 -Log $log } catch { $threw = $_ }
$elapsed = $sw.ElapsedMilliseconds
if ($returned -eq $true) { try { $mx2.ReleaseMutex() } catch { } }
Check   'real-failloud: holder outlives the bound -> throws QWTUPDMUTEXHELD' ($null -ne $threw -and $threw.Exception.Message -match '^QWTUPDMUTEXHELD: ')
Check   "real-failloud: ... at the bound, not the holder's end ($elapsed ms: <6000)" ($elapsed -lt 6000)
Check   'real-failloud: ... nothing returned to proceed on'                    ($returned -eq 'not-returned')
Stop-Holder $holder2

# --- done ---------------------------------------------------------------------------------------
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -EA SilentlyContinue
Write-Host ("--- {0} checks, {1} failed{2}" -f $script:run, $script:fail, $(if ($Defect) { " (defect knob: $Defect)" } else { '' }))
if ($script:fail -gt 0) { exit 1 }
exit 0
