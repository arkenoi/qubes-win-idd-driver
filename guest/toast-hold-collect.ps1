# toast-hold-collect.ps1 - the toast-hold harness's GUEST-SIDE INSTRUMENT (mgmt/harness/toast-hold-test.sh).
#
# Runs as SYSTEM over qubes.VMShell:
#   tools/qtest run powershell -NoProfile -ExecutionPolicy Bypass -File "<QubesIncoming>\toast-hold-collect.ps1" -Mode <m> ...
# SYSTEM reads the gui-agent log (registry LogDir, normally Q:\Qubes Logs - memory gui-agent-log-location) and the
# toast bridge's log (bridge.log, in that same LogDir since 7e349bac), and - because qrexec lands in the INTERACTIVE
# session on WinSta0 (guest/run-as-user.ps1 header, measured 2026-08-30) - can ask user32 whether the shell's banner
# window is visible right now.
#
# EVERY line the harness reads starts with 'THC ' - a marker that never appears on the command line qtest echoes back
# (the a0-lib self-match lesson: cmd's echo of the command line reproduces any marker passed as an argument). Regex
# patterns and hwnd lists arrive BASE64-encoded (-PatternB64, -HwndsB64) so no metacharacter ever meets cmd.exe.
#
# Modes:
#   where      THC where=<dir of this script> | THC logdir=<LogDir> agentlog=<newest gui-agent-*.log> agentlines=<n>
#              | THC bridgelog=<path> exists=<0|1> bridgelines=<n> | THC now=<local yyyy-MM-dd HH:mm:ss.fff> tz=<utc offset>
#   count      THC count agentlog=<name> agentlines=<n> bridgelines=<n> now=<...>
#   agentgrep  THC L|<line> for every line of the named agent log past -Skip that matches the decoded pattern;
#              THC END n=<matches> scanned=<lines read>
#   bridgegrep the same over bridge.log past -BridgeSkip
#   bannervis  THC bannervis known=<k> visible=<v> list=<hwnd:iswindow:visible:w:h;...> now=<...>
#              hwnds from -HwndsB64 (comma-separated hex), else every CoreWindow hwnd the agent's own QGAHELDDEFER /
#              QGATOASTHOLD lines name in the named agent log. The shell's banner window lives in a z-band EnumWindows
#              does not reach (measured 2026-10-04), but a handle the agent logged can be asked directly.
#   sync       THE CLOCK PROBE: starts charmap.exe (a classic Win32 window), finds its top-level window by PID, prints
#              THC sync t_start=<ts> t_seen=<ts> hwnd=0x<hex> pid=<pid>, waits 1.5 s, closes it BY PID and prints
#              THC sync t_close=<ts> t_closed=<ts>. The agent's QGAPROTO CREATE line for that hwnd ties the agent log's
#              clock to the guest's local clock (the bridge logs GetLocalTime) and proves ProtoTrace is on.
#   pull       the named agent log (lines matching the grader's token set; the first -Keep lines kept whole) and
#              bridge.log past -BridgeSkip, each as
#                THC PULL name=<n> lines=<count> bytes=<utf8 bytes> sha256=<hex> b64lines=<m>
#                THC B|<76 base64 chars>  (m lines)
#                THC PULLEND name=<n> b64lines=<m>
#              The counts and the hash are what the harness verifies the transfer against (trust counts, not streams).
param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [string]$AgentLog = '',
    [int]$Skip = 0,
    [int]$BridgeSkip = 0,
    [string]$PatternB64 = '',
    [string]$HwndsB64 = '',
    [int]$Keep = 40
)
$ErrorActionPreference = 'Continue'

function Get-ThcNow { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }

function Get-ThcLogDir {
    $r = Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
    if ($r -and $r.LogDir) { return [string]$r.LogDir }
    return 'Q:\Qubes Logs'
}

# bridge.log IS IN THE COMMON LOG DIRECTORY, resolved by the function right above - which was
# already here and simply unused. The hardcoded C:\ProgramData\qubes-toast-bridge\bridge.log this
# replaces named the bridge's STATE directory, which the writer left in 7e349bac, so Test-Path was
# false and the two uses below recorded bridge_exists=0 / bridge_lines=0 on a perfectly healthy
# guest. The assignment is HERE rather than at the top of the file because a PowerShell function is
# not callable until its definition has been executed.
$BridgePath = Join-Path (Get-ThcLogDir) 'bridge.log'

function Get-ThcNewestAgentLog([string]$dir) {
    $f = @(Get-ChildItem -LiteralPath $dir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($f.Count -gt 0) { return [string]$f[0].Name }
    return ''
}

# FileShare.ReadWrite: the agent and the bridge hold their logs open for writing, and a reader that does not share
# write access gets a sharing violation (which Get-Content avoids by sharing ReadWrite - this does the same, faster).
function Read-ThcLines([string]$path) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $path)) { return ,$out }
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        try { while ($null -ne ($l = $sr.ReadLine())) { $out.Add($l) } } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
    return ,$out
}

function Get-ThcDecoded([string]$b64) {
    if ([string]::IsNullOrEmpty($b64)) { return '' }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Resolve-ThcAgentLog {
    $dir = Get-ThcLogDir
    $name = $AgentLog
    if ([string]::IsNullOrEmpty($name)) { $name = Get-ThcNewestAgentLog $dir }
    if ([string]::IsNullOrEmpty($name)) { return @{ dir = $dir; name = ''; path = '' } }
    return @{ dir = $dir; name = $name; path = (Join-Path $dir $name) }
}

function Write-ThcGrep([string]$path, [int]$skipN, [string]$pattern) {
    $lines = Read-ThcLines $path
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern)
    $n = 0; $scanned = 0
    for ($i = $skipN; $i -lt $lines.Count; $i++) {
        $scanned++
        if ($rx.IsMatch($lines[$i])) { $n++; Write-Output ('THC L|' + $lines[$i]) }
    }
    Write-Output "THC END n=$n scanned=$scanned total=$($lines.Count)"
}

function Write-ThcBlock([string]$name, $lines) {
    $arr = @($lines)
    $text = [string]::Join("`n", $arr)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    $b64 = [Convert]::ToBase64String($bytes)
    $m = [int][math]::Ceiling($b64.Length / 76.0)
    Write-Output "THC PULL name=$name lines=$($arr.Count) bytes=$($bytes.Length) sha256=$sha b64lines=$m"
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        Write-Output ('THC B|' + $b64.Substring($i, [math]::Min(76, $b64.Length - $i)))
    }
    Write-Output "THC PULLEND name=$name b64lines=$m"
}

$ThcWinSrc = @'
using System;
using System.Runtime.InteropServices;
public static class ThcWin {
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    public static IntPtr FindTopForPid(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static string Describe(long hwnd) {
        IntPtr h = new IntPtr(hwnd);
        bool isw = IsWindow(h);
        bool vis = isw && IsWindowVisible(h);
        int w = 0, ht = 0;
        RECT r;
        if (isw && GetWindowRect(h, out r)) { w = r.R - r.L; ht = r.B - r.T; }
        return string.Format("0x{0:x}:{1}:{2}:{3}:{4}", hwnd, isw ? 1 : 0, vis ? 1 : 0, w, ht);
    }
}
'@
function Add-ThcWin {
    if (-not ('ThcWin' -as [type])) { Add-Type -TypeDefinition $ThcWinSrc -Language CSharp }
}

switch ($Mode) {
    'where' {
        # ALWAYS the newest log, whatever -AgentLog says: the harness calls this at the start (to pick the boot's
        # log) and at the end (to see whether a NEWER one appeared - an agent restart mid-run breaks coverage).
        $dir = Get-ThcLogDir
        $nm = Get-ThcNewestAgentLog $dir
        $a = @{ dir = $dir; name = $nm; path = $(if ($nm) { Join-Path $dir $nm } else { '' }) }
        $al = if ($a.path) { (Read-ThcLines $a.path).Count } else { 0 }
        $bx = if (Test-Path -LiteralPath $BridgePath) { 1 } else { 0 }
        $bl = if ($bx -eq 1) { (Read-ThcLines $BridgePath).Count } else { 0 }
        Write-Output "THC where=$PSScriptRoot"
        Write-Output "THC logdir=$($a.dir) agentlog=$($a.name) agentlines=$al"
        Write-Output "THC bridgelog=$BridgePath exists=$bx bridgelines=$bl"
        Write-Output "THC now=$(Get-ThcNow) tz=$([TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).ToString())"
        Write-Output "THC user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"
    }
    'count' {
        $a = Resolve-ThcAgentLog
        $al = if ($a.path) { (Read-ThcLines $a.path).Count } else { 0 }
        $bl = (Read-ThcLines $BridgePath).Count
        Write-Output "THC count agentlog=$($a.name) agentlines=$al bridgelines=$bl now=$(Get-ThcNow)"
    }
    'agentgrep' {
        $a = Resolve-ThcAgentLog
        if (-not $a.path) { Write-Output 'THC END n=0 scanned=0 total=0 error=no_agent_log'; break }
        Write-ThcGrep $a.path $Skip (Get-ThcDecoded $PatternB64)
    }
    'bridgegrep' {
        if (-not (Test-Path -LiteralPath $BridgePath)) { Write-Output 'THC END n=0 scanned=0 total=0 error=no_bridge_log'; break }
        Write-ThcGrep $BridgePath $BridgeSkip (Get-ThcDecoded $PatternB64)
    }
    'bannervis' {
        Add-ThcWin
        $hw = New-Object 'System.Collections.Generic.List[string]'
        $given = Get-ThcDecoded $HwndsB64
        if ($given) {
            foreach ($h in ($given -split ',')) { if ($h) { $hw.Add($h.Trim().ToLower()) } }
        } else {
            $a = Resolve-ThcAgentLog
            if ($a.path) {
                $rx = New-Object System.Text.RegularExpressions.Regex('(?:QGAHELDDEFER hwnd=0x([0-9a-fA-F]+) class=Windows\.UI\.Core\.CoreWindow|QGATOASTHOLD(?:LATE)? hwnd=0x([0-9a-fA-F]+))')
                foreach ($l in (Read-ThcLines $a.path)) {
                    $m = $rx.Match($l)
                    if ($m.Success) {
                        $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                        $v = $v.ToLower()
                        if ($hw.Contains($v)) { [void]$hw.Remove($v) }
                        $hw.Add($v)
                    }
                }
            }
        }
        while ($hw.Count -gt 6) { $hw.RemoveAt(0) }   # the most recent six handles
        $parts = New-Object 'System.Collections.Generic.List[string]'
        $visible = 0
        foreach ($h in $hw) {
            $d = [ThcWin]::Describe([Convert]::ToInt64($h, 16))
            $parts.Add($d)
            $f = $d -split ':'
            if ($f[1] -eq '1' -and $f[2] -eq '1' -and [int]$f[3] -gt 0 -and [int]$f[4] -gt 0) { $visible++ }
        }
        Write-Output "THC bannervis known=$($hw.Count) visible=$visible list=$([string]::Join(';', $parts.ToArray())) now=$(Get-ThcNow)"
    }
    'sync' {
        Add-ThcWin
        $tStart = Get-ThcNow
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\charmap.exe') -PassThru
        $h = [IntPtr]::Zero
        for ($i = 0; $i -lt 60 -and $h -eq [IntPtr]::Zero; $i++) {
            Start-Sleep -Milliseconds 100
            $h = [ThcWin]::FindTopForPid([uint32]$p.Id)
        }
        if ($h -ne [IntPtr]::Zero) {
            $tSeen = Get-ThcNow
            Write-Output ("THC sync t_start=$tStart t_seen=$tSeen hwnd=0x{0:x} pid=$($p.Id)" -f $h.ToInt64())
        } else {
            Write-Output "THC sync error=no_window pid=$($p.Id) t_start=$tStart"
        }
        Start-Sleep -Milliseconds 1500
        $tClose = Get-ThcNow
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue   # by PID: it is the process this probe started
        Start-Sleep -Milliseconds 700
        Write-Output "THC sync t_close=$tClose t_closed=$(Get-ThcNow)"
    }
    'pull' {
        Write-Output "THC now=$(Get-ThcNow)"
        $a = Resolve-ThcAgentLog
        $filter = New-Object System.Text.RegularExpressions.Regex('QGATOAST|QGAHELD|QGAPROTO,msg=(CREATE|MAP|DESTROY)|Unmapping window|toast card in|no card measured|Seamless mode chang|QGATWEAKS|QGANOTIF|QGASLICEMAP|QGACROPLATE|QGADIRECT|QGASTARTDISMISS|QGAFAULT|gui-agent|version|QGAFSFLASH|RESREQ|New resolution|msg=CONFIGURE,hwnd=0x0,')
        $kept = New-Object 'System.Collections.Generic.List[string]'
        $total = 0
        if ($a.path) {
            $all = Read-ThcLines $a.path
            $total = $all.Count
            for ($i = 0; $i -lt $all.Count; $i++) {
                if ($i -lt $Keep -or $filter.IsMatch($all[$i])) { $kept.Add($all[$i]) }
            }
        }
        Write-Output "THC agentlog=$($a.name) agentlines=$total kept=$($kept.Count)"
        Write-ThcBlock 'agent' $kept
        $b = Read-ThcLines $BridgePath
        $bs = New-Object 'System.Collections.Generic.List[string]'
        for ($i = $BridgeSkip; $i -lt $b.Count; $i++) { $bs.Add($b[$i]) }
        Write-Output "THC bridgelines=$($b.Count) skipped=$BridgeSkip"
        Write-ThcBlock 'bridge' $bs
    }
    default {
        Write-Output "THC error=unknown_mode mode=$Mode"
        exit 1
    }
}
