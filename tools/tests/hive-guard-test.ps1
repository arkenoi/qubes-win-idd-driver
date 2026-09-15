<#
.SYNOPSIS
    Offline suite for the self-guarding offline-hive path of guest/disable-hw-accel.ps1 and
    guest/disable-session-lock.ps1 (findings/issues.md installer audit 2026-09-16, items 2 and 15).

.DESCRIPTION
    Runs under the Linux pwsh on the dev qube - no rig, no guest, no registry. For each script it
    extracts the `# ---- HIVE-GUARD-BEGIN/END` and `# ---- OFFLINE-HIVE-BEGIN/END` marker blocks
    (never sed-to-closing-brace), dot-sources them, replaces the three registry primitives with
    stubs, puts a fake reg.exe on PATH that logs every call and refuses the ones named in
    FAKE_REG_FAIL, and judges OUTPUT: which reg calls happened and in what order, what the trailer
    counter ($script:failed) says, and how long the wait took.

    The condition under test is the audit's: an offline NTUSER.DAT is reg-loaded while the autologon
    user's logon may be in flight (HKEY_USERS\<sid> absent) and the run still reports failed=0; and,
    for item 15, a hive whose unload failed twice is reported as failed=0.

    DEFECT KNOB: HIVEGUARD_DEFECT=<name> deletes the extracted line tagged `# GUARD:<name>` from
    BOTH scripts (exactly one such line per script must exist, else exit 2) so the suite runs
    against the pre-fix shape:
      hivewait    the load fires whatever the guard decided        (audit item 2)
      unloadread  the second unload attempt's exit code is discarded (audit item 15)
    tools/tests/hive-guard-selftest.sh runs clean + each knob and requires the knob to redden
    exactly the intended cases (hivewait: hw-4 hw-5 sl-4 sl-5 - both are "the guard said no and the
    load fired anyway"; unloadread: hw-7 sl-7).

    Exit 0 = every check matched; 1 = at least one FAIL; 2 = the suite could not run (Windows,
    missing marker, knob that did not apply) - a suite that cannot run must never look green.
#>
[CmdletBinding()]
param([string]$HwAccelPath, [string]$SessionLockPath)

$ErrorActionPreference = 'Stop'
if ($IsWindows) { Write-Host 'FATAL: this suite fakes reg.exe through PATH and only runs on the Linux pwsh'; exit 2 }
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $HwAccelPath)     { $HwAccelPath     = Join-Path $repoRoot 'guest/disable-hw-accel.ps1' }
if (-not $SessionLockPath) { $SessionLockPath = Join-Path $repoRoot 'guest/disable-session-lock.ps1' }
$HwAccelPath     = (Resolve-Path -LiteralPath $HwAccelPath).Path
$SessionLockPath = (Resolve-Path -LiteralPath $SessionLockPath).Path

$script:run = 0; $script:fail = 0
# Every check name starts with its case id (hw-N / sl-N): the selftest wrapper groups FAIL lines by
# that id to prove a knob reddens exactly the intended cases.
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $line = "$tag $name"
    if ($detail) { $line += "   [$detail]" }
    Write-Host $line
}

# --- scratch: fake reg.exe on PATH, two NTUSER.DAT stand-ins ------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hiveguard-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$regDir = Join-Path $tmp 'reg'
New-Item -ItemType Directory -Path (Join-Path $tmp 'bin'), $regDir, (Join-Path $tmp 'alice'), (Join-Path $tmp 'Default') -Force | Out-Null
$fake = @'
#!/bin/sh
# fake reg.exe for tools/tests/hive-guard-test.ps1: logs "op arg1 arg2" to $FAKE_REG_DIR/calls.log and
# refuses the calls named in FAKE_REG_FAIL as "op:N" (N = the Nth call of that op in this case).
op="$1"
n=$(cat "$FAKE_REG_DIR/count.$op" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_REG_DIR/count.$op"
echo "$op $2 $3" >> "$FAKE_REG_DIR/calls.log"
case " $FAKE_REG_FAIL " in *" $op:$n "*) echo "ERROR: fake reg.exe refused $op #$n" >&2; exit 1;; esac
exit 0
'@
$fakePath = Join-Path $tmp 'bin/reg.exe'
[IO.File]::WriteAllText($fakePath, $fake.Replace("`r`n", "`n"))
& chmod +x $fakePath
$env:PATH = (Join-Path $tmp 'bin') + ':' + $env:PATH
$env:FAKE_REG_DIR = $regDir
$dat1 = Join-Path $tmp 'alice/NTUSER.DAT';   [IO.File]::WriteAllText($dat1, 'not a hive')
$dat2 = Join-Path $tmp 'Default/NTUSER.DAT'; [IO.File]::WriteAllText($dat2, 'not a hive')
$datMissing = Join-Path $tmp 'missing/NTUSER.DAT'

# --- marker extraction + defect knob --------------------------------------------------------------
function Get-MarkerBlock([string]$Path, [string]$Name) {
    $lines = [IO.File]::ReadAllLines($Path)
    $b = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match "^# ---- $Name-BEGIN" })
    $e = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match "^# ---- $Name-END" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $e[0] -le $b[0]) {
        Write-Host "FATAL: $Path must carry exactly one '# ---- $Name-BEGIN' and one '# ---- $Name-END' (found $($b.Count)/$($e.Count))"
        exit 2
    }
    return $lines[($b[0] + 1)..($e[0] - 1)]
}
$knob = $env:HIVEGUARD_DEFECT
function New-ExtractedScript([string]$Path, [string]$Tag) {
    $body = @(Get-MarkerBlock $Path 'HIVE-GUARD') + @(Get-MarkerBlock $Path 'OFFLINE-HIVE')
    if ($knob) {
        $kept = @($body | Where-Object { $_ -notmatch "#\s*GUARD:$knob\s*$" })
        $removed = $body.Count - $kept.Count
        if ($removed -ne 1) {
            Write-Host "FATAL: knob '$knob' must delete exactly one '# GUARD:$knob' line from $Path, would delete $removed"
            exit 2
        }
        $body = $kept
        Write-Host "knob   $knob applied to $(Split-Path $Path -Leaf): 1 line deleted"
    }
    $out = Join-Path $tmp "$Tag.ps1"
    [IO.File]::WriteAllLines($out, $body)
    return $out
}
$hwFile = New-ExtractedScript $HwAccelPath 'hw'
$slFile = New-ExtractedScript $SessionLockPath 'sl'

# --- stubs for the three registry primitives + the per-hive writers ----------------------------
$script:wl = $null                                   # what Get-HiveGuardWinlogon returns
$script:sid = 'S-1-5-21-1111-2222-3333-1001'         # what Resolve-HiveGuardSid returns ($null = throws)
$script:keyLoadedAt = 0                              # Test-HiveGuardKey: $true from the Nth probe on; 0 = at once; -1 = never
$script:probes = 0
$script:writes = New-Object System.Collections.ArrayList
function Install-Stubs {
    function script:Get-HiveGuardWinlogon { return $script:wl }
    function script:Test-HiveGuardKey([string]$Sid) {
        $script:probes++
        if ($Sid -ne $script:sid) { throw "guard probed the wrong SID: '$Sid' (expected '$($script:sid)')" }
        if ($script:keyLoadedAt -lt 0) { return $false }
        return ($script:probes -ge $script:keyLoadedAt)
    }
    function script:Resolve-HiveGuardSid([string]$Account) {
        if (-not $script:sid) { throw 'unresolvable account' }
        return $script:sid
    }
    # the writers: record where the script wanted to write, touch no registry
    function script:Set-PerUserValues { param([string]$HiveRoot, [string]$Label) [void]$script:writes.Add($HiveRoot) }
    function script:Set-Reg { param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Why) [void]$script:writes.Add($Path) }
}
function Reset-Case([hashtable]$Winlogon, [int]$KeyLoadedAt, [string]$RegFail = '', [int]$TimeoutSec = 10, [int]$PollSec = 1) {
    Get-ChildItem -LiteralPath $regDir -Force | Remove-Item -Force
    $env:FAKE_REG_FAIL = $RegFail
    $script:wl = $Winlogon; $script:keyLoadedAt = $KeyLoadedAt; $script:probes = 0; $script:writes.Clear()
    $script:sid = 'S-1-5-21-1111-2222-3333-1001'
    $script:failed = 0; $script:changed = 0
    $script:hiveGuardVerdict = $null; $script:hiveGuardTimeoutSec = $TimeoutSec; $script:hiveGuardPollSec = $PollSec
}
function Get-RegCalls {
    $log = Join-Path $regDir 'calls.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    return @([IO.File]::ReadAllLines($log) | ForEach-Object { ($_ -split ' ')[0] })
}
function Count-Lines($Out, [string]$Pattern) { return @($Out | Where-Object { "$_" -match $Pattern }).Count }

$armed   = @{ AutoAdminLogon = '1'; DefaultUserName = 'user'; DefaultDomainName = 'WIN-TEST' }
$unarmed = @{ AutoAdminLogon = '0'; DefaultUserName = 'user' }
$WhatIfOnly = $false
$ErrorActionPreference = 'Continue'   # the shipped scripts run with Continue; the cases judge results explicitly

# ================================================================================================
# guest/disable-hw-accel.ps1
# ================================================================================================
. $hwFile
Install-Stubs
$perUser = @(@{ sub = 'Software\Microsoft\Avalon.Graphics'; name = 'DisableHWAcceleration'; val = 1; type = 'DWord'; why = 'WPF' })
$mountHw = "Registry::HKEY_USERS\QwtNg$PID"

# hw-1: no autologon armed -> nothing to wait for; load, write, unload; failed=0
Reset-Case $unarmed -1
$o = @(Set-OfflineHive $dat1 'profile alice'); $c = Get-RegCalls
Check 'hw-1 no autologon armed: hive loaded, written, unloaded in that order' (($c -join ',') -eq 'load,unload' -and $script:writes.Count -eq 1 -and $script:writes[0] -eq $mountHw) "calls=$($c -join ',') writes=$($script:writes -join ',')"
Check 'hw-1 no autologon armed: failed=0 and the hive key was never probed' ($script:failed -eq 0 -and $script:probes -eq 0) "failed=$($script:failed) probes=$($script:probes)"

# hw-2: autologon armed, hive already under HKEY_USERS -> no wait at all
Reset-Case $armed 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat1 'profile alice'); $sw.Stop(); $c = Get-RegCalls
Check 'hw-2 autologon armed, hive loaded: load+unload, failed=0' (($c -join ',') -eq 'load,unload' -and $script:failed -eq 0) "calls=$($c -join ',') failed=$($script:failed)"
Check 'hw-2 autologon armed, hive loaded: decided without sleeping' ($sw.ElapsedMilliseconds -lt 900 -and (Count-Lines $o '^ok     autologon user') -eq 1) "elapsed=$($sw.ElapsedMilliseconds)ms"

# hw-3: hive appears on the 3rd probe -> the guard WAITS, then the load proceeds
Reset-Case $armed 3 -TimeoutSec 10 -PollSec 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat1 'profile alice'); $sw.Stop(); $c = Get-RegCalls
Check 'hw-3 hive appears on probe 3: waited two polls then loaded' ($sw.ElapsedMilliseconds -ge 1900 -and $sw.ElapsedMilliseconds -lt 8000 -and $script:probes -ge 3 -and ($c -join ',') -eq 'load,unload') "elapsed=$($sw.ElapsedMilliseconds)ms probes=$($script:probes) calls=$($c -join ',')"
Check 'hw-3 hive appears on probe 3: WAIT announced once, failed=0' ((Count-Lines $o '^WAIT   autologon user') -eq 1 -and $script:failed -eq 0) "failed=$($script:failed)"

# hw-4: THE AUDIT CASE. Hive never appears -> NO reg load for any profile, failed=1, decided once.
Reset-Case $armed -1 -TimeoutSec 2 -PollSec 1
$sw = [Diagnostics.Stopwatch]::StartNew()
$o = @(Set-OfflineHive $dat1 'profile alice') + @(Set-OfflineHive $dat2 'default profile')
$sw.Stop(); $c = Get-RegCalls
Check 'hw-4 hive never appears: NO reg.exe call at all (nothing loaded under a logon in flight)' ($c.Count -eq 0 -and $script:writes.Count -eq 0) "calls=$($c -join ',')"
Check 'hw-4 hive never appears: failed=1 (one deadline, counted once), both hives SKIPPED loudly' ($script:failed -eq 1 -and (Count-Lines $o '^SKIP   .*NOT loaded') -eq 2 -and (Count-Lines $o '^FAIL   autologon user.*no loaded hive after 2s') -eq 1) "failed=$($script:failed) skip=$(Count-Lines $o '^SKIP   .*NOT loaded') fail=$(Count-Lines $o '^FAIL')"
Check 'hw-4 hive never appears: the deadline ran ONCE for two hives (verdict memoised)' ($sw.ElapsedMilliseconds -ge 2000 -and $sw.ElapsedMilliseconds -lt 4000) "elapsed=$($sw.ElapsedMilliseconds)ms"

# hw-5: the account does not resolve -> cannot tell -> skip + failed=1, no load
Reset-Case $armed 1; $script:sid = $null
$o = @(Set-OfflineHive $dat1 'profile alice'); $c = Get-RegCalls
Check 'hw-5 autologon SID unresolvable: no load, failed=1, said so' ($c.Count -eq 0 -and $script:failed -eq 1 -and (Count-Lines $o '^FAIL   autologon user.*does not resolve') -eq 1) "calls=$($c -join ',') failed=$($script:failed)"

# hw-6: reg load refused -> failed=1, no write, no unload attempted
Reset-Case $armed 1 -RegFail 'load:1'
$o = @(Set-OfflineHive $dat1 'profile alice'); $c = Get-RegCalls
Check 'hw-6 load refused: failed=1, nothing written, no unload' (($c -join ',') -eq 'load' -and $script:writes.Count -eq 0 -and $script:failed -eq 1 -and (Count-Lines $o '^FAIL   .*could not load') -eq 1) "calls=$($c -join ',') failed=$($script:failed)"

# hw-7: both unload attempts refused -> failed=1 and PROFILE LEFT LOCKED
Reset-Case $armed 1 -RegFail 'unload:1 unload:2'
$o = @(Set-OfflineHive $dat1 'profile alice'); $c = Get-RegCalls
Check 'hw-7 unload refused twice: two attempts made, failed=1, PROFILE LEFT LOCKED reported' (($c -join ',') -eq 'load,unload,unload' -and $script:failed -eq 1 -and (Count-Lines $o 'PROFILE LEFT LOCKED') -eq 1) "calls=$($c -join ',') failed=$($script:failed)"

# hw-8: first unload refused, retry succeeds -> failed=0
Reset-Case $armed 1 -RegFail 'unload:1'
$o = @(Set-OfflineHive $dat1 'profile alice'); $c = Get-RegCalls
Check 'hw-8 unload refused once: retry succeeded, failed=0' (($c -join ',') -eq 'load,unload,unload' -and $script:failed -eq 0) "calls=$($c -join ',') failed=$($script:failed)"

# hw-9: DAT missing -> SKIP before the guard; never wait for a hive nothing will load
Reset-Case $armed -1 -TimeoutSec 2 -PollSec 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $datMissing 'profile ghost'); $sw.Stop(); $c = Get-RegCalls
Check 'hw-9 DAT missing: SKIP, no probe, no wait, failed=0' ($c.Count -eq 0 -and $script:probes -eq 0 -and $script:failed -eq 0 -and $sw.ElapsedMilliseconds -lt 900 -and (Count-Lines $o '^SKIP   .*not found') -eq 1) "elapsed=$($sw.ElapsedMilliseconds)ms failed=$($script:failed)"

# hw-10: dry run -> WOULD lines, no load, no wait
Reset-Case $armed -1 -TimeoutSec 2 -PollSec 1
$WhatIfOnly = $true
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat1 'profile alice'); $sw.Stop(); $c = Get-RegCalls
$WhatIfOnly = $false
Check 'hw-10 dry run: WOULD lines only, no load, no probe, no wait' ($c.Count -eq 0 -and $script:probes -eq 0 -and $sw.ElapsedMilliseconds -lt 900 -and (Count-Lines $o '^WOULD  ') -eq $perUser.Count) "elapsed=$($sw.ElapsedMilliseconds)ms would=$(Count-Lines $o '^WOULD  ')"

# ================================================================================================
# guest/disable-session-lock.ps1
# ================================================================================================
. $slFile
Install-Stubs
$perUser = @(@{ sub = 'Control Panel\Desktop'; n = 'ScreenSaveActive'; v = '0'; why = 'screensaver' })
$mountSl = 'Registry::HKEY_USERS\QwtNgLock\Control Panel\Desktop'

# sl-1
Reset-Case $unarmed -1
$o = @(Set-OfflineHive $dat2 'default profile'); $c = Get-RegCalls
Check 'sl-1 no autologon armed: hive loaded, written, unloaded in that order' (($c -join ',') -eq 'load,unload' -and $script:writes.Count -eq 1 -and $script:writes[0] -eq $mountSl) "calls=$($c -join ',') writes=$($script:writes -join ',')"
Check 'sl-1 no autologon armed: failed=0 and the hive key was never probed' ($script:failed -eq 0 -and $script:probes -eq 0) "failed=$($script:failed) probes=$($script:probes)"

# sl-2
Reset-Case $armed 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat2 'default profile'); $sw.Stop(); $c = Get-RegCalls
Check 'sl-2 autologon armed, hive loaded: load+unload, failed=0, no sleep' (($c -join ',') -eq 'load,unload' -and $script:failed -eq 0 -and $sw.ElapsedMilliseconds -lt 900) "calls=$($c -join ',') failed=$($script:failed) elapsed=$($sw.ElapsedMilliseconds)ms"

# sl-3
Reset-Case $armed 3 -TimeoutSec 10 -PollSec 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat2 'default profile'); $sw.Stop(); $c = Get-RegCalls
Check 'sl-3 hive appears on probe 3: waited two polls then loaded, failed=0' ($sw.ElapsedMilliseconds -ge 1900 -and $sw.ElapsedMilliseconds -lt 8000 -and ($c -join ',') -eq 'load,unload' -and $script:failed -eq 0 -and (Count-Lines $o '^WAIT   ') -eq 1) "elapsed=$($sw.ElapsedMilliseconds)ms calls=$($c -join ',')"

# sl-4: THE AUDIT CASE for the Default hive
Reset-Case $armed -1 -TimeoutSec 2 -PollSec 1
$sw = [Diagnostics.Stopwatch]::StartNew(); $o = @(Set-OfflineHive $dat2 'default profile'); $sw.Stop(); $c = Get-RegCalls
Check 'sl-4 hive never appears: NO reg.exe call (Default hive not loaded under a logon in flight)' ($c.Count -eq 0 -and $script:writes.Count -eq 0) "calls=$($c -join ',')"
Check 'sl-4 hive never appears: failed=1, SKIPPED loudly, deadline honoured' ($script:failed -eq 1 -and (Count-Lines $o '^SKIP   .*NOT loaded') -eq 1 -and (Count-Lines $o '^FAIL   autologon user.*no loaded hive after 2s') -eq 1 -and $sw.ElapsedMilliseconds -ge 2000 -and $sw.ElapsedMilliseconds -lt 4000) "failed=$($script:failed) elapsed=$($sw.ElapsedMilliseconds)ms"

# sl-5
Reset-Case $armed 1; $script:sid = $null
$o = @(Set-OfflineHive $dat2 'default profile'); $c = Get-RegCalls
Check 'sl-5 autologon SID unresolvable: no load, failed=1, said so' ($c.Count -eq 0 -and $script:failed -eq 1 -and (Count-Lines $o '^FAIL   autologon user.*does not resolve') -eq 1) "calls=$($c -join ',') failed=$($script:failed)"

# sl-6: load refused -> WARN (pre-existing behaviour, not this mandate), nothing written, no unload
Reset-Case $armed 1 -RegFail 'load:1'
$o = @(Set-OfflineHive $dat2 'default profile'); $c = Get-RegCalls
Check 'sl-6 load refused: nothing written, no unload attempted, WARN printed' (($c -join ',') -eq 'load' -and $script:writes.Count -eq 0 -and (Count-Lines $o '^WARN   could not load') -eq 1) "calls=$($c -join ',') failed=$($script:failed) (failed not asserted: pre-existing WARN)"

# sl-7: THE ITEM-15 CASE. Both unload attempts refused -> failed=1, PROFILE LEFT LOCKED
Reset-Case $armed 1 -RegFail 'unload:1 unload:2'
$o = @(Set-OfflineHive $dat2 'default profile'); $c = Get-RegCalls
Check 'sl-7 unload refused twice: two attempts made, failed=1, PROFILE LEFT LOCKED reported' (($c -join ',') -eq 'load,unload,unload' -and $script:failed -eq 1 -and (Count-Lines $o 'PROFILE LEFT LOCKED') -eq 1) "calls=$($c -join ',') failed=$($script:failed)"

# sl-8
Reset-Case $armed 1 -RegFail 'unload:1'
$o = @(Set-OfflineHive $dat2 'default profile'); $c = Get-RegCalls
Check 'sl-8 unload refused once: retry succeeded, failed=0' (($c -join ',') -eq 'load,unload,unload' -and $script:failed -eq 0) "calls=$($c -join ',') failed=$($script:failed)"

# --- verdict ------------------------------------------------------------------------------------
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
