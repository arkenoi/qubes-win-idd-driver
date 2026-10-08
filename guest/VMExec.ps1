# QWT-NG replacement for the stock qubes.VMExec handler. Stock behaviour, plus two fixes:
#
#  1. EXIT CODE PROPAGATION. The stock handler ends on `& cmd.exe /c $cmd` and never exits with
#     the child's status, so every qubes.VMExec call returns 0 to dom0 - measured: a command
#     exiting 100 arrived as 0, while the same command over qubes.VMShell correctly returned 100.
#     dom0 tooling decides success from that status (qubesadmin raises CalledProcessError on it),
#     so on Windows every failure currently reads as success. This is a genuine QWT defect and
#     is worth reporting upstream once the QWT-NG work is submitted.
#
#  2. dom0's `qubes-vm-update` sequence. Its commands are POSIX-shaped (`mkdir -p /run/...`,
#     `/usr/bin/python3 .../entrypoint.py`) and cmd.exe cannot run them - `mkdir -p /run/...`
#     fails outright. Commands naming the updater workdir or entrypoint go to vmupdate-shim.ps1;
#     EVERYTHING ELSE is passed to cmd.exe exactly as before, so generic qvm-run is untouched.
. $env:QUBES_TOOLS\qubes-rpc-services\VMExec-Decode.ps1

# 3. NON-ASCII ARGUMENTS. The stock decoder resolves each -HH escape with
#    [System.Text.Encoding]::ASCII.GetString(), and ASCII maps every byte above 0x7F to '?'. dom0's
#    encode_for_vmexec percent-encodes the UTF-8 BYTES of the argument, so a single 'a-umlaut'
#    arrives as two escapes and comes out as '??' - any path, filename or argument containing an
#    umlaut, Cyrillic, Arabic or CJK character is destroyed before cmd.exe ever sees it. A German
#    user with an umlaut in a folder name hits this on an ordinary qvm-run.
#
#    Decoding per-escape cannot be repaired by swapping the encoding either: a UTF-8 character
#    spans several bytes, so the bytes must be ACCUMULATED across escapes and decoded once at the
#    end. That is what this does. Defined AFTER the dot-source so it wins over the stock function,
#    and byte-identical to it for pure-ASCII input (UTF-8 of ASCII is ASCII), which is every
#    command the updater path sends.
function VMExec-DecodeUtf8([string]$part) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $part.Length) {
        if ($part[$i] -eq '-') {
            if ($i + 1 -lt $part.Length -and $part[$i + 1] -eq '-') { $bytes.Add([byte][char]'-'); $i += 2; continue }
            if ($i + 2 -lt $part.Length) {
                $hex = [string]$part[$i + 1] + [string]$part[$i + 2]
                $val = 0
                if ([int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
                    $bytes.Add([byte]$val); $i += 3; continue
                }
            }
            throw (New-Object DecodeError("invalid escape in VMExec argument"))
        }
        # Literal characters are ASCII by construction of the encoding; take their byte directly.
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes([string]$part[$i]))
        $i++
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

try {
    $parts = ($args[0]).split("+")
    $decoded = @($parts.foreach({VMExec-DecodeUtf8 $_}))
} catch [DecodeError] {
    Write-Error $_.Exception.Message
    exit 1
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$cmd = $decoded -join " "

# Audit every VMExec call and the code we hand back. dom0 keeps code = max(all step codes), so a
# single prep step returning nonzero turns a successful update into an ERROR verdict, and dom0's
# output does not say which step it was. This log does.
#
# IT GOES IN THE ONE COMMON LOG LOCATION. It used to write C:\ProgramData\Qubes\vmexec.log,
# outside LogDir, which only the log sweep's stray-path workaround collected - and the owner's rule
# is "NOTHING should write log outside. we have one common log location!". The dot-source guard is
# get-appmenus.ps1's, byte for byte: log.ps1 sits beside this script, and %QUBES_TOOLS% is not
# depended on for finding it.
#
# LogAppendLine, NOT LogInfo: Log gates on `$level -le $qwtLogLevel`, so LogInfo would DROP this
# line on a guest configured below INFO, while the write it replaces was unconditional.
# LogAppendLine bypasses only that filter and keeps the bounded retry and the loud report of a line
# it could not write.
$logPs1 = Join-Path $PSScriptRoot 'log.ps1'
if (-not (Test-Path -LiteralPath $logPs1) -and $env:QUBES_TOOLS) {
    $logPs1 = Join-Path $env:QUBES_TOOLS 'qubes-rpc-services\log.ps1'
}
if (Test-Path -LiteralPath $logPs1) {
    try { . $logPs1 } catch { }
}
function VMExecAudit([string]$what) {
    try {
        $who = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { '?' }
        $line = '[{0}-{1}-I] VMExecAudit: [{2}] {3}' -f (Get-Date -Format 'yyyyMMdd.HHmmss.fff'), $PID, $who, $what
        if (Get-Command LogAppendLine -ErrorAction SilentlyContinue) {
            if (-not $global:qwtLogPath) { LogStart }
            LogAppendLine $line
        } else {
            # log.ps1 is not beside us and %QUBES_TOOLS% is unset: an audit line is not worth
            # failing the qrexec call for, but it must not vanish without trace either.
            [Console]::Error.WriteLine("VMExec: no logger available, audit line not recorded: $line")
        }
    } catch { }
}

$shim = Join-Path $env:QUBES_TOOLS 'qubes-rpc-services\vmupdate-shim.ps1'
if ((Test-Path $shim) -and ($cmd -match '/run/qubes-update|\\run\\qubes-update|entrypoint\.py')) {
    & $shim @decoded
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    VMExecAudit "shim   rc=$rc  cmd: $cmd"
    exit $rc
}

& cmd.exe /c $cmd
$rc = $LASTEXITCODE
if ($null -eq $rc) { $rc = 0 }
VMExecAudit "cmd    rc=$rc  cmd: $cmd"
exit $rc
