# Why did an offline .msu install fail? Pull the decisive lines out of DISM's own log and CBS,
# per package, instead of guessing from an exit code.
$ErrorActionPreference = 'Continue'
$dism = 'C:\ProgramData\Qubes\wu\dism.log'

function Section($t) { Write-Output ''; Write-Output "=== $t ===" }

Section 'DISM: per-package outcome lines'
if (Test-Path $dism) {
    Get-Content $dism |
        Where-Object { $_ -match 'Add-Package|PackagePath|Failed processing|The operation completed|hrResult|Error DISM' } |
        Select-Object -Last 25 | ForEach-Object { Write-Output ("  " + $_.Trim()) }
} else { Write-Output "  (no $dism)" }

Section 'DISM: first error after each package start'
if (Test-Path $dism) {
    $lines = Get-Content $dism
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'kb504308|kb512100|ndp481') {
            Write-Output ("  @" + $i + ": " + $lines[$i].Trim())
        }
    }
}

Section 'CBS: why the boot-time servicing rolled back'
$cbs = 'C:\Windows\Logs\CBS\CBS.log'
if (Test-Path $cbs) {
    Get-Content $cbs -Tail 4000 |
        Where-Object { $_ -match '0x80070490|Failed to|rollback|Startup Processing|checkpoint|missing' } |
        Select-Object -Last 20 | ForEach-Object { Write-Output ("  " + $_.Trim()) }
} else { Write-Output '  (no CBS.log)' }

Section 'pending servicing state right now'
Write-Output ("  CBS RebootPending : " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
Write-Output ("  WU RebootRequired : " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
$sess = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
Write-Output ("  SessionsPending   : " + (Test-Path $sess))
Write-Output '=== RESULT === done'
