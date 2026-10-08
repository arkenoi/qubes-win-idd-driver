<#
.SYNOPSIS
    core-agent/src/qubes-rpc-services/log.ps1 - the sink EVERY PowerShell qrexec service logs through.

.DESCRIPTION
    Goal, owner 2026-10-08: "jev confirms that all errors are RCAd and fixed, no actual errors are
    lost or silenced, no error noise during the normal boot".

    This file is the sink, so a defect here silences emitters that are all perfectly correct. Three
    were found by measurement, not by reading:

    1. AN UNREADABLE LogLevel SILENCES EVERYTHING, INCLUDING ERRORS. LogStart reads it with
       Get-ItemPropertyValue and NO -ErrorAction, so under the default $ErrorActionPreference =
       'Continue' a failure is non-terminating and $qwtLogLevel is left unset. Log then gates on
       `$level -le $qwtLogLevel`, and measured on pwsh: `1 -le $null` is False. So LogError returns
       without writing, and so does every other level - no line, no stderr, nothing. Every
       PowerShell rpc service on that guest goes dark and the sweep reads it as a clean guest.

    2. AN UNREADABLE LogDir WRITES TO THE ROOT OF THE CURRENT DRIVE. Same missing -ErrorAction:
       $logDir becomes $null and "$logDir\$logName" is "\VMExec.ps1-20261008.log" - a brand-new
       stray log outside the one common location, which is what the owner banned, and which no
       collector looks at.

    3. THE PREFIX DOES NOT PARSE IN THE GATE. Log emits "[yyyyMMdd.HHmmss.fff-L] msg", while
       tools/log-sweep.py's WINUTILS_RE wants a PID field between the timestamp and the level. So
       every one of these logs falls to the 'plain' family, where parse_plain appends each line with
       ts=None: the lines cannot be joined to a boot and a --since window cannot place them. An
       ERROR with no timestamp is an error the gate cannot attribute.

    Run: pwsh -File tools/tests/ps-log-sink-test.ps1
    The two registry reads are stubbed (a function outranks a cmdlet), so each failure mode is
    driven directly instead of being argued about.
#>
param(
    [string]$LogPs1 = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'core-agent/src/qubes-rpc-services/log.ps1')
)
$ErrorActionPreference = 'Continue'      # AS SHIPPED: the guest runs these under the default
if (-not (Test-Path -LiteralPath $LogPs1)) { Write-Output "FAIL log.ps1 not found at $LogPs1"; exit 2 }

$pass = 0; $fail = 0
function Ok([string]$m) { $script:pass++; Write-Output "PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Output "FAIL  $m" }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("qwtlog-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$logDir = Join-Path $tmpRoot 'Qubes Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# THE STUB. $script:StubLogDir / $script:StubLogLevel are what the registry holds; 'THROW' means the
# read fails the way it does on a guest where the value or the key is absent.
$script:StubLogDir = $logDir
$script:StubLogLevel = 3
function Get-ItemPropertyValue {
    # NO explicit $ErrorAction parameter: that is a COMMON parameter name and declaring it makes
    # every call fail with "A parameter with the name 'ErrorAction' was defined multiple times" -
    # which my first version of this stub did, and then reported the real code as broken. Extra
    # arguments are swallowed instead, so the stub accepts whatever the sink passes.
    param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$Name,
          [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $v = if ($Name -eq 'LogDir') { $script:StubLogDir } elseif ($Name -eq 'LogLevel') { $script:StubLogLevel } else { $null }
    if ($v -eq 'THROW') { Write-Error "Property $Name does not exist at path $Path." ; return }
    return $v
}

. $LogPs1

function Reset-Sink {
    $global:qwtLogPath = $null
    $global:qwtLogLevel = $null
    Get-ChildItem -LiteralPath $logDir -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse
}
function Sink-Text {
    # Get-Content, NOT [IO.File]::ReadAllText: the sink builds "$logDir\$name" with a BACKSLASH,
    # which the PowerShell provider normalises on Linux and the .NET API does not - so ReadAllText
    # looked for a file literally named "Qubes Logs\x.log", threw, and reported three checks as
    # failures of log.ps1 when the instrument was what was broken. The guest is Windows; this is a
    # property of the test host only.
    if (-not $global:qwtLogPath) { return '' }
    if (-not (Test-Path -LiteralPath $global:qwtLogPath)) { return '' }
    return (Get-Content -LiteralPath $global:qwtLogPath -Raw -ErrorAction SilentlyContinue)
}

Write-Output "--- 1. an unreadable LogLevel must NOT silence an error ----------------------------"
Reset-Sink
$script:StubLogDir = $logDir
$script:StubLogLevel = 'THROW'
$err = $null
try { LogError 'sink-test an error while LogLevel is unreadable' } catch { $err = $_ }
$txt = Sink-Text
if ($txt -match 'sink-test an error while LogLevel is unreadable') {
    Ok "unreadable_level_still_logs_errors: the ERROR was written anyway"
} else {
    Bad "unreadable_level_still_logs_errors: the error was DROPPED - 1 -le `$null is False, so every level is silenced (path=$global:qwtLogPath err=$err)"
}

Write-Output "--- 2. an unreadable LogDir must not write to the root of the drive ----------------"
Reset-Sink
$script:StubLogDir = 'THROW'
$script:StubLogLevel = 3
try { LogError 'sink-test an error while LogDir is unreadable' } catch { }
# THE CRITERION IS THE PARENT DIRECTORY, not a regex on the string: the defect produced
# "\name.log", whose parent is the bare root (the root of the CURRENT DRIVE on Windows, empty
# here). A correct fallback names a real directory. My first version of this check tested
# `-notmatch '^[\/][^\/]'`, which is a Windows-shaped rule that then failed the correct Linux
# fallback /tmp/name.log.
$parent = if ($global:qwtLogPath) { Split-Path $global:qwtLogPath -Parent } else { '' }
if ($parent -and $parent -ne '/' -and $parent -ne '\\' -and [IO.Path]::IsPathRooted($global:qwtLogPath)) {
    Ok "unreadable_logdir_is_rooted: resolved into a real directory ($parent)"
} else {
    Bad "unreadable_logdir_is_rooted: path is '$global:qwtLogPath', parent '$parent' - that is the root of the current drive, outside the one common location"
}

Write-Output "--- 3. and it SAYS the location is not the configured one --------------------------"
# Silence here is the same defect as a quiet fallback anywhere else in this product: the operator
# must be able to find the log that exists rather than the one that was meant to.
# BEHAVIOURAL, not a source grep: the fallback must leave a WARN line in the log that exists.
# A grep for the stderr call passed on code that never reached it.
$fbTxt = Sink-Text
if ($fbTxt -match '(?i)^\[\d{8}\.\d{6}\.\d{3}-\d+-W\].*LogDir') {
    Ok "unreadable_logdir_is_loud: the log itself carries a WARN line naming the unreadable LogDir"
} else {
    Bad "unreadable_logdir_is_loud: the sink moved with nothing in the log saying so (got '$($fbTxt -replace "`r?`n", ' | ')')"
}
$src = [IO.File]::ReadAllText($LogPs1)

Write-Output "--- 4. the prefix must parse in the gate (WINUTILS_RE) ----------------------------"
Reset-Sink
$script:StubLogDir = $logDir
$script:StubLogLevel = 3
LogError 'sink-test prefix check'
# PARENTHESES REQUIRED: `Sink-Text -split "..."` binds -split as an argument to the function
# instead of applying the operator to its output.
$line = @((Sink-Text) -split "`r?`n" | Where-Object { $_ -match 'sink-test prefix check' })[0]
# The gate's regex, verbatim from tools/log-sweep.py:137
$winutils = '^\[(\d{8})\.(\d{6})\.(\d{3})-(\d+)(?::(\d+))?-([IWEDV])\] (.*)$'
if ($line -match $winutils) {
    Ok "prefix_parses_in_gate: '$($line.Substring(0, [Math]::Min(34, $line.Length)))...' matches WINUTILS_RE, so the line keeps its timestamp"
} else {
    Bad "prefix_parses_in_gate: '$line' does not match WINUTILS_RE - the file falls to family 'plain' and every line is parsed with ts=None"
}

Write-Output "--- 5. ONE FILE PER SCRIPT PER DAY: no pid in the NAME ----------------------------"
# The pid belongs in the PREFIX, never the filename: a per-pid name turned a few hundred qrexec
# calls into a few hundred files and starved the sweep's file budget.
if ($global:qwtLogPath -match '-\d{8}\.log$') {
    Ok "one_file_per_day: the name carries the date and no pid ($(Split-Path $global:qwtLogPath -Leaf))"
} else {
    Bad "one_file_per_day: name is '$(Split-Path $global:qwtLogPath -Leaf)'"
}

Write-Output "--- 6. the level filter still works when LogLevel IS readable ---------------------"
Reset-Sink
$script:StubLogLevel = 3
LogDebug 'sink-test a debug line at level 3'
LogInfo  'sink-test an info line at level 3'
$txt = Sink-Text
if ($txt -notmatch 'a debug line' -and $txt -match 'an info line') {
    Ok "level_filter_intact: DEBUG dropped at level 3, INFO kept - the noise policy still holds"
} else {
    Bad "level_filter_intact: got '$($txt -replace "`r?`n", ' | ')'"
}

Write-Output "--- 7. a level ABOVE the configured one is still dropped, errors are not --------"
Reset-Sink
$script:StubLogLevel = 1                      # errors only
LogInfo  'sink-test info at level 1'
LogError 'sink-test error at level 1'
$txt = Sink-Text
if ($txt -notmatch 'info at level 1' -and $txt -match 'error at level 1') {
    Ok "errors_always_kept: at LogLevel 1 the error is written and the info line is not"
} else {
    Bad "errors_always_kept: got '$($txt -replace "`r?`n", ' | ')'"
}

Write-Output "--- 8. a line that cannot be written is never silent ------------------------------"
if ($src -match 'line LOST') {
    Ok "lost_line_is_loud: LogAppendLine reports a line it could not write"
} else {
    Bad "lost_line_is_loud: a dropped line would be silent"
}

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "ps-log-sink-test: $pass checks passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
