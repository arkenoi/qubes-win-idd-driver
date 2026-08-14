# Second half of the same verification: WHAT are those 5 SessionsPending subkeys on a virgin image,
# and which of the standard pending-reboot indicators are actually set here?
# The corrected guard has to be built from what this prints, not from folklore about the key.
$ErrorActionPreference = 'Continue'
$sp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
Write-Output '=== RESULT ==='
foreach ($k in (Get-ChildItem $sp -EA SilentlyContinue)) {
    $p = Get-ItemProperty $k.PSPath -EA SilentlyContinue
    $names = @($k.GetValueNames() | Where-Object { $_ -ne '' })
    $pairs = foreach ($n in $names) { "{0}={1}" -f $n, $p.$n }
    Write-Output ("{0}  [{1}]" -f $k.PSChildName, ($pairs -join ' '))
}

Write-Output '--- other pending indicators ---'
$sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -EA SilentlyContinue
$pfro = @($sm.PendingFileRenameOperations)
Write-Output ("PendingFileRenameOperations entries = {0}" -f ($pfro | Where-Object { $_ }).Count)
Write-Output ("WU RebootRequired = {0}" -f (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
Write-Output ("CBS RebootInProgress = {0}" -f (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'))
Write-Output ("poqexec pending (winsxs\pending.xml) = {0}" -f (Test-Path 'C:\Windows\WinSxS\pending.xml'))
Write-Output ("SessionsPending\Exclusive = {0}" -f (Get-ItemProperty $sp -Name Exclusive -EA SilentlyContinue).Exclusive)

# CBS's own last words - the tail of its log says whether the last session finalized or aborted.
$cbslog = 'C:\Windows\Logs\CBS\CBS.log'
if (Test-Path $cbslog) {
    Write-Output '--- CBS.log tail (session outcome) ---'
    Get-Content $cbslog -Tail 200 -EA SilentlyContinue |
        Where-Object { $_ -match 'Reboot mark|Session:.*(initialized|finalized)|Failed|0x8' } |
        Select-Object -Last 8 | ForEach-Object { Write-Output ("   " + $_.Trim()) }
}
