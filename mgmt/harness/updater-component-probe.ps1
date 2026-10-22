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
$work  = 'C:\ProgramData\Qubes\wu'
$bin   = 'C:\Program Files\Qubes Tools\bin'
$agent = Join-Path $bin 'qubes-windows-update.ps1'
$exe   = Join-Path $bin 'qubes-updates-relay.exe'
$alog  = Join-Path $work 'agent.log'
$rlog  = Join-Path $work 'qubes-updates-relay.log'
$ilog  = 'C:\qwt-improved-install.log'

function Size([string]$p) { if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 } }
$aPre = Size $alog
$rPre = Size $rlog

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
    $aPre = Size $alog
    $rPre = Size $rlog
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
Write-Output ("agent_log_pre=" + $aPre)
Write-Output ("relay_log_pre=" + $rPre)
Write-Output '#ENDSIZES#'

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

Write-Output '#AGENTLOG#'
foreach ($l in @(New-Lines $alog $aPre)) { if ($l.Trim()) { Write-Output $l.TrimEnd() } }
Write-Output '#ENDAGENTLOG#'

Write-Output '#RELAYLOG#'
foreach ($l in @(New-Lines $rlog $rPre)) { if ($l.Trim()) { Write-Output $l.TrimEnd() } }
Write-Output '#ENDRELAYLOG#'
