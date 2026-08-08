<#
    bench-probe.ps1 - guest-side measurement primitive for scratchpad/benchmark.sh.

    Deliberately SIDE-AGNOSTIC: every mode here works on a STOCK QWT 4.2.2 gui-agent
    exactly as it works on ours. Nothing in this file reads QGAPERF or any other field
    our instrumentation adds - that is done host-side, from the agent log, and only for
    builds that emit it. This is the only reason a stock-vs-ours comparison is possible
    at all: stock has no instrumentation, so the cross-side metrics must come from
    process accounting (CPU/working set) and from dom0-observed pixels, not from logs.

    Modes:
      -Mode info                        one-shot facts: pid, binary hash, version, uptime,
                                        watchdog state, newest log, QGAPERF-recent count
                                        (the discriminator that proves which build runs)
      -Mode reset                       deterministic scene: kill notepad/chromerepro
      -Mode idle    -Seconds 60         blocking idle sample -> IDLE summary line
      -Mode trace   -Seconds N -Out P   blocking 4 Hz sampler -> SAMP lines into file P
                                        (run it from a SECOND qrexec connection, in
                                        parallel with the workload; keep the connection
                                        open for the whole duration - do NOT -Detach
                                        unless you have proven detached children survive
                                        the qrexec session ending)
      -Mode collect -Out P              print file P back, one TRACE line per sample

    All output is key=value ASCII on stdout, prefixed by mode. The dev qube parses it as
    DATA (CLAUDE.md hard rule: nothing from this VM is executed there).
#>
param(
    [ValidateSet('info','reset','idle','trace','collect')]
    [string]$Mode = 'info',
    [double]$Seconds = 60,
    [int]$IntervalMs = 250,
    [string]$Out = 'C:\qbench\trace.txt',
    [switch]$Detach
)

$ErrorActionPreference = 'Continue'
$binPath = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
# Read the CONFIGURED LogDir, do not assume one. LogDir moved to Q:\Qubes Logs when
# MoveUsers landed (2026-08-07), and this hardcoded path then found no agent log at all, so
# qgaperf_recent came back 0 and benchmark.sh aborted EVERY ours-side rep with
# "instrumented build not running" - on a guest whose instrumentation was working perfectly.
# Three reps were thrown away before the cause was found.
$logDir = $null
try {
    $cfg = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name 'LogDir' -ErrorAction Stop).LogDir
    if ($cfg -and (Test-Path $cfg)) { $logDir = $cfg }
} catch { }
if (-not $logDir) {
    foreach ($cand in @('Q:\Qubes Logs', 'C:\Program Files\Qubes Tools\log')) {
        if (Test-Path $cand) { $logDir = $cand; break }
    }
}
if (-not $logDir) { $logDir = 'C:\Program Files\Qubes Tools\log' }

function Stamp { (Get-Date).ToString('yyyyMMdd.HHmmss.fff') }
function AgentProc { Get-Process gui-agent -ErrorAction SilentlyContinue | Select-Object -First 1 }

# ------------------------------------------------------------------- info ----
if ($Mode -eq 'info') {
    $p = AgentProc
    Write-Output ("INFO stamp=" + (Stamp))
    Write-Output ("INFO agent_running=" + [bool]$p)
    if ($p) {
        Write-Output ("INFO agent_pid=" + $p.Id)
        try {
            $up = ((Get-Date) - $p.StartTime).TotalSeconds
            Write-Output ("INFO agent_uptime_s=" + [int]$up)
        } catch { Write-Output "INFO agent_uptime_s=NA" }
        Write-Output ("INFO agent_cpu_ms=" + [int]$p.TotalProcessorTime.TotalMilliseconds)
        Write-Output ("INFO agent_ws_bytes=" + $p.WorkingSet64)
        Write-Output ("INFO agent_handles=" + $p.HandleCount)
        Write-Output ("INFO agent_threads=" + $p.Threads.Count)
    }
    if (Test-Path $binPath) {
        $f = Get-Item $binPath
        Write-Output ("INFO agent_hash=" + (Get-FileHash $binPath).Hash.Substring(0,16))
        Write-Output ("INFO agent_size=" + $f.Length)
        Write-Output ("INFO agent_ver=" + $f.VersionInfo.FileVersion)
        Write-Output ("INFO agent_mtime=" + $f.LastWriteTimeUtc.ToString('yyyyMMdd.HHmmss'))
        Write-Output ("INFO agent_orig_present=" + (Test-Path ($binPath + '.orig')))
    } else {
        Write-Output "INFO agent_hash=NA"
    }
    $svc = Get-Service QubesGuiWatchdog -ErrorAction SilentlyContinue
    Write-Output ("INFO watchdog=" + $(if ($svc) { $svc.Status.ToString() } else { 'absent' }))

    $log = Get-ChildItem $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        Write-Output ("INFO logdir=" + $logDir)
        Write-Output ("INFO log=" + $log.Name)
        Write-Output ("INFO log_bytes=" + $log.Length)
        # The build discriminator. A stock 4.2.2 agent emits NO QGAPERF at all; ours emits
        # one record per frame. benchmark.sh hard-fails when this contradicts the side label,
        # so a mislabelled run cannot silently produce a "comparison".
        $tail = Get-Content $log.FullName -Tail 400 -ErrorAction SilentlyContinue
        $qg = @($tail | Where-Object { $_ -match 'QGAPERF,' })
        Write-Output ("INFO qgaperf_recent=" + $qg.Count)
        if ($qg.Count -gt 0 -and $qg[-1] -match ',mode=([sf]),') {
            Write-Output ("INFO mode_last=" + $Matches[1])
        }
    } else {
        Write-Output "INFO log=NA"
        Write-Output "INFO qgaperf_recent=0"
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    try {
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        Write-Output ("INFO screen=" + $b.Width + "x" + $b.Height)
    } catch { Write-Output "INFO screen=NA" }
    Write-Output ("INFO session=" + [System.Diagnostics.Process]::GetCurrentProcess().SessionId)
    Write-Output ("INFO os_boot=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('yyyyMMdd.HHmmss'))
    Write-Output "INFO ok=True"
    exit 0
}

# ------------------------------------------------------------------ reset ----
if ($Mode -eq 'reset') {
    # Deterministic scene. drag-harness.ps1 does this too, but the idle measurement runs
    # BEFORE the harness, and a leftover window repainting on its own would be charged to
    # "idle gui-agent CPU" (exactly the confounder that made an earlier drag benchmark
    # span 3657-7143 us on one unchanged binary).
    Get-Process notepad, chromerepro, iddtest -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = @(Get-Process notepad, chromerepro -ErrorAction SilentlyContinue).Count
    Write-Output ("RESET killed_left=" + $left + " stamp=" + (Stamp))
    Write-Output ("RESET ok=" + ($left -eq 0))
    exit 0
}

# ---------------------------------------------------------------- collect ----
if ($Mode -eq 'collect') {
    if (-not (Test-Path $Out)) { Write-Output "TRACE-ERROR missing=$Out"; exit 1 }
    Write-Output "===TRACESTART==="
    Get-Content $Out
    Write-Output "===TRACEEND==="
    exit 0
}

# ------------------------------------------------------- idle / trace core ---
$dir = Split-Path $Out -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

if ($Detach) {
    # Fallback path only. Prefer keeping the qrexec connection open for the sampler's
    # lifetime: whether a detached child survives the qrexec service session ending has
    # NOT been proven here, and benchmark.sh treats short sample coverage as a failed
    # metric rather than silently reporting a partial window.
    $self = $MyInvocation.MyCommand.Path
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$self`"",
        '-Mode',$Mode,'-Seconds',$Seconds,'-IntervalMs',$IntervalMs,'-Out',"`"$Out`"") | Out-Null
    Write-Output ("TRACE detached=True out=" + $Out + " seconds=" + $Seconds + " stamp=" + (Stamp))
    exit 0
}

$sw = New-Object System.Diagnostics.Stopwatch
$writer = New-Object System.IO.StreamWriter($Out, $false)
$writer.AutoFlush = $true     # a killed sampler must still leave the samples it took
$first = $null; $last = $null; $pids = @{}
$n = 0
$sw.Start()
try {
    $writer.WriteLine("HEAD mode=$Mode seconds=$Seconds interval_ms=$IntervalMs start=" + (Stamp))
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        $p = AgentProc
        $ts = Stamp
        if ($p) {
            $cpu = [int]$p.TotalProcessorTime.TotalMilliseconds
            $writer.WriteLine("SAMP $ts cpu_ms=$cpu ws=$($p.WorkingSet64) handles=$($p.HandleCount) pid=$($p.Id)")
            if ($null -eq $first) { $first = @{ t = $sw.Elapsed.TotalMilliseconds; cpu = $cpu } }
            $last = @{ t = $sw.Elapsed.TotalMilliseconds; cpu = $cpu }
            $pids[$p.Id] = 1
        } else {
            # Missing data must be visible, never interpolated.
            $writer.WriteLine("SAMP $ts agent=absent")
        }
        $n++
        $target = $n * $IntervalMs
        $left = $target - $sw.Elapsed.TotalMilliseconds
        if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
    }
} finally {
    $writer.WriteLine("TAIL samples=$n end=" + (Stamp))
    $writer.Close()
}

if ($Mode -eq 'idle') {
    if ($null -eq $first -or $null -eq $last -or $last.t -le $first.t) {
        Write-Output "IDLE ok=False reason=no_samples"
        exit 1
    }
    $wall = $last.t - $first.t
    $cpu  = $last.cpu - $first.cpu
    Write-Output ("IDLE ok=True samples=$n wall_ms=" + [int]$wall + " cpu_ms=" + $cpu +
                  " cpu_pct=" + [math]::Round(100.0 * $cpu / $wall, 3) +
                  " pid_count=" + $pids.Count + " out=" + $Out + " stamp=" + (Stamp))
} else {
    Write-Output ("TRACE ok=True samples=$n out=" + $Out + " stamp=" + (Stamp))
}
