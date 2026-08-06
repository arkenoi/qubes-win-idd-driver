<#
.SYNOPSIS
    Install Qubes Windows Tools 4.2.2 (rebuilt from source with the improved GUI agent)
    onto a clean Windows guest, or over a guest that already has QWT installed.

.DESCRIPTION
    This is a FULL install, not an overlay: it runs the real QWT installer.msi produced by
    the `qwt-full` CI workflow, which contains our gui-agent.exe / gui-watchdog.exe and
    every other component bit-identical to the shipped ITL 4.2.2 MSI.

    Two stages, because our binaries are TEST-SIGNED and Windows must be rebooted after
    `bcdedit /set testsigning on` before it will load them:

      stage 1  copy payload to disk, verify hashes, trust the signing certificates,
               seed the gui-agent registry defaults, enable testsigning, reboot
      stage 2  verify testsigning is active, REMOVE any previously installed QWT,
               install vc_redist, run msiexec, optionally stage the (experimental)
               IddCx driver, reboot

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

.PARAMETER InstallIddDriver
    Also stage the experimental Qubes IddCx display driver into the driver store. It is
    NOT activated (no monitor is created) - see README.txt. Default: off.

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
    [switch]$InstallIddDriver,
    [switch]$NoPvNetwork,
    [switch]$ResumeAfterUninstall,
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
        @('DisableCursor', 'REG_DWORD', '0'),
        # LogDir MUST be pre-seeded: two MSI components race to write it ([INSTALL_DIR]log
        # vs "Q:\Qubes Logs") under an identical condition. If Q:\ wins and does not exist,
        # every gui-agent log silently vanishes.
        @('LogDir', 'REG_SZ', 'C:\Program Files\Qubes Tools\log')
    )
    foreach ($s in $seed) {
        & reg.exe add $regPath /v $s[0] /t $s[1] /d $s[2] /f /reg:64 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "reg add failed for $($s[0])" }
    }
    Write-Log 'seeded gui-agent registry defaults (SeamlessMode=1, DisableCursor=0, LogDir)'
}

# ------------------------------------------------------- pre-existing QWT: detect/remove
# Files this package delivers into the QWT bin directory and that Windows Installer will
# refuse to overwrite if a same-or-newer-versioned copy is already there. Kept in sync
# with MANIFEST.json -> reference_binaries at run time; this is the fallback list.
$script:OurBinaries    = @('gui-agent.exe', 'gui-watchdog.exe')
$script:DefaultBinDir  = 'C:\Program Files\Qubes Tools\bin'
$script:GuiWatchdogSvc = 'QubesGuiWatchdog'

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
        $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
            '/x', $p.ProductCode, '/qn', '/norestart',
            'REBOOT=ReallySuppress', '/l*v', "`"$log`""
        )
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

# ------------------------------------------------------------------------------- stage 1
function Invoke-Stage1 {
    param([Parameter(Mandatory)][string]$Root)

    $script:Result.stage = 'stage1-prepare'

    # --- certificates -------------------------------------------------------------
    # Root  : makes the self-signed publisher chain valid.
    # TrustedPublisher : stops the "install this device software?" trust prompt, which
    #                    nobody is there to click during an unattended msiexec /qn.
    $certDir = Join-Path $Root 'certs'
    $certs = @(Get-ChildItem -LiteralPath $certDir -Filter *.cer -ErrorAction SilentlyContinue)
    if ($certs.Count -lt 2) { Fail "expected the QWT signing certs in $certDir, found $($certs.Count)" }
    foreach ($c in $certs) {
        foreach ($store in 'Root', 'TrustedPublisher') {
            & certutil.exe -addstore -f $store $c.FullName | Out-Null
            if ($LASTEXITCODE -ne 0) { Fail "certutil -addstore $store failed for $($c.Name)" }
        }
        Write-Log "trusted $($c.Name) (Root + TrustedPublisher)"
    }
    $script:Result.detail.certs_installed = $certs.Count

    Set-GuiAgentRegistryDefaults

    # --- testsigning ----------------------------------------------------------------
    & bcdedit.exe /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'bcdedit /set testsigning on failed (Secure Boot enabled?)' }
    Write-Log 'testsigning enabled for the NEXT boot'

    $script:Result.ok = $true
    $script:Result.reboot_needed = $true
    $script:Result.detail.next = 'reboot, then stage 2 installs QWT'

    $self = Join-Path $Root 'Install-QwtImproved.ps1'
    if ($Auto) {
        $extra = @()
        if ($InstallIddDriver) { $extra += '-InstallIddDriver' }
        if ($NoPvNetwork)      { $extra += '-NoPvNetwork' }
        $extra += '-Auto'
        Set-BootResume -ScriptPath $self -ExtraArgs $extra
        Write-Log 'STAGE 1 COMPLETE - rebooting in 15 s, installation resumes automatically'
        Emit-ResultThenReboot 10
    }
    Write-Log 'STAGE 1 COMPLETE'
    Write-Log "Now REBOOT, then run again elevated:  $self"
    Emit-Result 10
}

function Emit-ResultThenReboot {
    param([int]$ExitCode)
    $json = $script:Result | ConvertTo-Json -Depth 6 -Compress
    Write-Host '=== RESULT ==='
    Write-Host $json
    try { Add-Content -LiteralPath $script:LogFile -Value "=== RESULT === $json" -Encoding UTF8 } catch { }
    & shutdown.exe /r /t 15 /c 'Qubes Windows Tools setup' | Out-Null
    exit $ExitCode
}

# ------------------------------------------------------------------------------- stage 2
function Invoke-Stage2 {
    param([Parameter(Mandatory)][string]$Root)

    $script:Result.stage = 'stage2-install'

    # If we got here from the -Auto boot task, retire it first: a task left armed would
    # re-run the whole install on every subsequent boot.
    Clear-BootResume

    # Certs again: stage 1 may have run from the CD in a previous boot, and re-adding is
    # idempotent. Cheap insurance against a half-prepared machine.
    $certDir = Join-Path $Root 'certs'
    foreach ($c in @(Get-ChildItem -LiteralPath $certDir -Filter *.cer)) {
        foreach ($store in 'Root', 'TrustedPublisher') {
            & certutil.exe -addstore -f $store $c.FullName | Out-Null
        }
    }

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
            Stop-QwtRuntime
            $needReboot = Uninstall-ExistingQwt -Products $existing
            $still = @(Get-InstalledQwt)
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
                $self = Join-Path $Root 'Install-QwtImproved.ps1'
                if ($Auto) {
                    $extra = @()
                    if ($InstallIddDriver) { $extra += '-InstallIddDriver' }
                    if ($NoPvNetwork)      { $extra += '-NoPvNetwork' }
                    $extra += '-Auto'
                    $extra += '-ResumeAfterUninstall'
                    Set-BootResume -ScriptPath $self -ExtraArgs $extra
                    Write-Log 'removing the previous QWT requires a reboot - rebooting in 15 s, the install resumes automatically'
                    Emit-ResultThenReboot 10
                }
                Write-Log 'removing the previous QWT requires a reboot'
                Write-Log "REBOOT NOW, then run again elevated:  $self"
                Emit-Result 10
            }
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
    # Deliberately OMITTED: PvDriversDisk (documented BSOD risk), MoveUsers (BootExecute
    # relocation of C:\Users), Autologon (randomises the local password).
    $features = @('PvDriversCore', 'Core', 'Gui')
    if (-not $NoPvNetwork) { $features += 'PvDriversNetwork' }
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
    Write-Log "running msiexec ADDLOCAL=$addlocal (verbose log: $msiLog)"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart',
        "ADDLOCAL=$addlocal", 'REBOOT=ReallySuppress', 'REINSTALLMODE=amus',
        'MSIFASTINSTALL=7',
        '/l*v', "`"$msiLog`""
    )
    if ($p.ExitCode -notin 0, 3010) { Fail "msiexec failed with $($p.ExitCode) - see $msiLog" }
    Write-Log "QWT_INSTALL_OK rc=$($p.ExitCode)"
    $script:Result.detail.msiexec_rc = $p.ExitCode
    $script:Result.detail.addlocal = $addlocal

    # --- prove the install put OUR agent on disk ------------------------------------
    # Without this the script would report success for an install that silently kept a
    # previously present stock binary.
    $installed = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
    if (-not (Test-Path -LiteralPath $installed)) {
        Fail "msiexec reported success but $installed does not exist"
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

    # --- optional: stage the experimental IddCx driver ------------------------------
    $script:Result.detail.idd_driver = 'not requested'
    if ($InstallIddDriver) {
        $iddDir = Join-Path $Root 'idd-driver'
        $inf = @(Get-ChildItem -LiteralPath $iddDir -Filter *.inf -ErrorAction SilentlyContinue)
        if ($inf.Count -ne 1) {
            Fail "-InstallIddDriver requested but $iddDir holds $($inf.Count) .inf files (expected exactly 1)"
        }
        Write-Log "staging driver package $($inf[0].Name) into the driver store"
        $out = & pnputil.exe /add-driver $inf[0].FullName /install 2>&1
        $out | ForEach-Object { Write-Log "  pnputil: $_" }
        if ($LASTEXITCODE -ne 0) { Fail "pnputil /add-driver failed ($LASTEXITCODE)" }
        # Deliberately NOT activated: creating the software device would add a SECOND
        # monitor and enlarge the desktop bounding box the GUI agent maps as the screen,
        # which breaks seamless coordinates. See README.txt.
        $script:Result.detail.idd_driver = 'staged in driver store, NOT activated'
    }

    $script:Result.ok = $true
    $script:Result.reboot_needed = $true
    Write-Log 'STAGE 2 COMPLETE - QWT installed. A reboot is required for the drivers to bind.'

    if ($Auto) {
        Write-Log 'rebooting in 15 s'
        Emit-ResultThenReboot 0
    }
    Write-Log 'Reboot now; qrexec should answer roughly a minute after the guest comes back.'
    Emit-Result 0
}

# ---------------------------------------------------------------------------------- main
try {
    Write-Log '================================================================'
    Write-Log 'Qubes Windows Tools (improved GUI agent) - setup'
    Assert-Elevated

    $src = $PSScriptRoot
    if (-not $src) { Fail 'cannot determine script directory' }
    Write-Log "payload source: $src"

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
