<#
.SYNOPSIS
    Offline suite for the two defects behind "dom0 is told 0 updates after a reboot-pending pass,
    and nothing ever corrects it" in guest/qubes-windows-update.ps1 - GWeck's Patch Tuesday
    failure, reproduced 2026-09-16 on win11de-gwt (German Windows 11 25H2 26200.8037, TemplateVM,
    netvm='', QWT-NG 4.3.29 from the release package). Runs under pwsh on Linux or Windows
    PowerShell 5.1; no rig, no guest, no Windows Update - the status file, the log and the dom0
    report are the hooks the suite replaces.

.DESCRIPTION
    Replays the guest's ACTUAL captured update-status.json files (scratchpad/gweck25h2/run/i1 and
    run/i2 - the German titles, the KB5129195 ok=false state=deferred row, the staged row, the real
    done_ts stamps) against the SHIPPED code, extracted by marker lines (never by brace-hunting)
    and dot-sourced, under a live de-DE culture:
      rowkey    Test-RowKey answers a key on an OrderedDictionary (what the pass builds) and on a
                PSCustomObject (what ConvertFrom-Json returns); and the old idiom is shown dead on
                THIS shell too - PSObject.Properties.Name of [ordered]@{} lists Count,Keys,... and
                never a key, exactly as measured on the guest (run/diag/psobject.txt)
      report    the reboot-pending report on the pass-1 rows counts exactly KB5129195 -> remaining
                1, dom0 told 1 (the guest wrote 0 and told dom0 0); on the pass-2 rows (KB5129195
                staged, ok=true) -> 0, so the fix does not over-report; an informational row stays
                excluded; JSON-shaped rows give the same answer
      debounce  the boot scan at 22:54:00 after the reboot-pending pass whose done_ts is 22:49:16
                RUNS (the guest skipped it at exactly these stamps); a scan's own answer 4.7 min old
                still debounces the next scheduled scan; an old, errored or absent status never
                debounces; a dom0-driven (non -Scheduled) pass is never skipped
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the original bug in the extracted copy (the shipped file is never modified):
      deadfilter  the `# GUARD:rowkey` line becomes the pre-2026-09-16 predicate
                  `$_.PSObject.Properties.Name -contains 'kb'` - the pass-1 replay must FAIL
                  (remaining 0, dom0 told 0: what the guest wrote)
      debounce    the `# GUARD:bootconfirm` line becomes `$prevGuessed = $false` - a reboot-pending
                  pass counts as an answer again, and the boot-scan replay must FAIL (skipped)
    tools/tests/wu-reboot-report-selftest.sh runs the clean leg and both knobs and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$InstallerPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath)    { $ScriptPath    = Join-Path $repoRoot 'guest/qubes-windows-update.ps1' }
if (-not $InstallerPath) { $InstallerPath = Join-Path $repoRoot 'guest/install-updater-agent.ps1' }
$ScriptPath    = (Resolve-Path -LiteralPath $ScriptPath).Path
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}
function CheckEq([string]$name, $got, $want) {
    $script:run++
    $ok = ("$got" -eq "$want")
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host ("{0} {1,-88} want {2,-6} got {3}" -f $tag, $name, $want, $got)
}

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- the captured data: C:\ProgramData\Qubes\update-status.json as pulled from win11de-gwt ---------
# Pass 1 (QubesWindowsUpdateRun, 22:34-22:49 guest time, evidence run/i1/logs.txt): the September
# cumulative KB5129195 was fetched (4,424.5 MB) and DEFERRED behind the staged .NET KB5126052 by the
# one-staged-package-per-CBS-session rule. The file says remaining 0 - that number is the defect.
$Pass1Json = @'
{
    "action":  "full",
    "phase":  "done",
    "ts":  "2026-09-16T22:49:16",
    "count":  6,
    "available":  [
                      {
                          "kb":  "KB5007651",
                          "title":  "Update für Windows Security platform - KB5007651 (Version 10.0.29628.1000)",
                          "size_mb":  21.1,
                          "downloaded":  false,
                          "content_class":  "self-contained",
                          "direct_urls":  [
                                              "http://download.windowsupdate.com/d/msdownload/update/software/defu/2026/07/securityhealthsetup_21fb0c228dbf70d24ecb707b0ee9f97c2786961f.exe"
                                          ]
                      },
                      {
                          "kb":  "KB890830",
                          "title":  "Windows-Tool zum Entfernen bösartiger Software x64 - v5.145 (KB890830)",
                          "size_mb":  84.0,
                          "downloaded":  false,
                          "content_class":  "self-contained",
                          "direct_urls":  [
                                              "http://download.windowsupdate.com/d/msdownload/update/software/uprl/2026/09/windows-kb890830-x64-v5.145_860b493566a29282606ed075513294c239b1a545.exe"
                                          ]
                      },
                      {
                          "kb":  "KB2267602",
                          "title":  "Security Intelligence-Update für Microsoft Defender Antivirus - KB2267602 (Version 1.459.239.0) - Aktueller Kanal (Allgemein)",
                          "size_mb":  206.0,
                          "downloaded":  false,
                          "content_class":  "none",
                          "direct_urls":  [
                                          ]
                      },
                      {
                          "kb":  "(no KB)",
                          "title":  "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.7057)",
                          "size_mb":  28.6,
                          "downloaded":  false,
                          "content_class":  "none",
                          "direct_urls":  [
                                          ]
                      },
                      {
                          "kb":  "KB5126052",
                          "title":  "2026-09 .NET Framework Sicherheitsupdate (KB5126052)",
                          "size_mb":  184.4,
                          "downloaded":  false,
                          "content_class":  "none",
                          "direct_urls":  [
                                          ]
                      },
                      {
                          "kb":  "KB5129195",
                          "title":  "2026-09 Sicherheitsupdate (KB5129195) (26200.9457)",
                          "size_mb":  92399.7,
                          "downloaded":  false,
                          "content_class":  "none",
                          "direct_urls":  [
                                          ]
                      }
                  ],
    "downloading":  {
                        "kb":  "KB2267602",
                        "file":  "mpam-fe.exe",
                        "mb":  205,
                        "total_mb":  205,
                        "pct":  100
                    },
    "installing":  {
                       "file":  "windows11.0-kb5126052-x64-ndp481_082cfd5816914c794b261ea68bf6c91419fc32a8.msu",
                       "state":  "running"
                   },
    "result":  [
                   {
                       "kb":  "KB5007651",
                       "ok":  true,
                       "state":  "installed",
                       "files":  [
                                     {
                                         "kb":  "KB5007651",
                                         "file":  "securityhealthsetup_21fb0c228dbf70d24ecb707b0ee9f97c2786961f.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  false
                                     }
                                 ]
                   },
                   {
                       "kb":  "KB890830",
                       "ok":  true,
                       "state":  "installed",
                       "files":  [
                                     {
                                         "kb":  "KB890830",
                                         "file":  "windows-kb890830-x64-v5.145_860b493566a29282606ed075513294c239b1a545.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  true
                                     }
                                 ]
                   },
                   {
                       "kb":  "KB5126052",
                       "ok":  true,
                       "state":  "staged",
                       "files":  {
                                     "file":  "windows11.0-kb5126052-x64-ndp481_082cfd5816914c794b261ea68bf6c91419fc32a8.msu",
                                     "rc":  3010,
                                     "state_after":  "unknown"
                                 }
                   },
                   {
                       "kb":  "KB5129195",
                       "ok":  false,
                       "state":  "deferred",
                       "files":  {
                                     "file":  "windows11.0-kb5129195-x64_ed361878ec2b56a7dfdb8f256565263a7fdc8eaa.msu",
                                     "rc":  "deferred",
                                     "why":  "another package is already staged; installing it needs a reboot first"
                                 }
                   },
                   {
                       "kb":  "KB2267602",
                       "ok":  true,
                       "severity":  "ok",
                       "files":  [
                                     {
                                         "kb":  "KB2267602",
                                         "file":  "mpam-fe.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  true
                                     }
                                 ],
                       "reason":  "full signature package installed directly (verified by effect)"
                   }
               ],
    "reboot_needed":  true,
    "error":  null,
    "remaining":  0,
    "reboot_pending_confirmed":  true,
    "done_ts":  "2026-09-16T22:49:16"
}
'@
# Pass 2 (22:56-23:33 guest time, evidence run/i2/logs.txt): the reused .msu was staged by DISM
# (rc=3010, ok=true, state=staged). Here 0 remaining IS the right answer - the apply happens at the
# reboot the pass commits - so the fix must not turn a staged row into an outstanding one.
$Pass2ResultJson = @'
{
    "result":  [
                   {
                       "kb":  "KB5007651",
                       "ok":  true,
                       "state":  "installed",
                       "files":  [
                                     {
                                         "kb":  "KB5007651",
                                         "file":  "securityhealthsetup_21fb0c228dbf70d24ecb707b0ee9f97c2786961f.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  false
                                     }
                                 ]
                   },
                   {
                       "kb":  "KB4052623",
                       "ok":  true,
                       "state":  "installed",
                       "files":  [
                                     {
                                         "kb":  "KB4052623",
                                         "file":  "updateplatform.amd64fre_99b71e4d3a498fec8b527f4dc0cf4a74169de128.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  false
                                     }
                                 ]
                   },
                   {
                       "kb":  "KB5129195",
                       "ok":  true,
                       "state":  "staged",
                       "files":  {
                                     "file":  "windows11.0-kb5129195-x64_ed361878ec2b56a7dfdb8f256565263a7fdc8eaa.msu",
                                     "rc":  3010,
                                     "state_after":  "Not Present"
                                 }
                   },
                   {
                       "kb":  "KB2267602",
                       "ok":  true,
                       "severity":  "ok",
                       "files":  [
                                     {
                                         "kb":  "KB2267602",
                                         "file":  "mpam-fe.exe",
                                         "rc":  0,
                                         "ok":  true,
                                         "verified_by_effect":  false
                                     }
                                 ],
                       "reason":  "full signature package installed directly (verified by effect)"
                   }
               ],
    "reboot_needed":  true,
    "error":  null,
    "remaining":  0,
    "reboot_pending_confirmed":  true,
    "done_ts":  "2026-09-16T23:33:00"
}
'@
# The boot scan the guest actually ran after pass 1: LastRunTime 2026-09-16T22:54:00, LastTaskResult 0,
# nothing written to wu\agent.log, update-status.json still ts=22:49:16 (evidence run/bootscan2.out).
$BootScanAfterPass1 = [datetime]'2026-09-16T22:54:00'

# The rows this pass builds at runtime are [ordered]@{...} - OrderedDictionary, never PSCustomObject -
# which is exactly what the guest measured (row_type=System.Collections.Specialized.OrderedDictionary).
# The captured JSON is replayed back into that shape, key order and nesting intact.
function ConvertTo-GuestRow($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $d = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) {
            $v = $p.Value
            # Lists are rebuilt by assignment here, never returned through the pipeline (which
            # would unroll or wrap them); a dictionary is never enumerated on output, so it can be.
            if (($v -is [System.Collections.IList]) -and -not ($v -is [string])) {
                $d[$p.Name] = @(foreach ($e in $v) { ConvertTo-GuestRow $e })
            } else {
                $d[$p.Name] = ConvertTo-GuestRow $v
            }
        }
        return $d
    }
    return $o
}

# --- extract the regions by their marker lines ----------------------------------------------------
$lines = @(Get-Content -LiteralPath $ScriptPath)
function Get-Region([string]$name) {
    # Markers may be indented (the report region sits inside an `if`), so match the trimmed line.
    $begins = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $ends   = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $begins[0] -ge $ends[0]) {
        Write-Host "FAIL marker extraction ${name}: expected exactly one BEGIN before one END, got $($begins.Count)/$($ends.Count)"
        exit 1
    }
    return ,@($lines[($begins[0] + 1)..($ends[0] - 1)])
}
$debounceRegion = Get-Region 'WU-SCAN-DEBOUNCE'
$rowkeyRegion   = Get-Region 'WU-ROWKEY'
$reportRegion   = Get-Region 'WU-REBOOT-PENDING-REPORT'

switch ($Defect) {
    '' { }
    'deadfilter' {
        $hit = @($reportRegion | Where-Object { $_ -match '# GUARD:rowkey$' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect deadfilter: expected exactly 1 '# GUARD:rowkey' line, found $($hit.Count)"; exit 1 }
        $reportRegion = @($reportRegion | ForEach-Object {
            if ($_ -match '# GUARD:rowkey$') { "                     Where-Object { `$_.PSObject.Properties.Name -contains 'kb' -and -not `$_.ok -and `$_.severity -ne 'info' })   # DEFECT: the pre-2026-09-16 predicate" }
            else { $_ } })
    }
    'debounce' {
        $hit = @($debounceRegion | Where-Object { $_ -match '# GUARD:bootconfirm$' })
        if ($hit.Count -ne 1) { Write-Host "FAIL defect debounce: expected exactly 1 '# GUARD:bootconfirm' line, found $($hit.Count)"; exit 1 }
        $debounceRegion = @($debounceRegion | ForEach-Object {
            if ($_ -match '# GUARD:bootconfirm$') { '            $prevGuessed = $false   # DEFECT: pre-2026-09-16 - a reboot-pending pass counted as an answer' }
            else { $_ } })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (deadfilter | debounce)"; exit 1 }
}

# The debounce region ends a skipped scan with `exit 0`; in the replay that becomes a flag. Exactly
# one such line, or the extraction is not the block this suite was written for.
$exits = @($debounceRegion | Where-Object { $_ -match '^\s*exit 0\s*$' })
Check 'extract: the debounce region carries exactly one `exit 0` (the skip)' ($exits.Count -eq 1)
$debounceRegion = @($debounceRegion | ForEach-Object { if ($_ -match '^\s*exit 0\s*$') { '                    $script:DebounceSkipped = $true' } else { $_ } })

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wureport-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$debounceFile = Join-Path $tmpRoot 'debounce-region.ps1'
$rowkeyFile   = Join-Path $tmpRoot 'rowkey-region.ps1'
$reportFile   = Join-Path $tmpRoot 'report-region.ps1'
[IO.File]::WriteAllLines($debounceFile, [string[]]$debounceRegion)
[IO.File]::WriteAllLines($rowkeyFile,   [string[]]$rowkeyRegion)
[IO.File]::WriteAllLines($reportFile,   [string[]]$reportRegion)
. $rowkeyFile
Check 'extract: the rowkey region defines Test-RowKey' ([bool](Get-Command Test-RowKey -EA SilentlyContinue))

# --- the shipped file, as shipped --------------------------------------------------------------------
$shipped   = Get-Content -LiteralPath $ScriptPath -Raw
$installer = Get-Content -LiteralPath $InstallerPath -Raw
$guardLine = @($lines | Where-Object { $_ -match '# GUARD:rowkey$' })
Check 'shipped: exactly one # GUARD:rowkey line, it calls Test-RowKey and not PSObject.Properties.Name' `
      ($guardLine.Count -eq 1 -and $guardLine[0] -match 'Test-RowKey \$_ ''kb''' -and $guardLine[0] -notmatch 'PSObject\.Properties')
Check 'shipped: the debounce skip condition carries -not $prevGuessed' ($shipped -match 'if \(\$prev\.done_ts -and \$prevAnswered -and -not \$prevGuessed\) \{')
Check 'shipped: the status-file test at the debounce still uses the property list (a PSCustomObject there)' ($shipped -match "\`$prev\.PSObject\.Properties\.Name -contains 'available'")
Check 'shipped: the installer registers the boot scan as `-Action scan -Scheduled` with a BootTrigger' `
      ($installer -match '-Action scan -Scheduled' -and $installer -match '<BootTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></BootTrigger>')

# --- 1. rowkey ---------------------------------------------------------------------------------------
$od = [ordered]@{ kb = 'KB5129195'; ok = $false; state = 'deferred' }
Check 'rowkey: this shell hides dictionary keys from PSObject.Properties.Name (the old idiom is dead here too)' `
      (-not (@($od.PSObject.Properties.Name) -contains 'kb'))
Check 'rowkey: OrderedDictionary with kb -> $true'    ((Test-RowKey $od 'kb') -eq $true)
Check 'rowkey: OrderedDictionary without severity -> $false' ((Test-RowKey $od 'severity') -eq $false)
Check 'rowkey: plain hashtable with kb -> $true'      ((Test-RowKey @{ kb = 'x' } 'kb') -eq $true)
$pc = ('{"kb":"KB5129195","ok":false}' | ConvertFrom-Json)
Check 'rowkey: PSCustomObject (ConvertFrom-Json) with kb -> $true'   ((Test-RowKey $pc 'kb') -eq $true)
Check 'rowkey: PSCustomObject without severity -> $false'            ((Test-RowKey $pc 'severity') -eq $false)

# --- 2. the reboot-pending report, replayed ----------------------------------------------------------
$script:Saves = 0; $script:LogLines = @(); $script:Reported = @()
function Save { $script:Saves++ }
function Log($m) { $script:LogLines += $m }
function Report-Availability($count) { $script:Reported += ,$count }
function Invoke-Report($rows) {
    $script:Saves = 0; $script:LogLines = @(); $script:Reported = @()
    $script:St = [ordered]@{ action = 'full'; phase = 'install'; result = @($rows); reboot_needed = $true }
    . $reportFile
    return [pscustomobject]@{ remaining = $script:St.remaining; reported = @($script:Reported); failed = @($failedKbs); log = @($script:LogLines) }
}

$pass1 = $Pass1Json | ConvertFrom-Json
$pass1Rows = @(foreach ($e in $pass1.result) { ConvertTo-GuestRow $e })
CheckEq 'report: pass-1 rows replay as 5 OrderedDictionary rows (guest measured row_type=OrderedDictionary)' `
        (@($pass1Rows | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }).Count) 5
Check   'report: pass-1 row 4 is kb=KB5129195 ok=false state=deferred (the captured shape)' `
        ($pass1Rows[3].kb -eq 'KB5129195' -and $pass1Rows[3].ok -eq $false -and $pass1Rows[3].state -eq 'deferred')
Check   'report: the captured file says "remaining": 0 - the number under test' ($pass1.remaining -eq 0)
Check   'report: the captured German title is intact (codepoints of "für")' `
        (([int[]][char[]]'für' -join ',') -eq '102,252,114' -and $pass1.available[0].title -like 'Update für Windows Security platform*')
$r = Invoke-Report $pass1Rows
CheckEq 'report: pass-1 replay - remaining is 1 (KB5129195 ok=false state=deferred); the guest wrote 0' $r.remaining 1
CheckEq 'report: pass-1 replay - dom0 is told 1, exactly once' ($r.reported -join ',') '1'
Check   'report: pass-1 replay - the one outstanding KB is KB5129195' ($r.failed.Count -eq 1 -and $r.failed[0].kb -eq 'KB5129195')
Check   'report: pass-1 replay - the log line says "reporting 1 remaining"' (@($r.log | Where-Object { $_ -like 'reboot pending; reporting 1 remaining*' }).Count -eq 1)
Check   'report: pass-1 replay - the status was saved' ($r.remaining -eq 1 -and $script:Saves -ge 1)

$pass2Rows = @(foreach ($e in ($Pass2ResultJson | ConvertFrom-Json).result) { ConvertTo-GuestRow $e })
Check   'report: pass-2 row 3 is kb=KB5129195 ok=true state=staged (the captured shape)' `
        ($pass2Rows[2].kb -eq 'KB5129195' -and $pass2Rows[2].ok -eq $true -and $pass2Rows[2].state -eq 'staged')
$r2 = Invoke-Report $pass2Rows
CheckEq 'report: pass-2 replay - remaining is 0 (KB5129195 staged, ok=true): no over-report' $r2.remaining 0
CheckEq 'report: pass-2 replay - dom0 is told 0' ($r2.reported -join ',') '0'

# An informational row in the shipped shape (qubes-windows-update.ps1, the wu-only-express record):
# excluded from the count by severity, exactly as before the fix.
$infoRow = [ordered]@{ kb = 'KB5071959'; ok = $false; severity = 'info'; reason = 'wu-only-express (test copy of the shipped shape)' }
$r3 = Invoke-Report ($pass1Rows + ,$infoRow)
CheckEq 'report: pass-1 rows + a severity=info row - still 1 (informational stays excluded)' $r3.remaining 1

# The same rows in their JSON shape (PSCustomObject): the helper answers both shapes the same way.
$r4 = Invoke-Report @($pass1.result)
CheckEq 'report: pass-1 rows as PSCustomObjects (JSON shape) - still 1' $r4.remaining 1
$r5 = Invoke-Report @()
CheckEq 'report: no rows - 0' $r5.remaining 0

# --- 3. the scheduled-scan debounce, replayed at the captured timestamps ----------------------------
# The region reads $Scheduled/$Action/$StatusFile and calls Get-Date; the replay shadows Get-Date so
# the boot scan runs at the minute the guest's task actually fired.
$script:Now = $BootScanAfterPass1
function Get-Date { return $script:Now }
function Invoke-Debounce([string]$json, [datetime]$at, [bool]$scheduled = $true, [string]$action = 'scan') {
    $script:Now = $at
    $script:DebounceSkipped = $false
    $StatusFile = Join-Path $tmpRoot 'update-status.json'
    if ($null -eq $json) { Remove-Item -LiteralPath $StatusFile -Force -EA SilentlyContinue }
    else { [IO.File]::WriteAllText($StatusFile, $json, (New-Object System.Text.UTF8Encoding($false))) }
    $Scheduled = $scheduled
    $Action = $action
    . $debounceFile
    return [bool]$script:DebounceSkipped
}
function With-Field([string]$json, [hashtable]$set) {
    $o = $json | ConvertFrom-Json
    foreach ($k in $set.Keys) {
        if ($null -eq $set[$k]) { $o.PSObject.Properties.Remove($k) }
        elseif ($o.PSObject.Properties.Name -contains $k) { $o.$k = $set[$k] }
        else { $o | Add-Member -NotePropertyName $k -NotePropertyValue $set[$k] }
    }
    return ($o | ConvertTo-Json -Depth 8)
}

$env:QUBES_UPDATES_DEBOUNCE_MIN = $null
Check 'debounce: boot scan at 22:54:00 after the reboot-pending pass (done_ts 22:49:16) RUNS' `
      (-not (Invoke-Debounce $Pass1Json $BootScanAfterPass1))
Check 'debounce: the same status with reboot_needed=false (a scan''s own answer), 4.7 min old, is SKIPPED' `
      (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) $BootScanAfterPass1)
Check 'debounce: reboot_needed=false, 45 min old -> runs' `
      (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) ([datetime]'2026-09-16T23:34:16')))
Check 'debounce: reboot_needed=false, phase=error -> runs' `
      (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false; phase = 'error' }) $BootScanAfterPass1))
Check 'debounce: reboot_needed absent from the status (older agent), 4.7 min old -> skipped as before' `
      (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $null }) $BootScanAfterPass1)
Check 'debounce: a dom0-driven scan (not -Scheduled) on the 4.7 min old reboot_needed=false status -> runs' `
      (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) $BootScanAfterPass1 $false))
Check 'debounce: a scheduled non-scan action is never debounced here' `
      (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) $BootScanAfterPass1 $true 'install'))
Check 'debounce: status file absent -> runs' (-not (Invoke-Debounce $null $BootScanAfterPass1))
Check 'debounce: a done_ts in the future (clock moved) -> runs' `
      (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) ([datetime]'2026-09-16T22:40:00')))
$env:QUBES_UPDATES_DEBOUNCE_MIN = '0'
Check 'debounce: QUBES_UPDATES_DEBOUNCE_MIN=0 -> runs' (-not (Invoke-Debounce (With-Field $Pass1Json @{ reboot_needed = $false }) $BootScanAfterPass1))
$env:QUBES_UPDATES_DEBOUNCE_MIN = $null
# The pass-2 status (done_ts 23:33:00, reboot_needed=true - the cumulative staged): the boot scan
# 5 minutes later is what confirms the apply, and it must run too.
$pass2Full = With-Field $Pass1Json @{ reboot_needed = $true; done_ts = '2026-09-16T23:33:00'; ts = '2026-09-16T23:33:00' }
Check 'debounce: boot scan at 23:38:00 after the pass-2 reboot-pending status (done_ts 23:33:00) RUNS' `
      (-not (Invoke-Debounce $pass2Full ([datetime]'2026-09-16T23:38:00')))
Remove-Item function:Get-Date -EA SilentlyContinue

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -EA SilentlyContinue
Write-Host ("--- {0} checks, {1} failed{2}" -f $script:run, $script:fail, $(if ($Defect) { " (defect knob: $Defect)" } else { '' }))
if ($script:fail -gt 0) { exit 1 }
exit 0
