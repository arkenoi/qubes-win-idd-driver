# wu-catch-scope-test.ps1 - runs qubes-windows-update.ps1's MAIN CATCH (region WU-MAIN-CATCH) at SCRIPT scope, the scope it runs in on
# a guest, and checks that the 0x8024402C remedy survives it: the status object is still a dictionary, the restart is requested, dom0
# gets the reason - and gets it FIRST: no save may publish the terminal phase before the reason is final.
#
# WHY SCRIPT SCOPE. PowerShell names are case-insensitive: at script scope a catch-block local $st IS $script:St. On 2026-10-02 that is
# exactly what silenced the remedy in every release since 09-21 (the error-site logging's `$st = ...ScriptStackTrace`), and
# tools/tests/wu-reason-test.ps1 could not see it because it runs its region inside a function, where $st is a different variable.
# WHY THE ORDER OF SAVES. guest/wu-update.ps1 (dom0's view) polls the status every 3 s and renders the FIRST terminal phase it reads.
# On 2026-10-02 (rz31, GWeck's environment) the catch published phase=error with the bare exception and the reason 3 s later, and dom0
# printed "update failed: Ausnahme von HRESULT: 0x8024402C" while the status ended with the reason and the restart request.
#   pwsh wu-catch-scope-test.ps1 -Script <path-to-qubes-windows-update.ps1>
#   env WUCATCH_DEFECT=1         re-introduces the colliding `$st =`            - the test must then FAIL.
#   env WUCATCH_DEFECT=race      publishes phase=error before the diagnosis     - the test must then FAIL.
#   env WUCATCH_DEFECT=nofinally the terminal publication is skipped when the diagnosis throws - the test must then FAIL.
param([Parameter(Mandatory)][string]$Script)
$ErrorActionPreference = 'Continue'
$src = Get-Content -LiteralPath $Script -Raw
$m = [regex]::Match($src, "# ---- WU-MAIN-CATCH-BEGIN[^\n]*\n(.*?)# ---- WU-MAIN-CATCH-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: region WU-MAIN-CATCH not found"; exit 2 }
$region = $m.Groups[1].Value
switch ($env:WUCATCH_DEFECT) {
  '1' {
    $region = $region.Replace('$stackText = "$($_.ScriptStackTrace)"', '$st = "$($_.ScriptStackTrace)"').Replace('if ($stackText)', 'if ($st)').Replace('($stackText -split', '($st -split')
  }
  'race' {
    $d = $region.Replace("`$script:St.phase='diagnosing'", "`$script:St.phase='error'")
    if ($d -eq $region) { Write-Output "INSTRUMENT: the race defect could not be injected - the region no longer starts in 'diagnosing'"; exit 2 }
    $region = $d
  }
  'nofinally' {
    $d = [regex]::Replace($region, "(?s)\r?\n  \} finally \{\r?\n(?:[ \t]*#[^\n]*\n)*[ \t]*\`$script:St\.phase='error'; Save\r?\n  \}", "`n  } catch { throw }`n  `$script:St.phase='error'; Save")
    if ($d -eq $region) { Write-Output "INSTRUMENT: the nofinally defect could not be injected - the terminal publication is no longer in a finally"; exit 2 }
    $region = $d
  }
}
if ($region -notmatch 'ScriptStackTrace') { Write-Output "INSTRUMENT: the region no longer logs the stack - re-check what this test covers"; exit 2 }

# Stand-ins at SCRIPT scope, as on the guest: the status writer (recording what each save PUBLISHED), the log, the proxy probe
# (reachable), the boot time, the stamp store.
$script:Saves = 0
$script:Snaps = @()
function Save {
  $script:Saves++
  if ($script:St -is [System.Collections.Specialized.OrderedDictionary]) {
    $script:Snaps += [pscustomobject]@{ phase = "$($script:St.phase)"; error = "$($script:St.error)" }
  }
}
function Log($m) { }
function Test-ProxyServesWu { 'reachable status=200' }
function Get-CimInstance { param($ClassName, $EA) [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-02T14:09:00Z' } }
function Get-ItemProperty { param($Path, $Name, $EA) [pscustomobject]@{} }
function Set-ItemProperty { param($Path, $Name, $Value, $Type) }
function Test-Path { param($Path) $true }
function New-Item { param($Path, [switch]$Force) }
$Proxy = 'http://127.0.0.1:8082'
$script:St = [ordered]@{ action='full'; phase='scan'; error=$null; reboot_needed=$false }

# CASE 1: the search throws exactly what the guest's search threw, and the catch runs at script scope.
try { throw 'Ausnahme von HRESULT: 0x8024402C' } catch { try { Invoke-Expression $region } catch { } }

$fails = 0
function Check([string]$what, [bool]$ok) { if ($ok) { "  ok   $what" } else { "  FAIL $what"; $script:fails++ } }
Check 'the status object is still a dictionary after the catch' ($script:St -is [System.Collections.Specialized.OrderedDictionary])
$err = if ($script:St -is [System.Collections.Specialized.OrderedDictionary]) { [string]$script:St.error } else { '' }
Check 'the phase is error'                                      ($script:St -is [System.Collections.Specialized.OrderedDictionary] -and $script:St.phase -eq 'error')
Check 'dom0 is given the measured reason (WU did not use the proxy)' ($err -match 'did not use the configured proxy')
Check 'the remedy is requested (a restart clears it)'          ($err -match 'RESTART CLEARS THIS IMMEDIATELY')
Check 'reboot_needed is set, so the accounted restart happens' ($script:St -is [System.Collections.Specialized.OrderedDictionary] -and $script:St.reboot_needed -eq $true)
Check 'the status was saved after the remedy, not only before' ($script:Saves -ge 2)
$early = @($script:Snaps | Where-Object { $_.phase -eq 'error' -and $_.error -notmatch 'did not use the configured proxy' })
Check 'no save published phase=error before the reason was final (dom0 renders the FIRST terminal phase it reads)' ($early.Count -eq 0)
Check 'the last save published phase=error'                    ($script:Snaps.Count -gt 0 -and $script:Snaps[-1].phase -eq 'error')

# CASE 2: the DIAGNOSIS itself throws. The terminal phase must still be published, with the raw message - a pass that ends in
# 'diagnosing' would read to dom0 as a pass that died, and the error would be lost.
$script:Saves = 0; $script:Snaps = @()
$script:St = [ordered]@{ action='full'; phase='scan'; error=$null; reboot_needed=$false }
function Test-ProxyServesWu { throw 'probe exploded' }
try { throw 'Ausnahme von HRESULT: 0x8024402C' } catch { try { Invoke-Expression $region } catch { } }
Check 'a throwing diagnosis still ends with phase=error published' ($script:Snaps.Count -gt 0 -and $script:Snaps[-1].phase -eq 'error')
Check '...carrying the raw error, not nothing'                 ($script:Snaps.Count -gt 0 -and $script:Snaps[-1].error -match '0x8024402C')

if ($fails -eq 0) { Write-Output 'PASS  the main catch keeps the status, runs the remedy at script scope, and publishes the terminal phase once, last'; exit 0 }
Write-Output "FAIL  $fails check(s)"; exit 1
