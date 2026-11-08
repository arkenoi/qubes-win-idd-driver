# updater-component-probe.ps1 - the guest half of mgmt/harness/updater-component-test.sh.
#
# It drives ONE scan pass and emits four delimited sections the host-side grader splits apart:
# #INSTALLLOG# (what the deploy said while installing), #AGENTLOG# / #RELAYLOG# (only what THIS
# pass appended), #EXE# (the installed binary's identity). Sections are delimited rather than
# separately fetched because one qrexec round trip cannot be interleaved with another, and because
# the host must grade exactly the bytes this pass produced.
#
# LOCALE. This runs on a German image. Nothing here matches a Windows string - only our own log
# lines, which we emit in English, and numbers. Get-Content is used without -Encoding so the
# ANSI/UTF-16 question stays with PowerShell's own detection, and the host side greps with -a.
$ErrorActionPreference = 'Continue'
$bin   = 'C:\Program Files\Qubes Tools\bin'
$agent = Join-Path $bin 'qubes-windows-update.ps1'
$exe   = Join-Path $bin 'qubes-updates-relay.exe'
$ilog  = 'C:\qwt-improved-install.log'
# THE PASS'S LOGS ARE PER-DAY FILES IN THE ONE LOG DIRECTORY since 2026-11-01 (docs/ADR-logging.md): the updater's
# qubes-windows-update.ps1-<yyyyMMdd>.log and the relay's qubes-updates-relay-<yyyyMMdd>.log, each named on the day its
# process starts - so one pass can write a file that did not exist when the window opened. The directory is log.c's
# rule: the registry LogDir, else <SystemDrive>\Qubes Logs. The old cumulative files are read SECOND: an updater from
# before the move still writes them, and on an upgraded guest they stay, frozen.
$logDir = $null
try { $logDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir -ErrorAction Stop).LogDir } catch { }
if (-not $logDir) { $logDir = Join-Path $env:SystemDrive 'Qubes Logs' }
$work  = 'C:\ProgramData\Qubes\wu'
$aOld  = Join-Path $work 'agent.log'
$rOld  = Join-Path $work 'qubes-updates-relay.log'

function Size([string]$p) { if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 } }
# Every file of one log as it stands now: the per-day files in name order (their date order), then the old one.
function Log-Files([string]$filter, [string]$old) {
    $f = @(Get-ChildItem -LiteralPath $logDir -Filter $filter -File -ErrorAction SilentlyContinue |
           Sort-Object Name | ForEach-Object { $_.FullName })
    $f += $old
    return $f
}
# The length of each of those files - the window's start. A file absent here and present after is wholly this pass's.
function Sizes([string]$filter, [string]$old) {
    $h = @{}
    foreach ($p in (Log-Files $filter $old)) { $h[$p] = Size $p }
    return $h
}
$aPre = Sizes 'qubes-windows-update.ps1-*.log' $aOld
$rPre = Sizes 'qubes-updates-relay-*.log' $rOld

# ---- what the DEPLOY said. The whole install log is filtered to the updater's own lines: the three
# vouch/compile lines are what the fa5b416a defect lacked while still reporting success.
Write-Output '#INSTALLLOG#'
if (Test-Path -LiteralPath $ilog) {
    foreach ($l in @(Get-Content -LiteralPath $ilog | Where-Object {
        $_ -match 'relay source vouched|compiled relay ->|relay exe vouched|updater agent deployed|QWTRELAY|kept the previous relay exe|a relay is running|relay processes on our image' })) {
        Write-Output $l.TrimEnd()
    }
} else { Write-Output "(no install log at $ilog)" }
Write-Output '#ENDINSTALLLOG#'

# ---- the installed binary's identity. The marker is searched as the UTF-16 bytes a .NET literal
# actually occupies: an ASCII hit would pass a binary that merely mentions the word.
Write-Output '#EXE#'
if (Test-Path -LiteralPath $exe) {
    $fi = Get-Item -LiteralPath $exe
    Write-Output ("written=" + $fi.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    Write-Output ("size=" + $fi.Length)
    $b = [IO.File]::ReadAllBytes($exe)
    $m = [Text.Encoding]::Unicode.GetBytes('parent=')
    $hit = $false
    for ($i = 0; $i -le $b.Length - $m.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $m.Length; $j++) { if ($b[$i+$j] -ne $m[$j]) { $ok = $false; break } }
        if ($ok) { $hit = $true; break }
    }
    Write-Output ("marker=" + $hit)
} else { Write-Output 'written=ABSENT'; Write-Output 'size=0'; Write-Output 'marker=False' }
Write-Output '#ENDEXE#'

# ---- ONE pass. -Action scan is the path that reports availability to dom0; download and install
# stay on-demand by design, so a scan is the component's own end-to-end.
# ---- WAIT FOR THE UPDATER MUTEX, THEN RUN ONE PASS -------------------------------------------
# The install re-enables QubesWindowsUpdateScan, so a scheduled pass is often already running when
# this probe arrives. `-Action scan` then REFUSES - "QWTUPDMUTEXHELD: another Qubes update operation
# is in progress" - and, because refusing is not an error, it EXITS 0. Measured 2026-10-22: the
# harness read exit 0, believed a scan had run, and graded gates against a pass it had not driven.
# So: wait for the mutex to clear (bounded), and if it is still held, say so in a way the grader
# cannot mistake for success.
$mutexHeld = $false
Write-Output '#SCAN#'
$scanOut = @()
for ($attempt = 1; $attempt -le 10; $attempt++) {
    # THE WINDOW STARTS HERE, NOT BEFORE THE WAIT. Re-snapshotted on every attempt because the pass
    # holding the mutex keeps writing while we wait: measured 2026-10-22, a window opened before the
    # wait carried the CONCURRENT pass's completion ("13:10:48 scan: 6 update(s) offered ... reported
    # to dom0"), so U5 could have been satisfied by a pass this test did not drive. Same verdict that
    # time, but a gate must not depend on which pass happened to finish inside the window.
    $aPre = Sizes 'qubes-windows-update.ps1-*.log' $aOld
    $rPre = Sizes 'qubes-updates-relay-*.log' $rOld
    $scanOut = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $agent -Action scan 2>&1)
    $rc = $LASTEXITCODE
    if (@($scanOut | Where-Object { "$_" -match 'QWTUPDMUTEXHELD' }).Count -gt 0) {
        Write-Output ("  attempt " + $attempt + ": the updater mutex is held by another pass - waiting 60s")
        $mutexHeld = $true
        Start-Sleep -Seconds 60
        continue
    }
    $mutexHeld = $false
    break
}
foreach ($l in $scanOut) { Write-Output ("  " + $l) }
Write-Output ("scan_exit=" + $rc)
Write-Output ("scan_refused_mutex=" + $mutexHeld)
Write-Output '#ENDSCAN#'

# the offsets the windows below actually used - printed AFTER the scan because they are taken
# immediately before the attempt that ran, so a reader can check the window against the logs
Write-Output '#SIZES#'
foreach ($k in @($aPre.Keys | Sort-Object)) { Write-Output ("agent_log_pre=" + $aPre[$k] + " " + $k) }
foreach ($k in @($rPre.Keys | Sort-Object)) { Write-Output ("relay_log_pre=" + $rPre[$k] + " " + $k) }
Write-Output '#ENDSIZES#'

# THE PERSISTED STATUS, FOR U8 - AND SPLIT INTO PLAIN LINES HERE, NOT PARSED IN THE SHELL.
# `satisfied` is the list of offer identities (uid:rev) a pass wrote under satisfied_rule='installed',
# the only list the NEXT pass honours (guest/qubes-windows-update.ps1:3072, ADR-updater section 2 point 3),
# and the only place an identity this guest proved installed survives a pass. The grader is all grep over
# files by design, so the JSON is decoded HERE, where a parser exists, and leaves as one `satisfied=` line
# per identity. The updater itself records that this file can be held by another pass
# (qubes-windows-update.ps1:210), so an unreadable file prints its own reason and NEVER fails the probe:
# no status means U8 has no verdict, which is not a product failure.
Write-Output '#STATUS#'
try {
    $sp = 'C:\ProgramData\Qubes\update-status.json'
    if (Test-Path -LiteralPath $sp) {
        # READ IT THE WAY ITS OWN WRITER READS IT. guest/qubes-windows-update.ps1:89 does exactly
        # `Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json`; [IO.File]::ReadAllText would
        # decode as UTF-8 regardless of what PowerShell 5.1's Set-Content wrote on a German guest,
        # which is the same byte/encoding mismatch this file already pays attention to further down.
        $sj = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
        Write-Output ('status_readable=True mtime=' + (Get-Item -LiteralPath $sp).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        Write-Output ('satisfied_rule=' + [string]$sj.satisfied_rule)
        foreach ($s in @($sj.satisfied)) { if ("$s".Trim()) { Write-Output ('satisfied=' + "$s") } }
    } else {
        Write-Output 'status_readable=False reason=absent'
    }
} catch {
    Write-Output ('status_readable=False reason=' + $_.Exception.GetType().Name)
}
Write-Output '#ENDSTATUS#'

# NOTHING NEW MEANS NOTHING - NEVER THE WHOLE FILE.
# MEASURED 2026-10-22: the else-branch here used to return the ENTIRE log when this pass had
# appended nothing. On a run whose scan refused instantly (QWTUPDMUTEXHELD) that handed the grader
# the golden's whole history plus a concurrent pass's lines, and two gates "passed" on entries from
# 19:04 the previous evening. A fallback that substitutes different evidence is worse than no
# evidence: the grader can report INSTRUMENT on an empty window, but it cannot know that a full
# window belongs to someone else's pass.
# The offset is also in BYTES while a -Raw string indexes in CHARACTERS, so the comparison is made
# on the byte length of the text read back, not on $t.Length.
function New-Lines([string]$p, [long]$pre) {
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    # BYTES IN, BYTES OUT. $pre is a file LENGTH in bytes; a -Raw string indexes in CHARACTERS, so
    # mixing them cuts at the wrong place on any non-ASCII line - and this is a German guest. Read
    # the file as bytes, decode ONLY the range this pass appended. No ternary: the guest is
    # PowerShell 5.1 and `a ? b : c` is 7-only syntax that ps-parse-check (pwsh 7) would pass.
    $all = [IO.File]::ReadAllBytes($p)
    if ($all.Length -le $pre) { return @() }
    $n = $all.Length - $pre
    $new = New-Object byte[] $n
    [Array]::Copy($all, [long]$pre, $new, 0, $n)
    return ([Text.Encoding]::Default.GetString($new) -split "`r?`n")
}

# What this pass appended to every file of one log, the per-day files first and the old file last, each from the length
# it had when the window opened (0 for a file the window did not see: all of it is new).
function Pass-Lines([string]$filter, [string]$old, [hashtable]$pre) {
    foreach ($p in (Log-Files $filter $old)) {
        $from = 0
        if ($pre.ContainsKey($p)) { $from = [long]$pre[$p] }
        foreach ($l in @(New-Lines $p $from)) { if ($l.Trim()) { Write-Output $l.TrimEnd() } }
    }
}

Write-Output '#AGENTLOG#'
Pass-Lines 'qubes-windows-update.ps1-*.log' $aOld $aPre
Write-Output '#ENDAGENTLOG#'

Write-Output '#RELAYLOG#'
Pass-Lines 'qubes-updates-relay-*.log' $rOld $rPre
Write-Output '#ENDRELAYLOG#'
