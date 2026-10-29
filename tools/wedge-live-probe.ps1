# LIVE introspection of a stuck qrexec process, run WHILE it is stuck.
#
# This only became possible with core-agent 190c190. Before it, a wrapper blocked in
# GNTTABOP_unmap_grant_ref took the agent's event loop with it - the agent handed up to 130 handles
# to a WaitForMultipleObjects that hard-caps at 64, the call was rejected outright, and a single
# WAIT_FAILED broke the loop for good. The guest went silent, so the only instrument left was a
# memory image taken after the kill, and everything in findings/wedge.md was reconstructed from
# one. With the agent surviving a stuck child, qrexec still answers and the wedge can be
# interrogated as a LIVE condition instead of an autopsy.
#
# WHAT THIS CAN AND CANNOT SEE, stated up front so nothing here gets over-read.
# The specimen blocks PAST the vmcall, inside the hypercall, with the vCPU never released
# (pause_flags=4 VPF_blocked_in_xen). No user-mode instrument can see that - not this one, not a
# debugger. What user mode CAN settle, and what the memory image had to be mined for:
#   - WHICH call it is stuck in. A thread parked in NtDeviceIoControlFile with xeniface's ioctl
#     path on its stack is the gnttab map/unmap; which of the three map IOCTLs, or the unmap inside
#     libvchan_close, is the thing we have never read directly.
#   - WHETHER THE OTHER THREADS GOT OUT. The pumps, the control handler, whether the exit code was
#     ever sent. That decides between the exit-path branches in qrexec-wrapper.c rather than
#     inferring them.
#   - OUR OWN GLOBALS. g_VchanClosing / g_VchanOpen / g_exitReason are in the full-memory dump, and
#     they discriminate the cleanup branches outright.
# Kernel stacks need a kernel debugger over a second transport, which this rig does not have.
#
# USAGE (over qrexec, from dom0 or this qube, while the wedge is live):
#   QTEST_VM=<vm> tools/qtest pushrun tools/wedge-live-probe.ps1 -Name qrexec-wrapper
#   QTEST_VM=<vm> tools/qtest pushrun tools/wedge-live-probe.ps1 -ProcId 1672 -Stacks -Dump
#
# IT DOES NOT PERTURB THE SPECIMEN BY DEFAULT. -Dump is opt-in because MiniDumpWriteDump suspends
# every thread and reads each one's context, and a thread that is blocked in a hypercall which
# never returns is exactly the thread that may never yield one. So the dump runs LAST, in a
# SEPARATE process, under a bound - a hang there costs the dump, never the reading above it, which
# is already printed and flushed by then. Nothing here kills, suspends or resumes anything.

[CmdletBinding()]
param(
    [string]$Name = 'qrexec-wrapper',
    [int]$ProcId = 0,
    [switch]$Stacks,
    [switch]$Dump,
    [string]$DumpDir = '',
    [int]$DumpTimeoutSec = 90
)

$ErrorActionPreference = 'Continue'
function Emit([string]$s) { Write-Output $s }

Emit ("PROBE host=" + $env:COMPUTERNAME + " utc=" + ([datetime]::UtcNow.ToString('o')) + " up_s=" +
      [int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)

# ---- 1. pick the subjects ---------------------------------------------------------------------
$procs = @()
if ($ProcId -gt 0) {
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if ($p) { $procs = @($p) } else { Emit "NOPROC pid=$ProcId"; exit 1 }
} else {
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if (-not $procs -or $procs.Count -eq 0) { Emit "NOPROC name=$Name"; exit 1 }
}
Emit ("SUBJECTS n=" + $procs.Count)

# ---- 2. the agent's own view, which the fix made readable --------------------------------------
# 190c190 logs slot exhaustion with the count in use, and logs when the wait set goes windowed.
# Both lines are the agent saying how close it is to the 62-handle threshold - the number Jev has
# open as concurrent_connection_count - so they are worth pulling on every probe, not only on a
# wedge.
$agent = Get-Process -Name qrexec-agent -ErrorAction SilentlyContinue
if ($agent) {
    $at = $null
    try { $at = [int]$agent.TotalProcessorTime.TotalMilliseconds } catch { $at = -1 }
    Emit ("AGENT pid=" + $agent.Id + " threads=" + $agent.Threads.Count + " cpu_ms=" + $at +
          " handles=" + $agent.HandleCount)
} else {
    Emit "AGENT absent - if the agent is gone this is NOT the condition 190c190 addresses"
}
$logdir = 'C:\Program Files\Qubes Tools\log'
$alog = Get-ChildItem $logdir -Filter 'qrexec-agent*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
if ($alog) {
    Emit ("AGENTLOG " + $alog.Name + " size=" + $alog.Length + " lastwrite=" + $alog.LastWriteTime.ToString('o'))
    # The exact strings 190c190 emits. Anchored on the message, not on a level prefix: a level
    # change blinds every parser that anchors on one.
    Get-Content $alog.FullName -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch 'No free slot for child', 'slots in use', 'wait set windowed', 'WaitForMultipleObjects' |
        Select-Object -Last 25 | ForEach-Object { Emit ("AGENTLINE " + $_.Line.Trim()) }
    Get-Content $alog.FullName -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Emit ("AGENTTAIL " + $_) }
}

# ---- 3. per-process, per-thread state ----------------------------------------------------------
# THE CPU NUMBER IS THE DISCRIMINATOR, not the wait reason alone. A guest-side wedge and a stall
# below the guest look identical in a thread list; zero cputime that stays zero across two samples
# separates them. Two samples are taken here, four seconds apart, so one probe decides it.
foreach ($p in $procs) {
    $tot1 = $null
    try { $tot1 = $p.TotalProcessorTime.TotalMilliseconds } catch { $tot1 = -1 }
    $cmd = ''
    try { $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.Id)).CommandLine } catch { }
    # The command line carries the domain and port this wrapper serves; it is how a stuck child is
    # tied back to the connection the agent registered for it.
    Emit ("PROC pid=" + $p.Id + " name=" + $p.ProcessName + " threads=" + $p.Threads.Count +
          " handles=" + $p.HandleCount + " ws_kb=" + [int]($p.WorkingSet64 / 1kb) +
          " start=" + $(try { $p.StartTime.ToString('o') } catch { 'unknown' }) +
          " cpu_ms=" + $tot1)
    Emit ("PROCCMD pid=" + $p.Id + " " + $cmd)

    foreach ($t in $p.Threads) {
        $st = ''; $wr = ''; $tms = -1; $sa = ''
        try { $st = $t.ThreadState.ToString() } catch { $st = 'unreadable' }
        # WaitReason THROWS unless ThreadState is Wait - reading it unconditionally is how a probe
        # turns a readable thread list into an exception.
        if ($st -eq 'Wait') { try { $wr = $t.WaitReason.ToString() } catch { $wr = 'unreadable' } }
        try { $tms = [int]$t.TotalProcessorTime.TotalMilliseconds } catch { $tms = -1 }
        try { $sa = '0x' + $t.StartAddress.ToString('x') } catch { $sa = '?' }
        Emit ("THREAD pid=" + $p.Id + " tid=" + $t.Id + " state=" + $st + " wait=" + $wr +
              " cpu_ms=" + $tms + " start=" + $sa + " prio=" + $(try { $t.CurrentPriority } catch { '?' }))
    }

    # Module bases, so a return address read later from the dump resolves against the guest's OWN
    # pdb rather than against whatever this qube happens to have.
    $mods = @()
    try { $mods = @($p.Modules) } catch { Emit ("MODULEERR pid=" + $p.Id + " " + $_.Exception.Message) }
    foreach ($m in $mods) {
        if ($m.ModuleName -match 'qrexec|xencontrol|xeniface|vchan|qubes') {
            Emit ("MODULE pid=" + $p.Id + " " + $m.ModuleName + " base=0x" + $m.BaseAddress.ToString('x') +
                  " size=" + $m.ModuleMemorySize + " ver=" + $m.FileVersionInfo.FileVersion)
        }
    }
}

Start-Sleep -Seconds 4
foreach ($p in $procs) {
    $p.Refresh()
    $tot2 = $null
    try { $tot2 = $p.TotalProcessorTime.TotalMilliseconds } catch { $tot2 = -1 }
    Emit ("PROCDELTA pid=" + $p.Id + " cpu_ms_after_4s=" + $tot2 +
          "  # unchanged = not spinning; a wedge in the hypercall burns NO guest cpu")
}

# ---- 3b. WHICH CALL IS IT STUCK IN - a stack read, with no debugger to install ------------------
# This is the question the memory image had to be mined for, and the one a thread list cannot
# answer: a thread parked in NtDeviceIoControlFile tells you it is in an IOCTL, not WHICH one.
#
# WHY NOT A REAL STACK WALK. StackWalk64 needs STACKFRAME64 + KDHELP64 marshalled by hand and a
# symbol handler, and all of that to recover what we actually want, which is just "whose code is
# on this thread's stack and at what offset". So instead: take the thread's RSP, read the stack
# upward, and keep every 8-byte value that lands inside one of OUR modules. Return addresses are
# pushed by CALL, so the hits ARE the call chain - in stack order, with junk between them. The
# offsets resolve against the guest's own pdb afterwards; nothing here needs symbols present.
#
# IT SUSPENDS THE THREAD, briefly, which is why it is opt-in. GetThreadContext on a thread blocked
# in a syscall returns the user-mode context saved at the kernel boundary - which is exactly the
# frame we want - and that is also what any debugger attach would do to it. Every suspend is
# paired with a resume in a finally.
if ($Stacks) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PS {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenThread(int a, bool inh, uint tid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint SuspendThread(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern int ResumeThread(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(int a, bool inh, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(
      IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
}
"@
    # x64 CONTEXT is 1232 bytes and must be 16-byte aligned; RSP sits at 0x98, RIP at 0xF8.
    # CONTEXT_FULL on amd64 = CONTEXT_AMD64(0x100000) | CONTROL(1) | INTEGER(2) | FLOATING_POINT(8)
    $CTXSZ = 1232; $OFF_FLAGS = 0x30; $OFF_RSP = 0x98; $OFF_RIP = 0xF8; $CONTEXT_FULL = 0x0010000B
    $PROCESS_VM_READ = 0x0010; $PROCESS_QUERY_INFORMATION = 0x0400
    $THREAD_GET_CONTEXT = 0x0008; $THREAD_QUERY_INFORMATION = 0x0040; $THREAD_SUSPEND_RESUME = 0x0002

    foreach ($p in $procs) {
        # The module ranges a return address is matched against. Everything in the image, not only
        # ours: a frame in xencontrol or ntdll is as much of an answer as one in qrexec-wrapper.
        $ranges = @()
        $mods2 = @()
        try { $mods2 = @($p.Modules) } catch { Emit ("MODULEERR pid=" + $p.Id + " " + $_.Exception.Message) }
        if ($mods2.Count -eq 0) { Emit ("STACKSKIP pid=" + $p.Id + " no module list - a return address could not be attributed"); continue }
        foreach ($m in $mods2) {
            $ranges += [pscustomobject]@{
                Name = $m.ModuleName
                Lo   = [uint64]$m.BaseAddress.ToInt64()
                Hi   = [uint64]($m.BaseAddress.ToInt64() + $m.ModuleMemorySize)
            }
        }
        $hProc = [PS]::OpenProcess(($PROCESS_VM_READ -bor $PROCESS_QUERY_INFORMATION), $false, $p.Id)
        if ($hProc -eq [IntPtr]::Zero) {
            Emit ("STACKERR pid=" + $p.Id + " OpenProcess gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
            continue
        }
        try {
            foreach ($t in $p.Threads) {
                $hThr = [PS]::OpenThread(($THREAD_GET_CONTEXT -bor $THREAD_QUERY_INFORMATION -bor $THREAD_SUSPEND_RESUME),
                                         $false, [uint32]$t.Id)
                if ($hThr -eq [IntPtr]::Zero) {
                    Emit ("STACKERR tid=" + $t.Id + " OpenThread gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
                    continue
                }
                $raw = [IntPtr]::Zero
                try {
                    $raw = [Runtime.InteropServices.Marshal]::AllocHGlobal($CTXSZ + 16)
                    $aligned = [IntPtr](([int64]$raw + 15) -band (-16))
                    [Runtime.InteropServices.Marshal]::WriteInt32($aligned, $OFF_FLAGS, $CONTEXT_FULL)
                    $susp = [PS]::SuspendThread($hThr)
                    if ($susp -eq [uint32]::MaxValue) {
                        Emit ("STACKERR tid=" + $t.Id + " SuspendThread gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
                        continue
                    }
                    try {
                        if (-not [PS]::GetThreadContext($hThr, $aligned)) {
                            # A CONTEXT THAT NEVER ARRIVES IS ITSELF THE ANSWER for a thread that
                            # entered the hypervisor and did not come back - report it, do not
                            # swallow it as a probe failure.
                            Emit ("STACKNOCTX tid=" + $t.Id + " gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error() +
                                  "  # no user context - consistent with a thread that never returned from the kernel")
                        } else {
                            $rsp = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($aligned, $OFF_RSP)
                            $rip = [uint64][Runtime.InteropServices.Marshal]::ReadInt64($aligned, $OFF_RIP)
                            $ripWho = 'unmapped'
                            foreach ($r in $ranges) { if ($rip -ge $r.Lo -and $rip -lt $r.Hi) { $ripWho = $r.Name + '+0x' + ($rip - $r.Lo).ToString('x'); break } }
                            Emit ("RIP tid=" + $t.Id + " rip=0x" + $rip.ToString('x') + " " + $ripWho +
                                  " rsp=0x" + $rsp.ToString('x'))

                            # [IntPtr] has no UInt64 conversion in Windows PowerShell - every
                            # address crossing the P/Invoke boundary goes through [int64].
                            #
                            # PAGE AT A TIME, because the read runs off the TOP of the stack.
                            # ReadProcessMemory fails the WHOLE call on a partial read: measured on
                            # wedgeprobe 2026-10-30, one 64 KB read from RSP returned gle=299
                            # ERROR_PARTIAL_COPY for all six threads and yielded no frames at all.
                            # A page-sized walk that stops at the first unreadable page keeps every
                            # byte below it, and the stack we want is the part nearest RSP anyway.
                            # AND THE FIRST READ IS SHORT, to land on a page boundary. Measured on
                            # wedgeprobe 2026-10-30: page-sized reads starting at an unaligned RSP
                            # straddle the TOP of the stack region, and five of six threads returned
                            # gle=299 with zero bytes while the sixth - the one whose RSP happened to
                            # sit far enough below the boundary - returned a full 15-frame chain. The
                            # straddle was the whole difference, not the thread. Aligning after the
                            # first short read means a failure now means genuinely unmapped.
                            $PAGE = 4096; $MAXREAD = 64kb
                            $frames = 0; $total = 0; $stopped = ''
                            $buf = New-Object byte[] $PAGE
                            $addr = $rsp
                            while ($total -lt $MAXREAD -and $frames -lt 40) {
                                $len = $PAGE - [int]($addr % [uint64]$PAGE)
                                $got = [IntPtr]::Zero
                                if (-not [PS]::ReadProcessMemory($hProc, [IntPtr][int64]$addr, $buf, [IntPtr][int64]$len, [ref]$got)) {
                                    $stopped = 'gle=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ' at +0x' + $total.ToString('x')
                                    break
                                }
                                $n = [int]$got
                                if ($n -le 0) { $stopped = 'short read at +0x' + $total.ToString('x'); break }
                                for ($i = 0; $i -le $n - 8 -and $frames -lt 40; $i += 8) {
                                    $v = [uint64][BitConverter]::ToInt64($buf, $i)
                                    if ($v -lt 0x10000) { continue }
                                    foreach ($r in $ranges) {
                                        if ($v -ge $r.Lo -and $v -lt $r.Hi) {
                                            Emit ("FRAME tid=" + $t.Id + " +0x" + ($total + $i).ToString('x') +
                                                  " ret=0x" + $v.ToString('x') + " " + $r.Name + "+0x" + ($v - $r.Lo).ToString('x'))
                                            $frames++
                                            break
                                        }
                                    }
                                }
                                $total += $n
                                $addr  = $addr + [uint64]$n
                            }
                            Emit ("STACKEND tid=" + $t.Id + " bytes=" + $total + " frames=" + $frames +
                                  $(if ($stopped) { " stopped=" + $stopped } else { "" }))
                        }
                    } finally { [void][PS]::ResumeThread($hThr) }
                } finally {
                    if ($raw -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($raw) }
                    [void][PS]::CloseHandle($hThr)
                }
            }
        } finally { [void][PS]::CloseHandle($hProc) }
    }
} else {
    Emit "STACKS skipped (pass -Stacks); it suspends each thread for the length of one context read"
}

# ---- 4. the optional dump, bounded and out-of-process -------------------------------------------
if ($Dump) {
    # THE DUMP BELONGS ON THE LOG VOLUME, not on C:. A wedge is exactly the case where qrexec may
    # stop answering before anyone pulls the file off, and the DIAG image is the store the HOST can
    # read with mtools and no guest at all. So the bound LogDir is preferred and TEMP is only the
    # fallback; the resolved path is printed either way, because "where did it go" is not something
    # a later operator should have to guess.
    if (-not $DumpDir) {
        $ld = $null
        try { $ld = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir } catch { }
        if ($ld -and (Test-Path $ld)) { $DumpDir = $ld; Emit ("DUMPDIR logvol " + $ld) }
        else { $DumpDir = $env:TEMP; Emit ("DUMPDIR fallback " + $DumpDir + " - LogDir unset or absent, so this does NOT survive a guest that stops answering") }
    }
    $target = $procs[0]
    $stamp  = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $out    = Join-Path $DumpDir ("wedge-" + $target.ProcessName + "-" + $target.Id + "-" + $stamp + ".dmp")
    Emit ("DUMP_BEGIN pid=" + $target.Id + " path=" + $out + " bound_s=" + $DumpTimeoutSec)

    # MiniDumpWithFullMemory: the globals are the point, and a normal minidump does not carry them.
    $inner = @'
param([int]$TargetPid, [string]$Out)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MD {
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool MiniDumpWriteDump(IntPtr h, uint pid, IntPtr file, int type,
                                              IntPtr ex, IntPtr user, IntPtr cb);
}
"@
$p = Get-Process -Id $TargetPid -ErrorAction Stop
$fs = [System.IO.File]::Create($Out)
try {
    # 0x2 MiniDumpWithFullMemory | 0x4 MiniDumpWithHandleData | 0x800 MiniDumpWithFullMemoryInfo
    # | 0x1000 MiniDumpWithThreadInfo
    $ok = [MD]::MiniDumpWriteDump($p.Handle, [uint32]$TargetPid, $fs.SafeFileHandle.DangerousGetHandle(),
                                  (0x2 -bor 0x4 -bor 0x800 -bor 0x1000),
                                  [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($ok) { Write-Output ("DUMP_OK " + $Out) }
    else     { Write-Output ("DUMP_FAIL gle=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
} finally { $fs.Close() }
'@
    $innerPath = Join-Path $env:TEMP 'wedge-dump-inner.ps1'
    Set-Content -LiteralPath $innerPath -Value $inner -Encoding ASCII

    # A SEPARATE PROCESS UNDER A BOUND. If the target never yields a thread context this child
    # hangs; everything above is already printed, and the bound is what keeps the probe itself from
    # becoming a second stuck process. No kill on expiry - killing a dumper mid-write is how a
    # specimen gets damaged; it is reported and left for the operator.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $innerPath + '" -TargetPid ' +
                     $target.Id + ' -Out "' + $out + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $child = [System.Diagnostics.Process]::Start($psi)
    if ($child.WaitForExit($DumpTimeoutSec * 1000)) {
        $so = $child.StandardOutput.ReadToEnd().Trim()
        $se = $child.StandardError.ReadToEnd().Trim()
        if ($so) { $so -split "`n" | ForEach-Object { Emit ("DUMP " + $_.Trim()) } }
        if ($se) { $se -split "`n" | ForEach-Object { Emit ("DUMPERR " + $_.Trim()) } }
        if (Test-Path $out) { Emit ("DUMP_SIZE " + (Get-Item $out).Length) }
    } else {
        # THIS IS ITSELF A RESULT, and a strong one: a full-memory dump that cannot complete means
        # a thread never yielded its context, which is what a thread parked inside a hypercall
        # looks like from user mode.
        Emit ("DUMP_TIMEOUT after ${DumpTimeoutSec}s - dumper pid=" + $child.Id +
              " left running; a context that never arrives IS the blocked-in-Xen signature")
    }
} else {
    Emit "DUMP skipped (pass -Dump); the reading above does not touch the specimen"
}

Emit "PROBE_END"
