# qubes.ResizeDisk: dom0 runs this right after it grows one of this qube's volumes, sending the volume's
# name (private or root) on stdin, and shows the user what it prints on stderr when it exits non-zero.
# The boot guard (ensure-autologon.ps1) runs it with -Disk at every boot, so a volume extended while the
# qube was halted grows at the next start - the two paths Linux has (qubes.ResizeDisk and setup-rw.sh).
#
# private is the Q: partition, accepted only on the disk the installer identifies as the private disk by
# serial (Classify-PrivateDiskState, packaging/setup/Install-QwtImproved.ps1); root is the system drive.
# Windows extends a partition only into unallocated space directly after it, so a partition lying between
# the volume and the new space (on C:, usually the recovery partition) is named and left alone.
param([string]$Disk = '')
$ErrorActionPreference = 'Stop'
$qwtLogPs1 = Join-Path $PSScriptRoot 'log.ps1'
try { . $qwtLogPs1 } catch { [Console]::Error.WriteLine("resize-disk.ps1: cannot load $qwtLogPs1 ($($_.Exception.Message)) - no log sink"); exit 1 }

# log.ps1's writers only log; this one also answers the caller, on stderr for an error so that dom0
# shows it in its "Online resize ... failed" message.
function Write-ResizeLine([string]$lvl, [string]$msg) {
    $null = Write-QwtLogLine $lvl $msg -Module 'resize-disk.ps1'
    if ($lvl -eq 'E') { [Console]::Error.WriteLine($msg) } else { [Console]::Out.WriteLine($msg) }
}

$online = -not $Disk
if ($online) { $Disk = ([string][Console]::In.ReadLine()).Trim() }
$slack = 1MB
try {
    switch ($Disk) {
        'private' { $letter = 'Q' }
        'root'    { $letter = $env:SystemDrive.Substring(0, 1) }
        default   { Write-ResizeLine 'E' "Automatic resize of '$Disk' not supported"; exit 1 }
    }
    Update-HostStorageCache
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $part) { Write-ResizeLine 'E' "${letter}: does not exist - nothing to grow for the $Disk volume"; exit 1 }
    $n = [int]$part.DiskNumber
    Update-Disk -Number $n
    $dk = Get-Disk -Number $n
    $sn = ([string]$dk.SerialNumber).Trim()
    if ($Disk -eq 'private' -and $sn -notin @('QM00002', '0001')) {
        Write-ResizeLine 'E' "Q: is on disk #$n (serial '$sn'), not on the private disk - not touching it"; exit 1
    }
    $part = Get-Partition -DiskNumber $n -PartitionNumber $part.PartitionNumber
    $mib = { param($b) '{0:N0} MiB' -f ($b / 1MB) }
    # Qubes only ever shrinks a volume when forced (qvm-volume resize --force), and it cuts the disk
    # before this handler runs: a partition that was not shrunk first now ends past the disk.
    if ([int64]$part.Offset + [int64]$part.Size -gt [int64]$dk.Size) {
        Write-ResizeLine 'E' ("${letter}: ends at $(& $mib ([int64]$part.Offset + [int64]$part.Size)), past the end of disk #$n " +
                              "($(& $mib $dk.Size)): the $Disk volume was shrunk below its partition, and data past the end is gone. " +
                              "Restore it in dom0 with qvm-volume revert while the previous revision exists; shrink ${letter}: inside " +
                              "the guest first, then resize the volume with --force")
        exit 1
    }
    $sup = Get-PartitionSupportedSize -DiskNumber $n -PartitionNumber $part.PartitionNumber
    if ($sup.SizeMax -le $part.Size + $slack) {
        $used = (@(Get-Partition -DiskNumber $n) | Measure-Object -Property Size -Sum).Sum
        $free = [int64]$dk.Size - [int64]$used
        $next = @(Get-Partition -DiskNumber $n | Where-Object { $_.Offset -gt $part.Offset } | Sort-Object Offset) | Select-Object -First 1
        if ($free -gt 64MB -and $next) {
            Write-ResizeLine 'E' ("${letter}: cannot grow: $(& $mib $free) of disk #$n is unallocated, but partition #$($next.PartitionNumber) " +
                                  "($($next.Type), $(& $mib $next.Size)) lies between ${letter}: and that space, and Windows extends a partition " +
                                  "only into space directly after it")
            exit 1
        }
        if ($online) {
            Write-ResizeLine 'E' "${letter}: already fills disk #$n as Windows sees it ($(& $mib $dk.Size)) - the new size is not visible yet; ${letter}: grows at the next boot"
            exit 1
        }
        Write-ResizeLine 'I' "ok     ${letter}: fills disk #$n ($(& $mib $part.Size))"
        exit 0
    }
    $before = $part.Size
    Resize-Partition -DiskNumber $n -PartitionNumber $part.PartitionNumber -Size $sup.SizeMax
    $after = (Get-Partition -DiskNumber $n -PartitionNumber $part.PartitionNumber).Size
    if ($after -lt $sup.SizeMax - $slack) {
        Write-ResizeLine 'E' "${letter}: is $(& $mib $after) after Resize-Partition to $(& $mib $sup.SizeMax)"; exit 1
    }
    Write-ResizeLine 'I' "SET    ${letter}: grew from $(& $mib $before) to $(& $mib $after) on disk #$n"
    exit 0
} catch {
    Write-ResizeLine 'E' "resize of the $Disk volume failed: $($_.Exception.Message.Split([char]10)[0])"
    exit 1
}
