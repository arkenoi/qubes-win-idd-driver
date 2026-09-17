<#
.SYNOPSIS
    Offline suite for the dom0-facing outcome rendering in guest/wu-update.ps1 - the handler stock
    `qubes-vm-update` (and so the Qubes Update GUI) reaches through vmupdate-shim.ps1. Runs under
    pwsh on Linux or Windows PowerShell 5.1; no rig, no guest. The status file and dom0's stderr
    are the hooks the suite replaces.

.DESCRIPTION
    THE DEFECT (measured 2026-09-16 on win11de-gwt - German Windows 11 25H2 26200.8037, QWT-NG
    4.3.29 build 537, driven exactly as dom0 drives it: qubes.VMExec -> vmupdate-shim -> wu-update).
    dom0 was told, verbatim (scratchpad/gweck25h2/verify/s1/entrypoint.err, after the 100.0 line):
        staged (completes at restart): KB5126052
        updates installed - this qube shuts down in 60 seconds; start it again and the update finishes during boot
        FAILED KB5129195: DISM rejected every package file
        see C:\ProgramData\Qubes\update-status.json on the qube for details
      exit 1
    while the guest's own status row for that KB (scratchpad/gweck25h2/run/i1/logs.txt, the
    update-status.json of that pass, ts 2026-09-17T00:59:09) said
        "kb": "KB5129195", "ok": false, "state": "deferred",
        "files": { "rc": "deferred", "why": "another package is already staged; installing it needs a reboot first" }
    DISM was never handed the file. The 'done' branch classified every ok=false row as failed and,
    reading $row.reason (absent on this shape), printed a hard-coded fallback asserting a cause.

    The suite replays that CAPTURED status through the shipped WU-OUTCOME region (extracted by its
    marker lines, never by brace-hunting; dot-sourced; rows come through ConvertFrom-Json exactly
    as wu-update.ps1 reads them) under a live de-DE culture, and asserts the exact stderr text and
    exit code for:
      deferred        the captured pass: KB5126052 staged, KB5129195 deferred with ITS OWN why, exit 0;
                      the writer's second deferral shape (reason='deferred: ...', no state) likewise
      failed          a synthetic genuinely failed row carrying a reason -> FAILED <kb>: <reason>, exit 1
      dism-rc         a synthetic DISM failure (file rows with rc, no reason) -> the real file and rc
      installed       an all-installed pass -> installed: <kbs>, exit 0
      informational   the writer's severity=info shape -> rendered informational, exit 0
      deferred+failed a failure alongside a deferral -> both rendered, exit 1 (failure wins)
      contract        no rendered line ends in a bare number (dom0 parses float(line.split()[-1]))
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces a defect in the extracted copy (the shipped file is never modified):
      1 | prefix   the pre-2026-09-17 code: the `# GUARD:deferred` and `# GUARD:info` lines are
                   disabled (every ok=false row is a failure) and `# GUARD:rowwhy` becomes the old
                   `$f.reason`-else-"DISM rejected every package file" read. The captured pass must
                   then render EXACTLY the measured text above - the deferred case FAILS.
      deferred     only the deferred classification is disabled - exactly the deferred checks fail
      info         only the informational classification is disabled - exactly those checks fail
      fallback     only the reason read is restored - exactly the dism-rc checks fail
    tools/tests/wu-update-render-selftest.sh runs the clean leg and every knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'guest/wu-update.ps1' }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

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
    Write-Host ("{0} {1}" -f $tag, $name)
    if (-not $ok) { Write-Host ("       want [{0}]" -f $want); Write-Host ("       got  [{0}]" -f $got) }
}

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- the captured data ------------------------------------------------------------------------------
# C:\ProgramData\Qubes\update-status.json of the pass dom0 drove on win11de-gwt, as pulled off the
# guest (scratchpad/gweck25h2/run/i1/logs.txt). Two result rows: the .NET KB5126052 staged by DISM
# (rc 3010) and the September cumulative KB5129195 deferred behind it. The `available`/`downloading`
# blocks are kept as captured; only `result`, `count` and `reboot_needed` matter to the render.
$CapturedJson = @'
{
    "action":  "full",
    "phase":  "done",
    "ts":  "2026-09-17T00:59:09",
    "count":  3,
    "available":  [
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
                        "kb":  "KB5129195",
                        "file":  "windows11.0-kb5129195-x64_ed361878ec2b56a7dfdb8f256565263a7fdc8eaa.msu",
                        "mb":  4424.5,
                        "total_mb":  4424.5,
                        "pct":  100
                    },
    "installing":  {
                       "file":  "windows11.0-kb5126052-x64-ndp481_082cfd5816914c794b261ea68bf6c91419fc32a8.msu",
                       "state":  "running"
                   },
    "result":  [
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
                   }
               ],
    "reboot_needed":  true,
    "error":  null,
    "remaining":  1,
    "reboot_pending_confirmed":  true,
    "done_ts":  "2026-09-17T00:59:09"
}
'@
# What dom0 was told for that pass, verbatim (verify/s1/entrypoint.err) - the outcome lines only;
# the "updates installed - this qube shuts down..." line between them is the reboot block, which is
# outside the region under test.
$MeasuredPreFix = @(
    'staged (completes at restart): KB5126052',
    'FAILED KB5129195: DISM rejected every package file',
    'see C:\ProgramData\Qubes\update-status.json on the qube for details'
)

# Synthetic rows in the writer's OWN shapes (qubes-windows-update.ps1, line refs as of 2026-09-17):
$RowInstalledA = '{ "kb": "KB5007651", "ok": true, "state": "installed", "files": [ { "kb": "KB5007651", "file": "securityhealthsetup_21fb0c228dbf70d24ecb707b0ee9f97c2786961f.exe", "rc": 0, "ok": true, "verified_by_effect": false } ] }'
$RowInstalledB = '{ "kb": "KB890830", "ok": true, "state": "installed", "files": [ { "kb": "KB890830", "file": "windows-kb890830-x64-v5.145_860b493566a29282606ed075513294c239b1a545.exe", "rc": 0, "ok": true, "verified_by_effect": true } ] }'
# :1589 - no installable package resolved: {kb, ok=false, files=@(), reason=$why}
$RowFailedReason = '{ "kb": "KB5000001", "ok": false, "files": [ ], "reason": "no catalog entry matches this Windows version/architecture" }'
# :1611 + :1059 - every .msu failed in DISM: {kb, ok=false, state=failed, files=[{kb,file,rc,ok=false}]}
$RowFailedDism = '{ "kb": "KB5000002", "ok": false, "state": "failed", "files": [ { "kb": "KB5000002", "file": "windows11.0-kb5000002-x64_0000000000000000000000000000000000000000.msu", "rc": -2146498512, "ok": false } ] }'
# :1643 - the Windows-Update-native fallback deferred behind a staged package (no state key)
$RowDeferredWu = '{ "kb": "KB2267602", "ok": false, "files": [ ], "reason": "deferred: a reboot-requiring package is already staged this session; the next pass installs this" }'
# :1727 - the wu-only-express informational ceiling
$RowInfo = '{ "kb": "KB5071959", "ok": false, "severity": "info", "reason": "wu-only-express: Windows Update offers this KB only through Delivery Optimization (express streams and/or a delta patch that needs a base); no catalog .msu and no self-contained static installer, so it is not installable on a netvm-free guest. INFORMATIONAL - not a failure." }'

function StatusJson([string[]]$rows, [bool]$reboot, [int]$count = -1) {
    if ($count -lt 0) { $count = $rows.Count }
    $rb = 'false'; if ($reboot) { $rb = 'true' }
    return ('{ "action": "full", "phase": "done", "ts": "2026-09-17T00:59:09", "count": ' + $count +
            ', "result": [ ' + ($rows -join ', ') + ' ], "reboot_needed": ' + $rb + ', "error": null }')
}

# --- extract the region by its marker lines ----------------------------------------------------------
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
$region = Get-Region 'WU-OUTCOME'

function Swap-Guard([string[]]$src, [string]$guard, [string]$replacement) {
    $hit = @($src | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line in the region, found $($hit.Count)"; exit 1 }
    return ,@($src | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } })
}
$knobDeferred = '        if ($false) { }   # DEFECT: pre-2026-09-17 - a deferred row was a failure'
$knobInfo     = '        if ($false) { }   # DEFECT: pre-2026-09-17 - an informational row was a failure'
$knobRowWhy   = '        $why = if ($r.reason) { $r.reason } else { "DISM rejected every package file" }   # DEFECT: the pre-2026-09-17 read'
switch ($Defect) {
    ''         { }
    { $_ -in '1', 'prefix' } {
        $region = Swap-Guard $region 'deferred' $knobDeferred
        $region = Swap-Guard $region 'info'     $knobInfo
        $region = Swap-Guard $region 'rowwhy'   $knobRowWhy
    }
    'deferred' { $region = Swap-Guard $region 'deferred' $knobDeferred }
    'info'     { $region = Swap-Guard $region 'info'     $knobInfo }
    'fallback' { $region = Swap-Guard $region 'rowwhy'   $knobRowWhy }
    default    { Write-Host "FAIL unknown -Defect '$Defect' (1 | prefix | deferred | info | fallback)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wurender-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$regionFile = Join-Path $tmpRoot 'outcome-region.ps1'
[IO.File]::WriteAllLines($regionFile, [string[]]$region)
. $regionFile
Check 'extract: the region defines Get-RowWhy, Get-Outcome, Write-OutcomeHead, Write-OutcomeTail' `
      ((Get-Command Get-RowWhy, Get-Outcome, Write-OutcomeHead, Write-OutcomeTail -EA SilentlyContinue).Count -eq 4)

# --- the shipped file, as shipped ------------------------------------------------------------------
$shipped = Get-Content -LiteralPath $ScriptPath -Raw
Check 'shipped: the done branch renders through Get-Outcome / Write-OutcomeHead / Write-OutcomeTail' `
      ($shipped -match '\$outcome = Get-Outcome \$st' -and $shipped -match 'Write-OutcomeHead \$outcome \(\[bool\]\$st\.reboot_needed\)' -and
       $shipped -match 'if \(\(Write-OutcomeTail \$outcome\) -ne 0\) \{ exit 1 \}')
# Code lines only: the region's header comment quotes the measured line as history, which is allowed.
Check 'shipped: the invented cause "DISM rejected every package file" is gone from the handler''s code' `
      (@($lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'DISM rejected every package file' }).Count -eq 0)
Check 'shipped: exactly one # GUARD:deferred, # GUARD:info and # GUARD:rowwhy line each' `
      ((@($lines | Where-Object { $_ -match '# GUARD:deferred$' }).Count -eq 1) -and
       (@($lines | Where-Object { $_ -match '# GUARD:info$' }).Count -eq 1) -and
       (@($lines | Where-Object { $_ -match '# GUARD:rowwhy$' }).Count -eq 1))
Check 'shipped: the reboot block still re-asserts autologon from qubes-rpc-services before shutdown.exe' `
      ($shipped -match "Join-Path \`$qtRootForAl 'qubes-rpc-services\\ensure-autologon\.ps1'" -and $shipped -match 'shutdown\.exe /r /t 60')

# --- the replay: the region writes to $Err exactly as the handler does ----------------------------
$Err = New-Object System.IO.StringWriter
function Render([string]$json) {
    $Err.GetStringBuilder().Clear() | Out-Null
    $st = $json | ConvertFrom-Json
    $o  = Get-Outcome $st
    Write-OutcomeHead $o ([bool]$st.reboot_needed)
    $rc = Write-OutcomeTail $o
    $text = $Err.ToString()
    $out = @()
    if ($text.Length) { $out = @($text.TrimEnd("`r", "`n") -split "`r?`n") }
    foreach ($l in $out) { Write-Host "       > $l" }
    return [pscustomobject]@{ lines = $out; rc = [int]$rc; outcome = $o }
}
# dom0 (qube_connection.py::_collect_stderr) tries float(line) and float(line.split()[-1]); a line
# whose last token parses is swallowed as a progress value instead of being shown.
function Test-SwallowedByDom0([string]$line) {
    $tail = @($line.Trim() -split '\s+')[-1]
    $d = 0.0
    if ([double]::TryParse($tail, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $true }
    return ($tail -match '^[+-]?(inf|infinity|nan)$')
}
function CheckContract([string]$case, $r) {
    $bad = @($r.lines | Where-Object { Test-SwallowedByDom0 $_ })
    Check "contract: ${case} - no rendered line ends in a bare number (dom0 would swallow it as progress) [$($bad -join ' | ')]" ($bad.Count -eq 0)
}

# --- 1. the captured pass ---------------------------------------------------------------------------
$cap = $CapturedJson | ConvertFrom-Json
Check 'deferred: the captured status carries the row under test (KB5129195 ok=false state=deferred, why at files.why, no reason)' `
      ($cap.result[1].kb -eq 'KB5129195' -and $cap.result[1].ok -eq $false -and $cap.result[1].state -eq 'deferred' -and
       $cap.result[1].files.why -eq 'another package is already staged; installing it needs a reboot first' -and
       -not (@($cap.result[1].PSObject.Properties.Name) -contains 'reason'))
Write-Host '--- captured pass (win11de-gwt, ts 2026-09-17T00:59:09):'
$r = Render $CapturedJson
CheckEq 'deferred: captured pass - line 1 is the staged .NET update' $r.lines[0] 'staged (completes at restart): KB5126052'
CheckEq 'deferred: captured pass - KB5129195 is rendered deferred with its own why, not the DISM fallback' $r.lines[1] 'deferred KB5129195: another package is already staged; installing it needs a reboot first'
CheckEq 'deferred: captured pass - the operator is told what to do next' $r.lines[2] 'run this update again after the restart to install what was deferred'
CheckEq 'deferred: captured pass - exactly 3 outcome lines (no FAILED, no see-status pointer)' $r.lines.Count 3
CheckEq 'deferred: captured pass - exit code 0 (contract: 0 = success; the staged reboot completes it)' $r.rc 0
Check   'deferred: captured pass - the measured pre-fix line "FAILED KB5129195: DISM rejected every package file" is absent' `
        (-not ($r.lines -contains $MeasuredPreFix[1]))
Check   'deferred: captured pass - classified 1 ok, 1 deferred, 0 info, 0 failed' `
        ($r.outcome.ok.Count -eq 1 -and $r.outcome.deferred.Count -eq 1 -and $r.outcome.info.Count -eq 0 -and $r.outcome.failed.Count -eq 0)
CheckContract 'captured pass' $r

# The writer's second deferral shape: reason='deferred: ...' and no state key (:1643).
Write-Host '--- WU-native fallback deferral (reason=deferred:..., no state):'
$r = Render (StatusJson @($RowInstalledA, $RowDeferredWu) $true)
CheckEq 'deferred: WU-fallback shape - rendered deferred with its own reason (prefix stripped)' $r.lines[1] 'deferred KB2267602: a reboot-requiring package is already staged this session; the next pass installs this'
CheckEq 'deferred: WU-fallback shape - exit code 0' $r.rc 0
CheckContract 'WU-fallback deferral' $r

# --- 2. a genuinely failed row keeps failing, with its real reason --------------------------------
Write-Host '--- genuinely failed row with a recorded reason:'
$r = Render (StatusJson @($RowInstalledA, $RowFailedReason) $false)
CheckEq 'failed: line 1 names the installed KB' $r.lines[0] 'installed: KB5007651'
CheckEq 'failed: the row is rendered FAILED with its recorded reason' $r.lines[1] 'FAILED KB5000001: no catalog entry matches this Windows version/architecture'
CheckEq 'failed: the see-status pointer follows' $r.lines[2] 'see C:\ProgramData\Qubes\update-status.json on the qube for details'
CheckEq 'failed: exactly 3 lines' $r.lines.Count 3
CheckEq 'failed: exit code 1 (contract: anything but 0/100 = error)' $r.rc 1
CheckContract 'failed row' $r

Write-Host '--- DISM failure (file rows carry the rc, the row carries no reason):'
$r = Render (StatusJson @($RowFailedDism) $false 1)
CheckEq 'dism-rc: the real file and DISM rc are rendered, not an invented cause' $r.lines[0] 'FAILED KB5000002: windows11.0-kb5000002-x64_0000000000000000000000000000000000000000.msu rc=-2146498512'
CheckEq 'dism-rc: exit code 1' $r.rc 1
CheckContract 'DISM failure' $r

# --- 3. an all-installed pass -----------------------------------------------------------------------
Write-Host '--- all installed, no reboot:'
$r = Render (StatusJson @($RowInstalledA, $RowInstalledB) $false)
CheckEq 'installed: one line naming both KBs' ($r.lines -join ' | ') 'installed: KB5007651, KB890830'
CheckEq 'installed: exit code 0' $r.rc 0
CheckContract 'all installed' $r

# --- 4. informational rows are not failures ---------------------------------------------------------
Write-Host '--- an installed row + the wu-only-express informational row:'
$r = Render (StatusJson @($RowInstalledA, $RowInfo) $false)
CheckEq 'informational: the info row is rendered informational with its own reason' $r.lines[1] ('informational KB5071959: ' + (($RowInfo | ConvertFrom-Json).reason))
CheckEq 'informational: installed + informational -> exit code 0' $r.rc 0
CheckEq 'informational: no FAILED line anywhere' (@($r.lines | Where-Object { $_ -like 'FAILED *' }).Count) 0
CheckContract 'informational' $r

# Every non-failure class at once - the pass the mandate names: installed/staged/deferred/informational.
Write-Host '--- captured pass (staged + deferred) + an installed row + the informational row:'
$capRows = @($cap.result | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress })
$r = Render (StatusJson ($capRows + $RowInstalledA + $RowInfo) $true 4)
CheckEq 'deferred+informational: staged, deferred, installed and informational rows -> exit code 0' $r.rc 0
CheckEq 'deferred+informational: no FAILED line anywhere' (@($r.lines | Where-Object { $_ -like 'FAILED *' }).Count) 0
CheckEq 'deferred+informational: 4 lines - staged pair, deferred, its advice, informational' $r.lines.Count 4
CheckContract 'all non-failure classes' $r

# --- 5. a failure alongside a deferral: both told, failure decides the exit code ------------------
Write-Host '--- captured pass + a failed row:'
$r = Render (StatusJson ($capRows + $RowFailedReason) $true 3)
CheckEq 'deferred+failed: the deferred line is still its own why' $r.lines[1] 'deferred KB5129195: another package is already staged; installing it needs a reboot first'
CheckEq 'deferred+failed: the failed line carries its reason' $r.lines[3] 'FAILED KB5000001: no catalog entry matches this Windows version/architecture'
CheckEq 'deferred+failed: exit code 1' $r.rc 1
CheckContract 'deferred+failed' $r

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -EA SilentlyContinue
Write-Host ("--- {0} checks, {1} failed{2}" -f $script:run, $script:fail, $(if ($Defect) { " (defect knob: $Defect)" } else { '' }))
if ($script:fail -gt 0) { exit 1 }
exit 0
