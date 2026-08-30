# Count registered Qubes Windows Tools PRODUCTS - the same thing Install-QwtImproved.ps1 enumerates
# when it decides "upgrade" vs "fresh". Asserting a precondition on any other signal is how a cell
# certified a half-uninstalled guest as a fresh install.
$n = 0
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    foreach ($p in Get-ItemProperty $k -ErrorAction SilentlyContinue) {
        if ($p.DisplayName -like '*Qubes Windows Tools*') { $n++ }
    }
}
Write-Host "QWTPRODUCTS=$n"
