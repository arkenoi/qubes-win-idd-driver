# sup-goingdown-latch.ps1 - ADR-supervision item 2b, the going-down latch, which had RUNNER: none.
#
#   Item 2b shipped 2026-11-06 with five call sites and no run behind it, and the register entry
#   LAUNCHINTOADYINGSESSION says what is owed in its own words: "prove in a run that the service's
#   launch is REFUSED while the latch is held and allowed after the release".
#
# Run as SYSTEM with the guest UP. The latch's DACL is D:P(A;;GA;;;SY) - SYSTEM only - so an
# interactive token cannot open the object at all, and a run as the logged-on user would report
# "not held" for a latch that IS held. No shutdown, no detach: the channel survives and the harness
# reads the transcript back.
#
# HYPOTHESIS: with the latch published for the console session by a process that has EXITED, the
#   service's launch guard reads it on the next pass that wants to launch, ADOPTS it
#   (QGAWDGOINGDOWN ... adopting it) and launches nothing into that session; when the latch is
#   RELEASED the guard launches again. REFUTED by: an agent appearing in that session while the
#   latch is held (the defect the latch exists for), no adopt line at all (the guard never read
#   it), or no agent after the release (the latch strands the guest's GUI - worse than the defect).
# BASELINE: the -Control arm. The same kill with NO latch published: the agent must come back and
#   NO adopt line may appear. Without it a refusal proves nothing, because an agent that fails to
#   return for its own reasons reads exactly like a refusal.
# VARIABLE: one published latch. The kill, the subject and the timings are identical in both arms.
# INSTRUMENT: this transcript. It is validated BEFORE the stimulus by `pre_open`, which opens the
#   latch name before anything creates it and must report 0xC0000034: that is the leg proving the
#   held/not-held reading can come back negative, so `held_after_publish=0x00000000` is evidence and
#   not decoration. It can FAIL: a kill that does not land leaves `killed` absent, a privilege that
#   cannot be enabled leaves `pub_publish_status` non-zero, and the harness grades either INVALID -
#   never PASS.
# BUDGET: the release must happen INSIDE SESSION_END_NEVER_HAPPENED_MS (90 s, watchdog.c:96), which
#   is -WindowSec. At that bound the watchdog releases the latch ITSELF and launches, logging
#   QGAWDSESSIONSTUCK, so a launch after it is the recovery's and not ours (Jev
#   assert_inside_the_window 0.79 against letting the recovery fire as a second arm 0.20). Hence
#   `stuck_lines` is reported and the harness requires 0: it is what makes the post-release launch
#   attributable. Deadline -DeadlineSec per wait, three exits each, every exit named.
#
# THE OBJECT'S IDENTITY IS PASSED IN, NOT DEFAULTED. The name, the SDDL, the access mask and the
# OBJ_PERMANENT flag come from agent/include/qga-lifecycle.h via the harness, because a default
# here would let a product rename pass as "the latch was not held" - the cell would measure nothing
# and report PASS. No default target inside a harness (lint L10).
#
# THIS CELL ENDS AN AGENT, so it produces a death record, one dom0 notification and a death-number
# increment. L8 and L11 assert DELTAS on exactly those, so this runs after them, never before.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Out,
    # '\BaseNamedObjects\QGA_GOINGDOWN_{0}' - the harness translates the header's %lu to {0}.
    [Parameter(Mandatory)][string]$NtNameFmt,
    [Parameter(Mandatory)][string]$Sddl,
    [Parameter(Mandatory)][uint32]$Access,
    [Parameter(Mandatory)][uint32]$PermanentFlag,
    # The publisher must be a process that is GONE before the guard reads the latch, so this script
    # re-invokes ITSELF with -PublishOnly and that child exits. One file, no duplicated interop.
    [switch]$PublishOnly,
    [switch]$Control,
    [int]$DeadlineSec = 240,
    [int]$WindowSec = 90
)

$ErrorActionPreference = 'Continue'

# The child's keys are prefixed so the one transcript cannot be misread: `publish_status` written by
# a process that is still running would mean something different from the child's `pub_` record.
$KP = if ($PublishOnly) { 'pub_' } else { '' }

function T($k, $v) {
    $line = "L12|$KP$k|$v"
    try { $line | Out-File -LiteralPath $Out -Append -Encoding ASCII } catch { }
    Write-Output $line
}

function Hex($n) { '0x{0:X8}' -f ([uint32]($n -band 0xFFFFFFFFL)) }

$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
if (-not $PublishOnly) {
    T 'arm' $(if ($Control) { 'CONTROL' } else { 'INJECTED' })
    T 'logdir' $logdir
}
if (-not $logdir) { T 'terminal' 'no LogDir in the registry - nothing to read'; T 'verdict' 'TERMINAL'; return }

# ---- the three latch operations, mirroring QgaGoingDownSet/Held/Release ---------------------------
# C# rather than PowerShell marshalling because OBJECT_ATTRIBUTES carries a POINTER to a
# UNICODE_STRING and a security-descriptor pointer, and $null marshals as "" rather than NULL on
# this side. The struct names and shape are the ones the product header and
# mgmt/prime-jobs/ours-noidd/setup/provision-etwproxy-account.ps1:132 already use for the LSA calls;
# the flags, the access mask and the name are parameters, so nothing about the object's identity is
# decided in this file.
Add-Type -Namespace Q -Name Latch -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)]
    struct QGA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct QGA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
                                   public uint Attributes; public IntPtr SecurityDescriptor;
                                   public IntPtr SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attributes; }

    [DllImport("ntdll.dll")] static extern int NtCreateEvent(out IntPtr h, uint acc, ref QGA_OBJECT_ATTRIBUTES oa, int type, byte state);
    [DllImport("ntdll.dll")] static extern int NtOpenEvent(out IntPtr h, uint acc, ref QGA_OBJECT_ATTRIBUTES oa);
    [DllImport("ntdll.dll")] static extern int NtMakeTemporaryObject(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtClose(IntPtr h);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string s, uint rev, out IntPtr sd, IntPtr size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr proc, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LookupPrivilegeValueW(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TOKEN_PRIVILEGES newState,
                                             uint len, IntPtr prev, IntPtr retLen);

    // 0 on success, else the Win32 error. AdjustTokenPrivileges RETURNS TRUE while assigning
    // nothing (ERROR_NOT_ALL_ASSIGNED, 1300), so GetLastError is read even on a true return: that
    // is the trap that makes a privilege look enabled in a token that never held it.
    public static int EnablePriv(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028u /* ADJUST|QUERY */, out tok))
            return Marshal.GetLastWin32Error();
        try {
            long luid;
            if (!LookupPrivilegeValueW(null, name, out luid)) return Marshal.GetLastWin32Error();
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.Count = 1; tp.Luid = luid; tp.Attributes = 0x00000002u;   // SE_PRIVILEGE_ENABLED
            if (!AdjustTokenPrivileges(tok, false, ref tp, (uint)Marshal.SizeOf(tp), IntPtr.Zero, IntPtr.Zero))
                return Marshal.GetLastWin32Error();
            return Marshal.GetLastWin32Error();
        } finally { CloseHandle(tok); }
    }

    static QGA_OBJECT_ATTRIBUTES Attrs(string ntName, uint attributes, IntPtr sd,
                                       out IntPtr usp, out IntPtr strp) {
        strp = Marshal.StringToHGlobalUni(ntName);
        QGA_UNICODE_STRING us = new QGA_UNICODE_STRING();
        us.Length = (ushort)(ntName.Length * 2);
        us.MaximumLength = (ushort)(us.Length + 2);
        us.Buffer = strp;
        usp = Marshal.AllocHGlobal(Marshal.SizeOf(us));
        Marshal.StructureToPtr(us, usp, false);
        QGA_OBJECT_ATTRIBUTES oa = new QGA_OBJECT_ATTRIBUTES();
        oa.Length = Marshal.SizeOf(typeof(QGA_OBJECT_ATTRIBUTES));
        oa.ObjectName = usp;
        oa.Attributes = attributes;
        oa.SecurityDescriptor = sd;
        return oa;
    }

    // NTSTATUS of NtCreateEvent. NotificationEvent (type 0), initial state SIGNALLED, exactly as
    // QgaGoingDownSet creates it, and the handle is closed AT ONCE: OBJ_PERMANENT means the object
    // needs no holder, and keeping one would tie the fact's lifetime back to this process - the one
    // thing the latch exists to avoid.
    public static int Publish(string ntName, string sddl, uint access, uint permanentFlag) {
        IntPtr sd;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1u, out sd, IntPtr.Zero))
            return unchecked((int)0xC0000001);   // STATUS_UNSUCCESSFUL: no SD, so nothing was created
        IntPtr usp = IntPtr.Zero, strp = IntPtr.Zero, h = IntPtr.Zero;
        try {
            QGA_OBJECT_ATTRIBUTES oa = Attrs(ntName, permanentFlag | 0x40u /* OBJ_CASE_INSENSITIVE */,
                                             sd, out usp, out strp);
            int st = NtCreateEvent(out h, access, ref oa, 0, 1);
            if (st == 0) NtClose(h);
            return st;
        } finally { LocalFree(sd); Marshal.FreeHGlobal(usp); Marshal.FreeHGlobal(strp); }
    }

    // NTSTATUS of NtOpenEvent: 0 the name exists, 0xC0000034 it does not. The RAW status is
    // returned rather than QgaGoingDownHeld's 1/0/-1, because a cell must be able to tell "not
    // there" from "cannot read it" - those mean opposite things for the guard under test.
    public static int Open(string ntName, uint access) {
        IntPtr usp = IntPtr.Zero, strp = IntPtr.Zero, h = IntPtr.Zero;
        try {
            QGA_OBJECT_ATTRIBUTES oa = Attrs(ntName, 0x40u, IntPtr.Zero, out usp, out strp);
            int st = NtOpenEvent(out h, access, ref oa);
            if (st == 0) NtClose(h);
            return st;
        } finally { Marshal.FreeHGlobal(usp); Marshal.FreeHGlobal(strp); }
    }

    // NtMakeTemporaryObject plus the last close removes the name again. Returns the OPEN status
    // when the open failed, else the NTSTATUS of NtMakeTemporaryObject.
    public static int Release(string ntName, uint access) {
        IntPtr usp = IntPtr.Zero, strp = IntPtr.Zero, h = IntPtr.Zero;
        try {
            QGA_OBJECT_ATTRIBUTES oa = Attrs(ntName, 0x40u, IntPtr.Zero, out usp, out strp);
            int st = NtOpenEvent(out h, access, ref oa);
            if (st != 0) return st;
            int mt = NtMakeTemporaryObject(h);
            NtClose(h);
            return mt;
        } finally { Marshal.FreeHGlobal(usp); Marshal.FreeHGlobal(strp); }
    }
'@

$sess = [Q.Latch]::WTSGetActiveConsoleSessionId()
$ntName = $NtNameFmt -f $sess
if (-not $PublishOnly) { T 'session' $sess; T 'ntname' $ntName }
if ($sess -eq [uint32]::MaxValue) {
    T 'terminal' 'no active console session - the guard has nothing to refuse'
    T 'verdict' 'TERMINAL'
    return
}

function Priv-Enable {
    # SeCreatePermanentPrivilege is HELD by SYSTEM but disabled in the token until it is asked for,
    # which is why the ADR's measurement records it as "Enabled" rather than assuming it.
    $rc = [Q.Latch]::EnablePriv('SeCreatePermanentPrivilege')
    T 'priv_rc' $rc
    return ($rc -eq 0)
}

# ---- the child's whole job: publish, say what happened, exit -----------------------------------
if ($PublishOnly) {
    if (-not (Priv-Enable)) { T 'publish_status' 'PRIV'; return }
    T 'session' $sess
    T 'publish_status' (Hex ([Q.Latch]::Publish($ntName, $Sddl, $Access, $PermanentFlag)))
    T 'pid' $PID
    return
}

function Latch-Create {
    # The publisher is a SEPARATE PROCESS THAT EXITS, because ADR 2b's case is a session going down
    # "witnessed only by a process that is already gone": a latch still held open by a running
    # publisher would not test that. A child of a SYSTEM process is SYSTEM and enables its own
    # privilege. -Wait, so the publisher is gone before the stimulus is applied.
    # NOT $args: that is an automatic variable, and assigning to it inside a function is the kind of
    # shadowing that reads as working code until something else in the scope needs it.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
           '-Out', $Out, '-NtNameFmt', $NtNameFmt, '-Sddl', $Sddl,
           '-Access', $Access, '-PermanentFlag', $PermanentFlag, '-PublishOnly')
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
    T 'publisher_pid' $p.Id
    T 'publisher_exit' $p.ExitCode
    T 'publisher_running' $(if (Get-Process -Id $p.Id -EA SilentlyContinue) { 'YES' } else { 'NO' })
}

function Wd-Lines([hashtable]$mark) {
    # THE WATCHDOG'S OWN LOG, BY BYTE DELTA, never by timestamp parsing and never by mtime. Called
    # with @{} it returns the current marks and all of the text; called with an earlier mark it
    # returns only what was appended since. The per-day live file accumulates across every cell in
    # the routine, so an absolute grep cannot answer "what did THIS stimulus produce" - the same
    # defect measured on 2026-10-24, where one correct report read as 2. Opened with ReadWrite
    # sharing because the service holds the file open and writes to it throughout.
    $marks = @{}
    $sb = New-Object System.Text.StringBuilder
    # '*watchdog*.log', not 'gui-watchdog-*.log': tools/log-sweep.py:279 classifies the family with
    # TWO alternatives (`^gui-watchdog-.*\.log$|watchdog.*\.log$`), so the narrow filter would read
    # an empty delta - no adopt line, no stuck line - on a guest whose file carries the other shape,
    # and an empty delta is exactly what a PASS looks like in the control arm.
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter '*watchdog*.log' -EA SilentlyContinue) {
        $len = $f.Length
        $marks[$f.FullName] = $len
        $from = 0
        if ($mark -and $mark.ContainsKey($f.FullName)) { $from = [int64]$mark[$f.FullName] }
        if ($len -le $from) { continue }
        try {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                [void]$fs.Seek($from, 'Begin')
                $buf = New-Object byte[] ($len - $from)
                $got = $fs.Read($buf, 0, $buf.Length)
                [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $got))
            } finally { $fs.Close() }
        } catch { }
    }
    return [pscustomobject]@{ mark = $marks; text = $sb.ToString() }
}

function Agent-Pid {
    # BY LITERAL PID FROM THE AGENT'S OWN LOG, never by image name - L8's and L11's discipline, for
    # the same reason: a name matches whatever happens to be running. The birth line is the agent
    # saying which pid it is, and the process is verified to exist and to be gui-agent before
    # anything is ended.
    $last = $null
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue |
                   Sort-Object LastWriteTimeUtc) {
        foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue),
                                         'QWTBIRTH module=gui-agent ver=[0-9.]+ pid=(\d+)'))) {
            $last = [int]$m.Groups[1].Value
        }
    }
    if (-not $last) { return $null }
    $p = Get-Process -Id $last -EA SilentlyContinue
    if (-not $p) { return $null }
    if ($p.ProcessName -ne 'gui-agent') { return $null }
    return $p
}

# ---- leg 1: the instrument must be able to read NOT HELD ----------------------------------------
$pre = [Q.Latch]::Open($ntName, $Access)
T 'pre_open' (Hex $pre)
if ($pre -eq 0) {
    T 'terminal' 'the latch is ALREADY published before this cell did anything - a dirty subject, and no refusal could be attributed to this cell'
    T 'verdict' 'TERMINAL'
    return
}

# ---- leg 2: publish it, from a process that then exits ------------------------------------------
if (-not $Control) {
    Latch-Create
    $held = [Q.Latch]::Open($ntName, $Access)
    T 'held_after_publish' (Hex $held)
    if ($held -ne 0) {
        T 'terminal' 'the name does not open after the publisher exited - either the create failed (see pub_publish_status) or the fact did not outlive its creator, and nothing downstream means anything'
        T 'verdict' 'TERMINAL'
        return
    }
}

# ---- leg 3: make the service WANT to launch -----------------------------------------------------
$wd0 = Wd-Lines @{}
$p = Agent-Pid
if (-not $p) {
    T 'terminal' 'no live gui-agent.exe whose pid the log reports - the stimulus cannot be applied'
    T 'verdict' 'TERMINAL'
    return
}
T 'agent_pid_before' $p.Id
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $p.Kill(); T 'killed' (Get-Date -Format 'HH:mm:ss.fff') }
catch { T 'error' ("could not end the agent: " + $_.Exception.Message); T 'verdict' 'TERMINAL'; return }

# THREE EXITS, each named: the guard spoke / an agent came back (the REFUTED hypothesis in the
# injected arm and the expected one in the control) / the deadline. The poll is 1 s because the
# release has to land inside -WindowSec of the adopt, and the guard adopts on the pass that wants
# to launch.
$why = ''; $adoptMs = -1; $text = ''
$d = (Get-Date).AddSeconds($DeadlineSec)
while ($true) {
    Start-Sleep -Milliseconds 1000
    $text = (Wd-Lines $wd0.mark).text
    if ($text -match 'QGAWDGOINGDOWN console session') {
        $adoptMs = $sw.ElapsedMilliseconds; $why = 'the guard adopted the latch'; break
    }
    $back = Agent-Pid
    if ($back -and $back.Id -ne $p.Id) { $why = "an agent was launched (pid $($back.Id))"; break }
    if ((Get-Date) -gt $d) { $why = "the deadline ($DeadlineSec s) expired"; break }
}
T 'wait_exit' $why
T 'adopt_ms' $adoptMs
T 'adopt_lines'    @([regex]::Matches($text, 'QGAWDGOINGDOWN console session')).Count
T 'nolaunch_lines' @([regex]::Matches($text, 'QGAWDNOLAUNCH')).Count
$during = Agent-Pid
T 'agent_pid_during' $(if ($during) { $during.Id } else { 'NONE' })

# ---- leg 4: release it OURSELVES, inside the window ---------------------------------------------
# Past -WindowSec the watchdog releases the latch and launches by itself (QGAWDSESSIONSTUCK), and a
# launch after that is the recovery's and not the release's. The elapsed time is recorded so the
# harness can refuse the cell rather than read an unattributable launch as a pass.
if (-not $Control) {
    T 'release_at_ms' $sw.ElapsedMilliseconds
    T 'window_ms' ($WindowSec * 1000)
    T 'release_status' (Hex ([Q.Latch]::Release($ntName, $Access)))
    T 'held_after_release' (Hex ([Q.Latch]::Open($ntName, $Access)))
}

# ---- leg 5: the GUI must come back --------------------------------------------------------------
$d2 = (Get-Date).AddSeconds($DeadlineSec)
$why2 = ''
while ($true) {
    $back = Agent-Pid
    if ($back -and $back.Id -ne $p.Id) { $why2 = "an agent is running again (pid $($back.Id))"; break }
    if ((Get-Date) -gt $d2) { $why2 = "the deadline ($DeadlineSec s) expired with no agent"; break }
    Start-Sleep -Seconds 2
}
T 'relaunch_exit' $why2
T 'relaunch_ms' $sw.ElapsedMilliseconds
$after = Agent-Pid
T 'agent_pid_after' $(if ($after) { $after.Id } else { 'NONE' })
$wdEnd = Wd-Lines $wd0.mark
T 'stuck_lines'     @([regex]::Matches($wdEnd.text, 'QGAWDSESSIONSTUCK')).Count
T 'withdrawn_lines' @([regex]::Matches($wdEnd.text, 'withdrawn with it')).Count
T 'latch_at_end' (Hex ([Q.Latch]::Open($ntName, $Access)))
T 'done' (Get-Date).ToUniversalTime().ToString('s')
