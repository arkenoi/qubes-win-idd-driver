# Run ELEVATED inside win-idd-test, once, after Windows + QWT install.
# Enables test signing, trusts the throwaway build cert, disables test-hostile power saving.
$ErrorActionPreference = 'Continue'

bcdedit /set testsigning on

# Trust the build cert if it was pushed alongside/before this script (any QubesIncoming subdir)
$cer = Get-ChildItem "$env:USERPROFILE" -Recurse -Filter 'qubesidd-test.cer' -ErrorAction SilentlyContinue |
       Select-Object -First 1
if ($cer) {
    certutil -addstore -f Root $cer.FullName
    certutil -addstore -f TrustedPublisher $cer.FullName
    Write-Output "Trusted cert: $($cer.FullName)"
} else {
    Write-Output "NOTE: qubesidd-test.cer not found yet - re-run after pushing it."
}

Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' LongPathsEnabled 1

# no sleep/monitor-off mid-test
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# where did QWT put things? (recorded for Phase 0)
Write-Output "--- QWT services ---"
Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } | Format-Table Name, Status, DisplayName
Write-Output "--- Incoming dir candidates ---"
Get-ChildItem "$env:USERPROFILE" -Recurse -Directory -Filter 'QubesIncoming' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

Write-Output "OK - REBOOT REQUIRED for testsigning to take effect."
