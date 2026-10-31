# wu-save-atomic-test.ps1 - the status write must never be able to kill the pass it reports on.
#
# Measured 2026-09-21 on win11de-fresh, round 2: the Qube Manager handler tails update-status.json
# while a pass writes it, Set-Content hit the sharing violation, and the pass DIED - after it had
# already reported 3 to dom0. dom0 was left holding a number the pass never stood behind.
#
#   -Defect plainwrite   restore the plain Set-Content; the suite MUST then fail
#   -Defect clockblind   strip the monotonic/jump branch; the clock checks MUST then fail
param([string]$Defect = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src  = Get-Content -Raw (Join-Path $root 'guest/qubes-windows-update.ps1')
$m = [regex]::Match($src, "# ---- WU-SAVE-ATOMIC-BEGIN(.*?)# ---- WU-SAVE-ATOMIC-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: WU-SAVE-ATOMIC region not found"; exit 2 }
$region = $m.Groups[1].Value
if ($Defect -eq 'plainwrite') {
    $region = "function Save { `$script:St.ts=(Get-Date).ToString('s'); (`$script:St | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath `$StatusFile -Encoding UTF8 }"
} elseif ($Defect -eq 'clockblind') {
    # Take the monotonic clock back out, leaving the wall-clock duration the product used to write.
    $region = [regex]::Replace($region, '(?s)\n\s*if \(\$script:PassWatch\).*?\n(\s*)# ---- WU-SAVE-ATOMIC', "`n`$1# ---- WU-SAVE-ATOMIC")
    if ($region -match '\$script:PassWatch') { Write-Output 'INSTRUMENT: clockblind did not strip the branch'; exit 2 }
} elseif ($Defect -ne '') { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (plainwrite, clockblind)"; exit 2 }
Invoke-Expression $region

$pass = 0; $fail = 0
function Check($what, $got, $want) {
    if ("$got" -eq "$want") { Write-Output "  PASS  $what"; $script:pass++ }
    else { Write-Output "  FAIL  $what (got '$got', want '$want')"; $script:fail++ }
}
function Log($m) { }   # the region logs on give-up; the suite does not care what it says

$dir = Join-Path ([IO.Path]::GetTempPath()) ("wusave-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force $dir | Out-Null
$StatusFile = Join-Path $dir 'update-status.json'
$script:St = [ordered]@{ action = 'full'; count = 3; ts = $null }

# 1. the ordinary case still works
Save
Check "an unlocked status file is written" (Test-Path $StatusFile) 'True'
Check "and it is valid JSON with the payload" ((Get-Content -Raw $StatusFile | ConvertFrom-Json).count) 3

# 2. THE MEASURED CASE: a reader holds the file open the way the handler does.
$hold = [IO.File]::Open($StatusFile, 'Open', 'Read', 'None')   # FileShare.None - no writer may in
$script:St.count = 99
$threw = $false
try { Save } catch { $threw = $true }
$hold.Close()
Check "a locked status file does NOT kill the pass" $threw 'False'

# 3. and once the lock is gone, writing works again - the state is not left broken
$script:St.count = 7
Save
Check "the next write lands after the lock clears" ((Get-Content -Raw $StatusFile | ConvertFrom-Json).count) 7
Check "no .tmp file is left behind" (Test-Path "$StatusFile.tmp") 'False'

# 4. A CLOCK THAT JUMPS MID-PASS MUST NOT CORRUPT THE DURATION.
# Measured 2026-10-30: a guest cloned from a golden sealed on the other side of a DST boundary
# boots ~3594 s behind dom0 (findings/issues.md ETWCLOCKDST), and whatever corrects it does so
# WHILE a pass may be running. A duration taken as (Get-Date - start) then reads an hour longer
# than the pass really took - which is how an update scan comes to be recorded at ">66 min" and
# its task limit raised to PT2H. The pass clock is a Stopwatch, which a clock set cannot move.
$script:PassWatch           = [System.Diagnostics.Stopwatch]::StartNew()
$script:PassWallStart       = (Get-Date).AddSeconds(-3594)   # the wall clock jumped FORWARD under us
$script:ClockJumpLogged     = $false
$script:ClockJumpThresholdSec = 30
Start-Sleep -Milliseconds 50
$script:St.count = 11
Save
$j = Get-Content -Raw $StatusFile | ConvertFrom-Json
Check "a forward clock jump is REPORTED, not absorbed" ($j.clock_jump_s -gt 3000) 'True'
Check "and elapsed_s stays monotonic, not the wall delta" ($j.elapsed_s -lt 60) 'True'

# no jump: the field must be absent, so its presence always means something happened
$dir2 = Join-Path ([IO.Path]::GetTempPath()) ("wusave2-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force $dir2 | Out-Null
$StatusFile = Join-Path $dir2 'update-status.json'
$script:PassWatch     = [System.Diagnostics.Stopwatch]::StartNew()
$script:PassWallStart = Get-Date
Save
$j2 = Get-Content -Raw $StatusFile | ConvertFrom-Json
Check "a steady clock reports no jump at all" ($null -eq $j2.clock_jump_s) 'True'
Check "and still records a monotonic elapsed_s" ($null -ne $j2.elapsed_s) 'True'
Remove-Item -Recurse -Force $dir2 -EA SilentlyContinue

Remove-Item -Recurse -Force $dir -EA SilentlyContinue
Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
