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

# Disable UAC filtering on this DISPOSABLE, OFFLINE driver-dev VM so that qrexec/VMShell
# (which lands as 'user' in the interactive session) gets a full admin token and can run
# pnputil/devcon/sc and stop the gui-agent service non-interactively. Without this, every
# driver install and agent-binary swap fails "Access is denied" with no consent UI reachable
# from dom0, and there is no in-guest self-elevation path from the medium-integrity qrexec
# session. This mirrors QWT's own "Disable UAC" installer option. Applies on next reboot
# (firstboot reboots anyway). SECURITY: only appropriate for a throwaway, network-isolated
# test VM used for driver development — never for a real or networked Windows qube.
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty $sys EnableLUA 0 -Type DWord
Set-ItemProperty $sys ConsentPromptBehaviorAdmin 0 -Type DWord
Set-ItemProperty $sys LocalAccountTokenFilterPolicy 1 -Type DWord

# no sleep/monitor-off mid-test; /h off also kills Fast Startup so qvm-shutdown+start
# is a real cold boot (and the --cdrom drive stays visible per qubes-doc)
powercfg /h off
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# Pre-seed GUI agent settings BEFORE the MSI runs: its AppSearch skips seeding a value
# that already exists, so ours win. Default install would be SeamlessMode=0 (fullscreen)
# and DisableCursor=1.
New-Item -Path 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Force | Out-Null
Set-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' SeamlessMode 1 -Type DWord
Set-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' DisableCursor 0 -Type DWord

# where did QWT put things? (recorded for Phase 0)
Write-Output "--- QWT services ---"
Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } | Format-Table Name, Status, DisplayName
Write-Output "--- Incoming dir candidates ---"
Get-ChildItem "$env:USERPROFILE" -Recurse -Directory -Filter 'QubesIncoming' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

Write-Output "OK - REBOOT REQUIRED for testsigning to take effect."
