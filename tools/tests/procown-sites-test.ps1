<#
.SYNOPSIS
    Offline suite for every shipped site that used to kill or adopt a process BY NAME (owner's rule 2026-10-03,
    docs/ADR-updater.md 12.4 - step 3 of the process-ownership change): the setup installer (the SCM-pid service-stop
    helper, the xenbus_monitor stop, Stop-QwtRuntime, the stage-2 GUI quiesce, the pre-surgery re-assert),
    guest/activate-idd.ps1 (its quiesce and its helper copies), guest/pvnic-selfprime.ps1 (the QwtngNetSetup stop),
    guest/quiet-desktop.ps1 (OneDrive) and the overlay installer's stop. Runs under pwsh on Linux: no rig, no guest.
    Services, the SCM's pid table and processes are fakes this suite scripts, and every kill - by handle, by pipeline,
    by name - is recorded, so "a survivor is reported and not killed" is a measured fact, not a reading of the code.

.DESCRIPTION
    Each region is extracted from the SHIPPED file by its marker lines (never by brace-hunting) and dot-sourced into a
    scope that provides what the surrounding script would (Write-Log/Log, $script:Result, $result, $SERVICE, ...).
    The world: a service table (status, the pid the SCM reports, whether a stop works / throws / ends the process /
    takes the agent down - the 2026-10-03 watchdog does, an older one does not) and a process table (alive, killable,
    whether the agent honours QGA_SHUTDOWN, whether a helper leaves on its own after N waits).
      svcstop   the helper takes the SCM pid BEFORE the stop, waits on it by handle, ends ONLY it and only with
                -TerminateSurvivor, never a same-named process, and says "no pid" when the SCM reports none
      xbm       the installer's xenbus_monitor stop: a lingering service process is ended by ITS pid; an orphan the
                SCM does not own is reported with its pid, left alive, refused under -FatalIfSurvives
      runtime   Stop-QwtRuntime: a new watchdog takes its agent; an old one leaves it and the agent is ASKED via
                QGA_SHUTDOWN; one that ignores the request is reported (gui_runtime_survivors) and left alive
      quiesce   the stage-2 quiesce: service stop + task cleanup + request + bounded helper wait; survivors are
                reported in gui_quiesce_failed with GuiQuiesceHeld=false; a throwing Stop-Service kills nothing
      reassert  a reappeared process is recorded with its pid and left alive
      activate  activate-idd's quiesce: same, Assert-GuiQuiesced refuses naming the pid; its real Request-GuiAgentExit
                kills nothing when the event cannot be reached
      netsetup  pvnic-selfprime's QwtngNetSetup stop: the SCM pid is waited on and, if it lingers, ended, loudly; a
                same-named stray is never touched
      onedrive  quiet-desktop leaves a running OneDrive alone and says so
      overlay   the overlay installer: service stop by SCM pid, the agent asked, a survivor warned about and left alive
      shipped   static: no Stop-Process / taskkill / pipeline Kill in any region; .Kill() only on a Get-Process -Id
                handle; every GUARD anchor present exactly once; the installer's Request-GuiAgentExit kills nothing
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces one pre-2026-10-03 behaviour in the extracted copy (the shipped files are never modified) at the
    region's '# GUARD:<name>' line: svcpid (the SCM pid is never taken), xbmbyname, runtimebyname, quiescebyname,
    reassertbyname, activatebyname, netsetupbyname, onedrivebyname, overlaybyname (each the old by-name kill).
    tools/tests/procown-sites-selftest.sh runs the clean leg and every knob and requires each knob to FAIL its target.
#>
[CmdletBinding()]
param([string]$Defect = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    # Fully qualified: the regions' own Write-Host is mocked to silence below, and this must never be.
    Microsoft.PowerShell.Utility\Write-Host "$tag $name$suffix"
}

# --- extraction by marker -----------------------------------------------------------------------------------------
function Get-Region([string]$file, [string]$name) {
    $lines = @(Get-Content -LiteralPath (Join-Path $repoRoot $file))
    $b = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $e = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $b[0] -ge $e[0]) {
        Write-Host "FAIL marker extraction $file ${name}: expected exactly one BEGIN before one END, got $($b.Count)/$($e.Count)"
        exit 1
    }
    return ,@($lines[($b[0] + 1)..($e[0] - 1)])
}
$R = [ordered]@{
    'inst-svcstop'  = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'SVC-STOP'
    'inst-xbm'      = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'XBM-STOP'
    'inst-runtime'  = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'QWT-RUNTIME-STOP'
    'inst-quiesce'  = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'GUI-QUIESCE'
    'inst-reassert' = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'GUI-REASSERT'
    'act-fn'        = Get-Region 'guest/activate-idd.ps1' 'ACTIVATE-SVC-STOP'
    'act-quiesce'   = Get-Region 'guest/activate-idd.ps1' 'ACTIVATE-QUIESCE'
    'pv-netsetup'   = Get-Region 'guest/pvnic-selfprime.ps1' 'NETSETUP-STOP'
    'qd-onedrive'   = Get-Region 'guest/quiet-desktop.ps1' 'ONEDRIVE'
    'ov-stop'       = Get-Region 'packaging/payload/install-qwt-improved.ps1' 'OVERLAY-STOP'
}
# The installer's Request-GuiAgentExit is not a marked region (it is a plain function); taken for the static check only.
$instLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'packaging/setup/Install-QwtImproved.ps1'))
$rqStart = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_] -match '^function Request-GuiAgentExit\b' })
$rqEnd   = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QWT-RUNTIME-STOP-BEGIN*' })
Check 'extract: the installer defines Request-GuiAgentExit right before the QWT-RUNTIME-STOP region' ($rqStart.Count -eq 1 -and $rqEnd.Count -eq 1 -and $rqStart[0] -lt $rqEnd[0])
$instRequest = @($instLines[$rqStart[0]..($rqEnd[0] - 1)])

# --- shipped: static shapes, on the UNPATCHED regions --------------------------------------------------------------
function Get-CodeLines([string[]]$region) { @($region | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '\s#')[0] }) }
$guards = @{ 'inst-svcstop' = 'svcpid'; 'inst-xbm' = 'xbmbyname'; 'inst-runtime' = 'runtimebyname'; 'inst-quiesce' = 'quiescebyname'
             'inst-reassert' = 'reassertbyname'; 'act-quiesce' = 'activatebyname'; 'pv-netsetup' = 'netsetupbyname'
             'qd-onedrive' = 'onedrivebyname'; 'ov-stop' = 'overlaybyname' }
foreach ($k in $R.Keys) {
    $code = Get-CodeLines $R[$k]
    Check "shipped: no Stop-Process / taskkill / pipeline Kill in $k" (@($code | Where-Object { $_ -match 'Stop-Process|taskkill|\|\s*(ForEach-Object|%)\s*\{[^}]*\.Kill\(' }).Count -eq 0)
    Check "shipped: no line in $k both finds a process by name and kills it" (@($code | Where-Object { $_ -match 'Get-Process(?!\s+-Id\b)' -and $_ -match '\.Kill\(' }).Count -eq 0)
    if ($guards.ContainsKey($k)) {
        Check "shipped: exactly one '# GUARD:$($guards[$k])' anchor in $k" (@($R[$k] | Where-Object { $_ -match "# GUARD:$($guards[$k])`$" }).Count -eq 1)
    }
}
$killLines = @()
foreach ($k in $R.Keys) { $killLines += @(Get-CodeLines $R[$k] | Where-Object { $_ -match '\.Kill\(' }) }
Check 'shipped: the only .Kill() calls are on handles bound by Get-Process -Id ($proc in the installer helper, $oldProc in pvnic netsetup)' `
      ($killLines.Count -eq 2 -and @($killLines | Where-Object { $_ -match '\$(proc|oldProc)\.Kill\(' }).Count -eq 2) ($killLines -join ' || ')
$rqCode = Get-CodeLines $instRequest
Check 'shipped: the installer Request-GuiAgentExit asks (QGA_SHUTDOWN) and waits by handle; it has no Stop-Process, no .Kill, no taskkill' `
      (@($rqCode | Where-Object { $_ -match 'Stop-Process|\.Kill\(|taskkill' }).Count -eq 0 -and @($rqCode | Where-Object { $_ -match 'QGA_SHUTDOWN' }).Count -ge 1 -and @($rqCode | Where-Object { $_ -match 'WaitForExit' }).Count -ge 1)

# --- defect knobs: patch the extracted copy, never the shipped file -------------------------------------------------
function Set-GuardLine([string[]]$region, [string]$guard, [string]$replacement) {
    $hit = @($region | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line, found $($hit.Count)"; exit 1 }
    return ,@($region | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } })
}
$byName4 = '    foreach ($pn in ''gui-watchdog'', ''gui-agent'', ''wgcbroker'', ''notifhost'') { foreach ($pr in @(Get-Process -Name $pn -ErrorAction SilentlyContinue)) { try { $pr.Kill(); [void]$pr.WaitForExit(5000) } catch { } } }   # DEFECT: kill by name (pre-2026-10-03)'
switch ($Defect) {
    '' { }
    'svcpid'         { $R['inst-svcstop']  = Set-GuardLine $R['inst-svcstop']  'svcpid'         '    $svcPid = 0   # DEFECT: the SCM pid is never taken - nothing to wait on, nothing to end' }
    'xbmbyname'      { $R['inst-xbm']      = Set-GuardLine $R['inst-xbm']      'xbmbyname'      '    foreach ($p in @(Get-Process -Name ''xenbus_monitor*'' -ErrorAction SilentlyContinue)) { try { $p | Stop-Process -Force -ErrorAction Stop } catch { }; try { [void]$p.WaitForExit(5000) } catch { } }   # DEFECT: kill by name (pre-2026-10-03)' }
    'runtimebyname'  { $R['inst-runtime']  = Set-GuardLine $R['inst-runtime']  'runtimebyname'  '    foreach ($proc in ''gui-agent'', ''gui-watchdog'') { foreach ($pr in @(Get-Process -Name $proc -ErrorAction SilentlyContinue)) { try { $pr | Stop-Process -Force -ErrorAction Stop } catch { } } }   # DEFECT: kill by name (pre-2026-10-03)' }
    'quiescebyname'  { $R['inst-quiesce']  = Set-GuardLine $R['inst-quiesce']  'quiescebyname'  $byName4 }
    'reassertbyname' { $R['inst-reassert'] = Set-GuardLine $R['inst-reassert'] 'reassertbyname' '          try { $pr.Kill(); [void]$pr.WaitForExit(5000) } catch { }   # DEFECT: kill by name (pre-2026-10-03)' }
    'activatebyname' { $R['act-quiesce']   = Set-GuardLine $R['act-quiesce']   'activatebyname' $byName4 }
    'netsetupbyname' { $R['pv-netsetup']   = Set-GuardLine $R['pv-netsetup']   'netsetupbyname' '            foreach ($p in @(Get-Process -Name ''qwtng-netsetup'' -EA SilentlyContinue)) { if (-not $p.WaitForExit(15000)) { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { } } }   # DEFECT: kill by name (pre-2026-10-03)' }
    'onedrivebyname' { $R['qd-onedrive']   = Set-GuardLine $R['qd-onedrive']   'onedrivebyname' '    $run | Stop-Process -Force -ErrorAction SilentlyContinue   # DEFECT: kill by name (pre-2026-10-03)' }
    'overlaybyname'  { $R['ov-stop']       = Set-GuardLine $R['ov-stop']       'overlaybyname'  'Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue   # DEFECT: kill by name (pre-2026-10-03)' }
    default { Write-Host "FAIL unknown -Defect '$Defect'"; exit 1 }
}
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('procown-sites-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$F = @{}
foreach ($k in $R.Keys) {
    $F[$k] = Join-Path $tmpRoot "$k.ps1"
    [IO.File]::WriteAllLines($F[$k], [string[]]$R[$k], [Text.UTF8Encoding]::new($false))
}

# --- the fake world ------------------------------------------------------------------------------------------------
$script:W = $null
function New-World {
    param([hashtable[]]$Services = @(), [hashtable[]]$Procs = @())
    $w = @{ svc = @{}; proc = @{}; now = [datetime]'2026-10-03 12:00:00'
            log = [System.Collections.Generic.List[string]]::new(); out = [System.Collections.Generic.List[string]]::new()
            kills = [System.Collections.Generic.List[string]]::new(); schtasks = [System.Collections.Generic.List[string]]::new()
            sc = [System.Collections.Generic.List[string]]::new(); warns = [System.Collections.Generic.List[string]]::new()
            fails = [System.Collections.Generic.List[string]]::new(); requests = 0; byNameLookups = 0 }
    foreach ($s in $Services) {
        $d = @{ name = ''; status = 'Running'; start = 'Automatic'; pid = 0; stopWorks = $true; stopThrows = $false; procExitsOnStop = $true; stopTakesAgent = $false }
        foreach ($k in $s.Keys) { $d[$k] = $s[$k] }
        $w.svc[$d.name] = $d
    }
    foreach ($p in $Procs) {
        # ownedByService: the agent/helpers a NEW watchdog takes down with its service stop; exitsAfterWaits: a helper
        # that leaves on its own agent-liveness exit after that many WaitForExit/enumeration rounds (-1 = never).
        $d = @{ pid = 0; name = ''; alive = $true; killable = $true; honoursShutdown = $true; ownedByService = $false; exitsAfterWaits = -1; waits = 0 }
        foreach ($k in $p.Keys) { $d[$k] = $p[$k] }
        $w.proc[$d.pid] = $d
    }
    $script:W = $w
}
function Alive([string]$name = '*') { @($script:W.proc.Values | Where-Object { $_.alive -and $_.name -like $name } | ForEach-Object { $_.pid } | Sort-Object) }
function New-ProcObj([hashtable]$d) {
    $o = [pscustomobject]@{ Id = $d.pid; Name = $d.name; ProcessName = $d.name; Path = "C:\Program Files\Qubes Tools\bin\$($d.name).exe" }
    $o | Add-Member -MemberType ScriptProperty -Name HasExited -Value { -not $script:W.proc[$this.Id].alive }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param($ms)
        $d = $script:W.proc[$this.Id]
        $d.waits++
        if ($d.exitsAfterWaits -ge 0 -and $d.waits -ge $d.exitsAfterWaits) { $d.alive = $false }
        return (-not $d.alive)
    }
    $o | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $d = $script:W.proc[$this.Id]
        $script:W.kills.Add("handle:$($this.Id)")
        if ($d.killable) { $d.alive = $false } else { throw 'Access is denied' }
    }
    $o
}
# ---- mocks: the Windows the regions talk to, over $script:W ----
function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
    $s = $script:W.svc[$Name]
    if (-not $s) { return $null }
    # A ServiceController is a SNAPSHOT (status cached until Refresh); WaitForStatus watches the live world.
    $o = [pscustomobject]@{ Name = $Name; Status = $s.status; StartType = $s.start }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($st, $t) if ($script:W.svc[$this.Name].status -ne $st) { throw "timeout waiting for $st" } } -PassThru
}
function Stop-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    $s = $script:W.svc[$Name]
    if (-not $s) { return }
    if ($s.stopThrows) { throw "Cannot stop service '$Name' on computer '.' (the SCM is busy)" }
    if ($s.stopWorks) {
        $s.status = 'Stopped'
        if ($s.procExitsOnStop -and $s.pid -and $script:W.proc[$s.pid]) { $script:W.proc[$s.pid].alive = $false }
        if ($s.stopTakesAgent) { foreach ($d in $script:W.proc.Values) { if ($d.ownedByService) { $d.alive = $false } } }
    } else { $s.status = 'StopPending' }
}
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    if ($ClassName -ne 'Win32_Service' -or $Filter -notmatch "Name='([^']+)'") { return $null }
    $s = $script:W.svc[$Matches[1]]
    if (-not $s) { return $null }
    # Win32_Service.ProcessId is the service's pid while it runs (or is stopping) and 0 once it is Stopped.
    $p = 0
    if ($s.status -ne 'Stopped') { $p = $s.pid }
    [pscustomobject]@{ Name = $Matches[1]; ProcessId = [uint32]$p; State = $s.status }
}
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($Id) { foreach ($i in $Id) { $d = $script:W.proc[$i]; if ($d -and $d.alive) { New-ProcObj $d } }; return }
    $script:W.byNameLookups++
    foreach ($d in ($script:W.proc.Values | Sort-Object pid)) {
        if (-not $d.alive) { continue }
        # a by-name enumeration is also a liveness round for a helper that leaves on its own
        if ($d.exitsAfterWaits -ge 0) { $d.waits++; if ($d.waits -ge $d.exitsAfterWaits) { $d.alive = $false; continue } }
        foreach ($n in $Name) { if ($d.name -like $n) { New-ProcObj $d; break } }
    }
}
function Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [string[]]$Name, [int[]]$Id, [switch]$Force)
    process {
        $targets = @()
        if ($InputObject) { $targets += [int]$InputObject.Id }
        if ($Id) { $targets += $Id }
        if ($Name) { foreach ($d in $script:W.proc.Values) { foreach ($n in $Name) { if ($d.alive -and $d.name -like $n) { $targets += $d.pid } } } }
        foreach ($t in $targets) {
            $script:W.kills.Add("Stop-Process:$t")
            $d = $script:W.proc[$t]
            if ($d -and $d.killable) { $d.alive = $false }
        }
    }
}
function sc.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $script:W.sc.Add(($a -join ' '))
    $s = $null
    if ($a.Count -ge 2) { $s = $script:W.svc[$a[1]] }
    if (-not $s) { return }
    if ($a[0] -eq 'config') { $s.start = 'Disabled' }
    if ($a[0] -eq 'stop') {
        if ($s.stopWorks) { $s.status = 'Stopped'; if ($s.procExitsOnStop -and $s.pid -and $script:W.proc[$s.pid]) { $script:W.proc[$s.pid].alive = $false } }
        else { $s.status = 'StopPending' }
    }
}
function schtasks.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a) $script:W.schtasks.Add(($a -join ' ')) }
function Start-Sleep { param([int]$Seconds = 0, [int]$Milliseconds = 0) $script:W.now = $script:W.now.AddMilliseconds($Seconds * 1000 + $Milliseconds) }
function Get-Date { param([string]$Format) if ($Format) { return $script:W.now.ToString('HH:mm:ss') }; return $script:W.now }
function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:W.log.Add("[$Level] $Message") }
function Log($m, $lvl = 'INFO') { $script:W.log.Add("[$lvl] $m") }
function Warn { param([string]$Message) $script:W.warns.Add($Message) }
function Warn-DisplayBlackout { }
function Fail { param([string]$Message) $script:W.fails.Add($Message); throw "FAIL: $Message" }
function Set-Reg { param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$What) $script:changed++; Write-Output "SET    $What" }
function Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object) }   # the regions' Write-Host is noise here
# The installer's graceful request (mocked: on Linux the real one cannot reach the named event). An agent that honours
# QGA_SHUTDOWN exits; one that does not is returned as a survivor. Never kills.
function Invoke-MockRequest([int]$WaitMs) {
    $script:W.requests++
    $left = @()
    foreach ($d in @($script:W.proc.Values | Where-Object { $_.alive -and $_.name -eq 'gui-agent' })) {
        if ($d.honoursShutdown) { $d.alive = $false } else { $left += (New-ProcObj $d) }
    }
    return $left
}
function Request-GuiAgentExit { param([int]$WaitMs = 5000) Invoke-MockRequest $WaitMs }
function Logged([string]$pattern) { @($script:W.log | Where-Object { $_ -match $pattern }).Count -gt 0 }
$script:Result = $null; $script:GuiWatchdogSvc = 'QubesGuiWatchdog'; $script:GuiQuiesced = $false; $script:GuiQuiesceHeld = $false
$script:result = $null; $script:changed = 0; $SERVICE = 'QubesGuiWatchdog'; $AGENTPROC = 'gui-agent'; $POL = 'HKLM:\SOFTWARE\Policies\Microsoft'

# --- invokers: each dot-sources the helper copy the region's file provides, then the region -------------------------
function Invoke-InstSvcStop { param([string]$Name, [int]$TimeoutSec = 20, [switch]$TerminateSurvivor)
    . $F['inst-svcstop']
    if ($TerminateSurvivor) { return (Stop-ServiceProcess -Name $Name -TimeoutSec $TimeoutSec -TerminateSurvivor) }
    return (Stop-ServiceProcess -Name $Name -TimeoutSec $TimeoutSec)
}
function Invoke-InstXbm { param([switch]$FatalIfSurvives, [string]$Why = 'test')
    . $F['inst-svcstop']
    . $F['inst-xbm']
}
function Invoke-InstRuntime { . $F['inst-svcstop']; . $F['inst-runtime']; Stop-QwtRuntime }
function Invoke-InstQuiesce { . $F['inst-svcstop']; . $F['inst-quiesce'] }
function Invoke-InstReassert { . $F['inst-reassert'] }
function Invoke-Activate { param([switch]$RealRequest)
    . $F['act-fn']
    if (-not $RealRequest) { function Request-GuiAgentExit { param([int]$WaitMs = 5000) Invoke-MockRequest $WaitMs } }
    . $F['act-quiesce']
}
function Invoke-RealActivateRequest { . $F['act-fn']; return @(Request-GuiAgentExit -WaitMs 100) }
function Assert-GuiQuiesced([string]$When) {   # activate-idd's own assertion, as shipped (counting; throws naming the survivors)
    $live = @(Get-Process -Name 'gui-watchdog', 'gui-agent', 'wgcbroker', 'notifhost' -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0) { throw ("gui-agent quiesce is NOT holding $When (" + (($live | ForEach-Object { "$($_.ProcessName)/$($_.Id)" }) -join ', ') + ')') }
}
function Invoke-NetSetup { . $F['pv-netsetup'] }
function Invoke-OneDrive { . $F['qd-onedrive'] }
function Refresh-Runtime {
    $svc = Get-Service -Name $SERVICE -ErrorAction SilentlyContinue
    $script:result.service = $(if ($svc) { [string]$svc.Status } else { 'not-installed' })
    $script:result.agent_running = ((Alive 'gui-agent').Count -gt 0)
}
function Invoke-Overlay { . $F['ov-stop'] }

# ================================================================= svcstop: the installer's SCM-pid helper ==========
New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' })
$r = Invoke-InstSvcStop -Name 'QubesGuiWatchdog'
Check 'svcstop: a running service is stopped, its SCM pid (100) is waited on by handle and is gone; nothing is killed' `
      ($r.present -and $r.pid -eq 100 -and $r.stopped -and $r.gone -and -not $r.survivor -and $script:W.kills.Count -eq 0 -and (Alive).Count -eq 0) "r=$($r.detail) kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; procExitsOnStop = $false }) -Procs @(@{ pid = 100; name = 'gui-watchdog' })
$r = Invoke-InstSvcStop -Name 'QubesGuiWatchdog'
Check 'svcstop: a service process that outlives the stop is reported as the survivor (pid 100) and NOT killed without -TerminateSurvivor' `
      ($r.stopped -and -not $r.gone -and $r.survivor.Id -eq 100 -and $script:W.kills.Count -eq 0 -and ((Alive) -join ',') -eq '100' -and $r.detail -match 'STILL RUNNING') "r=$($r.detail) kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'xenbus_monitor'; pid = 100; procExitsOnStop = $false }) -Procs @(@{ pid = 100; name = 'xenbus_monitor_9_1_0_0' }, @{ pid = 101; name = 'xenbus_monitor_9_1_0_0' })
$r = Invoke-InstSvcStop -Name 'xenbus_monitor' -TimeoutSec 10 -TerminateSurvivor
Check 'svcstop: with -TerminateSurvivor the lingering service process is ended by ITS handle (pid 100) and is dead afterwards' `
      ($r.gone -and ($script:W.kills -join ',') -eq 'handle:100' -and -not $script:W.proc[100].alive -and $r.survivor -eq $null -and (Logged 'terminating THAT pid')) "r=$($r.detail) kills=$($script:W.kills -join ',') alive=$((Alive) -join ',')"
Check 'svcstop: a same-named process (pid 101) beside the service is never touched, even with -TerminateSurvivor' `
      ($script:W.proc[101].alive -and @($script:W.kills | Where-Object { $_ -match '101' }).Count -eq 0) "kills=$($script:W.kills -join ',')"

New-World
$r = Invoke-InstSvcStop -Name 'QubesGuiWatchdog'
Check 'svcstop: an absent service reports present=false, detail absent, and touches nothing' (-not $r.present -and $r.detail -eq 'absent' -and $script:W.kills.Count -eq 0) "r=$($r.detail)"

New-World -Services @(@{ name = 'xenbus_monitor'; pid = 0; status = 'Stopped'; start = 'Disabled' }) -Procs @(@{ pid = 102; name = 'xenbus_monitor_9_1_0_0' })
$r = Invoke-InstSvcStop -Name 'xenbus_monitor' -TerminateSurvivor
Check 'svcstop: an already-Stopped service (SCM pid 0) beside a same-named stray (pid 102): nothing is waited on or killed, detail says no pid' `
      ($r.present -and $r.pid -eq 0 -and $r.gone -and $r.detail -match 'none \(the SCM reported no pid\)' -and $script:W.kills.Count -eq 0 -and $script:W.proc[102].alive) "r=$($r.detail) kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopThrows = $true }) -Procs @(@{ pid = 100; name = 'gui-watchdog' })
$r = Invoke-InstSvcStop -Name 'QubesGuiWatchdog' -TimeoutSec 5
Check 'svcstop: a Stop-Service that throws is logged as WARN, the pid is still waited on, nothing is killed, stopped=false' `
      ((Logged '^\[WARN\] Stop-Service QubesGuiWatchdog threw') -and -not $r.stopped -and -not $r.gone -and $script:W.kills.Count -eq 0) "r=$($r.detail) log=$($script:W.log -join ' | ')"

# ================================================================= xbm: the installer's xenbus_monitor stop ==========
New-World -Services @(@{ name = 'xenbus_monitor'; pid = 400 }) -Procs @(@{ pid = 400; name = 'xenbus_monitor_9_1_0_0' })
$script:Result = @{ detail = @{} }; $thrown = ''
try { Invoke-InstXbm -FatalIfSurvives } catch { $thrown = "$_" }
Check 'xbm: clean - the service is disabled and stopped, its process gone, no survivors, no Fail' `
      ($thrown -eq '' -and (Alive).Count -eq 0 -and -not $script:Result.detail.ContainsKey('xenbus_monitor_survivors') -and $script:W.svc['xenbus_monitor'].start -eq 'Disabled' -and $script:W.kills.Count -eq 0) "thrown=$thrown alive=$((Alive) -join ',')"

New-World -Services @(@{ name = 'xenbus_monitor'; pid = 400; procExitsOnStop = $false }) -Procs @(@{ pid = 400; name = 'xenbus_monitor_9_1_0_0' })
$script:Result = @{ detail = @{} }; $thrown = ''
try { Invoke-InstXbm -FatalIfSurvives } catch { $thrown = "$_" }
Check 'xbm: the service process lingers - terminated by ITS pid (handle:400), nothing else, no survivors, no Fail' `
      ($thrown -eq '' -and ($script:W.kills -join ',') -eq 'handle:400' -and (Alive).Count -eq 0 -and -not $script:Result.detail.ContainsKey('xenbus_monitor_survivors')) "thrown=$thrown kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'xenbus_monitor'; pid = 0; status = 'Stopped'; start = 'Disabled' }) -Procs @(@{ pid = 777; name = 'xenbus_monitor_9_1_0_0' })
$script:Result = @{ detail = @{} }; $thrown = ''
try { Invoke-InstXbm -FatalIfSurvives -Why 'pre-msiexec' } catch { $thrown = "$_" }
Check 'xbm: an orphan monitor the SCM does not own (pid 777) is reported, left ALIVE, and refused under -FatalIfSurvives' `
      ($thrown -match 'xenbus_monitor STILL RUNNING' -and $thrown -match '\(777\)' -and $thrown -match 'NOT killed' -and $script:W.proc[777].alive -and $script:W.kills.Count -eq 0 -and (@($script:Result.detail.xenbus_monitor_survivors) -join ',') -eq '777') "thrown=$thrown alive=$((Alive) -join ',') kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'xenbus_monitor'; pid = 0; status = 'Stopped'; start = 'Disabled' }) -Procs @(@{ pid = 777; name = 'xenbus_monitor_9_1_0_0' })
$script:Result = @{ detail = @{} }; $thrown = ''
try { Invoke-InstXbm } catch { $thrown = "$_" }
Check 'xbm: the same orphan without -FatalIfSurvives is WARNed about with its pid and left ALIVE (no Fail)' `
      ($thrown -eq '' -and (Logged '^\[WARN\] xenbus_monitor STILL RUNNING.*\(777\).*NOT killed') -and $script:W.proc[777].alive -and $script:W.kills.Count -eq 0) "thrown=$thrown log=$($script:W.log -join ' | ')"

# ================================================================= runtime: Stop-QwtRuntime (pre-MSI) ================
New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopTakesAgent = $true }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; ownedByService = $true })
$script:Result = @{ detail = @{} }
Invoke-InstRuntime
Check 'runtime: a new watchdog takes its agent down with the service stop - nothing left, nothing killed, no survivors recorded' `
      ((Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and -not $script:Result.detail.ContainsKey('gui_runtime_survivors') -and (Logged 'service QubesGuiWatchdog: service=Stopped pid=100 process=gone')) "alive=$((Alive) -join ',') log=$($script:W.log -join ' | ')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $true })
$script:Result = @{ detail = @{} }
Invoke-InstRuntime
Check 'runtime: an old watchdog leaves the agent running; it is ASKED via QGA_SHUTDOWN and exits - nothing killed' `
      ($script:W.requests -eq 1 -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and -not $script:Result.detail.ContainsKey('gui_runtime_survivors')) "requests=$($script:W.requests) alive=$((Alive) -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $false })
$script:Result = @{ detail = @{} }
Invoke-InstRuntime
Check 'runtime: an agent that ignores QGA_SHUTDOWN under an old watchdog is reported in gui_runtime_survivors with its pid and left ALIVE' `
      ($script:Result.detail.gui_runtime_survivors -eq 'gui-agent/200' -and $script:W.proc[200].alive -and $script:W.kills.Count -eq 0 -and (Logged '^\[WARN\] still running after the service stop.*gui-agent/200.*NOT killed')) "detail=$($script:Result.detail.gui_runtime_survivors) alive=$((Alive) -join ',') kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; procExitsOnStop = $false }) -Procs @(@{ pid = 100; name = 'gui-watchdog' })
$script:Result = @{ detail = @{} }
Invoke-InstRuntime
Check 'runtime: a watchdog PROCESS that outlives its service stop is reported (gui-watchdog/100) and left ALIVE' `
      ($script:Result.detail.gui_runtime_survivors -eq 'gui-watchdog/100' -and $script:W.proc[100].alive -and $script:W.kills.Count -eq 0) "detail=$($script:Result.detail.gui_runtime_survivors) kills=$($script:W.kills -join ',')"

# ================================================================= quiesce: the stage-2 GUI quiesce =================
function Invoke-QuiesceCase { $script:Result = @{ detail = @{} }; $script:GuiQuiesced = $false; $script:GuiQuiesceHeld = $false; Invoke-InstQuiesce }
New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopTakesAgent = $true }) `
          -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; ownedByService = $true }, @{ pid = 300; name = 'wgcbroker'; ownedByService = $true }, @{ pid = 301; name = 'notifhost'; ownedByService = $true })
Invoke-QuiesceCase
Check 'quiesce: new watchdog - service stopped, tasks ended and deleted, helpers gone, GuiQuiesced and GuiQuiesceHeld, nothing killed' `
      ($script:GuiQuiesced -and $script:GuiQuiesceHeld -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and @($script:W.schtasks | Where-Object { $_ -match '^/End /TN Qubes-WgcBroker' }).Count -eq 1 -and @($script:W.schtasks | Where-Object { $_ -match '^/Delete /TN Qubes-NotifBridge' }).Count -eq 1 -and -not $script:Result.detail.ContainsKey('gui_quiesce_failed') -and $script:Result.detail.gui_quiesced_for_stage2 -eq $true) "alive=$((Alive) -join ',') schtasks=$($script:W.schtasks -join ' | ')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 0; status = 'Stopped' })
Invoke-QuiesceCase
Check 'quiesce: watchdog not running - nothing to quiesce, GuiQuiesced=false, the quiesce holds' `
      (-not $script:GuiQuiesced -and $script:GuiQuiesceHeld -and (Logged 'nothing to quiesce') -and $script:W.kills.Count -eq 0) "log=$($script:W.log -join ' | ')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopThrows = $true }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $true })
Invoke-QuiesceCase
Check 'quiesce: Stop-Service throws (SCM busy) - nothing is killed in its place; the watchdog process is reported in gui_quiesce_failed and left ALIVE' `
      (-not $script:GuiQuiesceHeld -and $script:Result.detail.gui_quiesce_failed -eq 'gui-watchdog' -and $script:W.proc[100].alive -and $script:W.kills.Count -eq 0 -and (Logged '^\[ERROR\] QUIESCE DID NOT HOLD.*gui-watchdog/100.*not killed')) "held=$($script:GuiQuiesceHeld) detail=$($script:Result.detail.gui_quiesce_failed) kills=$($script:W.kills -join ',') log=$($script:W.log -join ' | ')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopTakesAgent = $true }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $false })
Invoke-QuiesceCase
Check 'quiesce: a foreign agent that ignores QGA_SHUTDOWN is reported (QUIESCE DID NOT HOLD, gui-agent/200) and left ALIVE' `
      (-not $script:GuiQuiesceHeld -and $script:Result.detail.gui_quiesce_failed -eq 'gui-agent' -and $script:W.proc[200].alive -and $script:W.kills.Count -eq 0 -and (Logged 'QUIESCE DID NOT HOLD.*gui-agent/200') -and $script:W.requests -eq 1) "held=$($script:GuiQuiesceHeld) alive=$((Alive) -join ',') kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopTakesAgent = $true }) `
          -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; ownedByService = $true }, @{ pid = 300; name = 'wgcbroker'; exitsAfterWaits = 3 }, @{ pid = 301; name = 'notifhost'; exitsAfterWaits = 5 })
Invoke-QuiesceCase
Check 'quiesce: helpers that leave on their own agent-liveness exits within the bounded wait make the quiesce hold; nothing killed' `
      ($script:GuiQuiesceHeld -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and $script:W.now -lt ([datetime]'2026-10-03 12:00:00').AddSeconds(40)) "held=$($script:GuiQuiesceHeld) alive=$((Alive) -join ',') now=$($script:W.now)"

# ================================================================= reassert: before the display surgery ==============
New-World
$script:Result = @{ detail = @{} }
Invoke-InstReassert
Check 'reassert: nothing running - nothing recorded' (-not $script:Result.detail.ContainsKey('idd_gui_reappeared') -and $script:W.kills.Count -eq 0)

New-World -Procs @(@{ pid = 200; name = 'gui-agent' })
$script:Result = @{ detail = @{} }
Invoke-InstReassert
Check 'reassert: a reappeared agent is recorded in idd_gui_reappeared with its pid and left ALIVE' `
      ($script:Result.detail.idd_gui_reappeared -eq 'gui-agent/200' -and $script:W.proc[200].alive -and $script:W.kills.Count -eq 0 -and (Logged '^\[WARN\] the gui-agent came back during stage 2 \(gui-agent/200\).*not killed')) "detail=$($script:Result.detail.idd_gui_reappeared) kills=$($script:W.kills -join ',') log=$($script:W.log -join ' | ')"

# ================================================================= activate: guest/activate-idd.ps1 =================
function Invoke-ActivateCase { $script:result = [ordered]@{}; $script:GuiQuiesced = $false; $script:thrown = ''; try { Invoke-Activate } catch { $script:thrown = "$_" } }
New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100; stopTakesAgent = $true }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; ownedByService = $true }, @{ pid = 300; name = 'wgcbroker'; ownedByService = $true })
Invoke-ActivateCase
Check 'activate: new watchdog - the service is stopped and its pid waited on, Assert-GuiQuiesced passes, gui_quiesced=true, nothing killed' `
      ($script:thrown -eq '' -and $script:result['gui_quiesced'] -eq $true -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and (Logged 'QubesGuiWatchdog: service=Stopped pid=100 process=gone')) "thrown=$($script:thrown) alive=$((Alive) -join ',') log=$($script:W.log -join ' | ')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $true })
Invoke-ActivateCase
Check 'activate: old watchdog, the agent honours the QGA_SHUTDOWN request - quiesced, the assertion passes, nothing killed' `
      ($script:thrown -eq '' -and $script:W.requests -eq 1 -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0) "thrown=$($script:thrown) alive=$((Alive) -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent'; honoursShutdown = $false })
Invoke-ActivateCase
Check 'activate: a foreign agent that ignores QGA_SHUTDOWN makes Assert-GuiQuiesced refuse, naming gui-agent/200, and is left ALIVE' `
      ($script:thrown -match 'quiesce is NOT holding before staging the driver \(gui-agent/200\)' -and $script:W.proc[200].alive -and $script:W.kills.Count -eq 0) "thrown=$($script:thrown) alive=$((Alive) -join ',') kills=$($script:W.kills -join ',')"

New-World -Procs @(@{ pid = 200; name = 'gui-agent'; honoursShutdown = $true })
$left = @(Invoke-RealActivateRequest)
Check 'activate: the shipped Request-GuiAgentExit (real copy) with no reachable QGA_SHUTDOWN returns the agents, logs it, and kills nothing' `
      ($left.Count -eq 1 -and $left[0].Id -eq 200 -and $script:W.proc[200].alive -and $script:W.kills.Count -eq 0 -and (Logged 'QGA_SHUTDOWN not open.*nothing is killed')) "left=$($left.Count) kills=$($script:W.kills -join ',') log=$($script:W.log -join ' | ')"

# ================================================================= netsetup: pvnic-selfprime's QwtngNetSetup stop ====
New-World -Services @(@{ name = 'QwtngNetSetup'; pid = 500 }) -Procs @(@{ pid = 500; name = 'qwtng-netsetup' })
$out = @(Invoke-NetSetup)
Check 'netsetup: the service process exits on stop - nothing terminated, no WARNING, sc stop issued' `
      ($script:W.kills.Count -eq 0 -and (Alive).Count -eq 0 -and @($out | Where-Object { $_ -match 'WARNING' }).Count -eq 0 -and @($script:W.sc | Where-Object { $_ -eq 'stop QwtngNetSetup' }).Count -eq 1) "out=$($out -join ' | ') sc=$($script:W.sc -join ' | ')"

New-World -Services @(@{ name = 'QwtngNetSetup'; pid = 500; procExitsOnStop = $false }) -Procs @(@{ pid = 500; name = 'qwtng-netsetup' }, @{ pid = 501; name = 'qwtng-netsetup' })
$out = @(Invoke-NetSetup)
Check 'netsetup: the service process lingers - terminated by ITS pid (handle:500) with a WARNING naming it' `
      (($script:W.kills -join ',') -eq 'handle:500' -and -not $script:W.proc[500].alive -and @($out | Where-Object { $_ -match '^WARNING: qwtng-netsetup.exe \(pid 500' }).Count -eq 1) "kills=$($script:W.kills -join ',') out=$($out -join ' | ')"
Check 'netsetup: a same-named stray (pid 501) that is not the SCM pid is left ALIVE' ($script:W.proc[501].alive -and @($script:W.kills | Where-Object { $_ -match '501' }).Count -eq 0) "kills=$($script:W.kills -join ',')"

New-World -Procs @(@{ pid = 502; name = 'qwtng-netsetup' })
$out = @(Invoke-NetSetup)
Check 'netsetup: no service registered - nothing waited on, nothing terminated, a same-named process untouched' ($script:W.kills.Count -eq 0 -and $script:W.proc[502].alive) "kills=$($script:W.kills -join ',')"

# ================================================================= onedrive: guest/quiet-desktop.ps1 ===============
New-World -Procs @(@{ pid = 300; name = 'OneDrive' })
$script:changed = 0
$out = @(Invoke-OneDrive)
Check 'onedrive: the two policies are applied (changed=2) and the running instance (pid 300) is left ALIVE; the output says so' `
      ($script:changed -eq 2 -and $script:W.proc[300].alive -and $script:W.kills.Count -eq 0 -and @($out | Where-Object { $_ -match '^ok     OneDrive: 1 running instance\(s\) left running' }).Count -eq 1) "changed=$($script:changed) kills=$($script:W.kills -join ',') out=$($out -join ' | ')"

New-World
$script:changed = 0
$out = @(Invoke-OneDrive)
Check 'onedrive: no running instance - the policies are applied and nothing is said about instances' ($script:changed -eq 2 -and @($out | Where-Object { $_ -match 'instance' }).Count -eq 0) "out=$($out -join ' | ')"

# ================================================================= overlay: packaging/payload/install-qwt-improved.ps1
New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' })
$script:result = [ordered]@{ service = $null; agent_running = $false }
Invoke-Overlay
Check 'overlay: the service is stopped through the SCM and its pid waited on; no agent to ask; nothing killed, no warnings' `
      ($script:W.svc['QubesGuiWatchdog'].status -eq 'Stopped' -and (Alive).Count -eq 0 -and $script:W.kills.Count -eq 0 -and $script:W.warns.Count -eq 0 -and $script:result.stopped_service -eq 'Stopped') "warns=$($script:W.warns -join ' | ') kills=$($script:W.kills -join ',')"

New-World -Services @(@{ name = 'QubesGuiWatchdog'; pid = 100 }) -Procs @(@{ pid = 100; name = 'gui-watchdog' }, @{ pid = 200; name = 'gui-agent' })
$script:result = [ordered]@{ service = $null; agent_running = $false }
Invoke-Overlay
# The stock watchdog leaves the agent; the overlay asks via the named event, which this Linux run cannot open - the
# shipped code then WARNS and kills nothing. Either way the agent is a reported survivor here.
Check 'overlay: an agent still running after the stop is warned about (pid 200 or the unreachable event) and left ALIVE; file replace is said to be at risk' `
      ($script:W.proc[200].alive -and $script:W.kills.Count -eq 0 -and $script:result.agent_running -eq $true -and @($script:W.warns | Where-Object { $_ -match 'not killed' }).Count -ge 1 -and @($script:W.warns | Where-Object { $_ -match 'file replace may fail' }).Count -ge 1) "warns=$($script:W.warns -join ' | ') kills=$($script:W.kills -join ',')"

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host "=== procown sites: $($script:run) checks, $($script:fail) failed$(if ($Defect) { " (defect knob '$Defect': a FAIL is the required outcome)" }) ==="
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
