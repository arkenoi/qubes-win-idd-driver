# wu-catch-scope-test.ps1 - runs qubes-windows-update.ps1's MAIN CATCH (region WU-MAIN-CATCH) at SCRIPT scope, the scope it runs in on
# a guest, and checks that the 0x8024402C remedy survives it: the status object is still a dictionary, the restart is requested and dom0
# gets the reason.
#
# WHY SCRIPT SCOPE. PowerShell names are case-insensitive: at script scope a catch-block local $st IS $script:St. On 2026-10-02 that is
# exactly what silenced the remedy in every release since 09-21 (the error-site logging's `$st = ...ScriptStackTrace`), and
# tools/tests/wu-reason-test.ps1 could not see it because it runs its region inside a function, where $st is a different variable.
#   pwsh wu-catch-scope-test.ps1 <path-to-qubes-windows-update.ps1>
#   env WUCATCH_DEFECT=1 re-introduces the colliding `$st =` - the test must then FAIL.
param([Parameter(Mandatory)][string]$Script)
$ErrorActionPreference = 'Continue'
$src = Get-Content -LiteralPath $Script -Raw
$m = [regex]::Match($src, "# ---- WU-MAIN-CATCH-BEGIN[^\n]*\n(.*?)# ---- WU-MAIN-CATCH-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: region WU-MAIN-CATCH not found"; exit 2 }
$region = $m.Groups[1].Value
if ($env:WUCATCH_DEFECT -eq '1') {
    $region = $region.Replace('$stackText = "$($_.ScriptStackTrace)"', '$st = "$($_.ScriptStackTrace)"').Replace('if ($stackText)', 'if ($st)').Replace('($stackText -split', '($st -split')
}
if ($region -notmatch 'ScriptStackTrace') { Write-Output "INSTRUMENT: the region no longer logs the stack - re-check what this test covers"; exit 2 }

# Stand-ins at SCRIPT scope, as on the guest: the status writer, the log, the proxy probe (reachable), the boot time, the stamp store.
$script:Saves = 0
function Save { $script:Saves++ }
function Log($m) { }
function Test-ProxyServesWu { 'reachable status=200' }
function Get-CimInstance { param($ClassName, $EA) [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-02T14:09:00Z' } }
function Get-ItemProperty { param($Path, $Name, $EA) [pscustomobject]@{} }
function Set-ItemProperty { param($Path, $Name, $Value, $Type) }
function Test-Path { param($Path) $true }
function New-Item { param($Path, [switch]$Force) }
$Proxy = 'http://127.0.0.1:8082'
$script:St = [ordered]@{ action='full'; phase='scan'; error=$null; reboot_needed=$false }

# THE CASE: the search throws exactly what the guest's search threw, and the catch runs at script scope.
try { throw 'Ausnahme von HRESULT: 0x8024402C' } catch { Invoke-Expression $region }

$fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }
Check 'the status object is still a dictionary after the catch' ($script:St -is [System.Collections.Specialized.OrderedDictionary])
$err = if ($script:St -is [System.Collections.Specialized.OrderedDictionary]) { [string]$script:St.error } else { '' }
Check 'the phase is error'                                      ($script:St -is [System.Collections.Specialized.OrderedDictionary] -and $script:St.phase -eq 'error')
Check 'dom0 is given the measured reason (WU did not use the proxy)' ($err -match 'did not use the configured proxy')
Check 'the remedy is requested (a restart clears it)'          ($err -match 'RESTART CLEARS THIS IMMEDIATELY')
Check 'reboot_needed is set, so the accounted restart happens' ($script:St -is [System.Collections.Specialized.OrderedDictionary] -and $script:St.reboot_needed -eq $true)
Check 'the status was saved after the remedy, not only before' ($script:Saves -ge 2)
if ($fails -eq 0) { Write-Output 'PASS  the main catch keeps the status and runs the remedy at script scope'; exit 0 }
Write-Output "FAIL  $fails check(s)"; exit 1
