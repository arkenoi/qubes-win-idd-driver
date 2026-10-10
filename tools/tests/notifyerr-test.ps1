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
      gate      off -> 'gated': nothing to dom0, THE ERROR WINDOW instead (owner 2026-10-07), under the dedupe and the cap
      window    dom0 not told (failed:transport, gated) -> the window; never on send / duplicate / cap / rejection; no storm
      text      the notify file is UTF-16LE with BOM; line 1 is the header alone, the body is line 1, the
                cause and the technical line (rz39 shape: Format-QwtNotifyText, Format-QwtNotifyTechLine)
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
$script:QwtNotifyBuild = '4.3.36.915'   # the installed build the technical line names; pinned (the resolver reads a guest's gui-agent.exe)
# the error window: every box the route shows is recorded (header + text), as WTSSendMessage would get them
$script:boxes = New-Object System.Collections.ArrayList
$script:QwtNotifyBoxShower = { param($h, $t) [void]$script:boxes.Add(@{ header = $h; text = $t }); return $true }

. $HelperPath

function Reset-Store {
    if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $script:logLines.Clear(); $script:launched.Clear(); $script:QwtNotifyLogged.Clear(); $script:boxes.Clear()
    $script:QwtNotifyStateDir = $stateDir
    $script:QwtNotifyGate = $true
    $script:QwtNotifyBoxWithoutRecord = $false
    $script:QwtNotifyBoxShower = { param($h, $t) [void]$script:boxes.Add(@{ header = $h; text = $t }); return $true }
}
function LogCount([string]$needle) { return @($script:logLines | Where-Object { $_ -like "*$needle*" }).Count }

# --- 1. pure redaction --------------------------------------------------------------------------
$clean = "The display driver needs a reboot that was refused`r`nThe new display driver is not primary until this qube is restarted by hand from dom0.`r`nCause: Windows refused the reboot request; the log has shutdown.exe's code.`r`nactivate-idd.ps1; reported once per boot; build 4.3.36.915. Evidence: C:\qwt-idd-activate.log."
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
Check 'boot: the same token is one boot' (Test-QwtNotifyBootMatch 1000 1000)
# The 4.3.22 defect: a +/-120 s tolerance made two boots 73 s apart one boot, so the second boot's
# ACTION error was swallowed. Consecutive boot stamps are (previous uptime + downtime) apart, so
# that is the ordinary chained-update reboot. Measured on win11-ne 2026-09-09. These FAIL the
# moment any margin comes back.
Check 'boot: a token 73 s away is ANOTHER boot (close reboot, the 4.3.22 defect)' (-not (Test-QwtNotifyBootMatch 1000 1073))
Check 'boot: a token 1 s away is ANOTHER boot' (-not (Test-QwtNotifyBootMatch 1000 1001))

# --- 3. gate off: nothing to dom0, THE ERROR WINDOW instead (owner 2026-10-07; Jev gated=window 0.76) --------
Reset-Store
$script:QwtNotifyGate = $false
CheckStatus 'gate off: ACTION error is not sent to dom0 (gated)' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Severity ACTION -Header 'The display driver needs a reboot that was refused' -Next 'y' -Tech 'z') 'gated'
Check 'gate off: nothing launched' ($script:launched.Count -eq 0)
Check 'gate off: the error window is shown once, with the header and the whole text' ($script:boxes.Count -eq 1 -and $script:boxes[0].header -eq 'The display driver needs a reboot that was refused' -and $script:boxes[0].text -eq "The display driver needs a reboot that was refused`r`ny`r`nz")
Check 'gate off: the per-boot record is written (the window shares the dedupe)' ((Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')) -and (Test-Path (Join-Path $stateDir '.count')))
Check 'gate off: the window is logged (QGAERRBOX)' ((LogCount 'QGAERRBOX activate-idd.reboot-refused shown') -eq 1)
CheckStatus 'gate off: the same error again this boot is a duplicate' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Header 'x' -Next 'y' -Tech 'z') 'suppressed:duplicate'
Check 'gate off: a duplicate shows NO second window (no storm)' ($script:boxes.Count -eq 1)
CheckStatus 'gate off: a DEGRADED report is rejected by severity, not shown' (Send-QwtError -Component 'activate-idd' -Id 'degraded' -Severity DEGRADED -Header 'x' -Next 'y' -Tech 'z') 'rejected:severity'
CheckStatus 'gate off: secret-shaped text is refused, not shown' (Send-QwtError -Component 'activate-idd' -Id 'secret' -Header 'password=abc' -Next 'y' -Tech 'z') 'rejected:redact'
Check 'gate off: rejections show no window' ($script:boxes.Count -eq 1)
$last = 'gated'
for ($i = 2; $i -le 8; $i++) { $last = Send-QwtError -Component 'gui-agent' -Id "gated-$i" -Header 'x' -Next 'y' -Tech 'z' }
CheckStatus 'gate off: the 8th distinct gated error is still shown' $last 'gated'
Check 'gate off: eight windows this boot' ($script:boxes.Count -eq 8)
CheckStatus 'gate off: the 9th distinct gated error is capped' (Send-QwtError -Component 'gui-agent' -Id 'gated-9' -Header 'x' -Next 'y' -Tech 'z') 'suppressed:cap'
Check 'gate off: the cap holds for windows too (still eight)' ($script:boxes.Count -eq 8)

# --- 4. send, dedupe, severity, cap ----------------------------------------------------------
Reset-Store
New-Item -ItemType File -Path $script:QwtNotifyHostExe -Force | Out-Null   # "present" for the launcher hook
CheckStatus 'send: first ACTION report sends' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Header 'The display driver needs a reboot that was refused' -Next 'The new display driver is not primary until this qube is rebooted by hand.' -Cause 'Cause: Windows refused the reboot request.' -Tech (Format-QwtNotifyTechLine -Subject 'activate-idd.ps1' -Count 'reported once per boot' -Evidence 'C:\qwt-idd-activate.log')) 'send'
Check 'send: notifhost launched once with a file' ($script:launched.Count -eq 1)
Check 'send: dom0 was told, so NO window' ($script:boxes.Count -eq 0)
$bytes = [IO.File]::ReadAllBytes($script:launched[0])
Check 'send: notify file is UTF-16LE with BOM (what notifhost reads)' (($bytes.Length -gt 2) -and ($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE))
$content = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
Check 'send: line 1 is the header, alone' ($content.StartsWith("The display driver needs a reboot that was refused`r`n"))
Check 'send: the body is line 1, the cause and the technical line, CRLF-separated' ($content -eq "The display driver needs a reboot that was refused`r`nThe new display driver is not primary until this qube is rebooted by hand.`r`nCause: Windows refused the reboot request.`r`nactivate-idd.ps1; reported once per boot; build 4.3.36.915. Evidence: C:\qwt-idd-activate.log.")
Check 'text: Format-QwtNotifyText with no cause is three lines' ((Format-QwtNotifyText -Header 'H' -Next 'N' -Tech 'T') -eq "H`r`nN`r`nT")
Check 'text: a CR/LF inside a part is folded to a space (it cannot move text into another line)' ((Format-QwtNotifyText -Header "H`r`nx" -Next "N`ny" -Cause "C`rz" -Tech 'T') -eq "H x`r`nN y`r`nC z`r`nT")
Check 'tech: every part, in order - the build after the count, before the one pointer' ((Format-QwtNotifyTechLine -Subject 'gui-agent.exe' -ProcessId 6100 -Code 'exception 0xC0000409' -Ran '0:12:34' -Count 'death 1 this boot' -Evidence 'C:\ProgramData\Qubes\qwt-deaths.log') -eq 'gui-agent.exe pid 6100; exception 0xC0000409; ran 0:12:34; death 1 this boot; build 4.3.36.915. Evidence: C:\ProgramData\Qubes\qwt-deaths.log.')
Check 'tech: no pid, no code, no run time -> subject, count, build and evidence only' ((Format-QwtNotifyTechLine -Subject 'activate-idd.ps1' -Count 'reported once per boot' -Evidence 'C:\x.log') -eq 'activate-idd.ps1; reported once per boot; build 4.3.36.915. Evidence: C:\x.log.')
# THE BUILD (owner 2026-10-10: "i see win11-acc error on screen, but since dom0 toasts do not have timestamps, i cannot figure
# out if it is a botched fix or control reproduction run"): every technical line names it; when none could be read the line
# SAYS so - "build unknown" - rather than printing an empty field, because a notice nobody can date is when the build matters.
Check 'tech: the line names the build that produced it' ((Format-QwtNotifyTechLine -Subject 'x.ps1' -Count 'reported once per boot' -Evidence 'C:\x.log') -like '*; reported once per boot; build 4.3.36.915. Evidence: C:\x.log.')
$script:QwtNotifyBuild = ''
Check 'tech: no build known -> "build unknown", never an empty field' ((Format-QwtNotifyTechLine -Subject 'x.ps1' -Count 'reported once per boot' -Evidence 'C:\x.log') -eq 'x.ps1; reported once per boot; build unknown. Evidence: C:\x.log.')
# the resolver itself, on a host with no registry and no gui-agent.exe next to the (fake) notifhost: '' and no exception
$script:QwtNotifyBuild = $null
$threw = $false
try { $line = Format-QwtNotifyTechLine -Subject 'x.ps1' -Count 'reported once per boot' -Evidence 'C:\x.log' } catch { $threw = $true; $line = 'THREW' }
Check 'tech: the resolver finds no gui-agent.exe to read -> build unknown, no exception' ((-not $threw) -and $line -eq 'x.ps1; reported once per boot; build unknown. Evidence: C:\x.log.')
Check 'tech: the resolver''s answer is cached as "none" for the process' ($script:QwtNotifyBuild -eq '')
$script:QwtNotifyBuild = '4.3.36.915'
CheckStatus 'compose: a report with no header is refused (never a silent drop)' (Send-QwtError -Component 'activate-idd' -Id 'no-header' -Header '' -Next 'y' -Tech 'z') 'rejected:redact'
Check 'compose: the refusal is logged' ((LogCount 'did not compose') -eq 1)
Check 'send: marker and count files written' ((Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')) -and (Test-Path (Join-Path $stateDir '.count')))
CheckStatus 'dedupe: the same error again this boot is suppressed' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Header 'shutdown refused' -Next 'y' -Tech 'z') 'suppressed:duplicate'
Check 'dedupe: no second launch' ($script:launched.Count -eq 1)
CheckStatus 'dedupe: a different id still sends' (Send-QwtError -Component 'activate-idd' -Id 'activation-failed' -Header 'x' -Next 'y' -Tech 'z') 'send'
CheckStatus 'severity: DEGRADED report is rejected' (Send-QwtError -Component 'activate-idd' -Id 'degraded' -Severity DEGRADED -Header 'x' -Next 'y' -Tech 'z') 'rejected:severity'
CheckStatus 'severity: INFO report is rejected' (Send-QwtError -Component 'activate-idd' -Id 'info' -Severity INFO -Header 'x' -Next 'y' -Tech 'z') 'rejected:severity'
Check 'severity: rejected event left no marker and no launch' ((-not (Test-Path (Join-Path $stateDir 'activate-idd.degraded'))) -and ($script:launched.Count -eq 2))
# a marker written by the C side for THIS boot must suppress (cross-language dedupe)
[IO.File]::WriteAllText((Join-Path $stateDir 'gui-agent.deslicedown'), "boot=$BOOT`n", [Text.Encoding]::ASCII)
CheckStatus 'dedupe: C-side marker from this boot suppresses' (Send-QwtError -Component 'gui-agent' -Id 'deslicedown' -Header 'x' -Next 'y' -Tech 'z') 'suppressed:duplicate'
[IO.File]::WriteAllText((Join-Path $stateDir 'gui-agent.oldboot'), "boot=$($BOOT - 5000)`n", [Text.Encoding]::ASCII)
CheckStatus 'dedupe: marker from an earlier boot does not suppress' (Send-QwtError -Component 'gui-agent' -Id 'oldboot' -Header 'x' -Next 'y' -Tech 'z') 'send'
# The same defect end-to-end, not just in the comparator: a marker left by a boot that ended 73 s
# ago is a DIFFERENT boot and must not suppress this one.
[IO.File]::WriteAllText((Join-Path $stateDir 'gui-agent.closeboot'), "boot=$($BOOT - 73)`n", [Text.Encoding]::ASCII)
CheckStatus 'dedupe: marker from a boot 73 s earlier does not suppress (close reboot)' (Send-QwtError -Component 'gui-agent' -Id 'closeboot' -Header 'x' -Next 'y' -Tech 'z') 'send'
# cap: 4 sends so far (the close-reboot case above is the 4th); distinct ids up to 8
$last = 'send'
for ($i = 4; $i -lt 8; $i++) { $last = Send-QwtError -Component 'gui-agent' -Id "cap-$i" -Header 'x' -Next 'y' -Tech 'z' }
CheckStatus 'cap: the 8th distinct error still sends' $last 'send'
CheckStatus 'cap: the 9th distinct error is suppressed' (Send-QwtError -Component 'gui-agent' -Id 'cap-9' -Header 'x' -Next 'y' -Tech 'z') 'suppressed:cap'
Check 'cap: exactly 8 launches this boot' ($script:launched.Count -eq 8)
Check 'cap: suppression was logged' ((LogCount 'suppressed:cap') -eq 1)
Check 'cap and dedupe: nothing suppressed by the policy was shown as a window' ($script:boxes.Count -eq 0)

# --- 5. redaction end-to-end -------------------------------------------------------------------
Reset-Store
CheckStatus 'redact e2e: summary with a password is refused' (Send-QwtError -Component 'activate-idd' -Id 'reboot-refused' -Header 'shutdown refused, password=abc' -Next 'y' -Tech 'z') 'rejected:redact'
Check 'redact e2e: refused text launched nothing and left no marker' (($script:launched.Count -eq 0) -and -not (Test-Path (Join-Path $stateDir 'activate-idd.reboot-refused')))
Check 'redact e2e: refusal logged' ((LogCount 'rejected:redact') -eq 1)

# --- 6. fail-open ------------------------------------------------------------------------------
Reset-Store
Remove-Item -LiteralPath $script:QwtNotifyHostExe -Force   # exe missing
$threw = $false
try { $s = Send-QwtError -Component 'gui-agent' -Id 'a' -Header 'The GUI agent crashed' -Next 'y' -Tech 'z' } catch { $threw = $true; $s = 'THREW' }
CheckStatus 'fail-open: exe missing -> status, not an exception' $s 'failed:transport'
Check 'fail-open: no exception reached the caller' (-not $threw)
Check 'fail-open: dom0 not told -> the error window IS shown, with the text dom0 would have got' ($script:boxes.Count -eq 1 -and $script:boxes[0].header -eq 'The GUI agent crashed' -and $script:boxes[0].text -eq "The GUI agent crashed`r`ny`r`nz")
[void](Send-QwtError -Component 'gui-agent' -Id 'b' -Header 'x' -Next 'y' -Tech 'z')
[void](Send-QwtError -Component 'gui-agent' -Id 'c' -Header 'x' -Next 'y' -Tech 'z')
Check 'fail-open: three failures, the missing exe logged ONCE' ((LogCount 'NOT PRESENT') -eq 1)
Check 'fail-open: three distinct errors, three windows (each under its own per-boot record)' ($script:boxes.Count -eq 3)
CheckStatus 'fail-open: the same error again is a duplicate - no second window' (Send-QwtError -Component 'gui-agent' -Id 'a' -Header 'x' -Next 'y' -Tech 'z') 'suppressed:duplicate'
Check 'fail-open: still three windows' ($script:boxes.Count -eq 3)
New-Item -ItemType File -Path $script:QwtNotifyHostExe -Force | Out-Null   # exe present, launch fails
$script:QwtNotifyLauncher = { param($exe, $file) throw 'Start-Process failed' }
[void](Send-QwtError -Component 'gui-agent' -Id 'd' -Header 'x' -Next 'y' -Tech 'z')
[void](Send-QwtError -Component 'gui-agent' -Id 'e' -Header 'x' -Next 'y' -Tech 'z')
Check 'fail-open: launcher throwing logged ONCE' ((LogCount 'Start-Process failed') -eq 1)
Check 'fail-open: a launch failure shows the window too' ($script:boxes.Count -eq 5)
$script:QwtNotifyBoxShower = { param($h, $t) return $false }
[void](Send-QwtError -Component 'gui-agent' -Id 'f-nobox' -Header 'x' -Next 'y' -Tech 'z')
Check 'fail-open: a window that cannot be shown is a loud line, and the caller still gets a status' ((LogCount 'could NOT be shown') -eq 1)
$script:QwtNotifyBoxShower = { param($h, $t) throw 'WTSSendMessage threw' }
$threw = $false
try { $s = Send-QwtError -Component 'gui-agent' -Id 'g-boxthrows' -Header 'x' -Next 'y' -Tech 'z' } catch { $threw = $true; $s = 'THREW' }
Check 'fail-open: a shower that throws is caught, logged, and the caller still gets failed:transport' ((-not $threw) -and $s -eq 'failed:transport' -and (LogCount 'WTSSendMessage threw') -eq 1)
Check 'fail-open: caller reached this line' $true
# unwritable store: a FILE where the directory must be
Reset-Store
$badDir = Join-Path $tmpRoot 'not-a-dir'
[IO.File]::WriteAllText($badDir, 'x', [Text.Encoding]::ASCII)
$script:QwtNotifyStateDir = $badDir
$script:QwtNotifyLauncher = { param($exe, $file) [void]$script:launched.Add($file) }
CheckStatus 'fail-open: unwritable store -> no send' (Send-QwtError -Component 'gui-agent' -Id 'f' -Header 'x' -Next 'y' -Tech 'z') 'failed:transport'
[void](Send-QwtError -Component 'gui-agent' -Id 'g' -Header 'x' -Next 'y' -Tech 'z')
Check 'fail-open: unwritable store launched nothing' ($script:launched.Count -eq 0)
Check 'fail-open: unwritable store logged ONCE' ((LogCount 'not writable') -eq 1)
Check 'fail-open: with no per-boot record the window is shown at most ONCE per process (no dedupe, so no storm)' ($script:boxes.Count -eq 1)

# --- 7. no per-boot token -> LOUD failure, never a guess ---------------------------------------
# Boot identity is a volatile HKLM key (QERR_BOOT_KEY). Unpinning the stamp makes the helper go
# after it for real, and on this Linux pwsh the registry type throws - which is exactly the
# "no boot identity" path. Without a boot token neither once-per-boot nor the cap can be honoured,
# so the route must REFUSE and say so, rather than guess a token (which would either storm dom0 or
# swallow errors). This is what covers GUARD:boottoken in tools/tests/notifyerr-selftest.sh.
Reset-Store
$pinned = $script:QwtNotifyBootStamp
$script:QwtNotifyBootStamp = $null
$script:QwtNotifyBootCached = $null
$threw = $false
try { $s = Send-QwtError -Component 'gui-agent' -Id 'noboot' -Header 'x' -Next 'y' -Tech 'z' } catch { $threw = $true; $s = 'THREW' }
CheckStatus 'boot token: unavailable -> no send' $s 'failed:transport'
Check 'boot token: no exception reached the caller' (-not $threw)
Check 'boot token: nothing launched, no marker written' (($script:launched.Count -eq 0) -and -not (Test-Path (Join-Path $stateDir 'gui-agent.noboot')))
Check 'boot token: the failure is logged' ((LogCount 'no per-boot token') -eq 1)
Check 'boot token: the window is still shown, once per process' ($script:boxes.Count -eq 1)
$script:QwtNotifyBootStamp = $pinned
$script:QwtNotifyBootCached = $null

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
