# wu-save-atomic-test.ps1 - the status write must never be able to kill the pass it reports on.
#
# Measured 2026-09-21 on win11de-fresh, round 2: the Qube Manager handler tails update-status.json
# while a pass writes it, Set-Content hit the sharing violation, and the pass DIED - after it had
# already reported 3 to dom0. dom0 was left holding a number the pass never stood behind.
#
#   -Defect plainwrite   restore the plain Set-Content; the suite MUST then fail
param([string]$Defect = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src  = Get-Content -Raw (Join-Path $root 'guest/qubes-windows-update.ps1')
$m = [regex]::Match($src, "# ---- WU-SAVE-ATOMIC-BEGIN(.*?)# ---- WU-SAVE-ATOMIC-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: WU-SAVE-ATOMIC region not found"; exit 2 }
$region = $m.Groups[1].Value
if ($Defect -eq 'plainwrite') {
    $region = "function Save { `$script:St.ts=(Get-Date).ToString('s'); (`$script:St | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath `$StatusFile -Encoding UTF8 }"
} elseif ($Defect -ne '') { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (plainwrite)"; exit 2 }
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

Remove-Item -Recurse -Force $dir -EA SilentlyContinue
Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
