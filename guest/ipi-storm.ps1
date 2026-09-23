<#
.SYNOPSIS
    Drive the guest's CROSS-PROCESSOR call path hard, to make a rare wedge reproducible on demand.

.DESCRIPTION
    The 2026-09-23 specimen was a processor spinning at a cross-processor-call barrier
    (ntoskrnl polling KPRCB+0x2d80, the field KeIpiGenericCall also touches) while the other
    processors never answered - one of them inside xen.sys. That class has been hunted for two
    weeks at an intermittent 10-20 % per clean install, which is far too rare to A/B a fix
    against. Jev, asked how to prove a fix cheapest: `stress-the-cross-processor-path` 0.63.

    Two generators, because the failures were seen in both contexts:
      TLB  - N threads, one per processor, each committing, touching and RELEASING memory in a
             tight loop. A VirtualFree(MEM_RELEASE) of pages another processor has in its TLB is
             what forces Windows to send TLB-shootdown IPIs, and it is the cheapest way to make
             the cross-processor path run thousands of times a second from user mode.
      PNP  - device disable/enable cycles, which is what OUR INSTALLER does (devcon install, then
             disabling the emulated VGA) and which makes the kernel run cache-flush cross calls.
             Off by default: it needs a device to pick and it is far more disruptive.

    It does NOT claim to reproduce the wedge; it raises the rate of the operation the wedge
    happens inside. The harness that runs it decides whether a wedge occurred, by its own probes.

.PARAMETER Seconds      how long to run (default 120)
.PARAMETER Threads      worker threads; default = processor count, which is the point
.PARAMETER MB           per-iteration allocation size in MiB (default 8)
.PARAMETER PnpDevice    optional: a device instance id to disable/enable in a loop alongside
#>
param(
    [int]$Seconds = 120,
    [int]$Threads = 0,
    [int]$MB = 8,
    [string]$PnpDevice = ''
)
$ErrorActionPreference = 'Stop'
if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class Storm {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);
    [DllImport("kernel32.dll")] static extern bool SetThreadAffinityMask(IntPtr t, UIntPtr mask);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000, PAGE_RW = 0x04;
    public static long Cycles = 0;
    public static volatile bool Stop = false;
    // THREADS ARE STARTED HERE, not from PowerShell. A PowerShell scriptblock cannot be used as a
    // ParameterizedThreadStart on 5.1: the first version of this file did that, printed its start
    // banner, and exited within two seconds having run nothing - which the harness caught only
    // because the cycle heartbeat is a MEASUREMENT and its absence marks the round UNMEASURED.
    public static void Start(int threads, long bytes) {
        Stop = false; Cycles = 0;
        for (int i = 0; i < threads; i++) {
            int cpu = i % Environment.ProcessorCount;
            Thread t = new Thread(delegate() { Worker(cpu, bytes); });
            t.IsBackground = true;
            t.Start();
        }
    }
    public static void Worker(int cpu, long bytes) {
        // Pin to one processor: the shootdown has to cross processors to be interesting, and a
        // roaming thread would mostly hit its own TLB.
        SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << cpu));
        while (!Stop) {
            IntPtr p = VirtualAlloc(IntPtr.Zero, (UIntPtr)bytes, MEM_COMMIT|MEM_RESERVE, PAGE_RW);
            if (p == IntPtr.Zero) { Thread.Sleep(1); continue; }
            // Touch every page so the mapping is really established on THIS processor...
            for (long off = 0; off < bytes; off += 4096) Marshal.WriteByte(p, (int)off, 1);
            // ...then release it, which is what forces the other processors' TLBs to be shot down.
            VirtualFree(p, UIntPtr.Zero, MEM_RELEASE);
            Interlocked.Increment(ref Cycles);
        }
    }
}
'@

Write-Output ("IPISTORM start threads=$Threads mb=$MB seconds=$Seconds cpus=" + [Environment]::ProcessorCount)
$bytes = [long]$MB * 1MB
[Storm]::Start($Threads, $bytes)
Start-Sleep -Seconds 2
if ([Storm]::Cycles -le 0) {
    # Refuse to report a storm that is not turning. An UNMEASURED round is a legitimate outcome;
    # a silent no-op dressed as a run is not.
    Write-Output "IPISTORM ERROR no cycles after 2s - the workers did not start"
    exit 3
}

$pnpJob = $null
if ($PnpDevice) {
    Write-Output "IPISTORM pnp cycling $PnpDevice"
    $pnpJob = Start-Job -ScriptBlock {
        param($dev, $secs)
        $end = (Get-Date).AddSeconds($secs)
        while ((Get-Date) -lt $end) {
            Disable-PnpDevice -InstanceId $dev -Confirm:$false -EA SilentlyContinue
            Start-Sleep -Milliseconds 400
            Enable-PnpDevice  -InstanceId $dev -Confirm:$false -EA SilentlyContinue
            Start-Sleep -Milliseconds 400
        }
    } -ArgumentList $PnpDevice, $Seconds
}

$deadline = (Get-Date).AddSeconds($Seconds)
$last = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $now = [Storm]::Cycles
    # A HEARTBEAT WITH A RATE, not a dot: if the guest is about to wedge, the rate collapsing to
    # zero while this script still runs is itself the interesting observation.
    Write-Output ("IPISTORM t={0:HH:mm:ss} cycles={1} rate={2}/s" -f (Get-Date), $now, [math]::Round(($now-$last)/10,1))
    $last = $now
}
[Storm]::Stop = $true
Start-Sleep -Seconds 2
if ($pnpJob) { Receive-Job $pnpJob -EA SilentlyContinue | Out-Null; Remove-Job $pnpJob -Force -EA SilentlyContinue }
Write-Output ("IPISTORM done cycles=" + [Storm]::Cycles)
