<#
.SYNOPSIS
  Deploy the QWT-NG Windows Update agent and register its scheduled scan (north-star: report
  update availability to dom0, non-blocking).

.DESCRIPTION
  Idempotent. Run elevated by the QWT installer (writes to Program Files) or standalone for test
  with -BinDir to a writable dir. Three steps:
    1. compile the relay from qubes-updates-relay.cs with the in-box csc (no build infra, matching
       the winenum.cs convention) -> <BinDir>\qubes-updates-relay.exe
    2. place qubes-windows-update.ps1 -> <BinDir>
    3. register scheduled task QubesWindowsUpdateScan (SYSTEM; at boot + every -Interval) that runs
       `-Action scan` only. Scan REPORTS availability; download/install stay on-demand so the task
       never blocks or reboots the guest on its own.

.PARAMETER SetupRoot  Dir holding qubes-updates-relay.cs and qubes-windows-update.ps1 (default: this script's dir).
.PARAMETER BinDir     Install dir for the exe + agent script.
.PARAMETER Interval   Scan cadence as an ISO-8601 duration (default PT6H).
#>
[CmdletBinding()]
param(
  [string]$SetupRoot = $PSScriptRoot,
  [string]$BinDir    = 'C:\Program Files\Qubes Tools\bin',
  [string]$Interval  = 'PT6H'
)
$ErrorActionPreference = 'Stop'
function Log($m){ Write-Output ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) }

New-Item -ItemType Directory -Force $BinDir | Out-Null

# 1. compile the relay with the in-box csc
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$src = Join-Path $SetupRoot 'qubes-updates-relay.cs'
$exe = Join-Path $BinDir 'qubes-updates-relay.exe'
if (-not (Test-Path $csc)) { throw "in-box csc not found at $csc" }
if (-not (Test-Path $src)) { throw "relay source not found at $src" }
& $csc /nologo /optimize /target:exe /out:"$exe" "$src" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "relay compile failed (csc rc=$LASTEXITCODE)" }
Log "compiled relay -> $exe"

# 2. place the agent script
$agent = Join-Path $BinDir 'qubes-windows-update.ps1'
Copy-Item (Join-Path $SetupRoot 'qubes-windows-update.ps1') $agent -Force
Log "placed agent -> $agent"

# 3. register the scheduled scan task. Past StartBoundary is fine - the repetition schedules the
#    next occurrence. Runs as SYSTEM/HighestAvailable so it works with no user logged on.
$cmd  = 'powershell.exe'
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$agent`" -Action scan -RelayExe `"$exe`""
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: scan Windows Update over the Qubes proxy and report availability to dom0</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></BootTrigger>
    <TimeTrigger><Enabled>true</Enabled><StartBoundary>2026-01-01T03:00:00</StartBoundary><Repetition><Interval>$Interval</Interval></Repetition></TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT20M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>$cmd</Command><Arguments>$args</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'qubes-wu-scan.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateScan /xml "$f" /f 2>&1
Log ("REGISTER QubesWindowsUpdateScan rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register failed (rc=$LASTEXITCODE)" }

# 4. the dom0-DRIVEN update path, Linux-updater style (update runs only when dom0 asks):
#    - QubesWindowsUpdateRun: on-demand SYSTEM task running `-Action full` (rpc handlers are
#      unelevated and DISM needs admin; the SYSTEM-task path is proven). No triggers - fires
#      only via schtasks /run.
#    - qubes.WindowsUpdate rpc service: dom0 calls it to start the run; the handler
#      (wu-update.ps1) kicks the task, tails update-status.json, and speaks the qubes-vm-update
#      protocol (float progress on stderr, exit 100 = no updates). dom0-initiated, no policy.
# XML with an EMPTY Triggers block: purely on-demand, and no schtasks /st-in-the-past warning
# (which, on stderr under ErrorActionPreference=Stop, would kill this script mid-deploy).
$runXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: perform a full Windows update pass (dom0-driven via qubes.WindowsUpdate; never fires on its own)</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$agent" -Action full -RelayExe "$exe"</Arguments></Exec></Actions>
</Task>
"@
$fr = Join-Path $env:TEMP 'qubes-wu-run.xml'
[IO.File]::WriteAllText($fr, $runXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateRun /xml "$fr" /f 2>&1
Log ("REGISTER QubesWindowsUpdateRun rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register (run task) failed (rc=$LASTEXITCODE)" }

$qt = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
$handlerDir = Join-Path $qt 'qubes-rpc-services'
$svcDir     = Join-Path $qt 'qubes-rpc'
if ((Test-Path $handlerDir) -and (Test-Path $svcDir)) {
    Copy-Item (Join-Path $SetupRoot 'wu-update.ps1') (Join-Path $handlerDir 'wu-update.ps1') -Force
    $map = 'c:\windows\system32\cmd.exe /c powershell.exe -executionpolicy bypass -noninteractive -inputformat none -file "%QUBES_TOOLS%\qubes-rpc-services\wu-update.ps1"'
    [IO.File]::WriteAllText((Join-Path $svcDir 'qubes.WindowsUpdate'), $map, [Text.Encoding]::ASCII)
    # retire the short-lived poll service - progress now streams over the update call itself
    Remove-Item (Join-Path $svcDir 'qubes.WindowsUpdateStatus'), (Join-Path $handlerDir 'wu-status.ps1') -Force -EA SilentlyContinue
    Log 'registered qubes.WindowsUpdate rpc service (dom0-driven update)'

    # 5. STOCK-TOOL COMPATIBILITY: make dom0's own `qubes-vm-update` - and therefore the Qubes
    #    Update GUI - drive this qube, so updating a Windows qube is the same click as any other
    #    and needs no dom0-side command. dom0 injects a Python agent and runs it; we answer the
    #    same command shapes and run ours instead. See guest/vmupdate-shim.ps1 for the sequence.
    Copy-Item (Join-Path $SetupRoot 'vmupdate-shim.ps1') (Join-Path $handlerDir 'vmupdate-shim.ps1') -Force
    # Re-asserted before every reboot the updater triggers: Windows servicing rewrites Winlogon,
    # and a qube that returns to a sign-in screen is unreachable over qrexec.
    if (Test-Path (Join-Path $SetupRoot 'ensure-autologon.ps1')) {
        Copy-Item (Join-Path $SetupRoot 'ensure-autologon.ps1') (Join-Path $handlerDir 'ensure-autologon.ps1') -Force
    }
    $vmexec = Join-Path $handlerDir 'VMExec.ps1'
    $backup = Join-Path $handlerDir 'VMExec.ps1.qwt-orig'
    if ((Test-Path $vmexec) -and -not (Test-Path $backup)) { Copy-Item $vmexec $backup -Force }
    Copy-Item (Join-Path $SetupRoot 'VMExec.ps1') $vmexec -Force
    Log 'installed vmupdate-shim + VMExec.ps1 (exit-code propagation + updater dispatch)'
} else {
    Log 'qubes-rpc dirs missing - skipped rpc service (is QWT installed?)'
}

# 6. `cat` for the one step PATH can satisfy: dom0 ships its agent tarball in with
#    `cat > <file>` over qubes.VMShell, which goes straight to cmd.exe with no interception
#    point. (mkdir/rm/tar/python3 all arrive via qubes.VMExec and are handled by the shim.)
$shimDir = Join-Path $qt 'vmupdate-shim'
New-Item -ItemType Directory -Force $shimDir | Out-Null
$catSrc = Join-Path $SetupRoot 'qubes-posix-cat.cs'
$catExe = Join-Path $shimDir 'cat.exe'
if (Test-Path $catSrc) {
    & $csc /nologo /optimize /target:exe /out:"$catExe" "$catSrc" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cat.exe compile failed (csc rc=$LASTEXITCODE)" }
    # Appended, never prepended: if a real POSIX toolset is installed later, it wins.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$shimDir*") {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $shimDir), 'Machine')
        Log "added $shimDir to the machine PATH"
    }
    Log "compiled cat -> $catExe"
}

# 7. download-only pass, kept separate so `--download-only` can never install.
$dlXml = $runXml -replace 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload' `
                 -replace '-Action full', '-Action download' `
                 -replace 'perform a full Windows update pass', 'download Windows updates only'
$fd = Join-Path $env:TEMP 'qubes-wu-dl.xml'
[IO.File]::WriteAllText($fd, $dlXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateDownload /xml "$fd" /f 2>&1
Log ("REGISTER QubesWindowsUpdateDownload rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register (download task) failed (rc=$LASTEXITCODE)" }

# 8. The updater workdir, pre-created ON PURPOSE - do not delete it.
#
#    dom0 chooses its transport per qube: qubesadmin's run_with_args() uses qubes.VMExec only
#    for qubes advertising the `vmexec` feature, and otherwise falls back to qubes.VMShell with
#    a shell-quoted line. We CANNOT advertise that feature from the guest: the Windows build of
#    qubesdb-cmd cannot write at all (`optind -= 2` in client/qubesdb-cmd.c leaves exactly one
#    trailing argument, so `write path value` always dies with "Invalid number of parameters" -
#    measured, every documented form). Do not re-add an advertisement step; it cannot work until
#    that upstream bug is fixed or dom0 sets the feature itself (`qvm-features <vm> vmexec 1`).
#
#    So the fallback path must work, and it does - with this one preparation. Over VMShell each
#    of dom0's POSIX commands fails on cmd.exe, but `& exit` returns 0 regardless (measured: a
#    bogus command still yields exit 0), so dom0 sees success and proceeds. The only step that
#    then matters is the agent run itself, and that ALWAYS travels over qubes.VMExec - the
#    progress path calls the service directly, with no feature check and no fallback - so our
#    shim still handles it. The one thing that must not fail is dom0 piping its agent tarball in
#    with `cat > <workdir>/agent.tar.gz`: if the directory is missing, cmd's redirection fails,
#    cmd exits immediately and dom0 is left writing a megabyte into a closed pipe. Hence the
#    directory exists from install time, and the shim's `rm` empties it rather than removing it.
$workdir = Join-Path $env:SystemDrive 'run\qubes-update'
New-Item -ItemType Directory -Force -Path $workdir | Out-Null
Log "prepared updater workdir $workdir (kept even when dom0 asks to remove it - see comment)"

# 9. Guest-side auto-update OFF: dom0 owns every install decision from now on. This is not
#    cosmetic - the updates proxy is raised only for the duration of a dom0-driven pass, which
#    is precisely the window in which a live Windows AU would find connectivity and start
#    installing behind dom0's back. The wuauserv/USO services stay ENABLED: the on-demand path
#    needs them; only the automatic behaviour is disabled.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
Log 'set NoAutoUpdate=1 (dom0 owns updates; guest never installs on its own)'

Log 'updater agent deployed'
