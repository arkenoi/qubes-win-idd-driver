# THE DEPLOY MUST PROVE WHAT IT BUILT, AND THIS RUNS THE CODE THAT PROVES IT.
#
# WHAT WENT WRONG, and it shipped in a build the owner was told was ready. MEASURED on win11de-tup,
# 2026-10-22, three template-update rounds: guest/install-updater-agent.ps1 logged
# "updater agent deployed" and every relay launched afterwards bound THE PASS'S OWN PID as its
# listen port - 600, 2880, 4184, 5548, 6688, 8228 - with no `parent=` on its listen line. The
# shipped source writes that field unconditionally, so none of those processes was the shipped
# binary. WinHTTP points at 8082, nothing served it, every pass ended SILENT and dom0 was told
# nothing. This had been reported FIXED (87e3a746) on offline legs and Jev scores alone, with no
# receipt that the new relay had ever run - which is precisely what those legs could not see.
#
# WHY IT HAPPENED. $src is $SetupRoot\qubes-updates-relay.cs, and on a guest $SetupRoot is a COPY
# (C:\qwt-improved-setup). A stale copy compiles an old binary while every step reports success:
# the move already throws when the exe is locked, so the move was never the failure. And the whole
# busy/orphan path keys on Get-NetTCPConnection -LocalPort 8082 - "found by the PORT ... never by a
# name" in its own comment - which is exactly what a relay on a pid-port defeats.
#
# THE THREE PROPERTIES ASSERTED HERE, each by running the shipped region:
#   RELAYSOURCEVOUCH - a source missing any capability marker is REFUSED as a stale payload;
#   RELAYEXEVOUCH    - the placed exe must carry the shipped binary's marker, searched as the UTF-16
#                      bytes a .NET literal actually occupies, with no execution and no port bound;
#   RELAYBYIMAGE     - a relay running from the exe we are replacing is ended BY ITS PID whatever
#                      port it holds, and never by name.
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; "ok   $what" } else { $script:fail++; "FAIL $what"; if ($detail) { "       -> $detail" } }
}
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$deploy = Join-Path $repo 'guest/install-updater-agent.ps1'
if (-not (Test-Path -LiteralPath $deploy)) { "FATAL: $deploy missing"; exit 2 }
$lines = Get-Content -LiteralPath $deploy

function Get-Region([string]$name) {
    $b = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $e = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $e[0] -le $b[0]) { return $null }
    return ($lines[($b[0] + 1)..($e[0] - 1)]) -join "`n"
}
$T = Join-Path ([IO.Path]::GetTempPath()) ("relayvouch-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $T | Out-Null
function Reset-Harness { $script:logged = New-Object System.Collections.ArrayList
    function global:Log { param([string]$m) [void]$script:logged.Add($m) } }

# =============== 1. the SOURCE vouch =============================================================
$rsv = Get-Region 'RELAYSOURCEVOUCH'
if (-not $rsv) { "FATAL: could not extract RELAYSOURCEVOUCH"; exit 2 }
# the shipped source is the positive fixture - not a hand-written stand-in, or the test is about
# the stand-in rather than about the release
$shipped = Join-Path $repo 'guest/qubes-updates-relay.cs'
Reset-Harness
$src = $shipped
$threw = $null
try { Invoke-Expression $rsv } catch { $threw = "$($_.Exception.Message)" }
Check 'source vouch: the SHIPPED relay source passes' ($null -eq $threw) "threw: $threw"
Check '...and it says so in the log, so a reader can see the check ran' `
    (@($script:logged | Where-Object { $_ -like '*vouched*' }).Count -eq 1) "log=$($script:logged -join ' | ')"

foreach ($marker in @('--parent-pid', 'i == 1 && int.TryParse', 'parent=')) {
    # a stale payload is simulated by removing EXACTLY one capability from the shipped text, so the
    # fixture is the real source minus the one thing the vouch is about
    $stale = Join-Path $T ("stale-" + ($marker -replace '[^a-z]', '') + ".cs")
    (Get-Content -LiteralPath $shipped -Raw).Replace($marker, 'XXREMOVEDXX') | Set-Content -LiteralPath $stale -NoNewline
    Reset-Harness
    $src = $stale
    $threw = $null
    try { Invoke-Expression $rsv } catch { $threw = "$($_.Exception.Message)" }
    Check "source vouch: a source with '$marker' removed is REFUSED as a stale payload" `
        ($threw -and $threw -like '*QWTRELAYSTALESRC*') "threw: $threw"
    Check "...and the refusal names what is missing, not just that something is" `
        ($threw -and $threw -like "*$marker*") "threw: $threw"
}

# =============== 2. the placed EXE vouch =========================================================
$rev = Get-Region 'RELAYEXEVOUCH'
if (-not $rev) { "FATAL: could not extract RELAYEXEVOUCH"; exit 2 }
# NOTHING IS STRIPPED. The END marker sits INSIDE the compile block, above that block's own closing
# brace, so the extracted region is already balanced and runs as-is. Two earlier drafts removed a
# lone `}` - first every one, then the last - and both took a brace the region's own for/if needed,
# which surfaced as "Missing closing '}'" on three legs. That is the extraction testing itself, and
# the region is used verbatim for the same reason the suite reads the shipped file at all.
$revBody = $rev

$good = Join-Path $T 'good.exe'
[IO.File]::WriteAllBytes($good, (@([byte]0x4D, 0x5A) + [Text.Encoding]::Unicode.GetBytes('parent=none (no watchdog)') + @([byte]0x00)))
Reset-Harness; $exe = $good; $threw = $null
try { Invoke-Expression $revBody } catch { $threw = "$($_.Exception.Message)" }
Check 'exe vouch: a binary carrying the UTF-16 parent= marker passes' ($null -eq $threw) "threw: $threw"

$bad = Join-Path $T 'stale.exe'
[IO.File]::WriteAllBytes($bad, (@([byte]0x4D, 0x5A) + [Text.Encoding]::Unicode.GetBytes('listen 127.0.0.1:') + @([byte]0x00)))
Reset-Harness; $exe = $bad; $threw = $null
try { Invoke-Expression $revBody } catch { $threw = "$($_.Exception.Message)" }
Check 'exe vouch: the SHIPPED FAILURE - a relay without the marker is REFUSED, not reported deployed' `
    ($threw -and $threw -like '*QWTRELAYSTALEEXE*') "threw: $threw"

# ASCII is not UTF-16: a .NET literal lives in the PE as UTF-16, and searching for ASCII bytes
# would pass a binary that merely mentions the word in a resource or a path.
$ascii = Join-Path $T 'ascii.exe'
[IO.File]::WriteAllBytes($ascii, [Text.Encoding]::ASCII.GetBytes('parent=none (no watchdog)'))
Reset-Harness; $exe = $ascii; $threw = $null
try { Invoke-Expression $revBody } catch { $threw = "$($_.Exception.Message)" }
Check 'exe vouch: an ASCII-only occurrence does NOT satisfy it - the marker is a UTF-16 literal' `
    ($threw -and $threw -like '*QWTRELAYSTALEEXE*') "threw: $threw"

# A VOUCH THAT CANNOT READ THE FILE MUST NOT CALL IT STALE. Defender holds a freshly written exe
# briefly, so a single read right after Move-Item can fail on a binary that is perfectly correct.
# Refusing it as a stale relay would fail a good install and send the reader hunting a payload
# problem that does not exist, so the two cases carry different errors.
function global:Start-Sleep { param($Milliseconds, $Seconds) }
Reset-Harness; $exe = (Join-Path $T 'no-such-relay.exe'); $threw = $null
try { Invoke-Expression $revBody } catch { $threw = "$($_.Exception.Message)" }
Check 'exe vouch: an UNREADABLE exe is its own error, not a stale-binary refusal' `
    ($threw -and $threw -like '*QWTRELAYUNREADABLE*') "threw: $threw"
Check '...and it does NOT claim the binary is stale, which would misdirect the reader' `
    ($threw -and $threw -notlike '*QWTRELAYSTALEEXE*') "threw: $threw"
Remove-Item function:global:Start-Sleep -EA SilentlyContinue

# =============== 3. stale relays found BY IMAGE, not by port =====================================
$rbi = Get-Region 'RELAYBYIMAGE'
if (-not $rbi) { "FATAL: could not extract RELAYBYIMAGE"; exit 2 }
Check 'by-image: the region never looks up or stops anything BY NAME' `
    ((@($rbi -split "`n" | Where-Object { $_ -match 'Get-Process(?!\s+-Id\b)' -or $_ -match 'Stop-Process(?!\s+-Id\b)' -or $_ -match 'taskkill' }).Count) -eq 0) `
    'a pattern matches the matcher; only -Id is allowed'

function Drive-ByImage([object[]]$procs, [string]$exePath, [int]$failCimAfter = 0) {
    $script:stopped = New-Object System.Collections.ArrayList
    $script:cimCalls = 0
    $script:failCimAfter = $failCimAfter
    function global:Get-CimInstance { param($ClassName, $Filter, $EA, $ErrorAction)
        $script:cimCalls++
        if ($script:failCimAfter -gt 0 -and $script:cimCalls -gt $script:failCimAfter) {
            throw 'WMI: the RPC server is unavailable'
        }
        return $script:procTable }
    function global:Stop-Process { param([int]$Id, [switch]$Force, $EA, $ErrorAction)
        [void]$script:stopped.Add($Id)
        $script:procTable = @($script:procTable | Where-Object { [int]$_.ProcessId -ne $Id }) }
    function global:Start-Sleep { param($Milliseconds, $Seconds) }
    $script:procTable = $procs
    Reset-Harness
    $exe = $exePath
    Invoke-Expression $rbi
}

$ourExe = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
# the measured orphan: running from OUR exe, on a pid-port, so nothing holds 8082
Drive-ByImage @([pscustomobject]@{ ProcessId = 600; ExecutablePath = $ourExe }) $ourExe
Check 'by-image: a relay on OUR exe is ended by its pid even though it holds no 8082' `
    ($script:stopped -contains 600) "stopped=$($script:stopped -join ',')"

Drive-ByImage @([pscustomobject]@{ ProcessId = 777; ExecutablePath = 'C:\Other\qubes-updates-relay.exe' }) $ourExe
Check 'by-image: a relay from a DIFFERENT path is left alone - this is not a kill-by-name' `
    ($script:stopped.Count -eq 0) "stopped=$($script:stopped -join ',')"
# ...and it is NAMED in the log. The comparison is a plain path equality (GetFullPath is not
# portable enough to test here), so the one thing that must never happen is a miss that looks like
# "no relay found". A different image is reported, with its pid and its path.
Check '...and it is LOGGED, so a path-spelling miss can never read as "nothing found"' `
    (($script:logged -join ' | ') -like '*DIFFERENT image*777*') "log=$($script:logged -join ' | ')"

Drive-ByImage @() $ourExe
Check 'by-image: no relay running is a no-op, and nothing is waited on' `
    ($script:stopped.Count -eq 0) "stopped=$($script:stopped -join ',')"

Drive-ByImage @([pscustomobject]@{ ProcessId = 600; ExecutablePath = $ourExe },
                [pscustomobject]@{ ProcessId = 2880; ExecutablePath = $ourExe }) $ourExe
Check 'by-image: every stale relay is ended, not just the first (the measured run had six)' `
    (($script:stopped -contains 600) -and ($script:stopped -contains 2880)) "stopped=$($script:stopped -join ',')"

# UNKNOWN IS NOT ZERO. The confirm-the-stop loop used to swallow a failed process query into an
# empty array, break on it, and log "relay processes on our image after the stop: 0" - a query that
# never ran, reported as success. That is the same shape as the defect this whole region exists for:
# a step that could not do its job announcing that it did. Here the FIRST query finds the orphan and
# every later one fails, which is exactly the window the loop runs in.
Drive-ByImage @([pscustomobject]@{ ProcessId = 600; ExecutablePath = $ourExe }) $ourExe 1
$log = ($script:logged -join ' | ')
Check 'by-image: a FAILED process query is never reported as zero relays left' `
    ($log -notmatch 'after the stop: 0') "log=$log"
Check '...and it says the check could not be confirmed, so a reader is not told it passed' `
    ($log -like '*could not confirm*') "log=$log"

Remove-Item -Recurse -Force $T -EA SilentlyContinue
''
"RESULT: $pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
