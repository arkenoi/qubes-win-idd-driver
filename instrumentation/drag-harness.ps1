<#
    Phase 1A.4 measurement harness for the Qubes Windows gui-agent.

    Drives synthetic, repeatable input at the guest desktop so the QGAPERF records
    emitted by the instrumented gui-agent (see phase1a-timing.patch) can be sliced
    per workload:

        idle    -> baseline: what the agent costs when nothing moves
        drag    -> Notepad dragged in circles by the title bar (the #1861 workload)
        scroll  -> mouse wheel over a large text buffer
        type    -> steady keystroke cadence into Notepad (typing latency)

    Run it with:  tools/qtest pushrun instrumentation/drag-harness.ps1
    qubes.VMShell lands in the interactive console session (session 1, verified),
    so SendInput reaches the input desktop -- the script proves that before
    trusting any number, and aborts loudly if it doesn't.

    All input loops live in C#, not PowerShell: at 60 Hz the per-iteration cost of
    PowerShell object churn is comparable to what we are trying to measure in the
    agent. The C# loops also report their achieved cadence and jitter, so the
    harness is measured rather than assumed.

    Phase boundaries are printed as wall-clock stamps in the exact format the agent
    log uses ([yyyyMMdd.HHmmss.fff-tid-L]), so slicing the agent log per phase is a
    string comparison (see analyze-perf.py --markers).

    Emits a '=== RESULT ===' JSON block last, per guest/deploy-and-test.ps1 convention.
#>
param(
    [double]$DragSeconds   = 10,
    [double]$ScrollSeconds = 10,
    [double]$TypeSeconds   = 10,
    [double]$IdleSeconds   = 5,
    [int]   $DragHz        = 60,     # synthetic mouse-move rate during the drag
    [int]   $DragRadius    = 200,    # pixels
    [double]$DragPeriod    = 2.0,    # seconds per full circle
    [int]   $ScrollHz      = 20,
    [int]   $TypeHz        = 10,
    [switch]$KeepNotepad
)

$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    ok = $false; phases = @(); notes = @(); cadence = [ordered]@{}
    logdir = 'C:\Program Files\Qubes Tools\log'; markerFile = $null; error = $null
}

function Stamp { (Get-Date).ToString('yyyyMMdd.HHmmss.fff') }
function Note($m) { $script:result.notes += "$m"; Write-Output "# $m" }

# ---------------------------------------------------------------- interop ----
Add-Type -Namespace Q -Name In -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)]
public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)]
public struct INPUT { public uint type; public INPUTUNION u; }
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int left; public int top; public int right; public int bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int x; public int y; }

[DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] p, int cb);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("winmm.dll")]  public static extern uint timeBeginPeriod(uint ms);
[DllImport("winmm.dll")]  public static extern uint timeEndPeriod(uint ms);

const uint MOVE = 0x0001, LDOWN = 0x0002, LUP = 0x0004, WHEEL = 0x0800, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
const uint KEYUP = 0x0002, UNICODE_FLAG = 0x0004;

static int vx, vy, vw, vh;
public static void InitScreen() {
    vx = GetSystemMetrics(76); vy = GetSystemMetrics(77);
    vw = GetSystemMetrics(78); vh = GetSystemMetrics(79);
    if (vw < 2) vw = 2; if (vh < 2) vh = 2;
}

static void Send(INPUT[] a) {
    uint n = SendInput((uint)a.Length, a, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    if (n != a.Length)
        throw new System.Exception("SendInput sent " + n + "/" + a.Length + ", GetLastError=" +
            System.Runtime.InteropServices.Marshal.GetLastWin32Error());
}

public static void MoveTo(int x, int y) {
    INPUT[] a = new INPUT[1];
    a[0].type = 0;
    a[0].u.mi.dx = (int)((long)(x - vx) * 65535 / (vw - 1));
    a[0].u.mi.dy = (int)((long)(y - vy) * 65535 / (vh - 1));
    a[0].u.mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
    Send(a);
}

public static void Button(bool down) {
    INPUT[] a = new INPUT[1];
    a[0].type = 0;
    a[0].u.mi.dwFlags = down ? LDOWN : LUP;
    Send(a);
}

public static void Wheel(int delta) {
    INPUT[] a = new INPUT[1];
    a[0].type = 0;
    a[0].u.mi.mouseData = unchecked((uint)delta);
    a[0].u.mi.dwFlags = WHEEL;
    Send(a);
}

public static void Key(char c) {
    INPUT[] a = new INPUT[2];
    a[0].type = 1; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = UNICODE_FLAG;
    a[1].type = 1; a[1].u.ki.wScan = (ushort)c; a[1].u.ki.dwFlags = UNICODE_FLAG | KEYUP;
    Send(a);
}

// Sleep-then-spin until sw has reached targetMs. timeBeginPeriod(1) is in effect.
static void WaitUntil(System.Diagnostics.Stopwatch sw, double targetMs) {
    for (;;) {
        double left = targetMs - sw.Elapsed.TotalMilliseconds;
        if (left <= 0) return;
        if (left > 3) System.Threading.Thread.Sleep((int)(left - 2));
        else System.Threading.Thread.SpinWait(200);
    }
}

static string Cadence(double[] err, System.Diagnostics.Stopwatch sw, int steps, double wantMs) {
    System.Array.Sort(err);
    double p50 = err.Length > 0 ? err[err.Length / 2] : 0;
    double p95 = err.Length > 0 ? err[(int)(err.Length * 0.95)] : 0;
    double max = err.Length > 0 ? err[err.Length - 1] : 0;
    return "steps=" + steps + " wall_ms=" + (int)sw.Elapsed.TotalMilliseconds +
           " want_ms=" + (int)wantMs + " jitter_ms p50=" + p50.ToString("F2") +
           " p95=" + p95.ToString("F2") + " max=" + max.ToString("F2");
}

// Drag: press at (gx,gy), walk a circle of the given radius, release.
public static string DragCircle(int gx, int gy, int radius, double periodSec, double seconds, int hz) {
    MoveTo(gx, gy);
    System.Threading.Thread.Sleep(200);
    Button(true);
    int steps = (int)(seconds * hz);
    double[] err = new double[steps];
    System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
    try {
        for (int k = 1; k <= steps; k++) {
            double t = (double)k / hz;
            double ang = 2 * System.Math.PI * t / periodSec;
            MoveTo(gx + (int)(radius * (System.Math.Cos(ang) - 1)), gy + (int)(radius * System.Math.Sin(ang)));
            double want = k * 1000.0 / hz;
            err[k - 1] = System.Math.Abs(sw.Elapsed.TotalMilliseconds - want);
            WaitUntil(sw, want);
        }
    } finally { Button(false); }
    return Cadence(err, sw, steps, seconds * 1000);
}

public static string ScrollLoop(int cx, int cy, double seconds, int hz) {
    MoveTo(cx, cy);
    System.Threading.Thread.Sleep(200);
    int steps = (int)(seconds * hz);
    double[] err = new double[steps];
    System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
    for (int k = 1; k <= steps; k++) {
        Wheel((k <= steps / 2 ? -1 : 1) * 120 * 3);
        double want = k * 1000.0 / hz;
        err[k - 1] = System.Math.Abs(sw.Elapsed.TotalMilliseconds - want);
        WaitUntil(sw, want);
    }
    return Cadence(err, sw, steps, seconds * 1000);
}

public static string TypeLoop(string text, double seconds, int hz) {
    int steps = (int)(seconds * hz);
    double[] err = new double[steps];
    System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
    for (int k = 1; k <= steps; k++) {
        Key(text[(k - 1) % text.Length]);
        double want = k * 1000.0 / hz;
        err[k - 1] = System.Math.Abs(sw.Elapsed.TotalMilliseconds - want);
        WaitUntil(sw, want);
    }
    return Cadence(err, sw, steps, seconds * 1000);
}
'@

$phaseList = New-Object System.Collections.ArrayList
function Phase([string]$name, [scriptblock]$body) {
    $start = Stamp
    Write-Output "### PHASE-START $name $start"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & $body
    $sw.Stop()
    $end = Stamp
    if ($out) { Write-Output "#   $name cadence: $out"; $script:result.cadence[$name] = "$out" }
    Write-Output "### PHASE-END   $name $end"
    [void]$phaseList.Add([ordered]@{ name = $name; start = $start; end = $end; ms = [int]$sw.Elapsed.TotalMilliseconds })
}

# --------------------------------------------------------------- preflight ---
$notepad = $null
[void][Q.In]::timeBeginPeriod(1)
try {
    [Q.In]::InitScreen()
    $vx = [Q.In]::GetSystemMetrics(76); $vy = [Q.In]::GetSystemMetrics(77)
    $vw = [Q.In]::GetSystemMetrics(78); $vh = [Q.In]::GetSystemMetrics(79)
    Note "session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId) user=$env:USERNAME interactive=$([Environment]::UserInteractive)"
    Note "virtual screen origin ($vx,$vy) size ${vw}x${vh}"

    # Prove SendInput actually reaches the input desktop before trusting any timing.
    $before = New-Object Q.In+POINT; [void][Q.In]::GetCursorPos([ref]$before)
    $probeX = $vx + [int]($vw / 3); $probeY = $vy + [int]($vh / 3)
    [Q.In]::MoveTo($probeX, $probeY)
    Start-Sleep -Milliseconds 150
    $after = New-Object Q.In+POINT; [void][Q.In]::GetCursorPos([ref]$after)
    if ([Math]::Abs($after.x - $probeX) -gt 4 -or [Math]::Abs($after.y - $probeY) -gt 4) {
        throw "SendInput does not reach the input desktop (cursor ($($after.x),$($after.y)), wanted ($probeX,$probeY)). Wrong session or window station."
    }
    Note "SendInput verified: cursor ($($before.x),$($before.y)) -> ($($after.x),$($after.y))"

    # ----------------------------------------------------- deterministic desktop --
    # The drag cost depends on how much has to be repainted, which depends on what the dragged
    # window passes over. Leaving other windows on screen (the visual scene leaves two Notepads
    # and chromerepro) makes the damage volume a function of run-to-run window placement: three
    # runs of ONE unchanged binary spanned 3657-7143us, wider than any difference between
    # builds, which made the harness useless for comparing them.
    Get-Process notepad, chromerepro -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $others = 0
    $enum = {
        param($h, $l)
        if ([Q.In]::IsWindowVisible($h)) {
            $r2 = New-Object Q.In+RECT
            if ([Q.In]::GetWindowRect($h, [ref]$r2)) {
                if (($r2.right - $r2.left) -gt 200 -and ($r2.bottom - $r2.top) -gt 200) { $script:others++ }
            }
        }
        return $true
    }
    Note "cleared other app windows before measuring"

    # --------------------------------------------------------------- notepad --
    # Open a pre-made file rather than pasting: the clipboard needs an STA thread
    # and qubes.VMShell does not guarantee one.
    $bufFile = Join-Path $env:TEMP 'qgaperf-scrollbuffer.txt'
    (1..400 | ForEach-Object { "line $_ " + ('x' * 60) }) -join "`r`n" | Set-Content -Encoding ASCII $bufFile
    $notepad = Start-Process notepad -ArgumentList "`"$bufFile`"" -PassThru
    [void]$notepad.WaitForInputIdle(10000)
    for ($i = 0; $i -lt 50 -and $notepad.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 100; $notepad.Refresh() }
    $hwnd = $notepad.MainWindowHandle
    if ($hwnd -eq 0) { throw 'Notepad has no main window' }

    $w = 800; $h = 600
    $wx = $vx + [int](($vw - $w) / 2); $wy = $vy + [int](($vh - $h) / 2)
    [void][Q.In]::MoveWindow($hwnd, $wx, $wy, $w, $h, $true)
    [void][Q.In]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 700
    $r = New-Object Q.In+RECT; [void][Q.In]::GetWindowRect($hwnd, [ref]$r)
    Note ("notepad hwnd=0x{0:x} rect=({1},{2})-({3},{4})" -f [int64]$hwnd, $r.left, $r.top, $r.right, $r.bottom)
    $result.hwnd = ('0x{0:x}' -f [int64]$hwnd)

    $grabX   = [int](($r.left + $r.right) / 2)
    $grabY   = $r.top + 15                          # title bar
    $clientX = [int](($r.left + $r.right) / 2)
    $clientY = [int](($r.top + $r.bottom) / 2)

    # ----------------------------------------------------------- the phases --
    Phase 'idle-pre'  { Start-Sleep -Seconds $IdleSeconds; $null }
    # settle before measuring: a repaint still draining into the first drag frames is charged
    # to the drag phase
    Start-Sleep -Seconds 2
    Phase 'drag'      { [Q.In]::DragCircle($grabX, $grabY, $DragRadius, $DragPeriod, $DragSeconds, $DragHz) }
    Phase 'idle-mid1' { Start-Sleep -Seconds 2; $null }
    Phase 'scroll'    { [void][Q.In]::SetForegroundWindow($hwnd); [Q.In]::ScrollLoop($clientX, $clientY, $ScrollSeconds, $ScrollHz) }
    Phase 'idle-mid2' { Start-Sleep -Seconds 2; $null }
    Phase 'type'      { [void][Q.In]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300
                        [Q.In]::TypeLoop('the quick brown fox jumps over the lazy dog 0123456789 ', $TypeSeconds, $TypeHz) }
    Phase 'idle-post' { Start-Sleep -Seconds $IdleSeconds; $null }

    $result.ok = $true
}
catch {
    $result.error = "$($_.Exception.Message)"
    Write-Output "!!! $($_.Exception.Message)"
}
finally {
    [void][Q.In]::timeEndPeriod(1)
    if ($notepad -and -not $KeepNotepad) {
        # the typing phase dirtied the buffer, so just kill it (test VM, disposable)
        try { Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    }
}

$result.phases = @($phaseList)
$markerFile = Join-Path $env:TEMP ('qgaperf-harness-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
try {
    $result.markerFile = $markerFile
    ($result | ConvertTo-Json -Depth 6) | Set-Content -Encoding UTF8 $markerFile
} catch {}

Write-Output '=== RESULT ==='
$result | ConvertTo-Json -Depth 6
