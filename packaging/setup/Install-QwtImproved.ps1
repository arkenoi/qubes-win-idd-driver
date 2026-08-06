<#
.SYNOPSIS
    Install Qubes Windows Tools 4.2.2 (rebuilt from source with the improved GUI agent)
    onto a CLEAN Windows guest.

.DESCRIPTION
    This is a FULL install, not an overlay: it runs the real QWT installer.msi produced by
    the `qwt-full` CI workflow, which contains our gui-agent.exe / gui-watchdog.exe and
    every other component bit-identical to the shipped ITL 4.2.2 MSI.

    Two stages, because our binaries are TEST-SIGNED and Windows must be rebooted after
    `bcdedit /set testsigning on` before it will load them:

      stage 1  copy payload to disk, verify hashes, trust the signing certificates,
               seed the gui-agent registry defaults, enable testsigning, reboot
      stage 2  verify testsigning is active, install vc_redist, run msiexec, optionally
               stage the (experimental) IddCx driver, reboot

    The stage is DETECTED, not remembered: if testsigning is not active in the current
    boot we are in stage 1, otherwise stage 2. Re-running the script is safe.

.PARAMETER Auto
    Reboot automatically at the end of each stage and resume via RunOnce. Without it the
    script stops and tells you to reboot and re-run.

.PARAMETER InstallIddDriver
    Also stage the experimental Qubes IddCx display driver into the driver store. It is
    NOT activated (no monitor is created) - see README.txt. Default: off.

.PARAMETER NoPvNetwork
    Drop PvDriversNetwork from ADDLOCAL. See the NETWORKING caveat in README.txt.

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

    # --- gui-agent registry defaults ----------------------------------------------
    # The MSI only seeds these when its AppSearch does NOT already find them (conditions
    # NOT GUI_SEAMLESS_SET / NOT GUI_CURSOR_SET / NOT LOG_DIR_SET), so writing them first
    # makes ours win. /reg:64 because the MSI's RegLocator is 64-bit; a WOW-redirected
    # write would simply be invisible to it.
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
    Write-Log "running msiexec ADDLOCAL=$addlocal (verbose log: $msiLog)"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart',
        "ADDLOCAL=$addlocal", 'REBOOT=ReallySuppress', 'MSIFASTINSTALL=7',
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
