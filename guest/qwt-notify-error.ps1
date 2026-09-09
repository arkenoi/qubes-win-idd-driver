# qwt-notify-error.ps1 - PowerShell twin of the SECONDARY error-delivery route
# (agent/gui-agent/notifyerr.h is the C policy core; docs/DESIGN-error-notify.md is the design).
#
# Dot-source it, then:   Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' `
#                            -Summary 'shutdown.exe refused the reboot; reboot this qube by hand' `
#                            -LogPath 'C:\qwt-idd-activate.log'
#
# It reports a guest error to dom0 as a notification IN ADDITION TO the caller's own log line -
# never instead of it. The caller logs first, exactly as before, then calls this. The transport
# is the toast bridge's proven one-shot: `notifhost.exe --notify-file <file>` over
# qubes.Notifications, started and NOT waited for.
#
# HONEST LIMIT (owner, 2026-09-09): that transport is qrexec - notifhost hands the relay to the
# LOCAL qrexec-agent service, which owns the vchan. So this delivers only while qrexec-agent is
# up. When qrexec is down - the case that prompted this work, a guest whose PV bus never bound so
# xeniface, qubesdb and qrexec were all absent together - it delivers NOTHING and the log on disk
# is the only record, reachable only once some channel to the guest exists again. This is a
# channel for "qrexec is up and nobody is reading logs", not for "everything else failed".
#
# CONTRACT (identical to the C side; the two languages share the marker files and therefore
# de-duplicate against each other):
#   gate       registry HKLM\...\Qubes Tools\gui-agent : NotifyErrors (DWORD), then qubesdb
#              /qubes-service/notify-errors - dom0 wins. Default OFF. A sibling of NotifyBridge,
#              not the same gate: that one forwards the guest's APP toasts and suppresses their
#              banners; an operator who wants error reports must not have to accept that, and
#              service.legacy-toasts (which forces the bridge off) must not silence errors.
#   severity   ACTION only (the product is not delivering and will not recover by itself; a human
#              must act). DEGRADED / INFO stay in the log.
#   dedupe     one notification per (component, id) per BOOT: marker <state>\<component>.<id>
#              holding "boot=<uptime-derived boot epoch seconds>"; a marker from an earlier boot
#              does not suppress. Cap: at most 8 per boot across all ids (<state>\.count).
#   redaction  the payload is REFUSED (not masked) if it is longer than 600 bytes, more than 6
#              lines, has a control character, a credential keyword, a base64-class run >= 40 or
#              a hex run >= 32. Pass templated text: component, id, one sentence, the log path.
#   fail-open  never throws, never waits, never changes the caller's state. Returns a status
#              string ('send', 'rejected:severity', 'rejected:name', 'rejected:redact',
#              'suppressed:duplicate', 'suppressed:cap', 'failed:transport', 'gated'). Transport
#              failures are logged ONCE per process. An unwritable marker store means NO SEND
#              (missing data fails: without persistence a relaunched helper would repeat).
#
# Windows PowerShell 5.1 (no ternary, no ??, no && chains). The test at
# tools/tests/notifyerr-test.ps1 runs this file under pwsh on Linux with the hooks below
# replaced; lines tagged `# GUARD:<name>` are each deleted by tools/tests/notifyerr-selftest.sh to
# prove the test sees that guard fail. Keep each guard on ONE line for that reason.

# --- hooks (script scope; a test or a caller may override after dot-sourcing) ------------------
if (-not $script:QwtNotifyStateDir) {
    if ($env:ProgramData) { $script:QwtNotifyStateDir = Join-Path $env:ProgramData 'Qubes\notify-errors' }
    else { $script:QwtNotifyStateDir = '/tmp/qwt-notify-errors' }
}
if (-not $script:QwtNotifyHostExe) { $script:QwtNotifyHostExe = 'C:\Program Files\Qubes Tools\bin\notifhost.exe' }
if ($null -eq $script:QwtNotifyGate) { $script:QwtNotifyGate = $null }        # $null = resolve from registry/qubesdb
if ($null -eq $script:QwtNotifyBootStamp) { $script:QwtNotifyBootStamp = $null }
if (-not $script:QwtNotifyLog) { $script:QwtNotifyLog = { param($m) Write-Host "NOTIFYERR $m" } }
if (-not $script:QwtNotifyLauncher) {
    $script:QwtNotifyLauncher = {
        param($exe, $file)
        Start-Process -FilePath $exe -ArgumentList ('--notify-file "' + $file + '"') -WindowStyle Hidden | Out-Null
    }
}
if (-not $script:QwtNotifyLogged) { $script:QwtNotifyLogged = @{} }

# --- constants (mirror notifyerr.h) ------------------------------------------------------------
$script:QwtNotifyMaxText = 600
$script:QwtNotifyMaxLines = 6
$script:QwtNotifyCapPerBoot = 8
$script:QwtNotifyBootToleranceS = 120

# --- qubesdb read (inline mirror of guest/qubesdb-read.ps1 Get-QubesDbValue: this file must be
#     self-contained on the deployed medium, like the installer and the updater) ----------------
function Get-QwtNotifyQubesDbValue {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not ('QwtQdbNotify' -as [type])) {
            Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QwtQdbNotify {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
        }
        $h = [QwtQdbNotify]::qdb_open([IntPtr]::Zero)
        if ($h -eq [IntPtr]::Zero) { return $null }
        try {
            $len = [uint32]0
            $p = [QwtQdbNotify]::qdb_read($h, $Path, [ref]$len)
            if ($p -eq [IntPtr]::Zero) { return $null }
            return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
        } finally { [QwtQdbNotify]::qdb_close($h) }
    } catch { return $null }
}

# Gate, resolved once per process: registry base, qubesdb override (dom0 wins). Absent = OFF.
function Get-QwtNotifyErrorsGate {
    if ($null -ne $script:QwtNotifyGate) { return [bool]$script:QwtNotifyGate }
    $on = $false
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent' -Name 'NotifyErrors' -ErrorAction SilentlyContinue).NotifyErrors
        if ($null -ne $v) { $on = ([int]$v -ne 0) }
    } catch { }
    $q = Get-QwtNotifyQubesDbValue '/qubes-service/notify-errors'
    if ($null -ne $q) { $on = ("$q".Trim() -ne '0') }
    $script:QwtNotifyGate = $on
    return $on
}

# --- pure policy pieces (each mirrors a notifyerr.h function) ---------------------------------
function Test-QwtNotifyName {
    param([string]$Name, [int]$MaxLen)
    if (-not $Name) { return $false }
    if ($Name.Length -gt $MaxLen) { return $false }
    return [bool]($Name -cmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
}

# $null = clean, else the reason. REFUSE, never mask.
function Get-QwtNotifyRedactReason {
    param([string]$Text)
    if (-not $Text) { return 'empty' }
    $bytes = [Text.Encoding]::UTF8.GetByteCount($Text)
    if ($bytes -gt $script:QwtNotifyMaxText) { return 'too long (file-content-shaped)' }
    if ($Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return 'control character' }
    $lines = ($Text -split "`n").Count
    if ($lines -gt $script:QwtNotifyMaxLines) { return 'too many lines (file-content-shaped)' }
    if ($Text -match '[A-Za-z0-9+/=]{40,}') { return 'long opaque run (key/blob-shaped)' }
    if ($Text -match '[0-9A-Fa-f]{32,}') { return 'hex run (digest/key-shaped)' }
    if ($Text -imatch '(password|passwd|pwd=|secret|token|apikey|api_key|api-key|authorization|bearer |-----begin|private key|credential)') { return 'credential keyword' }
    return $null
}

function Get-QwtNotifyBootStamp {
    if ($null -ne $script:QwtNotifyBootStamp) { return [long]$script:QwtNotifyBootStamp }
    $up = [math]::Floor([Diagnostics.Stopwatch]::GetTimestamp() / [Diagnostics.Stopwatch]::Frequency)
    $nowS = [long][math]::Floor(([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds)
    return [long]($nowS - $up)
}

function Test-QwtNotifyBootMatch {
    param([long]$A, [long]$B)
    return ([math]::Abs($A - $B) -le $script:QwtNotifyBootToleranceS)
}

# "key=value" lines; returns $null when the key is absent or not an integer.
function Get-QwtNotifyKv {
    param([string]$Text, [string]$Key)
    if (-not $Text) { return $null }
    foreach ($line in ($Text -split "`n")) {
        $l = $line.Trim()
        if ($l -cmatch ('^' + [regex]::Escape($Key) + '=(-?[0-9]+)')) { return [long]$Matches[1] }
    }
    return $null
}

function Read-QwtNotifySmall {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        return [IO.File]::ReadAllText($Path)
    } catch { return $null }
}

function Write-QwtNotifyOnce {
    param([string]$Kind, [string]$Message)
    if ($script:QwtNotifyLogged[$Kind]) { return }   # GUARD:failopen
    $script:QwtNotifyLogged[$Kind] = $true
    try { & $script:QwtNotifyLog $Message } catch { }
}

# --- the entry point ------------------------------------------------------------------------
function Send-QwtError {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('INFO', 'DEGRADED', 'ACTION')][string]$Severity = 'ACTION',
        [Parameter(Mandatory)][string]$Summary,
        [string]$LogPath = ''
    )
    try {
        if (-not (Get-QwtNotifyErrorsGate)) { return 'gated' }
        $sevNum = 0
        if ($Severity -eq 'DEGRADED') { $sevNum = 1 }
        if ($Severity -eq 'ACTION') { $sevNum = 2 }
        if ($sevNum -lt 2) { return 'rejected:severity' }   # GUARD:severity
        if (-not (Test-QwtNotifyName $Component 24) -or -not (Test-QwtNotifyName $Id 40)) {
            & $script:QwtNotifyLog "$Component.$Id not sent: rejected:name"
            return 'rejected:name'
        }
        $hint = $LogPath
        if (-not $hint) { $hint = 'see the gui-agent log directory' }
        $text = "Qubes Windows Tools, ${Component}: $Summary`r`nError id: $Id. Reported once per boot; the detail is in the guest log: $hint"
        $reason = Get-QwtNotifyRedactReason $text
        if ($reason) { & $script:QwtNotifyLog "$Component.$Id not sent: rejected:redact ($reason)"; return 'rejected:redact' }   # GUARD:redact

        $now = Get-QwtNotifyBootStamp
        $markerPath = Join-Path $script:QwtNotifyStateDir "$Component.$Id"
        $countPath = Join-Path $script:QwtNotifyStateDir '.count'
        $markerBoot = Get-QwtNotifyKv (Read-QwtNotifySmall $markerPath) 'boot'
        if ($null -ne $markerBoot -and (Test-QwtNotifyBootMatch $markerBoot $now)) { & $script:QwtNotifyLog "$Component.$Id not sent: suppressed:duplicate"; return 'suppressed:duplicate' }   # GUARD:ratelimit
        $countText = Read-QwtNotifySmall $countPath
        $countBoot = Get-QwtNotifyKv $countText 'boot'
        $count = Get-QwtNotifyKv $countText 'count'
        $have = 0
        if ($null -ne $countBoot -and $null -ne $count -and (Test-QwtNotifyBootMatch $countBoot $now)) { $have = [int]$count }
        if ($have -ge $script:QwtNotifyCapPerBoot) { & $script:QwtNotifyLog "$Component.$Id not sent: suppressed:cap"; return 'suppressed:cap' }   # GUARD:cap

        # Persist the once-per-boot record BEFORE the transport. If this cannot be written there
        # is no dedupe, and then there is no send (missing data fails).
        try {
            if (-not (Test-Path -LiteralPath $script:QwtNotifyStateDir)) { New-Item -ItemType Directory -Path $script:QwtNotifyStateDir -Force -ErrorAction Stop | Out-Null }
            [IO.File]::WriteAllText($markerPath, "boot=$now`n", [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText($countPath, "boot=$now`ncount=$($have + 1)`n", [Text.Encoding]::ASCII)
        } catch {
            Write-QwtNotifyOnce 'store' "state dir $($script:QwtNotifyStateDir) is not writable - the route is OFF for this process (a notification with no once-per-boot record would repeat)"
            return 'failed:transport'
        }

        $file = Join-Path $script:QwtNotifyStateDir ("out-$Component-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            [IO.File]::WriteAllText($file, $text, [Text.Encoding]::Unicode)   # UTF-16LE + BOM, what notifhost reads
        } catch {
            Write-QwtNotifyOnce 'store' "cannot write $file - notification not sent"
            return 'failed:transport'
        }
        # Two distinct failure kinds, each logged once: a missing exe is a PACKAGING GAP in the
        # reporting path itself; a launch that fails with the exe present is a runtime fault.
        if (-not (Test-Path -LiteralPath $script:QwtNotifyHostExe)) {
            Write-QwtNotifyOnce 'noexe' "notifhost.exe is NOT PRESENT at $($script:QwtNotifyHostExe) - dom0 notifications cannot be sent (packaging gap in the reporting path; the log remains the record)"
            return 'failed:transport'
        }
        try {
            & $script:QwtNotifyLauncher $script:QwtNotifyHostExe $file
        } catch {
            Write-QwtNotifyOnce 'spawn' "notifhost --notify-file could not be started ($($_.Exception.Message)) - notification not sent; the log remains the record"
            return 'failed:transport'
        }
        & $script:QwtNotifyLog "$Component.$Id sent to dom0 (#$($have + 1) this boot; delivery is notifhost's to log)"
        return 'send'
    } catch {
        # Nothing in this function may reach the caller as an error.
        Write-QwtNotifyOnce 'internal' "internal failure ($($_.Exception.Message)) - notification not sent"
        return 'failed:transport'
    }
}
