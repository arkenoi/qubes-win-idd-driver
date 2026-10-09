# health-logfresh-test.ps1 - the agent-log freshness anchor, run offline against a fake log tree.
#
# WHY. agent_log_healthy decided "is this the running agent's log?" from the FILE's metadata, and
# metadata is exactly what cannot answer it here. Measured 2026-10-09 on win11-acc:
#   * the live log is PER-DAY and APPENDED ('gui-agent-<yyyymmdd>.log'), so its name carries no
#     instance and the per-instance files beside it belong to OLDER instances;
#   * the clock flips once per boot, ~t+60 s, when sync-clock-from-dom0 lands - the agent's own
#     lines jump from 055237 to 025240 inside one file, and for the MINUTES AROUND THE FLIP the
#     boot stamp and the clock sit in different phases (+103 s and +54 s before, -10734 s just
#     after; the same guest read SKEW=835 thirteen minutes in, so the stamp re-derives later).
#     That window is exactly where the acceptance battery grades, ~103 s after its reboot;
#   * NTFS updates LastWriteTime LAZILY for an open handle - at 05:52:40 the directory entry still
#     read 02:07:10, the PREVIOUS boot's write, while the agent had already appended at 05:52:37.
# Those produced BOTH errors in the 4.3.36 gate: WIN11-clean FAILED with its agent running
# (boot_stamp_usable=true, skew=+103, logs_this_boot=0, newest=NONE), and the newest-by-mtime
# fallback PASSED five cells on a previous boot's file (mtime 05:00:17 outranking the live file at
# 02:55:04 because the stale stamp was an ahead-phase one).
# The anchor is now the agent's own pid in every line prefix - '[<date>.<time>.<ms>-<pid>:<tid>-<L>]'.
#
#   pwsh health-logfresh-test.ps1 -Script <path-to-health-check.ps1>
#   env LOGFRESH_DEFECT=mtime  restores the metadata logic - cases 1, 2 and 7 must then FAIL.
param([Parameter(Mandatory)][string]$Script)
$ErrorActionPreference = 'Continue'
$src = Get-Content -LiteralPath $Script -Raw
$m = [regex]::Match($src, "# ---- AGENT-LOG-FRESHNESS-BEGIN[^\n]*\n(.*?)# ---- AGENT-LOG-FRESHNESS-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: region AGENT-LOG-FRESHNESS not found"; exit 2 }
$region = $m.Groups[1].Value
# The guard is the ANCHOR, not any one string: a region that no longer reads the running agent's
# pid out of the line prefix is not the thing this file tests.
if ($region -notmatch '\$agentPids') { Write-Output "INSTRUMENT: the region no longer derives the running agent's pids"; exit 2 }
if ($region -notmatch '-\{0\}:') { Write-Output "INSTRUMENT: the region no longer matches the '-<pid>:<tid>-' line prefix"; exit 2 }
if ($region -notmatch 'Test-LogHeldOpen') { Write-Output "INSTRUMENT: the region no longer closes pid reuse with the open handle"; exit 2 }
if ($env:LOGFRESH_DEFECT -eq 'mtime') {
    # THE DEFECT, VERBATIM AS IT SHIPPED: trust the boot stamp when it looks sane, else take the
    # newest file by mtime that has an Init line.
    $region = @'
$bootSkewS = $null; $bootUsable = $false
if ($boot) { $bootSkewS = [int]((Get-Date) - $boot).TotalSeconds; $bootUsable = ($bootSkewS -ge 0) }
$agentPids = @(@($agentProc) | Where-Object { $_ } | ForEach-Object { $_.Id })   # measured, unused: the defect ignores it
$allAgentLogs = @($logDirs | ForEach-Object { Get-ChildItem $_ -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue })
if ($bootUsable) { $logsThisBoot = @($allAgentLogs | Where-Object { $_.LastWriteTime -gt $boot }) }
else { $logsThisBoot = @($allAgentLogs | Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                         Where-Object { Select-String -Path $_.FullName -Pattern 'Init:' -Quiet }) }
$instanceHits = @($logsThisBoot | ForEach-Object { [pscustomobject]@{ File = $_; AgentPid = ($agentPids | Select-Object -First 1); Lines = 1; HeldOpen = $true } })
$logAnchor = 'DEFECT: newest-by-mtime'; $anyHeld = $true
'@
}

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$ev='') {
  if ($ok) { $script:pass++; Write-Output "  ok   $what" }
  else { $script:fail++; Write-Output "  FAIL $what$(if($ev){" [$ev]"})" }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('logfresh-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$LIVEPID = 6852
$OLDPID  = 3412
function mklog([string]$name, [datetime]$mtime, [string[]]$lines) {
  $f = Join-Path $tmp $name
  Set-Content -LiteralPath $f -Value ($lines -join "`n")
  (Get-Item $f).LastWriteTime = $mtime
  return $f
}
function pfx([int]$p, [string]$text, [string]$lvl='I') { "[20261009.055237.423-${p}:6984-$lvl] $text" }
function names($hits) { (@($hits) | ForEach-Object { $_.File.Name }) -join ',' }
$logDirs = @($tmp)
$now = Get-Date
# A held handle is only a discriminator if this platform ENFORCES FileShare.None. pwsh 7 on Linux
# does (flock), measured 2026-10-09 - but if a runner ever does not, the held-open cases would
# pass vacuously, so refuse rather than pretend.
$probeFile = Join-Path $tmp 'shareprobe.txt'
Set-Content -LiteralPath $probeFile -Value 'x'
$h = [IO.File]::Open($probeFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$enforced = $true
try { $x=[IO.File]::Open($probeFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None); $x.Close(); $enforced=$false } catch { }
$h.Close(); Remove-Item -LiteralPath $probeFile -Force
if (-not $enforced) { Write-Output "INSTRUMENT: this platform does not enforce FileShare.None - the open-handle cases cannot be exercised"; exit 2 }
function reset { Get-ChildItem $tmp -Filter '*.log' | Remove-Item -Force }

# THE REAL SHAPE, in every case below: one per-DAY file the running agent appends to, whose mtime
# is BELOW the boot stamp (lazy mtime, then the clock flip), plus a per-instance file from the
# PREVIOUS boot whose ahead-phase mtime ranks ABOVE the boot stamp.
$script:holders = @()
function release { foreach ($h in $script:holders) { try { $h.Close() } catch { } }; $script:holders = @() }
function hold([string[]]$names) { # an agent holds its own log open with read sharing: a reader can
  release                         # still Select-String it, an EXCLUSIVE open cannot be taken. Two
  foreach ($n in $names) {        # live agents hold two logs, which is why this takes a list.
    $script:holders += [IO.File]::Open((Join-Path $tmp $n), [IO.FileMode]::Open,
                                       [IO.FileAccess]::Read, [IO.FileShare]::Read)
  }
}
function fixture {
  release
  reset
  [void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @(
          (pfx $OLDPID 'LogInit: Log started, module name: gui-agent'),
          (pfx $OLDPID 'Init: earlier instance, same day, same file'),
          (pfx $LIVEPID 'LogInit: Log started, module name: gui-agent'),
          (pfx $LIVEPID 'EnsureQubesIddSolo: IDD solo: found IDD adapter ''X'' (''Qubes Idd'')')))
  [void](mklog ('gui-agent-20261009-045802-{0}.log' -f $OLDPID) $now.AddMinutes(-1) @(
          (pfx $OLDPID 'LogInit: Log started, module name: gui-agent'),
          (pfx $OLDPID 'Init: PREVIOUS BOOT - must never answer for the running instance'),
          (pfx $OLDPID 'WatchForEvents: vchan disconnected')))
  hold 'gui-agent-20261009.log'
}

# ---- 1. THE MEASURED FAILURE: a healthy agent whose live log is older than the boot stamp -------
fixture
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
$boot = $now.AddMinutes(-2)      # usable stamp (+120 s), exactly WIN11-clean's condition
. ([scriptblock]::Create($region))
Check 'live log older than the boot stamp: the running instance IS found' ($instanceHits.Count -ge 1) `
      "hits=$($instanceHits.Count)"
Check 'live log older than the boot stamp: it is the PER-DAY file the agent appends to' `
      (@($instanceHits).Count -ge 1 -and @($instanceHits)[0].File.Name -eq 'gui-agent-20261009.log') `
      "picked=$(names $instanceHits)"

# ---- 2. THE FALSE PASS: the previous boot's file must never be selected ------------------------
Check 'the previous boot''s file is NOT selected, though it is newest by mtime and has an Init line' `
      (@($instanceHits | Where-Object { $_.File.Name -like '*-045802-*' }).Count -eq 0) `
      "picked=$(names $instanceHits)"
Check 'the selected instance is attributed to the RUNNING pid' `
      (@($instanceHits).Count -ge 1 -and @($instanceHits)[0].AgentPid -eq $LIVEPID) `
      "pid=$(@($instanceHits)[0].AgentPid)"
Check 'and its line count is the running instance''s own lines, not the file''s' `
      (@($instanceHits).Count -ge 1 -and @($instanceHits)[0].Lines -eq 2) `
      "lines=$(@($instanceHits)[0].Lines)"

# ---- 3. A GENUINELY SILENT AGENT STILL FAILS ---------------------------------------------------
# The file exists, is fresh, has Init lines - but none of them are this agent's. That is the defect
# the check exists for: errors going nowhere.
reset
[void](mklog 'gui-agent-20261009.log' $now @(
        (pfx $OLDPID 'LogInit: Log started, module name: gui-agent'),
        (pfx $OLDPID 'Init: not the running instance')))
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'a running agent with no line of its own anywhere: NOTHING is found (it must FAIL)' `
      ($instanceHits.Count -eq 0) "hits=$($instanceHits.Count) picked=$(names $instanceHits)"

# ---- 4. no agent process at all ----------------------------------------------------------------
fixture
$agentProc = $null
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'no agent process: no instance is claimed from any file' ($instanceHits.Count -eq 0) `
      "hits=$($instanceHits.Count) picked=$(names $instanceHits)"
Check 'no agent process: the pid list is empty, not a stray $null' ($agentPids.Count -eq 0) "pids=$($agentPids.Count)"

# ---- 5. the boot stamp is still MEASURED and REPORTED, just not obeyed -------------------------
fixture
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
$boot = $now.AddHours(3)         # the post-flip state: a boot 3 h in the future
. ([scriptblock]::Create($region))
Check 'stamp in the future: it is reported unusable' ($bootUsable -eq $false) "usable=$bootUsable"
Check 'stamp in the future: the skew is reported so the clock defect stays visible' ($bootSkewS -lt -3000) "skew=$bootSkewS"
Check 'stamp in the future: the running instance is found anyway' `
      (@($instanceHits).Count -ge 1 -and @($instanceHits)[0].File.Name -eq 'gui-agent-20261009.log') `
      "picked=$(names $instanceHits)"

# ---- 6. no boot stamp at all ($boot unreadable) - the check must still decide ------------------
fixture
$boot = $null
. ([scriptblock]::Create($region))
Check 'no boot stamp: the running instance is still found (the check is no longer gated on it)' `
      (@($instanceHits).Count -ge 1) "hits=$($instanceHits.Count)"
Check 'no boot stamp: skew is reported as null rather than invented' ($null -eq $bootSkewS) "skew=$bootSkewS"

# ---- 7. TWO live agents: both are looked for, and the file is attributed once ------------------
reset
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @((pfx 7777 'LogInit: second live agent')))
[void](mklog 'gui-agent-20261009-045802-9.log' $now.AddHours(-3) @((pfx $LIVEPID 'LogInit: first live agent')))
hold @('gui-agent-20261009.log', 'gui-agent-20261009-045802-9.log')   # each agent holds its own
$agentProc = @([pscustomobject]@{ Id = $LIVEPID }, [pscustomobject]@{ Id = 7777 })
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'two live agents: both their logs are found' ($instanceHits.Count -eq 2) `
      "hits=$($instanceHits.Count) picked=$(names $instanceHits)"

# ---- 8. a dir that does not exist is not an error, and not a pass ------------------------------
reset
$logDirs = @($tmp, (Join-Path $tmp 'nope'))
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'a missing log dir is survived and yields no instance' ($instanceHits.Count -eq 0) "hits=$($instanceHits.Count)"

# ---- 9. PID REUSE: the stale file carries the RUNNING pid and must still lose -----------------
# Windows recycles pids across boots. This is the one hole a pid anchor has, and the open handle is
# what closes it: the writer holds its log, a file from an earlier boot does not.
release; reset
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @(
        (pfx $LIVEPID 'LogInit: Log started, module name: gui-agent'),
        (pfx $LIVEPID 'Init: the LIVE instance')))
[void](mklog 'gui-agent-20261008-231111-6852.log' $now.AddMinutes(-1) @(
        (pfx $LIVEPID 'LogInit: Log started, module name: gui-agent'),
        (pfx $LIVEPID 'Init: AN EARLIER BOOT THAT HAPPENED TO GET THE SAME PID')))
hold 'gui-agent-20261009.log'
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'pid reuse: only the HELD file is taken, though both carry the running pid' `
      ($instanceHits.Count -eq 1 -and @($instanceHits)[0].File.Name -eq 'gui-agent-20261009.log') `
      "hits=$($instanceHits.Count) picked=$(names $instanceHits)"
Check 'pid reuse: the anchor names the open handle' ($logAnchor -match 'open-handle') "anchor=$logAnchor"

# ---- 10. PID REUSE + A SILENT AGENT: the stale file must not stand in for it ------------------
release; reset
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @('[no lines of any instance yet]'))
[void](mklog 'gui-agent-20261008-231111-6852.log' $now.AddMinutes(-1) @(
        (pfx $LIVEPID 'LogInit: Log started, module name: gui-agent'),
        (pfx $LIVEPID 'Init: AN EARLIER BOOT WITH THE SAME PID')))
hold 'gui-agent-20261009.log'
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
. ([scriptblock]::Create($region))
Check 'pid reuse + silent agent: nothing is found, so the check FAILS as it must' `
      ($instanceHits.Count -eq 0) "hits=$($instanceHits.Count) picked=$(names $instanceHits)"

# ---- 11. NOTHING HELD OPEN: a loud FAIL, not a degraded pass ----------------------------------
# An earlier draft degraded to the pid alone here. That reopened pid reuse exactly where nothing
# else could discriminate (Jev fallback_is_a_real_hole 0.59), so the handle is now required and
# this state FAILS - the agent is not logging, or its handle policy changed. Either is a finding.
release; reset
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @(
        (pfx $LIVEPID 'LogInit: Log started, module name: gui-agent')))
$agentProc = [pscustomobject]@{ Id = $LIVEPID }
. ([scriptblock]::Create($region))
Check 'no handle anywhere: nothing is attributed, so the check FAILS' ($instanceHits.Count -eq 0) `
      "hits=$($instanceHits.Count) picked=$(names $instanceHits)"
Check 'no handle anywhere: the no-handle state is visible in $anyHeld for the evidence' `
      ($anyHeld -eq $false) "anyHeld=$anyHeld"
Check 'the anchor string no longer advertises a degraded mode' `
      ($logAnchor -notmatch 'ONLY') "anchor=$logAnchor"

# ---- 12. AN OLDER AGENT: the prefix carries the THREAD id, the pid only in LogInit -------------
# MEASURED on a 4.3.32 agent log the campaign left on win11-acc: its lines read
# '[20261009.045802.150-2484-I]' while its own LogInit says 'process ID: 3412'. An anchor matching
# '-<pid>:' alone reports "this instance wrote nothing" on every such guest - and the stock cells
# run one. The LogInit line names the pid in BOTH formats.
release; reset
$OLDFMT = 3412
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @(
        "[20261009.045802.150-2484-I] LogInit: Log started, module name: gui-agent",
        "[20261009.045802.152-2484-I] LogInit: Running as user: SYSTEM, process ID: $OLDFMT",
        "[20261009.045802.152-2484-I] LogInit: Module version: 4.3.32.612"))
hold 'gui-agent-20261009.log'
$agentProc = [pscustomobject]@{ Id = $OLDFMT }
$boot = $now.AddMinutes(-2)
. ([scriptblock]::Create($region))
Check 'older agent: the instance is found via its LogInit process ID' `
      (@($instanceHits).Count -eq 1 -and @($instanceHits)[0].AgentPid -eq $OLDFMT) `
      "hits=$($instanceHits.Count) picked=$(names $instanceHits)"
Check 'older agent: the hit records that the pid is NOT in the line prefix' `
      (@($instanceHits).Count -eq 1 -and @($instanceHits)[0].PidInPrefix -eq $false) `
      "pidInPrefix=$(@($instanceHits)[0].PidInPrefix)"
# and the THREAD id in that prefix must not be mistaken for a running agent
release; reset
[void](mklog 'gui-agent-20261009.log' $now.AddHours(-3) @(
        "[20261009.045802.150-2484-I] LogInit: Log started, module name: gui-agent",
        "[20261009.045802.152-2484-I] LogInit: Running as user: SYSTEM, process ID: $OLDFMT"))
hold 'gui-agent-20261009.log'
$agentProc = [pscustomobject]@{ Id = 2484 }      # the THREAD id, not this log's process
. ([scriptblock]::Create($region))
Check 'older agent: a thread id equal to the running pid does NOT claim the log' `
      ($instanceHits.Count -eq 0) "hits=$($instanceHits.Count) picked=$(names $instanceHits)"

release
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "health-logfresh-test: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
