<#
.SYNOPSIS
    Install QWT-NG 4.3 (Qubes Windows Tools rebuilt from upstream 4.2.2 sources with the
    improved GUI agent) onto a clean Windows guest, or over a guest that already has QWT
    installed.

.DESCRIPTION
    This is a FULL install, not an overlay: it runs the real QWT installer.msi produced by
    the `qwt-full` CI workflow, which contains our gui-agent.exe / gui-watchdog.exe and
    every other component bit-identical to the shipped ITL 4.2.2 MSI.

    Two stages, because our binaries are TEST-SIGNED and Windows must be rebooted after
    `bcdedit /set testsigning on` before it will load them:

      stage 1  copy payload to disk, verify hashes, trust the signing certificates,
               seed the gui-agent registry defaults, enable testsigning, reboot
      stage 2  verify testsigning is active, REMOVE any previously installed QWT,
               install vc_redist, run msiexec, optionally install AND ACTIVATE the
               IddCx display driver, reboot

    The stage is DETECTED, not remembered: if testsigning is not active in the current
    boot we are in stage 1, otherwise stage 2. Re-running the script is safe.

    WHY STAGE 2 UNINSTALLS FIRST (measured 2026-08-06, FINDINGS.md): on a guest that
    already had QWT, msiexec returned 3010 "success" and every component updated EXCEPT
    gui-agent.exe, which kept the pre-existing build - verified across a reboot, so it is
    not deferred file replacement. It is the Windows Installer file-versioning rule: an
    existing file whose version is >= the incoming one is not overwritten, and our
    binaries carry no increasing FILEVERSION. Removing the old product and deleting the
    leftover binaries makes the versioning rule inapplicable; REINSTALLMODE=amus on the
    install command line is the second, independent belt.

.PARAMETER Auto
    Reboot automatically at the end of each stage and resume via RunOnce. Without it the
    script stops and tells you to reboot and re-run.

.PARAMETER AcceptPvDiskUpgrade
    Proceed with removing an existing QWT even though the C: boot disk is on the Xen PV
    disk path (xenvbd, boot-start). Without it the script refuses: uninstalling stock QWT
    reverts the boot disk toward emulated IDE, which Windows has by then demoted from
    boot-start, so the intermediate reboot the removal needs can bugcheck 0x7B
    INACCESSIBLE BOOT DEVICE. Read the UPGRADING FROM STOCK QWT section of README.txt
    (including the recovery recipe) before passing this.

.PARAMETER NoIddDriver
    Do NOT activate the Qubes IddCx display driver; leave the guest on the emulated Basic
    Display Adapter. IDD activation is ON BY DEFAULT (it is the point of this package -
    arbitrary resolutions that follow the dom0 window, no oversized BDA snapping) and is
    non-fatal: if it fails the install still succeeds on the BDA.

.PARAMETER InstallIddDriver
    Deprecated no-op (IDD is default-on). Kept so old command lines and /idd still parse.
    Also install and ACTIVATE the Qubes IddCx display driver: the package is staged with
    pnputil, the root-enumerated device (root\iddsampledriver) is created with devcon,
    and once it binds the emulated VGA adapter (PCI display class CC_0300) is DISABLED,
    so the desktop comes up on the IDD after the final reboot. The gui-agent installed
    by this same stage publishes the mode list to HKLM\SOFTWARE\QubesIDD\Modes at
    runtime. Recovery: re-enable the VGA adapter (its InstanceId is in the result JSON)
    and reboot - see README.txt. Default: off.

.PARAMETER NoMoveUsers
Omit MoveUsers, leaving C:\Users on the root volume. Recovery use only.

.PARAMETER NoPvDisk
Omit the Xen PV disk drivers (xenvbd). Leaves the guest on emulated IDE. Diagnostic use only.

.PARAMETER NoPvNetwork
    Drop PvDriversNetwork from ADDLOCAL. See the NETWORKING caveat in README.txt.

.PARAMETER ResumeAfterUninstall
    INTERNAL. Set only by the boot-resume task this script arms for itself when removing
    the previously installed QWT demanded a reboot. It makes the resumed run skip the
    detect/uninstall phase and go straight to the install phase.

.PARAMETER WorkDir
    Where the payload is copied to before installing. Default C:\qwt-improved-setup.

.OUTPUTS
    Human-readable progress, plus a machine-readable trailer:
        === RESULT === {json}
    Exit codes: 0 = this stage completed, 10 = stage completed and a REBOOT is required
    before re-running, anything else = failure.
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    # Reboot at the END of the install as well. OFF by default: the install costs ONE guest
    # shutdown (the testsigning reboot between the two stages) and the PV drivers hand over
    # from their emulated counterparts at the qube's next start, exactly as stock QWT leaves
    # it. A second shutdown hangs qvm-create-windows-qube, which restarts the qube once and
    # then waits forever for os=Windows.
    [switch]$RebootAtEnd,
    # IDD activation is default-on: the IddCx driver is the display point of this package
    # (arbitrary resolutions following the dom0 window, no Basic-Display-Adapter snapping).
    # -NoIddDriver (/noidd) leaves the guest on the emulated BDA - a reduced configuration,
    # not a broken one, and the supported escape hatch when the IDD misbehaves on a given
    # host. -InstallIddDriver is a harmless no-op kept so /idd still parses.
    [switch]$NoIddDriver,
    [switch]$InstallIddDriver,
    [switch]$NoPvNetwork,

    # INERT since 2026-08-15. It used to override the PV-boot-disk gate; that gate is now a
    # hard refusal because the failure was reproduced and could not be recovered from inside
    # the guest (see the refusal message in stage 2). Still accepted so existing command lines
    # and scripts do not break - it just warns and changes nothing.
    [switch]$AcceptPvDiskUpgrade,

    # Skip the app hardware-acceleration pre-tweak (disable-hw-accel.ps1): HKLM policies
    # that make Chrome/Edge/Brave/Firefox/Slack and (per-user) Office render in software.
    # On a GPU-less guest the GPU path is emulation at best and a common source of
    # rendering artifacts and capture-hostile repaint storms, so the tweak is ON by
    # default; this exists for guests where the admin manages those policies themselves.
    [switch]$NoAppTweaks,

    # Skip the Windows Update agent (install-updater-agent.ps1). It is ON by default because
    # dom0 owns updates in this model: the guest reports availability, dom0 installs, and
    # Windows' own auto-update is turned off. Use this only where updates are managed some
    # other way - a guest without it will neither report updates nor answer the Update GUI.
    [switch]$NoUpdaterAgent,

    # Escape hatch only. PV disk is ON by default because stock QWT installs it by default
    # and emulated IDE is markedly slower; use this only to isolate a suspected xenvbd fault.
    [switch]$NoPvDisk,

    # Escape hatch. MoveUsers is ON by default (stock does it, and the private volume is where
    # user data belongs); this exists only to recover a guest that fails to boot after it.
    [switch]$NoMoveUsers,
    [switch]$ResumeAfterUninstall,

    # AUTOLOGON. A Qubes Windows guest that stops at a sign-in screen is unreachable (no qrexec
    # session) and, in seamless mode, invisible (the sign-in screen is not displayed). The
    # installer therefore arms autologon: pass the account password here for an unattended
    # install, or let it prompt. -NoAutologon opts out and says what that costs.
    [string]$AutologonPassword,
    [string]$AutologonUser,
    [switch]$NoAutologon,

    [string]$WorkDir = 'C:\qwt-improved-setup'
)

$ErrorActionPreference = 'Stop'
# Version 1.0 deliberately: 2.0 turns "read a property that is absent" into a terminating
# error, and this script reads optional registry values and optional manifest keys on a
# machine we cannot debug interactively.
Set-StrictMode -Version 1.0

$script:LogFile = 'C:\qwt-improved-install.log'
$script:Result  = [ordered]@{
    stage        = 'unknown'
    ok           = $false
    reboot_needed = $false
    error        = $null
    detail       = [ordered]@{}
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Emit-Result {
    param([int]$ExitCode)
    $json = $script:Result | ConvertTo-Json -Depth 6 -Compress
    Write-Host '=== RESULT ==='
    Write-Host $json
    try { Add-Content -LiteralPath $script:LogFile -Value "=== RESULT === $json" -Encoding UTF8 } catch { }
    exit $ExitCode
}

function Fail {
    param([string]$Message)
    Write-Log $Message 'FATAL'
    $script:Result.ok = $false
    $script:Result.error = $Message
    Emit-Result 1
}

# ---------------------------------------------------------------------------- elevation
function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'not running elevated - right-click install.cmd and "Run as administrator"'
    }
}

# ------------------------------------------------------------------- payload verification
# A payload that cannot be verified is not installed. SHA256SUMS.txt is produced by
# packaging/make-setup.ps1 in CI and covers every file in the tree.
function Test-Payload {
    param([Parameter(Mandatory)][string]$Root)

    $sums = Join-Path $Root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sums)) {
        Fail "SHA256SUMS.txt missing in $Root - refusing to install an unverified payload"
    }
    $lines = @(Get-Content -LiteralPath $sums | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -lt 5) {
        Fail "SHA256SUMS.txt lists only $($lines.Count) files - implausible, treating as corrupt"
    }

    $bad = @()
    $seen = @{}
    foreach ($l in $lines) {
        # -match (not -notmatch): $Matches is only guaranteed populated on the TRUE branch
        # of -match, and this loop depends on the captures.
        if (-not ($l -match '^([0-9a-fA-F]{64})\s+(.+)$')) { Fail "malformed SHA256SUMS.txt line: $l" }
        $want = $Matches[1].ToLowerInvariant()
        $rel  = $Matches[2].Trim()
        $seen[$rel] = $true
        $p = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p)) { $bad += "MISSING  $rel"; continue }
        $have = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($have -ne $want) { $bad += "MISMATCH $rel (got $have, want $want)" }
    }
    if ($bad.Count -gt 0) {
        Fail ("payload verification FAILED:`n  " + ($bad -join "`n  "))
    }
    # The manifest must actually cover the thing we are about to run, or the check above
    # proved nothing about it.
    foreach ($required in 'msi/installer.msi', 'msi/vc_redist.x64.exe') {
        if (-not $seen.ContainsKey($required)) {
            Fail "SHA256SUMS.txt does not cover $required - verification is meaningless"
        }
    }
    Write-Log "payload verified: $($lines.Count) files match SHA256SUMS.txt"
    return $lines.Count
}

# ------------------------------------------------------------------------------- staging
function Copy-Payload {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Dest)

    if ((Resolve-Path -LiteralPath $Source).Path.TrimEnd('\') -ieq $Dest.TrimEnd('\')) {
        Write-Log "already running from $Dest - no copy needed"
        return
    }
    Write-Log "copying payload $Source -> $Dest"
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $Dest -Recurse -Force
    # Files copied off a CD keep the read-only attribute, which breaks nothing here but
    # makes a later re-run unable to replace them.
    Get-ChildItem -LiteralPath $Dest -Recurse -File | ForEach-Object {
        if ($_.IsReadOnly) { $_.IsReadOnly = $false }
    }
}

# -------------------------------------------------------------------------- boot state
function Test-TestSigningActive {
    # SystemStartOptions reflects the CURRENT boot; `bcdedit` reflects the NEXT one. Only
    # the former tells us whether the kernel will load our test-signed binaries right now.
    $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                           -Name SystemStartOptions -ErrorAction SilentlyContinue).SystemStartOptions
    return ($v -and $v -match 'TESTSIGNING')
}

function Start-XenbusPromptSuppressor {
    # KEEP the monitor down FOR THE DURATION of an msiexec/driver install, not just before and
    # after it.
    #
    # Disabling it before msiexec is not enough and the field proved it: the MSI lays the
    # service down FRESH (auto-start) and STARTS it while it is still running, so the PV driver
    # install's reboot request is raised and answered by a modal "... needs to restart the
    # system to complete installation" INSIDE the msiexec window - after our pre-disable, before
    # our post-disable. Forum 42717 post 104: answering Yes shut the VM down mid-install and
    # left "a QWT that was installed only partially, had no IDD graphics, and was not useful at
    # all"; the reporter only got a working guest by answering No. An unattended install has
    # nobody to answer at all, and on a seamless guest the dialog may not even be clickable.
    #
    # So: a background loop that re-disables the service, kills it if it is up, and deletes any
    # pending reboot Request key, once a second until told to stop. Deleting Request is what
    # makes this stick - a service restarted by the MSI then has nothing to prompt about.
    $job = $null
    try {
    $job = Start-Job -ScriptBlock {
        for ($i = 0; $i -lt 1800; $i++) {
            & sc.exe config xenbus_monitor start= disabled *>$null
            $svc = Get-Service xenbus_monitor -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') { & sc.exe stop xenbus_monitor *>$null }
            # UNCONDITIONAL, every tick, for the same reason as in Disable-XenbusMonitor: gating
            # the kill on the SERVICE state lets a running PROCESS through, and a running process
            # is the thing that restarts the guest mid-install.
            Get-Process -Name 'xenbus_monitor*' -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            # Nothing pending -> nothing to ask about, even if something restarts the service.
            # Registry API, not reg.exe: no process spawned per tick, and no stderr to trip over.
            try {
                $hk = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
                $sk = $hk.OpenSubKey('SYSTEM\CurrentControlSet\Services\xenbus_monitor', $true)
                if ($sk) {
                    if ($sk.GetSubKeyNames() -contains 'Request') { $sk.DeleteSubKeyTree('Request') }
                    $sk.Close()
                }
                $hk.Close()
            } catch { }
            Start-Sleep -Seconds 1
        }
    }
    } catch {
        # A suppressor that cannot start must not take the install with it - the before/after
        # Disable-XenbusMonitor calls still apply, they just leave the msiexec window uncovered.
        Write-Log "could not start the xenbus prompt suppressor: $($_.Exception.Message) - the reboot prompt may appear during the install" 'WARN'
        return $null
    }
    Write-Log "xenbus reboot-prompt suppressor running (job $($job.Id)) - it holds the monitor down THROUGH the install, which before/after calls alone do not"
    return $job
}

function Stop-XenbusPromptSuppressor {
    param($Job)
    if (-not $Job) { return }
    try {
        Stop-Job $Job -ErrorAction SilentlyContinue
        Remove-Job $Job -Force -ErrorAction SilentlyContinue
        Write-Log 'xenbus reboot-prompt suppressor stopped'
    } catch { }
}

function Disable-XenbusMonitor {
    param([string]$Why = '')
    # The xenbus_monitor service (xenbus/src/monitor/monitor.c PromptForReboot) pops a modal
    # Yes/No - "... needs to restart the system to complete installation" - whenever a PV
    # driver install wants a reboot. It hangs an unattended install, and on a seamless guest
    # the user may not even be able to act on it (forum 42717 post 33).
    #
    # Until 4.3.6 the answer was AutoReboot=1 (silent reboot instead of the prompt). The
    # 2026-08-25 review showed why that cannot ship: xenvbd re-files its reboot request at
    # EVERY AppVM boot (a volatile root forgets the PnP configure that would satisfy it), so
    # the inherited AutoReboot=1 became the field's AppVM reboot loop - and the 4.3.6
    # AutoReboot=0 alone left the request answered by a modal csrss "Xen" prompt on every
    # AppVM boot, with the monitor wedged STOP_PENDING behind it.
    #
    # Nothing in the unattended QWT flow needs the monitor at all: this installer performs its
    # own reboot/shutdown at the right moments (stage 1's shutdown /r, the final install
    # shutdown), so the service is stopped and DISABLED - no prompt, no surprise reboot. The
    # per-boot payload (pvnic-selfprime) re-asserts this on every boot as the belt for driver
    # package upgrades that re-register the service. AutoReboot=0 stays written as the second
    # belt in case something re-enables the service anyway.
    & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Parameters' `
        /v AutoReboot /t REG_DWORD /d 0 /f /reg:64 | Out-Null
    # AND REMOVE THE PENDING REQUEST. Disabling the service and setting AutoReboot=0 leaves the
    # trigger itself in place: HKLM\...\xenbus_monitor\Request\<driver>\Reboot=1, written by a PV
    # driver install, is what the monitor answers with its modal prompt. Anything that re-enables
    # or reinstalls the service - the MSI does exactly that mid-install - then finds a request
    # waiting and asks. With no request there is nothing to ask about, whoever starts the service.
    # (The suppressor loop clears this every second DURING msiexec; doing it here covers every
    # other call site too: stage 1, the uninstall, and the post-install re-assert.)
    # Delete it through the registry API, checking first, rather than shelling out.
    # reg.exe delete FAILS on a key that is not there ("unable to find the specified registry
    # key"), writing to stderr and exiting non-zero - which in this script became a TERMINATING
    # error and aborted stage 2 on any guest with NO pending request, i.e. the normal case
    # (measured 2026-08-28: "[FATAL] at Disable-XenbusMonitor ... line 341", both chains).
    # Absence is the desired state, so it must not even look like an error. OpenBaseKey with
    # Registry64 keeps the same 64-bit view the reg.exe calls here ask for with /reg:64.
    try {
        $hklm64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        $svcKey = $hklm64.OpenSubKey('SYSTEM\CurrentControlSet\Services\xenbus_monitor', $true)
        if ($svcKey) {
            if ($svcKey.GetSubKeyNames() -contains 'Request') {
                $svcKey.DeleteSubKeyTree('Request')
                Write-Log 'cleared a pending PV reboot request (xenbus_monitor\Request)'
            }
            $svcKey.Close()
        }
        $hklm64.Close()
    } catch {
        # Never fatal: not clearing the request costs a prompt, failing here costs the install.
        Write-Log "could not clear xenbus_monitor\Request: $($_.Exception.Message) (continuing)" 'WARN'
    }
    $svc = Get-Service xenbus_monitor -ErrorAction SilentlyContinue
    if ($svc) {
        & sc.exe config xenbus_monitor start= disabled 2>&1 | Out-Null
        if ($svc.Status -ne 'Stopped') {
            & sc.exe stop xenbus_monitor 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    }
    # KILL THE PROCESS UNCONDITIONALLY - this is what actually bricks guests.
    #
    # Measured 2026-08-28. On an UPGRADE the service is already `Disabled` (a previous QWT
    # install disabled it) yet a monitor process from that earlier boot is still RUNNING, and
    # disabling a service does nothing to a process already in memory. That survivor sees the
    # reboot request the PV driver install files during msiexec and restarts the guest mid-install
    # - Windows event 1074, "xenbus_monitor_9_1_0_0.exe has initiated the restart ... Operating
    # System: Recovery (Planned)" - leaving a guest that boots to Automatic Repair or runs
    # headless with no qrexec. Reproduced 5/5.
    #
    # The previous version could not prevent it: the kill sat behind "if the service STILL is not
    # Stopped after sc stop", so the moment SCM reported success - which it does while the process
    # is still exiting, and always for a process that is not under SCM control - the kill was
    # skipped and the survivor did the damage. A stopped SERVICE and a dead PROCESS are different
    # facts, and only the second one is safe to start msiexec on.
    $killed = @()
    foreach ($p in @(Get-Process -Name 'xenbus_monitor*' -ErrorAction SilentlyContinue)) {
        $killed += "$($p.Name)($($p.Id))"
        try { $p | Stop-Process -Force -ErrorAction Stop } catch { Write-Log "could not kill $($p.Name) ($($p.Id)): $($_.Exception.Message)" 'WARN' }
    }
    if ($killed.Count) { Write-Log "killed running monitor process(es): $($killed -join ', ')" }
    # And VERIFY, because a survivor here is the difference between an install and a brick.
    Start-Sleep -Milliseconds 300
    $alive = @(Get-Process -Name 'xenbus_monitor*' -ErrorAction SilentlyContinue)
    if ($alive.Count) {
        Write-Log ("xenbus_monitor STILL RUNNING after the kill: " +
                   (($alive | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ', ') +
                   ' - it can restart the guest during the install') 'WARN'
        $script:Result.detail.xenbus_monitor_survivors = @($alive | ForEach-Object { $_.Id })
    }
    $state = if ($svc) { "was $($svc.StartType)/$($svc.Status)" } else { 'service not present yet' }
    $reason = if ($Why) { " [$Why]" } else { '' }
    Write-Log "xenbus_monitor disabled, AutoReboot=0 ($state)$reason"
    $script:Result.detail.xenbus_monitor = 'disabled'
    return $true
}

$script:TaskName = 'QwtImprovedSetup'

function Set-BootResume {
    param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$ExtraArgs = @())
    # A scheduled ONSTART task running as SYSTEM, NOT HKLM\...\RunOnce: RunOnce entries
    # execute with the logged-on user's FILTERED token under UAC, so the resumed stage
    # would not be elevated and every step here needs elevation.
    if ($ScriptPath -match '\s') {
        Fail "-Auto needs a space-free payload path for the resume task; got '$ScriptPath' (pass -WorkDir C:\something-without-spaces)"
    }
    $argline = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArgs
    $cmd = 'powershell.exe ' + ($argline -join ' ')
    # /DELAY: ONSTART fires very early. msiexec needs the Windows Installer service, and
    # the PV driver install needs PnP settled; a minute of slack costs nothing and avoids
    # a class of "worked when I ran it by hand" failures.
    # Same native-stderr trap as Clear-BootResume: schtasks can warn on stderr (e.g.
    # overwriting an existing task with /F) and that would terminate under
    # ErrorActionPreference='Stop'. Judge the EXIT CODE, never the stream.
    try { & schtasks.exe /Create /TN $script:TaskName /SC ONSTART /DELAY 0001:00 `
                   /RU SYSTEM /RL HIGHEST /F /TR $cmd *>&1 | Out-Null } catch { }
    if ($LASTEXITCODE -ne 0) { Fail "schtasks /Create failed ($LASTEXITCODE) - cannot arm the post-reboot resume" }
    Write-Log "boot resume armed as SYSTEM task '$script:TaskName': $cmd"
}

function Clear-BootResume {
    # schtasks writes "ERROR: The system cannot find the file specified." to STDERR when
    # the task does not exist - and under $ErrorActionPreference='Stop' PowerShell turns
    # a native command's stderr into a TERMINATING error. So this no-op aborted the whole
    # install whenever stage 2 ran without a prior -Auto stage 1 (measured 2026-08-06 on a
    # fresh guest whose boot ISO had already enabled testsigning). Same trap as the
    # pnp-revert setup script hit earlier; swallow it explicitly.
    try { & schtasks.exe /Delete /TN $script:TaskName /F *>&1 | Out-Null } catch { }
    $global:LASTEXITCODE = 0
}

# --------------------------------------------------------------- gui-agent registry seed
function Set-GuiAgentRegistryDefaults {
    # The MSI only seeds these when its AppSearch does NOT already find them (conditions
    # NOT GUI_SEAMLESS_SET / NOT GUI_CURSOR_SET / NOT LOG_DIR_SET), so writing them first
    # makes ours win. /reg:64 because the MSI's RegLocator is 64-bit; a WOW-redirected
    # write would simply be invisible to it.
    # Called twice: in stage 1, and again in stage 2 AFTER a previous QWT is uninstalled -
    # that uninstall takes this key with it, which would otherwise hand the decision back
    # to the MSI's own defaults.
    $regPath = 'HKLM\Software\Invisible Things Lab\Qubes Tools'
    $seed = @(
        @('SeamlessMode',  'REG_DWORD', '1'),
        # DisableCursor=1, i.e. DO blank the guest's software cursor. 24a1ded seeded 0 with
        # no stated reason and that produces a DOUBLE CURSOR: dom0 always draws the X cursor
        # over the guest window, and with 0 the guest ALSO composites its own cursor into the
        # framebuffer we capture, so the user sees two. Reported on Win11 2026-08-07.
        # The name reads backwards: gui-agent's HideCursors() returns early unless
        # g_DisableCursor is set (util.c:213), so 1 = hide the guest cursor = correct. This is
        # also the agent's own built-in default (util.c:36) and the stock MSI's default.
        # It matters more now that /idd is on by default: the IddCx driver implements NO
        # hardware cursor path at all (zero cursor code in Driver.cpp), so the guest cursor
        # can only ever arrive as pixels baked into the frame.
        @('DisableCursor', 'REG_DWORD', '1'),
        # LogDir MUST be pre-seeded: two MSI components race to write it ([INSTALL_DIR]log
        # vs "Q:\Qubes Logs") under an identical condition, so without a deterministic seed
        # the winner is arbitrary - and if Q:\ wins while Q: does not exist, every gui-agent
        # log silently vanishes. So the seed is about DETERMINISM, not about which path.
        # The private image is the correct destination (user data belongs on the private
        # volume, not root - same reason MoveUsers exists), and PvDriversDisk + MoveUsers
        # now guarantee Q: is present, so seed the stock value rather than a root-volume one.
        @('LogDir', 'REG_SZ', 'Q:\Qubes Logs')
    )
    foreach ($s in $seed) {
        & reg.exe add $regPath /v $s[0] /t $s[1] /d $s[2] /f /reg:64 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "reg add failed for $($s[0])" }
    }
    Write-Log 'seeded gui-agent registry defaults (SeamlessMode=1, DisableCursor=1, LogDir)'
}

# ------------------------------------------------------- pre-existing QWT: detect/remove
# Files this package delivers into the QWT bin directory and that Windows Installer will
# refuse to overwrite if a same-or-newer-versioned copy is already there. Kept in sync
# with MANIFEST.json -> reference_binaries at run time; this is the fallback list.
$script:OurBinaries    = @('gui-agent.exe', 'gui-watchdog.exe')
$script:DefaultBinDir  = 'C:\Program Files\Qubes Tools\bin'
$script:GuiWatchdogSvc = 'QubesGuiWatchdog'
# Set true only on the same-ProductVersion in-place reinstall path (see the upgrade block); a
# fresh install never enters that block, so default it here rather than rely on StrictMode 1.0.
$script:SameVersionReinstall = $false

function Get-QwtBinDir {
    foreach ($k in 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools',
                   'HKLM:\SOFTWARE\WOW6432Node\Invisible Things Lab\Qubes Tools') {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($p.PSObject.Properties.Name -contains 'GuiAgentPath' -and $p.GuiAgentPath) {
            return (Split-Path -Parent $p.GuiAgentPath)
        }
        if ($p.PSObject.Properties.Name -contains 'InstallDir' -and $p.InstallDir) {
            return (Join-Path $p.InstallDir 'bin')
        }
    }
    return $script:DefaultBinDir
}

function Get-InstalledQwt {
    # The Uninstall hive, deliberately NOT Win32_Product: enumerating that WMI class makes
    # Windows Installer reconfigure every registered product - minutes of work and it can
    # itself rewrite the very files this function exists to get rid of.
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $found = @()
    $seen  = @{}
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            if ($p.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            $name = [string]$p.DisplayName
            # "Qubes Windows Tools" is the shipped ProductName. Match loosely enough to
            # catch a renamed rebuild, tightly enough not to hit "Qubes Tools Driver..."
            # style third-party entries - there are none on a Windows guest.
            if ($name -notmatch '^Qubes\s+(Windows\s+)?Tools') { continue }
            $code = [string]$k.PSChildName
            if ($seen.ContainsKey($code)) { continue }
            $seen[$code] = $true
            $ver = ''
            if ($p.PSObject.Properties.Name -contains 'DisplayVersion') { $ver = [string]$p.DisplayVersion }
            $found += [pscustomobject]@{
                DisplayName = $name
                Version     = $ver
                ProductCode = $code
                IsMsi       = ($code -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$')
                RegKey      = [string]$k.PSPath
            }
        }
    }
    return $found
}

function Stop-QwtRuntime {
    # Graceful first: the agent owns Global\QGA_SHUTDOWN and exits cleanly on it, which
    # lets it drop the framebuffer grants instead of leaving them held by a killed process.
    # Then the service (the watchdog respawns gui-agent.exe, so it has to go before the
    # process), then the hammer.
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting('Global\QGA_SHUTDOWN')
        [void]$ev.Set()
        $ev.Close()
        Write-Log 'signalled Global\QGA_SHUTDOWN - waiting 5 s for a graceful agent exit'
        Start-Sleep -Seconds 5
    } catch {
        Write-Log 'Global\QGA_SHUTDOWN not open (no running agent, or no access) - continuing'
    }

    $s = Get-Service -Name $script:GuiWatchdogSvc -ErrorAction SilentlyContinue
    if ($s) {
        try { Stop-Service -Name $script:GuiWatchdogSvc -Force -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 20; $i++) {
            $s = Get-Service -Name $script:GuiWatchdogSvc -ErrorAction SilentlyContinue
            if (-not $s -or $s.Status -eq 'Stopped') { break }
            Start-Sleep -Seconds 1
        }
        $state = 'absent'
        if ($s) { $state = [string]$s.Status }
        Write-Log "service $script:GuiWatchdogSvc is $state"
    } else {
        Write-Log "service $script:GuiWatchdogSvc not installed"
    }

    foreach ($proc in 'gui-agent', 'gui-watchdog') {
        $ps = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
        if ($ps.Count -gt 0) {
            Write-Log "force-terminating $($ps.Count) x $proc.exe"
            $ps | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Remove-QwtLeftovers {
    param([Parameter(Mandatory)][string]$BinDir, [Parameter(Mandatory)][string[]]$Files)
    # MEASURED 2026-08-06: `msiexec /x` of the old QWT leaves gui-agent.exe on disk. A file
    # left behind is exactly what the installer's file-versioning rule then refuses to
    # overwrite, so removal here is what makes the reinstall deliver our binary.
    $deleted = @(); $stuck = @(); $absent = @()
    foreach ($f in $Files) {
        $p = Join-Path $BinDir $f
        if (-not (Test-Path -LiteralPath $p)) { $absent += $f; continue }
        for ($i = 1; $i -le 5; $i++) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; break }
            catch { Start-Sleep -Seconds 2 }
        }
        if (Test-Path -LiteralPath $p) {
            # Still locked (a process we could not kill holds the image). Renaming an open
            # image file IS allowed on Windows and gets the name out of the installer's way.
            $side = "$p.replaced-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss')
            try { Rename-Item -LiteralPath $p -NewName (Split-Path -Leaf $side) -Force -ErrorAction Stop
                  Write-Log "could not delete $f - renamed it to $(Split-Path -Leaf $side)" 'WARN'
                  $deleted += "$f (renamed)" }
            catch { Write-Log "could not delete OR rename $f - the install may not replace it" 'WARN'
                    $stuck += $f }
        } else {
            $deleted += $f
        }
    }
    Write-Log ("leftover sweep in {0}: removed [{1}] absent [{2}] stuck [{3}]" -f `
        $BinDir, ($deleted -join ' '), ($absent -join ' '), ($stuck -join ' '))
    return [ordered]@{ removed = $deleted; absent = $absent; stuck = $stuck }
}

function Get-InstalledPvDiskDriverVersion {
    # File version of the RUNNING PV disk driver, which is what an upgrade would replace.
    # TEST HOOK: QUBES_FAKE_INSTALLED_PVDISK_VERSION overrides it, so the downgrade refusal can
    # be SEEN to fire - our package and stock carry the SAME xenvbd, so a real downgrade cannot
    # be produced from the artifacts we have. Dead code unless the variable is set.
    $fake = [Environment]::GetEnvironmentVariable('QUBES_FAKE_INSTALLED_PVDISK_VERSION')
    if ($fake) {
        Write-Log "QUBES_FAKE_INSTALLED_PVDISK_VERSION=$fake - pretending that is the installed PV disk driver" 'WARN'
        return $fake
    }
    foreach ($p in "$env:WINDIR\System32\drivers\xenvbd.sys", "$env:WINDIR\System32\drivers\xen\xenvbd.sys") {
        if (Test-Path -LiteralPath $p) {
            try { return (Get-Item -LiteralPath $p).VersionInfo.FileVersion } catch { }
        }
    }
    return $null
}

function Get-PackagePvDiskDriverVersion {
    # The version of xenvbd.sys INSIDE our MSI, read from the MSI's own File table - no
    # extraction, no guessing, and it stays correct when the payload changes.
    param([Parameter(Mandatory)][string]$MsiPath)
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
                    @("SELECT FileName, Version FROM File"))
        # [void]: InvokeMember returns a value, and an unassigned return goes straight to the
        # pipeline - which made this function emit @($null, '9.1.0.0') instead of a version
        # string, and the [version] cast then failed. Caught on the guest, 2026-08-15.
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        while ($true) {
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $rec) { break }
            $name = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
            $ver  = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 2)
            # FileName is "SHORTNAME|longname" when a short name exists.
            if ($name -match 'xenvbd\.sys') { return $ver }
        }
    } catch {
        Write-Log "could not read the PV disk driver version from the MSI: $($_.Exception.Message)" 'WARN'
    }
    return $null
}

function Test-BootDiskOnPvPath {
    # TRUE when the C: boot disk is already served by the Xen PV disk path: the disk
    # reports BusType SCSI (xenvbd is a StorPort miniport; emulated IDE reports ATA) AND
    # the xenvbd service is registered boot-start (Start=0). That is the state in which
    # removing the installed QWT is dangerous - the uninstall reverts the boot disk toward
    # emulated IDE, which Windows has by then demoted from boot-start, and the intermediate
    # reboot can bugcheck 0x7B INACCESSIBLE BOOT DEVICE (reported in the field by a user
    # upgrading over stock QWT).
    #
    # HONESTY: this detection has NOT been validated against a live reproduction - that
    # needs stock QWT with the PV disk active on a test guest, which has not been run yet.
    # It is a conservative gate on a plausible-and-reported failure mode, not a proven
    # check. Defensive on purpose: any probe error returns $false with a warning, because
    # a broken probe must never block an install.
    try {
        $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
        if (-not $disk -or [string]$disk.BusType -ne 'SCSI') { return $false }
        $svc = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenvbd' `
                                -ErrorAction Stop
        return ($svc.PSObject.Properties.Name -contains 'Start' -and $svc.Start -eq 0)
    } catch {
        Write-Log "PV boot-disk probe failed ($($_.Exception.Message)) - assuming NOT on the PV path" 'WARN'
        return $false
    }
}

function Uninstall-ExistingQwt {
    param([Parameter(Mandatory)][object[]]$Products)
    # Returns $true if any uninstall demanded a reboot (rc 3010).
    $rebootNeeded = $false
    $rcs = [ordered]@{}
    foreach ($p in $Products) {
        if (-not $p.IsMsi) {
            Write-Log "'$($p.DisplayName)' key $($p.ProductCode) is not an MSI product code - not removing it" 'WARN'
            continue
        }
        $log = 'C:\qwt-uninstall.log'
        Write-Log "uninstalling '$($p.DisplayName)' $($p.Version) $($p.ProductCode) (verbose log: $log)"
        # /l*v+ appends: with more than one registered product the second msiexec would
        # otherwise truncate the log of the first, which is the one that usually explains
        # a failure.
        # Same window as the install: removing a previous QWT re-touches the PV drivers, so the
        # monitor can raise its modal prompt DURING this msiexec too. Hold it down throughout.
        $unGuard = Start-XenbusPromptSuppressor
        try {
            $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
                '/x', $p.ProductCode, '/qn', '/norestart',
                # '!' FLUSHES each line to disk instead of buffering. Without it a mid-install
                # restart loses the buffered tail - which is exactly the part that says what was
                # happening when the guest went down, and no MSI log from a failing run has ever
                # been recovered here (FINDINGS 2026-08-29, dossier gaps). Slower, and worth it.
                'REBOOT=ReallySuppress', '/l*v+!', "`"$log`""
            )
        } finally {
            Stop-XenbusPromptSuppressor $unGuard
        }
        $rc = $proc.ExitCode
        $rcs[$p.ProductCode] = $rc
        # 0    removed
        # 3010 removed, reboot required to finish deleting in-use files
        # 1605 not actually installed (a stale Uninstall key) - the state we wanted anyway
        if ($rc -notin 0, 3010, 1605) {
            Fail "msiexec /x $($p.ProductCode) failed with $rc - see $log"
        }
        Write-Log "uninstall rc=$rc"
        if ($rc -eq 3010) { $rebootNeeded = $true }
    }
    $script:Result.detail.uninstall_rc = $rcs
    return $rebootNeeded
}

# --------------------------------------------------- carrying the switches across the reboot
# The install is two stages with a reboot between them. Under -Auto the resume task carries the
# chosen switches on its own command line, but a MANUAL install carried NOTHING: stage 2 started
# from defaults, and since the IddCx driver is activated BY DEFAULT, `install.cmd /noidd` followed
# by a manual reboot installed and activated the IDD anyway - the exact opposite of the request,
# with no warning. (Stage 1's own closing message even tells the user to re-run the script bare.)
#
# So stage 1 records its switches and stage 2 restores any the caller did not pass explicitly.
# An explicit argument always wins, so changing your mind at stage 2 still works. The file lives
# beside the install log on C: - never in the payload directory, which may be a CD or an ISO.
$script:StageFlagFile = 'C:\qwt-improved-stage1.json'
$script:CarriedFlags  = @('NoIddDriver','NoPvNetwork','NoPvDisk','NoMoveUsers',
                          'AcceptPvDiskUpgrade','NoAppTweaks','NoUpdaterAgent','RebootAtEnd')

function Save-StageFlags {
    $set = @{}
    foreach ($n in $script:CarriedFlags) {
        $v = Get-Variable -Name $n -Scope Script -ValueOnly -EA SilentlyContinue
        if ($v) { $set[$n] = $true }
    }
    try {
        ($set | ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:StageFlagFile -Encoding ASCII
        $names = if ($set.Keys.Count) { ($set.Keys | Sort-Object) -join ' ' } else { '(none)' }
        Write-Log "stage-2 switches recorded in $($script:StageFlagFile): $names"
    } catch {
        Write-Log "WARNING: could not record stage-2 switches ($($_.Exception.Message)) - a manual stage 2 will use defaults"
    }
}

function Restore-StageFlags {
    param([hashtable]$Bound)
    if (-not (Test-Path -LiteralPath $script:StageFlagFile)) { return }
    try { $saved = Get-Content -LiteralPath $script:StageFlagFile -Raw | ConvertFrom-Json }
    catch { Write-Log 'stage-1 switch file is unreadable - stage 2 continues with what was passed'; return }
    $restored = @()
    foreach ($n in $script:CarriedFlags) {
        if ($Bound.ContainsKey($n)) { continue }        # explicit argument wins over the record
        if (($saved.PSObject.Properties.Name -contains $n) -and $saved.$n) {
            Set-Variable -Name $n -Value ([switch]$true) -Scope Script
            $restored += $n
        }
    }
    if ($restored.Count) { Write-Log ('stage-1 switches restored for stage 2: ' + ($restored -join ' ')) }
}

# ------------------------------------------------------------------------------- stage 1
function Invoke-Stage1 {
    param([Parameter(Mandatory)][string]$Root)

    $script:Result.stage = 'stage1-prepare'

    # Earliest possible point: a guest that ALREADY has PV drivers can raise the
    # xenbus_monitor reboot prompt during stage 1's uninstall of a previous QWT, long before
    # stage 2 runs. A stopped, disabled monitor cannot prompt (and cannot silently reboot
    # mid-uninstall either); stage 1 performs its own shutdown /r when it is actually time.
    Disable-XenbusMonitor -Why 'stage 1: before uninstall of a previous QWT' | Out-Null

    # --- certificates -------------------------------------------------------------
    # Root  : makes the self-signed publisher chain valid.
    # TrustedPublisher : stops the "install this device software?" trust prompt, which
    #                    nobody is there to click during an unattended msiexec /qn.
    [void](Import-PayloadCerts -Root $Root -Why 'stage 1')

    Set-GuiAgentRegistryDefaults

    # --- testsigning ----------------------------------------------------------------
    & bcdedit.exe /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'bcdedit /set testsigning on failed (Secure Boot enabled?)' }
    Write-Log 'testsigning enabled for the NEXT boot'

    # AUTOLOGON IS ARMED HERE, IN STAGE 1, AND NOT IN STAGE 2.
    #
    # Stage 2 resumes after a reboot from a scheduled task whose arguments are rebuilt from a
    # fixed list, so anything not in that list is lost - including the password. Carrying it
    # across would mean writing the user's password into a task command line on disk, which is a
    # worse exposure than the registry value this whole thing exists to avoid. Stage 1 has the
    # password in hand, so arm it now: the guest then comes back by itself from the install's OWN
    # reboot, which is the first moment it needs to.
    # --- autologon: the qube must be able to come back by itself ------------------------
    #
    # A Windows guest that stops at the sign-in screen is not merely inconvenient, it is GONE:
    # qrexec service calls have no session to run in, so dom0 cannot run apps in it, update it or
    # read it - and in seamless mode the sign-in screen is not displayed either, so the qube
    # window is simply empty (measured 2026-08-28: autologon off -> 0 windows mapped in dom0;
    # two field reports of exactly this). Owner decision 2026-08-28: enforce autologon.
    #
    # We cannot arm it without the account's password, so the order is: what the caller gave us,
    # then an interactive prompt, then an EMPTY password (which is correct for the many guests
    # that have no password at all - set-autologon.ps1 validates with LogonUser before writing,
    # so a wrong guess is refused rather than stranding the guest). Skipping is always reported.
    if ($NoAutologon) {
        Write-Log 'autologon SKIPPED (/noautologon) - if this account needs a password, the qube will'
        Write-Log '  come back at the sign-in screen, unreachable over qrexec and blank in dom0' 'WARN'
        $script:Result.detail.autologon = 'skipped'
    } else {
        $setal = Join-Path $Root 'set-autologon.ps1'
        if (Test-Path -LiteralPath $setal) {
            $alUser = $AutologonUser
            if (-not $alUser) {
                $cs = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
                if ($cs) { $alUser = $cs.Split('\')[-1] }
            }
            $alPass = $AutologonPassword
            $alSource = 'parameter'
            if ($null -eq $alPass) {
                $canPrompt = $false
                try { $canPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { $canPrompt = $false }
                if ($canPrompt) {
                    Write-Host ''
                    Write-Host "  Qubes needs this guest to log in by itself, or the qube comes back unusable:"
                    Write-Host "  no qrexec session, and nothing displayed in dom0 at all."
                    Write-Host "  Enter the Windows password for '$alUser' (blank = the account has none;"
                    Write-Host "  Esc or 2 minutes of silence = skip and arrange autologon yourself):"
                    Write-Host -NoNewline '  password: '
                    # BOUNDED, not Read-Host. An install is routinely launched minimised or from a
                    # script, where a console exists but nobody is watching it - and a Read-Host
                    # there hangs the whole installation for ever. Read keys with a deadline
                    # instead: no answer in 2 minutes means carry on without one.
                    try {
                        $sb = New-Object System.Text.StringBuilder
                        $deadline = (Get-Date).AddSeconds(120)
                        $answered = $false
                        while ((Get-Date) -lt $deadline) {
                            if ([Console]::KeyAvailable) {
                                $k = [Console]::ReadKey($true)
                                if ($k.Key -eq 'Enter')  { $answered = $true; break }
                                if ($k.Key -eq 'Escape') { break }
                                if ($k.Key -eq 'Backspace') {
                                    if ($sb.Length -gt 0) { $sb.Length--; Write-Host -NoNewline "`b `b" }
                                    continue
                                }
                                [void]$sb.Append($k.KeyChar)
                                Write-Host -NoNewline '*'
                            } else {
                                Start-Sleep -Milliseconds 100
                            }
                        }
                        Write-Host ''
                        if ($answered) { $alPass = $sb.ToString(); $alSource = 'prompt' }
                        else { Write-Log 'no password typed (skipped or timed out) - trying an empty one' }
                    } catch {
                        Write-Log "could not read a password from the console: $($_.Exception.Message)"
                        $alPass = $null
                    }
                }
                if ($null -eq $alPass) { $alPass = ''; $alSource = 'empty-password-guess' }
            }
            Write-Log "arming autologon for '$alUser' (password from: $alSource)"
            try {
                $alOut = & $setal -User $alUser -Password $alPass 2>&1
                foreach ($l in @($alOut | Select-Object -Last 6)) { Write-Log "  $l" }
                $tr = @($alOut) | Where-Object { $_ -match '=== RESULT === armed=(\d)' } | Select-Object -Last 1
                if ($tr -match 'armed=1') {
                    $script:Result.detail.autologon = 'armed'
                    Write-Log 'autologon armed and verified - this qube can come back on its own'
                } else {
                    $reason = if ($tr -match 'reason=([a-z-]+)') { $Matches[1] } else { 'unknown' }
                    $script:Result.detail.autologon = "not-armed:$reason"
                    Write-Log "autologon NOT armed ($reason). If this account has a password, arrange" 'WARN'
                    Write-Log '  autologon yourself (guest\set-autologon.ps1 -Password ...) or the qube will' 'WARN'
                    Write-Log '  come back at a sign-in screen that dom0 does not display in seamless mode.' 'WARN'
                }
            } catch {
                Write-Log "autologon arming failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.autologon = "error: $($_.Exception.Message)"
            } finally {
                $alPass = $null
            }
        } else {
            Write-Log 'set-autologon.ps1 not in payload - autologon not armed' 'WARN'
            $script:Result.detail.autologon = 'not in payload'
        }
    }


    $script:Result.ok = $true
    $script:Result.reboot_needed = $true
    $script:Result.detail.next = 'reboot, then stage 2 installs QWT'

    # Record the switches for stage 2 on BOTH paths. -Auto also passes them on the resume task's
    # command line (belt and braces, and those win because they arrive as explicit arguments);
    # the manual path has nothing else, and used to silently lose them.
    Save-StageFlags

    $self = Join-Path $Root 'Install-QwtImproved.ps1'
    if ($Auto) {
        $extra = @()
        if ($NoIddDriver)      { $extra += '-NoIddDriver' }
        if ($NoPvNetwork)      { $extra += '-NoPvNetwork' }
        if ($NoPvDisk)         { $extra += '-NoPvDisk' }
        if ($NoMoveUsers)      { $extra += '-NoMoveUsers' }
        if ($AcceptPvDiskUpgrade) { $extra += '-AcceptPvDiskUpgrade' }
        if ($NoAppTweaks)      { $extra += '-NoAppTweaks' }
        if ($NoUpdaterAgent)   { $extra += '-NoUpdaterAgent' }
        if ($RebootAtEnd)      { $extra += '-RebootAtEnd' }
        $extra += '-Auto'
        Set-BootResume -ScriptPath $self -ExtraArgs $extra
        Write-Log 'STAGE 1 COMPLETE - rebooting in 2 s, installation resumes automatically'
        Emit-ResultThenReboot 10
    }
    Write-Log 'STAGE 1 COMPLETE'
    Write-Log "Now REBOOT, then run again elevated:  $self"
    Write-Log 'The switches you gave stage 1 are remembered - running it bare above is correct. Passing a switch again overrides the remembered one.'
    Emit-Result 10
}

function Emit-ResultThenReboot {
    param([int]$ExitCode)
    $json = $script:Result | ConvertTo-Json -Depth 6 -Compress
    Write-Host '=== RESULT ==='
    Write-Host $json
    try { Add-Content -LiteralPath $script:LogFile -Value "=== RESULT === $json" -Encoding UTF8 } catch { }
    # This helper is reached ONLY on the -Auto (unattended) path - every caller is inside
    # `if ($Auto)`. Nobody is watching a countdown, so a 15 s dialog was pure dead wait between
    # stages. The RESULT is already flushed to the log above, so reboot near-immediately; a 2 s
    # margin just lets this process exit cleanly before the machine goes down.
    & shutdown.exe /r /t 2 /c 'Qubes Windows Tools setup' | Out-Null
    exit $ExitCode
}

# --------------------------------------------------------------------- IDD device lookup
function Get-IddPnpDevice {
    param([Parameter(Mandatory)][string]$HardwareId)
    # Win32_PnPEntity rather than Get-PnpDevice: ConfigManagerErrorCode is a first-class
    # property there, and the bind poll below is exactly a wait for it to reach 0.
    return (Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareID -and (@($_.HardwareID) -contains $HardwareId) } |
        Select-Object -First 1)
}

# ------------------------------------------------------------------------------- stage 2
function Invoke-Stage2 {
    param([Parameter(Mandatory)][string]$Root)

    $script:Result.stage = 'stage2-install'

    # If we got here from the -Auto boot task, retire it first: a task left armed would
    # re-run the whole install on every subsequent boot.
    Clear-BootResume

    # Certs again: stage 1 may have run from the CD in a previous boot, and re-adding is
    # idempotent. Cheap insurance against a half-prepared machine - and NOT optional: on a guest
    # that arrives with testsigning already on, stage 2 is the ONLY stage that runs, so this is
    # the single point at which the driver publishers become trusted before msiexec installs
    # them. That is the path the 2026-08-29 hang was found on.
    [void](Import-PayloadCerts -Root $Root -Why 'stage 2, before msiexec')

    # --- remove any previously installed QWT ----------------------------------------
    # Rationale in the file header. Without this the MSI reports success while silently
    # keeping the old gui-agent.exe (measured 2026-08-06).
    $binDir = Get-QwtBinDir
    $deliver = @($script:OurBinaries)
    $mfPath = Join-Path $Root 'MANIFEST.json'
    if (Test-Path -LiteralPath $mfPath) {
        $mfj = Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json
        if ($mfj.PSObject.Properties.Name -contains 'reference_binaries' -and $mfj.reference_binaries) {
            $names = @($mfj.reference_binaries.PSObject.Properties.Name)
            if ($names.Count -gt 0) { $deliver = $names }
        }
    }
    $script:Result.detail.bin_dir = $binDir
    $script:Result.detail.leftovers_targeted = $deliver

    # Probe once per stage-2 run and always record it, so the trailer says which disk
    # path the upgrade decision below was made on.
    $pvBoot = Test-BootDiskOnPvPath
    $script:Result.detail.pv_boot_disk = $pvBoot
    Write-Log "PV boot-disk probe: C: on the PV path = $pvBoot"

    if ($ResumeAfterUninstall) {
        # Resumed by the boot task armed below: the previous QWT is already gone, so the
        # detect/uninstall phase is skipped and this run goes straight to the install.
        Write-Log 'resumed after the uninstall reboot - skipping detection, proceeding to install'
        $script:Result.detail.existing_qwt = 'removed before the reboot this run resumed from'
    } else {
        $existing = @(Get-InstalledQwt)
        $script:Result.detail.existing_qwt = @($existing | ForEach-Object {
            '{0} {1} {2}' -f $_.DisplayName, $_.Version, $_.ProductCode })
        if ($existing.Count -eq 0) {
            Write-Log 'no previously installed Qubes Windows Tools found - clean install path'
        } else {
            foreach ($e in $existing) {
                Write-Log "found existing QWT: '$($e.DisplayName)' $($e.Version) $($e.ProductCode)"
            }

            # IN-PLACE MSI MAJOR UPGRADE - the normal path since the 4.3.0 version bump.
            # The rebuilt MSI shares stock's UpgradeCode ({14BCB82F-...}) and carries a
            # HIGHER ProductVersion, and the WiX package declares <MajorUpgrade>, so
            # installing it over any OLDER QWT lets Windows Installer replace the old
            # product inside one transaction: no separate uninstall, no intermediate
            # reboot, and the PV disk driver is upgraded rather than ripped out - which
            # removes the 0x7B INACCESSIBLE BOOT DEVICE window entirely (reproduced
            # 2026-08-10: the uninstall-first flow bricked a PV-booted guest; under Qubes
            # the bugcheck destroys the domain, so there is no in-guest recovery).
            # The uninstall-first flow below survives ONLY for the cases a major upgrade
            # cannot handle: an installed version equal to or newer than ours.
            # In-place is safe for installed <= ours: a strictly-older version is a MajorUpgrade,
            # and an EQUAL version is a same-version reinstall/repair (msiexec /i REINSTALL=ALL).
            # Neither uninstalls anything, so neither can revert the boot disk toward emulated IDE
            # - the 0x7B hazard the PV gate below guards. ONLY a genuine downgrade (installed
            # STRICTLY newer than ours) needs the uninstall-first flow, because MajorUpgrade will
            # not remove a newer product. Treating same-version as uninstall-first is what made a
            # plain re-run (e.g. to pick up the now-default IDD driver) hit the PV gate and hard-fail.
            $inPlace = $false
            $script:SameVersionReinstall = $false
            try {
                # Normalize to MAJOR.MINOR.BUILD before comparing. The MSI registers a 4-field
                # DisplayVersion (e.g. 4.3.1.0) while package_version is 3-field (4.3.1), and .NET
                # ranks [version]'4.3.1.0' ABOVE [version]'4.3.1' (unspecified Revision -1 < 0). So
                # an EQUAL build read as "installed is NEWER than ours" and fell to uninstall-first
                # -> the PV gate -> hard fail. Windows Installer itself compares only the first
                # three fields, so we must too. (Caught by the E2E same-version reinstall test,
                # 2026-08-11 - the 4.3.0->4.3.1 upgrade passed only because that is a real diff.)
                $oursStr = "$($script:Result.detail.package_version)" -split '\+' | Select-Object -First 1
                $ov = [version]$oursStr
                $ours = [version]::new($ov.Major, $ov.Minor, [math]::Max([int]$ov.Build, 0))
                $olds = @($existing | ForEach-Object {
                    $iv = [version]$_.Version
                    [version]::new($iv.Major, $iv.Minor, [math]::Max([int]$iv.Build, 0)) })
                if ($olds.Count -gt 0 -and @($olds | Where-Object { $_ -gt $ours }).Count -eq 0) {
                    $inPlace = $true
                    $script:SameVersionReinstall = @($olds | Where-Object { $_ -eq $ours }).Count -gt 0
                }
            } catch {
                Write-Log "version comparison failed ($($_.Exception.Message)) - falling back to the uninstall-first flow" 'WARN'
            }
            # THE PV DISK DRIVER ONLY GOES UP, OR STAYS THE SAME.
            # An in-place upgrade is safe precisely because it does not disturb the disk driver
            # serving C: - our MSI is rebuilt from the same upstream sources, so it carries the
            # same xenvbd. If a package ever carried an OLDER disk driver, Windows Installer
            # would have to remove the newer one to put the older one back, and that is the
            # operation measured on 2026-08-15 to leave the guest with no boot disk at all
            # (0x7B, unrecoverable from inside: the PV drivers unplug the emulated disk).
            # So a disk-driver DOWNGRADE is refused here, before anything is touched. Downgrading
            # deliberately means uninstalling QWT properly first, from a guest that can still
            # boot without it - not something this installer can do safely in one pass.
            $pkgVbd = Get-PackagePvDiskDriverVersion -MsiPath (Join-Path $Root 'msi\installer.msi')
            $insVbd = Get-InstalledPvDiskDriverVersion
            $script:Result.detail.pvdisk_driver_installed = $insVbd
            $script:Result.detail.pvdisk_driver_package   = $pkgVbd
            if ($insVbd -and $pkgVbd) {
                try {
                    $iv = [version]($insVbd -replace '[^0-9.].*$', '')
                    $pv = [version]($pkgVbd -replace '[^0-9.].*$', '')
                    Write-Log "PV disk driver: installed $iv, package $pv"
                    if ($pv -lt $iv) {
                        Fail ("REFUSING: this package carries an OLDER Xen PV disk driver " +
                              "($pv) than the one already running ($iv). Installing it would have to " +
                              'remove the newer disk driver to put the older one back, and on a guest ' +
                              'whose boot disk is on the PV path that leaves NO boot disk at all - ' +
                              'measured 0x7B INACCESSIBLE BOOT DEVICE, not recoverable from inside the ' +
                              'guest, because the PV drivers unplug the emulated disk. The PV disk ' +
                              'driver only goes UP or stays the SAME. To go back deliberately, ' +
                              'uninstall Qubes Windows Tools first on a guest that can still boot ' +
                              'without it, then install the older package.')
                    }
                } catch {
                    Write-Log "PV disk driver version comparison failed ($($_.Exception.Message)) - continuing" 'WARN'
                }
            } else {
                Write-Log "PV disk driver version unknown (installed='$insVbd' package='$pkgVbd') - no downgrade check possible" 'WARN'
            }

            $script:Result.detail.upgrade_mode =
                if ($inPlace -and $script:SameVersionReinstall) { 'in-place-same-version-reinstall' }
                elseif ($inPlace) { 'in-place-msi-major-upgrade' }
                else { 'uninstall-first' }

            if ($inPlace) {
                if ($script:SameVersionReinstall) {
                    Write-Log ("installed QWT (" + (($existing | ForEach-Object { $_.Version }) -join ', ') +
                               ") is the SAME version as this package ($oursStr) - IN-PLACE reinstall/repair " +
                               "(REINSTALL=ALL), no uninstall, no intermediate reboot")
                } else {
                    Write-Log ("installed QWT (" + (($existing | ForEach-Object { $_.Version }) -join ', ') +
                               ") is older than this package ($oursStr) - IN-PLACE MSI major upgrade, no uninstall, no intermediate reboot")
                }
                Stop-QwtRuntime   # the agent holds files the MSI is about to replace
                # Fall through to the install phase below - msiexec /i does the rest.
            } else {

            if ($pvBoot) {
                # HARD REFUSAL. This used to be an overridable warning, and /AcceptPvDiskUpgrade
                # let a user proceed. It is not overridable any more, because the failure it
                # guards against was reproduced on 2026-08-15 and NO recovery performed from
                # inside the guest could undo it:
                #
                #   The Xen PV drivers UNPLUG the emulated disk. A healthy guest in this state
                #   has exactly ONE disk (XENSRC PVDISK) - the IDE controller is still there
                #   with nothing behind it. Remove the PV disk driver and the next boot has no
                #   disk AT ALL, which is 0x7B, and under Qubes the qube is destroyed at the
                #   bugcheck. Measured: domain destroyed within ~50 s, twice. Re-arming the
                #   inbox ATA drivers does not help (nothing to bind to). Un-masking XENFILT's
                #   IDE channel, or taking the whole Xen bus stack out of the boot path, gets
                #   as far as Windows Automatic Repair - a disk is visible again - but not to a
                #   normal boot. Safe mode is why the field recovery works: it loads none of
                #   these drivers, so nothing unplugs the emulated disk.
                #
                # An installer must not offer a switch whose failure mode it cannot undo. The
                # supported path is the IN-PLACE major upgrade taken above, which never removes
                # the PV disk driver - and that needs a package whose version is HIGHER than the
                # installed one. That is exactly the invariant tools/cut-release.sh enforces,
                # and the reason 4.3.0/4.3.1 (both stamped MSI ProductVersion 4.3.0) could not
                # take it and had to remove first.
                Fail ('REFUSING to remove the installed QWT: the C: boot disk is served by the Xen ' +
                      'PV disk driver (BusType SCSI, xenvbd boot-start), and the PV drivers have ' +
                      'unplugged the emulated disk - so removing them leaves this guest with NO ' +
                      'boot disk and it will bugcheck 0x7B INACCESSIBLE BOOT DEVICE. Measured, and ' +
                      'not recoverable from inside the guest. ' +
                      "Install a package whose version is HIGHER than the installed $($existing[0].Version) " +
                      'instead: a version-bumped package upgrades in place, never removes the PV disk ' +
                      'driver, and is the supported upgrade path. ' +
                      '(/acceptpvdiskupgrade no longer overrides this - see UPGRADING FROM STOCK QWT ' +
                      'in README.txt.)')
            }
            Stop-QwtRuntime
            $needReboot = Uninstall-ExistingQwt -Products $existing
            # Only products we actually tried to remove count here: a non-MSI Uninstall key
            # is logged and skipped above, and must not turn into a hard failure.
            $tried = @($existing | Where-Object { $_.IsMsi } | ForEach-Object { $_.ProductCode })
            $still = @(Get-InstalledQwt | Where-Object { $tried -contains $_.ProductCode })
            if ($still.Count -gt 0 -and -not $needReboot) {
                Fail ("msiexec /x reported success but these products are still registered: " +
                      (($still | ForEach-Object { $_.ProductCode }) -join ' '))
            }

            if ($needReboot) {
                # Cross-reboot continuation, reusing the SAME -Auto boot-resume task as
                # stage 1 (Set-BootResume/Clear-BootResume) with -ResumeAfterUninstall
                # added, so the resumed run re-enters stage 2 and skips straight to the
                # install. Nothing re-arms the task in the resumed run, so at most one
                # uninstall reboot can ever happen. Without -Auto the exit code is 10,
                # which install.cmd already reports as "reboot, then run me again"; that
                # re-run finds nothing registered and takes the clean path.
                # The leftover sweep is deliberately left for AFTER the reboot: the reboot
                # is exactly when a file that was locked stops being locked.
                $script:Result.stage = 'stage2-uninstall-reboot'
                $script:Result.ok = $true
                $script:Result.reboot_needed = $true
                $script:Result.detail.next = 'reboot, then the install phase runs'
                if ($pvBoot) {
                    # /AcceptPvDiskUpgrade was passed (the gate above stops here otherwise).
                    #
                    # RE-ARM THE EMULATED STORAGE STACK before the risky reboot. Removing
                    # QWT reverts the boot disk toward emulated IDE, but Windows demoted
                    # those drivers from boot-start when xenvbd took over, so the next boot
                    # bugchecks 0x7B. Reproduced 2026-08-10 on a clean stock guest: without
                    # this, the guest became UNBOOTABLE, and under Qubes the domain is
                    # DESTROYED at the instant of the bugcheck (on_crash=destroy) - Windows
                    # never gets to count failed boots, so the advertised auto-recovery
                    # menu may never appear at all. Setting Start=0 (boot) on the emulated
                    # controller drivers is exactly the state a Safe Mode boot restores;
                    # doing it NOW makes the intermediate boot succeed on IDE directly.
                    # Boot-start drivers whose hardware is absent are simply not started,
                    # so the extra entries are harmless on any disk layout.
                    foreach ($svc in 'atapi', 'intelide', 'pciide', 'storahci') {
                        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                        if (Test-Path -LiteralPath $k) {
                            try {
                                $old = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).Start
                                Set-ItemProperty -LiteralPath $k -Name Start -Value 0 -Type DWord -ErrorAction Stop
                                Write-Log "re-armed emulated storage driver ${svc}: Start $old -> 0 (boot)"
                            } catch {
                                Write-Log "could not re-arm ${svc}: $($_.Exception.Message)" 'WARN'
                            }
                        }
                    }
                    $script:Result.detail.emulated_storage_rearmed = $true
                    # Recovery recipe on screen AND in C:\qwt-improved-install.log NOW - if
                    # the coming reboot still bugchecks 0x7B, this is the last chance.
                    foreach ($l in @(
                        'PV BOOT DISK: the coming reboot may bugcheck 0x7B INACCESSIBLE BOOT DEVICE. If it does:',
                        '  1. start the qube again after each crash (under Qubes each bugcheck HALTS the qube;',
                        '     it will not loop by itself) - after ~3 failed boots Windows may offer advanced startup',
                        '  2. Startup Settings -> Restart -> pick Safe Mode (option number varies by locale; 4 on many)',
                        '  3. one Safe Mode boot is enough - then reboot normally',
                        '  4. run install.cmd again to finish the install',
                        '  If the recovery menu never appears (the qube dies instantly on every start), the guest',
                        '  needs offline repair (attach the disk to another qube, load the SYSTEM hive, set',
                        '  Services\atapi, intelide, pciide, storahci Start=0) - or a reinstall.'
                    )) { Write-Log $l 'WARN' }
                }
                $self = Join-Path $Root 'Install-QwtImproved.ps1'
                if ($Auto) {
                    $extra = @()
                    if ($NoIddDriver)      { $extra += '-NoIddDriver' }
                    if ($NoPvNetwork)      { $extra += '-NoPvNetwork' }
                    if ($NoPvDisk)         { $extra += '-NoPvDisk' }
                    if ($NoMoveUsers)      { $extra += '-NoMoveUsers' }
                    if ($AcceptPvDiskUpgrade) { $extra += '-AcceptPvDiskUpgrade' }
                    if ($NoAppTweaks)      { $extra += '-NoAppTweaks' }
                    if ($NoUpdaterAgent)   { $extra += '-NoUpdaterAgent' }
                    if ($RebootAtEnd)      { $extra += '-RebootAtEnd' }
                    $extra += '-Auto'
                    $extra += '-ResumeAfterUninstall'
                    Set-BootResume -ScriptPath $self -ExtraArgs $extra
                    Write-Log 'removing the previous QWT requires a reboot - rebooting in 2 s, the install resumes automatically'
                    Emit-ResultThenReboot 10
                }
                Write-Log 'removing the previous QWT requires a reboot'
                Write-Log "REBOOT NOW, then run again elevated:  $self"
                Emit-Result 10
            }
            } # end uninstall-first branch; the in-place upgrade path falls through to install
        }
    }

    # Always, on every path that reaches the install: nothing of ours may be running and
    # none of the files we are about to deliver may still be on disk. A guest where QWT
    # was uninstalled by hand has no registration left but DOES keep the old binaries
    # (measured), and that alone is enough to make Windows Installer skip them.
    Stop-QwtRuntime
    $script:Result.detail.leftover_sweep = Remove-QwtLeftovers -BinDir $binDir -Files $deliver
    # The uninstall takes HKLM\Software\Invisible Things Lab\Qubes Tools with it, so the
    # seeded gui-agent defaults have to be rewritten before the MSI's AppSearch runs.
    Set-GuiAgentRegistryDefaults

    # --- VC++ runtime (the Burn bundle's prerequisite package) ----------------------
    $vc = Join-Path $Root 'msi\vc_redist.x64.exe'
    Write-Log 'installing vc_redist.x64.exe'
    $p = Start-Process -FilePath $vc -ArgumentList '/quiet', '/norestart' -Wait -PassThru
    # 1638 = a newer runtime is already present.
    if ($p.ExitCode -notin 0, 3010, 1638) { Fail "vc_redist.x64.exe failed with $($p.ExitCode)" }
    Write-Log "vc_redist rc=$($p.ExitCode)"
    $script:Result.detail.vc_redist_rc = $p.ExitCode

    # --- Qubes Windows Tools --------------------------------------------------------
    #   PvDriversCore     xenbus + xeniface -> gnttab/vchan. REQUIRED by the GUI agent.
    #   Core              qubesdb, qrexec agent, file/clipboard handlers.
    #   Gui               gui-agent.exe + QubesGuiWatchdog service (OUR build).
    #   PvDriversNetwork  xenvif/xennet. Included by default; see README NETWORKING.
    #   PvDriversDisk     xenvbd/xendisk/xencrsh. Moves the boot disk off emulated IDE.
    #
    # PvDriversDisk was omitted in 24a1ded for a "documented BSOD risk". That claim had NO
    # source: upstream's own feature description is "Xen PV disk drivers for increased
    # performance" (Package.en-us.wxl:32), no Level attribute is set on any feature in
    # Package.wxs, and WiX defaults Level=1 - so STOCK QWT 4.2.2 INSTALLS THIS BY DEFAULT.
    # Omitting it left every guest on emulated IDE, i.e. a performance regression against
    # stock that we shipped. Measured 2026-08-07 on win10-clean: the feature-add binds
    # (XENBUS\...&DEV_VBD err=0 svc=xenvbd), the guest reboots cleanly, and all disks move
    # from BusType=ATA to BusType=SCSI. No bugcheck.
    # Keep this list identical to stock's default set except where we have a MEASURED reason.
    #   MoveUsers         relocates C:\Users to Q:\Users on the Qubes PRIVATE image.
    # MoveUsers was omitted until 2026-08-07. Stock installs it, and omitting it put ALL user
    # data on the ROOT volume, which breaks the Qubes root/private split: private is the
    # volume Qubes treats as user data (backups, and `qvm-volume revert` of root would
    # otherwise destroy the profile). It is BOOT-CRITICAL - it registers relocate-dir.exe
    # under Session Manager!BootExecute - so it was tested on a throwaway guest before being
    # enabled here. /nousers is the escape hatch if a guest ever fails to boot after it.
    $features = @('PvDriversCore', 'Core', 'Gui')
    if (-not $NoPvNetwork) { $features += 'PvDriversNetwork' }
    if (-not $NoPvDisk)    { $features += 'PvDriversDisk' }
    if (-not $NoMoveUsers) { $features += 'MoveUsers' }
    $addlocal = $features -join ','

    $msi = Join-Path $Root 'msi\installer.msi'
    $msiLog = 'C:\qwt-install.log'
    # REINSTALLMODE=amus is a SECOND, independent guard against the same defect the
    # uninstall-first phase above addresses: 'a' means "copy all files regardless of
    # version", i.e. it disables exactly the file-versioning rule that kept the old
    # gui-agent.exe. Both are present on purpose - the uninstall can be defeated by a
    # product that refuses to remove itself or by a file we could not delete, and
    # REINSTALLMODE only takes effect on paths where Windows Installer consults it. If
    # either mechanism works, our agent lands; the hash check below decides.
    # REINSTALL=ALL matters ONLY for re-running the IDENTICAL build already installed: the WiX
    # package uses ProductCode="*" (a fresh GUID every build, Package.wxs:12), so REINSTALL - which
    # keys on a MATCHING installed ProductCode - can only repair the very same build. It does
    # NOTHING for a DIFFERENT build stamped the same ProductVersion: that build's ProductCode
    # differs (no product to reinstall), and MajorUpgrade (AllowSameVersionUpgrades defaults off,
    # Package.wxs:15) will not remove an equal-version product either. The SUPPORTED way to land a
    # new release over an existing one is a real version bump (agent/version, third field), which
    # makes it an honest MajorUpgrade. This branch only stops an identical-build re-run from
    # hard-failing at the PV gate; shipping two releases at one version is prevented upstream, at
    # build time, not patched over here.
    $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', "ADDLOCAL=$addlocal")
    if ($script:SameVersionReinstall) { $msiArgs += 'REINSTALL=ALL' }
    # '/l*v!' - the '!' flushes every line to disk rather than buffering it. This is the install
    # that reboots the guest mid-flight when it goes wrong, so the buffered tail is precisely the
    # evidence that has never survived: the dossier records that NO MSI verbose log from any failing
    # run was ever captured. Unbuffered logging is the difference between diagnosing the brick and
    # guessing at it again.
    $msiArgs += @('REBOOT=ReallySuppress', 'REINSTALLMODE=amus', 'MSIFASTINSTALL=7', '/l*v!', "`"$msiLog`"")
    Write-Log "running msiexec ADDLOCAL=$addlocal REINSTALL=$(if($script:SameVersionReinstall){'ALL'}else{'(none)'}) (verbose log: $msiLog)"
    # BEFORE msiexec, not after. The running xenbus_monitor pops its modal Yes/No the moment a
    # PV driver install asks for a reboot - i.e. DURING this msiexec. Observed live on
    # 2026-08-14: the dialog was sitting on the dom0 desktop mid-install, which is the field
    # report in forum 42717 post 33 ("the PV disk driver installer prompt is not clickable").
    # A monitor that is stopped and disabled before msiexec starts can never show it.
    Disable-XenbusMonitor -Why 'before msiexec'

    # RE-ARM THE INBOX STORAGE DRIVERS before the MSI touches the PV disk driver.
    # MEASURED 2026-08-15, upgrading a genuine stock QWT 4.2.2 guest to this package: the boot
    # disk moves OFF the PV path during the upgrade - bus=SCSI model=PVDISK before, bus=ATA
    # model="QEMU HARDDISK" on the boot straight after - and only returns to PV on the boot
    # after that. Whether that intermediate boot survives depends entirely on whether Windows
    # still has a boot-start inbox ATA driver. On our test image atapi/intelide/pciide were all
    # still Start=0 and it booted fine; on a guest where Windows has demoted them (they are
    # unused once the PV path takes over) the same transition is bugcheck 0x7B
    # INACCESSIBLE_BOOT_DEVICE, recoverable only through safe mode - which is exactly the field
    # report in forum 42717 post 27.
    # Setting them boot-start costs nothing when the hardware is absent, so this makes the
    # outcome independent of the guest's servicing history instead of a coin toss.
    # NOTE: the uninstall path re-arms the same drivers inline (search
    # emulated_storage_rearmed) - that one covers the remove-then-install upgrade, this one
    # covers the IN-PLACE major upgrade, which is the path a version-bumped MSI actually takes
    # and where the disk was measured leaving the PV path. Both are cheap and idempotent.
    $rearm = Join-Path $Root 'rearm-inbox-disk-controllers.ps1'
    if (Test-Path -LiteralPath $rearm) {
        try {
            $out = & $rearm 2>&1
            foreach ($l in @($out | Select-Object -Last 2)) { Write-Log "  rearm: $l" }
            $script:Result.detail.inbox_disk_rearm = 'done'
        } catch {
            Write-Log "inbox storage re-arm failed: $($_.Exception.Message) (continuing)" 'WARN'
            $script:Result.detail.inbox_disk_rearm = "failed: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'rearm-inbox-disk-controllers.ps1 not in payload - the intermediate boot relies on whatever Windows left boot-start' 'WARN'
        $script:Result.detail.inbox_disk_rearm = 'not shipped'
    }

    # The prompt appears INSIDE this call - see Start-XenbusPromptSuppressor.
    $promptGuard = Start-XenbusPromptSuppressor
    try {
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList $msiArgs
    } finally {
        Stop-XenbusPromptSuppressor $promptGuard
    }
    if ($p.ExitCode -notin 0, 3010) { Fail "msiexec failed with $($p.ExitCode) - see $msiLog" }
    Write-Log "QWT_INSTALL_OK rc=$($p.ExitCode)"
    $script:Result.detail.msiexec_rc = $p.ExitCode
    $script:Result.detail.addlocal = $addlocal

    # Re-assert AFTER the install too: the MSI lays the service down fresh (auto-start, new
    # service key), losing both the disable and the AutoReboot value written before it.
    Disable-XenbusMonitor -Why 'after msiexec: MSI re-registered the service'

    # --- prove the install put OUR agent on disk ------------------------------------
    # Without this the script would report success for an install that silently kept a
    # previously present stock binary.
    $installed = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
    if (-not (Test-Path -LiteralPath $installed)) {
        # SAME-VERSION REINSTALL RECOVERY (measured 2026-08-29 on win10-clean, 4.3.15 over 4.3.15).
        #
        # REINSTALL=ALL acts ONLY on features Windows Installer records as already installed. If a
        # feature is recorded Absent it is skipped outright - the MSI log says it plainly:
        #     Feature: Gui;  Installed: Absent;  Request: Null;  Action: Null
        # and ADDLOCAL is overridden while REINSTALL is present, so msiexec exits 0 having installed
        # nothing. Combined with the leftover sweep above - which deliberately DELETES gui-agent.exe
        # and gui-watchdog.exe before msiexec runs - the guest is left with no agent at all and a
        # "successful" install. This check caught it; that is what it is for.
        #
        # Recovery: re-run WITHOUT REINSTALL. With no REINSTALL property, ADDLOCAL is honoured and an
        # Absent feature is installed normally. Bounded to ONE retry, and the same existence test
        # decides afterwards - a retry that does not produce the binary still Fails.
        if ($script:SameVersionReinstall) {
            Write-Log ("gui-agent.exe absent after REINSTALL=ALL - the MSI records a feature as " +
                       "Absent, which REINSTALL skips. Retrying ONCE with ADDLOCAL only.") 'WARN'
            $retryArgs = @('/i', "`"$msi`"", '/qn', '/norestart', "ADDLOCAL=$addlocal",
                           'REBOOT=ReallySuppress', 'REINSTALLMODE=amus', 'MSIFASTINSTALL=7',
                           '/l*v+!', "`"$msiLog`"")
            $rp = Start-Process msiexec.exe -Wait -PassThru -ArgumentList $retryArgs
            Write-Log "  ADDLOCAL-only retry exit=$($rp.ExitCode)"
            $script:Result.detail.same_version_addlocal_retry = $rp.ExitCode
        }
        if (-not (Test-Path -LiteralPath $installed)) {
            Fail "msiexec reported success but $installed does not exist"
        }
        Write-Log 'gui-agent.exe recovered by the ADDLOCAL-only retry'
    }
    $haveHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
    $wantHash = $null
    $mf = Join-Path $Root 'MANIFEST.json'
    if (Test-Path -LiteralPath $mf) {
        $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
        if ($m.PSObject.Properties.Name -contains 'reference_binaries') {
            $wantHash = $m.reference_binaries.'gui-agent.exe'
        }
    }
    $script:Result.detail.installed_gui_agent_sha256 = $haveHash
    if ($wantHash) {
        $script:Result.detail.expected_gui_agent_sha256 = $wantHash
        if ($haveHash -ne $wantHash.ToLowerInvariant()) {
            Fail "installed gui-agent.exe is $haveHash but the package was built with $wantHash - the MSI did not deliver our agent"
        }
        Write-Log "installed gui-agent.exe matches the package manifest ($haveHash)"
    } else {
        Write-Log 'MANIFEST.json has no reference_binaries - cannot verify the installed agent' 'WARN'
        $script:Result.detail.agent_hash_verified = $false
    }

    # --- Start Menu qube-app shortcut: NOT INSTALLED (see docs/PLAN-start-menu.md) ------
    # The agent does not present the Start menu in seamless mode (user decision
    # 2026-08-13): on 25H2 it never rendered acceptably through the seamless path. A
    # 'Start Menu' entry in the qube's application menu would therefore appear to do
    # nothing, which is worse than no entry at all. Remove any entry an earlier build
    # published; the opener script itself is left in place under guest/ for whoever
    # restores the capability (agent knob SeamlessStart=1).
    Remove-Item -LiteralPath 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Start Menu.lnk' -Force -ErrorAction SilentlyContinue
    Write-Log 'Start Menu appmenu shortcut intentionally NOT installed (Start is hidden in seamless mode)'
    $script:Result.detail.start_menu_shortcut = 'not-installed-by-design'

    # --- netvm hotplug: re-apply Qubes addressing when an interface appears ----------
    # QWT applies the qubesdb-driven static IP with network-setup.exe at BOOT, and nothing
    # re-runs it when a vif is hot-plugged, so `qvm-prefs <vm> netvm <net>` on a running
    # guest leaves it on APIPA (169.254.*) with no gateway until a reboot (measured
    # 2026-08-07). This registers a SYSTEM task triggered by NetworkProfile event 10000
    # ("network connected"), which fires on vif arrival. VERIFIED end to end: detach ->
    # attach restored 10.137.0.70 by itself within 15 s, no manual step, no reboot.
    $netExe = 'C:\Program Files\Qubes Tools\bin\network-setup.exe'
    if (Test-Path -LiteralPath $netExe) {
        $taskXml = Join-Path $env:TEMP 'qubes-netreapply.xml'
        $sub = '&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;' +
               '&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]' +
               '&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
        $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Re-apply Qubes network config when an interface appears</Description></RegistrationInfo>
  <Triggers><EventTrigger><Enabled>true</Enabled><Subscription>$sub</Subscription><Delay>PT3S</Delay></EventTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT2M</ExecutionTimeLimit><AllowHardTerminate>true</AllowHardTerminate></Settings>
  <Actions Context="Author"><Exec><Command>"$netExe"</Command></Exec></Actions>
</Task>
"@
        [IO.File]::WriteAllText($taskXml, $xml, [Text.Encoding]::Unicode)
        try { $out = & schtasks /create /tn QubesNetworkReapply /xml $taskXml /f 2>&1 } catch { $out = "$_" }
        Remove-Item $taskXml -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'registered QubesNetworkReapply (netvm hotplug re-applies addressing automatically)'
            $script:Result.detail.net_reapply_task = 'registered'
        } else {
            Write-Log "could not register QubesNetworkReapply ($LASTEXITCODE) - netvm hotplug will need network-setup.exe by hand" 'WARN'
            $script:Result.detail.net_reapply_task = "failed rc=$LASTEXITCODE"
        }
    }

    # --- PV network fix: xenvif that can actually bind xennet -----------------------
    # SHIPPED BY DEFAULT (not optional): QWT 4.2.2's own xenvif tops out at VIF interface
    # REV_09000004 while its xennet requires REV_09000005, so the XENVIF NET child can
    # never bind and Windows falls back to the QEMU-emulated Realtek NIC. Measured on a
    # clean Qubes 4.3 guest 2026-08-07; stock QWT is affected identically (our PV binaries
    # are byte-identical to stock's). Upstream added rev 5 in xenvif 4608bc1 "Use UNPLUG
    # v3"; we build xenvif from xenbits master and install it here, AFTER the MSI, so it
    # upgrades the one the MSI just laid down.
    # Proven on win10-clean: Realtek RTL8139C+ -> Xen PV Network Device #0, gateway
    # reachable.
    $pvDir = Join-Path $Root 'pv-drivers'
    $pvInf = Join-Path $pvDir 'xenvif.inf'
    if (Test-Path -LiteralPath $pvInf) {
        # Trust the signer FIRST: testsigning permits self-signed drivers, but an untrusted
        # publisher fails the driver-store add with 0xE0000247 (measured, same day).
        $pvCer = Join-Path $pvDir 'xenvif-signer.cer'
        if (Test-Path -LiteralPath $pvCer) {
            foreach ($store in 'Root', 'TrustedPublisher') {
                try { $out = & certutil.exe -addstore -f $store $pvCer 2>&1 } catch { $out = "$_" }
                Write-Log "  certutil ${store}: rc=$LASTEXITCODE"
            }
        } else {
            Write-Log 'pv-drivers/xenvif-signer.cer missing - the driver store add will likely fail' 'WARN'
        }
        Write-Log 'installing xenvif (PV network interface fix)'
        try { $out = & pnputil.exe /add-driver $pvInf /install 2>&1 } catch { $out = "$_" }
        $out | ForEach-Object { Write-Log "  pnputil(xenvif): $_" }
        # 259 = no more items (nothing to do); 3010 = success, reboot required - stage 2
        # always reboots. Anything else is a real failure, but NOT fatal to the install:
        # the guest still works on the emulated NIC, which is the pre-fix status quo.
        if ($LASTEXITCODE -notin 0, 259, 3010) {
            Write-Log "xenvif install returned $LASTEXITCODE - PV networking may stay on the emulated NIC" 'WARN'
            $script:Result.detail.pv_xenvif = "failed rc=$LASTEXITCODE"
        } else {
            Write-Log 'xenvif installed - the emulated NIC should be unplugged after the reboot'
            $script:Result.detail.pv_xenvif = 'installed'
        }
    } else {
        Write-Log 'pv-drivers/xenvif.inf not in the payload - PV networking will use the emulated NIC' 'WARN'
        $script:Result.detail.pv_xenvif = 'not shipped'
    }

    # --- PV console: an out-of-band channel for diagnosing a wedged guest ------------
    # QWT vendors no xencons, so XENBUS\VEN_XP0001&DEV_CONS has always sat at CM code 28.
    # Installing it gives dom0 `xl console` into the guest. This is DIAGNOSTIC only -
    # nothing in QWT binds to it and no feature depends on it - so every failure below is a
    # warning, never fatal: losing a diagnostic must not fail a working install.
    #
    # Why it is worth shipping in a release rather than side-loading when needed: the wedge
    # takes qrexec with it, and a guest with no qrexec cannot be given a driver afterwards.
    # An instrument that must be installed before the failure is only useful if it is
    # already there.
    $consInf = Join-Path $pvDir 'xencons.inf'
    if (Test-Path -LiteralPath $consInf) {
        $consCer = Join-Path $pvDir 'xencons-signer.cer'
        if (Test-Path -LiteralPath $consCer) {
            foreach ($store in 'Root', 'TrustedPublisher') {
                try { $out = & certutil.exe -addstore -f $store $consCer 2>&1 } catch { $out = "$_" }
                Write-Log "  certutil ${store} (xencons): rc=$LASTEXITCODE"
            }
        } else {
            Write-Log 'pv-drivers/xencons-signer.cer missing - the xencons store add will likely fail' 'WARN'
        }
        Write-Log 'installing xencons (PV console - diagnostic channel)'
        try { $out = & pnputil.exe /add-driver $consInf /install 2>&1 } catch { $out = "$_" }
        $out | ForEach-Object { Write-Log "  pnputil(xencons): $_" }
        if ($LASTEXITCODE -notin 0, 259, 3010) {
            Write-Log "xencons install returned $LASTEXITCODE - DEV_CONS stays at code 28, no out-of-band channel" 'WARN'
            $script:Result.detail.pv_xencons = "failed rc=$LASTEXITCODE"
        } else {
            Write-Log 'xencons installed - DEV_CONS should bind after the reboot'
            $script:Result.detail.pv_xencons = 'installed'
        }
    } else {
        Write-Log 'pv-drivers/xencons.inf not in the payload - no PV console (diagnostic only)'
        $script:Result.detail.pv_xencons = 'not shipped'
    }

    # --- optional: install and ACTIVATE the IddCx driver ----------------------------
    # Proven shipping configuration (win-idd-test, 2026-08): IDD device ROOT\DISPLAY\0000
    # (hardware id root\iddsampledriver) bound with ConfigManagerErrorCode 0, and the
    # emulated VGA adapter (Microsoft Basic Display Adapter on PCI, class CC_0300, on
    # Qubes PCI\VEN_1234&DEV_1111) DISABLED (code 22). Windows then spins up
    # ROOT\BASICDISPLAY - the Basic Display DRIVER fallback - on another adapter; that is
    # harmless, the gui-agent captures adapter 0 = the IDD. The gui-agent installed by
    # the MSI above publishes the mode list to HKLM\SOFTWARE\QubesIDD\Modes at runtime
    # and the driver reads it at monitor arrival. Activation happens HERE, right before
    # the stage-2 reboot, so the next boot comes up IDD-primary.
    # IDD is DEFAULT-ON: the IddCx driver is the headline display capability (arbitrary
    # resolutions that follow the dom0 window, no oversized Basic-Display-Adapter snapping).
    # Shipping it opt-in meant the default install ran the emulated BDA - i.e. stock display -
    # so it is activated by default now; /noidd (-NoIddDriver) opts out. NON-FATAL by design:
    # the whole block is wrapped so ANY activation failure WARNs and continues on the BDA - a
    # display feature must never fail the QWT install. Internal failures throw; the catch below
    # degrades gracefully. detail.idd_driver records how far it got either way.
    $script:Result.detail.idd_driver = 'skipped (/noidd)'
    if (-not $NoIddDriver) {
      try {
        $script:Result.detail.idd_driver = 'requested'
        $iddDir  = Join-Path $Root 'idd-driver'
        $iddHwId = 'root\iddsampledriver'
        $devcon  = Join-Path $iddDir 'devcon.exe'
        $inf = @(Get-ChildItem -LiteralPath $iddDir -Filter *.inf -ErrorAction SilentlyContinue)
        if ($inf.Count -ne 1) {
            throw "$iddDir holds $($inf.Count) .inf files (expected exactly 1)"
        }
        if (-not (Test-Path -LiteralPath $devcon)) {
            throw ("devcon.exe is missing from $iddDir - the release-package workflow's 'idd' job " +
                   'must copy it out of the WDK into idd-package/ and packaging/make-setup.ps1 must ' +
                   'stage it into idd-driver/; without it the IDD device cannot be created or removed')
        }
        # Native calls in this block: capture output in try/catch and judge ONLY
        # $LASTEXITCODE - under $ErrorActionPreference='Stop' PS 5.1 turns native stderr
        # into a terminating error (the schtasks lesson in Clear-BootResume, measured
        # 2026-08-06), which would skip the tailored diagnostics below.
        Write-Log "staging driver package $($inf[0].Name) into the driver store"
        try { $out = & pnputil.exe /add-driver $inf[0].FullName /install 2>&1 } catch { $out = "$_" }
        $out | ForEach-Object { Write-Log "  pnputil: $_" }
        # 3010 = success, reboot required: LIKELY here on upgrade, because replacing the
        # driver package of the live IDD display is exactly the in-use case. Stage 2
        # unconditionally ends in a reboot, so 3010 == 0 for our purposes.
        # 259 = ERROR_NO_MORE_ITEMS: the package is already in the store and up-to-date
        # ("Added driver packages: 0"). This is the SAME-VERSION reinstall / re-activation case
        # (the REINSTALL=ALL path, or an /iddonly run) - a success, not a failure. Only the
        # first install returns 0/3010; a re-run of an identical driver returns 259.
        if ($LASTEXITCODE -notin 0, 3010, 259) { throw "pnputil /add-driver failed ($LASTEXITCODE)" }
        $script:Result.detail.idd_driver = 'driver staged'

        # Create the root-enumerated software device - the same pnputil+devcon two-step
        # guest/deploy-and-test.ps1 uses. devcon install creates a NEW device every time
        # it runs, so a healthy existing device is reused; a BROKEN existing device is
        # removed and recreated (otherwise every re-run polls a permanently dead node).
        $createdByThisRun = $false
        $dev = Get-IddPnpDevice -HardwareId $iddHwId
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0) {
            Write-Log "IDD device already exists and is healthy ($($dev.PNPDeviceID)) - reusing it"
        } else {
            if ($dev) {
                Write-Log "IDD device exists but is broken (ConfigManagerErrorCode $($dev.ConfigManagerErrorCode)) - removing and recreating" 'WARN'
                try { $out = & $devcon remove $iddHwId 2>&1 } catch { $out = "$_" }
                $out | ForEach-Object { Write-Log "  devcon remove: $_" }
            }
            Write-Log "creating the IDD device: devcon install $($inf[0].Name) $iddHwId"
            try { $out = & $devcon install $inf[0].FullName $iddHwId 2>&1 } catch { $out = "$_" }
            $out | ForEach-Object { Write-Log "  devcon: $_" }
            # devcon: 0 = done, 1 = done but a reboot is required - and stage 2 always
            # ends in a reboot anyway.
            if ($LASTEXITCODE -notin 0, 1) { throw "devcon install $iddHwId failed ($LASTEXITCODE)" }
            $createdByThisRun = $true
            $script:Result.detail.idd_driver = 'device created, waiting for bind'
        }

        # Never disable the VGA adapter until the replacement display is demonstrably up.
        # Two gates, because ConfigManagerErrorCode 0 only proves the UMDF devnode
        # STARTED: IddCx adapter/monitor init completes asynchronously afterwards and can
        # fail while the devnode stays at code 0. The second gate requires an actual
        # VIDEO CONTROLLER attributable to the IDD devnode - the same evidence the
        # FINDINGS topology snapshots use ('IddSampleDriver Device' controller).
        Write-Log 'waiting up to 30 s for the IDD device to bind (ConfigManagerErrorCode 0)'
        $deadline = (Get-Date).AddSeconds(30)
        while ($true) {
            $dev = Get-IddPnpDevice -HardwareId $iddHwId
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { break }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 2
        }
        $iddCtrl = $null
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0) {
            Write-Log "IDD devnode up: $($dev.PNPDeviceID); waiting up to 30 s for its display adapter"
            $deadline = (Get-Date).AddSeconds(30)
            while ($true) {
                $iddCtrl = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                           Where-Object { $_.PNPDeviceID -eq $dev.PNPDeviceID } | Select-Object -First 1
                if ($iddCtrl) { break }
                if ((Get-Date) -ge $deadline) { break }
                Start-Sleep -Seconds 2
            }
        }
        if (-not ($dev -and $dev.ConfigManagerErrorCode -eq 0 -and $iddCtrl)) {
            # Leaving a half-created device behind is NOT 'unchanged': it can bind on the
            # next boot and come up as an ACTIVE SECOND monitor beside the VGA - the
            # seamless-coordinate breakage this script exists to avoid. Tear down what
            # this run created before failing.
            $state = if (-not $dev) { 'device never appeared' }
                     elseif ($dev.ConfigManagerErrorCode -ne 0) { "devnode error $($dev.ConfigManagerErrorCode)" }
                     else { 'devnode up but no display adapter materialized' }
            if ($createdByThisRun) {
                Write-Log "activation failed ($state) - removing the device this run created" 'WARN'
                try { $out = & $devcon remove $iddHwId 2>&1 } catch { $out = "$_" }
                $out | ForEach-Object { Write-Log "  devcon remove: $_" }
                $script:Result.detail.idd_driver = "activation failed ($state); device removed, VGA untouched"
            } else {
                $script:Result.detail.idd_driver = "activation failed ($state); pre-existing device LEFT IN PLACE, VGA untouched"
            }
            throw "IDD activation failed: $state - NOT disabling the VGA adapter"
        }
        Write-Log "IDD display adapter present: $($iddCtrl.Name)"

        # BIND-VERSION ASSERTION (added after 4.3.10): pnputil's ranking only rebinds
        # UPWARD, so on a DOWNGRADE (reinstalling an older release over a newer one - the
        # recovery flow a withdrawn release forces) the reused healthy device silently
        # keeps the NEWER driver against this package's OLDER agent. Assert the bound
        # driver version equals the payload INF's DriverVer version; force-bind with
        # devcon update on mismatch. Same logic as guest/activate-idd.ps1.
        $infVer = $null
        try {
            if ((Get-Content -LiteralPath $inf[0].FullName -Raw) -match 'DriverVer\s*=\s*[^,]+,\s*([0-9][0-9.]*)') { $infVer = $Matches[1] }
        } catch {}
        if (-not $infVer) {
            Write-Log 'could not parse DriverVer from the payload INF - bind-version assertion skipped' 'WARN'
        } else {
            $boundVer = (Get-PnpDeviceProperty -InstanceId $dev.PNPDeviceID -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue).Data
            if ($boundVer -ne $infVer) {
                Write-Log "bound driver $boundVer != payload $infVer - forcing rebind (devcon update; ranking never rebinds downward)" 'WARN'
                try { $out = & $devcon update $inf[0].FullName $iddHwId 2>&1 } catch { $out = "$_" }
                $out | ForEach-Object { Write-Log "  devcon update: $_" }
                $deadline = (Get-Date).AddSeconds(30)
                while ($true) {
                    $dev = Get-IddPnpDevice -HardwareId $iddHwId
                    if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { break }
                    if ((Get-Date) -ge $deadline) { break }
                    Start-Sleep -Seconds 2
                }
                if (-not ($dev -and $dev.ConfigManagerErrorCode -eq 0)) {
                    throw "IDD device did not come back healthy after the forced rebind to $infVer - NOT disabling the VGA adapter"
                }
                $boundVer = (Get-PnpDeviceProperty -InstanceId $dev.PNPDeviceID -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue).Data
                if ($boundVer -ne $infVer) {
                    throw "bound driver is $boundVer but this package ships $infVer - agent/driver mismatch, refusing to activate"
                }
            }
            Write-Log "bound driver version $boundVer matches the payload"
            $script:Result.detail.idd_bound = $boundVer
        }

        # Disable the emulated VGA adapter so the next boot comes up on the IDD. Match by
        # the PCI display class code (CC_0300 in the hardware ids), PREFERRING the
        # Qubes/QEMU stdvga identity VEN_1234&DEV_1111 when present - but not hardcoding
        # it as the only acceptable match.
        $vga = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                 Where-Object { $_.InstanceId -like 'PCI\*' -and ($_.HardwareID -match 'CC_0300') })
        if ($vga.Count -eq 0) {
            throw 'IDD device is up but no PCI display adapter (hardware id matching CC_0300) was found to disable - refusing to guess at the display topology'
        }
        $preferred = @($vga | Where-Object { $_.HardwareID -match 'VEN_1234&DEV_1111' })
        if ($preferred.Count -gt 0) { $vga = $preferred }
        if ($vga.Count -gt 1) {
            Write-Log ('multiple PCI display adapters match CC_0300 [' +
                (($vga | ForEach-Object { $_.InstanceId }) -join '; ') + '] - disabling the first') 'WARN'
        }
        $vgaDev = $vga[0]
        # Re-run/upgrade path: a previous activation already disabled it. Disabling an
        # already-disabled device is an unverified operation - skip it, keep the result
        # fields populated either way.
        $vgaCim = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                  Where-Object { $_.PNPDeviceID -eq $vgaDev.InstanceId } | Select-Object -First 1
        if ($vgaCim -and $vgaCim.ConfigManagerErrorCode -eq 22) {
            Write-Log "VGA adapter $($vgaDev.InstanceId) is already disabled (previous activation) - nothing to do"
        } else {
            # The live console may switch to the IDD the moment this executes - warn
            # BEFORE it happens so an interactive user is not left staring at a frozen
            # window with no explanation.
            Write-Log "disabling emulated VGA adapter: $($vgaDev.InstanceId) ($($vgaDev.FriendlyName)) - the display may switch or blank until the reboot"
            Disable-PnpDevice -InstanceId $vgaDev.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
        }
        # ROOT\BASICDISPLAY appearing after the reboot is EXPECTED (Basic Display DRIVER
        # fallback on another adapter) and harmless - see the block comment above.
        $script:Result.detail.idd_driver = "activated: device up ($($dev.PNPDeviceID)), VGA adapter disabled ($($vgaDev.InstanceId))"
        $script:Result.detail.idd_vga_instance_id = $vgaDev.InstanceId
        $script:Result.detail.idd_recovery = ('if the guest has no usable display after the reboot, run over qrexec: ' +
            "Enable-PnpDevice -InstanceId '$($vgaDev.InstanceId)' -Confirm:" + '$false' +
            ' (or devcon enable on that instance id), then reboot - that restores the pre-IDD display')
        Write-Log 'IDD ACTIVATED - after the reboot the Qubes IDD drives the desktop (modes from HKLM\SOFTWARE\QubesIDD\Modes)'
      } catch {
        # IDD activation is REQUIRED - it is the whole display point of this package. Running
        # on the emulated Basic Display Adapter is a FAILURE STATE, not a supported fallback:
        # arbitrary resolutions and dom0-window-following do not work on the BDA. We do NOT
        # brick the install (the guest is still usable, so the user can retry), but this is
        # logged as an ERROR and flagged loudly in the result so a BDA guest never passes as OK.
        Write-Log ("IDD ACTIVATION FAILED: $($_.Exception.Message). The guest will boot on the emulated Basic Display Adapter - a DEGRADED/FAILURE state (no arbitrary resolutions). Retry elevated once up.") 'ERROR'
        if ("$($script:Result.detail.idd_driver)" -notlike 'activated*') {
            $script:Result.detail.idd_driver = "FAILED (on Basic Display Adapter): $($_.Exception.Message)"
            $script:Result.detail.idd_failed = $true
        }
      }
    }

    # --- app hardware-acceleration pre-tweak (default ON, /noapptweaks skips) -----------
    # After the QWT install proper, before declaring the stage done: the policies are
    # order-independent (they apply to software installed later), and a failure here must
    # never fail the QWT install - it is an optimization, not a dependency.
    if ($NoAppTweaks) {
        Write-Log 'app HW-accel pre-tweak SKIPPED (/noapptweaks)'
        $script:Result.detail.app_hwaccel = 'skipped'
    } else {
        $tweak = Join-Path $Root 'disable-hw-accel.ps1'
        if (Test-Path -LiteralPath $tweak) {
            Write-Log 'applying app HW-accel pre-tweak (disable-hw-accel.ps1; /noapptweaks to skip)'
            try {
                $tw = & $tweak 2>&1
                foreach ($l in @($tw | Select-Object -Last 3)) { Write-Log "  $l" }
                $trailer = @($tw) | Where-Object { $_ -match '=== RESULT === changed=(\d+) failed=(\d+)' } | Select-Object -Last 1
                if ($trailer -match 'changed=(\d+) failed=(\d+)') {
                    $script:Result.detail.app_hwaccel = "changed=$($Matches[1]) failed=$($Matches[2])"
                    if ([int]$Matches[2] -gt 0) { Write-Log "app HW-accel pre-tweak: $($Matches[2]) writes failed (non-fatal)" 'WARN' }
                } else {
                    $script:Result.detail.app_hwaccel = 'ran, no result trailer'
                }
            } catch {
                Write-Log "app HW-accel pre-tweak failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.app_hwaccel = "error: $($_.Exception.Message)"
            }
        } else {
            Write-Log 'disable-hw-accel.ps1 not in payload - pre-tweak unavailable' 'WARN'
            $script:Result.detail.app_hwaccel = 'not in payload'
        }
    }

    # --- session lock: never let the guest take the input desktop ----------------------
    # A Windows lock screen is a secure-desktop surface, which the agent refuses to map (that
    # rule is what stopped the field "black window"), so an idle lock leaves the qube looking
    # frozen with no way in. dom0's own screen lock is the one that protects the machine, and a
    # guest lock would invite typing a password into an untrusted VM. Not gated by /noapptweaks:
    # this is correctness for a Qubes guest, not a cosmetic tweak.
    $nolock = Join-Path $Root 'disable-session-lock.ps1'
    if (Test-Path -LiteralPath $nolock) {
        Write-Log 'preventing guest session lock / screen blank (dom0 owns the screen lock)'
        try {
            $no = & $nolock 2>&1
            $tr = @($no) | Where-Object { $_ -match '=== RESULT === changed=(\d+) failed=(\d+)' } | Select-Object -Last 1
            if ($tr -match 'changed=(\d+) failed=(\d+)') {
                $script:Result.detail.session_lock = "changed=$($Matches[1]) failed=$($Matches[2])"
            } else { $script:Result.detail.session_lock = 'ran, no result trailer' }
        } catch {
            Write-Log "session-lock prevention failed: $($_.Exception.Message) (non-fatal)" 'WARN'
            $script:Result.detail.session_lock = "error: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'disable-session-lock.ps1 not in payload - guest may idle-lock' 'WARN'
        $script:Result.detail.session_lock = 'not in payload'
    }

    # --- qrexec rpc scripts + service definitions: place OUR copies over the stock ones -
    # The MSI is the stock QWT image plus our gui-agent binaries only, so every file it puts
    # under qubes-rpc-services\ and qubes-rpc\ is the STOCK text; this block is what makes the
    # repo's copies real on a guest. It used to name exactly two files (get-appmenus.ps1,
    # start-app.ps1) in a list duplicated in make-setup.ps1 - so when a THIRD script in that
    # directory was edited (2026-08-25), both lists stayed as they were, CI stayed green, and
    # the guest silently kept stock: the change shipped nothing. Now the payload directories
    # are SWEPT: make-setup.ps1 stages everything core-agent/src/qubes-rpc-services holds
    # (split to mirror the guest layout), and whatever was staged is what lands here. There is
    # no list left to forget in either file.
    # Why our scripts matter even on a fresh guest: a fresh Start Menu yields almost nothing
    # to the .lnk sweep, so dom0's application list comes up nearly empty - and in seamless
    # mode that list is the only way in. Our get-appmenus.ps1 also reports Notepad, Edge,
    # Explorer, Settings, cmd and PowerShell, and our start-app.ps1 knows how to launch them.
    $qtRoot = Join-Path $env:ProgramFiles 'Qubes Tools'
    $rpcPairs = @(
        @{ Src = Join-Path $Root 'rpc\qubes-rpc-services'; Dst = Join-Path $qtRoot 'qubes-rpc-services'; What = 'rpc handler scripts' },
        @{ Src = Join-Path $Root 'rpc\qubes-rpc';          Dst = Join-Path $qtRoot 'qubes-rpc';          What = 'qrexec service definitions' }
    )
    $rpcReport = @()
    $rpcFailed = @()
    $rpcPlacedNames = @()
    foreach ($pair in $rpcPairs) {
        if (-not (Test-Path -LiteralPath $pair.Src)) {
            # A payload without the dir is a packaging regression, not a supported shape - say
            # which side is missing, because "not deployed" hid exactly this for months.
            Write-Log "rpc payload dir missing ($($pair.Src)) - guest keeps the STOCK $($pair.What)" 'WARN'
            $rpcReport += "$($pair.What): payload-missing"
            continue
        }
        if (-not (Test-Path -LiteralPath $pair.Dst)) {
            Write-Log "$($pair.Dst) not found (QWT install incomplete?) - STOCK $($pair.What) unreplaced" 'WARN'
            $rpcReport += "$($pair.What): target-missing"
            continue
        }
        $all = @(Get-ChildItem -LiteralPath $pair.Src -File)
        $placed = 0
        foreach ($f in $all) {
            $dst = Join-Path $pair.Dst $f.Name
            try {
                if ((Test-Path -LiteralPath $dst) -and -not (Test-Path -LiteralPath "$dst.qwt-stock")) {
                    Copy-Item -LiteralPath $dst -Destination "$dst.qwt-stock" -Force
                }
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
                $placed++
                $rpcPlacedNames += $f.Name
            } catch {
                Write-Log "could not place $($f.Name): $($_.Exception.Message) (non-fatal)" 'WARN'
                $rpcFailed += $f.Name
            }
        }
        Write-Log "$($pair.What) placed: $placed/$($all.Count) (stock copies kept as *.qwt-stock)"
        $rpcReport += "$($pair.What): $placed/$($all.Count)"
    }
    if ($rpcFailed.Count) {
        Write-Log ("rpc overlay INCOMPLETE - these stayed STOCK on the guest: " + ($rpcFailed -join ', ')) 'WARN'
        $script:Result.detail.rpc_overlay_failed = $rpcFailed -join ','
    }
    $script:Result.detail.rpc_overlay = $rpcReport -join '; '
    # Field kept for older log parsers: the app-menu pair specifically. Counted from what the
    # sweep actually PLACED, not from Test-Path on the destination - the stock MSI installs
    # files under these names too, so an existence check there could never fail.
    $appmenuPlaced = @('get-appmenus.ps1', 'start-app.ps1' | Where-Object { $rpcPlacedNames -contains $_ }).Count
    $script:Result.detail.appmenu_scripts = "placed=$appmenuPlaced"

    # SERVICE NAME CASE. dom0 asks for 'qubes.GetAppmenus' (lowercase m - qubesappmenus'
    # receive.py calls run_service('qubes.GetAppmenus')), while Windows Tools has always
    # shipped the definition as 'qubes.GetAppMenus'. The sweep above now delivers the fork's
    # own qubes.GetAppmenus file (it used to be re-implemented here by copying the guest's
    # stock file, leaving the repo copy decorative - if the fork's command line ever changed,
    # the guest kept stock). This block stays as the belt-and-braces fallback for a payload
    # whose definitions dir went missing: on a case-insensitive volume it detects the file as
    # already present; on a case-sensitive one it creates the exact-case alias.
    try {
        $svc = Get-ChildItem -Path $qtRoot -Filter 'qubes.GetAppMenus' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            $alias = Join-Path $svc.DirectoryName 'qubes.GetAppmenus'
            if (-not (Test-Path -LiteralPath $alias)) {
                Copy-Item -LiteralPath $svc.FullName -Destination $alias -Force
                Write-Log "added qrexec service alias: $alias"
            }
            $script:Result.detail.appmenu_alias = 'present'
        } else {
            Write-Log 'qubes.GetAppMenus service definition not found - cannot add the lowercase alias' 'WARN'
            $script:Result.detail.appmenu_alias = 'service-file-not-found'
        }
    } catch {
        Write-Log "service alias failed: $($_.Exception.Message) (non-fatal)" 'WARN'
        $script:Result.detail.appmenu_alias = "error"
    }

    # --- fork-built qrexec binaries: OUR bin\ over the stock one ------------------------
    # The same gap in binary form: qrexec-wrapper.exe carries the drain-race fix ("do not
    # report the exit code before the i/o pumps have drained") in the core-agent fork, but
    # the MSI installs the stock 4.2.2 build - so the fix was merged, CI-green, and running
    # on NO guest. When the package carries bin\ (make-setup.ps1 -CoreAgentBins), place its
    # files over `Qubes Tools\bin`. A running exe cannot be overwritten but CAN be renamed,
    # so on a locked file the live binary is moved aside and the copy retried; the swap takes
    # effect at the next process spawn (qrexec-wrapper is started per connection) or, for the
    # agent service itself, at the reboot this stage ends in.
    $binSrc = Join-Path $Root 'bin'
    $binDst = Join-Path $qtRoot 'bin'
    if ((Test-Path -LiteralPath $binSrc) -and (Test-Path -LiteralPath $binDst)) {
        $binPlaced = 0
        $binFailed = @()
        foreach ($b in @(Get-ChildItem -LiteralPath $binSrc -File)) {
            $dst = Join-Path $binDst $b.Name
            try {
                if ((Test-Path -LiteralPath $dst) -and -not (Test-Path -LiteralPath "$dst.qwt-stock")) {
                    Copy-Item -LiteralPath $dst -Destination "$dst.qwt-stock" -Force
                }
                try {
                    Copy-Item -LiteralPath $b.FullName -Destination $dst -Force
                } catch {
                    # Sharing violation: the stock binary is executing right now (the qrexec
                    # agent service, or the very wrapper hosting this connection). Rename it
                    # out of the way - allowed for a running image - and copy again.
                    Move-Item -LiteralPath $dst -Destination "$dst.qwt-prev" -Force
                    Copy-Item -LiteralPath $b.FullName -Destination $dst -Force
                }
                $binPlaced++
            } catch {
                Write-Log "could not place bin\$($b.Name): $($_.Exception.Message) (non-fatal)" 'WARN'
                $binFailed += $b.Name
            }
        }
        Write-Log "fork qrexec binaries placed: $binPlaced (stock kept as *.qwt-stock)"
        $script:Result.detail.qrexec_bins = if ($binFailed.Count) { "placed=$binPlaced FAILED=" + ($binFailed -join ',') } else { "placed=$binPlaced" }
        if ($binFailed.Count) { Write-Log ("qrexec binaries left STOCK: " + ($binFailed -join ', ')) 'WARN' }
    } elseif (Test-Path -LiteralPath $binSrc) {
        Write-Log "payload bin\ present but $binDst missing - QWT install incomplete? STOCK qrexec binaries unreplaced" 'WARN'
        $script:Result.detail.qrexec_bins = 'target-missing'
    } else {
        # Not fatal while the release workflow does not yet build core-agent, but it must be
        # VISIBLE: no bin\ means the guest runs the STOCK qrexec-wrapper (lost bytes on
        # service exit) and this line is the only witness to that.
        Write-Log 'no bin\ in payload - guest keeps the STOCK qrexec binaries (the drain-race fix is NOT deployed)' 'WARN'
        $script:Result.detail.qrexec_bins = 'not-in-payload'
    }

    # --- ETW-proxy least-privilege account (notification bridge, ETW tier) --------------
    # Provisions the dedicated qubes-etwproxy account the SYSTEM gui-agent will use to
    # launch `etwproxy.exe` (the GUI-DLL-free console proxy, 2026-09-05 split;
    # DESIGN-p3-classifier-impl.md sec 10.14, revised by the capability-grant split):
    # NO group memberships at all (the agent grants the
    # consumer TRACELOG_ACCESS_REALTIME on the one trace session instead of PLU), explicit
    # SeBatchLogonRight, batch logon only (interactive/remote/network DENIED), a throwaway
    # random password VALIDATED with a real batch LogonUser then DISCARDED (no secret at
    # rest - the agent sets a fresh in-memory password at every launch), outbound-block
    # firewall rule, a log ACE scoped to the proxy's own etw-proxy.log in the standard QWT
    # log dir, a deny-write ACE on the bridge state dir, and removal of the retired LSA
    # secret + QubesEtwProxyGuard boot task on upgrade.
    # Runs AFTER the bin overlay so etwproxy.exe is already next to gui-agent.exe.
    # THE SCRIPT NEVER FAILS THE INSTALL: on a managed/hardened image that refuses any step
    # it logs, reports provisioned=0 in its trailer, and exits 0 - the bridge's ETW tier
    # then simply stays down and the classifier serves from the listener/DB rungs
    # (fail-open). Absence of the script from the payload is loud for the same reason the
    # qrexec-bins warning above is: a provisioning step that does not ship runs on NO guest
    # (the 4.3.18 de-slice-broker inert-clean-install gap).
    $etwProv = Join-Path $Root 'provision-etwproxy-account.ps1'
    if (Test-Path -LiteralPath $etwProv) {
        Write-Log 'provisioning the least-privilege ETW proxy account (qubes-etwproxy)'
        try {
            $po = & $etwProv 2>&1
            foreach ($l in @($po | Select-Object -Last 8)) { Write-Log "  $l" }
            $tr = @($po) | Where-Object { $_ -match '=== RESULT === provisioned=(\d)' } | Select-Object -Last 1
            if ($tr -match 'provisioned=1') {
                $script:Result.detail.etwproxy_account = 'provisioned'
                Write-Log 'ETW proxy account provisioned (zero-groups, batch-validated, no credential at rest)'
            } else {
                $reason = if ($tr -match 'reason=([A-Za-z0-9-]+)') { $Matches[1] } else { 'unknown' }
                $script:Result.detail.etwproxy_account = "skipped:$reason"
                Write-Log "ETW proxy account NOT provisioned ($reason) - the notification bridge's" 'WARN'
                Write-Log '  ETW tier stays down; toasts still classify via the listener/DB path' 'WARN'
            }
        } catch {
            Write-Log "ETW proxy provisioning failed: $($_.Exception.Message) (non-fatal)" 'WARN'
            $script:Result.detail.etwproxy_account = "error: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'provision-etwproxy-account.ps1 not in payload - ETW proxy account not provisioned' 'WARN'
        $script:Result.detail.etwproxy_account = 'not in payload'
    }

    # --- reboot audit: keep the evidence of WHY a restart happened ----------------------
    # An AppVM's System log is on the volatile C:, so Event 1074 - the record naming who asked
    # for a restart - is destroyed by the restart it describes. Without it a guest that reboots
    # itself is indistinguishable from one dom0 asked to reboot, and those have opposite fixes.
    $audit = Join-Path $Root 'install-reboot-audit.ps1'
    if (Test-Path -LiteralPath $audit) {
        Write-Log 'installing the reboot-cause audit (event-triggered, writes to the private volume)'
        try {
            $ao = & $audit 2>&1
            foreach ($l in @($ao | Select-Object -Last 5)) { Write-Log "  $l" }
            $tr = @($ao) | Where-Object { $_ -match '=== RESULT === changed=(\d+) failed=(\d+)' } | Select-Object -Last 1
            if ($tr -match 'changed=(\d+) failed=(\d+)') {
                $script:Result.detail.reboot_audit = "changed=$($Matches[1]) failed=$($Matches[2])"
            } else { $script:Result.detail.reboot_audit = 'ran, no result trailer' }
        } catch {
            Write-Log "reboot audit install failed: $($_.Exception.Message) (non-fatal)" 'WARN'
            $script:Result.detail.reboot_audit = "error: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'install-reboot-audit.ps1 not in payload - reboot causes will not be recorded' 'WARN'
        $script:Result.detail.reboot_audit = 'not in payload'
    }

    # --- autologon: VERIFY what stage 1 armed -------------------------------------------
    # The arming happens in stage 1 (the password is only available there - see the note next to
    # it). What stage 2 can do, and must, is check the result and report it, so an install that
    # ends with a guest unable to log itself back in says so instead of looking clean.
    $ea = Join-Path $Root 'ensure-autologon.ps1'
    if (Test-Path -LiteralPath $ea) {
        try {
            $eo = & $ea 2>&1
            foreach ($l in @($eo | Select-Object -Last 6)) { Write-Log "  $l" }
            $tr = @($eo) | Where-Object { $_ -match '=== RESULT === changed=(\d+) warnings=(\d+)' } | Select-Object -Last 1
            if ($tr -match 'warnings=(\d+)') {
                if ([int]$Matches[1] -eq 0) {
                    $script:Result.detail.autologon = 'armed'
                    Write-Log 'autologon verified - this qube can come back on its own'
                } else {
                    $script:Result.detail.autologon = 'not-armed:no-password'
                    Write-Log 'autologon is NOT usable: no password is set for it. This qube will come' 'WARN'
                    Write-Log '  back at a sign-in screen, which seamless mode does not display - arm it with' 'WARN'
                    Write-Log '  set-autologon.ps1, or reinstall passing /autologon:PASSWORD.' 'WARN'
                }
            } else { $script:Result.detail.autologon = 'verify: no result trailer' }
        } catch {
            Write-Log "autologon verification failed: $($_.Exception.Message) (non-fatal)" 'WARN'
            $script:Result.detail.autologon = "verify-error: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'ensure-autologon.ps1 not in payload - cannot verify autologon' 'WARN'
        $script:Result.detail.autologon = 'unverified'
    }

    # --- consumer-nag silencer (same switch as the HW-accel tweak) ----------------------
    if (-not $NoAppTweaks) {
        $quiet = Join-Path $Root 'quiet-desktop.ps1'
        if (Test-Path -LiteralPath $quiet) {
            Write-Log 'silencing consumer nags (OneDrive reminder, Spotlight, OOBE prompts)'
            try {
                $qo = & $quiet 2>&1
                $trailer = @($qo) | Where-Object { $_ -match '=== RESULT === changed=(\d+) failed=(\d+)' } | Select-Object -Last 1
                if ($trailer -match 'changed=(\d+) failed=(\d+)') {
                    $script:Result.detail.quiet_desktop = "changed=$($Matches[1]) failed=$($Matches[2])"
                } else { $script:Result.detail.quiet_desktop = 'ran, no result trailer' }
            } catch {
                Write-Log "consumer-nag silencer failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.quiet_desktop = "error: $($_.Exception.Message)"
            }

            # RE-ASSERT AT EVERY BOOT, and keep a persistent copy to re-assert FROM.
            #
            # Running this once at install time is not enough, for two reasons that both bite in
            # normal use:
            #   * a feature update rewrites consumer surface - the same reason the autologon guard
            #     exists - so a qube that was quiet before 24H2 -> 25H2 is chatty after it;
            #   * this is a TEMPLATE. Its AppVMs get fresh user profiles, and the per-user half of
            #     these settings (File Explorer sync-provider adverts, ContentDeliveryManager) is
            #     written per profile. quiet-desktop.ps1 covers existing profiles and the Default
            #     hive, but only for profiles that exist WHEN IT RUNS.
            # The installer runs the script straight out of the setup payload, which does not
            # survive, so a persistent copy is a prerequisite rather than a nicety.
            try {
                $qBin = Join-Path $script:DefaultBinDir 'quiet-desktop.ps1'
                New-Item -ItemType Directory -Force (Split-Path $qBin) | Out-Null
                Copy-Item -LiteralPath $quiet -Destination $qBin -Force
                $qXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: re-assert the consumer-nag policies at boot (feature updates and new user profiles undo them)</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$qBin"</Arguments></Exec></Actions>
</Task>
"@
                $qf = Join-Path $env:TEMP 'qubes-quiet-desktop.xml'
                [IO.File]::WriteAllText($qf, $qXml, [Text.Encoding]::Unicode)
                $qr = & schtasks /create /tn QubesQuietDesktopGuard /xml "$qf" /f 2>&1
                Write-Log ("quiet-desktop boot guard rc=$LASTEXITCODE : " + ($qr -join ' '))
                $script:Result.detail.quiet_desktop_guard = "rc=$LASTEXITCODE"
            } catch {
                Write-Log "quiet-desktop boot guard failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.quiet_desktop_guard = "error: $($_.Exception.Message)"
            }
        }
    } else { $script:Result.detail.quiet_desktop = 'skipped' }

    # --- Windows Update agent (default ON, /noupdates skips) ----------------------------
    # Updates are dom0-owned: the guest reports availability via qubes.NotifyUpdates and
    # installs ONLY when dom0 asks, exactly like a Linux qube. install-updater-agent.ps1 also
    # makes dom0's stock `qubes-vm-update` (and the Qubes Update GUI) able to drive this qube,
    # and turns Windows' own auto-update OFF. Deployed by DEFAULT: behind a switch it would
    # never be there when the user clicks Update. Non-fatal, like the tweak above.
    if ($NoUpdaterAgent) {
        Write-Log 'Windows Update agent SKIPPED (/noupdates)'
        $script:Result.detail.updater_agent = 'skipped'
    } else {
        $deployUpd = Join-Path $Root 'install-updater-agent.ps1'
        if (Test-Path -LiteralPath $deployUpd) {
            Write-Log 'deploying the Windows Update agent (dom0-driven; /noupdates to skip)'
            try {
                $ud = & $deployUpd -SetupRoot $Root 2>&1
                foreach ($l in @($ud | Select-Object -Last 6)) { Write-Log "  $l" }
                $script:Result.detail.updater_agent = 'deployed'
                # Two settings live in dom0 and cannot be applied from in here. The RPM's
                # qwt-ng-prepare-qube does them; say so, because a qube missing them fails to
                # update in a way that looks like a bug in the guest.
                Write-Log 'NOTE: dom0-side, this qube also needs:  qwt-ng-prepare-qube <qube>'
                Write-Log '      (sets feature vmexec=1 and raises qrexec_timeout; without them'
                Write-Log '       the Qubes Update tool cannot drive this qube)'
            } catch {
                Write-Log "Windows Update agent deploy failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.updater_agent = "error: $($_.Exception.Message)"
            }
        } else {
            Write-Log 'install-updater-agent.ps1 not in payload - updater agent unavailable' 'WARN'
            $script:Result.detail.updater_agent = 'not in payload'
        }
    }

    # --- PV NIC priming latch: UNCONDITIONAL, every qube class (owner, 2026-08-29) -------
    # Was TEMPLATES-only. The stated reason was that "a StandaloneVM has a persistent root that
    # completes the vif install on its own first netvm boot". MEASURED 2026-08-29 and that is
    # FALSE: on win10-u10, freshly installed from our package with netvm='' and then given a vif
    # live, the PV NIC landed in PnP Error (XENVIF\VEN_XP&DEV_NET\0, XENNET Stopped) and stayed
    # there until a reboot. A second boot is a FAILURE, not a property - it is precisely what the
    # latch exists to remove. The old comment already conceded "priming a non-template is
    # harmless", so there was never a cost to doing it everywhere, only an untested assumption
    # that it was unnecessary. Now seeded for EVERY class; the class is read only for the log.
    # (guest/pvnic-selfprime.ps1 is transactional: tasks registered first, latch armed last.) The class is read LIVE from qubesdb via the
    # client DLL in SYSTEM32 (qdb_open/qdb_read) - the earlier "qubesdb is unreadable in a
    # Windows guest" belief was a P/Invoke marshaling bug, now retired. /type is the exact class
    # name. Non-template, or class unreadable -> skip harmlessly. (If a qube is converted to a
    # template AFTER install, re-run priming or let clone-to-template seed it.)
    $primeClass = $null
    try {
        if (-not ('QdbPrime' -as [type])) {
            Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QdbPrime {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
        }
        # The read is retried: a single failed attempt used to fall through to
        # "skipped-non-template", silently shipping an unprimed template (the exact
        # AppVM restart-loop this block exists to prevent). Field-observed as an
        # intermittent misread; each retry re-opens the connection.
        for ($qtry = 0; $qtry -lt 3 -and -not $primeClass; $qtry++) {
            if ($qtry -gt 0) { Start-Sleep 2 }
            $qh = [QdbPrime]::qdb_open([IntPtr]::Zero)
            if ($qh -ne [IntPtr]::Zero) {
                $ql = [uint32]0
                $qp = [QdbPrime]::qdb_read($qh, '/type', [ref]$ql)
                if ($qp -ne [IntPtr]::Zero) { $primeClass = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($qp, [int]$ql) }
                [QdbPrime]::qdb_close($qh)
            }
        }
    } catch { }
    # FAIL CLOSED on an unreadable class: priming is transactional (tasks registered,
    # latch armed last; an AppVM re-arms per boot, a StandaloneVM tolerates the armed
    # latch - its persistent root completes the vif install either way), while SKIPPING
    # on a template is the restart-loop defect. So: known TemplateVM -> prime; class
    # unreadable after retries -> prime anyway; known non-template -> skip.
    $primeIndeterminate = [string]::IsNullOrEmpty($primeClass)
    # The class no longer gates anything - it is recorded for the log only.
    if ($primeIndeterminate) { Write-Log 'qubesdb /type unreadable - priming anyway (it is unconditional)' 'WARN' }
    if ($true) {
        $deployPrime = Join-Path $Root 'pvnic-selfprime.ps1'
        if (Test-Path -LiteralPath $deployPrime) {
            Write-Log "class='$(if ($primeIndeterminate) { 'indeterminate' } else { $primeClass })': seeding PV NIC priming latch UNCONDITIONALLY (pvnic-selfprime.ps1)"
            try {
                $pp = & $deployPrime 2>&1
                foreach ($l in @($pp | Select-Object -Last 4)) { Write-Log "  $l" }
                $script:Result.detail.pvnic_prime = if ($primeIndeterminate) { 'seeded-indeterminate-class' } else { 'seeded' }
            } catch {
                Write-Log "pvnic priming failed: $($_.Exception.Message) (non-fatal)" 'WARN'
                $script:Result.detail.pvnic_prime = "error: $($_.Exception.Message)"
            }
        } else {
            Write-Log 'pvnic-selfprime.ps1 not in payload - PV NIC priming unavailable' 'WARN'
            $script:Result.detail.pvnic_prime = 'not in payload'
        }
        # ARM THE LATCH NOW, as the last act before this installer shuts the guest down.
        #
        # pvnic-selfprime.ps1 is transactional on purpose: it registers the tasks and lets the TASK
        # arm the latch, so a failed registration can never leave a template latched-but-applierless.
        # The task runs ~25-29 s into a boot - and the installer shuts the guest down immediately
        # after this point ("ONE guest shutdown for the whole install"), so on a normal install the
        # task never gets that far and the template ships with NICS UNSET.
        #
        # xen.sys consumes NICS at every boot (delete-on-read) and vetoes it unless an Enum\XENBUS
        # subkey name contains "VIF", so an unset latch means an AppVM cannot complete its PV NIC
        # install in one volatile boot: it demands a restart, the volatile root discards the
        # half-finished install, and Qubes halts the qube. That is the "AppVM shuts down a couple of
        # seconds after starting" report from the field (forum posts 56, 70, 89).
        #
        # Arming here is safe in both directions: the tasks are already registered above, so the
        # forbidden latched-without-applier state cannot arise, and an AppVM re-arms per boot anyway.
        # (The xenbus_monitor shipping state - disabled, AutoReboot=0 - is asserted below for EVERY
        # qube class, not just templates; 4.3.6 had it in this branch only, which left StandaloneVMs
        # with silent-AutoReboot permanently armed.)
        try {
            reg add "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS /t REG_DWORD /d 1 /f | Out-Null
            reg add "HKLM\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF" /f | Out-Null
            $nics = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS
            if ($nics -eq 1) {
                Write-Log 'PV NIC unplug latch armed for shutdown (NICS=1)'
                $script:Result.detail.pvnic_latch = 'armed'
            } else {
                Write-Log "PV NIC unplug latch did NOT read back armed (NICS='$nics') - AppVMs on this template may restart-loop" 'WARN'
                $script:Result.detail.pvnic_latch = "unconfirmed:$nics"
            }
        } catch {
            Write-Log "arming the PV NIC unplug latch failed: $($_.Exception.Message)" 'WARN'
            $script:Result.detail.pvnic_latch = "error: $($_.Exception.Message)"
        }
    }

    # SHIPPING STATE, every qube class: xenbus_monitor disabled, AutoReboot=0, no reboot request
    # left parked. The msiexec earlier in this stage re-registered the service auto-start; this is
    # the assertion that outlives the install. The per-boot payload re-asserts it on templates and
    # AppVMs; a StandaloneVM (no payload) relies on exactly this line - 4.3.6 missed it there.
    # The Request key holds whatever reboot demand the install itself parked (xenvbd's, typically);
    # clearing it costs nothing - a demand that still matters is re-filed by the driver on the next
    # boot that needs it, and the next boot completes the binding anyway (that is the documented
    # ONE-shutdown handover).
    try {
        # Disable-XenbusMonitor now clears the Request key itself, through the registry API. The
        # reg.exe delete that used to follow it here threw on an ABSENT key (stderr -> terminating
        # error under ErrorActionPreference=Stop), and being inside this try/catch that silently
        # skipped the state read and log lines below - so the shipping state went unrecorded
        # exactly when it was already correct.
        Disable-XenbusMonitor -Why 'final act: shipping state' | Out-Null
        $arFinal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Parameters' -EA SilentlyContinue).AutoReboot
        $xbmFinal = Get-Service xenbus_monitor -EA SilentlyContinue
        Write-Log "xenbus_monitor shipping state: AutoReboot=$arFinal start=$($xbmFinal.StartType) status=$($xbmFinal.Status)"
        $script:Result.detail.xenbus_autoreboot_final = $arFinal
        $script:Result.detail.xenbus_monitor_final = "$($xbmFinal.StartType)/$($xbmFinal.Status)"
    } catch { Write-Log "could not assert xenbus_monitor shipping state: $($_.Exception.Message)" 'WARN' }

    # UAC PROMPTS ON THE NORMAL DESKTOP (owner decision 2026-08-27). The secure desktop is
    # never granted to dom0 (its dimming backdrop mapped as an unclosable black window WAS
    # the field-reported bug; the agent now freezes all output while it is up), which makes
    # a secure-desktop UAC prompt INVISIBLE - the qube just sits there until the prompt
    # times out. PromptOnSecureDesktop=0 renders consent on the Default desktop instead:
    # the prompt becomes an ordinary dom0 window the user can see and answer. UAC itself
    # stays ON (EnableLUA untouched - the admin/kernel ladder is real guest->host attack
    # surface reduction); what is traded away is secure-desktop prompt integrity against
    # in-guest overlay deception, a distinction worth little inside a qube. UIPI still
    # blocks synthesized input from medium-IL guest code. Revert per guest:
    #   reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 1 /f
    try {
        & reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f /reg:64 | Out-Null
        $psd = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -EA SilentlyContinue).PromptOnSecureDesktop
        Write-Log "UAC consent rendering: PromptOnSecureDesktop=$psd (0 = visible in dom0; EnableLUA untouched)"
        $script:Result.detail.uac_prompt_on_secure_desktop = $psd
    } catch { Write-Log "could not seed PromptOnSecureDesktop: $($_.Exception.Message)" 'WARN' }

    $script:Result.ok = $true
    $script:Result.reboot_needed = $true
    # The install cycle is over - the carried switches have done their job. Leaving the file would
    # silently re-apply them to any later re-run of this script on this guest.
    Remove-Item -LiteralPath $script:StageFlagFile -Force -EA SilentlyContinue
    Write-Log 'INSTALL COMPLETE - QWT installed. The PV drivers bind at the guest''s NEXT start.'

    # ONE guest shutdown for the whole install, not two.
    #
    # Everything that needed testsigning ACTIVE has already happened in this boot - the MSI,
    # the PV driver packages, and the IDD activation, which waits for the IddCx device to bind
    # before it disables the emulated VGA. What the old final reboot bought was the PV disk and
    # network drivers taking over from their emulated counterparts, and that is exactly the
    # kind of thing a guest picks up on its next start anyway. Stock QWT hands a qube back the
    # same way.
    #
    # Why it matters beyond tidiness: qvm-create-windows-qube restarts the qube EXACTLY ONCE
    # after running the tools installer and then waits forever for os=Windows. A second
    # shutdown leaves it waiting on a halted qube with nobody to start it - the provisioning
    # run hangs. With one shutdown, an unpatched upstream works.
    #
    # -RebootAtEnd restores the old behaviour for a caller that wants the finished state
    # immediately (our own acceptance harness reboots by itself and does not need it).
    if ($Auto -and $RebootAtEnd) {
        Write-Log 'rebooting in 2 s (-RebootAtEnd)'
        Emit-ResultThenReboot 0
    }
    Write-Log 'No reboot from here. qrexec answers in this boot; PV drivers and their'
    Write-Log 'emulated-device handover complete the next time the qube starts.'
    Emit-Result 0
}

function Import-PayloadCerts {
    # Trust EVERY publisher whose driver this payload will install, BEFORE anything installs one.
    #
    # ROOT CAUSE, measured 2026-08-29 on win10-u10 (FINDINGS: "the WIN10 install hangs on a
    # Windows Security driver-trust dialog"). The old code imported only certs\*.cer here, and
    # imported pv-drivers\xenvif-signer.cer LATER, after msiexec. But msiexec's own ADDLOCAL
    # installs the PV drivers, and they are signed by that same throwaway CI certificate. So at
    # InstallDriverPackages time the publisher was NOT trusted, Windows raised a modal
    # "Windows Security" prompt (class #32770, rundll32) 1.5 s into the custom action, and with
    # nobody there to click it the install hung for 27.9 minutes until the guest was shut down.
    # The code already knew the rule - "Trust the signer FIRST: an untrusted publisher fails the
    # driver-store add with 0xE0000247" - but applied it only to its own pnputil step.
    #
    # Note the certs share a common name ("QubesIDD Test Signing") but differ by THUMBPRINT
    # between builds, because CI test-signs with a throwaway key. Matching by name is therefore
    # useless; every .cer the payload ships must be imported.
    param([Parameter(Mandatory)][string]$Root, [string]$Why = '')

    $dirs = @((Join-Path $Root 'certs'), (Join-Path $Root 'pv-drivers'))
    $certs = @()
    foreach ($d in $dirs) {
        $certs += @(Get-ChildItem -LiteralPath $d -Filter *.cer -ErrorAction SilentlyContinue)
    }
    if ($certs.Count -lt 2) {
        Fail "expected the QWT signing certs under $Root (certs\ + pv-drivers\), found $($certs.Count)"
    }
    foreach ($c in $certs) {
        foreach ($store in 'Root', 'TrustedPublisher') {
            & certutil.exe -addstore -f $store $c.FullName | Out-Null
            # CHECKED, in both stages. Stage 2's old import discarded the result and logged
            # nothing, so a failed import was invisible - and stage 2 is the path this bug was
            # found on. An untrusted publisher does not fail loudly; it waits for a human.
            if ($LASTEXITCODE -ne 0) { Fail "certutil -addstore $store failed for $($c.Name)" }
        }
    }
    Write-Log ("trusted $($certs.Count) payload certs (Root + TrustedPublisher)" +
               $(if ($Why) { " [$Why]" } else { '' }))
    $script:Result.detail.certs_installed = $certs.Count
    return $certs.Count
}

function Write-PreconditionSnapshot {
    # The FIRST act of the installer, before anything mutates. Records the guest state THE
    # INSTALLER ITSELF SEES, read through the same helpers the install decisions are made with.
    #
    # WHY (2026-08-29): the 2026-08-28 WIN10 matrix was voided because cells asserted their
    # precondition on a signal the code under test does not consult. The clearest case: a cell
    # logged "precondition real (no QWT installed)" at 01:16:18 while this script, 25 s later,
    # found QWT 4.3.2.0 and took the in-place major-upgrade path. Both statements were recorded;
    # only one came from the code that branches. A harness may still probe whatever it likes, but
    # the RECORD OF RECORD for what path a run exercised is this snapshot - taken here, by us,
    # before we have changed anything.
    #
    # Emitted as one parseable line into the install log (the channel already proven to survive a
    # mid-install reboot) and, best-effort, as a file. The log line is authoritative.
    param([string]$RunId)

    $snap = [ordered]@{ run_id = $RunId; t = (Get-Date).ToUniversalTime().ToString('o') }

    # Local clock offset, so an injection timestamped by a harness on another clock can be
    # reconciled with this log instead of guessed at.
    try { $snap.utc_offset_minutes = [int]([TimeZoneInfo]::Local.GetUtcOffset((Get-Date))).TotalMinutes }
    catch { $snap.utc_offset_minutes = $null }

    try { $snap.testsigning_active = [bool](Test-TestSigningActive) } catch { $snap.testsigning_active = 'ERROR' }

    # The decisive one: what the installer's own detector reports. This is the signal that decides
    # fresh vs upgrade, so it is what defines which scenario a cell actually ran.
    try {
        $q = @(Get-InstalledQwt)
        $snap.installed_qwt = @($q | ForEach-Object {
            [ordered]@{ name = $_.DisplayName; version = $_.DisplayVersion; code = $_.PSChildName } })
        $snap.installed_qwt_count = $q.Count
    } catch { $snap.installed_qwt = 'ERROR'; $snap.installed_qwt_count = -1 }

    try { $snap.pv_boot_disk = [bool](Test-BootDiskOnPvPath) } catch { $snap.pv_boot_disk = 'ERROR' }

    # xenbus_monitor: service state AND live processes. These differ - 81d2b79 exists because the
    # service was Disabled while the process was still running and acting. Recorded separately so
    # that difference is never collapsed again.
    $mon = [ordered]@{}
    try {
        $svc = Get-Service -Name 'xenbus_monitor' -ErrorAction SilentlyContinue
        if ($svc) { $mon.status = [string]$svc.Status } else { $mon.status = 'ABSENT' }
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor' -ErrorAction SilentlyContinue
        if ($k) { $mon.start = $k.Start } else { $mon.start = $null }
        $mon.pids = @(Get-Process -ErrorAction SilentlyContinue |
                      Where-Object { $_.ProcessName -match '(?i)xenbus_monitor' } |
                      ForEach-Object { $_.Id })
    } catch { $mon.error = $_.Exception.Message }
    $snap.xenbus_monitor = $mon

    # Pending PV reboot Request, WITH VALUES. A bare subkey list cannot distinguish "armed" from
    # "present but zero", and that distinction is the whole suppressor question.
    $req = @()
    try {
        $rp = 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request'
        foreach ($c in @(Get-ChildItem -LiteralPath $rp -ErrorAction SilentlyContinue)) {
            $vals = [ordered]@{}
            $p = Get-ItemProperty -LiteralPath $c.PSPath -ErrorAction SilentlyContinue
            if ($p) {
                foreach ($n in @($p.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' })) {
                    $vals[$n] = $p.$n
                }
            }
            $req += [ordered]@{ key = $c.PSChildName; values = $vals }
        }
    } catch {}
    $snap.pending_request = $req
    try {
        $ar = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Xen\XenBusMonitor' -Name 'AutoReboot' -ErrorAction SilentlyContinue
        if ($ar) { $snap.auto_reboot = $ar.AutoReboot } else { $snap.auto_reboot = $null }
    } catch { $snap.auto_reboot = $null }

    # Installed PV driver binaries, by file version - the thing an upgrade path acts on.
    $drv = [ordered]@{}
    try {
        foreach ($n in @('xenbus','xenvif','xennet','xenvbd','xeniface')) {
            $f = Join-Path $env:SystemRoot ("System32\drivers\$n.sys")
            if (Test-Path -LiteralPath $f) {
                $drv[$n] = (Get-Item -LiteralPath $f).VersionInfo.FileVersion
            } else { $drv[$n] = 'ABSENT' }
        }
    } catch {}
    $snap.pv_drivers = $drv

    # Windows' own "a reboot is already owed" state. If this is set BEFORE we start, a reboot
    # during our install is not necessarily ours, and that ambiguity must be on the record.
    $pend = [ordered]@{}
    try {
        $pend.cbs_reboot_pending = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        $pend.wu_reboot_required = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($sm -and $sm.PendingFileRenameOperations) {
            $pend.pending_file_renames = @($sm.PendingFileRenameOperations).Count
        } else { $pend.pending_file_renames = 0 }
    } catch {}
    $snap.reboot_already_pending = $pend

    # Set both keys unconditionally first, so the record has ONE schema whatever fails. A snapshot
    # whose key set varies with which call threw forces every consumer to special-case absence, and
    # "key missing" then reads as "not applicable" instead of "we could not measure it".
    $snap.last_boot_utc = $null
    $snap.os_build      = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $snap.last_boot_utc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $ubr = ''
        if ($cv) { $ubr = [string]$cv.UBR }
        $snap.os_build = ($os.Version + '.' + $ubr)
    } catch { }

    $json = ($snap | ConvertTo-Json -Compress -Depth 6)
    Write-Log ('=== PRECONDITION === ' + $json)
    try {
        $dir = Split-Path $WorkDir -Parent
        if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
        Set-Content -LiteralPath (Join-Path $WorkDir 'precondition.json') -Value $json -Encoding ASCII
    } catch {
        Write-Log ("precondition snapshot file could not be written: $($_.Exception.Message) " +
                   '- the log line above is the record') 'WARN'
    }
    $script:Result.detail.precondition = $snap
    return $snap
}

# ---------------------------------------------------------------------------------- main
try {
    Write-Log '================================================================'
    Write-Log 'Qubes Windows Tools (improved GUI agent) - setup'
    Assert-Elevated

    # FIRST, before anything mutates - see the function header. A run whose log has no
    # '=== PRECONDITION ===' line did not get this far, and its scenario is therefore unknown:
    # the harness must treat that as an instrument failure, never as a fresh install.
    $script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    Write-Log ("run id: $script:RunId")
    [void](Write-PreconditionSnapshot -RunId $script:RunId)

    $src = $PSScriptRoot
    if (-not $src) { Fail 'cannot determine script directory' }
    Write-Log "payload source: $src"

    if ($AcceptPvDiskUpgrade) {
        Write-Log ('/acceptpvdiskupgrade is INERT since 4.3.2 and is being ignored: the path it ' +
                   'used to unlock (removing QWT while the boot disk is on the PV path) leaves the ' +
                   'guest with no boot disk at all, which was reproduced and could not be recovered ' +
                   'from inside. Use a version-bumped package, which upgrades in place.') 'WARN'
    }
    $n = Test-Payload -Root $src
    $script:Result.detail.payload_files_verified = $n

    Copy-Payload -Source $src -Dest $WorkDir
    # Re-verify AFTER the copy: a truncated copy from a CD is exactly the failure this
    # catches, and the installer runs from the copy, not from the source.
    [void](Test-Payload -Root $WorkDir)

    $mf = Join-Path $WorkDir 'MANIFEST.json'
    if (Test-Path -LiteralPath $mf) {
        $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
        Write-Log ("package {0}  repo {1}  agent {2}  CI run {3}" -f `
            $m.package_version, $m.source.driver_repo_commit, $m.source.agent_commit, $m.ci.run_id)
        $script:Result.detail.package_version = $m.package_version
    }

    if (Test-TestSigningActive) {
        Write-Log 'testsigning is ACTIVE in this boot -> stage 2'
        # Re-apply what stage 1 was asked for, for anything not passed explicitly on THIS command
        # line. Without this a manual `install.cmd /noidd` reached here with $NoIddDriver unset and
        # activated the IDD - the switch was accepted, then quietly discarded across the reboot.
        Restore-StageFlags -Bound $PSBoundParameters
        Invoke-Stage2 -Root $WorkDir
    } else {
        Write-Log 'testsigning is NOT active in this boot -> stage 1'
        Invoke-Stage1 -Root $WorkDir
    }
} catch {
    $msg = "$($_.Exception.Message)"
    Write-Log $msg 'FATAL'
    Write-Log ($_.ScriptStackTrace) 'FATAL'
    $script:Result.ok = $false
    $script:Result.error = $msg
    Emit-Result 1
}
