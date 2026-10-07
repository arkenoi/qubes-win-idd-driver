<#
.SYNOPSIS
    Offline suite for the serialized service start after msiexec AND the qrexec hold through the stage-2 device work
    (docs/ADR-boot.md 1 and 2; the installer's SVC-SERIAL-START, POST-MSI-ORDER, QREXEC-RELEASE, FAIL-PATH, MAIN-CATCH,
    EMIT-RESULT and POWEROFF regions): after msiexec QdbDaemon is started and observed RUNNING and READY (the local qubesdb
    answers /name) before any further step of stage 2; QrexecAgent is HELD - started, observed RUNNING, only after the
    stage's last device-work step, or by every exit path after msiexec that does not power off (Fail, the main catch, a
    refused power-off), and not at all on the -Auto -RebootAtEnd path, where the RESULT says so; QubesGuiWatchdog is held
    for the quiesce; a service that never starts is a loud, flagged failure; a RESULT written with QrexecAgent still held
    is flagged; the MSI is refused if it would start the services itself, and reported if it did anyway. Runs under pwsh
    on Linux: no rig, no guest, no SCM, no qubesdb, no Windows Installer.

.DESCRIPTION
    Each region is extracted from the SHIPPED installer by its marker lines (never by brace-hunting) and dot-sourced
    into a scope that provides what the surrounding script would. The world: a service table (status, whether a start
    throws, how long until RUNNING, how long until qubesdb answers), a fake clock that Start-Sleep and WaitForStatus
    advance, a scripted Windows Installer database for the contract check, a shutdown.exe whose exit code the scenario
    sets, and recorders in place of every other stage-2 step the POST-MSI-ORDER region calls (xenbus_monitor stop, sweep,
    recovery, event source, death reporter) - so the ORDER of what stage 2 does after msiexec is measured, not read off
    the code.
      shipped    static: GUARD anchors once each; both msiexec /i argument lists carry QWTNG_SERIALSTART=1; nothing
                 between msiexec and the serialized start but the sweep, the monitor stop and the MSI-start check; no
                 fixed pause, no kill in the region; the region follows msiexec directly; the QREXEC-RELEASE site sits
                 after the LAST device-work step of stage 2 and before the ok= grading, the watchdog restore and the
                 RESULT; nothing starts QrexecAgent between the serialized start and that site
      clean      the recorded order; the watchdog never started and held; QrexecAgent held; the RESULT narrative; no flags
      pacing     the first step after the serialized start runs only after QdbDaemon is observed RUNNING and READY
      release    after the device work QrexecAgent is started and observed RUNNING, recorded with its site and the hold's
                 length; idempotent; on -Auto -RebootAtEnd it is NOT started and the RESULT says so; a release that never
                 reaches RUNNING is flagged; an agent the MSI had started, or one not attempted, is not held
      poweroff   a refused shutdown starts the held QrexecAgent before the second RESULT; an accepted one starts nothing
      failure    never RUNNING / start throws / never ready / absent: ERROR, svc_serial_start_failed, the dependents
                 not attempted, the stage continues (recovery, event source, reporter still run)
      violation  services found running right after msiexec are recorded in svc_msi_started (error-class)
      contract   an MSI whose StartServices row carries the condition passes; one without, one with no row, and an
                 unreadable database are REFUSED (Fail) before msiexec
      retry      the second start after the ADDLOCAL-only retry observes the running QdbDaemon and holds QrexecAgent again
      quiesce    the GUI-QUIESCE block counts a held watchdog as quiesced (so the end of the stage restores it)
      maincatch  an exception during the device work starts the held QrexecAgent before the RESULT
      emit       a RESULT written with QrexecAgent still held records NEVER-STARTED (error-class); released or never
                 held, nothing is added
      failpath   a Fail after msiexec starts QdbDaemon (if not yet) and the held QrexecAgent before the RESULT
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces one defect in the extracted copy (the shipped file is never modified) at a '# GUARD:<name>' line:
      msicontract       the unconditioned MSI is run anyway (WARN, no Fail)
      noviolation       MSI-started services are never reported
      startwatchdog     the watchdog is started like the MSI did (and stopped seconds later by the quiesce)
      nowaitrunning     RUNNING is assumed, not observed through the SCM
      nowaitready       readiness is assumed - the device work starts on top of an unsynced qubesdb
      silentfail        a failed start is a WARN with no flag
      serialfirst       the death reporter is registered BEFORE the services are started
      noserialstart     stage 2 never starts the services at all
      startonexit       an early exit after msiexec leaves the services stopped
      failstart         a Fail after msiexec writes the RESULT before the services are started
      msinostart        QWTNG_SERIALSTART=1 is not passed to msiexec
      noholdqrexec      QrexecAgent is started right after QdbDaemon, before the device work (ADR-boot 1 alone)
      releaseunobserved the release starts QrexecAgent without observing RUNNING
      qrexecsilentfail  a release that never reaches RUNNING is not flagged
      noreleasestart    the QREXEC-RELEASE site never starts QrexecAgent
      startonpoweroff   the -Auto -RebootAtEnd path starts QrexecAgent seconds before the power-off
      releaseearly      the release call moves to right after the serialized start (in the in-memory copy of the file)
      regionearly       the whole QREXEC-RELEASE region moves to right after the serialized start (in-memory copy)
      releasetwice      the power-off skip also marks the hold released, so a refused power-off starts nothing (in-memory copy)
      noqrexecflag      the ok= block no longer grades svc_qrexec_start_failed (in-memory copy)
      deployinhold      the Windows Update agent deploy moves back inside the qrexec hold, before the release (in-memory copy)
      failrelease       a Fail after msiexec writes the RESULT with QrexecAgent still held
      catchrelease      the main catch writes the RESULT with QrexecAgent still held
      poweroffrefused   a refused power-off writes its second RESULT with QrexecAgent still held
      emitcheck         Emit-Result writes a RESULT with QrexecAgent still held and says nothing
    tools/tests/svc-serial-start-selftest.sh runs the clean leg and every knob and requires each knob to FAIL its target.
#>
[CmdletBinding()]
param([string]$Defect = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
$installerRel = 'packaging/setup/Install-QwtImproved.ps1'

$script:run = 0; $script:nfail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:nfail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    Microsoft.PowerShell.Utility\Write-Host "$tag $name$suffix"
}

# --- the shipped file, in memory --------------------------------------------------------------------------------------
$instLines = @(Get-Content -LiteralPath (Join-Path $repoRoot $installerRel))
function Idx([string]$literal) { @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Contains($literal) }) }
function IdxRx([string]$rx) { @(0..($instLines.Count - 1) | Where-Object { $instLines[$_] -match $rx }) }

# FILE-LEVEL knobs: the static "shipped" checks below read the file as a whole (where the release sits, what sets and clears
# the hold, what the ok= block grades), so their defects are re-introduced in the in-memory copy of the file BEFORE the
# regions are extracted - the shipped file is never modified. The other knobs patch an extracted region further down.
function Must-One([int[]]$ix, [string]$what) { if ($ix.Count -ne 1) { Microsoft.PowerShell.Utility\Write-Host "FAIL defect ${Defect}: expected exactly one $what, found $($ix.Count)"; exit 1 } }
switch ($Defect) {
    'releaseearly' {
        # the release CALL moves from the QREXEC-RELEASE site to right after the serialized start
        $siteIdx = IdxRx '# GUARD:releaseafterdevicework$'; $sfIdx = IdxRx '# GUARD:serialfirst$'
        Must-One $siteIdx 'GUARD:releaseafterdevicework line'; Must-One $sfIdx 'GUARD:serialfirst line'
        $patched = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $instLines.Count; $i++) {
            if ($i -eq $siteIdx[0]) { $patched.Add('        # DEFECT (releaseearly): the release moved to right after the serialized start'); continue }
            $patched.Add($instLines[$i])
            if ($i -eq $sfIdx[0]) { $patched.Add("        [void](Start-HeldQrexecAgent -Site 'after-device-work')   # DEFECT (releaseearly): QrexecAgent starts before the device work") }
        }
        $instLines = @($patched)
    }
    'regionearly' {
        # the whole QREXEC-RELEASE REGION (markers and all) moves to right after the serialized start - before the device work
        $rb = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QREXEC-RELEASE-BEGIN*' })
        $re = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QREXEC-RELEASE-END*' })
        $sfIdx = IdxRx '# GUARD:serialfirst$'
        Must-One $rb 'QREXEC-RELEASE-BEGIN'; Must-One $re 'QREXEC-RELEASE-END'; Must-One $sfIdx 'GUARD:serialfirst line'
        $region = @($instLines[$rb[0]..$re[0]])
        $patched = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $instLines.Count; $i++) {
            if ($i -ge $rb[0] -and $i -le $re[0]) { continue }
            $patched.Add($instLines[$i])
            if ($i -eq $sfIdx[0]) { foreach ($l in $region) { $patched.Add($l) } }
        }
        $instLines = @($patched)
    }
    'releasetwice' {
        # the power-off skip ALSO marks the hold released, so a refused power-off finds nothing to start
        $skipIdx = IdxRx 'QrexecAgent NOT started in this stage: the guest powers off now'
        Must-One $skipIdx 'power-off skip log line'
        $patched = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $instLines.Count; $i++) {
            $patched.Add($instLines[$i])
            if ($i -eq $skipIdx[0]) { $patched.Add('    $script:QrexecAgentReleased = $true   # DEFECT (releasetwice): the skip marks the hold released') }
        }
        $instLines = @($patched)
    }
    'deployinhold' {
        # the UPDATER-DEPLOY region (with its header comment) moves back to just before the QREXEC-RELEASE region - inside the hold
        $ub = IdxRx '^\s*# --- Windows Update agent \(default ON'; $ue = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -eq '# ---- UPDATER-DEPLOY-END' })
        $rb = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QREXEC-RELEASE-BEGIN*' })
        Must-One $ub 'Windows Update agent header'; Must-One $ue 'UPDATER-DEPLOY-END'; Must-One $rb 'QREXEC-RELEASE-BEGIN'
        $region = @($instLines[$ub[0]..$ue[0]])
        $patched = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $instLines.Count; $i++) {
            if ($i -ge $ub[0] -and $i -le $ue[0]) { continue }
            if ($i -eq $rb[0]) { foreach ($l in $region) { $patched.Add($l) } }
            $patched.Add($instLines[$i])
        }
        $instLines = @($patched)
    }
    'noqrexecflag' {
        # the ok= block no longer grades a failed release
        $flagIdx = IdxRx "\`$errFlags \+= 'svc_qrexec_start_failed'"
        Must-One $flagIdx 'svc_qrexec_start_failed errFlags line'
        $instLines = @(0..($instLines.Count - 1) | Where-Object { $_ -ne $flagIdx[0] } | ForEach-Object { $instLines[$_] })
    }
    default { }
}

# --- extraction by marker ------------------------------------------------------------------------------------------
function Get-Region([string]$name) {
    $b = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $e = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like "# ---- $name-END*" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $b[0] -ge $e[0]) {
        Microsoft.PowerShell.Utility\Write-Host "FAIL marker extraction ${name}: expected exactly one BEGIN before one END, got $($b.Count)/$($e.Count)"
        exit 1
    }
    return ,@($instLines[($b[0] + 1)..($e[0] - 1)])
}
$R = [ordered]@{
    'serial'    = Get-Region 'SVC-SERIAL-START'
    'postmsi'   = Get-Region 'POST-MSI-ORDER'
    'failpath'  = Get-Region 'FAIL-PATH'
    'quiesce'   = Get-Region 'GUI-QUIESCE'
    'svcstop'   = Get-Region 'SVC-STOP'
    'release'   = Get-Region 'QREXEC-RELEASE'
    'maincatch' = Get-Region 'MAIN-CATCH'
    'emit'      = Get-Region 'EMIT-RESULT'
    'poweroff'  = Get-Region 'POWEROFF'
}
# The two lines that build the main msiexec argument list: the property line and the array it goes into.
$propLineIdx = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_] -match '^\s*\$serialProp = ' })
$argsLineIdx = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_] -match '^\s*\$msiArgs = @\(' })
Check 'extract: exactly one $serialProp line and one $msiArgs = @(...) line in the installer' ($propLineIdx.Count -eq 1 -and $argsLineIdx.Count -eq 1 -and $propLineIdx[0] -lt $argsLineIdx[0]) "prop=$($propLineIdx -join ',') args=$($argsLineIdx -join ',')"
$R['msiargs'] = @($instLines[$propLineIdx[0]], $instLines[$argsLineIdx[0]])

function Get-CodeLines([string[]]$region) { @($region | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } | ForEach-Object { ($_ -split '\s#')[0] }) }

# --- shipped: static shapes, on the UNPATCHED regions --------------------------------------------------------------
$guards = @{ 'serial' = @('msicontract', 'noviolation', 'startwatchdog', 'nowaitrunning', 'nowaitready', 'silentfail', 'holdqrexec', 'qrexecrelease', 'qrexecsilentfail')
             'postmsi' = @('serialfirst', 'startonexit'); 'failpath' = @('failstart', 'failrelease'); 'msiargs' = @('msinostart')
             'release' = @('skiponpoweroff', 'releaseafterdevicework'); 'maincatch' = @('catchrelease'); 'emit' = @('emitcheck'); 'poweroff' = @('poweroffrefused') }
foreach ($k in $guards.Keys) {
    foreach ($g in $guards[$k]) {
        Check "shipped: exactly one '# GUARD:$g' anchor in $k" (@($R[$k] | Where-Object { $_ -match "# GUARD:$g`$" }).Count -eq 1)
    }
}
$serialCode = Get-CodeLines $R['serial']
Check 'shipped: no Stop-Process / taskkill / .Kill( in SVC-SERIAL-START (it starts and observes, it never ends anything)' (@($serialCode | Where-Object { $_ -match 'Stop-Process|taskkill|\.Kill\(' }).Count -eq 0)
Check 'shipped: no fixed pause in SVC-SERIAL-START - the only Start-Sleep is the 250 ms sampling interval of the readiness wait' `
      (@($serialCode | Where-Object { $_ -match 'Start-Sleep' }).Count -eq 1 -and @($serialCode | Where-Object { $_ -match 'Start-Sleep -Milliseconds 250' }).Count -eq 1 -and @($serialCode | Where-Object { $_ -match 'Start-Sleep -Seconds' }).Count -eq 0)
Check 'shipped: SVC-SERIAL-START never names QubesGuiWatchdog in a Start-Service' (@($serialCode | Where-Object { $_ -match 'Start-Service' -and $_ -match 'QubesGuiWatchdog|GuiWatchdogSvc' }).Count -eq 0)
Check 'shipped: the service list is QdbDaemon, QrexecAgent, QubesGuiWatchdog in that (dependency) order' `
      (@($serialCode | Where-Object { $_ -match "QwtMsiServices = @\('QdbDaemon', 'QrexecAgent', 'QubesGuiWatchdog'\)" }).Count -eq 1)
Check 'shipped: the hold is set in one place (GUARD:holdqrexec) and cleared in one (Start-HeldQrexecAgent), both inside SVC-SERIAL-START' `
      (@($serialCode | Where-Object { $_ -match '\$script:QrexecAgentHeld = \$true' }).Count -eq 1 -and @($serialCode | Where-Object { $_ -match '\$script:QrexecAgentReleased = \$true' }).Count -eq 1 -and @($instLines | Where-Object { $_ -match '\$script:QrexecAgentReleased = \$true' }).Count -eq 1)
# POST-MSI-ORDER: before the serialized start there is nothing but the completion flag, the sweep, the monitor stop and the check.
$postCode = Get-CodeLines $R['postmsi']
$startAt = @(0..($postCode.Count - 1) | Where-Object { $postCode[$_] -match '^\s*Start-QwtServicesSerially\s*$' })
$before = @(); if ($startAt.Count -eq 1) { $before = @($postCode[0..($startAt[0] - 1)] | ForEach-Object { $_.Trim() }) }
Check 'shipped: nothing runs between msiexec and the serialized start but the completion flag, the try, the sweep, the xenbus_monitor stop and the MSI-start check' `
      ($startAt.Count -eq 1 -and $before.Count -eq 6 -and $before[0] -eq '$script:MsiInstallCompleted = $true' -and $before[1] -eq '$script:SerialStartDone = $false' -and
       $before[2] -eq 'try {' -and $before[3] -eq 'Remove-SweptAside' -and $before[4] -like 'Disable-XenbusMonitor*' -and $before[5] -eq 'Assert-NoServiceStartedByMsi') "startAt=$($startAt -join ',') before=[$($before -join ' | ')]"
$after = @(); if ($startAt.Count -eq 1 -and $startAt[0] -lt $postCode.Count - 1) { $after = @($postCode[($startAt[0] + 1)..($postCode.Count - 1)] | ForEach-Object { $_.Trim() }) }
Check 'shipped: after the serialized start only the done-flag and the early-exit finally, then recovery arming, the Event Log source and the death reporter, in that order' `
      ($after.Count -eq 11 -and $after[0] -eq '$script:SerialStartDone = $true' -and $after[1] -eq '} finally {' -and $after[2] -like 'if (-not $script:SerialStartDone) {*' -and
       $after[4] -like 'try { Start-QwtServicesSerially }*' -and $after[5] -eq '$script:SerialStartDone = $true' -and $after[8] -eq 'Set-QubesServiceRecovery' -and
       $after[9] -eq 'Register-QwtEventSource' -and $after[10] -like 'Register-QwtDeathReporter*') "after=[$($after -join ' | ')]"
# The region follows the msiexec call directly: between the last `-ArgumentList $msiArgs` and the BEGIN marker there is only
# the loop tail (the 1618 retry, the exit-code Fail, two detail records), no device step.
$beginIdx = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- POST-MSI-ORDER-BEGIN*' })[0]
$msiCallIdx = @(0..($beginIdx - 1) | Where-Object { $instLines[$_] -match 'Start-Process msiexec\.exe .*-ArgumentList \$msiArgs' })
$between = @(); if ($msiCallIdx.Count -eq 1) { $between = @($instLines[($msiCallIdx[0] + 1)..($beginIdx - 1)] | Where-Object { $_ -notmatch '^\s*#' }) }
Check 'shipped: the POST-MSI-ORDER region starts right after the msiexec call (only the 1618 retry tail and the exit-code check between)' `
      ($msiCallIdx.Count -eq 1 -and ($beginIdx - $msiCallIdx[0]) -le 25 -and @($between | Where-Object { $_ -match 'pnputil|devcon|Disable-PnpDevice|Register-Qwt|Set-QubesServiceRecovery|Get-Disk|Get-CimInstance|schtasks|Start-Service|Stop-Service' }).Count -eq 0) "msiCall=$($msiCallIdx -join ',') begin=$beginIdx"
# Both msiexec /i sites carry the property; the only other msiexec is the /x uninstall.
$msiexecSites = @($instLines | Where-Object { $_ -match 'Start-Process msiexec\.exe' })
$retryIdx = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_] -match '^\s*\$retryArgs = @\(' })
Check 'msiexec: exactly three msiexec sites - /i with $msiArgs, /i with $retryArgs, and the /x uninstall' `
      ($msiexecSites.Count -eq 3 -and @($msiexecSites | Where-Object { $_ -match '-ArgumentList \$msiArgs\b' }).Count -eq 1 -and @($msiexecSites | Where-Object { $_ -match '-ArgumentList \$retryArgs\b' }).Count -eq 1) "sites=$($msiexecSites.Count)"
Check 'msiexec: the ADDLOCAL-only retry argument list carries $serialProp too' ($retryIdx.Count -eq 1 -and $instLines[$retryIdx[0]] -match '\$serialProp')
Check 'msiexec: the retry is followed by a second serialized start (-AfterRetry)' `
      ($retryIdx.Count -eq 1 -and @($instLines[$retryIdx[0]..([math]::Min($retryIdx[0] + 20, $instLines.Count - 1))] | Where-Object { $_ -match '^\s*Start-QwtServicesSerially -AfterRetry\s*$' }).Count -eq 1)
Check 'shipped: the stage-2 ok= block names svc_serial_start_failed, svc_qrexec_start_failed and svc_msi_started as error-class flags' `
      (@($instLines | Where-Object { $_ -match "\`$errFlags \+= 'svc_serial_start_failed'" }).Count -eq 1 -and @($instLines | Where-Object { $_ -match "\`$errFlags \+= 'svc_qrexec_start_failed'" }).Count -eq 1 -and @($instLines | Where-Object { $_ -match "\`$errFlags \+= 'svc_msi_started'" }).Count -eq 1)

# THE PLACE OF THE RELEASE (docs/ADR-boot.md 2), on the file: after the LAST device-work step of stage 2 and before the ok=
# grading, the watchdog restore (which depends on QrexecAgent) and the RESULT; inside Invoke-Stage2; and no start of
# QrexecAgent anywhere between the serialized start and that site.
$relBegin = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QREXEC-RELEASE-BEGIN*' })[0]
$relEnd   = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- QREXEC-RELEASE-END*' })[0]
$postEnd  = @(0..($instLines.Count - 1) | Where-Object { $instLines[$_].Trim() -like '# ---- POST-MSI-ORDER-END*' })[0]
$stage2At = (IdxRx '^function Invoke-Stage2')[0]
$emit0    = @((IdxRx '^\s*Emit-Result 0\s*$') | Where-Object { $_ -gt $stage2At })[0]
$deviceAnchors = @('pnputil.exe /add-driver $pvInf /install', 'pnputil.exe /add-driver $consInf /install', '& $devcon install $inf[0].FullName $iddHwId',
                   'Disable-PnpDevice -InstanceId $vgaDev.InstanceId', '$pp = & $deployPrime',
                   'reg add "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS', 'schtasks /create /tn QubesNetworkReapply',
                   "Disable-XenbusMonitor -Why 'final act: shipping state'", '/v PromptOnSecureDesktop /t REG_DWORD /d 0')
$afterAnchors  = @('$errFlags = @()', "Start-Service -Name 'QubesGuiWatchdog' -ErrorAction Stop", 'Emit-ResultThenPowerOff 0')
$misplaced = @()
foreach ($a in $deviceAnchors) { $ix = Idx $a; if ($ix.Count -ne 1 -or $ix[0] -le $postEnd -or $ix[0] -ge $relBegin) { $misplaced += "device[$a]=$($ix -join ',')" } }
foreach ($a in $afterAnchors)  { $ix = Idx $a; if ($ix.Count -ne 1 -or $ix[0] -le $relEnd -or $ix[0] -ge $emit0) { $misplaced += "after[$a]=$($ix -join ',')" } }
$fnBetween = @((IdxRx '^function ') | Where-Object { $_ -gt $stage2At -and $_ -lt $emit0 })
Check 'shipped: QrexecAgent is released only after the last device-work step of stage 2 (xenvif, xencons, the IDD device and the VGA disable, the PV NIC latch, the netvm task, the shipping state, the UAC policy) and before the ok= grading, the watchdog restore and the RESULT' `
      ($null -ne $relBegin -and $null -ne $relEnd -and $null -ne $emit0 -and $postEnd -lt $relBegin -and $relBegin -lt $relEnd -and $relEnd -lt $emit0 -and $stage2At -lt $relBegin -and $fnBetween.Count -eq 0 -and $misplaced.Count -eq 0) "rel=$relBegin..$relEnd postEnd=$postEnd emit0=$emit0 fnBetween=$($fnBetween -join ',') misplaced=[$($misplaced -join '; ')]"
# THE UPDATER DEPLOY IS NOT DEVICE WORK (2026-10-04): it runs AFTER the release - a deploy that waits for the previous updater's
# running boot scan must wait with qrexec up (the scan reaches dom0's update proxy over qrexec) - and BEFORE the ok= grading,
# which folds its updater_agent_failed flag.
$udIx = Idx '$ud = & $deployUpd -SetupRoot $Root'
$okIx = Idx '$errFlags = @()'
Check 'shipped: the Windows Update agent deploy runs after the QREXEC-RELEASE site and before the ok= grading that folds updater_agent_failed' `
      ($udIx.Count -eq 1 -and $okIx.Count -eq 1 -and $null -ne $relEnd -and $udIx[0] -gt $relEnd -and $udIx[0] -lt $okIx[0]) "deploy=$($udIx -join ',') relEnd=$relEnd ok=$($okIx -join ',')"
$sfLine = (IdxRx '# GUARD:serialfirst$')[0]
$midCode = @()
if ($null -ne $sfLine -and $null -ne $relBegin -and $sfLine -lt $relBegin) { $midCode = @($instLines[($sfLine + 1)..($relBegin - 1)] | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '\s#')[0] }) }
$midStarts = @($midCode | Where-Object { $_ -match 'Start-HeldQrexecAgent|Start-Service\b.*QrexecAgent|\bsc(\.exe)?\s+start\b|\bnet(\.exe)?\s+start\b' })
Check 'shipped: nothing starts QrexecAgent between the serialized start and the QREXEC-RELEASE site (no Start-HeldQrexecAgent, no Start-Service of it, no sc/net start)' `
      ($null -ne $sfLine -and $midStarts.Count -eq 0) "starts=[$(($midStarts | ForEach-Object { $_.Trim() }) -join ' | ')]"
$relCode = @((Get-CodeLines $R['release']) | ForEach-Object { $_.Trim() })
Check 'shipped: the QREXEC-RELEASE region is exactly the -Auto -RebootAtEnd skip or the observed start, nothing else' `
      ($relCode.Count -eq 5 -and $relCode[0] -eq 'if ($Auto -and $RebootAtEnd) {' -and $relCode[1] -eq 'Skip-HeldQrexecAgentForPowerOff' -and $relCode[2] -eq '} else {' -and $relCode[3] -eq "[void](Start-HeldQrexecAgent -Site 'after-device-work')" -and $relCode[4] -eq '}') "code=[$($relCode -join ' | ')]"

# --- defect knobs: patch the extracted copy, never the shipped file -------------------------------------------------
function Set-GuardLine([string[]]$region, [string]$guard, [string]$replacement) {
    $hit = @($region | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Microsoft.PowerShell.Utility\Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line, found $($hit.Count)"; exit 1 }
    return ,@($region | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } })
}
switch ($Defect) {
    '' { }
    { $_ -in 'releaseearly', 'regionearly', 'releasetwice', 'noqrexecflag', 'deployinhold' } { }   # file-level knobs, applied to the in-memory copy above
    'msicontract'   { $R['serial']  = Set-GuardLine $R['serial']  'msicontract'   "    Write-Log `$msg 'WARN'   # DEFECT: the un-paced MSI is run anyway" }
    'noviolation'   { $R['serial']  = Set-GuardLine $R['serial']  'noviolation'   '    if ($false) {   # DEFECT: an MSI-started service is never reported' }
    'startwatchdog' { $R['serial']  = Set-GuardLine $R['serial']  'startwatchdog' '            Start-Service -Name $svc -ErrorAction SilentlyContinue   # DEFECT: the watchdog is started as the MSI did (stopped seconds later by the quiesce)' }
    'nowaitrunning' { $R['serial']  = Set-GuardLine $R['serial']  'nowaitrunning' '            $running = $true   # DEFECT: RUNNING is assumed, not observed through the SCM' }
    'nowaitready'   { $R['serial']  = Set-GuardLine $R['serial']  'nowaitready'   '            $w = [ordered]@{ ready = $true; secs = 0; probes = 0 }   # DEFECT: readiness is assumed - the device work starts on top of an unsynced qubesdb' }
    'silentfail'    { $R['serial']  = Set-GuardLine $R['serial']  'silentfail'    "    if (`$failedSvc -ne '') { Write-Log `"serial start: `$failedSvc failed (continuing)`" 'WARN' }   # DEFECT: a failed start is a WARN with no flag" }
    'noholdqrexec'  { $R['serial']  = Set-GuardLine $R['serial']  'holdqrexec'    '            $r = Start-QwtServiceObserved -Name $svc -RunningTimeoutSec $RunningTimeoutSec -ReadyTimeoutSec $ReadyTimeoutSec; $narr[$svc] = $r.note; if (-not $r.ok) { $failedSvc = $svc }; continue   # DEFECT: QrexecAgent is started right after QdbDaemon, before the device work' }
    'releaseunobserved' { $R['serial'] = Set-GuardLine $R['serial'] 'qrexecrelease' "    Start-Service -Name 'QrexecAgent' -ErrorAction SilentlyContinue; `$r = [ordered]@{ ok = `$true; note = 'started (not observed)' }   # DEFECT: the release does not observe RUNNING" }
    'qrexecsilentfail' { $R['serial'] = Set-GuardLine $R['serial'] 'qrexecsilentfail' '    if ($false) {   # DEFECT: a release that never reaches RUNNING is not flagged' }
    'serialfirst'   { $R['postmsi'] = Set-GuardLine $R['postmsi'] 'serialfirst'   '    Register-QwtDeathReporter -Root $Root; Start-QwtServicesSerially   # DEFECT: a device step runs before the services are up' }
    'noserialstart' { $R['postmsi'] = Set-GuardLine $R['postmsi'] 'serialfirst'   '        # DEFECT: stage 2 never starts the services'; $R['postmsi'] = Set-GuardLine $R['postmsi'] 'startonexit' '        if ($false) {   # DEFECT (with noserialstart): no early-exit start either' }
    'startonexit'   { $R['postmsi'] = Set-GuardLine $R['postmsi'] 'startonexit'   '        if ($false) {   # DEFECT: an early exit after msiexec leaves the services stopped' }
    'failstart'     { $R['failpath'] = Set-GuardLine $R['failpath'] 'failstart'   '    if ($false) {   # DEFECT: a Fail after msiexec writes the RESULT before the services are started' }
    'failrelease'   { $R['failpath'] = Set-GuardLine $R['failpath'] 'failrelease' '    if ($false) {   # DEFECT: a Fail after msiexec writes the RESULT with QrexecAgent still held' }
    'msinostart'    { $R['msiargs'] = Set-GuardLine $R['msiargs'] 'msinostart'    "    `$serialProp = 'REBOOT=ReallySuppress'   # DEFECT: the property is not passed - the MSI starts the services itself" }
    'noreleasestart' { $R['release'] = Set-GuardLine $R['release'] 'releaseafterdevicework' '        # DEFECT: the stage ends with QrexecAgent still held' }
    'startonpoweroff' { $R['release'] = Set-GuardLine $R['release'] 'skiponpoweroff' "        [void](Start-HeldQrexecAgent -Site 'before-power-off')   # DEFECT: the agent is started seconds before the power-off" }
    'catchrelease'  { $R['maincatch'] = Set-GuardLine $R['maincatch'] 'catchrelease' '    # DEFECT: the main catch writes the RESULT with QrexecAgent still held' }
    'emitcheck'     { $R['emit'] = Set-GuardLine $R['emit'] 'emitcheck' '    if ($false) {   # DEFECT: a RESULT is written with QrexecAgent still held and nothing says so' }
    'poweroffrefused' { $R['poweroff'] = Set-GuardLine $R['poweroff'] 'poweroffrefused' '        # DEFECT: the refused power-off writes its second RESULT with QrexecAgent still held' }
    default { Microsoft.PowerShell.Utility\Write-Host "FAIL unknown -Defect '$Defect'"; exit 1 }
}
# The two process-ending writers are dot-sourced with their `exit` turned into a throw the scenarios catch.
foreach ($k in 'emit', 'poweroff') { $R[$k] = @($R[$k] | ForEach-Object { if ($_ -match '^\s*exit \$ExitCode\s*$') { '    throw "EXIT:$ExitCode"' } else { $_ } }) }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('svc-serial-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$F = @{}
foreach ($k in $R.Keys) {
    $F[$k] = Join-Path $tmpRoot "$k.ps1"
    [IO.File]::WriteAllLines($F[$k], [string[]]$R[$k], [Text.UTF8Encoding]::new($false))
}

# --- the fake world ------------------------------------------------------------------------------------------------
$script:W = $null
function New-World {
    param([hashtable[]]$Services = @(), [string]$QdbName = 'win10-acc', [string]$MsiCondition = 'VersionNT AND NOT QWTNG_SERIALSTART', [switch]$MsiNoRow, [switch]$MsiThrows, [int]$ShutdownRc = 0)
    $w = @{ svc = @{}; t0 = [datetime]'2026-10-04 10:28:19'; now = [datetime]'2026-10-04 10:28:19'
            calls = [System.Collections.Generic.List[string]]::new(); at = @{}
            log = [System.Collections.Generic.List[string]]::new(); fails = [System.Collections.Generic.List[string]]::new()
            qdbName = $QdbName; msiCond = $MsiCondition; msiNoRow = [bool]$MsiNoRow; msiThrows = [bool]$MsiThrows; probes = 0; shutdownRc = $ShutdownRc }
    foreach ($s in $Services) {
        # runningAfterSec: time from Start-Service to the SCM reporting RUNNING; readyAfterSec: time from the start until the
        # local qubesdb answers /name (-1 = never); neverRunning: START_PENDING for ever.
        $d = @{ name = ''; status = 'Stopped'; start = 'Automatic'; startThrows = $false; neverRunning = $false; runningAfterSec = 0.0; readyAfterSec = 0.0; startedAt = $null }
        foreach ($k in $s.Keys) { $d[$k] = $s[$k] }
        $w.svc[$d.name] = $d
    }
    $script:W = $w
}
function Secs() { [math]::Round(($script:W.now - $script:W.t0).TotalSeconds, 2) }
function Rec([string]$what) { $script:W.calls.Add($what); if (-not $script:W.at.ContainsKey($what)) { $script:W.at[$what] = Secs } }
function Logged([string]$pattern) { @($script:W.log | Where-Object { $_ -match $pattern }).Count -gt 0 }
function Calls() { ($script:W.calls -join ' ') }
function CountCalls([string]$what) { @($script:W.calls | Where-Object { $_ -eq $what }).Count }

# ---- mocks: the Windows the regions talk to, over $script:W ----
function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
    $s = $script:W.svc[$Name]
    if (-not $s) {
        if ($ErrorActionPreference -eq 'Stop') { throw "Cannot find any service with service name '$Name'." }
        return $null
    }
    $o = [pscustomobject]@{ Name = $Name; Status = $s.status; StartType = $s.start }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($st, $t)
        $d = $script:W.svc[$this.Name]
        if ($d.status -eq $st) { Rec "running:$($this.Name)"; return }
        $bound = [double]$t.TotalSeconds
        if ($st -eq 'Running' -and -not $d.neverRunning -and $d.status -eq 'StartPending' -and $d.runningAfterSec -le $bound) {
            $script:W.now = $script:W.now.AddSeconds($d.runningAfterSec)
            $d.status = 'Running'
            Rec "running:$($this.Name)"
            return
        }
        $script:W.now = $script:W.now.AddSeconds($bound)
        throw [System.ServiceProcess.TimeoutException]::new("Time out has expired and the operation has not been completed.")
    } -PassThru
}
function Start-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
    Rec "start:$Name"
    $s = $script:W.svc[$Name]
    if (-not $s) { throw "Cannot find any service with service name '$Name'." }
    if ($s.startThrows) { throw "Service '$Name' cannot be started due to the following error: Cannot start service $Name on computer '.'." }
    $s.startedAt = $script:W.now
    $s.status = 'StartPending'
    if ($s.runningAfterSec -eq 0 -and -not $s.neverRunning) { $s.status = 'Running' }
}
function Stop-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [switch]$Force)
    Rec "stop:$Name"; $s = $script:W.svc[$Name]; if ($s) { $s.status = 'Stopped' }
}
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    if ($ClassName -ne 'Win32_Service' -or $Filter -notmatch "Name='([^']+)'") { return $null }
    [pscustomobject]@{ Name = $Matches[1]; ProcessId = [uint32]0; State = 'Stopped' }
}
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id) }
function Start-Sleep { param([int]$Seconds = 0, [int]$Milliseconds = 0) $script:W.now = $script:W.now.AddMilliseconds($Seconds * 1000 + $Milliseconds) }
function Get-Date { param([string]$Format) if ($Format) { return $script:W.now.ToString('HH:mm:ss') }; return $script:W.now }
function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:W.log.Add("[$Level] $Message") }
function Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object) }   # the regions' Write-Host is noise here
function Fail { param([string]$Message) $script:W.fails.Add($Message); throw "FAIL: $Message" }
function Warn-DisplayBlackout { }
function Request-GuiAgentExit { param([int]$WaitMs = 5000) return @() }
function schtasks.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a) }
function shutdown.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a) Rec 'shutdown'; $global:LASTEXITCODE = $script:W.shutdownRc }
function Clear-BootResume { }
function Reset-AutoRunCounter { }
function Restore-SweptBinaries { }
# the other stage-2 steps the POST-MSI-ORDER region calls: recorders
function Remove-SweptAside { Rec 'sweep' }
function Disable-XenbusMonitor { param([string]$Why = '', [switch]$FatalIfSurvives) Rec 'xbm'; if ($script:W['xbmFails']) { Fail 'xenbus_monitor survived its stop (test world)' } }
function Set-QubesServiceRecovery { Rec 'recovery' }
# The stop regions disarm the SCM's recovery before stopping one of our services (R1, 2026-10-07): the SCM is a
# relauncher, and on a reinstall its actions were armed by the previous install. Recorded like every other call.
function Suspend-QubesServiceRecovery { param([Parameter(Mandatory)][string]$Name) Rec "disarm:$Name"; return $true }
function Resume-QubesServiceRecovery { param([string]$Name) Rec "rearm:$Name" }
function Register-QwtEventSource { Rec 'evsrc' }
function Register-QwtDeathReporter { param([string]$Root) Rec 'reporter' }
# the RESULT writer as a recorder; the shipped one is dot-sourced in its own scenario (emit) and the recorder restored after
function Set-EmitRecorder { Set-Item -Path function:global:Emit-Result -Value { param([int]$ExitCode) Rec 'emit'; throw "EMIT:$ExitCode" } }
Set-EmitRecorder

# the region's own functions, at script scope (the knob copy)
. $F['serial']
. $F['svcstop']
. $F['poweroff']
# ...and the two seams the region exposes for exactly this: the qubesdb probe and the Windows Installer COM surface.
function Read-QwtQubesDbValue { param([Parameter(Mandatory)][string]$Path)
    $script:W.probes++
    Rec "probe:$Path"
    $d = $script:W.svc['QdbDaemon']
    if (-not $d -or $d.status -ne 'Running' -or $null -eq $d.startedAt) { return $null }
    if ($d.readyAfterSec -lt 0) { return $null }
    if (($script:W.now - $d.startedAt).TotalSeconds -ge $d.readyAfterSec) { return $script:W.qdbName }
    return $null
}
function New-QwtMsiInstallerObject { return @{ kind = 'installer' } }
function Invoke-QwtComMember { param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Kind, [object[]]$Arguments = $null)
    Rec "com:$Name"
    switch ($Name) {
        'OpenDatabase' { if ($script:W.msiThrows) { throw 'OpenDatabase: the database could not be opened (0x80004005)' }; return @{ kind = 'db'; path = $Arguments[0] } }
        'OpenView'     { return @{ kind = 'view'; sql = $Arguments[0]; fetched = $false } }
        'Execute'      { return $null }
        'Fetch'        { if ($Object.fetched -or $script:W.msiNoRow) { return $null }; $Object.fetched = $true; return @{ kind = 'rec'; cond = $script:W.msiCond } }
        'StringData'   { return $Object.cond }
        default        { throw "unexpected COM member $Name" }
    }
}

$Root = 'C:\qwt-improved-setup'
$script:GuiWatchdogSvc = 'QubesGuiWatchdog'
$Auto = $false; $RebootAtEnd = $false
function Reset-Result {
    $script:Result = [ordered]@{ stage = 'stage2-install'; ok = $false; detail = [ordered]@{} }
    $script:GuiWatchdogHeld = $false; $script:GuiQuiesced = $false; $script:GuiQuiesceHeld = $false; $script:MsiInstallCompleted = $false
    $script:QrexecAgentHeld = $false; $script:QrexecAgentHeldAt = $null; $script:QrexecAgentReleased = $false
}
function Invoke-PostMsi { . $F['postmsi'] }
function Invoke-Quiesce { . $F['quiesce'] }
function Invoke-Release { . $F['release'] }
function Invoke-MsiArgs {
    # the two shipped lines, evaluated the way stage 2 does, under the knob copy
    $script:MsiSerialStartProperty = 'QWTNG_SERIALSTART'
    $msi = 'C:\qwt-improved-setup\msi\installer.msi'; $addlocal = 'PvDriversCore,Core,Gui'
    . ([scriptblock]::Create(($R['msiargs'] -join "`n")))
    return ,@($msiArgs)
}
$three = @(@{ name = 'QdbDaemon'; runningAfterSec = 0.4; readyAfterSec = 1.1 }, @{ name = 'QrexecAgent'; runningAfterSec = 0.3 }, @{ name = 'QubesGuiWatchdog' })

# ================================================================= msiexec arguments ================================
$args1 = Invoke-MsiArgs
Check 'msiexec: both /i argument lists carry QWTNG_SERIALSTART=1 (the main list evaluated, the retry list by reference)' `
      ($args1 -contains 'QWTNG_SERIALSTART=1' -and $args1[0] -eq '/i' -and $retryIdx.Count -eq 1 -and $instLines[$retryIdx[0]] -match '\$serialProp') "args=$($args1 -join ' ')"

# ================================================================= clean: the order after msiexec ==================
New-World -Services $three; Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'clean: the recorded order is sweep, xbm, start QdbDaemon, RUNNING, probes, recovery, evsrc, reporter - QrexecAgent is not started, nothing else runs' `
      ($thrown -eq '' -and (Calls) -match '^sweep xbm start:QdbDaemon running:QdbDaemon (probe:/name )+recovery evsrc reporter$') "thrown=$thrown calls=$(Calls)"
Check 'clean: QubesGuiWatchdog is never started by the serialized start and is recorded as held' `
      ($script:W.calls -notcontains 'start:QubesGuiWatchdog' -and $script:GuiWatchdogHeld -eq $true -and $script:W.svc['QubesGuiWatchdog'].status -eq 'Stopped' -and "$($script:Result.detail.svc_serial_start)" -match 'QubesGuiWatchdog=held-for-quiesce') "held=$($script:GuiWatchdogHeld) calls=$(Calls)"
Check 'clean: QrexecAgent is HELD by the serialized start - not started, Stopped, recorded held-for-device-work, the hold flag set with its clock, the log says why' `
      ($script:W.calls -notcontains 'start:QrexecAgent' -and $script:W.svc['QrexecAgent'].status -eq 'Stopped' -and $script:QrexecAgentHeld -eq $true -and $null -ne $script:QrexecAgentHeldAt -and $script:QrexecAgentReleased -eq $false -and
       "$($script:Result.detail.svc_serial_start)" -match 'QrexecAgent=held-for-device-work' -and (Logged 'serial start: QrexecAgent HELD - not started')) "held=$($script:QrexecAgentHeld) narr=$($script:Result.detail.svc_serial_start) calls=$(Calls)"
Check 'clean: svc_serial_start records QdbDaemon started/running/ready, QrexecAgent held, the watchdog held, with the seconds observed' `
      ("$($script:Result.detail.svc_serial_start)" -match '^QdbDaemon=started running=0\.4s ready=0\.[0-9]s; QrexecAgent=held-for-device-work; QubesGuiWatchdog=held-for-quiesce$' -and $script:Result.detail.svc_serial_start_secs -ge 1.1) "narr=$($script:Result.detail.svc_serial_start) secs=$($script:Result.detail.svc_serial_start_secs)"
Check 'clean: no failure flag, no MSI-start violation, the post-msiexec check logged that none was running' `
      (-not $script:Result.detail.Contains('svc_serial_start_failed') -and -not $script:Result.detail.Contains('svc_msi_started') -and (Logged 'none of the QWT services is running') -and $script:W.fails.Count -eq 0) "detail=$(($script:Result.detail.Keys) -join ',')"
Check 'pacing: QdbDaemon RUNNING is observed through the SCM before its first readiness probe' `
      ($script:W.at.ContainsKey('running:QdbDaemon') -and $script:W.at.ContainsKey('probe:/name') -and $script:W.calls.IndexOf('running:QdbDaemon') -lt $script:W.calls.IndexOf('probe:/name')) "calls=$(Calls)"
Check 'pacing: the first step after the serialized start (recovery arming) runs only after QdbDaemon is observed RUNNING and READY (clock: >= 1.1 s after QdbDaemon''s start; order: after the last probe)' `
      ($script:W.at.ContainsKey('recovery') -and ($script:W.at['recovery'] - $script:W.at['start:QdbDaemon']) -ge 1.1 -and $script:W.calls.LastIndexOf('probe:/name') -lt $script:W.calls.IndexOf('recovery') -and $script:W.probes -ge 2) "at=$($script:W.at['start:QdbDaemon'])->$($script:W.at['recovery']) probes=$($script:W.probes)"
Check 'order: nothing but the sweep, the xenbus_monitor stop and the MSI-start check runs before the serialized start completes (recovery/evsrc/reporter all after QdbDaemon READY, QrexecAgent not among them)' `
      ($script:W.calls.IndexOf('recovery') -gt $script:W.calls.LastIndexOf('probe:/name') -and $script:W.calls.IndexOf('evsrc') -gt $script:W.calls.IndexOf('recovery') -and $script:W.calls.IndexOf('reporter') -gt $script:W.calls.IndexOf('evsrc') -and $script:W.calls.IndexOf('xbm') -lt $script:W.calls.IndexOf('start:QdbDaemon') -and $script:W.calls -notcontains 'start:QrexecAgent') "calls=$(Calls)"

# ================================================================= release: after the device work ===================
# Same world, continuing: the stage's device work is done (the recorders above stand for it), the release site runs.
$Auto = $false; $RebootAtEnd = $false
$thrown = ''; try { Invoke-Release } catch { $thrown = "$_" }
Check 'release: after the device work QrexecAgent is started and observed RUNNING through the SCM (start, then RUNNING, after the last post-msiexec step)' `
      ($thrown -eq '' -and (CountCalls 'start:QrexecAgent') -eq 1 -and $script:W.calls.IndexOf('start:QrexecAgent') -gt $script:W.calls.IndexOf('reporter') -and $script:W.calls.IndexOf('running:QrexecAgent') -eq $script:W.calls.IndexOf('start:QrexecAgent') + 1 -and $script:W.svc['QrexecAgent'].status -eq 'Running') "thrown=$thrown calls=$(Calls)"
Check 'release: the RESULT records the site, the observed seconds and the hold''s length (svc_qrexec_start, svc_qrexec_held_secs), no failure flag, the hold released' `
      ("$($script:Result.detail.svc_qrexec_start)" -match '^after-device-work: started running=0\.3s$' -and $script:Result.detail.Contains('svc_qrexec_held_secs') -and ([double]$script:Result.detail.svc_qrexec_held_secs) -ge 0 -and -not $script:Result.detail.Contains('svc_qrexec_start_failed') -and $script:QrexecAgentReleased -eq $true -and (Logged 'qrexec release \(after-device-work\): starting QrexecAgent now')) "start=$($script:Result.detail.svc_qrexec_start) held=$($script:Result.detail.svc_qrexec_held_secs)"
$thrown = ''; try { [void](Start-HeldQrexecAgent -Site 'fail-path') } catch { $thrown = "$_" }
Check 'release: a later exit path (a Fail after the normal release) starts nothing twice and leaves the record as the first site wrote it' `
      ($thrown -eq '' -and (CountCalls 'start:QrexecAgent') -eq 1 -and "$($script:Result.detail.svc_qrexec_start)" -match '^after-device-work: ') "calls=$(Calls) start=$($script:Result.detail.svc_qrexec_start)"

# ================================================================= release: the -Auto -RebootAtEnd skip =============
New-World -Services $three; Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
$Auto = $true; $RebootAtEnd = $true
try { Invoke-Release } catch { $thrown += "$_" }
Check 'release: on the -Auto -RebootAtEnd path QrexecAgent is NOT started - the RESULT says not-started-powering-off (auto-start, next boot), the log says why, and the hold is NOT marked released' `
      ($thrown -eq '' -and $script:W.calls -notcontains 'start:QrexecAgent' -and "$($script:Result.detail.svc_qrexec_start)" -like 'not-started-powering-off: auto-start on the next boot (held *s)' -and $script:Result.detail.Contains('svc_qrexec_held_secs') -and
       (Logged 'QrexecAgent NOT started in this stage: the guest powers off now') -and $script:QrexecAgentReleased -eq $false -and $script:QrexecAgentHeld -eq $true) "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) released=$($script:QrexecAgentReleased) calls=$(Calls)"
# ...and the power-off itself: refused -> the guest stays up -> the hold is released before the second RESULT
$script:W.shutdownRc = 1190
$thrown = ''; try { Emit-ResultThenPowerOff 0 } catch { $thrown = "$_" }
Check 'poweroff: a refused shutdown starts the held QrexecAgent, observed, before the second RESULT (site power-off-refused, shutdown_rc recorded, ok:false)' `
      ($thrown -eq 'EMIT:1' -and $script:W.calls.IndexOf('shutdown') -lt $script:W.calls.IndexOf('start:QrexecAgent') -and $script:W.calls.IndexOf('start:QrexecAgent') -lt $script:W.calls.IndexOf('emit') -and $script:W.calls.IndexOf('running:QrexecAgent') -lt $script:W.calls.IndexOf('emit') -and
       "$($script:Result.detail.svc_qrexec_start)" -match '^power-off-refused: started running=0\.3s$' -and $script:Result.detail.shutdown_rc -eq 1190 -and $script:Result.ok -eq $false) "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) rc=$($script:Result.detail.shutdown_rc) calls=$(Calls)"
New-World -Services $three; Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
$Auto = $true; $RebootAtEnd = $true
try { Invoke-Release } catch { $thrown += "$_" }
$script:W.shutdownRc = 0
try { Emit-ResultThenPowerOff 0 } catch { $thrown += "$_" }
Check 'poweroff: an accepted shutdown starts nothing - the hold is left to the next boot''s auto-start (exit 0, no start, the skip record kept)' `
      ($thrown -eq 'EXIT:0' -and $script:W.calls -notcontains 'start:QrexecAgent' -and $script:W.calls -contains 'shutdown' -and "$($script:Result.detail.svc_qrexec_start)" -like 'not-started-powering-off:*' -and -not $script:Result.detail.Contains('svc_qrexec_never_started')) "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) calls=$(Calls)"
$Auto = $false; $RebootAtEnd = $false

# ================================================================= release failure ==================================
New-World -Services @(@{ name = 'QdbDaemon'; runningAfterSec = 0.4; readyAfterSec = 1.1 }, @{ name = 'QrexecAgent'; neverRunning = $true }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
try { Invoke-Release } catch { $thrown += "$_" }
Check 'release failure: a QrexecAgent that never reaches RUNNING at the release is flagged svc_qrexec_start_failed, with an ERROR line and a TIMEOUT narrative after the 60 s bound' `
      ($thrown -eq '' -and $script:Result.detail.svc_qrexec_start_failed -eq $true -and "$($script:Result.detail.svc_qrexec_start)" -match '^after-device-work: TIMEOUT: not RUNNING after 60s \(status StartPending\)$' -and (Logged '^\[ERROR\] qrexec release \(after-device-work\): QrexecAgent did NOT start')) "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) flag=$($script:Result.detail.svc_qrexec_start_failed)"
New-World -Services @(@{ name = 'QdbDaemon'; runningAfterSec = 0.4; readyAfterSec = 1.1 }, @{ name = 'QrexecAgent'; startThrows = $true }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
try { Invoke-Release } catch { $thrown += "$_" }
Check 'release failure: a Start-Service that throws at the release is recorded FAILED with the SCM''s message and flagged' `
      ($thrown -eq '' -and $script:Result.detail.svc_qrexec_start_failed -eq $true -and "$($script:Result.detail.svc_qrexec_start)" -match "^after-device-work: FAILED: Service 'QrexecAgent' cannot be started") "start=$($script:Result.detail.svc_qrexec_start)"

# ================================================================= early exit: a step before the start Fails =========
New-World -Services $three; Reset-Result; $script:W['xbmFails'] = $true
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'exit: a step between msiexec and the start that Fails still gets QdbDaemon started by the early-exit finally (the MSI no longer does), QrexecAgent held for the exit path, the watchdog held' `
      ($thrown -like 'FAIL: *' -and $script:W.calls -contains 'start:QdbDaemon' -and $script:W.calls -contains 'running:QdbDaemon' -and $script:W.calls -notcontains 'start:QrexecAgent' -and $script:QrexecAgentHeld -eq $true -and
       $script:W.calls -notcontains 'start:QubesGuiWatchdog' -and (Logged 'ended early')) "thrown=$thrown calls=$(Calls) held=$($script:QrexecAgentHeld)"

# ================================================================= failure: never RUNNING ===========================
New-World -Services @(@{ name = 'QdbDaemon'; neverRunning = $true }, @{ name = 'QrexecAgent' }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'failure: a service that never reaches RUNNING sets svc_serial_start_failed, logs ERROR, and its dependents are not attempted' `
      ($thrown -eq '' -and $script:Result.detail.svc_serial_start_failed -eq $true -and "$($script:Result.detail.svc_serial_start)" -match '^QdbDaemon=TIMEOUT: not RUNNING after 60s \(status StartPending\); QrexecAgent=not-attempted \(QdbDaemon failed\); QubesGuiWatchdog=held-for-quiesce$' -and (Logged '^\[ERROR\] serial start: QdbDaemon did not reach RUNNING within 60 s') -and $script:W.calls -notcontains 'start:QrexecAgent') "thrown=$thrown narr=$($script:Result.detail.svc_serial_start) flag=$($script:Result.detail.svc_serial_start_failed)"
Check 'failure: the stage continues into its defined steps after the loud failure (recovery, evsrc, reporter still run, in order, after it)' `
      ((Calls) -match 'start:QdbDaemon recovery evsrc reporter$') "calls=$(Calls)"
try { Invoke-Release } catch { $thrown += "$_" }
Check 'release: after a QdbDaemon failure QrexecAgent was not attempted and is not held - the release starts nothing on top of the failed dependency and records nothing of its own' `
      ($thrown -eq '' -and $script:W.calls -notcontains 'start:QrexecAgent' -and $script:QrexecAgentHeld -eq $false -and -not $script:Result.detail.Contains('svc_qrexec_start')) "thrown=$thrown held=$($script:QrexecAgentHeld) calls=$(Calls)"

# ================================================================= failure: Start-Service throws ====================
New-World -Services @(@{ name = 'QdbDaemon'; startThrows = $true }, @{ name = 'QrexecAgent' }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'failure: a Start-Service that throws is recorded as FAILED with the SCM''s message, flagged, dependents not attempted' `
      ($thrown -eq '' -and $script:Result.detail.svc_serial_start_failed -eq $true -and "$($script:Result.detail.svc_serial_start)" -match "^QdbDaemon=FAILED: Service 'QdbDaemon' cannot be started" -and "$($script:Result.detail.svc_serial_start)" -match 'QrexecAgent=not-attempted' -and $script:W.calls -notcontains 'start:QrexecAgent') "narr=$($script:Result.detail.svc_serial_start)"

# ================================================================= failure: RUNNING but never ready =================
New-World -Services @(@{ name = 'QdbDaemon'; runningAfterSec = 0.2; readyAfterSec = -1 }, @{ name = 'QrexecAgent' }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'failure: QdbDaemon RUNNING but /name never readable is a ready TIMEOUT after the 120 s bound, flagged; QrexecAgent is not started on top of it' `
      ($thrown -eq '' -and $script:Result.detail.svc_serial_start_failed -eq $true -and "$($script:Result.detail.svc_serial_start)" -match '^QdbDaemon=started running=0\.2s ready=TIMEOUT 120s; QrexecAgent=not-attempted' -and $script:W.calls -notcontains 'start:QrexecAgent' -and (Logged '^\[ERROR\] serial start: QdbDaemon is RUNNING but not ready after 120s')) "narr=$($script:Result.detail.svc_serial_start) probes=$($script:W.probes)"

# ================================================================= failure: a service the MSI did not register =======
New-World -Services @(@{ name = 'QrexecAgent' }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'failure: an absent QdbDaemon is recorded ABSENT, flagged, and QrexecAgent is not attempted' `
      ($thrown -eq '' -and $script:Result.detail.svc_serial_start_failed -eq $true -and "$($script:Result.detail.svc_serial_start)" -match '^QdbDaemon=ABSENT; QrexecAgent=not-attempted' -and $script:W.calls -notcontains 'start:QrexecAgent') "narr=$($script:Result.detail.svc_serial_start)"

# ================================================================= violation: the MSI started them anyway ============
New-World -Services @(@{ name = 'QdbDaemon'; status = 'Running'; startedAt = [datetime]'2026-10-04 10:28:00' }, @{ name = 'QrexecAgent'; status = 'Running' }, @{ name = 'QubesGuiWatchdog'; status = 'Running' }); Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
Check 'violation: services found running right after msiexec are recorded in svc_msi_started with an ERROR line, and are not restarted' `
      ($thrown -eq '' -and $script:Result.detail.svc_msi_started -eq 'QdbDaemon=Running,QrexecAgent=Running,QubesGuiWatchdog=Running' -and (Logged '^\[ERROR\] after msiexec: QdbDaemon=Running.*the serialized start did NOT hold') -and (Logged 'Started by:') -and @($script:W.calls | Where-Object { $_ -like 'start:*' }).Count -eq 0) "detail=$($script:Result.detail.svc_msi_started) calls=$(Calls)"
Check 'violation: the serialized start then observes them as already-running (no flag of its own) - a running QrexecAgent is observed, never stopped to be held' `
      ("$($script:Result.detail.svc_serial_start)" -match '^QdbDaemon=already-running ready=[0-9.]+s; QrexecAgent=already-running; QubesGuiWatchdog=held-for-quiesce$' -and -not $script:Result.detail.Contains('svc_serial_start_failed') -and $script:QrexecAgentHeld -eq $false) "narr=$($script:Result.detail.svc_serial_start) held=$($script:QrexecAgentHeld)"
try { Invoke-Release } catch { $thrown += "$_" }
Check 'release: an agent the MSI had started is not held - the release starts nothing and records nothing of its own (the violation is in svc_msi_started)' `
      ($thrown -eq '' -and @($script:W.calls | Where-Object { $_ -like 'start:*' }).Count -eq 0 -and -not $script:Result.detail.Contains('svc_qrexec_start')) "thrown=$thrown calls=$(Calls)"

# ================================================================= retry: the second serialized start ===============
New-World -Services @(@{ name = 'QdbDaemon'; status = 'Running'; startedAt = [datetime]'2026-10-04 10:28:00' }, @{ name = 'QrexecAgent'; status = 'Stopped'; runningAfterSec = 0.5 }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$script:Result.detail.svc_serial_start = 'first-pass-record'
$script:QrexecAgentHeld = $true; $script:QrexecAgentHeldAt = [datetime]'2026-10-04 10:28:10'   # the first pass held it
$thrown = ''; try { Start-QwtServicesSerially -AfterRetry } catch { $thrown = "$_" }
Check 'retry: -AfterRetry observes the running QdbDaemon, holds the Stopped QrexecAgent again (the hold''s clock untouched), holds the watchdog, and records under svc_serial_start_after_retry leaving the first record intact' `
      ($thrown -eq '' -and $script:Result.detail.svc_serial_start -eq 'first-pass-record' -and "$($script:Result.detail.svc_serial_start_after_retry)" -match '^QdbDaemon=already-running ready=[0-9.]+s; QrexecAgent=held-for-device-work; QubesGuiWatchdog=held-for-quiesce$' -and (Calls) -eq 'probe:/name' -and
       $script:QrexecAgentHeld -eq $true -and $script:QrexecAgentHeldAt -eq [datetime]'2026-10-04 10:28:10' -and -not $script:Result.detail.Contains('svc_serial_start_failed')) "thrown=$thrown narr=$($script:Result.detail.svc_serial_start_after_retry) calls=$(Calls) heldAt=$($script:QrexecAgentHeldAt)"

# ================================================================= contract: the MSI is asked before it runs =========
New-World; Reset-Result
$thrown = ''; $ret = $null; try { $ret = Assert-MsiSerialStartContract -MsiPath 'C:\qwt-improved-setup\msi\installer.msi' } catch { $thrown = "$_" }
Check 'contract: an MSI whose StartServices row carries the condition passes, records it, does not Fail' `
      ($thrown -eq '' -and $ret -eq $true -and $script:Result.detail.msi_startservices_condition -eq 'VersionNT AND NOT QWTNG_SERIALSTART' -and $script:W.fails.Count -eq 0 -and (Calls) -eq 'com:OpenDatabase com:OpenView com:Execute com:Fetch com:StringData') "thrown=$thrown calls=$(Calls)"
New-World -MsiCondition 'VersionNT'; Reset-Result
$thrown = ''; try { [void](Assert-MsiSerialStartContract -MsiPath 'C:\x\installer.msi') } catch { $thrown = "$_" }
Check 'contract: an MSI whose StartServices is not conditioned is REFUSED (Fail names the condition it found) before msiexec' `
      ($thrown -match '^FAIL: REFUSING to run msiexec: this MSI would start QWT''s services inside Windows Installer' -and $thrown -match "condition is 'VersionNT', which does not mention QWTNG_SERIALSTART" -and $script:W.fails.Count -eq 1 -and "$($script:Result.detail.msi_startservices_condition)" -like 'REFUSED:*') "thrown=$thrown"
New-World -MsiNoRow; Reset-Result
$thrown = ''; try { [void](Assert-MsiSerialStartContract -MsiPath 'C:\x\installer.msi') } catch { $thrown = "$_" }
Check 'contract: an MSI with no StartServices row at all is REFUSED' ($thrown -match 'has no StartServices row' -and $script:W.fails.Count -eq 1) "thrown=$thrown"
New-World -MsiThrows; Reset-Result
$thrown = ''; try { [void](Assert-MsiSerialStartContract -MsiPath 'C:\x\installer.msi') } catch { $thrown = "$_" }
Check 'contract: an unreadable MSI database is REFUSED (missing data fails, it is not "no condition")' ($thrown -match 'the MSI database could not be read \(OpenDatabase' -and $script:W.fails.Count -eq 1) "thrown=$thrown"

# ================================================================= quiesce: the held watchdog counts as quiesced =====
New-World -Services @(@{ name = 'QubesGuiWatchdog'; status = 'Stopped' }); Reset-Result
$script:GuiWatchdogHeld = $true
$thrown = ''; try { Invoke-Quiesce } catch { $thrown = "$_" }
Check 'quiesce: a watchdog the serialized start held (Stopped, never started) is counted as quiesced, so the end of the stage restores it' `
      ($thrown -eq '' -and $script:GuiQuiesced -eq $true -and $script:GuiQuiesceHeld -eq $true -and (Logged 'held by the serialized start') -and $script:Result.detail.gui_quiesced_for_stage2 -eq $true -and $script:W.calls -notcontains 'stop:QubesGuiWatchdog') "thrown=$thrown quiesced=$($script:GuiQuiesced) log=$($script:W.log -join ' | ')"
New-World -Services @(@{ name = 'QubesGuiWatchdog'; status = 'Stopped' }); Reset-Result
$thrown = ''; try { Invoke-Quiesce } catch { $thrown = "$_" }
Check 'quiesce: a Stopped watchdog nobody held is still "nothing to quiesce" (GuiQuiesced=false)' ($thrown -eq '' -and $script:GuiQuiesced -eq $false -and (Logged 'nothing to quiesce')) "thrown=$thrown"

# ================================================================= main catch: an exception during the device work ===
New-World -Services $three; Reset-Result
$thrown = ''; try { Invoke-PostMsi } catch { $thrown = "$_" }
try { try { throw 'the device work threw' } catch { . $F['maincatch'] } } catch { $thrown += "$_" }
Check 'maincatch: an unexpected exception during the device work starts the held QrexecAgent, observed, before the RESULT (site main-catch, ok:false, the message kept)' `
      ($thrown -eq 'EMIT:1' -and (CountCalls 'start:QrexecAgent') -eq 1 -and $script:W.calls.IndexOf('start:QrexecAgent') -lt $script:W.calls.IndexOf('emit') -and $script:W.calls.IndexOf('running:QrexecAgent') -lt $script:W.calls.IndexOf('emit') -and
       "$($script:Result.detail.svc_qrexec_start)" -match '^main-catch: started running=0\.3s$' -and $script:Result.ok -eq $false -and $script:Result.error -eq 'the device work threw') "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) calls=$(Calls)"

# ================================================================= emit: the shipped RESULT writer ===================
# The shipped Emit-Result replaces the recorder for these three checks (its exit is a throw in the extracted copy).
. $F['emit']
New-World -Services $three; Reset-Result
$script:QrexecAgentHeld = $true; $script:QrexecAgentHeldAt = $script:W.now; $script:QrexecAgentReleased = $false
$thrown = ''; try { Emit-Result 0 } catch { $thrown = "$_" }
Check 'emit: a RESULT written with QrexecAgent still held records NEVER-STARTED and svc_qrexec_never_started (error-class), and logs ERROR' `
      ($thrown -eq 'EXIT:0' -and $script:Result.detail.svc_qrexec_never_started -eq $true -and "$($script:Result.detail.svc_qrexec_start)" -like 'NEVER-STARTED: QrexecAgent was held through the device work*' -and (Logged '^\[ERROR\] NEVER-STARTED')) "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start)"
Reset-Result; $script:QrexecAgentHeld = $true; $script:QrexecAgentHeldAt = $script:W.now; $script:QrexecAgentReleased = $true
$thrown = ''; try { Emit-Result 0 } catch { $thrown = "$_" }
Check 'emit: a RESULT after the release carries no never-started flag' ($thrown -eq 'EXIT:0' -and -not $script:Result.detail.Contains('svc_qrexec_never_started') -and -not $script:Result.detail.Contains('svc_qrexec_start')) "thrown=$thrown detail=$(($script:Result.detail.Keys) -join ',')"
Reset-Result
$thrown = ''; try { Emit-Result 1 } catch { $thrown = "$_" }
Check 'emit: a RESULT with nothing held (stage 1, a Fail before msiexec) carries no never-started flag' ($thrown -eq 'EXIT:1' -and -not $script:Result.detail.Contains('svc_qrexec_never_started')) "thrown=$thrown"
Set-EmitRecorder

# ================================================================= Fail path: the start precedes the RESULT ==========
# LAST on purpose: this defines the SHIPPED Fail (the knob copy), replacing the recorder Fail the scenarios above use.
New-World -Services $three; Reset-Result
$script:MsiInstallCompleted = $true; $script:SerialStartDone = $false
. ([scriptblock]::Create(($R['failpath'] -join "`n")))
$thrown = ''; try { Fail 'test: a step after msiexec failed' } catch { $thrown = "$_" }
Check 'failpath: a Fail after msiexec starts the services one at a time BEFORE the RESULT is written, and the RESULT carries the start' `
      ($thrown -eq 'EMIT:1' -and $script:W.calls -contains 'start:QdbDaemon' -and $script:W.calls -contains 'emit' -and
       $script:W.calls.IndexOf('start:QdbDaemon') -lt $script:W.calls.IndexOf('emit') -and "$($script:Result.detail.svc_serial_start)" -match 'QdbDaemon=started') "thrown=$thrown calls=$(Calls)"
Check 'failpath: that Fail also starts the QrexecAgent the serialized start held, observed, before the RESULT (QdbDaemon first, then QrexecAgent, then the RESULT; site fail-path)' `
      ($thrown -eq 'EMIT:1' -and (CountCalls 'start:QrexecAgent') -eq 1 -and $script:W.calls.IndexOf('start:QdbDaemon') -lt $script:W.calls.IndexOf('start:QrexecAgent') -and $script:W.calls.IndexOf('running:QrexecAgent') -lt $script:W.calls.IndexOf('emit') -and
       "$($script:Result.detail.svc_serial_start)" -match 'QrexecAgent=held-for-device-work' -and "$($script:Result.detail.svc_qrexec_start)" -match '^fail-path: started running=0\.3s$') "thrown=$thrown start=$($script:Result.detail.svc_qrexec_start) calls=$(Calls)"
New-World -Services @(@{ name = 'QdbDaemon'; status = 'Running'; startedAt = [datetime]'2026-10-04 10:28:00' }, @{ name = 'QrexecAgent'; runningAfterSec = 0.3 }, @{ name = 'QubesGuiWatchdog' }); Reset-Result
$script:MsiInstallCompleted = $true; $script:SerialStartDone = $true
$script:QrexecAgentHeld = $true; $script:QrexecAgentHeldAt = $script:W.now; $script:QrexecAgentReleased = $false
$thrown = ''; try { Fail 'test: the device work failed' } catch { $thrown = "$_" }
Check 'failpath: a Fail during the device work (serialized start done, QrexecAgent held) starts the held QrexecAgent before the RESULT, and nothing else' `
      ($thrown -eq 'EMIT:1' -and (Calls) -eq 'start:QrexecAgent running:QrexecAgent emit' -and "$($script:Result.detail.svc_qrexec_start)" -match '^fail-path: started running=0\.3s$') "thrown=$thrown calls=$(Calls)"
New-World -Services $three; Reset-Result
$script:MsiInstallCompleted = $false; $script:SerialStartDone = $false
$thrown = ''; try { Fail 'test: a step BEFORE msiexec failed' } catch { $thrown = "$_" }
Check 'failpath: a Fail before msiexec starts nothing (the old product is still in place)' ($thrown -eq 'EMIT:1' -and $script:W.calls -notcontains 'start:QdbDaemon' -and $script:W.calls -notcontains 'start:QrexecAgent') "calls=$(Calls)"

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host "=== svc-serial-start: $($script:run) checks, $($script:nfail) failed$(if ($Defect) { " (defect knob '$Defect': a FAIL is the required outcome)" }) ==="
exit $(if ($script:nfail -eq 0) { 0 } else { 1 })
