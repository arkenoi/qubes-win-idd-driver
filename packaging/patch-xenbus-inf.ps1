<#
.SYNOPSIS
Stop xenbus.inf from installing the xenbus_monitor service in a state where it can reboot the
guest, then regenerate and re-sign the driver catalog.

.DESCRIPTION
MEASURED ROOT CAUSE, 2026-08-28. Installing our own package onto a guest that has a pending PV
reboot request bricks it. Windows event 1074, captured live from the guest mid-install:

    The process C:\Windows\System32\xenbus_monitor_9_1_0_0.exe has initiated the RESTART of
    computer WIN-IDD-TEST on behalf of user NT AUTHORITY\SYSTEM for the following reason:
    Operating System: Recovery (Planned)   Reason Code: 0x80020002

The restart lands ~28-30 s into msiexec, in the middle of the PV driver install; the interrupted
install leaves a guest that either boots to "Automatic Repair couldn't repair your PC" or runs
headless with no qrexec. Reproduced four times; the same install without a pending request
completes in 90 s and stays healthy.

WHY THE SUPPRESSOR CANNOT FIX IT. Start-XenbusPromptSuppressor sweeps once a second - disable the
service, stop it, kill xenbus_monitor*, delete the Request key. But this INF is what creates the
service, and it creates it with SPSVCSINST_STARTSERVICE, so Windows STARTS it as part of the
driver install; the monitor reboots the machine the instant it starts with a request pending. A
1 Hz sweep against "starts and immediately reboots" is a race by construction - it had been
running 28 s when the reboot landed, and still lost.

WHAT THIS CHANGES, and why it is ours to change. The INF is a text file WE ship inside an MSI WE
build, and the catalog covering it is signed with our own throwaway "Qubes Windows Tools" cert on
a testsigning guest - there is nothing upstream or immutable about it. Two edits:

    AddService=xenbus_monitor,%SPSVCSINST_STARTSERVICE%,...  ->  AddService=xenbus_monitor,,...
    [Monitor_Service] StartType=%SERVICE_AUTO_START%         ->  StartType=%SERVICE_DISABLED%

The service is still installed (the driver package keeps its shape, and an admin can start it by
hand) but nothing starts it: not the driver install, not the next boot. Our installer performs its
own reboots at the moments it chooses, and has never needed the monitor - that is already stated
in Disable-XenbusMonitor.

This removes the whole bug class rather than one symptom: the mid-install restart, the modal
"needs to restart the system" prompt an unattended install cannot answer (forum 42717 post 104),
and the per-boot re-file that drives AppVM reboot loops.

.PARAMETER InfPath
xenbus.inf in the staged QUBES_REPO (…\vmm-xen-windows-pvdrivers\bin\xenbus.inf).

.PARAMETER PfxPath / PfxPassword
Signing cert for the regenerated catalog. Omit to patch the INF only (the catalog is then stale
and the caller must handle it) - used by the offline unit test.

.PARAMETER Inf2CatPath
Optional explicit path to Inf2Cat.exe; otherwise located under the Windows Kits bin directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfPath,
    [string]$PfxPath,
    [string]$PfxPassword,
    [string]$Inf2CatPath,
    [string]$CatOs = '10_X64'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InfPath)) { throw "xenbus.inf not found at $InfPath" }
$text = Get-Content -LiteralPath $InfPath -Raw

# --- edit 1: the driver install must not START the service --------------------------------
# Matches the AddService line for xenbus_monitor and drops ONLY its flags field. Anchored to the
# service name so the xenbus/xenfilt AddService lines (which need their own flags) are untouched.
$reStart = '(?im)^(\s*AddService\s*=\s*xenbus_monitor\s*,)\s*%SPSVCSINST_STARTSERVICE%\s*,'
$afterStart = [regex]::Replace($text, $reStart, '$1,')
if ($afterStart -eq $text) {
    throw "patch 1 did not apply: no 'AddService=xenbus_monitor,%SPSVCSINST_STARTSERVICE%,' line in $InfPath. " +
          "The INF changed shape - re-read it before assuming this patch is still correct."
}

# --- edit 2: and it must not auto-start on any later boot either ---------------------------
# Section-scoped: StartType appears in several service sections and only Monitor_Service may change.
$reMonitor = '(?ims)(^\[Monitor_Service\]\s*$.*?)(^\s*StartType\s*=\s*)%SERVICE_AUTO_START%'
$afterType = [regex]::Replace($afterStart, $reMonitor, '${1}${2}%SERVICE_DISABLED%')
if ($afterType -eq $afterStart) {
    throw "patch 2 did not apply: no 'StartType=%SERVICE_AUTO_START%' inside [Monitor_Service] in $InfPath."
}

Set-Content -LiteralPath $InfPath -Value $afterType -NoNewline -Encoding Ascii
Write-Host "patched $InfPath: xenbus_monitor is installed but never started (no STARTSERVICE, StartType=disabled)"

# --- prove it, on the file as written ------------------------------------------------------
$check = Get-Content -LiteralPath $InfPath -Raw
if ($check -match '(?im)^\s*AddService\s*=\s*xenbus_monitor\s*,\s*%SPSVCSINST_STARTSERVICE%') {
    throw 'verification failed: the STARTSERVICE flag is still present after patching'
}
if ($check -notmatch '(?ims)^\[Monitor_Service\]\s*$.*?^\s*StartType\s*=\s*%SERVICE_DISABLED%') {
    throw 'verification failed: Monitor_Service StartType is not SERVICE_DISABLED after patching'
}

# --- regenerate + re-sign the catalog ------------------------------------------------------
# Editing the INF invalidates xenbus.cat, and an unsigned/stale catalog fails the driver install
# even with testsigning on. Regenerate from the patched directory and sign with the same cert
# every other binary in this package is signed with.
if (-not $PfxPath) {
    Write-Warning 'no -PfxPath: INF patched but the catalog was NOT regenerated (offline/test mode)'
    return
}

$dir = Split-Path -Parent $InfPath
if (-not $Inf2CatPath) {
    $Inf2CatPath = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter Inf2Cat.exe -ErrorAction SilentlyContinue |
                    Where-Object FullName -match 'x86|x64' | Select-Object -First 1).FullName
}
if (-not $Inf2CatPath) { throw 'Inf2Cat.exe not found - cannot regenerate the driver catalog' }

& $Inf2CatPath /driver:$dir /os:$CatOs /verbose
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed with $LASTEXITCODE for $dir" }

$cat = Join-Path $dir 'xenbus.cat'
if (-not (Test-Path -LiteralPath $cat)) { throw "Inf2Cat reported success but $cat is missing" }

$signtool = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
             Where-Object FullName -match 'x64' | Select-Object -First 1).FullName
if (-not $signtool) { throw 'signtool.exe not found - cannot sign the regenerated catalog' }

& $signtool sign /fd sha256 /f $PfxPath /p $PfxPassword $cat
if ($LASTEXITCODE -ne 0) { throw "signtool failed on $cat" }
Write-Host "regenerated and signed $cat"
