<#
.SYNOPSIS
    The death reporter's LOG DIRECTORY resolver, which no other check has ever exercised.

.DESCRIPTION
    Owner, 2026-10-07: "NOTHING should write log outside." "we have one common log location!"

    WHY THIS FILE EXISTS. guest/qwt-report-death.ps1 writes the one record the release gate reads for
    deaths, and it resolves where to write it from the registry's LogDir. Both existing offline
    suites - death-reporter-test.ps1 and notify-render-test.ps1 - set the $script:QwtDeathLogDir test
    hook before dot-sourcing, and Get-QwtDeathLogDir short-circuits on that hook as its FIRST line.
    So between them, 630 checks, and the resolver and its fallback were executed by NONE of them.
    Jev, asked whether the fix could go in without one: needs_a_failing_check_first 0.61.

    THE TWO DEFECTS THIS DRIVES, and both are seen to FAIL below against the unmodified file:

    1. THE GATE. The resolver demanded that the configured LogDir ALREADY EXIST
       (`if ($v -and (Test-Path -LiteralPath $v))`) and otherwise diverted to %ProgramData%\Qubes -
       which the writer then CREATES one line later. The one case the gate existed for is the case
       the writer handled for free, so its only effect was to prefer a second directory over the one
       common location. The consequence is a SPLIT RECORD: the deaths log exists in two places on one
       guest, the user-facing notification embeds the path as its evidence, and the watermark moves
       with it. LogDir is on the private volume Q: and the reporter task has a BOOT trigger, so
       "configured but not yet there" is the normal case, not a corner.

    2. THE LOST LINE. Simply dropping that gate would have been worse: when the configured directory
       cannot be created, New-Item throws inside one `try { } catch { }` that wraps the append as
       well, and the empty catch SWALLOWS THE DEATH LINE - trading a split record for a lost one,
       which is what "missing data FAILS" forbids. The writer must therefore FALL BACK and still
       write, say in the record that it fell back, and if there is no writable directory at all, say
       on stderr that the line was LOST rather than drop it in silence.

    Run: pwsh -File tools/tests/death-log-resolver-test.ps1
    No rig, no registry, no event log: Get-ItemProperty is stubbed (a function outranks a cmdlet) so
    a Linux pwsh can drive a registry-backed resolver, and $env:ProgramData is pointed at a temp dir
    so the fallback is deterministic instead of being /tmp.
#>
param(
    [string]$ReporterPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'guest/qwt-report-death.ps1')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ReporterPath)) { Write-Output "FAIL reporter not found at $ReporterPath"; exit 2 }

$pass = 0; $fail = 0
function Ok([string]$m) { $script:pass++; Write-Output "PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Output "FAIL  $m" }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("qwtdlr-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$progData = Join-Path $tmpRoot 'ProgramData'
New-Item -ItemType Directory -Force -Path $progData | Out-Null
$env:ProgramData = $progData
$pdQubes = Join-Path $progData 'Qubes'

# THE STUB. $script:StubLogDir is what the registry "holds"; $null means the value is unreadable.
# A function outranks a cmdlet in PowerShell's command precedence, so this is what the resolver
# calls. It answers ONLY the LogDir query and returns nothing for anything else, so a stray call
# cannot silently pick up this answer.
$script:StubLogDir = $null
$script:StubReads = 0
function Get-ItemProperty {
    param([string]$Path, [string]$Name, $ErrorAction)
    if ($Name -eq 'LogDir') {
        $script:StubReads++
        if ($null -eq $script:StubLogDir) { return $null }
        return [pscustomobject]@{ LogDir = $script:StubLogDir }
    }
    return $null
}

# Library-only, and DELIBERATELY WITHOUT the $script:QwtDeathLogDir hook - setting it is exactly
# what made the other two suites blind to this code.
$script:QwtDeathLibraryOnly = $true
$script:QwtDeathStateDir = Join-Path $tmpRoot 'state'
New-Item -ItemType Directory -Force -Path $script:QwtDeathStateDir | Out-Null
$script:QwtNotifyGate = $false
function Write-Host { }
. $ReporterPath

# The resolver memoises into $script:QwtDeathLogDir, and the fallback marker is once per process,
# so every case must start from a clean slate or the second case reads the first one's answer.
function Reset-Resolver {
    $script:QwtDeathLogDir = $null
    if (Get-Variable -Name QwtDeathLogDirConfigured -Scope script -ErrorAction SilentlyContinue) {
        $script:QwtDeathLogDirConfigured = $null
    }
    if (Get-Variable -Name QwtDeathLogDirSaid -Scope script -ErrorAction SilentlyContinue) {
        $script:QwtDeathLogDirSaid = $false
    }
}
function Read-Log([string]$dir) {
    $p = Join-Path $dir 'qwt-deaths.log'
    if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) }
    return ''
}

Write-Output "--- 1. a configured LogDir that does not exist yet is STILL the answer ------------"
# The boot-trigger case: Q: is configured, the directory is not there yet. The record belongs in the
# one common location, which the writer creates - not in a second directory.
Reset-Resolver
$want = Join-Path $tmpRoot 'Q-Qubes Logs'          # configured, deliberately NOT created
$script:StubLogDir = $want
$got = Get-QwtDeathLogDir
if ($got -eq $want) {
    Ok "configured_absent_dir_wins: the resolver returned the configured directory ($got)"
} else {
    Bad "configured_absent_dir_wins: resolver returned '$got', wanted the configured '$want' - the record goes to a SECOND directory and the gate reads a split record"
}

Write-Output "--- 2. and the death line actually lands there -------------------------------------"
Reset-Resolver
$script:StubLogDir = $want
Write-QwtDeathLog 'ERROR' 'resolver-test line A'
$txt = Read-Log $want
if ($txt -match 'resolver-test line A') {
    Ok "line_lands_in_configured_dir: the writer created the configured directory and appended"
} else {
    Bad "line_lands_in_configured_dir: nothing in $want\qwt-deaths.log - the line went elsewhere or was lost"
}
if (-not (Test-Path -LiteralPath (Join-Path $pdQubes 'qwt-deaths.log'))) {
    Ok "no_split_record: nothing was written to %ProgramData%\Qubes as well"
} else {
    Bad "no_split_record: the same process wrote to BOTH directories - that is the split record"
}

Write-Output "--- 3. a configured directory that CANNOT be created must not lose the line --------"
# The parent is a FILE, so New-Item cannot create the directory. This is the case where dropping
# the gate without a fallback swallows the death line inside an empty catch.
Reset-Resolver
$blocker = Join-Path $tmpRoot 'blocker'
[IO.File]::WriteAllText($blocker, 'i am a file, not a directory')
$script:StubLogDir = Join-Path $blocker 'Qubes Logs'
Write-QwtDeathLog 'ERROR' 'resolver-test line B'
$pdTxt = Read-Log $pdQubes
if ($pdTxt -match 'resolver-test line B') {
    Ok "unwritable_falls_back: the line was preserved in %ProgramData%\Qubes instead of being dropped"
} else {
    Bad "unwritable_falls_back: 'line B' is in NO log - a death record was SWALLOWED by an empty catch"
}

Write-Output "--- 4. the fallback SAYS SO, in the record the sweep collects ----------------------"
# A stderr-only warning would be invisible: the shipped vehicle is the SYSTEM task QwtDeathReporter,
# whose Exec action has no redirection, so Task Scheduler discards stdout and stderr both.
if ($pdTxt -match '(?i)\[WARN\].*(fell back|falls back|fallback)') {
    Ok "fallback_is_recorded: a WARN line in the log itself names the fallback"
} else {
    Bad "fallback_is_recorded: the record moved with nothing in it saying so (a stderr line is discarded by Task Scheduler)"
}
$warnCount = ([regex]::Matches($pdTxt, '(?i)\[WARN\].*(fell back|falls back|fallback)')).Count
if ($warnCount -eq 1) {
    Ok "fallback_said_once: exactly one marker line, not one per death"
} else {
    Bad "fallback_said_once: $warnCount marker lines in one process"
}

Write-Output "--- 5. a second death in the same process does not repeat the marker ---------------"
Write-QwtDeathLog 'ERROR' 'resolver-test line C'
$pdTxt2 = Read-Log $pdQubes
if ($pdTxt2 -match 'resolver-test line C') {
    Ok "second_line_still_written: the fallback keeps working after the marker"
} else {
    Bad "second_line_still_written: 'line C' is missing"
}
$warnCount2 = ([regex]::Matches($pdTxt2, '(?i)\[WARN\].*(fell back|falls back|fallback)')).Count
if ($warnCount2 -eq 1) {
    Ok "marker_not_repeated: still exactly one marker after a second death"
} else {
    Bad "marker_not_repeated: $warnCount2 markers after two deaths"
}

Write-Output "--- 6. the NORMAL case adds no marker and no noise ---------------------------------"
# The marker must fire on a fallback, never on a healthy guest: a new WARN line in gate input on
# every normal boot would be exactly the noise the owner objected to.
Reset-Resolver
$normal = Join-Path $tmpRoot 'normal-logs'
New-Item -ItemType Directory -Force -Path $normal | Out-Null
$script:StubLogDir = $normal
Write-QwtDeathLog 'ERROR' 'resolver-test line D'
$nTxt = Read-Log $normal
if ($nTxt -match 'resolver-test line D' -and $nTxt -notmatch '(?i)\[WARN\]') {
    Ok "healthy_guest_is_quiet: the death line, and no marker, when the configured directory is usable"
} else {
    Bad "healthy_guest_is_quiet: got '$($nTxt -replace "`r?`n", ' | ')'"
}

Write-Output "--- 7. an unreadable registry value still resolves, and says so --------------------"
Reset-Resolver
$script:StubLogDir = $null                     # the value cannot be read at all
$got = Get-QwtDeathLogDir
if ($got -eq $pdQubes) {
    Ok "unreadable_registry_falls_back: resolved to %ProgramData%\Qubes"
} else {
    Bad "unreadable_registry_falls_back: resolved to '$got'"
}
Write-QwtDeathLog 'ERROR' 'resolver-test line E'
$pdTxt3 = Read-Log $pdQubes
if ($pdTxt3 -match 'resolver-test line E') {
    Ok "unreadable_registry_still_logs: the death line was written"
} else {
    Bad "unreadable_registry_still_logs: 'line E' is missing"
}

Write-Output "--- 8. no recursion: the marker cannot re-enter the writer -------------------------"
# Write-QwtDeathLog -> Get-QwtDeathLogDir -> Write-QwtDeathLog would be infinite. Reaching this
# line at all proves it terminated; the check is that the marker is written directly.
# The first version of this check matched the writer's ordinary AppendAllText, so it passed on the
# UNMODIFIED file and proved nothing. It now requires the MARKER's own append, and that no call to
# Write-QwtDeathLog appears inside the writer's body.
$src = [IO.File]::ReadAllText($ReporterPath)
$body = ''
if ($src -match '(?s)function Write-QwtDeathLog\s*\{(.*?)\n\}') { $body = $Matches[1] }
if (-not $body) {
    Bad "marker_written_directly: could not isolate Write-QwtDeathLog's body"
} elseif ($body -match 'QwtDeathLogDirSaid' -and $body -match '(?s)QwtDeathLogDirSaid.{0,900}?AppendAllText' -and $body -notmatch 'Write-QwtDeathLog') {
    Ok "marker_written_directly: the marker appends directly and the writer never calls itself"
} else {
    Bad "marker_written_directly: the marker path could recurse through Get-QwtDeathLogDir"
}

Write-Output "--- 9. the registry is read ONCE per process --------------------------------------"
$before = $script:StubReads
Write-QwtDeathLog 'ERROR' 'resolver-test line F'
Write-QwtDeathLog 'ERROR' 'resolver-test line G'
if ($script:StubReads -eq $before) {
    Ok "resolver_memoised: no extra registry read per death"
} else {
    Bad "resolver_memoised: $($script:StubReads - $before) further registry read(s) for two lines"
}

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "death-log-resolver-test: $pass checks passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
