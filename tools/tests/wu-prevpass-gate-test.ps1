<#
.SYNOPSIS
    Offline suite for qubes-windows-update.ps1's start gate on a CUT-OFF earlier pass (region WU-PREVPASS-GATE) - the owner's D3
    decision of 2026-10-02. Runs under pwsh on Linux or Windows PowerShell 5.1; no guest.

.DESCRIPTION
    THE DEFECT: until 2026-10-02 a status left at a non-terminal phase by a pass whose process was gone made EVERY later pass refuse,
    forever - only a completed pass rewrites the status, and the refusal prevented one. The scheduled scan's own PT20M limit produces
    that state on GWeck's template (first scans after servicing ran >25 and >66 min).
    THE DECISION: a cut-off SCAN never blocks; a pass cut off before the last restart proceeds; a pass cut off in THIS boot refuses once
    and requests one restart (reboot_needed on its own record). Both proceeding cases leave a note for dom0 (status field 'recovered').

    The region is extracted by its marker lines and run in a CHILD pwsh per scenario (it exits the process by contract), with the
    status file real (per scenario), and Test-WuOwnerAlive, Get-CimInstance (the boot time) and Write-Refusal as hooks:
      none          no status file                                    -> proceeds, no note
      finished      phase done                                        -> proceeds, no note
      live          phase install, owner alive                        -> proceeds (the mutex handles contention), no note
      scan-cut      a scan cut off in THIS boot                       -> proceeds, note "a scan installs nothing"
      prev-boot     a full pass cut off BEFORE the last restart       -> proceeds, note "before this qube's last restart"
      this-boot     a full pass cut off in THIS boot                  -> REFUSED state-unknown "Restart this qube once", exit 1,
                                                                         its record now carries reboot_needed=true, phase unchanged
      again         a second attempt in the same boot                 -> REFUSED again
      unreadable-ts the cut-off pass's timestamp cannot be read       -> REFUSED (one restart settles it either way)
      unreadable-after-restart  the same, refused in an EARLIER boot -> proceeds (the recorded refused_boot differs: the restart happened)
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
      oldgate     the pre-decision gate: the scan and earlier-boot rules disabled - every cut-off pass refuses (scan-cut, prev-boot FAIL)
      nothisboot  the this-boot refusal does not exit - a pass proceeds on top of possibly running servicing (this-boot FAILS)
      noreboot    the restart request is not recorded (this-boot's record check FAILS)
      norefusedboot  the refused_boot rule disabled - an unreadable-timing refusal repeats in every boot (unreadable-after-restart FAILS)
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'guest/qubes-windows-update.ps1' }
$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) { $script:run++; if (-not $ok) { $script:fail++ }; Write-Host ($(if ($ok) { 'ok   ' } else { 'FAIL ' }) + $name) }

$lines = @(Get-Content -LiteralPath $ScriptPath)
$b = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like '# ---- WU-PREVPASS-GATE-BEGIN*' })
$e = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like '# ---- WU-PREVPASS-GATE-END*' })
if ($b.Count -ne 1 -or $e.Count -ne 1 -or $b[0] -ge $e[0]) { Write-Host "FAIL marker extraction: $($b.Count)/$($e.Count)"; exit 1 }
$region = @($lines[($b[0] + 1)..($e[0] - 1)])
function Knob([string]$guard, [scriptblock]$replace) {
    $hit = @($region | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line, found $($hit.Count)"; exit 1 }
    $script:region = @($region | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { & $replace $_ } else { $_ } })
}
switch ($Defect) {
    '' { }
    'oldgate' {
        Knob 'prevscan' { param($l) $l -replace "if \(\`$prevAction -eq 'scan'\)", 'if ($false)' }
        Knob 'prevboot' { param($l) $l -replace 'elseif \(\$bootT -and \$lastKnown -and \$lastT -lt \$bootT\)', 'elseif ($false)' }
    }
    'nothisboot' { Knob 'thisboot' { param($l) '            # DEFECT: the refusal does not exit' } }
    'noreboot' {
        $hit = @($region | Where-Object { $_ -match 'Move-Item -LiteralPath "\$StatusFile\.tmp"' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect noreboot: the record write was not found"; exit 1 }
        $region = @($region | ForEach-Object { if ($_ -match 'Move-Item -LiteralPath "\$StatusFile\.tmp"') { '                # DEFECT: the request is not recorded' } else { $_ } })
    }
    'norefusedboot' { Knob 'refusedboot' { param($l) $l -replace 'elseif \(\$refusedBoot -and \$bootS -and \$refusedBoot -ne \$bootS\)', 'elseif ($false)' } }
    default { Write-Host "FAIL unknown -Defect '$Defect' (oldgate|nothisboot|noreboot|norefusedboot)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wu-prevpass-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$boot = '2026-10-02T19:00:00'
$preamble = @'
$ErrorActionPreference = 'Continue'
$StatusFile = '__STATUS__'
$Action = 'full'; $Scheduled = $false
$WU_TERMINAL_PHASES = @('done','error','diagnosing','skipped-unknown','skipped-standalone','skipped-appvm')
$script:St = [ordered]@{ action = 'full'; phase = 'init'; recovered = '' }
$script:OwnerAlive = __ALIVE__
function Test-WuOwnerAlive([int]$ownerPid, [string]$ownerStart) { return $script:OwnerAlive }
$script:Boot = [datetime]::ParseExact('__BOOT__', 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)]$ClassName) return [pscustomobject]@{ LastBootUpTime = $script:Boot } }
function Write-Refusal([string]$reason, [string]$message) { [Console]::Out.WriteLine("REFUSED|$reason|$message") }
'@
$post = @('[Console]::Out.WriteLine("PROCEED|" + $script:St.recovered)', 'exit 0')
function Scenario([string]$name, $status, [bool]$alive, [switch]$keep) {
    $dir = Join-Path $tmpRoot $name
    if (-not $keep) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sf = Join-Path $dir 'update-status.json'
    if (-not $keep) { if ($null -ne $status) { ($status | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $sf -Encoding UTF8 } }
    $src = $preamble.Replace('__STATUS__', $sf.Replace("'", "''")).Replace('__ALIVE__', $(if ($alive) { '$true' } else { '$false' })).Replace('__BOOT__', $boot)
    $file = Join-Path $dir 'scenario.ps1'
    [IO.File]::WriteAllLines($file, [string[]](@($src) + $region + $post), [Text.UTF8Encoding]::new($false))
    $out = Join-Path $dir 'stdout.txt'
    $p = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-File', $file) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError (Join-Path $dir 'stderr.txt')
    $so = @(); if (Test-Path $out) { $so = @(Get-Content -LiteralPath $out) }
    $after = $null; if (Test-Path $sf) { try { $after = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json } catch { } }
    return [pscustomobject]@{ rc = $p.ExitCode; proceed = @($so | Where-Object { $_ -like 'PROCEED|*' }); refused = @($so | Where-Object { $_ -like 'REFUSED|*' }); after = $after; dir = $dir }
}
function St([string]$action, [string]$phase, [string]$ts) { return @{ action = $action; phase = $phase; ts = $ts; owner_pid = 3548; owner_pid_start = '2026-10-02T19:31:36'; reboot_needed = $false } }
$thisBoot = '2026-10-02T19:32:38'   # after $boot
$prevBoot = '2026-10-02T18:31:00'   # before $boot

$r = Scenario 'none' $null $false
Check 'none: no status -> proceeds, no note' ($r.rc -eq 0 -and $r.proceed.Count -eq 1 -and $r.proceed[0] -eq 'PROCEED|')
$r = Scenario 'finished' (St 'full' 'done' $thisBoot) $false
Check 'finished: phase done -> proceeds, no note' ($r.rc -eq 0 -and $r.proceed[0] -eq 'PROCEED|')
$r = Scenario 'live' (St 'full' 'install' $thisBoot) $true
Check 'live: owner alive -> proceeds to the mutex, no note' ($r.rc -eq 0 -and $r.proceed[0] -eq 'PROCEED|')
$r = Scenario 'scan-cut' (St 'scan' 'scan' $thisBoot) $false
$SCANCUT = 'scan-cut: a scan cut off in THIS boot -> proceeds at once with the note "a scan installs nothing"'
Check $SCANCUT ($r.rc -eq 0 -and $r.proceed.Count -eq 1 -and $r.proceed[0] -like "PROCEED|*'scan'*cut off at phase 'scan'*a scan installs nothing*continuing")
$r = Scenario 'prev-boot' (St 'full' 'install' $prevBoot) $false
$PREVBOOT = 'prev-boot: a full pass cut off before the last restart -> proceeds with the note "before this qube''s last restart"'
Check $PREVBOOT ($r.rc -eq 0 -and $r.proceed.Count -eq 1 -and $r.proceed[0] -like "PROCEED|*'full'*cut off at phase 'install'*before this qube's last restart*settled; continuing")
$r = Scenario 'this-boot' (St 'full' 'install' $thisBoot) $false
$THISBOOT = 'this-boot: a full pass cut off in THIS boot -> REFUSED state-unknown, "Restart this qube once", exit 1'
Check $THISBOOT ($r.rc -eq 1 -and $r.proceed.Count -eq 0 -and $r.refused.Count -eq 1 -and $r.refused[0] -like 'REFUSED|state-unknown|QWTUPDSTATEUNKNOWN:*in THIS boot*Restart this qube once, then update again*')
Check 'this-boot: the cut-off pass''s record now requests the restart (reboot_needed=true) and stays non-terminal (phase install)' `
      ($null -ne $r.after -and $r.after.reboot_needed -eq $true -and $r.after.phase -eq 'install')
$r2 = Scenario 'this-boot' $null $false -keep
Check 'again: a second attempt in the same boot is refused the same way' ($r2.rc -eq 1 -and $r2.refused.Count -eq 1)
$r = Scenario 'unreadable-ts' (St 'full' 'download' 'not-a-time') $false
Check 'unreadable-ts: the timing cannot be read -> REFUSED (one restart settles it either way)' ($r.rc -eq 1 -and $r.refused.Count -eq 1)
$rb = $null; if ($null -ne $r.after) { $rb = $r.after.refused_boot; if ($rb -is [datetime]) { $rb = $rb.ToString('s') } }
Check 'unreadable-ts: the refusal records the boot it was made in (refused_boot)' ("$rb" -eq $boot)
$ur = St 'full' 'download' 'not-a-time'; $ur.refused_boot = '2026-10-02T17:00:00'; $ur.reboot_needed = $true
$r3 = Scenario 'unreadable-after-restart' $ur $false
$AFTERRESTART = 'unreadable-after-restart: refused in an earlier boot, the qube restarted since -> proceeds with a note (no dead end)'
Check $AFTERRESTART ($r3.rc -eq 0 -and $r3.proceed.Count -eq 1 -and $r3.proceed[0] -like "PROCEED|*refused it in an earlier boot (2026-10-02T17:00:00)*which has happened*continuing")
Check 'contract: refusals and notes end in words, never a bare number (dom0 float-parses stderr)' `
      (@(($r.refused + $r2.refused) | Where-Object { $_ -match '\s[0-9]+([.,][0-9]+)?$' }).Count -eq 0)

Remove-Item -Recurse -Force $tmpRoot -EA SilentlyContinue
Write-Host ("--- {0} checks, {1} failed" -f $script:run, $script:fail)
if ($script:fail) { exit 1 }
exit 0
