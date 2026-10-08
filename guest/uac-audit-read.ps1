# uac-audit-read.ps1 - READ EVERY PROCESS CREATED THIS BOOT, AND SAY WHETHER THE READ ITSELF WORKED.
#
# Companion to uac-startup-sample.ps1. The sampler cannot speak for the first minute of a boot (an
# ONSTART task starts when the Task Scheduler does, measured 65 s after boot on this guest), and that
# is exactly the window a startup elevation would live in. Windows' own process-creation auditing
# (Security event 4688) covers the whole boot, so this asks Windows instead of guessing.
#
# WHAT MAKES A ZERO MEANINGFUL. A zero from a log that holds no 4688 events at all is not a
# measurement, it is a silent instrument - and that is the shape of every false negative this
# project has paid for. So TOTAL_4688 is printed FIRST and AUDIT_USABLE says plainly whether a zero
# may be read as evidence. Everything is scoped to THIS boot by LastBootUpTime, so a previous boot's
# events can never be counted as this run's.
[CmdletBinding()]
param([switch] $Verbose_)

$ErrorActionPreference = 'Continue'

$boot = $null
try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
if (-not $boot) { Write-Output 'AUDIT_USABLE=no reason=cannot-read-LastBootUpTime'; exit 2 }
Write-Output ("BOOT_TIME={0:o}" -f $boot)
Write-Output ("READ_TIME={0:o}" -f (Get-Date))

$pol = 'unknown'
try {
    $raw = & auditpol /get /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' 2>&1 | Out-String
    if ($raw -match '(?m)^\s+\S.*?\s\s(.+?)\s*$') { $pol = $Matches[1].Trim() }
} catch { }
Write-Output "AUDIT_POLICY=$pol"

$ev = @()
$readError = $null
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688; StartTime = $boot } -ErrorAction Stop)
} catch {
    $readError = $_.Exception.Message
    # "No events were found" is a legitimate empty result, not a read failure - tell them apart.
    if ($readError -match 'No events were found') { $readError = $null }
}
if ($readError) { Write-Output "AUDIT_USABLE=no reason=read-failed detail=$readError"; exit 2 }

Write-Output ("TOTAL_4688={0}" -f $ev.Count)
if ($ev.Count -eq 0) {
    # A LOG WITH NO PROCESS CREATIONS AT ALL CANNOT SHOW THE ABSENCE OF ONE. Every boot creates
    # dozens of processes, so zero means auditing was not in force for this boot - most likely the
    # policy was enabled after it started.
    Write-Output 'AUDIT_USABLE=no reason=zero-events-of-any-kind-so-absence-proves-nothing'
    Write-Output 'CONSENT_4688=unmeasured'
    Write-Output 'MSIEXEC_4688=unmeasured'
    exit 1
}
Write-Output 'AUDIT_USABLE=yes'

function Get-NewProcessName($e) {
    try {
        $x = [xml]$e.ToXml()
        $d = $x.Event.EventData.Data | Where-Object { $_.Name -eq 'NewProcessName' }
        if ($d) { return [string]$d.'#text' }
    } catch { }
    return ''
}

$consent = @(); $msi = @()
foreach ($e in $ev) {
    $n = Get-NewProcessName $e
    if ($n -match '(?i)\\consent\.exe$')  { $consent += [pscustomobject]@{ t = $e.TimeCreated; n = $n } }
    if ($n -match '(?i)\\msiexec\.exe$')  { $msi     += [pscustomobject]@{ t = $e.TimeCreated; n = $n } }
}

Write-Output ("CONSENT_4688={0}" -f $consent.Count)
foreach ($c in $consent) { Write-Output ("CONSENT_AT={0:o} since_boot_s={1} path={2}" -f $c.t, [math]::Round(($c.t - $boot).TotalSeconds, 1), $c.n) }
Write-Output ("MSIEXEC_4688={0}" -f $msi.Count)
foreach ($m in $msi) { Write-Output ("MSIEXEC_AT={0:o} since_boot_s={1} path={2}" -f $m.t, [math]::Round(($m.t - $boot).TotalSeconds, 1), $m.n) }

# EARLIEST AUDITED PROCESS: this is the real coverage statement. If the first audited creation is
# itself 60 s into the boot, the audit has the same blind spot as the sampler and must say so rather
# than letting a zero stand for the whole boot.
$first = ($ev | Sort-Object TimeCreated | Select-Object -First 1)
if ($first) {
    Write-Output ("AUDIT_FIRST_EVENT_SINCE_BOOT_S={0}" -f [math]::Round(($first.TimeCreated - $boot).TotalSeconds, 1))
    Write-Output ("AUDIT_FIRST_PROCESS={0}" -f (Get-NewProcessName $first))
}
exit 0
