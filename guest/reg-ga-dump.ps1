# Dump the gui-agent module config subkey.
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
Write-Output '=== RESULT ==='
if (Test-Path $k) {
    Get-ItemProperty $k | Select-Object -Property * -ExcludeProperty PS* | ConvertTo-Json
} else {
    Write-Output '{"missing":true}'
}
