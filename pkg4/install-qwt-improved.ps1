<#
.SYNOPSIS
    Install the improved Qubes GUI agent over an existing Qubes Windows Tools 4.2.2 install.

.DESCRIPTION
    This is an OVERLAY updater, not a full Qubes Windows Tools installer. It replaces
    individual QWT user-mode binaries in place and keeps a .orig backup of every file it
    touches, so -Restore puts the shipped binaries back exactly.

    It does NOT install, upgrade or remove:
      * Qubes Windows Tools itself (QWT 4.2.2 must already be installed and working),
      * the Xen PV drivers (xenbus/xeniface/xenvif/xennet/xenvbd),
      * qrexec-agent, qubesdb-daemon, the RPC handlers, or any registry/service layout.
    See README.md for exactly why, and for the fresh-machine install sequence.

    Run ELEVATED. Safe to run repeatedly: if the target files already match the package,
    nothing is stopped, copied or restarted.

.PARAMETER Components
    Which binaries to install. Default: agent.
      agent     gui-agent.exe    <- the only binary this project actually changed
      watchdog  gui-watchdog.exe <- rebuild of UNCHANGED upstream source; off by default
      all       both
    -Restore accepts the same values and restores exactly those.

.PARAMETER Status
    Report current state and exit without changing anything. Does not require elevation.

.PARAMETER Restore
    Put the .orig backups back (reverse of an install).

.PARAMETER PackageRoot
    Root of the unpacked package. Defaults to the directory containing this script.

.PARAMETER BinDir
    QWT bin directory. Auto-detected from HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools
    (GuiAgentPath, then InstallDir); falls back to C:\Program Files\Qubes Tools\bin.

.PARAMETER Force
    Reinstall even when the installed files already match the package.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-qwt-improved.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-qwt-improved.ps1 -Restore
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-qwt-improved.ps1 -Status

.OUTPUTS
    A human-readable transcript, then a line "=== RESULT ===" followed by a JSON object.
    Machine consumers should parse only what follows that marker.
#>
[CmdletBinding()]
param(
    [ValidateSet('agent', 'watchdog', 'all')]
    [string[]]$Components = @('agent'),
    [switch]$Restore,
    [switch]$Status,
    [string]$PackageRoot,
    [string]$BinDir,
    [switch]$Force
)

# Deliberately no Set-StrictMode: this script reads optional registry properties and
# optional dictionary keys, and a strict-mode PropertyNotFound on a cosmetic field must
# never be able to abort a run that has already replaced a binary.
$ErrorActionPreference = 'Continue'

$SERVICE   = 'QubesGuiWatchdog'
$AGENTPROC = 'gui-agent'
$STATEFILE = 'qwt-improved-state.json'

# Component table: logical name -> file name. Extend here if a future phase changes more
# QWT binaries; everything below is driven off this map.
$COMPONENT_FILES = [ordered]@{
    agent    = 'gui-agent.exe'
    watchdog = 'gui-watchdog.exe'
}

$result = [ordered]@{
    action          = $(if ($Status) { 'status' } elseif ($Restore) { 'restore' } else { 'install' })
    script_version  = 1
    ok              = $false
    elevated        = $false
    bin_dir         = $null
    package_root    = $null
    manifest        = $null
    requested       = @()
    components      = [ordered]@{}
    service         = $null
    agent_running   = $false
    agent_path      = $null
    already_current = $false
    changed         = $false
    log             = [ordered]@{}
    warnings        = @()
    errors          = @()
}

function Emit-Result {
    param([int]$ExitCode = 0)
    Write-Output '=== RESULT ==='
    $result | ConvertTo-Json -Depth 6
    exit $ExitCode
}
function Fail {
    param([string]$Message)
    $result.errors += $Message
    Write-Warning $Message
    Emit-Result -ExitCode 1
}
function Warn {
    param([string]$Message)
    $result.warnings += $Message
    Write-Warning $Message
}
function Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
    catch { return $null }
}
function FileFacts {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $i = Get-Item -LiteralPath $Path
    return [ordered]@{
        path    = $i.FullName
        size    = $i.Length
        version = $i.VersionInfo.FileVersion
        sha256  = Sha256 $Path
        mtime   = $i.LastWriteTimeUtc.ToString('o')
    }
}

# ---------------------------------------------------------------- resolve what to act on
if ($Components -contains 'all') { $selected = @($COMPONENT_FILES.Keys) }
else { $selected = @($Components | Select-Object -Unique) }
$result.requested = $selected

# ---------------------------------------------------------------- locate the package
if (-not $PackageRoot) {
    if ($PSScriptRoot) { $PackageRoot = $PSScriptRoot }
    else { $PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }
}
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot -ErrorAction SilentlyContinue).Path
$result.package_root = $PackageRoot

$manifestPath = Join-Path $PackageRoot 'MANIFEST.json'
if (Test-Path -LiteralPath $manifestPath) {
    try { $result.manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { Warn "MANIFEST.json present but unparseable: $($_.Exception.Message)" }
} elseif (-not $Status) {
    Warn 'MANIFEST.json not found next to the script - package provenance unknown.'
}

# ---------------------------------------------------------------- locate the QWT bin dir
if (-not $BinDir) {
    $key = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
    $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties['GuiAgentPath'] -and $p.GuiAgentPath) {
        $BinDir = Split-Path -Parent $p.GuiAgentPath
    } elseif ($p -and $p.PSObject.Properties['InstallDir'] -and $p.InstallDir) {
        $BinDir = Join-Path $p.InstallDir 'bin'
    } else {
        $BinDir = 'C:\Program Files\Qubes Tools\bin'
        Warn "Qubes Tools registry key not found; falling back to $BinDir"
    }
}
$result.bin_dir = $BinDir
if (-not (Test-Path -LiteralPath $BinDir)) {
    Fail "Qubes Windows Tools bin directory not found: $BinDir - install QWT first (see README.md)."
}

$statePath = Join-Path (Split-Path -Parent $BinDir) $STATEFILE

# ---------------------------------------------------------------- gather per-component state
$plan = @()
foreach ($name in $selected) {
    if (-not $COMPONENT_FILES.Contains($name)) { Fail "unknown component: $name" }
    $file   = $COMPONENT_FILES[$name]
    $target = Join-Path $BinDir $file
    $backup = "$target.orig"
    $source = Join-Path (Join-Path $PackageRoot 'bin') $file

    $entry = [ordered]@{
        file          = $file
        target        = $target
        backup        = $backup
        source        = $source
        source_exists = (Test-Path -LiteralPath $source)
        source_sha256 = Sha256 $source
        installed     = FileFacts $target
        backup_facts  = FileFacts $backup
        state         = 'unknown'
        action        = 'none'
    }
    if (-not $entry.installed) {
        $entry.state = 'missing-target'
    } elseif ($entry.source_sha256 -and $entry.installed.sha256 -eq $entry.source_sha256) {
        $entry.state = 'package'
    } elseif ($entry.backup_facts -and $entry.installed.sha256 -eq $entry.backup_facts.sha256) {
        $entry.state = 'original'
    } else {
        $entry.state = 'other'
    }
    $result.components[$name] = $entry
    $plan += , @{ name = $name; entry = $entry }
}

function Refresh-Runtime {
    $svc = Get-Service -Name $SERVICE -ErrorAction SilentlyContinue
    $result.service = $(if ($svc) { $svc.Status.ToString() } else { 'not-installed' })
    $proc = @(Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue)
    $result.agent_running = ($proc.Count -gt 0)
    if ($proc.Count -gt 0) {
        try { $result.agent_path = $proc[0].Path } catch { $result.agent_path = $null }
    } else { $result.agent_path = $null }
}
Refresh-Runtime

# newest gui-agent log, useful for judging whether the agent came back healthy
function Refresh-Log {
    $logDir = $null
    $p = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties['LogDir'] -and $p.LogDir) { $logDir = $p.LogDir }
    if (-not $logDir) { $logDir = Join-Path (Split-Path -Parent $BinDir) 'log' }
    $result.log.dir = $logDir
    $l = Get-ChildItem -LiteralPath $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) {
        $result.log.newest = $l.Name
        $result.log.age_seconds = [int]((Get-Date) - $l.LastWriteTime).TotalSeconds
        # Cast to plain strings: Get-Content decorates each line with PSPath/ReadCount note
        # properties, and ConvertTo-Json would serialise the whole provider object tree.
        $result.log.tail = [string[]]@(Get-Content -LiteralPath $l.FullName -Tail 12 -ErrorAction SilentlyContinue |
                                       ForEach-Object { $_.ToString() })
    } else {
        $result.log.newest = $null
    }
}

if ($Status) {
    Refresh-Log
    $result.ok = $true
    Emit-Result
}

# ---------------------------------------------------------------- elevation (mutating paths)
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$result.elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $result.elevated) {
    Fail 'not elevated - re-run this script from an elevated PowerShell (Run as administrator).'
}

# ---------------------------------------------------------------- validate the plan
foreach ($p in $plan) {
    $e = $p.entry
    if ($Restore) {
        if (-not $e.backup_facts) {
            Fail "no backup to restore for $($e.file) (expected $($e.backup)) - nothing was ever installed by this script, or the backup was deleted."
        }
        if ($e.state -eq 'original') { $e.action = 'already-original' } else { $e.action = 'restore' }
    } else {
        if (-not $e.source_exists) { Fail "package is incomplete: missing $($e.source)" }
        if ((Get-Item -LiteralPath $e.source).Length -lt 1024) { Fail "package file looks truncated: $($e.source)" }
        $hdr = [byte[]](Get-Content -LiteralPath $e.source -Encoding Byte -TotalCount 2)
        if ($hdr[0] -ne 0x4D -or $hdr[1] -ne 0x5A) { Fail "package file is not a Windows executable: $($e.source)" }
        if (-not $e.installed) { Fail "target not present: $($e.target) - this package overlays an existing QWT install." }
        if ($e.state -eq 'package' -and -not $Force) { $e.action = 'already-current' } else { $e.action = 'install' }
    }
}

$needWork = @($plan | Where-Object { $_.entry.action -in @('install', 'restore') })
if ($needWork.Count -eq 0) {
    $result.already_current = $true
    Refresh-Runtime
    Refresh-Log
    # Idempotent no-op, but still make sure the service is actually up.
    if ($result.service -ne 'Running') {
        Write-Host "Files already correct but service is $($result.service); starting it."
        Start-Service $SERVICE -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Refresh-Runtime
        $result.changed = $true
    }
    $result.ok = ($result.service -eq 'Running' -and $result.agent_running)
    if (-not $result.ok) { $result.errors += 'nothing to do, but the GUI agent is not running' }
    Write-Host 'Nothing to do: installed files already match the requested state.'
    Emit-Result -ExitCode $(if ($result.ok) { 0 } else { 1 })
}

# ---------------------------------------------------------------- stop
Write-Host "Stopping $SERVICE ..."
Stop-Service $SERVICE -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) {
    $s = Get-Service -Name $SERVICE -ErrorAction SilentlyContinue
    if (-not $s -or $s.Status -eq 'Stopped') { break }
    Start-Sleep -Seconds 1
}
# The watchdog respawns gui-agent.exe in the interactive session, so it must be gone first.
Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Refresh-Runtime
$result.stopped_service = $result.service
if ($result.agent_running) { Warn 'gui-agent still running after stop; file replace may fail' }

# ---------------------------------------------------------------- copy (with retries: a
# freshly-exited process can still hold the image file for a moment)
function Copy-WithRetry {
    param([string]$From, [string]$To, [int]$Tries = 6)
    for ($i = 1; $i -le $Tries; $i++) {
        try { Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop; return $true }
        catch { Start-Sleep -Seconds 2 }
    }
    return $false
}

foreach ($p in $needWork) {
    $e = $p.entry
    if ($e.action -eq 'install') {
        if (-not $e.backup_facts) {
            if (-not (Copy-WithRetry $e.target $e.backup)) { Fail "could not create backup $($e.backup)" }
            $e.backup_created = $true
            Write-Host "Backed up $($e.file) -> $(Split-Path -Leaf $e.backup)"
        } else {
            $e.backup_created = $false   # never overwrite an existing .orig
        }
        if (-not (Copy-WithRetry $e.source $e.target)) { Fail "could not replace $($e.target)" }
        Write-Host "Installed $($e.file)"
    } else {
        if (-not (Copy-WithRetry $e.backup $e.target)) { Fail "could not restore $($e.target)" }
        Write-Host "Restored $($e.file) from backup"
    }
    $result.changed = $true
}

# ---------------------------------------------------------------- start + verify
Write-Host "Starting $SERVICE ..."
Start-Service $SERVICE -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) {
    $s = Get-Service -Name $SERVICE -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq 'Running') { break }
    Start-Sleep -Seconds 1
}
# The watchdog only spawns gui-agent once a user session is present; give it a while.
for ($i = 0; $i -lt 30; $i++) {
    if (@(Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue).Count -gt 0) { break }
    Start-Sleep -Seconds 1
}
Refresh-Runtime
Refresh-Log

# re-read what is actually on disk now and check it against what we intended
$verified = $true
foreach ($p in $plan) {
    $e = $p.entry
    $e.installed_after = FileFacts $e.target
    $want = $(if ($e.action -eq 'restore' -or $e.action -eq 'already-original') { $e.backup_facts.sha256 } else { $e.source_sha256 })
    $e.verified = ($e.installed_after -and $e.installed_after.sha256 -eq $want)
    if (-not $e.verified) { $verified = $false; $result.errors += "post-install hash mismatch for $($e.file)" }
}

$result.ok = ($verified -and $result.service -eq 'Running' -and $result.agent_running)
if (-not $result.ok) {
    if ($result.service -ne 'Running') { $result.errors += "service $SERVICE is $($result.service)" }
    if (-not $result.agent_running)    { $result.errors += 'gui-agent.exe is not running' }
}

# ---------------------------------------------------------------- state file
try {
    $state = [ordered]@{
        updated  = (Get-Date).ToUniversalTime().ToString('o')
        bin_dir  = $BinDir
        action   = $result.action
        manifest = $result.manifest
        files    = [ordered]@{}
    }
    foreach ($p in $plan) {
        $e = $p.entry
        $state.files[$e.file] = [ordered]@{
            action  = $e.action
            sha256  = $(if ($e.installed_after) { $e.installed_after.sha256 } else { $null })
            backup  = $e.backup
        }
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
    $result.state_file = $statePath
} catch {
    Warn "could not write state file $statePath : $($_.Exception.Message)"
}

if ($result.ok) {
    Write-Host ''
    Write-Host 'OK. Now confirm the desktop is still live from dom0 (window drag / qvm-run a GUI app).'
} else {
    Write-Host ''
    Write-Host 'FAILED. Re-run with -Restore to put the shipped binaries back.'
}
Emit-Result -ExitCode $(if ($result.ok) { 0 } else { 1 })
