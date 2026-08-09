# Standalone copy of the installer's Test-BootDiskOnPvPath, with raw evidence output.
# Exists to VALIDATE the gate added for the field-reported 0x7B upgrade crash: the
# installer's probe must be seen returning TRUE on a guest whose boot disk really is on
# xenvbd, and FALSE on one whose boot disk is emulated - otherwise the gate is an
# unproven check (see the honesty note in Install-QwtImproved.ps1).
# Output is KEY=VALUE, parsed by scratchpad/pv-validate.sh.
$ErrorActionPreference = 'Continue'
try {
    $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
    Write-Output ("BUSTYPE=" + [string]$disk.BusType)
    Write-Output ("DISKMODEL=" + [string]$disk.FriendlyName)
} catch {
    Write-Output ("BUSTYPE=PROBE-ERROR " + $_.Exception.Message)
}
try {
    $svc = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenvbd' -ErrorAction Stop
    Write-Output ("XENVBD_START=" + $svc.Start)
} catch {
    Write-Output "XENVBD_START=ABSENT"
}
# The verdict, computed the same way the installer computes it.
$pv = $false
try {
    $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
    if ($disk -and [string]$disk.BusType -eq 'SCSI') {
        $svc = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenvbd' -ErrorAction Stop
        $pv = ($svc.PSObject.Properties.Name -contains 'Start' -and $svc.Start -eq 0)
    }
} catch { $pv = $false }
Write-Output ("PVBOOT=" + $pv)
