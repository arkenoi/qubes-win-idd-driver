<#
.SYNOPSIS
  Put a guest BACK on the emulated Basic Display Adapter: re-enable the PCI VGA adapter,
  disarm the agent's IDD topology apply, and remove the root\iddsampledriver device.
  The reverse of activate-idd.ps1, and the recovery path for a guest whose display is
  unusable after IDD activation. Run ELEVATED; reboots when done.

.DESCRIPTION
  WHY THIS EXISTS. Activation disables the emulated VGA adapter and hands the desktop to the
  IddCx monitor, and the topology apply that attaches that monitor lives in the gui-agent. If
  the apply does not succeed - on Win10 the OS does not perform it by itself - the guest can
  end up with NO attached display at all, which from dom0 looks like a black, unresponsive
  window. Field-reported on Windows 10 22H2 (forum 42717 post 54).

  A stranded user cannot fix that from inside the guest, because there is nothing to see. This
  script is therefore designed to run over qrexec from dom0 with no interactive desktop:

      qvm-run -u SYSTEM <vm> "powershell -ExecutionPolicy Bypass -File <path>\deactivate-idd.ps1"

  so it must NOT depend on anything that needs a visible desktop. It does not call
  ChangeDisplaySettingsEx (that fails in session 0); it changes the DEVICE state and lets the
  next boot rebuild the topology around the only adapter left.

  Order matters:
    1. NoTopologyApply=1 first, so the agent cannot re-detach the VGA before we get there,
    2. then re-enable the VGA,
    3. then remove the IDD device, so nothing is left that could bind as a second display.
#>
[CmdletBinding()]
param([string]$Root = $PSScriptRoot, [switch]$NoReboot)

$ErrorActionPreference = 'Stop'
$log = 'C:\qwt-idd-deactivate.log'
function Log($m,$lvl='INFO'){ $line=('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'),$lvl,$m); Write-Host $line; try{Add-Content -LiteralPath $log -Value $line}catch{} }
$result = [ordered]@{ ok=$false; no_topology_apply=$false; vga=$null; idd=$null; reboot_needed=$false; error=$null }

function Emit($code){
    $json = ($result | ConvertTo-Json -Compress)
    Write-Host '=== RESULT ==='; Write-Host $json
    try { Add-Content -LiteralPath $log -Value "=== RESULT === $json" } catch {}
    exit $code
}

try {
    Log '=== IDD deactivation (back to the Basic Display Adapter) ==='
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'not elevated - run install.cmd /iddoff from an Administrator prompt, or over qrexec as SYSTEM'
    }

    # 1. Disarm the agent's topology apply BEFORE touching devices. Without this the agent can
    #    detach the VGA again at its next start and we would be back where we came from.
    $key = 'HKLM:\SOFTWARE\QubesIDD'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -LiteralPath $key -Name 'NoTopologyApply' -PropertyType DWord -Value 1 -Force | Out-Null
    $result.no_topology_apply = $true
    Log 'HKLM\SOFTWARE\QubesIDD!NoTopologyApply=1 - the gui-agent will leave the display topology alone'

    # 2. Re-enable the emulated VGA. Match the same way activation picked it: PCI display class
    #    CC_0300, preferring the Qubes/QEMU stdvga identity, but not hardcoding it.
    $vga = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like 'PCI\*' -and ($_.HardwareID -match 'CC_0300') })
    if ($vga.Count -eq 0) {
        # Not fatal: a guest can legitimately have no emulated VGA (PCI passthrough, or a
        # topology we do not know). Say so loudly instead of throwing away the rest of the run.
        Log 'no PCI display adapter (CC_0300) found to re-enable - continuing with the IDD removal' 'WARN'
        $result.vga = 'no PCI display adapter found'
    } else {
        $pref = @($vga | Where-Object { $_.HardwareID -match 'VEN_1234&DEV_1111' })
        if ($pref.Count -gt 0) { $vga = $pref }
        $vgaDev = $vga[0]
        if ($vgaDev.Status -eq 'OK' -and $vgaDev.ConfigManagerErrorCode -eq 'CM_PROB_NONE') {
            Log "VGA $($vgaDev.InstanceId) is already enabled - nothing to do"
            $result.vga = "already enabled ($($vgaDev.InstanceId))"
        } else {
            Log "enabling VGA adapter $($vgaDev.InstanceId) ($($vgaDev.FriendlyName))"
            Enable-PnpDevice -InstanceId $vgaDev.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
            $result.vga = "enabled ($($vgaDev.InstanceId))"
            $result.reboot_needed = $true
        }
    }

    # 3. Remove the IDD device. devcon is the tool activation used; fall back to disabling the
    #    devnode when it is not on this medium, because a DISABLED IDD is also not a display
    #    target and that is the property we need. Never let this step be the reason the VGA
    #    stays off: by here the VGA is already back.
    $iddHwId = 'root\iddsampledriver'
    $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.HardwareID -contains $iddHwId -or $_.InstanceId -like "*$iddHwId*" } | Select-Object -First 1
    if (-not $dev) {
        Log 'no IDD device present - nothing to remove'
        $result.idd = 'absent'
    } else {
        $devcon = Join-Path $Root 'idd-driver\devcon.exe'
        if (-not (Test-Path -LiteralPath $devcon)) { $devcon = Join-Path $Root 'devcon.exe' }
        if (Test-Path -LiteralPath $devcon) {
            Log "removing IDD device $($dev.InstanceId) with devcon"
            try { $out = & $devcon remove $iddHwId 2>&1 } catch { $out = "$_" }
            $out | ForEach-Object { Log "  devcon: $_" }
            # devcon: 0 = removed, 1 = removed but a reboot is required. Anything else -> fall
            # through to the disable path rather than declaring the guest recovered.
            if ($LASTEXITCODE -in 0,1) {
                $result.idd = "removed ($($dev.InstanceId))"
            } else {
                Log "devcon remove returned $LASTEXITCODE - disabling the devnode instead" 'WARN'
                Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
                $result.idd = "disabled ($($dev.InstanceId))"
            }
        } else {
            Log "devcon.exe not on this medium - disabling the IDD devnode instead of removing it"
            Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
            $result.idd = "disabled ($($dev.InstanceId))"
        }
        $result.reboot_needed = $true
    }

    $result.ok = $true
    Log 'IDD DEACTIVATED - reboot so Windows rebuilds the display topology around the VGA adapter'
    Log 'to go back to the IDD later: install.cmd /iddonly (it clears NoTopologyApply)'
    if (-not $NoReboot) { Log 'rebooting in 5 s'; & shutdown.exe /r /t 5 /c 'Qubes IDD deactivation' | Out-Null }
    Emit 0
} catch {
    $result.error = "$($_.Exception.Message)"
    Log "IDD DEACTIVATION FAILED: $($result.error)" 'ERROR'
    Emit 1
}
