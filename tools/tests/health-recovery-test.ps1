<#
.SYNOPSIS
    Offline suite for guest/health-check.ps1 section 2b (region SVC-RECOVERY-CHECK): the recovery that docs/ADR-supervision.md 4
    promises is asserted on every service of ours - QdbDaemon, QrexecAgent, QubesGuiWatchdog (Set-QubesServiceRecovery) and
    QwtngNetSetup (pvnic-selfprime.ps1) - from the registry's raw FailureActions. Runs under pwsh on Linux: the registry
    is a fake this suite scripts, sc.exe is a function.

.DESCRIPTION
    The region is extracted from the SHIPPED file by its marker lines and dot-sourced into a scope that provides Check,
    Test-Path, Get-ItemProperty and sc.exe. FailureActions is built here exactly as the SCM stores it (dwResetPeriod; two
    string offsets; cActions; actions offset; SC_ACTION{Type,Delay}...), so the parse the check does is exercised, not
    assumed. Exit 0 = every case matched; 1 = at least one FAIL.

.PARAMETER Defect
    recovfour: the region is run with its 2026-10-03 list reverted to the two control-channel services, so an unarmed
    QubesGuiWatchdog or QwtngNetSetup passes - tools/tests/health-recovery-selftest.sh requires the suite to FAIL then.
#>
[CmdletBinding()]
param([string]$Defect = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

$script:run = 0; $script:fail = 0
function Assert([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    Microsoft.PowerShell.Utility\Write-Host "$tag $name$suffix"
}
function Get-Region([string]$file, [string]$name) {
    $lines = @(Get-Content -LiteralPath (Join-Path $repoRoot $file))
    $b = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $e = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $b[0] -ge $e[0]) { Microsoft.PowerShell.Utility\Write-Host "FAIL marker extraction $file ${name}: got $($b.Count)/$($e.Count)"; exit 1 }
    return ,@($lines[($b[0] + 1)..($e[0] - 1)])
}
$region = Get-Region 'guest/health-check.ps1' 'SVC-RECOVERY-CHECK'
switch ($Defect) {
    '' { }
    'recovfour' {
        $hit = @($region | Where-Object { $_ -match '# GUARD:recovfour$' })
        if ($hit.Count -ne 1) { Microsoft.PowerShell.Utility\Write-Host "FAIL defect: expected exactly 1 '# GUARD:recovfour' line, found $($hit.Count)"; exit 1 }
        $region = @($region | ForEach-Object { if ($_ -match '# GUARD:recovfour$') { "foreach (`$svcName in 'QdbDaemon', 'QrexecAgent') {   # DEFECT: the two control-channel services only" } else { $_ } })
    }
    default { Microsoft.PowerShell.Utility\Write-Host "FAIL unknown -Defect '$Defect'"; exit 1 }
}

# --- the fake registry ------------------------------------------------------------------------------------------------
# $script:Reg[<service>] = @{ fa = <byte[] FailureActions or $null>; flag = <0/1/$null> }; absent service = no key
$script:Reg = @{}
function New-FailureActions([uint32]$reset, [int]$restarts, [int]$others = 0) {
    $n = $restarts + $others
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange([BitConverter]::GetBytes([uint32]$reset)); $b.AddRange([BitConverter]::GetBytes([uint32]0)); $b.AddRange([BitConverter]::GetBytes([uint32]0))
    $b.AddRange([BitConverter]::GetBytes([uint32]$n)); $b.AddRange([BitConverter]::GetBytes([uint32]20))
    $delays = @(5000, 15000, 60000)
    for ($i = 0; $i -lt $restarts; $i++) { $b.AddRange([BitConverter]::GetBytes([uint32]1)); $b.AddRange([BitConverter]::GetBytes([uint32]$delays[$i % 3])) }
    for ($i = 0; $i -lt $others; $i++) { $b.AddRange([BitConverter]::GetBytes([uint32]0)); $b.AddRange([BitConverter]::GetBytes([uint32]0)) }
    return ,$b.ToArray()
}
function Test-Path { param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
    $p = $Path; if ($LiteralPath) { $p = $LiteralPath }
    if ($p -match '^HKLM:\\SYSTEM\\CurrentControlSet\\Services\\([A-Za-z]+)$') { return $script:Reg.ContainsKey($Matches[1]) }
    return $false
}
function Get-ItemProperty { [CmdletBinding()] param([string]$Path, [string]$Name)
    if ($Path -notmatch '^HKLM:\\SYSTEM\\CurrentControlSet\\Services\\([A-Za-z]+)$') { return $null }
    $e = $script:Reg[$Matches[1]]; if (-not $e) { return $null }
    $o = [pscustomobject]@{}
    if ($Name -eq 'FailureActions') { $o | Add-Member -NotePropertyName FailureActions -NotePropertyValue $e.fa }
    if ($Name -eq 'FailureActionsOnNonCrashFailures') { $o | Add-Member -NotePropertyName FailureActionsOnNonCrashFailures -NotePropertyValue $e.flag }
    return $o
}
function sc.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $e = $script:Reg[$a[1]]
    if ($a[0] -eq 'qfailure' -and $e -and $e.fa) { return "SERVICE_NAME: $($a[1])`n        RESET_PERIOD (in seconds)    : $([BitConverter]::ToUInt32($e.fa, 0))`n" }
    return '[SC] QueryServiceConfig2 FAILED 1060'
}
$script:checks = @{}
function Check([string]$name, [bool]$pass, $evidence) { $script:checks[$name] = @{ pass = $pass; evidence = $evidence } }
function Invoke-Region { $script:checks.Clear(); . ([scriptblock]::Create(($region -join "`n"))); return $script:checks['service_recovery_configured'] }
function Set-Armed([string]$svc) { $script:Reg[$svc] = @{ fa = (New-FailureActions 86400 3); flag = 1 } }

# =====================================================================================================================
$script:Reg.Clear()
foreach ($s in 'QdbDaemon', 'QrexecAgent', 'QubesGuiWatchdog', 'QwtngNetSetup') { Set-Armed $s }
$c = Invoke-Region
Assert 'all four armed: PASS' ($c.pass)
Assert 'all four armed: each reported configured, with 3 restart actions and the flag' (@($c.evidence.services.Keys).Count -eq 4 -and @($c.evidence.services.Values | Where-Object { $_.configured -and $_.restart_actions -eq 3 -and $_.noncrash_flag -eq 1 }).Count -eq 4)
Assert 'all four armed: the sc qfailure RESET_PERIOD corroborates' (@($c.evidence.services.Values | Where-Object { $_.sc_qfailure_reset -eq 86400 }).Count -eq 4)
Assert 'all four armed: the want names every service and who arms it' ($c.evidence.want -like '*QubesGuiWatchdog from Set-QubesServiceRecovery; QwtngNetSetup from pvnic-selfprime*')

$script:Reg.Remove('QwtngNetSetup')
$c = Invoke-Region
Assert 'QwtngNetSetup absent (no applier on this guest class): PASS, recorded as absent_by_class' ($c.pass -and $c.evidence.services['QwtngNetSetup'].absent_by_class -eq $true)

Set-Armed 'QwtngNetSetup'
$script:Reg['QwtngNetSetup'] = @{ fa = (New-FailureActions 0 0); flag = $null }
$c = Invoke-Region
Assert 'QwtngNetSetup present but unarmed (RESET_PERIOD 0, no actions, no flag): FAIL' (-not $c.pass -and -not $c.evidence.services['QwtngNetSetup'].configured)

Set-Armed 'QwtngNetSetup'
$script:Reg['QubesGuiWatchdog'] = @{ fa = (New-FailureActions 0 0); flag = $null }
$c = Invoke-Region
Assert 'QubesGuiWatchdog unarmed (the pre-2026-10-03 state of the MSI): FAIL' (-not $c.pass -and -not $c.evidence.services['QubesGuiWatchdog'].configured)

Set-Armed 'QubesGuiWatchdog'
$script:Reg['QrexecAgent'] = @{ fa = (New-FailureActions 86400 3); flag = 0 }
$c = Invoke-Region
Assert 'QrexecAgent armed but the non-crash flag off: FAIL' (-not $c.pass -and -not $c.evidence.services['QrexecAgent'].configured)

$script:Reg['QrexecAgent'] = @{ fa = (New-FailureActions 86400 2 1); flag = 1 }
$c = Invoke-Region
Assert 'QrexecAgent with two restarts and a none action: FAIL (three restarts wanted)' (-not $c.pass -and $c.evidence.services['QrexecAgent'].restart_actions -eq 2)

$script:Reg['QrexecAgent'] = @{ fa = (New-FailureActions 3600 3); flag = 1 }
$c = Invoke-Region
Assert 'QrexecAgent with a different reset period: FAIL (86400 wanted)' (-not $c.pass -and $c.evidence.services['QrexecAgent'].reset_period -eq 3600)

Set-Armed 'QrexecAgent'
$script:Reg.Remove('QdbDaemon')
$c = Invoke-Region
Assert 'QdbDaemon absent (never acceptable): FAIL, present=false' (-not $c.pass -and -not $c.evidence.services['QdbDaemon'].present)

Microsoft.PowerShell.Utility\Write-Host "$($script:run) checks, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
