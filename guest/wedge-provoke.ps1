<#
.SYNOPSIS
    Try to PROVOKE the wedge on demand, and leave a black box saying exactly when and during
    what the guest died.

.DESCRIPTION
    THE PROBLEM THIS SOLVES. The wedge has been observed twice by this project and "often
    enough to be annoying" by the owner, but never on demand - so every conclusion about it has
    rested on two uncontrolled samples. Worse, when it hits we lose qrexec, window capture and
    the Windows event log at the same instant, so the guest dies with nothing recorded: the dm
    log for the 2026-08-29 win10-clean occurrence is a 97-minute hole containing not one device
    model event, not even a SHUTDOWN on ACPI request.

    Without a reproducer there is no A/B. "4.3.13 looked fine" is absence of observation, not
    evidence - a guest that idles quietly proves nothing about a fault that needs provoking.
    The point of this script is to make the fault happen ON PURPOSE, so that .13 surviving N
    provocations that reliably kill .15 becomes a real result.

    THE MECHANISM IT AIMS AT, from two NMI dumps: concurrent memory-manager operations issue a
    single-target TLB shootdown IPI that a Xen HVM vCPU never ACKs, and the sender spins
    forever holding locks. Two ingredients are therefore required, and this script supplies
    both at once:

      1. MM PRESSURE on every vCPU. Threads pinned one per processor doing
         VirtualAlloc/commit/touch/VirtualFree. Freeing memory that is live in another
         processor's TLB is what forces the single-target shootdown IPI - the exact operation
         the dumps caught spinning. Merely allocating does not; the free is the trigger.

      2. PV DRIVER CHURN concurrently. Both observed occurrences sit on PV driver binding -
         one was a netvm attach (xenvif/xennet binding), one was mid-install while drivers
         were being installed. A driver start/stop maps and unmaps MDLs and sets up and tears
         down grant mappings at raised IRQL, which is MM work in kernel mode racing the MM
         work in ingredient 1.

    Neither alone reproduced anything in the field; the hypothesis is that the race needs both.

.SAFETY
    -Device accepts ONLY xenvif or xencons, and the script hard-refuses anything else.
    Cycling XENBUS would take every child device with it and cycling XENVBD would pull the
    boot disk out from under a running Windows - both would hang the guest BY CONSTRUCTION and
    hand back a guaranteed false positive that looks exactly like the fault under study. A
    provocation that fakes the result it is hunting is worse than no provocation.

    Run this on a CLONE. It is designed to hang the guest, and a guest hung at high IRQL may
    have to be killed, which risks the disk image.

.OUTPUT
    A heartbeat file written with WriteThrough (every record forced to disk, no buffering - a
    wedged guest never flushes, so a buffered log loses precisely the last seconds that
    matter). Each record carries iteration, phase and timestamp, so after a kill+reboot the
    last line bounds the time of death to about a second and names the phase that did it.

    Note the heartbeat is the channel *this* qube can read after the fact. The PV console
    (xencons, shipped since 4.3.16) is the live channel, but it is read from dom0 with
    `xl console` and this qube cannot run that - so watch the console yourself if you want to
    see the guest die in real time.

.EXAMPLE
    powershell -ep bypass -f wedge-provoke.ps1 -Minutes 20 -Device xenvif
#>
[CmdletBinding()]
param(
    # How long to keep provoking before declaring the guest survived.
    [int]$Minutes = 15,

    # Which PV devnode to cycle. Deliberately a tiny allowlist - see .SAFETY.
    [ValidateSet('xenvif', 'xencons')]
    [string]$Device = 'xenvif',

    # MM pressure threads. Default 0 = one per logical processor, which is what makes a
    # SINGLE-TARGET shootdown likely: every vCPU holds live mappings, so a free on one has
    # to be flushed on a specific other.
    [int]$Threads = 0,

    # Per-thread working set. Big enough to span many pages (so a free flushes a real TLB
    # range), small enough that four threads cannot push a 4 GB guest into swapping - paging
    # would add its own stalls and muddy the signal.
    [int]$BufferMB = 64,

    # Seconds between devnode cycles. The disable/enable itself takes seconds; this is the
    # gap on top.
    [int]$CycleGap = 3,

    [string]$HeartbeatPath = 'C:\wedge-provoke-heartbeat.log',

    # Skip the PnP half and run MM pressure only. This is the CONTROL: if the guest wedges
    # with -NoPnp too, the PV driver is exonerated and the fault is plain MM pressure, which
    # is a different (and much more serious) finding.
    [switch]$NoPnp
)

$ErrorActionPreference = 'Stop'

if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }

# --- the black box -------------------------------------------------------------------
# WriteThrough is the whole point: a wedged guest stops running, so anything sitting in a
# buffer is lost, and the lost part is exactly the moment of death.
$hbStream = [System.IO.FileStream]::new(
    $HeartbeatPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::WriteThrough)
$hbWriter = [System.IO.StreamWriter]::new($hbStream)
$hbWriter.AutoFlush = $true

function Beat([string]$phase, [string]$detail = '') {
    $line = ('{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $phase, $detail).TrimEnd()
    $hbWriter.WriteLine($line)
    $hbWriter.Flush()
    $hbStream.Flush($true)   # $true = flush the OS file buffers to the device, not just ours
    Write-Host $line
}

Beat 'START' ("threads=$Threads bufferMB=$BufferMB device=$Device nopnp=$NoPnp " +
              "cpus=$([Environment]::ProcessorCount) minutes=$Minutes")

# Record what we are running against, so a heartbeat file found later is self-describing and
# cannot be misattributed to the wrong build - the "wrong package" failure this project has
# already paid for once.
try {
    $mf = 'C:\qwt-improved-setup\MANIFEST.json'
    if (Test-Path $mf) {
        $m = Get-Content $mf -Raw | ConvertFrom-Json
        Beat 'BUILD' ("repo_commit=" + $m.source.driver_repo_commit + " version=" + $m.version)
    } else {
        Beat 'BUILD' 'no MANIFEST.json - build identity UNKNOWN, treat results with suspicion'
    }
} catch { Beat 'BUILD' "manifest unreadable: $_" }

# --- ingredient 1: MM pressure, one thread per vCPU ------------------------------------
# Runspaces, not Start-Job: jobs are separate PROCESSES with their own address spaces and
# their own idle time, which is the opposite of what we want. Threads in ONE process share a
# page table, so a free on one vCPU must invalidate mappings live on the others - and that
# cross-processor invalidation is the single-target shootdown we are hunting.
$pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
$pool.Open()
$workers = @()

$mmScript = {
    param($bufferMB, $affinityMask)
    # Pin to one logical processor so each thread's mappings live in a DISTINCT TLB.
    # Unpinned threads get migrated by the scheduler and may all end up on one vCPU, where a
    # free needs no remote invalidation at all and the provocation quietly does nothing.
    try {
        $t = [System.Diagnostics.Process]::GetCurrentProcess().Threads |
             Where-Object { $_.Id -eq [System.AppDomain]::GetCurrentThreadId() } | Select-Object -First 1
        if ($t) { $t.ProcessorAffinity = [IntPtr]$affinityMask }
    } catch { }   # affinity is an optimisation of the provocation, never a reason to abort it

    $bytes = $bufferMB * 1MB
    $n = 0
    while ($true) {
        # Allocate, TOUCH every page (an untouched commit is never backed, so freeing it
        # invalidates nothing and the whole loop becomes a no-op), then free.
        $a = New-Object byte[] $bytes
        for ($i = 0; $i -lt $bytes; $i += 4096) { $a[$i] = 1 }
        $a = $null
        # Forced gen-2 collection with compaction: this is what actually returns pages to the
        # OS and issues the unmap. Without it .NET keeps the memory on its own heap and no
        # shootdown is ever generated.
        [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = 'CompactOnce'
        [GC]::Collect(2, 'Forced', $true, $true)
        $n++
    }
}

for ($i = 0; $i -lt $Threads; $i++) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($mmScript).AddArgument($BufferMB).AddArgument(1 -shl ($i % [Environment]::ProcessorCount))
    $workers += @{ ps = $ps; handle = $ps.BeginInvoke() }
}
Beat 'MM_RUNNING' "$Threads threads pinned, ${BufferMB}MB each"

# --- ingredient 2: PV driver churn ------------------------------------------------------
$deadline = (Get-Date).AddMinutes($Minutes)
$cycle = 0
$hwidPrefix = if ($Device -eq 'xenvif') { 'XENBUS\VEN_XP0001&DEV_VIF' } else { 'XENBUS\VEN_XP0001&DEV_CONS' }

try {
    while ((Get-Date) -lt $deadline) {
        $cycle++
        if ($NoPnp) {
            Beat 'MM_ONLY' "cycle=$cycle (control run - no PnP churn)"
            Start-Sleep -Seconds $CycleGap
            continue
        }

        $dev = @(Get-PnpDevice -ErrorAction SilentlyContinue |
                 Where-Object { $_.InstanceId -like "$hwidPrefix*" })
        if (-not $dev) {
            # Not fatal, and NOT silently skipped: a run that provoked nothing must not look
            # like a run that survived. This is the "missing data fails" rule - the absence of
            # the device is the finding here.
            Beat 'PNP_ABSENT' "no device matching $hwidPrefix - PnP half of the provocation is INERT"
            Start-Sleep -Seconds $CycleGap
            continue
        }

        foreach ($d in $dev) {
            Beat 'PNP_DISABLE' ("cycle=$cycle " + $d.InstanceId + " status=" + $d.Status)
            try { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop }
            catch { Beat 'PNP_DISABLE_ERR' "$_" }

            Beat 'PNP_ENABLE' ("cycle=$cycle " + $d.InstanceId)
            try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop }
            catch { Beat 'PNP_ENABLE_ERR' "$_" }
        }

        Beat 'CYCLE_OK' "cycle=$cycle"
        Start-Sleep -Seconds $CycleGap
    }

    Beat 'SURVIVED' "completed $cycle cycles over $Minutes minutes without wedging"
}
finally {
    # Best-effort teardown. If the guest is already wedging, none of this runs - which is
    # precisely why the heartbeat is written WriteThrough as we go rather than summarised here.
    foreach ($w in $workers) { try { $w.ps.Stop(); $w.ps.Dispose() } catch { } }
    try { $pool.Close(); $pool.Dispose() } catch { }
    try {
        if (-not $NoPnp) {
            $dev = @(Get-PnpDevice -ErrorAction SilentlyContinue |
                     Where-Object { $_.InstanceId -like "$hwidPrefix*" -and $_.Status -ne 'OK' })
            foreach ($d in $dev) {
                Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    } catch { }
    try { Beat 'END' 'teardown complete'; $hbWriter.Dispose(); $hbStream.Dispose() } catch { }
}
