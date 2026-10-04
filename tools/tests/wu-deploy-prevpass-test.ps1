<#
  wu-deploy-prevpass-test.ps1 - the deploy step's gate for a cut-off update pass (guest/install-updater-agent.ps1, region
  DEPLOY-PREVPASS), run for real against a fake status file, a fake process table and a fake boot time.

  WHY (2026-10-04): the rz39 (4.3.34) gate's WIN10-upgrade failed with updater_agent=error QWTUPDSTATEUNKNOWN - the entry fixture
  had been shut down while its boot scan was at phase 'init', and the deploy refused every cut-off pass, where the updater's own gate
  (WU-PREVPASS-GATE, the owner's D3 decision) lets a cut-off SCAN and a pass from an EARLIER boot through. Jev: root cause 0.98.

  Scenarios: a cut-off scan in this boot deploys; a cut-off install from an earlier boot deploys; a cut-off install in THIS boot
  refuses (QWTUPDSTATEUNKNOWN), as does one whose timing cannot be read - unless a pass already refused it in an earlier boot (the
  requested restart has happened); a terminal status deploys.
  -Defect deployscan     the scan exemption removed          -> the cut-off scan refuses   (must FAIL)
  -Defect deployboot     the earlier-boot exemption removed  -> the earlier-boot install refuses (must FAIL)
  -Defect deployrefused  the refused-earlier exemption removed -> the install refused in an earlier boot refuses again (must FAIL)
#>
param([string]$Defect = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src = Get-Content -Raw -LiteralPath (Join-Path $root 'guest/install-updater-agent.ps1')
$b = $src.IndexOf('# ---- DEPLOY-PREVPASS-BEGIN'); $e = $src.IndexOf('# ---- DEPLOY-PREVPASS-END')
if ($b -lt 0 -or $e -lt $b) { Write-Output 'FAIL the DEPLOY-PREVPASS region is missing - nothing ran'; exit 2 }
$region = $src.Substring($b, $e - $b)
switch ($Defect) {
    ''           { }
    'deployscan' { $region = ($region -split "`n" | ForEach-Object { if ($_ -match '# GUARD:deployscan$') { '        if ($false) {   # DEFECT: no scan exemption' } else { $_ } }) -join "`n" }
    'deployboot' { $region = ($region -split "`n" | ForEach-Object { if ($_ -match '# GUARD:deployboot$') { '        } elseif ($false) {   # DEFECT: no earlier-boot exemption' } else { $_ } }) -join "`n" }
    'deployrefused' { $region = ($region -split "`n" | ForEach-Object { if ($_ -match '# GUARD:deployrefused$') { '        } elseif ($false) {   # DEFECT: no refused-earlier exemption' } else { $_ } }) -join "`n" }
    default      { Write-Output "FAIL unknown -Defect '$Defect'"; exit 2 }
}
foreach ($g in 'deployscan', 'deployboot', 'deployrefused') { if ($Defect -ne $g -and $region -notmatch "# GUARD:$g") { Write-Output "FAIL GUARD:$g not found in the region"; exit 2 } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('deploy-prevpass-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$statusPath = Join-Path $tmp 'update-status.json'
$region = $region.Replace("'C:\ProgramData\Qubes\update-status.json'", "'$statusPath'")

$script:Logged = New-Object System.Collections.ArrayList
function Log($m) { [void]$script:Logged.Add([string]$m) }
$script:FakeBoot = [datetime]'2026-10-04T08:51:00'
$script:LiveProc = $null
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName) [pscustomobject]@{ LastBootUpTime = $script:FakeBoot } }
function Get-Process { [CmdletBinding()] param([int]$Id) $script:LiveProc }

$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what  [$detail]"; $script:fail++ }
}
function Run-Gate($status, $liveProc = $null) {
    Set-Content -LiteralPath $statusPath -Value ($status | ConvertTo-Json) -Encoding UTF8
    $script:LiveProc = $liveProc; $script:Logged.Clear()
    try { . ([scriptblock]::Create($region)); return 'deployed' } catch { return "refused: $($_.Exception.Message)" }
}

$r = Run-Gate @{ action = 'scan'; phase = 'init'; owner_pid = 6052; owner_pid_start = '2026-10-04T08:52:00'; ts = '2026-10-04T08:52:00' }
Check 'a cut-off scan in THIS boot deploys (a scan installs nothing)' ($r -eq 'deployed') $r
Check '  and says why' ((@($script:Logged) -join ' ') -match 'a scan only searches and installs nothing') (@($script:Logged) -join ' | ')

$r = Run-Gate @{ action = 'install'; phase = 'install'; owner_pid = 4100; owner_pid_start = '2026-10-04T01:05:00'; ts = '2026-10-04T01:05:30' }
Check 'a cut-off install that last wrote BEFORE this boot deploys (Windows settled it during boot)' ($r -eq 'deployed') $r
Check '  and says why' ((@($script:Logged) -join ' ') -match 'before this qube.s last restart') (@($script:Logged) -join ' | ')

$r = Run-Gate @{ action = 'install'; phase = 'install'; owner_pid = 4100; owner_pid_start = '2026-10-04T08:52:10'; ts = '2026-10-04T08:52:30' }
Check 'a cut-off install in THIS boot refuses with QWTUPDSTATEUNKNOWN' ($r -like 'refused: QWTUPDSTATEUNKNOWN*') $r

$r = Run-Gate @{ action = 'install'; phase = 'install'; owner_pid = 4100; owner_pid_start = '2026-10-04T08:52:10'; ts = 'garbage' }
Check 'a cut-off install whose timing cannot be read refuses (unknown is not "earlier")' ($r -like 'refused: QWTUPDSTATEUNKNOWN*') $r

$r = Run-Gate @{ action = 'install'; phase = 'install'; owner_pid = 4100; owner_pid_start = '2026-10-04T08:52:10'; ts = 'garbage'; refused_boot = '2026-10-04T01:00:00' }
Check 'an unreadable-timing install a pass refused in an EARLIER boot deploys (the requested restart happened)' ($r -eq 'deployed') $r
Check '  and says why' ((@($script:Logged) -join ' ') -match 'refused it in an earlier boot') (@($script:Logged) -join ' | ')

$r = Run-Gate @{ action = 'install'; phase = 'install'; owner_pid = 4100; owner_pid_start = '2026-10-04T08:52:10'; ts = 'garbage'; refused_boot = '2026-10-04T08:51:00' }
Check 'an unreadable-timing install a pass refused in THIS boot still refuses' ($r -like 'refused: QWTUPDSTATEUNKNOWN*') $r

$r = Run-Gate @{ action = 'install'; phase = 'done'; owner_pid = 4100; ts = '2026-10-04T08:52:30' }
Check 'a terminal status deploys (no gate)' ($r -eq 'deployed') $r

# (No live-owner case here: pwsh 7's ConvertFrom-Json turns the ISO owner_pid_start into a DateTime where the guest's Windows
#  PowerShell 5.1 keeps a string, so that comparison cannot be replayed faithfully on this host - and this change does not touch it.)

Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
if ($fail) { Write-Output "--- $fail FAILED"; exit 1 }
Write-Output '--- deploy gate kept'
