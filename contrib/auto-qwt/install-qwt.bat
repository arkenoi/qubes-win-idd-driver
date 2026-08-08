@echo off
title %~f0

:: Drop-in replacement for qvm-create-windows-qube's tools/auto-qwt/install-qwt.bat,
:: adapted for QWT-NG. Upstream original (QubesOS/qvm-create-windows-qube, MIT,
:: Copyright (C) 2023 Elliot Killick) is:
::
::     cd installer || exit
::     for %%i in (qubes-tools-*.exe qubes-tools-*.msi) do (
::         start %%i /passive
::     )
::
:: WHY IT MUST CHANGE. That glob looks for a single `qubes-tools-*.exe|msi` at the root of
:: the mounted QWT ISO. QWT-NG ships an installer TREE instead - install.cmd,
:: Install-QwtImproved.ps1, msi\installer.msi, certs\, pv-drivers\, idd-driver\ - because the
:: install is two-stage: our binaries are test-signed, so testsigning must be enabled and the
:: guest rebooted before the MSI can run. A single /passive msiexec cannot express that.
::
:: Left unpatched the glob simply matches NOTHING. There is no error and no dialog: the qube
:: finishes provisioning with no tools installed at all, which looks like "QWT silently failed"
:: rather than "the installer was never invoked". That silence is the reason this file exists.
::
:: /auto makes install.cmd reboot and resume itself, which is what an unattended flow needs.
:: Note it consumes MORE than one reboot; qvm-create-windows-qube's wait_for_shutdown_or_qwt
:: must tolerate that (see contrib/README-qvm-create-windows-qube.md).

cd installer || exit

if exist "install.cmd" (
    rem QWT-NG installer tree.
    start /wait cmd /c "install.cmd /auto"
) else (
    rem Fall back to upstream behaviour so this file still works with a stock QWT ISO.
    for %%i in (qubes-tools-*.exe qubes-tools-*.msi) do (
        start %%i /passive
    )
)
