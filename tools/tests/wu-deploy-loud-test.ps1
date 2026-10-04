<#
  wu-deploy-loud-test.ps1 - the Windows Update agent deploy under a RUNNING updater pass, and what the installer says when the
  deploy is refused (guest/install-updater-agent.ps1 regions DEPLOY-HELPERS, DEPLOY-PREVPASS and DEPLOY-MUTEX;
  packaging/setup/Install-QwtImproved.ps1 regions UPDATER-DEPLOY-RECORD, UPDATER-DEPLOY, STAGE2-OK-FOLD, UPDATER-DEPLOY-VERDICT).
  Offline, under pwsh on Linux - but the mutex is REAL: a second pwsh process takes Global\<name> and holds it, releases it, or
  dies with it, and the shipped region's WaitOne is what observes that. The holder's pid and start time are read with the real
  Get-Process; the scheduled-task reader (Get-UpdTaskState) is the one fake on the deploy side, the deploy script and the service
  table are the fakes on the installer side; the notification route is the shipped guest/qwt-notify-error.ps1 with its test hooks.

  WHY (2026-10-04): the field reporter (German 25H2 TemplateVM) upgraded to 4.3.33 and dom0 showed no updates while Windows Update
  listed one. Measured on his environment with 4.3.34: the installer got to the updater 3 min after boot, inside the previous
  updater's boot scan (QubesWindowsUpdateScan, boot+2 min, PT20M), the deploy refused (QWTUPDMUTEXHELD), the installer wrote ONE
  WARN line and a RESULT that said ok:true, and the guest kept its OLD updater. Two fixes (Jev: F-a + F-b):
    F-b  a running SCAN is waited for, on the mutex, bounded by the scan task's own limit (+ grace); a full pass, the bound
         expiring, an unknown holder refuse; an abandoned mutex after a scan proceeds (D3), after anything else refuses.
    F-a  a refused or failed deploy is an ERROR, an error-class flag (updater_agent_failed) that makes the RESULT ok:false, a
         plain-words verdict as the last lines before the RESULT, and a dom0 notification through the existing route once
         QrexecAgent is running (never on -Auto -RebootAtEnd, where that is said instead).

  Scenarios (deploy side)             nobody holds -> deploys; a scan with a LIVE recorded owner (4.3.33+ record) holding 1.5 s
  -> waits and deploys; a scan with owner_pid 0 (4.3.32 record) seen through the Running Scan task -> waits and deploys; a
  4.3.29 record (no owner_pid at all) -> the same; a scan holding past the bound -> QWTUPDSCANWAITEXPIRED; a full pass -> refused
  at once, QWTUPDMUTEXHELD; a dead recorded owner with no running scan task -> refused; abandoned after a scan -> proceeds and
  owns the mutex; abandoned after a full pass -> refused and the mutex given back; a 4.3.29 scan record that is NOT held says
  its owner was never recorded; the Scan task Running but the scan record older than its run -> refused at once.
  Scenarios (installer side)          deployed -> no flag, ok:true, every deploy line streamed into the log; refused -> ERROR line,
  updater_agent_failed, ok:false naming it, result-flags.py red naming it, the verdict lines, the notification sent with the shipped
  route's gate/redaction/size rules; refused with QrexecAgent stopped -> verdict, no notification, said so; returned incomplete ->
  the same loud path; /noupdates -> skipped, quiet.

  -Defect <knob>  re-introduces one defect in the extracted copy (never the shipped file), at the line tagged '# GUARD:<knob>';
  each must make this suite FAIL (tools/tests/wu-deploy-loud-selftest.sh):
    scanwait       a running scan is not waited for                 fullrefuse     a full pass is waited for instead of refused
    waitbound      the wait proceeds when its bound expires         abandonedscan  abandoned after a scan refuses (D3 gone)
    abandonedfull  abandoned after a full pass proceeds             deployerror    the installer logs the refusal as a WARN
    deployflag     no updater_agent_failed flag                     deployfold     the ok= block ignores updater_agent_failed
    deployverdict  no plain-words verdict before the RESULT         deploynotify   dom0 is not notified
    freshrecord    a scan record from an earlier scan vouches for the holder (witness B without the freshness test)
#>
param([string]$Defect = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$knobs = @('scanwait', 'waitbound', 'fullrefuse', 'abandonedscan', 'abandonedfull', 'freshrecord', 'deployerror', 'deployflag', 'deployfold', 'deployverdict', 'deploynotify')
if ($Defect -and $knobs -notcontains $Defect) { Write-Output "FAIL unknown -Defect '$Defect'"; exit 2 }

$script:fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what  [$detail]"; $script:fail++ }
}
function Region([string]$text, [string]$name) {
    $b = $text.IndexOf("# ---- $name-BEGIN"); $e = $text.IndexOf("# ---- $name-END")
    if ($b -lt 0 -or $e -lt $b) { Write-Output "FAIL the $name region is missing - nothing ran"; exit 2 }
    return $text.Substring($b, $e - $b)
}
function Set-Guard([string]$region, [string]$guard, [string]$replacement) {
    $lines = $region -split "`n"
    $hit = @($lines | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Write-Output "FAIL expected exactly one '# GUARD:$guard' line, found $($hit.Count)"; exit 2 }
    return (($lines | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } }) -join "`n")
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('deploy-loud-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

# =====================================================================================================================
# PART 1 - the deploy script: a real holder process on the real named mutex
# =====================================================================================================================
$dsrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'guest/install-updater-agent.ps1')
$helpers  = Region $dsrc 'DEPLOY-HELPERS'
$prevpass = Region $dsrc 'DEPLOY-PREVPASS'
$mutexReg = Region $dsrc 'DEPLOY-MUTEX'
foreach ($g in 'scanwait', 'waitbound', 'fullrefuse', 'abandonedscan', 'abandonedfull', 'freshrecord') { if ($mutexReg -notmatch "# GUARD:$g") { Write-Output "FAIL GUARD:$g not found in DEPLOY-MUTEX"; exit 2 } }
switch ($Defect) {
    'scanwait'      { $mutexReg = Set-Guard $mutexReg 'scanwait'      '    if ($false) {   # DEFECT: a running scan is not waited for' }
    'waitbound'     { $mutexReg = Set-Guard $mutexReg 'waitbound'     '            if ($leftMs -le 0) { $haveUpdMutex = $true; break }   # DEFECT: proceed when the bound expires' }
    'fullrefuse'    { $mutexReg = Set-Guard $mutexReg 'fullrefuse'    '        Log $msg; $haveUpdMutex = $updMutex.WaitOne(20000)   # DEFECT: wait for the full pass instead' }
    'abandonedscan' { $mutexReg = Set-Guard $mutexReg 'abandonedscan' '    if ($false) {   # DEFECT: no D3 rule for an abandoned scan' }
    'abandonedfull' { $mutexReg = Set-Guard $mutexReg 'abandonedfull' '        Log $msg   # DEFECT: proceed on an abandoned full pass' }
    'freshrecord'   { $mutexReg = Set-Guard $mutexReg 'freshrecord'   '    $updFresh = $true   # DEFECT: a scan record from an earlier scan vouches for the holder' }
    default { }
}
$statusPath = Join-Path $tmp 'update-status.json'
$mutexName  = 'Global\QwtDeployLoudTest-' + [guid]::NewGuid().ToString('N')
$prevpass = $prevpass.Replace("'C:\ProgramData\Qubes\update-status.json'", "'$statusPath'")
$mutexReg = $mutexReg.Replace("'Global\QubesWindowsUpdate'", "'$mutexName'")
if ($mutexReg -notmatch [regex]::Escape($mutexName)) { Write-Output 'FAIL the mutex name literal was not found in DEPLOY-MUTEX'; exit 2 }

# shipped shapes
$mutexCode = @(($mutexReg -split "`n") | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '\s#')[0] })
Check 'shipped: DEPLOY-MUTEX has no Start-Sleep (the wait is the kernel wait on the mutex, in slices)' (@($mutexCode | Where-Object { $_ -match 'Start-Sleep' }).Count -eq 0)
Check 'shipped: DEPLOY-MUTEX kills, stops or adopts nothing (no Stop-Process, taskkill, .Kill(, Start-Process)' (@($mutexCode | Where-Object { $_ -match 'Stop-Process|taskkill|\.Kill\(|Start-Process' }).Count -eq 0)
Check 'shipped: the wait slice is 30 s and the grace is an ISO duration (DEPLOY-HELPERS)' ($helpers -match '\$UpdWaitSliceMs\s*=\s*30000' -and $helpers -match "\`$UpdScanWaitGrace\s*=\s*'PT\d+[MS]'")
Check 'shipped: the bound names the scan task limit, the elapsed time and the grace in its log line' ($mutexReg -match 'QWTUPDSCANWAIT:' -and $mutexReg -match 'already run' -and $mutexReg -match 'at most \$\{boundS\}s')

# the world
. ([scriptblock]::Create($helpers))      # the real Get-UpdSeconds; Get-UpdTaskState is replaced below; the constants are overridden
$UpdWaitSliceMs   = 500
$UpdScanWaitGrace = 'PT1S'
$ScanTaskLimit = 'PT20M'; $PassTaskLimit = 'PT2H'
$script:FakeTasks = @{}
function Get-UpdTaskState([string]$Name) {
    if ($script:FakeTasks.ContainsKey($Name)) { return $script:FakeTasks[$Name] }
    return @{ state = 'Ready'; limit = 'PT20M'; lastRun = $null }
}
$script:Logged = New-Object System.Collections.ArrayList
function Log($m) { [void]$script:Logged.Add([string]$m) }
$script:FakeBoot = (Get-Date).AddMinutes(-3)
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName) [pscustomobject]@{ LastBootUpTime = $script:FakeBoot } }

$holderScript = Join-Path $tmp 'holder.ps1'
Set-Content -LiteralPath $holderScript -Encoding UTF8 -Value @'
param([string]$Name, [string]$Marker, [double]$HoldSeconds, [switch]$Abandon)
$m = New-Object System.Threading.Mutex($false, $Name)
$got = $m.WaitOne(0)
Set-Content -LiteralPath $Marker -Value "got=$got"
Start-Sleep -Milliseconds ([int]($HoldSeconds * 1000))
if (-not $Abandon) { $m.ReleaseMutex() }
exit 0
'@
$script:holderN = 0
function Start-Holder([double]$holdSeconds, [switch]$Abandon) {
    $script:holderN++
    $marker = Join-Path $tmp "holder$($script:holderN).marker"
    $argv = @('-NoProfile', '-File', $holderScript, '-Name', $mutexName, '-Marker', $marker, '-HoldSeconds', "$holdSeconds")
    if ($Abandon) { $argv += '-Abandon' }
    $p = Start-Process -FilePath $pwshExe -ArgumentList $argv -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $marker)) { Write-Output 'FAIL the holder process never reported taking the mutex - nothing ran'; exit 2 }
    if ((Get-Content -LiteralPath $marker -Raw) -notmatch 'got=True') { Write-Output 'FAIL the holder process could not take the mutex - nothing ran'; exit 2 }
    return $p
}
function Owner-Start($p) { return (Get-Process -Id $p.Id).StartTime.ToString('s') }
function Run-Deploy($status) {
    if ($null -eq $status) { Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue }
    else { Set-Content -LiteralPath $statusPath -Value ($status | ConvertTo-Json) -Encoding UTF8 }
    $script:Logged.Clear()
    $t0 = Get-Date
    $verdict = 'deployed'
    try { . ([scriptblock]::Create($prevpass + "`n" + $mutexReg)) } catch { $verdict = "refused: $($_.Exception.Message)" }
    $r = @{ verdict = $verdict; secs = ((Get-Date) - $t0).TotalSeconds; have = $false; mutex = $null; log = (@($script:Logged) -join ' | ') }
    if (Test-Path variable:haveUpdMutex) { $r.have = [bool]$haveUpdMutex }
    if (Test-Path variable:updMutex) { $r.mutex = $updMutex }
    return $r
}
function Release-Deploy($r) { if ($r.mutex) { try { $r.mutex.ReleaseMutex() } catch { }; try { $r.mutex.Dispose() } catch { } } }
$now = (Get-Date).ToString('s')

# S1 control: nobody holds
$r = Run-Deploy @{ action = 'scan'; phase = 'done'; owner_pid = 0; ts = $now }
Check 'S1 nobody holds the mutex: deploys at once and owns it' ($r.verdict -eq 'deployed' -and $r.have -and $r.secs -lt 1.5) "$($r.verdict) secs=$([math]::Round($r.secs,2)) have=$($r.have)"
Check '   and did not wait for anything' ($r.log -notmatch 'QWTUPDSCANWAIT') $r.log
Release-Deploy $r

# S2 a running scan with a live recorded owner (a 4.3.33+ record): waited for, deploys when it releases
$script:FakeTasks = @{ QubesWindowsUpdateScan = @{ state = 'Ready'; limit = 'PT4S'; lastRun = $null } }
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'scan'; phase = 'searching'; owner_pid = $h.Id; owner_pid_start = (Owner-Start $h); ts = $now }
Check 'S2 a running scan (live recorded owner) holds 1.5 s: the deploy waits on the mutex and deploys when the scan releases it' ($r.verdict -eq 'deployed' -and $r.have -and $r.secs -ge 1.0 -and $r.secs -lt 4.0) "$($r.verdict) secs=$([math]::Round($r.secs,2)) have=$($r.have)"
Check '   logged the wait start with the bound, a progress line, and the release' ($r.log -match 'QWTUPDSCANWAIT: .*owner process \d+ .* is running' -and $r.log -match 'still waiting for the scan' -and $r.log -match 'the scan released .* after \d+s - deploying') $r.log
Release-Deploy $r; $h.WaitForExit()

# S3 a running scan whose record carries owner_pid 0 (a 4.3.32 record): seen through the Running Scan task
$script:FakeTasks = @{ QubesWindowsUpdateScan = @{ state = 'Running'; limit = 'PT4S'; lastRun = (Get-Date).AddSeconds(-0.5) }
                       QubesWindowsUpdateRun = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null }; QubesWindowsUpdateDownload = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null } }
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'scan'; phase = 'scan'; owner_pid = 0; owner_pid_start = ''; ts = (Get-Date).ToString('s') }   # written by the running instance
Check 'S3 a running scan recorded with owner_pid 0 (4.3.32), the Scan task Running: waited for and deployed' ($r.verdict -eq 'deployed' -and $r.have -and $r.secs -ge 1.0 -and $r.secs -lt 4.0) "$($r.verdict) secs=$([math]::Round($r.secs,2))"
Check '   identified by the task, and the record''s missing owner said so' ($r.log -match 'QubesWindowsUpdateScan task is Running' -and $r.log -match 'never recorded one') $r.log
Release-Deploy $r; $h.WaitForExit()

# S3b a 4.3.29 record: no owner_pid property at all (a fresh task table: the bound counts from the task's own start)
$script:FakeTasks = @{ QubesWindowsUpdateScan = @{ state = 'Running'; limit = 'PT4S'; lastRun = (Get-Date).AddSeconds(-0.5) }
                       QubesWindowsUpdateRun = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null }; QubesWindowsUpdateDownload = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null } }
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'scan'; phase = 'scan'; ts = (Get-Date).ToString('s') }   # written by the running instance
Check 'S3b a running scan recorded without any owner field (4.3.29), the Scan task Running: waited for and deployed' ($r.verdict -eq 'deployed' -and $r.have -and $r.secs -ge 1.0 -and $r.secs -lt 4.0) "$($r.verdict) secs=$([math]::Round($r.secs,2))"
Release-Deploy $r; $h.WaitForExit()

# S3c the Scan task is Running but the 'scan' record is from an EARLIER scan (written before this instance started): the record
# does not vouch for the holder (e.g. a pass started by hand that has not written its own record while a scan instance waits) - refused
$script:FakeTasks = @{ QubesWindowsUpdateScan = @{ state = 'Running'; limit = 'PT4S'; lastRun = (Get-Date).AddSeconds(-0.5) }
                       QubesWindowsUpdateRun = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null }; QubesWindowsUpdateDownload = @{ state = 'Ready'; limit = 'PT2H'; lastRun = $null } }
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'scan'; phase = 'done'; owner_pid = 0; ts = (Get-Date).AddMinutes(-10).ToString('s') }
Check 'S3c the Scan task Running but the scan record predates its run: not a witness - refused at once with QWTUPDMUTEXHELD' ($r.verdict -like 'refused: QWTUPDMUTEXHELD*' -and -not $r.have -and $r.secs -lt 1.0) "$($r.verdict) secs=$([math]::Round($r.secs,2))"
Check '   the refusal says the record predates the Scan task''s current run' ($r.verdict -match 'predates the Scan task') $r.verdict
Release-Deploy $r; $h.WaitForExit()

# S4 a scan that holds past the bound (limit PT1S + grace PT1S): refused, loudly, nothing proceeds
$script:FakeTasks = @{ QubesWindowsUpdateScan = @{ state = 'Ready'; limit = 'PT1S'; lastRun = $null } }
$h = Start-Holder 4
$r = Run-Deploy @{ action = 'scan'; phase = 'searching'; owner_pid = $h.Id; owner_pid_start = (Owner-Start $h); ts = $now }
Check 'S4 a scan still holding when the bound (its limit + grace) expires: refused with QWTUPDSCANWAITEXPIRED, within the bound' ($r.verdict -like 'refused: QWTUPDSCANWAITEXPIRED*' -and -not $r.have -and $r.secs -ge 0.8 -and $r.secs -lt 3.5) "$($r.verdict) secs=$([math]::Round($r.secs,2)) have=$($r.have)"
Check '   the refusal names the remedy' ($r.verdict -match 'schtasks /end /tn QubesWindowsUpdateScan' -and $r.verdict -match 'install.cmd /updatesonly') $r.verdict
Release-Deploy $r; $h.WaitForExit()

# S5 a running FULL pass: not waited for
$script:FakeTasks = @{ QubesWindowsUpdateRun = @{ state = 'Running'; limit = 'PT2H'; lastRun = (Get-Date) } }
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'full'; phase = 'install'; owner_pid = $h.Id; owner_pid_start = (Owner-Start $h); ts = $now }
Check 'S5 a running full pass holds: refused at once with QWTUPDMUTEXHELD, not waited for' ($r.verdict -like 'refused: QWTUPDMUTEXHELD*' -and -not $r.have -and $r.secs -lt 1.0) "$($r.verdict) secs=$([math]::Round($r.secs,2))"
Check '   the refusal names the pass, the task states and the remedy' ($r.verdict -match "'full', phase 'install'" -and $r.verdict -match 'Run=Running' -and $r.verdict -match 'install.cmd /updatesonly') $r.verdict
Release-Deploy $r; $h.WaitForExit()

# S6 held, the record says scan, its recorded owner is dead and no scan task runs: an unknown holder, refused
$dead = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru
$deadStart = ''; try { $deadStart = (Get-Process -Id $dead.Id).StartTime.ToString('s') } catch { $deadStart = (Get-Date).ToString('s') }
$dead.WaitForExit()
$script:FakeTasks = @{}
$h = Start-Holder 1.5
$r = Run-Deploy @{ action = 'scan'; phase = 'searching'; owner_pid = $dead.Id; owner_pid_start = $deadStart; ts = $now }
Check 'S6 held while the scan record''s owner is dead and no Scan task is Running: an unknown holder, refused (QWTUPDMUTEXHELD), not waited for' ($r.verdict -like 'refused: QWTUPDMUTEXHELD*' -and $r.secs -lt 1.0) "$($r.verdict) secs=$([math]::Round($r.secs,2))"
Release-Deploy $r; $h.WaitForExit()

# S7 abandoned after a scan: a handle of ours keeps the mutex alive while the holder dies with it
$keep = New-Object System.Threading.Mutex($false, $mutexName)
$h = Start-Holder 0.3 -Abandon
$hStart = Owner-Start $h
$h.WaitForExit()
$r = Run-Deploy @{ action = 'scan'; phase = 'searching'; owner_pid = $h.Id; owner_pid_start = $hStart; ts = $now }
Check 'S7 the mutex abandoned by a scan: the deploy proceeds and owns it (D3: a scan installs nothing)' ($r.verdict -eq 'deployed' -and $r.have) "$($r.verdict) have=$($r.have)"
Check '   and said so' ($r.log -match 'QWTUPDMUTEXABANDONED: .* scan .* proceeds') $r.log
Release-Deploy $r
$clean = $false; try { $clean = $keep.WaitOne(0); if ($clean) { $keep.ReleaseMutex() } } catch { $clean = $false }
Check '   the mutex is clean afterwards (a fresh take succeeds without an abandonment)' $clean

# S8 abandoned after a full pass: refused, and the mutex given back
$h = Start-Holder 0.3 -Abandon
$hStart = Owner-Start $h
$h.WaitForExit()
$r = Run-Deploy @{ action = 'full'; phase = 'done'; owner_pid = $h.Id; owner_pid_start = $hStart; ts = $now }
Check 'S8 the mutex abandoned by a full pass: refused with QWTUPDMUTEXABANDONED, nothing proceeds' ($r.verdict -like 'refused: QWTUPDMUTEXABANDONED*' -and -not $r.have) "$($r.verdict) have=$($r.have)"
Check '   the refusal names the pass and the remedy' ($r.verdict -match "'full'" -and $r.verdict -match 'install.cmd /updatesonly') $r.verdict
Release-Deploy $r
$clean = $false; try { $clean = $keep.WaitOne(0); if ($clean) { $keep.ReleaseMutex() } } catch { $clean = $false }
Check '   the refusing deploy gave the abandoned mutex back (a fresh take succeeds without an abandonment)' $clean
$keep.Dispose()

# S9 a 4.3.29 scan record, NOT held: the cut-off wording says the owner was never recorded
$r = Run-Deploy @{ action = 'scan'; phase = 'scan'; ts = $now }
Check 'S9 a cut-off 4.3.29 scan record with nobody holding: deploys, and says the record names no owner rather than "process 0 is gone"' ($r.verdict -eq 'deployed' -and $r.log -match 'recorded no owner process' -and $r.log -notmatch 'process \(0\) is gone') $r.log
Release-Deploy $r

# =====================================================================================================================
# PART 2 - the installer: what a refused deploy becomes in the log, the RESULT, the grader, the console and dom0
# =====================================================================================================================
$isrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'packaging/setup/Install-QwtImproved.ps1')
$ilines = $isrc -split "`n"
$recordReg  = Region $isrc 'UPDATER-DEPLOY-RECORD'
$deployReg  = Region $isrc 'UPDATER-DEPLOY'
$foldReg    = Region $isrc 'STAGE2-OK-FOLD'
$verdictReg = Region $isrc 'UPDATER-DEPLOY-VERDICT'
foreach ($g in 'deployerror', 'deployflag') { if ($deployReg -notmatch "# GUARD:$g") { Write-Output "FAIL GUARD:$g not found in UPDATER-DEPLOY"; exit 2 } }
if ($foldReg -notmatch '# GUARD:deployfold') { Write-Output 'FAIL GUARD:deployfold not found in STAGE2-OK-FOLD'; exit 2 }
foreach ($g in 'deployverdict', 'deploynotify') { if ($verdictReg -notmatch "# GUARD:$g") { Write-Output "FAIL GUARD:$g not found in UPDATER-DEPLOY-VERDICT"; exit 2 } }
switch ($Defect) {
    'deployerror'   { $deployReg  = Set-Guard $deployReg  'deployerror'   '                Write-Log "Windows Update agent deploy failed: $udMsg (non-fatal)" ''WARN''   # DEFECT: a WARN' }
    'deployflag'    { $deployReg  = Set-Guard $deployReg  'deployflag'    '                # DEFECT: no updater_agent_failed flag' }
    'deployfold'    { $foldReg    = Set-Guard $foldReg    'deployfold'    '    # DEFECT: the ok= block ignores updater_agent_failed' }
    'deployverdict' { $verdictReg = Set-Guard $verdictReg 'deployverdict' '        Write-Log "updater: $($udf.code)"   # DEFECT: no plain-words verdict' }
    'deploynotify'  { $verdictReg = Set-Guard $verdictReg 'deploynotify'  '        if ($false) {   # DEFECT: dom0 is not notified' }
    default { }
}

# shipped shapes
$callIdx = @(0..($ilines.Count - 1) | Where-Object { $ilines[$_].Contains('$ud = & $deployUpd -SetupRoot $Root') })
Check 'shipped: the installer streams the deploy''s output into its log as it arrives (the call is piped through Write-Log), not the last lines after the call' ($callIdx.Count -eq 1 -and $ilines[$callIdx[0]] -match '2>&1 \| ForEach-Object \{ Write-Log' -and $deployReg -notmatch 'Select-Object -Last') "call lines=$($callIdx -join ',')"
$iRx = { param($rx) @(0..($ilines.Count - 1) | Where-Object { $ilines[$_] -match $rx }) }
$vBegin = (& $iRx '# ---- UPDATER-DEPLOY-VERDICT-BEGIN')[0]; $wdRestore = (& $iRx "Start-Service -Name 'QubesGuiWatchdog' -ErrorAction Stop")[0]
$poweroff = (& $iRx '^\s*Emit-ResultThenPowerOff 0\s*$')[0]; $okFold = (& $iRx '^\s*\$errFlags = @\(\)\s*$')[0]; $complete = (& $iRx "INSTALL COMPLETE - QWT installed")[0]
Check 'shipped: the verdict sits after the ok= grading, INSTALL COMPLETE and the watchdog restore, and before the power-off / RESULT (the last lines a user reads)' ($null -ne $vBegin -and $okFold -lt $complete -and $complete -lt $wdRestore -and $wdRestore -lt $vBegin -and $vBegin -lt $poweroff) "fold=$okFold complete=$complete restore=$wdRestore verdict=$vBegin poweroff=$poweroff"
Check 'shipped: the deploy''s failure record is built in one place (Get-UpdaterDeployFailureRecord) and the state is initialised for StrictMode' ((& $iRx '^\s*\$script:UpdaterDeployFailure = \$null\s*$').Count -eq 1 -and @($ilines | Where-Object { $_ -match 'Get-UpdaterDeployFailureRecord -Message' }).Count -eq 2)
Check 'shipped: "non-fatal" is no longer how the updater deploy''s failure is logged' (($deployReg -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'non-fatal' }).Count -eq 0)

# the world
$iroot = Join-Path $tmp 'payload'; New-Item -ItemType Directory -Path $iroot | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'guest/qwt-notify-error.ps1') -Destination (Join-Path $iroot 'qwt-notify-error.ps1')
$modeFile = Join-Path $tmp 'deploy.mode'
Set-Content -LiteralPath (Join-Path $iroot 'install-updater-agent.ps1') -Encoding UTF8 -Value @"
param([string]`$SetupRoot)
`$ErrorActionPreference = 'Stop'
`$mode = (Get-Content -LiteralPath '$modeFile' -Raw).Trim()
Write-Output 'LINE-1 SetupRoot recovered'
Write-Output 'LINE-2 compiled relay'
Write-Output 'LINE-3 placed agent'
Write-Output 'LINE-4 REGISTER QubesWindowsUpdateScan rc=0'
Write-Output 'LINE-5 REGISTER QubesWindowsUpdateRun rc=0'
Write-Output 'LINE-6 task scheduler operational log'
Write-Output 'LINE-7 REGISTER QubesAutologonGuard rc=0'
if (`$mode -eq 'held') { Write-Output 'QWTUPDSCANWAIT: would have waited'; throw 'QWTUPDMUTEXHELD: Global\QubesWindowsUpdate is held by a running updater pass (last status record: ''full'', phase ''install'') - not a scan that ends on its own (tasks: Scan=Ready Run=Running Download=Ready), so it is not waited for; refusing. Let it finish or end it. Then run install.cmd /updatesonly from this install medium to install the Windows Update agent.' }
if (`$mode -eq 'incomplete') { Write-Output 'LINE-8 prepared updater workdir'; exit 0 }
Write-Output 'LINE-8 prepared updater workdir'
Write-Output 'updater agent deployed'
"@
$script:WLog = New-Object System.Collections.ArrayList
function Write-Log { param([string]$Message, [string]$Level = 'INFO') [void]$script:WLog.Add("[$Level] $Message") }
$script:FakeQrexec = 'Running'
function Get-Service { param([string]$Name, [string]$ErrorAction) [pscustomobject]@{ Name = $Name; Status = $script:FakeQrexec } }
$script:LogFile = Join-Path $tmp 'install.log'
# the shipped route's test hooks (as tools/tests/notifyerr-test.ps1 sets them): gate on, a pinned boot token, a state dir, a
# launcher that records the notify file instead of starting notifhost
$script:NotifyLaunched = New-Object System.Collections.ArrayList
$script:NotifyLogged   = New-Object System.Collections.ArrayList
$script:QwtNotifyHostExe = Join-Path $tmp 'notifhost.exe'                      # the route refuses when the host exe is absent
New-Item -ItemType File -Path $script:QwtNotifyHostExe -Force | Out-Null      # "present" for the recording launcher hook
. ([scriptblock]::Create($recordReg))
function Run-Install([string]$mode, [string]$qrexec, [bool]$noUpdater = $false) {
    Set-Content -LiteralPath $modeFile -Value $mode
    $script:WLog.Clear(); $script:NotifyLaunched.Clear(); $script:NotifyLogged.Clear()
    $script:FakeQrexec = $qrexec
    $stateDir = Join-Path $tmp ("notify-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $stateDir | Out-Null
    $script:QwtNotifyStateDir = $stateDir; $script:QwtNotifyGate = $true; $script:QwtNotifyBootStamp = 424242
    $script:QwtNotifyLog = { param($m) [void]$script:NotifyLogged.Add($m) }
    $script:QwtNotifyLauncher = { param($exe, $file) [void]$script:NotifyLaunched.Add((Get-Content -LiteralPath $file -Raw)) }
    $script:QwtNotifyLogged = @{}
    $script:Result = [ordered]@{ stage = 'stage2-install'; ok = $false; reboot_needed = $false; error = $null; detail = [ordered]@{} }
    $script:UpdaterDeployFailure = $null
    $Root = $iroot; $NoUpdaterAgent = $noUpdater
    . ([scriptblock]::Create($deployReg))
    . ([scriptblock]::Create($foldReg))
    . ([scriptblock]::Create($verdictReg))
    $json = $script:Result | ConvertTo-Json -Depth 6 -Compress
    $grader = @(& python3 (Join-Path $repoRoot 'mgmt/harness/result-flags.py') "=== RESULT === $json" 2>&1); $grc = $LASTEXITCODE
    return @{ log = @($script:WLog); logText = (@($script:WLog) -join ' | '); result = $script:Result; json = $json; graderRc = $grc; graderLast = "$($grader | Select-Object -Last 1)"
              launched = @($script:NotifyLaunched); notifyLog = (@($script:NotifyLogged) -join ' | ') }
}
function Has-Key($detail, [string]$k) { return (@($detail.Keys) -contains $k) }

# I1 deployed
$r = Run-Install 'deployed' 'Running'
Check 'I1 deployed: updater_agent=deployed, no failure flag, ok:true, grader green, no verdict, no notification' ($r.result.detail.updater_agent -eq 'deployed' -and -not (Has-Key $r.result.detail 'updater_agent_failed') -and $r.result.ok -eq $true -and $r.graderRc -eq 0 -and $r.logText -notmatch 'NOT installed' -and $r.launched.Count -eq 0) "$($r.json) grader=$($r.graderRc) $($r.graderLast)"
Check '   every line of the deploy is in the install log, in order (streamed - the first lines were lost when only the last six were logged)' (($r.log -join "`n") -match '\[INFO\]   LINE-1 .*\n.*LINE-2 .*\n.*LINE-3 .*\n.*LINE-4 .*\n.*LINE-5 .*\n.*LINE-6 .*\n.*LINE-7 .*\n.*LINE-8 .*\n.*updater agent deployed') $r.logText

# I2 refused with QrexecAgent running (the interactive path and -Auto without -RebootAtEnd)
$r = Run-Install 'held' 'Running'
Check 'I2 refused: the install log carries the refusal as an ERROR with the code, not a WARN' (@($r.log | Where-Object { $_ -match '^\[ERROR\] Windows Update agent deploy FAILED: QWTUPDMUTEXHELD' }).Count -eq 1 -and @($r.log | Where-Object { $_ -match '^\[WARN\].*Windows Update agent' }).Count -eq 0) $r.logText
Check '   the deploy''s own lines that preceded the throw are in the log (streamed)' ($r.logText -match 'LINE-7 REGISTER QubesAutologonGuard' -and $r.logText -match 'QWTUPDSCANWAIT: would have waited') $r.logText
Check '   RESULT: updater_agent=error: QWTUPDMUTEXHELD... AND updater_agent_failed=true' ("$($r.result.detail.updater_agent)" -like 'error: QWTUPDMUTEXHELD*' -and $r.result.detail.updater_agent_failed -eq $true) $r.json
Check '   RESULT: ok:false, and the error names updater_agent_failed (the ok= fold)' ($r.result.ok -eq $false -and "$($r.result.error)" -match 'updater_agent_failed') $r.json
Check '   mgmt/harness/result-flags.py grades it RED and names updater_agent_failed' ($r.graderRc -eq 1 -and $r.graderLast -match 'updater_agent_failed=') "rc=$($r.graderRc) $($r.graderLast)"
Check '   the last lines before the RESULT say it in plain words with the remedy' (@($r.log | Where-Object { $_ -match '^\[ERROR\] Windows Update agent was NOT installed: .*QWTUPDMUTEXHELD' }).Count -eq 1 -and $r.logText -match '\[ERROR\]   What to do: .*install.cmd /updatesonly' -and $r.logText -match 'keeps its previous updater') $r.logText
Check '   dom0 is notified through the shipped route (the text passed its gate, redaction and size rules): one notify file, header + remedy + code' ($r.launched.Count -eq 1 -and $r.launched[0] -match '^The Windows Update agent was not installed' -and $r.launched[0] -match 'install.cmd /updatesonly' -and $r.launched[0] -match 'QWTUPDMUTEXHELD' -and $r.logText -match 'dom0 notification installer.updater-not-installed: send') "launched=$($r.launched.Count) log=[$($r.logText)] route=[$($r.notifyLog)]"
$ntBytes = -1; $ntLines = -1
if ($r.launched.Count -eq 1) { $ntBytes = [Text.Encoding]::UTF8.GetByteCount($r.launched[0]); $ntLines = @($r.launched[0] -split "`n").Count }
Check "   the notification has at most 6 lines and 600 bytes (the route's own limits, measured on the sent text: $ntBytes bytes, $ntLines lines)" ($ntLines -ge 1 -and $ntLines -le 6 -and $ntBytes -ge 1 -and $ntBytes -le 600) "bytes=$ntBytes lines=$ntLines"

# I3 refused with QrexecAgent stopped (-Auto -RebootAtEnd: the service is left to the next boot)
$r = Run-Install 'held' 'Stopped'
Check 'I3 refused while QrexecAgent is not running: the verdict is still printed, no notification is attempted, and the log says the RESULT carries it' ($r.logText -match 'Windows Update agent was NOT installed' -and $r.launched.Count -eq 0 -and $r.logText -match 'dom0 was NOT notified from this boot: QrexecAgent is not running' -and $r.result.ok -eq $false -and $r.graderRc -eq 1) "launched=$($r.launched.Count) $($r.logText)"

# I4 returned without the completion line
$r = Run-Install 'incomplete' 'Running'
Check 'I4 the deploy returns without its completion line: ERROR, updater_agent_failed, ok:false, grader red, verdict, notification' ($r.logText -match '\[ERROR\] install-updater-agent.ps1 returned WITHOUT its completion line' -and $r.result.detail.updater_agent_failed -eq $true -and $r.result.ok -eq $false -and $r.graderRc -eq 1 -and $r.logText -match 'Windows Update agent was NOT installed' -and $r.launched.Count -eq 1) "$($r.json) $($r.logText)"

# I5 /noupdates
$r = Run-Install 'deployed' 'Running' $true
Check 'I5 /noupdates: skipped, no flag, ok:true, quiet' ($r.result.detail.updater_agent -eq 'skipped' -and -not (Has-Key $r.result.detail 'updater_agent_failed') -and $r.result.ok -eq $true -and $r.logText -notmatch 'NOT installed' -and $r.launched.Count -eq 0) $r.json

Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
if ($script:fail) { Write-Output "--- $($script:fail) FAILED"; exit 1 }
Write-Output '--- the updater deploy is loud and waits for a running scan'
