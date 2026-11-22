<#
.SYNOPSIS
    Close event channels WHILE their events are being dispatched, from threads spread over the
    CPUs or all on CPU 0 - the high-rate reproducer that decides whether CPU placement alone keeps
    stock xenbus's bucket lock from wedging.

.DESCRIPTION
    The freeze (findings/wedge.md, kind C) is a vCPU spinning in xenbus's hash-table bucket lock.
    A model check of that lock finds stuck states only when two users of one bucket run on two
    CPUs. Event dispatch takes the bucket as a READER on the CPU that polls (evtchn.c:506); under
    the FIFO ABI that is the port's bound vCPU, 0 for every channel we open. A channel CLOSE takes
    it as a WRITER on the closing thread's CPU (evtchn.c:953). So a close racing its own pending
    events is the user-mode shape of the field trigger, with every Qubes transport removed.

    Each worker loops: open an unbound channel P to this domain, bind Q to it (a loopback pair),
    send -Notifies events through Q, then close P at once - with its events in flight - and Q.
    The September tool (origin/xenbus-store-wait-research tools/evtchnstorm) opened and closed
    unbound channels with no events at all, so it never exercised the reader; this one does, and
    COUNTS it: `delivered` is the number of pairs whose event had already fired before the close.

      -Placement spread   worker i on CPU (i mod N): readers on CPU 0, writers on every CPU
      -Placement cpu0     every worker on CPU 0: readers and writers on one CPU

    It changes nothing in any driver. It does not claim the product's teardown is the same: it
    covers event-channel open, close and dispatch on a process's own threads only - not the grant
    map table, not a killed process's cleanup on a system worker, not xenvif's off-CPU-0 binds.

.PARAMETER Seconds       stop after this long (default 300)
.PARAMETER MaxPairs      also stop after this many pairs in all; 0 = no pair budget
.PARAMETER Threads       worker threads; default = processor count
.PARAMETER Placement     spread | cpu0
.PARAMETER RemoteDomain  the peer for the loopback pair; default DOMID_SELF (0x7FF0)
.PARAMETER Notifies      events sent into each pair before its close (default 4)
#>
param(
    [int]$Seconds = 300,
    [long]$MaxPairs = 0,
    [int]$Threads = 0,
    [ValidateSet('spread', 'cpu0')][string]$Placement = 'spread',
    [int]$RemoteDomain = 0x7FF0,
    [int]$Notifies = 4
)
$ErrorActionPreference = 'Stop'
if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }

$dll = @('C:\Program Files\Qubes Tools\bin\xencontrol.dll', 'C:\Program Files\Qubes Tools\xencontrol.dll',
         'C:\Program Files\Xen PV Drivers\bin\xencontrol.dll') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dll) {
    $hit = Get-ChildItem 'C:\Program Files' -Recurse -Filter xencontrol.dll -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $dll = $hit.FullName }
}
if (-not $dll) { Write-Output 'EVTSTORM ERROR xencontrol.dll not found'; exit 2 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class EvtchnStorm {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr t, UIntPtr mask);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessorNumber();
    [DllImport("kernel32.dll")] static extern IntPtr CreateEventW(IntPtr sa, int manual, int initial, IntPtr name);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern int CloseHandle(IntPtr h);
    [DllImport("xencontrol.dll")] static extern uint XcOpen(IntPtr logger, out IntPtr xc);
    [DllImport("xencontrol.dll")] static extern void XcClose(IntPtr xc);
    [DllImport("xencontrol.dll")] static extern uint XcEvtchnOpenUnbound(IntPtr xc, ushort remoteDomain, IntPtr ev, int mask, out uint port);
    [DllImport("xencontrol.dll")] static extern uint XcEvtchnBindInterdomain(IntPtr xc, ushort remoteDomain, uint remotePort, IntPtr ev, int mask, out uint port);
    [DllImport("xencontrol.dll")] static extern uint XcEvtchnClose(IntPtr xc, uint port);
    [DllImport("xencontrol.dll")] static extern uint XcEvtchnNotify(IntPtr xc, uint port);

    public static long Pairs = 0, Delivered = 0, Errors = 0, MaxPairs = 0;
    public static volatile bool Stop = false;
    public static string Placements = "";

    // The DLL is loaded by full path ONCE, so every [DllImport("xencontrol.dll")] above binds to
    // that module by its base name.
    public static bool Load(string path) { return LoadLibraryW(path) != IntPtr.Zero; }

    // One pair, waiting for its event: proves open, self-bind and delivery work before the storm,
    // so a storm that never reaches the reader cannot read as a survival.
    public static string Probe(ushort rd) {
        IntPtr xc, evP = CreateEventW(IntPtr.Zero, 0, 0, IntPtr.Zero), evQ = CreateEventW(IntPtr.Zero, 0, 0, IntPtr.Zero);
        uint rc = XcOpen(IntPtr.Zero, out xc); if (rc != 0) return "XcOpen rc=" + rc;
        uint p, q;
        rc = XcEvtchnOpenUnbound(xc, rd, evP, 0, out p); if (rc != 0) { XcClose(xc); return "OpenUnbound rc=" + rc; }
        rc = XcEvtchnBindInterdomain(xc, rd, p, evQ, 1, out q); if (rc != 0) { XcEvtchnClose(xc, p); XcClose(xc); return "BindInterdomain rc=" + rc; }
        rc = XcEvtchnNotify(xc, q);
        uint w = WaitForSingleObject(evP, 2000);
        XcEvtchnClose(xc, p); XcEvtchnClose(xc, q); XcClose(xc); CloseHandle(evP); CloseHandle(evQ);
        if (rc != 0) return "Notify rc=" + rc;
        return w == 0 ? "ok p=" + p + " q=" + q : "no delivery within 2 s (p=" + p + " q=" + q + ")";
    }

    public static void Start(int threads, bool cpu0, ushort rd, int notifies, long maxPairs) {
        Stop = false; Pairs = 0; Delivered = 0; Errors = 0; MaxPairs = maxPairs; Placements = "";
        int n = Environment.ProcessorCount;
        for (int i = 0; i < threads; i++) {
            int cpu = cpu0 ? 0 : i % n;
            Thread t = new Thread(delegate() { Worker(cpu, rd, notifies); });
            t.IsBackground = true;
            t.Start();
        }
    }

    static void Worker(int cpu, ushort rd, int notifies) {
        UIntPtr want = (UIntPtr)(1UL << cpu);
        SetThreadAffinityMask(GetCurrentThread(), want);
        UIntPtr got = SetThreadAffinityMask(GetCurrentThread(), want);   // returns the mask now in force
        Thread.Sleep(0);
        lock (typeof(EvtchnStorm)) { Placements += " want=0x" + want.ToUInt64().ToString("x") + "/got=0x" + got.ToUInt64().ToString("x") + "/on=" + GetCurrentProcessorNumber(); }
        IntPtr xc;
        if (XcOpen(IntPtr.Zero, out xc) != 0) { Interlocked.Increment(ref Errors); return; }
        IntPtr evP = CreateEventW(IntPtr.Zero, 0, 0, IntPtr.Zero), evQ = CreateEventW(IntPtr.Zero, 0, 0, IntPtr.Zero);
        while (!Stop && (MaxPairs == 0 || Interlocked.Read(ref Pairs) < MaxPairs)) {
            uint p, q;
            if (XcEvtchnOpenUnbound(xc, rd, evP, 0, out p) != 0) { Interlocked.Increment(ref Errors); Thread.Sleep(1); continue; }
            if (XcEvtchnBindInterdomain(xc, rd, p, evQ, 1, out q) != 0) { Interlocked.Increment(ref Errors); XcEvtchnClose(xc, p); continue; }
            for (int k = 0; k < notifies; k++) XcEvtchnNotify(xc, q);
            if (WaitForSingleObject(evP, 0) == 0) Interlocked.Increment(ref Delivered);
            XcEvtchnClose(xc, p);   // the writer, with P's events possibly still being dispatched
            XcEvtchnClose(xc, q);
            Interlocked.Increment(ref Pairs);
        }
        CloseHandle(evP); CloseHandle(evQ); XcClose(xc);
    }
}
'@

if (-not [EvtchnStorm]::Load($dll)) { Write-Output "EVTSTORM ERROR LoadLibrary failed: $dll"; exit 2 }
$rd = [uint16]$RemoteDomain
$probe = [EvtchnStorm]::Probe($rd)
Write-Output "EVTSTORM probe $probe dll=$dll"
if ($probe -notlike 'ok*') {
    # Refuse to storm without a working reader: an unbound-only storm is the September tool again.
    Write-Output 'EVTSTORM ERROR loopback pair or event delivery does not work - nothing would exercise the reader'
    exit 3
}
$proc = [Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity
Write-Output ("EVTSTORM start placement=$Placement threads=$Threads cpus=" + [Environment]::ProcessorCount +
              " notifies=$Notifies seconds=$Seconds maxpairs=$MaxPairs process_mask=0x{0:x}" -f [int64]$proc)
[EvtchnStorm]::Start($Threads, ($Placement -eq 'cpu0'), $rd, $Notifies, $MaxPairs)
Start-Sleep -Seconds 2
Write-Output ("EVTSTORM workers" + [EvtchnStorm]::Placements)
if ([EvtchnStorm]::Pairs -le 0) { Write-Output 'EVTSTORM ERROR no pairs after 2s - the workers did not start'; exit 3 }

$deadline = (Get-Date).AddSeconds($Seconds)
$last = 0
while ((Get-Date) -lt $deadline -and ($MaxPairs -eq 0 -or [EvtchnStorm]::Pairs -lt $MaxPairs)) {
    Start-Sleep -Seconds 5
    $now = [EvtchnStorm]::Pairs
    # A RATE, not a dot: the rate collapsing to zero while this script still prints is itself the
    # observation (a worker spinning at HIGH_LEVEL takes its CPU with it).
    Write-Output ("EVTSTORM t={0:HH:mm:ss} pairs={1} delivered={2} errors={3} rate={4}/s" -f (Get-Date), $now,
                  [EvtchnStorm]::Delivered, [EvtchnStorm]::Errors, [math]::Round(($now - $last) / 5, 0))
    $last = $now
}
[EvtchnStorm]::Stop = $true
Start-Sleep -Seconds 2
Write-Output ("EVTSTORM done pairs=" + [EvtchnStorm]::Pairs + " delivered=" + [EvtchnStorm]::Delivered + " errors=" + [EvtchnStorm]::Errors)
