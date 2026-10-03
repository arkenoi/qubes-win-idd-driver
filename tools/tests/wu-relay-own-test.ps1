<#
.SYNOPSIS
    Offline suite for the relay lifecycle of guest/qubes-windows-update.ps1 (Ensure-Proxy, Start-Relay,
    Stop-OwnRelay, Remove-Proxy): the pass owns exactly the relay it started, by handle, and never kills
    or adopts a process by NAME. Runs under pwsh on Linux or Windows PowerShell 5.1; no rig, no guest,
    no relay binary - processes and the TCP table are fakes this suite scripts.

.DESCRIPTION
    THE DEFECT (measured 2026-10-03, docs/ADR-updater.md 12.4, findings/issues.md P1 "OUR UPDATE CODE
    KILLS AND ADOPTS PROCESSES BY NAME"): Ensure-Proxy started a relay only if no process NAMED
    qubes-updates-relay existed and otherwise served through whatever answered on 8082; when 8082 did not
    answer it killed every relay by name; Remove-Proxy (the end of every pass) TerminateProcess'ed every
    process with that name. A controlled repro: a foreign relay with a live parent was started on 8082,
    the shipped scan ran beside it, adopted it, and killed it at 'proxy removed, relay stopped'.

    The suite extracts the WU-RELAY and WU-RELAY-TEARDOWN regions by their marker lines (never by
    brace-hunting), dot-sources them, and drives them against a fake world: Start-Process returns fake
    Process objects (Kill/WaitForExit/HasExited record what is done to them), Get-NetTCPConnection answers
    from a scripted port table, Get-Process/Stop-Process record every BY-NAME lookup or kill so a knob
    that restores one is seen, Test-RelayListening answers from the port table. Live de-DE culture.
      own       8082 free -> one relay started with -PassThru and held (pid + start time); Remove-Proxy
                stops exactly it, once, logs pid and exit code; a second Remove-Proxy kills nothing
      foreign   8082 held by a process this pass did not start -> Ensure-Proxy REFUSES naming its pid,
                starts nothing, sets no proxy; Remove-Proxy leaves it alone
      deaf      the own relay does not accept -> it alone is stopped (by handle) and another started;
                a relay-NAMED process elsewhere is not touched by the respawn or by the end of the pass
      race      a listener takes 8082 between the check and our start -> not adopted: REFUSED naming it,
                the own relay stopped by handle, the squatter untouched
      unknown   the TCP table cannot be read -> REFUSED (unknown is not free), nothing started
      shipped   no by-name process lookup is left in either region; the --parent-pid wiring the
                relay-parent test asserts is intact
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces one pre-2026-10-03 behaviour in the extracted copy (the shipped file is never modified):
      1   `# GUARD:relayrefuse`   adopt by name: start a relay only if none is NAMED qubes-updates-relay,
                                  serve through whatever listens -> the foreign case must FAIL
      2   `# GUARD:relayownstop`  Remove-Proxy kills every process named qubes-updates-relay -> the
                                  foreign process no longer survives the end of the pass
      3   `# GUARD:relayrespawnown`  the respawn kills every relay-named process -> the deaf case's
                                  bystander is killed
      4   `# GUARD:relayhandle`   Start-Process without -PassThru: no handle is kept -> the own case
                                  cannot stop its relay
      5   `# GUARD:relayidentity` the listener is not checked to be ours -> the race case adopts the squatter
    tools/tests/wu-relay-own-selftest.sh runs the clean leg and every knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'guest/qubes-windows-update.ps1' }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- extract the regions by their marker lines ------------------------------------------------------
$lines = @(Get-Content -LiteralPath $ScriptPath)
function Get-Region([string]$name) {
    $begins = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $ends   = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $begins[0] -ge $ends[0]) {
        Write-Host "FAIL marker extraction ${name}: expected exactly one BEGIN before one END, got $($begins.Count)/$($ends.Count)"
        exit 1
    }
    return ,@($lines[($begins[0] + 1)..($ends[0] - 1)])
}
$relay    = Get-Region 'WU-RELAY'
$teardown = Get-Region 'WU-RELAY-TEARDOWN'
Check 'extract: the WU-RELAY region defines the probe, the port-owner read, the refusal, the start, the own-stop and Ensure-Proxy' `
      (@($relay | Where-Object { $_ -match '^function (Test-RelayListening|Get-RelayPortOwner|Format-RelayRefusal|Start-Relay|Stop-OwnRelay|Ensure-Proxy)\b' }).Count -eq 6)
Check 'extract: the WU-RELAY-TEARDOWN region defines Remove-Proxy' (@($teardown | Where-Object { $_ -match '^function Remove-Proxy\b' }).Count -eq 1)
foreach ($g in 'relayhandle', 'relayrefuse', 'relayrespawnown', 'relayidentity') {
    Check "extract: exactly one '# GUARD:$g' line in WU-RELAY" (@($relay | Where-Object { $_ -match "# GUARD:$g`$" }).Count -eq 1)
}
Check "extract: exactly one '# GUARD:relayownstop' line in WU-RELAY-TEARDOWN" (@($teardown | Where-Object { $_ -match '# GUARD:relayownstop$' }).Count -eq 1)

# --- shipped: the by-name shapes are gone from the code lines of both regions -----------------------------
$code = @(($relay + $teardown) | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '\s#')[0] })
Check 'shipped: no by-name Get-Process is left in the relay regions (every Get-Process there is -Id)' `
      (@($code | Where-Object { $_ -match 'Get-Process(?!\s+-Id\b)' }).Count -eq 0)
Check 'shipped: no Stop-Process, no pipeline Kill, no taskkill in the relay regions' `
      (@($code | Where-Object { $_ -match 'Stop-Process|\|\s*(ForEach-Object|%)\s*\{[^}]*\.Kill\(|taskkill' }).Count -eq 0)
Check 'shipped: Start-Relay keeps the --parent-pid wiring (what relay-parent-test asserts) and adds -PassThru' `
      (@($relay | Where-Object { $_ -match "'--listen','8082','--target','@default','--log',\`$WorkDir,'--parent-pid',`"\`$PID`"" -and $_ -match '-PassThru' }).Count -eq 1)

# --- defect knobs: patch the extracted copy, never the shipped file ---------------------------------------------
function Set-GuardLine([string[]]$region, [string]$guard, [string]$replacement) {
    $hit = @($region | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line, found $($hit.Count)"; exit 1 }
    return ,@($region | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } })
}
switch ($Defect) {
    '' { }
    '1' { $relay = Set-GuardLine $relay 'relayrefuse' ('  & netsh winhttp set proxy ''127.0.0.1:8082'' ''<local>'' | Out-Null; if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) { Start-Relay }; if (Test-RelayListening) { return }   # DEFECT: adopt by name (pre-2026-10-03)') }
    '2' { $teardown = Set-GuardLine $teardown 'relayownstop' '  Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }   # DEFECT: kill by name (pre-2026-10-03)' }
    '3' { $relay = Set-GuardLine $relay 'relayrespawnown' '    Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue   # DEFECT: kill by name (pre-2026-10-03)' }
    '4' { $relay = Set-GuardLine $relay 'relayhandle' ('  Start-Process -FilePath $RelayExe -ArgumentList ''--listen'',''8082'',''--target'',''@default'',''--log'',$WorkDir,''--parent-pid'',"$PID" -WindowStyle Hidden; $p = $null   # DEFECT: no handle kept (pre-2026-10-03)') }
    '5' { $relay = Set-GuardLine $relay 'relayidentity' '  # DEFECT: the listener is not checked to be ours' }
    default { Write-Host "FAIL unknown -Defect '$Defect' (1|2|3|4|5)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wu-relay-own-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$regionFile = Join-Path $tmpRoot 'relay-region.ps1'
[IO.File]::WriteAllLines($regionFile, [string[]]($relay + $teardown), [Text.UTF8Encoding]::new($false))

# What the regions read from the pass's preamble.
$RelayExe = Join-Path $tmpRoot 'qubes-updates-relay.exe'
[IO.File]::WriteAllText($RelayExe, 'fake')
$WorkDir = $tmpRoot
$POL = 'HKLM:\fake\Policies'
$IS  = 'HKLM:\fake\Internet Settings'
$script:OwnRelay = $null; $script:OwnRelayPid = 0; $script:OwnRelayStart = ''

. $regionFile

# --- the fake world --------------------------------------------------------------------------------------------------
# Procs: pid -> fake Process. PortOwner: who listens on 8082 (0 = nobody). DeafPids: listening but never accepting.
# GrabOnStart: a squatter that takes the port the moment our relay is started. PortUnknown: the TCP table is unreadable.
function Reset-World {
    $script:Procs = @{}; $script:Calls = @(); $script:Logs = @()
    $script:PortOwner = 0; $script:NextPid = 5001; $script:DeafPids = @(); $script:GrabOnStart = 0; $script:PortUnknown = ''
    $script:OwnRelay = $null; $script:OwnRelayPid = 0; $script:OwnRelayStart = ''
}
function New-FakeProcess([int]$id, [string]$name) {
    $o = [pscustomobject]@{ Id = $id; ProcessName = $name; StartTime = (Get-Date).AddSeconds(-1); ExitCode = 0; Exited = $false }
    $o | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $this.Exited }
    $o | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $script:Calls += "Kill $($this.Id)"
        $this.Exited = $true; $this.ExitCode = -1
        if ($script:PortOwner -eq $this.Id) { $script:PortOwner = 0 }
    }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return [bool]$this.Exited }
    $script:Procs[$id] = $o
    return $o
}
function Start-Process { [CmdletBinding()] param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
    $id = $script:NextPid; $script:NextPid++
    $script:Calls += ("Start-Process {0} passthru={1}" -f $id, [bool]$PassThru)
    $p = New-FakeProcess $id 'qubes-updates-relay'
    if ($script:GrabOnStart) { if ($script:PortOwner -eq 0) { $script:PortOwner = $script:GrabOnStart } }
    elseif ($script:PortOwner -eq 0) { $script:PortOwner = $id }
    if ($PassThru) { return $p }
}
function Get-NetTCPConnection { [CmdletBinding()] param($LocalPort, $State)
    $script:Calls += 'Get-NetTCPConnection 8082'
    if ($script:PortUnknown -eq 'throw') { throw "The term 'Get-NetTCPConnection' is not recognized" }
    if ($script:PortUnknown -eq 'error') { Write-Error -Message 'Zugriff verweigert' -Category PermissionDenied; return }
    if ($script:PortOwner -le 0) { Write-Error -Message "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '8082'" -Category ObjectNotFound; return }
    return ,([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8082; State = 'Listen'; OwningProcess = [uint32]$script:PortOwner })
}
# Overrides the region's: no real socket. Something accepts iff a listener is on the port and it is not deaf.
function Test-RelayListening {
    $script:Calls += 'Test-RelayListening'
    if ($script:PortOwner -le 0) { return $false }
    if ($script:DeafPids -contains $script:PortOwner) { return $false }
    return $true
}
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $script:Calls += "Get-Process -Id $Id"
        $r = @(); foreach ($i in $Id) { if ($script:Procs.ContainsKey([int]$i) -and -not $script:Procs[[int]$i].Exited) { $r += $script:Procs[[int]$i] } }
        return $r
    }
    $script:Calls += "Get-Process $Name"   # BY NAME - recorded so a knob that restores it is seen
    return @($script:Procs.Values | Where-Object { -not $_.Exited -and ($Name -contains $_.ProcessName) })
}
function Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { if ($InputObject) { $script:Calls += "Stop-Process $($InputObject.Id)"; $InputObject.Kill() } }
}
function netsh { $script:Calls += ('netsh ' + ($args -join ' ')) }
function SetV($p, $n, $v, $t) { $script:Calls += "SetV $n=$v" }
function Remove-ItemProperty { [CmdletBinding()] param($Path, $Name) $script:Calls += "Remove-ItemProperty $Name" }
function Log($m) { $script:Logs += "$m" }
function Start-Sleep { [CmdletBinding()] param($Seconds, $Milliseconds) }

function Invoke-EnsureProxy { $script:Thrown = ''; try { Ensure-Proxy } catch { $script:Thrown = "$($_.Exception.Message)" } }
function Count-Calls([string]$like) { return @($script:Calls | Where-Object { $_ -like $like }).Count }
function Count-ByName { return @($script:Calls | Where-Object { $_ -like 'Get-Process *' -and $_ -notlike 'Get-Process -Id *' }).Count }

# --- 1. own: the pass starts one relay, holds it, and stops exactly it -----------------------------------------------
Reset-World
Invoke-EnsureProxy
Check 'own: with 8082 free, Ensure-Proxy starts exactly one relay and returns' ($script:Thrown -eq '' -and (Count-Calls 'Start-Process *') -eq 1)
Check 'own: the relay is started with -PassThru and held by handle (pid 5001, start time recorded)' `
      ($script:Calls -contains 'Start-Process 5001 passthru=True' -and $script:OwnRelayPid -eq 5001 -and $null -ne $script:OwnRelay -and $script:OwnRelay.Id -eq 5001 -and $script:OwnRelayStart -ne '')
Check 'own: the proxy settings are set and the relay is proven to be the listener (proxy up logged with pid 5001)' `
      ($script:Calls -contains 'netsh winhttp set proxy 127.0.0.1:8082 <local>' -and $script:Calls -contains 'SetV ProxyServer=127.0.0.1:8082' -and
       @($script:Logs | Where-Object { $_ -eq 'proxy up: 127.0.0.1:8082 is served by relay pid 5001, started by this pass' }).Count -eq 1)
Check 'own: no process was looked up by name on the way' ((Count-ByName) -eq 0)
Remove-Proxy
Check 'own: Remove-Proxy stops the own relay by its handle, once (Kill 5001), and it has exited' ((Count-Calls 'Kill 5001') -eq 1 -and $script:Procs[5001].Exited)
Check 'own: the stop is logged with the pid and the exit code' (@($script:Logs | Where-Object { $_ -like 'relay pid 5001 stopped by this pass (exit code *)' }).Count -eq 1)
Check 'own: Remove-Proxy resets the proxy settings (netsh reset, ProxyEnable=0, ProxyServer removed)' `
      ($script:Calls -contains 'netsh winhttp reset proxy' -and $script:Calls -contains 'SetV ProxyEnable=0' -and $script:Calls -contains 'Remove-ItemProperty ProxyServer')
Remove-Proxy
Check 'own: a second Remove-Proxy kills nothing (the handle was released with the stop) and says so' `
      ((Count-Calls 'Kill *') -eq 1 -and @($script:Logs | Where-Object { $_ -like 'relay: this pass holds no relay handle*' }).Count -eq 1)
Check 'own: still no by-name lookup, and no Stop-Process at all' ((Count-ByName) -eq 0 -and (Count-Calls 'Stop-Process *') -eq 0)

# --- 2. foreign: 8082 is held by a process this pass did not start ------------------------------------------------------
Reset-World
$foreign = New-FakeProcess 7777 'qubes-updates-relay'
$script:PortOwner = 7777
Invoke-EnsureProxy
Check 'foreign: a listener this pass did not start on 8082 -> Ensure-Proxy REFUSES, naming pid 7777 and that it was not killed' `
      ($script:Thrown -like 'REFUSED: 127.0.0.1:8082 is already served by pid 7777 (qubes-updates-relay, started *' -and $script:Thrown -like '*it was NOT killed')
Check 'foreign: nothing was started and nothing adopted (no Start-Process, no handle held)' ((Count-Calls 'Start-Process *') -eq 0 -and $null -eq $script:OwnRelay -and $script:OwnRelayPid -eq 0)
Check 'foreign: the proxy settings were not set before the refusal (no netsh set, no SetV)' ((Count-Calls 'netsh winhttp set *') -eq 0 -and (Count-Calls 'SetV *') -eq 0)
Remove-Proxy
Check 'foreign: at the end of the pass Remove-Proxy leaves the foreign relay-named process alone (no Kill 7777, still running)' `
      ((Count-Calls 'Kill 7777') -eq 0 -and (Count-Calls 'Stop-Process 7777') -eq 0 -and -not $foreign.Exited)
Check 'foreign: Remove-Proxy still resets the proxy settings and logs that this pass holds no relay handle' `
      ($script:Calls -contains 'netsh winhttp reset proxy' -and @($script:Logs | Where-Object { $_ -like 'relay: this pass holds no relay handle*' }).Count -eq 1)
Check 'foreign: no process was looked up by name' ((Count-ByName) -eq 0)

# --- 3. deaf: the own relay does not accept; a relay-NAMED bystander elsewhere must survive the respawn ----------------
Reset-World
$bystander = New-FakeProcess 7777 'qubes-updates-relay'   # the same image, another port, another owner - not on 8082
$script:DeafPids = @(5001)
Invoke-EnsureProxy
Check 'deaf: the own relay (5001) does not accept -> it alone is stopped by handle and another (5002) is started; the pass proceeds' `
      ($script:Thrown -eq '' -and (Count-Calls 'Kill 5001') -eq 1 -and $script:Calls -contains 'Start-Process 5002 passthru=True' -and $script:OwnRelayPid -eq 5002)
Check 'deaf: the respawn is logged against pid 5001 by its handle' (@($script:Logs | Where-Object { $_ -like 'relay pid 5001 is not accepting connections*stopping THAT relay (by its handle)*' }).Count -eq 1)
Check 'deaf: the relay-named bystander (7777) is not touched by the respawn (no Stop-Process 7777, no Kill 7777, no by-name lookup)' `
      ((Count-Calls 'Kill 7777') -eq 0 -and (Count-Calls 'Stop-Process 7777') -eq 0 -and -not $bystander.Exited -and (Count-ByName) -eq 0)
Remove-Proxy
Check 'deaf: the end of the pass stops 5002 only; the bystander is still running' ((Count-Calls 'Kill 5002') -eq 1 -and (Count-Calls 'Kill 7777') -eq 0 -and -not $bystander.Exited)

# --- 4. race: a squatter takes 8082 between the check and our start ------------------------------------------------------
Reset-World
$squatter = New-FakeProcess 7777 'squatter'
$script:GrabOnStart = 7777
Invoke-EnsureProxy
Check 'race: a listener that took 8082 between the check and our start is not adopted -> REFUSED naming pid 7777 (squatter)' `
      ($script:Thrown -like 'REFUSED: 127.0.0.1:8082 is already served by pid 7777 (squatter, started *')
Check 'race: the own relay (5001) was stopped by handle; the squatter was not touched' ((Count-Calls 'Kill 5001') -eq 1 -and (Count-Calls 'Kill 7777') -eq 0 -and -not $squatter.Exited)
Remove-Proxy
Check 'race: the end of the pass kills nothing more' ((Count-Calls 'Kill *') -eq 1 -and -not $squatter.Exited)

# --- 5. unknown: the TCP table cannot be read -------------------------------------------------------------------------------
foreach ($mode in 'throw', 'error') {
    Reset-World
    $script:PortUnknown = $mode
    Invoke-EnsureProxy
    Check "unknown ($mode): when the port table cannot be read, Ensure-Proxy REFUSES (unknown is not free) and starts nothing" `
          ($script:Thrown -like 'REFUSED: cannot read who listens on 127.0.0.1:8082*' -and (Count-Calls 'Start-Process *') -eq 0 -and (Count-Calls 'netsh winhttp set *') -eq 0)
}

Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail) { exit 1 }
exit 0
