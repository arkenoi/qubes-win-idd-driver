<#
.SYNOPSIS
  Install + ACTIVATE the Qubes IddCx display driver on a guest that ALREADY has QWT installed,
  WITHOUT re-running the MSI (no version gate, no PV-disk 0x7B gate). This is the "add IDD to an
  existing install" path: GWeck's case - a 4.3.x guest that was installed before IDD was default,
  or any guest where IDD needs (re)activating.

  Mirrors the activation stage of Install-QwtImproved.ps1 (pnputil /add-driver -> devcon create
  root\iddsampledriver -> wait for bind -> disable the emulated VGA). Run ELEVATED. A reboot is
  required afterwards so the IDD comes up primary; the gui-agent (already installed) performs the
  display-topology apply at startup and publishes the mode list to HKLM\SOFTWARE\QubesIDD\Modes.

  NOTE: this duplicates the installer's IDD logic deliberately, to avoid refactoring the 1200-line
  installer blind. TODO(4.3.x): extract the shared activation into one module both call.
#>
[CmdletBinding()]
param([string]$Root = $PSScriptRoot, [switch]$NoReboot)

$ErrorActionPreference = 'Stop'
$log = 'C:\qwt-idd-activate.log'
function Log($m,$lvl='INFO'){ $line=('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'),$lvl,$m); Write-Host $line; try{Add-Content -LiteralPath $log -Value $line}catch{} }
$result = [ordered]@{ ok=$false; idd=$null; reboot_needed=$false; error=$null }

function Emit($code){
    $result.idd = "$($script:idd)"
    $json = ($result | ConvertTo-Json -Compress)
    Write-Host '=== RESULT ==='; Write-Host $json
    try { Add-Content -LiteralPath $log -Value "=== RESULT === $json" } catch {}
    exit $code
}
function Get-IddDev($hwid){ Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains $hwid -or $_.InstanceId -like "*$hwid*" } | Select-Object -First 1 }

try {
    Log '=== IDD-only activation ==='
    # elevation
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'not elevated - run install.cmd /iddonly from an Administrator prompt'
    }
    # QWT must already be installed: the gui-agent does the topology apply that makes the IDD primary
    $qwt = Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools','HKLM:\SOFTWARE\WOW6432Node\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
    if (-not $qwt) { Log 'no "Qubes Tools" registry key found - IDD will install but nothing will drive it primary until QWT is installed. Continuing anyway.' 'WARN' }
    # the IDD package is TEST-SIGNED - without testsigning the driver will not load
    $so = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
    if ($so -notmatch 'testsigning\s+Yes') {
        throw 'testsigning is NOT active in this boot - the test-signed IDD driver cannot load. Run the full installer once (it enables testsigning) before /iddonly.'
    }

    # deactivate-idd.ps1 (/iddoff) sets NoTopologyApply=1 to stop the agent detaching displays.
    # Re-activating must clear it, or the IDD would be created and then never attached - the
    # exact "connected but inactive, black screen" state /iddoff exists to escape.
    $qkey = 'HKLM:\SOFTWARE\QubesIDD'
    if ((Get-ItemProperty -LiteralPath $qkey -Name 'NoTopologyApply' -ErrorAction SilentlyContinue).NoTopologyApply) {
        Remove-ItemProperty -LiteralPath $qkey -Name 'NoTopologyApply' -Force -ErrorAction SilentlyContinue
        Log 'cleared HKLM\SOFTWARE\QubesIDD!NoTopologyApply (set by a previous /iddoff)'
    }

    $iddDir  = Join-Path $Root 'idd-driver'
    $iddHwId = 'root\iddsampledriver'
    $devcon  = Join-Path $iddDir 'devcon.exe'
    $inf = @(Get-ChildItem -LiteralPath $iddDir -Filter *.inf -ErrorAction SilentlyContinue)
    if ($inf.Count -ne 1) { throw "$iddDir holds $($inf.Count) .inf files (expected exactly 1)" }
    if (-not (Test-Path -LiteralPath $devcon)) { throw "devcon.exe missing from $iddDir" }

    # ---- identical-bytes guard + self-heal (FINDINGS 2026-08-27, the withdrawn 4.3.8) --------
    # Staging a package whose DLL is BYTE-IDENTICAL to the one already running re-binds the
    # device to a new store generation while C:\Windows\System32\drivers\UMDF\ keeps its
    # hardlink into the OLD generation (the copy engine skips identical content). The device
    # then never starts cleanly: the QIDD control ioctl answers 0xC0000476 and registry modes
    # are never offered. So: if the payload's DLL matches the running copy and the control
    # interface answers, there is NOTHING to update - skip staging entirely. If it matches but
    # the interface does NOT answer, this guest is already in the broken state (took the
    # withdrawn 4.3.8): heal by re-binding to the package the UMDF copy actually belongs to.
    function Test-QiddIoctl([string]$InstanceId) {
        try {
            if (-not ('QiddProbe' -as [type])) {
                Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QiddProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inb, uint insz, IntPtr outb, uint outsz, out uint ret, IntPtr ov);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
            }
            $path = '\\?\' + ($InstanceId -replace '\\','#') + '#{c7817eb4-b2b6-4996-a48c-04ef247952ab}'
            $h = [QiddProbe]::CreateFileW($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
            if ($h -eq [IntPtr]::new(-1)) { return $false }
            $ret = [uint32]0
            $ok = [QiddProbe]::DeviceIoControl($h, 0x00222000, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$ret, [IntPtr]::Zero)
            [QiddProbe]::CloseHandle($h) | Out-Null
            return [bool]$ok
        } catch { return $false }
    }
    $skipStage = $false
    $payloadDll = Join-Path $iddDir 'IddSampleDriver.dll'
    $umdfCopy = Join-Path $env:SystemRoot 'System32\drivers\UMDF\IddSampleDriver.dll'
    $dev0 = Get-IddDev $iddHwId
    if ($dev0 -and $dev0.ConfigManagerErrorCode -eq 0 -and (Test-Path $payloadDll) -and (Test-Path $umdfCopy)) {
        $newHash = (Get-FileHash -LiteralPath $payloadDll -Algorithm SHA256).Hash
        $runHash = (Get-FileHash -LiteralPath $umdfCopy -Algorithm SHA256).Hash
        if ($newHash -eq $runHash) {
            if (Test-QiddIoctl $dev0.InstanceId) {
                Log 'IDD driver content identical to the running copy and the control interface answers - nothing to update, SKIPPING staging (an identical-bytes restage un-links the UMDF copy and breaks the device)'
                $skipStage = $true
            } else {
                Log 'IDD control interface does not answer while the driver content is current - the identical-bytes-restage breakage; healing by re-binding to the package the UMDF copy belongs to' 'WARN'
                $linked = (& fsutil.exe hardlink list $umdfCopy 2>$null) |
                          Where-Object { $_ -match 'DriverStore\\FileRepository' } | Select-Object -First 1
                if ($linked) {
                    $healInf = Join-Path (Split-Path (Join-Path $env:SystemDrive $linked)) 'IddSampleDriver.inf'
                    Log "  heal: devcon update $healInf"
                    try { & $devcon update $healInf $iddHwId 2>&1 | ForEach-Object { Log "  devcon heal: $_" } } catch { Log "  heal failed: $_" 'WARN' }
                    $result.reboot_needed = $true
                    Log '  heal takes effect at the next boot (the wounded adapter state persists for this session)'
                    $skipStage = $true
                } else {
                    Log '  could not resolve the UMDF copy hardlink target - proceeding with normal staging' 'WARN'
                }
            }
        }
    }

    if (-not $skipStage) {
    Log "staging driver package $($inf[0].Name)"
    try { $out = & pnputil.exe /add-driver $inf[0].FullName /install 2>&1 } catch { $out = "$_" }
    $out | ForEach-Object { Log "  pnputil: $_" }
    # 259 = ERROR_NO_MORE_ITEMS: package already in the store and up-to-date ("Added driver
    # packages: 0"). That is the NORMAL /iddonly re-activation case - success, not failure.
    if ($LASTEXITCODE -notin 0,3010,259) { throw "pnputil /add-driver failed ($LASTEXITCODE)" }
    if ($LASTEXITCODE -eq 3010) { $result.reboot_needed = $true }
    } # -not $skipStage

    $createdByThisRun = $false
    $dev = Get-IddDev $iddHwId
    if ($dev -and $dev.ConfigManagerErrorCode -eq 0) {
        Log "IDD device already present and healthy ($($dev.InstanceId)) - reusing"
    } else {
        if ($dev) { Log "IDD device broken (code $($dev.ConfigManagerErrorCode)) - recreating" 'WARN'; try { & $devcon remove $iddHwId 2>&1 | ForEach-Object { Log "  devcon remove: $_" } } catch {} }
        Log "creating IDD device: devcon install $($inf[0].Name) $iddHwId"
        try { $out = & $devcon install $inf[0].FullName $iddHwId 2>&1 } catch { $out = "$_" }
        $out | ForEach-Object { Log "  devcon: $_" }
        if ($LASTEXITCODE -notin 0,1) { throw "devcon install failed ($LASTEXITCODE)" }
        $createdByThisRun = $true
    }

    Log 'waiting up to 30s for the IDD devnode (ConfigManagerErrorCode 0)'
    $deadline = (Get-Date).AddSeconds(30)
    do { $dev = Get-IddDev $iddHwId; if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { break }; Start-Sleep 2 } while ((Get-Date) -lt $deadline)
    $ctrl = $null
    if ($dev -and $dev.ConfigManagerErrorCode -eq 0) {
        $deadline = (Get-Date).AddSeconds(30)
        do { $ctrl = Get-CimInstance Win32_VideoController -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $dev.InstanceId } | Select-Object -First 1; if ($ctrl) { break }; Start-Sleep 2 } while ((Get-Date) -lt $deadline)
    }
    if (-not ($dev -and $dev.ConfigManagerErrorCode -eq 0 -and $ctrl)) {
        if ($createdByThisRun) { Log 'activation failed - removing the device this run created' 'WARN'; try { & $devcon remove $iddHwId 2>&1 | Out-Null } catch {} }
        throw 'IDD device did not bind with a display adapter - NOT disabling the VGA'
    }
    Log "IDD display adapter present: $($ctrl.Name)"

    # disable the emulated VGA (PCI display class CC_0300, prefer VEN_1234&DEV_1111)
    $vga = @(Get-PnpDevice -Class Display -EA SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' -and ($_.HardwareID -match 'CC_0300') })
    if ($vga.Count -eq 0) { throw 'IDD is up but no PCI display adapter (CC_0300) found to disable' }
    $pref = @($vga | Where-Object { $_.HardwareID -match 'VEN_1234&DEV_1111' }); if ($pref.Count -gt 0) { $vga = $pref }
    $vgaDev = $vga[0]
    $vgaCim = Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $vgaDev.InstanceId } | Select-Object -First 1
    if ($vgaCim -and $vgaCim.ConfigManagerErrorCode -eq 22) {
        Log "VGA $($vgaDev.InstanceId) already disabled - nothing to do"
    } else {
        Log "disabling emulated VGA: $($vgaDev.InstanceId) - display may blank until reboot"
        Disable-PnpDevice -InstanceId $vgaDev.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $script:idd = "activated: device up ($($dev.InstanceId)), VGA disabled ($($vgaDev.InstanceId))"
    $result.ok = $true; $result.reboot_needed = $true
    Log 'IDD ACTIVATED - reboot required so it comes up primary'
    if (-not $NoReboot) { Log 'rebooting in 5 s'; & shutdown.exe /r /t 5 /c 'Qubes IDD activation' | Out-Null }
    Emit 0
} catch {
    $result.error = "$($_.Exception.Message)"
    Log "IDD ACTIVATION FAILED: $($result.error)" 'ERROR'
    Emit 1
}
