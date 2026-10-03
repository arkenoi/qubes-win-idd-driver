<#
.SYNOPSIS
    Offline suite for the relay-replacement step of guest/install-updater-agent.ps1 (the WU-INSTALLER-RELAY-WAIT
    region): the installer kills nothing. Holding the updater mutex, it waits, bounded, for 127.0.0.1:8082's
    listener to go away; a listener that remains is NOT killed - the relay compile is skipped, the previous exe
    is kept, and the pid is named. Runs under pwsh on Linux or Windows PowerShell 5.1; no rig, no guest, no csc.

.DESCRIPTION
    THE DEFECT (docs/ADR-updater.md 12.4, 2026-10-03): before recompiling the relay the installer ran
    `Get-Process -Name 'qubes-updates-relay' | Stop-Process -Force` - every process with that name, whoever
    started it. Its reason was real (a running relay holds the exe open; the move then fails, measured
    2026-08-25) and is now met by waiting for the pass's relay to exit by its own --parent-pid watchdog.

    The suite extracts the region by its marker lines (never by brace-hunting) and dot-sources it per
    scenario at script scope, under a scripted TCP table (Get-NetTCPConnection), recording process stubs
    (Get-Process by name and Stop-Process record every call, so a knob that restores the kill is seen), a
    no-op Start-Sleep and a captured Log. Live de-DE culture.
      exits-on-own    8082 held by pid 4711, free after 3 lookups -> the wait ends, compile NOT skipped, the
                      exit is logged as "not killed", nothing killed, nothing looked up by name
      free            8082 free -> one lookup, no wait, compile not skipped, no relay line logged
      survivor        pid 4711 never leaves and a previous exe exists -> no kill, compile SKIPPED, the exe
                      kept, QWTRELAYBUSY logged with the pid and the process name read by pid
      survivor-noexe  the same with no previous exe -> throws QWTRELAYBUSY naming the pid; nothing compiled,
                      nothing killed
      unknown         the TCP table cannot be read -> treated as a possible relay: skip (exe) / throw (no exe)
      shipped         the compile block is gated on $skipRelayCompile; no by-name kill is left in the installer
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the pre-2026-10-03 behaviour in the extracted copy (the shipped file is never modified):
      1   `# GUARD:relaynokill`  the kill by name is back and the survivor branch never runs -> the survivor
                                 cases must FAIL (Stop-Process recorded, compile not skipped)
      2   `# GUARD:relaywait`    no wait at all -> exits-on-own is reported as a survivor
    tools/tests/wu-installer-relay-selftest.sh runs the clean leg and both knobs and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'guest/install-updater-agent.ps1' }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}

$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- extract the region by its marker lines ------------------------------------------------------------
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
$region = Get-Region 'WU-INSTALLER-RELAY-WAIT'
Check 'extract: the region reads the port owner, waits and decides (Get-RelayPortOwner, GUARD:relaywait, GUARD:relaynokill once each)' `
      (@($region | Where-Object { $_ -match '^function Get-RelayPortOwner\b' }).Count -eq 1 -and
       @($region | Where-Object { $_ -match '# GUARD:relaywait$' }).Count -eq 1 -and @($region | Where-Object { $_ -match '# GUARD:relaynokill$' }).Count -eq 1)

# --- shipped: the compile is gated, the by-name kill is gone -------------------------------------------------
$codeLines = @($lines | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '\s#')[0] })
Check 'shipped: no by-name Get-Process and no Stop-Process is left in the installer''s code lines' `
      (@($codeLines | Where-Object { $_ -match 'Get-Process(?!\s+-Id\b)' -or $_ -match 'Stop-Process|taskkill' }).Count -eq 0)
Check 'shipped: the compile block is gated on $skipRelayCompile and the skip keeps the previous exe' `
      (@($codeLines | Where-Object { $_ -match '^\s*if \(\$skipRelayCompile\) \{' }).Count -eq 1 -and @($lines | Where-Object { $_ -like '*kept the previous relay exe*' }).Count -eq 1)

switch ($Defect) {
    '' { }
    '1' {
        $region = @($region | ForEach-Object {
            if ($_ -match '# GUARD:relaynokill$') { "Get-Process -Name 'qubes-updates-relay' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; if (`$false) {   # DEFECT: kill by name (pre-2026-10-03)" }
            else { $_ } })
    }
    '2' {
        $region = @($region | ForEach-Object { if ($_ -match '# GUARD:relaywait$') { '# DEFECT: no wait for the watchdog' } else { $_ } })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (1|2)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wu-installer-relay-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$regionFile = Join-Path $tmpRoot 'installer-region.ps1'
[IO.File]::WriteAllLines($regionFile, [string[]]$region, [Text.UTF8Encoding]::new($false))

# --- the fake world ---------------------------------------------------------------------------------------------
function Reset-World([int]$owner, [int]$goneAfter, [bool]$exeExists, [string]$unknown = '') {
    $script:Calls = @(); $script:Logs = @()
    $script:PortOwnerPid = $owner; $script:PortGoneAfter = $goneAfter; $script:PortLookups = 0; $script:PortUnknown = $unknown
    $script:exe = Join-Path $tmpRoot ('relay-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.exe')
    if ($exeExists) { [IO.File]::WriteAllText($script:exe, 'previous') }
    $script:skipRelayCompile = $null
}
function Get-NetTCPConnection { [CmdletBinding()] param($LocalPort, $State)
    $script:PortLookups++
    $script:Calls += 'Get-NetTCPConnection 8082'
    if ($script:PortUnknown -eq 'throw') { throw "The term 'Get-NetTCPConnection' is not recognized" }
    if ($script:PortUnknown -eq 'error') { Write-Error -Message 'Zugriff verweigert' -Category PermissionDenied; return }
    if ($script:PortOwnerPid -le 0 -or ($script:PortGoneAfter -ge 0 -and $script:PortLookups -gt $script:PortGoneAfter)) {
        Write-Error -Message "No MSFT_NetTCPConnection objects found with property 'LocalPort' equal to '8082'" -Category ObjectNotFound; return
    }
    return ,([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8082; State = 'Listen'; OwningProcess = [uint32]$script:PortOwnerPid })
}
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $script:Calls += "Get-Process -Id $Id"
        if ([int]$Id[0] -eq 4711) { return [pscustomobject]@{ Id = 4711; ProcessName = 'qubes-updates-relay'; Path = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe' } }
        return $null
    }
    $script:Calls += "Get-Process $Name"   # BY NAME - recorded so the knob is seen
    $p = [pscustomobject]@{ Id = 4711; ProcessName = 'qubes-updates-relay' }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:Calls += 'Kill 4711' }
    return ,$p
}
function Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { if ($InputObject) { $script:Calls += "Stop-Process $($InputObject.Id)" } }
}
function Log($m) { $script:Logs += "$m" }
function Start-Sleep { [CmdletBinding()] param($Seconds, $Milliseconds) }
function Count-Calls([string]$like) { return @($script:Calls | Where-Object { $_ -like $like }).Count }
function Test-NothingKilled { return ((Count-Calls 'Stop-Process *') -eq 0 -and (Count-Calls 'Kill *') -eq 0 -and @($script:Calls | Where-Object { $_ -like 'Get-Process *' -and $_ -notlike 'Get-Process -Id *' }).Count -eq 0) }

# --- 1. exits-on-own: the dead pass's relay leaves by its own watchdog while the installer waits ---------------------
Reset-World 4711 3 $true
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
Check 'exits-on-own: the installer waits for 8082''s owner to go away (4 lookups: held, held, held, free) and does not skip the compile' `
      ($script:Thrown -eq '' -and (Count-Calls 'Get-NetTCPConnection 8082') -eq 4 -and $script:skipRelayCompile -eq $false)
Check 'exits-on-own: the exit is logged as the relay''s own, with its pid, "not killed"' `
      (@($script:Logs | Where-Object { $_ -like 'a relay (pid 4711) was still listening on 127.0.0.1:8082 and exited on its own after * ms - not killed' }).Count -eq 1)
Check 'exits-on-own: nothing was killed and nothing looked up by name' (Test-NothingKilled)

# --- 2. free: nobody on 8082 ------------------------------------------------------------------------------------------------
Reset-World 0 -1 $true
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
Check 'free: one lookup, no wait, compile not skipped, no relay line logged' `
      ($script:Thrown -eq '' -and (Count-Calls 'Get-NetTCPConnection 8082') -eq 1 -and $script:skipRelayCompile -eq $false -and $script:Logs.Count -eq 0 -and (Test-NothingKilled))

# --- 3. survivor: a listener that never leaves, with a previous exe to keep ------------------------------------------------------
Reset-World 4711 -1 $true
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
$SURV = 'survivor: a listener still on 8082 after the bound is NOT killed: compile skipped, previous exe kept'
Check $SURV ($script:Thrown -eq '' -and $script:skipRelayCompile -eq $true -and (Test-Path -LiteralPath $script:exe) -and (Test-NothingKilled))
Check 'survivor: the wait ran its full bound (41 lookups = 1 + 40 x 500 ms)' ((Count-Calls 'Get-NetTCPConnection 8082') -eq 41)
Check 'survivor: QWTRELAYBUSY is logged with the pid, the name read BY PID, "NOT killed", the kept exe and the rerun advice' `
      (@($script:Logs | Where-Object { $_ -like 'QWTRELAYBUSY: pid 4711 (qubes-updates-relay at *) is still listening on 127.0.0.1:8082 after 20 s*NOT killed*' -and $_ -like "*previous exe at $($script:exe) is kept*" -and $_ -like '*rerun this deploy*' }).Count -eq 1)
Check 'survivor: the name was read by pid, never by name' ((Count-Calls 'Get-Process -Id 4711') -eq 1)

# --- 4. survivor-noexe: the same, with nothing to keep ----------------------------------------------------------------------------
Reset-World 4711 -1 $false
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
Check 'survivor-noexe: with no previous exe the deploy REFUSES (throws QWTRELAYBUSY naming pid 4711), nothing compiled, nothing killed' `
      ($script:Thrown -like 'QWTRELAYBUSY: pid 4711 (*) is still listening*No previous relay exe exists at *refusing - nothing compiled, nothing killed*' -and (Test-NothingKilled))
Check 'survivor-noexe: the refusal is also logged' (@($script:Logs | Where-Object { $_ -like 'QWTRELAYBUSY: pid 4711*' }).Count -eq 1)

# --- 5. unknown: the TCP table cannot be read ---------------------------------------------------------------------------------------
Reset-World 0 -1 $true 'throw'
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
Check 'unknown (exe): an unreadable port table is not "free" - compile skipped, the reason logged, nothing killed' `
      ($script:Thrown -eq '' -and $script:skipRelayCompile -eq $true -and @($script:Logs | Where-Object { $_ -like 'cannot read who listens on 127.0.0.1:8082*' }).Count -eq 1 -and (Test-NothingKilled))
Reset-World 0 -1 $false 'error'
$script:Thrown = ''; try { . $regionFile } catch { $script:Thrown = "$($_.Exception.Message)" }
Check 'unknown (no exe): the deploy refuses with the reason' ($script:Thrown -like 'cannot read who listens on 127.0.0.1:8082*No previous relay exe exists*' -and (Test-NothingKilled))

Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail) { exit 1 }
exit 0
