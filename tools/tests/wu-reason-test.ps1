# wu-reason-test.ps1 - replay the SHIPPED decision that turns a 0x8024402C pass failure into a
# REASON for dom0 (GUARD:reasonmeasured), offline. No rig, no guest.
#
# WHY THIS EXISTS. 0x8024402C is WU_E_PT_WINHTTP_NAME_NOT_RESOLVED, and on a routeless guest it has
# two causes dom0 must never be left to guess between: our proxy was not usable, or Windows Update
# did not use it. Measured on three clones of the German 25H2 golden 2026-09-21: WinHTTP through
# 127.0.0.1:8082 fetches the same service-registration endpoint (HTTP 200) at the very moment WU
# fails on it, and neither re-applying the machine proxy nor populating the service account's proxy
# changes anything. The shipped code therefore PROBES at failure time and reports what it measured.
#
# The suite extracts WU-DIAGNOSE-REASON from the shipped script and drives it with each probe
# outcome. -Defect <knob> re-introduces a specific defect so the suite MUST fail on the check that
# knob targets; a guard never seen to fail is decoration.
param([string]$Defect = '', [string]$ScriptPath = '')
$ErrorActionPreference = 'Stop'
if ($ScriptPath) { $script = $ScriptPath }
else {
  $root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script = Join-Path $root 'guest/qubes-windows-update.ps1'
}
if (-not (Test-Path $script)) { Write-Output "INSTRUMENT: $script not found"; exit 2 }
$src = Get-Content -Raw $script
$m = [regex]::Match($src, "# ---- WU-DIAGNOSE-REASON-BEGIN(.*?)# ---- WU-DIAGNOSE-REASON-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: region WU-DIAGNOSE-REASON not found"; exit 2 }
$region = $m.Groups[1].Value

switch ($Defect) {
    # the state before this change: dom0 gets the bare HRESULT and no reason at all
    'rawerror'  { $region = $region -replace '(?s)if \(\$msg -match .8024402C.\) \{.*', '' }
    # asserts the Windows-Update-did-not-use-it reason whatever the probe found - which is the
    # difference between a measured reason and a story
    'assertwithoutprobe' { $region = $region.Replace("if (`$probeResult -match '^reachable status=(\d+)')", 'if ($true)') }
    # re-introduces a duration claim, which three subjects do not support (Jev timer_claim 0.25)
    'claimtimer' { $region = $region.Replace('the pass after the restart searches normally', 'the pass after the restart searches normally within 15 minutes') }
    # asks for a restart every time, including when one was already asked for in this boot - a
    # reboot loop dressed as a remedy
    'rebootloop' { $region = $region.Replace('} elseif ($askedFor -eq $bootNow) {', '} elseif ($false) {') }
    # reports the reason but requests nothing, which is where this started: the admin is told what
    # happened and given nothing to do
    'noremedy'   { $region = $region.Replace('$script:St.reboot_needed = $true', '$null = $true') }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown defect knob '$Defect'"; exit 2 }
}

$fails = 0; $checks = 0
function Check([string]$what, [bool]$ok) {
    $script:checks++
    if ($ok) { Write-Output "  ok   $what" } else { Write-Output "  FAIL $what"; $script:fails++ }
}
function Run([string]$msg, [string]$probeResult) {
    $script:St = [ordered]@{ phase='error'; error=$msg; reboot_needed=$false }
    $Proxy = 'http://127.0.0.1:8082'
    function Save {}
    function Log($m) {}
    # Stand-ins for the two reads the remedy makes. The BOOT time is fixed, and the stamp either
    # matches it (a restart was already asked for in this boot) or does not.
    function Get-CimInstance { param($ClassName,[switch]$EA) [pscustomobject]@{ LastBootUpTime = [datetime]'2026-09-21T09:00:00Z' } }
    function Get-ItemProperty { param($Path,$Name,$EA)
        if ($script:AlreadyAsked) { return [pscustomobject]@{ ProxyStateRestartAskedBoot = ([datetime]'2026-09-21T09:00:00Z').ToUniversalTime().ToString('o') } }
        return [pscustomobject]@{} }
    function Set-ItemProperty { param($Path,$Name,$Value,$Type) }
    function Test-Path { param($Path) $true }
    function New-Item { param($Path,[switch]$Force) }
    Invoke-Expression $region
    return [string]$script:St.error
}

Write-Output 'CASE 0x8024402C, and the proxy WAS usable at that moment'
$e = Run 'Ausnahme von HRESULT: 0x8024402C' 'reachable status=200'
Check 'names Windows Update as not having used the proxy' ($e -match 'did not use the configured proxy')
Check 'carries the MEASUREMENT that proves it (the HTTP status)' ($e -match 'HTTP 200')
Check 'says dom0 was told nothing about availability'          ($e -match 'no update state was reported to dom0')
Check 'claims NO duration - three subjects do not support one' (-not ($e -match '\d+\s*(minutes|minute|min)\b'))
Check 'promises no retry loop, just the next pass'             ($e -match 'searches normally')

Write-Output 'CASE the remedy: a restart is REQUESTED, once, and recorded'
$script:FakeReg = @{}
$e = Run 'Ausnahme von HRESULT: 0x8024402C' 'reachable status=200'
Check 'asks for the restart that is measured to clear it' ($e -match 'RESTART CLEARS THIS IMMEDIATELY')
Check 'and sets reboot_needed so the existing accounting performs it' ($script:St.reboot_needed -eq $true)
Check 'still claims no duration'                        (-not ($e -match '\d+\s*(minutes|minute|min)\b'))

Write-Output 'CASE a restart was ALREADY requested in this boot - no loop'
$script:AlreadyAsked = $true
$e = Run 'Ausnahme von HRESULT: 0x8024402C' 'reachable status=200'
Check 'does NOT ask again'                              ($e -match 'not asking again')
Check 'says the restart has NOT been performed, not that it failed' ($e -match 'has NOT been performed yet')
Check 'does not claim the remedy stopped working'      (-not ($e -match 'stopped working'))
Check 'and does not set reboot_needed a second time'    (-not $script:St.reboot_needed)
$script:AlreadyAsked = $false

Write-Output 'CASE 0x8024402C, and the proxy was NOT usable either'
$e = Run 'Ausnahme von HRESULT: 0x8024402C' 'unreachable Der Remoteserver antwortet nicht'
Check 'calls it a transport failure, not the WU state'      ($e -match 'transport\s+failure')
Check 'does NOT blame Windows Update'                        (-not ($e -match 'did not use the configured proxy'))
Check 'carries the transport detail it measured'             ($e -match 'antwortet nicht')

Write-Output 'CASE 0x8024402C, and the probe itself could not run'
$e = Run 'Ausnahme von HRESULT: 0x8024402C' ''
Check 'says the cause is UNMEASURED rather than picking one' ($e -match 'UNMEASURED')

Write-Output 'CASE a DIFFERENT error - the reason machinery must not touch it'
$e = Run 'Ausnahme von HRESULT: 0x80072EFE' 'reachable status=200'
Check 'the original error is left exactly as it was' ($e -eq 'Ausnahme von HRESULT: 0x80072EFE')

Write-Output ''
if ($fails -eq 0) { Write-Output "PASS  $checks checks"; exit 0 }
Write-Output "FAIL  $fails of $checks checks"; exit 1
