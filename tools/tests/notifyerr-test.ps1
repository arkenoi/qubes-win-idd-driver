<#
.SYNOPSIS
    Offline suite for guest/qwt-notify-error.ps1 (the PowerShell twin of the secondary
    error-delivery route). Runs under pwsh on Linux or Windows PowerShell 5.1; no rig, no
    notifhost, no qrexec - the launcher, the gate and the boot stamp are hooks the suite replaces.

.DESCRIPTION
    Exit 0 = every case matched; 1 = at least one FAIL. Each guard is proven to be seen failing
    by tools/tests/notifyerr-selftest.sh, which deletes the helper's `# GUARD:<name>` line into a
    temporary copy and runs this suite against it with -HelperPath; the suite MUST then exit 1.

    What it pins, mirroring agent/gui-agent/notifyerr_test.c so the two languages cannot drift:
      severity  DEGRADED/INFO rejected, ACTION sent
      dedupe    same (component,id) twice in one boot sends once; a marker from an EARLIER boot,
                and a marker WRITTEN BY THE C SIDE ("boot=N\n"), both behave per contract
      cap       the 9th distinct error in one boot is suppressed
      redaction secret-shaped text is refused, pure and end-to-end (no marker, no launch)
      fail-open launcher missing/throwing: the caller gets a status string, never an exception,
                and the failure is logged ONCE for repeated errors; unwritable store -> no send
      gate      off -> 'gated', nothing touched
      text      the notify file is UTF-16LE with BOM, summary names the component, body has id + log
#>
[CmdletBinding()]
param([string]$HelperPath)

$ErrorActionPreference = 'Stop'
if (-not $HelperPath) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
    $HelperPath = Join-Path $repoRoot 'guest/qwt-notify-error.ps1'
}
$HelperPath = (Resolve-Path -LiteralPath $HelperPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}
function CheckStatus([string]$name, [string]$got, [string]$want) {
    $script:run++
    $ok = ($got -eq $want)
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host ("{0} {1,-60} want {2,-22} got {3}" -f $tag, $name, $want, $got)
}

$BOOT = [long]1757400000
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('notifyerr-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$stateDir = Join-Path $tmpRoot 'store'

# --- hooks -----------------------------------------------------------------------------------
$script:logLines = New-Object System.Collections.ArrayList
$script:launched = New-Object System.Collections.ArrayList
$script:QwtNotifyStateDir = $stateDir
$script:QwtNotifyHostExe = Join-Path $tmpRoot 'notifhost.exe'   # absent on purpose until a case creates it
$script:QwtNotifyGate = $true
$script:QwtNotifyBootStamp = $BOOT
$script:QwtNotifyLog = { param($m) [void]$script:logLines.Add($m) }
$script:QwtNotifyLauncher = { param($exe, $file) [void]$script:launched.Add($file) }
$script:QwtNotifyLogged = @{}

. $HelperPath

function Reset-Store {
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $script:logLines.Clear(); $script:launched.Clear(); $script:QwtNotifyLogged.Clear()
    $script:QwtNotifyStateDir = $stateDir
    $script:QwtNotifyGate = $true
}
function LogCount([string]$needle) { return @($script:logLines | Where-Object { $_ -like "*$needle*" }).Count }

# --- 1. pure redaction --------------------------------------------------------------------------
$clean = "Qubes Windows Tools, activate-idd: shutdown refused`r`nError id: reboot-refused. Reported once per boot; the detail is in the guest log: C:\qwt-idd-activate.log"
Check 'redact: templated text with a log path is clean' ($null -eq (Get-QwtNotifyRedactReason $clean))
Check "redact: 'password=' refused" ($null -ne (Get-QwtNotifyRedactReason 'agent failed: password=hunter2'))
Check "redact: 'DefaultPassword' refused" ($null -ne (Get-QwtNotifyRedactReason 'LSA DefaultPassword missing'))
Check "redact: 'Authorization' refused" ($null -ne (Get-QwtNotifyRedactReason 'proxy said Authorization: Basic x'))
Check 'redact: PEM header refused' ($null -ne (Get-QwtNotifyRedactReason '-----BEGIN RSA PRIVATE KEY-----'))
Check 'redact: 40-char base64 run refused' ($null -ne (Get-QwtNotifyRedactReason 'blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5 end'))
Check 'redact: 32 hex digits (a hash) refused' ($null -ne (Get-QwtNotifyRedactReason 'hash 0123456789abcdef0123456789abcdef mismatch'))
Check 'redact: 31 hex digits pass' ($null -eq (Get-QwtNotifyRedactReason 'id 0123456789abcdef0123456789abcde'))
Check 'redact: control character refused' ($null -ne (Get-QwtNotifyRedactReason "bad $([char]1) byte"))
Check 'redact: 7 lines (file-shaped) refused' ($null -ne (Get-QwtNotifyRedactReason "a`nb`nc`nd`ne`nf`ng"))
Check 'redact: > 600 bytes refused' ($null -ne (Get-QwtNotifyRedactReason (('x ' * 320))))
Check 'redact: empty refused' ($null -ne (Get-QwtNotifyRedactReason ''))

# --- 2. names, marker contract, boot match ----------------------------------------------------
Check "name: 'activate-idd' valid" (Test-QwtNotifyName 'activate-idd' 24)
Check 'name: upper-case rejected' (-not (Test-QwtNotifyName 'ActivateIdd' 24))
Check 'name: path chars rejected' (-not (Test-QwtNotifyName '../x' 40))
Check 'name: leading dash rejected' (-not (Test-QwtNotifyName '-x' 40))
Check "marker: parse C-side 'boot=N\n'" ((Get-QwtNotifyKv "boot=1757400000`n" 'boot') -eq 1757400000)
Check 'marker: parse CRLF' ((Get-QwtNotifyKv "boot=1757400000`r`n" 'boot') -eq 1757400000)
Check 'marker: garbage does not parse' ($null -eq (Get-QwtNotifyKv 'hello' 'boot'))
Check 'count: both keys' (((Get-QwtNotifyKv "boot=5`ncount=3`n" 'boot') -eq 5) -and ((Get-QwtNotifyKv "boot=5`ncount=3`n" 'count') -eq 3))
Check 'boot: within tolerance is one boot' (Test-QwtNotifyBootMatch 1000 1120)
Check 'boot: beyond tolerance is another boot' (-not (Test-QwtNotifyBootMatch 1000 1121))

# --- 3. gate off ----------------------------------------------------------------------------------
Reset-Store
$script:QwtNotifyGate = $false
CheckStatus 'gate off: ACTION error is not sent' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Severity ACTION -Summary 'x') 'gated'
Check 'gate off: nothing launched, no marker' (($script:launched.Count -eq 0) -and -not (Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')))

# --- 4. send, dedupe, severity, cap ----------------------------------------------------------
Reset-Store
New-Item -ItemType File -Path $script:QwtNotifyHostExe -Force | Out-Null   # "present" for the launcher hook
CheckStatus 'send: first ACTION report sends' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Summary 'shutdown refused' -LogPath 'C:\qwt-idd-activate.log') 'send'
Check 'send: notifhost launched once with a file' ($script:launched.Count -eq 1)
$bytes = [IO.File]::ReadAllBytes($script:launched[0])
Check 'send: notify file is UTF-16LE with BOM (what notifhost reads)' (($bytes.Length -gt 2) -and ($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE))
$content = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
Check 'send: summary line names the component' ($content.StartsWith("Qubes Windows Tools, activate-idd: shutdown refused`r`n"))
Check 'send: body carries the id and the log pointer' (($content -like '*Error id: reboot-refused.*') -and ($content -like '*C:\qwt-idd-activate.log*'))
Check 'send: marker and count files written' ((Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')) -and (Test-Path (Join-Path $stateDir '.count')))
CheckStatus 'dedupe: the same error again this boot is suppressed' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Summary 'shutdown refused') 'suppressed:duplicate'
Check 'dedupe: no second launch' ($script:launched.Count -eq 1)
CheckStatus 'dedupe: a different id still sends' (Send-QwtError -Component 'activate-idd' -Id 'activation-failed' -Summary 'x') 'send'
CheckStatus 'severity: DEGRADED report is rejected' (Send-QwtError -Component 'activate-idd' -Id 'degraded' -Severity DEGRADED -Summary 'x') 'rejected:severity'
CheckStatus 'severity: INFO report is rejected' (Send-QwtError -Component 'activate-idd' -Id 'info' -Severity INFO -Summary 'x') 'rejected:severity'
Check 'severity: rejected event left no marker and no launch' ((-not (Test-Path (Join-Path $stateDir 'activate-idd.degraded'))) -and ($script:launched.Count -eq 2))
# a marker written by the C side for THIS boot must suppress (cross-language dedupe)
[IO.File]::WriteAllText((Join-Path $stateDir 'gui-agent.deslicedown'), "boot=$($BOOT + 30)`n", [Text.Encoding]::ASCII)
CheckStatus 'dedupe: C-side marker from this boot suppresses' (Send-QwtError -Component 'gui-agent' -Id 'deslicedown' -Summary 'x') 'suppressed:duplicate'
[IO.File]::WriteAllText((Join-Path $stateDir 'gui-agent.oldboot'), "boot=$($BOOT - 5000)`n", [Text.Encoding]::ASCII)
CheckStatus 'dedupe: marker from an earlier boot does not suppress' (Send-QwtError -Component 'gui-agent' -Id 'oldboot' -Summary 'x') 'send'
# cap: 3 sends so far; distinct ids up to 8
$last = 'send'
for ($i = 3; $i -lt 8; $i++) { $last = Send-QwtError -Component 'gui-agent' -Id "cap-$i" -Summary 'x' }
CheckStatus 'cap: the 8th distinct error still sends' $last 'send'
CheckStatus 'cap: the 9th distinct error is suppressed' (Send-QwtError -Component 'gui-agent' -Id 'cap-9' -Summary 'x') 'suppressed:cap'
Check 'cap: exactly 8 launches this boot' ($script:launched.Count -eq 8)
Check 'cap: suppression was logged' ((LogCount 'suppressed:cap') -eq 1)

# --- 5. redaction end-to-end -------------------------------------------------------------------
Reset-Store
CheckStatus 'redact e2e: summary with a password is refused' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Summary 'shutdown refused, password=abc') 'rejected:redact'
Check 'redact e2e: refused text launched nothing and left no marker' (($script:launched.Count -eq 0) -and -not (Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')))
Check 'redact e2e: refusal logged' ((LogCount 'rejected:redact') -eq 1)

# --- 6. fail-open ------------------------------------------------------------------------------
Reset-Store
Remove-Item -LiteralPath $script:QwtNotifyHostExe -Force   # exe missing
$threw = $false
try { $s = Send-QwtError -Component 'gui-agent' -Id 'a' -Summary 'x' } catch { $threw = $true; $s = 'THREW' }
CheckStatus 'fail-open: exe missing -> status, not an exception' $s 'failed:transport'
Check 'fail-open: no exception reached the caller' (-not $threw)
[void](Send-QwtError -Component 'gui-agent' -Id 'b' -Summary 'x')
[void](Send-QwtError -Component 'gui-agent' -Id 'c' -Summary 'x')
Check 'fail-open: three failures, the missing exe logged ONCE' ((LogCount 'NOT PRESENT') -eq 1)
New-Item -ItemType File -Path $script:QwtNotifyHostExe -Force | Out-Null   # exe present, launch fails
$script:QwtNotifyLauncher = { param($exe, $file) throw 'Start-Process failed' }
[void](Send-QwtError -Component 'gui-agent' -Id 'd' -Summary 'x')
[void](Send-QwtError -Component 'gui-agent' -Id 'e' -Summary 'x')
Check 'fail-open: launcher throwing logged ONCE' ((LogCount 'Start-Process failed') -eq 1)
Check 'fail-open: caller reached this line' $true
# unwritable store: a FILE where the directory must be
Reset-Store
$badDir = Join-Path $tmpRoot 'not-a-dir'
[IO.File]::WriteAllText($badDir, 'x', [Text.Encoding]::ASCII)
$script:QwtNotifyStateDir = $badDir
$script:QwtNotifyLauncher = { param($exe, $file) [void]$script:launched.Add($file) }
CheckStatus 'fail-open: unwritable store -> no send' (Send-QwtError -Component 'gui-agent' -Id 'f' -Summary 'x') 'failed:transport'
[void](Send-QwtError -Component 'gui-agent' -Id 'g' -Summary 'x')
Check 'fail-open: unwritable store launched nothing' ($script:launched.Count -eq 0)
Check 'fail-open: unwritable store logged ONCE' ((LogCount 'not writable') -eq 1)

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
