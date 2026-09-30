# rig-silencer.ps1 - TEST RIG ONLY: pause a test guest's background work for the length of a measurement, gate on it,
# restore it. NOT the product's guest/quiet-desktop.ps1 and never shipped (make-setup.ps1 stages named files only): the
# product decides what a user's guest runs; this only makes a disposable test guest measurable (owner, 2026-09-30:
# "production quiet desktop and test rig silencer should not be the same").
#
# WHY (owner, 2026-09-30: "we cannot measure anything reliable while some 'scanning' occurs in the background").
# Measured the same day on a Win11 24H2 test guest: Windows Defender (MsMpEng) burned 37-41% of a core inside two
# 60 s CPU samples and the Update Orchestrator (MoUsoCoreWorker) showed up in another - noise far above what the
# benchmark resolves. Off restores exactly what On changed (recorded in -StateFile). Run as SYSTEM (qubes.VMShell).
# WINDOWS UPDATE IS DELIBERATELY NOT TOUCHED (owner, same day: "updates should be off unconditionally except maybe
# standalonevms"): that is the PRODUCT's job, and silencing it here would hide whether the product does it. The quiet gate
# still sees the Update Orchestrator (MoUsoCoreWorker) if it wakes, and a measurement then waits instead of recording.
#
#   -Mode On     stop background services (recording each one's state and start type), disable scheduled
#                maintenance, cancel a running Defender scan, try to switch Defender real-time protection off
#                (Tamper Protection may refuse - reported as RTP=STILL-ON, never hidden) and add scan exclusions for
#                the measurement's own paths, end known background workers. Prints one line per action.
#   -Mode Check  sample every process for -Seconds; QUIET=1 when no process outside the measurement's own set used
#                more than -MaxPct % of one core; prints the busiest processes either way.
#   -Mode Off    undo On from the state file.
param([ValidateSet('On', 'Off', 'Check')][string]$Mode = 'Check', [int]$Seconds = 15, [double]$MaxPct = 2.0, [double]$MaxTotalPct = 50.0,
      [string]$StateFile = 'C:\ProgramData\Qubes\rig-silencer.json')
$ErrorActionPreference = 'Continue'
$inv = [Globalization.CultureInfo]::InvariantCulture
$services = @('WSearch', 'SysMain', 'DiagTrack', 'dmwappushservice', 'MapsBroker')
$workers = @('CompatTelRunner', 'mscorsvw', 'ngen', 'ngentask', 'SearchProtocolHost', 'SearchFilterHost', 'DeviceCensus',
             'wsqmcons')
$exclusions = @('C:\Users', 'C:\Program Files\Qubes Tools', 'C:\Windows\Temp', 'C:\ProgramData\Qubes')
$maintKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'

if ($Mode -eq 'On') {
    if (Test-Path $StateFile) { Write-Output "REFUSED: $StateFile exists - a previous On was never undone; run -Mode Off first"; exit 2 }
    # RECORD EVERYTHING FIRST, then change: a failure half-way through must still leave Off a complete record.
    $state = @{ services = @{}; maint = $null; rtpWasDisabled = $null; addedExclusions = @() }
    foreach ($n in $services) {
        # ONLY services that are RUNNING are touched: a stopped one needs nothing, and not touching it means there is nothing
        # to restore (measured: rewriting a stopped Manual service's start type cleared a DelayedAutostart flag that the
        # service manager then kept cleared until a reboot).
        $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($w -and $w.State -eq 'Running') { $state.services[$n] = @{ status = "$($w.State)"; start = "$($w.StartMode)"; delayed = [bool]$w.DelayedAutoStart } }
    }
    $state.maint = (Get-ItemProperty -Path $maintKey -Name MaintenanceDisabled -ErrorAction SilentlyContinue).MaintenanceDisabled
    try { $state.rtpWasDisabled = [bool](Get-MpPreference -ErrorAction Stop).DisableRealtimeMonitoring } catch { }
    New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
    $save = { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
    & $save
    foreach ($n in @($state.services.Keys)) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        # Disabled first, so a trigger-started service cannot come straight back mid-measurement.
        try { Set-Service -Name $n -StartupType Disabled -ErrorAction Stop } catch { Write-Output "KEEP-START $n ($($_.Exception.Message.Split([char]10)[0]))" }
        if ($s.Status -eq 'Running') {
            try { Stop-Service -Name $n -Force -ErrorAction Stop; Write-Output "STOPPED $n" }
            catch { Write-Output "REFUSED $n ($($_.Exception.Message.Split([char]10)[0]))" }
        }
    }
    try { New-ItemProperty -Path $maintKey -Name MaintenanceDisabled -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null; Write-Output 'MAINTENANCE disabled' }
    catch { Write-Output "REFUSED maintenance ($($_.Exception.Message))" }
    $mpc = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
    if (Test-Path $mpc) { & $mpc -Scan -Cancel *> $null; Write-Output "DEFENDER scan cancel rc=$LASTEXITCODE" }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        foreach ($p in $exclusions) {
            if ($pref.ExclusionPath -notcontains $p) { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; $state.addedExclusions += $p; & $save }
        }
        $st = Get-MpComputerStatus -ErrorAction Stop
        Write-Output ("DEFENDER RTP=" + $(if ($st.RealTimeProtectionEnabled) { 'STILL-ON' } else { 'OFF' }) + " tamper=" + $st.IsTamperProtected +
                      " exclusions-added=" + $state.addedExclusions.Count)
    } catch { Write-Output "DEFENDER not changed ($($_.Exception.Message.Split([char]10)[0]))" }
    foreach ($w in $workers) {
        foreach ($p in @(Get-Process -Name $w -ErrorAction SilentlyContinue)) {
            try { $p.Kill(); Write-Output "ENDED $w/$($p.Id)" } catch { Write-Output "REFUSED end $w/$($p.Id)" }
        }
    }
    & $save
    Write-Output "STATE saved to $StateFile"
    exit 0
}

if ($Mode -eq 'Off') {
    if (-not (Test-Path $StateFile)) { Write-Output "NOTHING TO UNDO: no $StateFile"; exit 0 }
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    foreach ($prop in $state.services.PSObject.Properties) {
        $n = $prop.Name; $v = $prop.Value
        # sc.exe, not Set-Service: Set-Service cannot express DELAYED automatic start, and restoring "Automatic" would change
        # the guest's boot behaviour.
        $sc = switch ($v.start) { 'Auto' { if ($v.delayed) { 'delayed-auto' } else { 'auto' } } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { 'demand' } }
        & sc.exe config $n start= $sc | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "RESTORE-START-FAILED $n ($sc, rc=$LASTEXITCODE)" }
        if ($v.status -eq 'Running') { try { Start-Service -Name $n -ErrorAction Stop; Write-Output "RESTARTED $n" } catch { Write-Output "RESTART-FAILED $n" } }
    }
    if ($null -eq $state.maint) { Remove-ItemProperty -Path $maintKey -Name MaintenanceDisabled -ErrorAction SilentlyContinue }
    else { New-ItemProperty -Path $maintKey -Name MaintenanceDisabled -Value $state.maint -PropertyType DWord -Force | Out-Null }
    Write-Output 'MAINTENANCE restored'
    try {
        if ($null -ne $state.rtpWasDisabled) { Set-MpPreference -DisableRealtimeMonitoring ([bool]$state.rtpWasDisabled) -ErrorAction Stop }
        foreach ($p in @($state.addedExclusions)) { if ($p) { Remove-MpPreference -ExclusionPath $p -ErrorAction Stop } }
        Write-Output ("DEFENDER restored RTP=" + $(if ((Get-MpComputerStatus).RealTimeProtectionEnabled) { 'ON' } else { 'OFF' }))
    } catch { Write-Output "DEFENDER restore FAILED ($($_.Exception.Message.Split([char]10)[0]))" }
    Remove-Item -LiteralPath $StateFile -Force
    Write-Output 'STATE removed'
    exit 0
}

# Check: who is working?
# Identity = pid AND start time: a pid reused inside the window - even by a process of the same name - is a different
# process (Jev review round 2). A process whose counters cannot be read is recorded as unreadable, not dropped.
function Snap {
    $h = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $st = $null; $c = $null
        try { $st = $p.StartTime.Ticks } catch { }
        try { $c = $p.TotalProcessorTime.TotalSeconds } catch { }
        $h["$($p.Id)"] = @($p.ProcessName, $c, $st)
    }
    $h
}
Add-Type -Namespace RS -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long i, out long k, out long u);'
function Busy { $i = 0L; $k = 0L; $u = 0L; [void][RS.K]::GetSystemTimes([ref]$i, [ref]$k, [ref]$u); ($k - $i + $u) / 1e7 }
$a = Snap; $ba = Busy; $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
Start-Sleep -Seconds $Seconds
$b = Snap; $bb = Busy; $wall = ([Diagnostics.Stopwatch]::GetTimestamp() - $t0) / [Diagnostics.Stopwatch]::Frequency
# The measurement's OWN set is this gate's process ancestry by pid (itself, its cmd, its qrexec-wrapper) plus the kernel's
# pseudo-processes and the long-running qrexec-agent that carries it. Never by name alone: a background powershell (our
# product's own scheduled scripts among them) or another qrexec call starting mid-window is exactly the noise to catch.
$anc = @($PID); $cur = $PID
for ($i = 0; $i -lt 8; $i++) {
    $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
    if (-not $pp -or $pp -in $anc) { break }; $anc += [int]$pp; $cur = $pp
}
# A process that started, exited or had its pid reused between the two snapshots is CHURN: its CPU in the window cannot
# be measured from two snapshots (Jev review: a burst that starts and exits inside the window is otherwise invisible).
$churn = New-Object System.Collections.Generic.List[string]
$same = { param($x, $y) $null -ne $x -and $null -ne $y -and $x[0] -eq $y[0] -and "$($x[2])" -eq "$($y[2])" }
$unread = New-Object System.Collections.Generic.List[string]
$rows = foreach ($id in $b.Keys) {
    $pa = $a[$id]; $pb = $b[$id]
    if ($null -eq $pb[1]) { $unread.Add($pb[0] + ":" + $id); continue }
    if ((& $same $pa $pb) -and $null -ne $pa[1] -and $pb[1] -ge $pa[1]) { $d = $pb[1] - $pa[1] }
    else { $d = $pb[1]; $churn.Add("started:" + $pb[0] + ":" + $id) }
    [pscustomobject]@{ Name = $pb[0]; Id = [int]$id; Pct = 100.0 * $d / $wall }
}
foreach ($id in $a.Keys) { if (-not (& $same $a[$id] $b[$id])) { $churn.Add("exited:" + $a[$id][0] + ":" + $id) } }
# The measurement's own set: this sampler, the qrexec plumbing that carries it, and the kernel's System/Idle.
$own = { param($r) $r.Id -in $anc -or $r.Name -in @('Idle', 'System', 'Registry', 'qrexec-agent') }
$noisy = @($rows | Where-Object { -not (& $own $_) -and $_.Pct -gt $MaxPct } | Sort-Object Pct -Descending)
$churnOther = @($churn | Where-Object { [int](($_ -split ':')[2]) -notin $anc })
# THE WHOLE-GUEST TOTAL catches what two snapshots cannot: a burst from a process that started AND exited inside the
# window, or one that exited after working. Churn itself is reported, not failed on - service hosts and WMI providers come
# and go at ~0 CPU all the time (measured: the gate failed 2 of 4 times on those alone with nothing above 0.5%). The
# idle floor of this guest's total is ~30% of one core (kernel/interrupt time no process carries), hence -MaxTotalPct 50.
$totalPct = 100.0 * ($bb - $ba) / $wall
# MISSING DATA FAILS: a process whose counter cannot be read could be the noise. Only the kernel's permanent
# pseudo-processes are allowed to be unreadable (Jev review round 3: unreadable-not-failing 0.66).
$kernelNames = @('Idle', 'System', 'Registry', 'Secure System', 'Memory Compression')
$unreadOther = @($unread | Where-Object { ($_ -split ':')[0] -notin $kernelNames -and [int](($_ -split ':')[1]) -notin $anc })
$top = ($rows | Sort-Object Pct -Descending | Select-Object -First 6 | ForEach-Object { [string]::Format($inv, '{0}:{1}={2:F1}', $_.Name, $_.Id, $_.Pct) }) -join ','
Write-Output ("QUIET=" + $(if ($noisy.Count -eq 0 -and $unreadOther.Count -eq 0 -and $totalPct -le $MaxTotalPct) { 1 } else { 0 }) + "|secs=" + [Math]::Round($wall, 1).ToString($inv) +
              "|total=" + [Math]::Round($totalPct, 1).ToString($inv) +
              "|churn=" + ($churnOther -join ',') + "|unreadable=" + ($unread -join ',') + "|noisy=" +
              (($noisy | ForEach-Object { [string]::Format($inv, '{0}={1:F1}', $_.Name, $_.Pct) }) -join ',') + "|top=" + $top)
