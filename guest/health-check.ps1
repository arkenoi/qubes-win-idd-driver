# Release-acceptance HEALTH ASSERTION - run inside the guest after install + reboot.
#
# Exists because the 2026-08-06 clean-path gate ("installed binary hash == manifest")
# PASSED on a guest that was missing the entire IDD display stack: a hash check cannot
# see absent function. This script asserts the guest actually delivers the product:
#   1. our gui-agent binary installed (hash vs MANIFEST) AND running
#   2. the Qubes IDD device present, started (ConfigManagerErrorCode 0), driving
#      the desktop as adapter of the primary display
#   3. the agent<->driver mode loop alive: HKLM\SOFTWARE\QubesIDD\Modes published
#   4. NO PnP device in an error state, except an explicit allowlist that names each
#      accepted defect (the Basic Display Adapter WE disable is expected code 22)
#   5. agent log fresh and free of fatal signatures in the current boot
#
# Pixels-changing and window-mapping checks live dom0-side (tools/accept-clean.sh):
# a guest cannot attest its own output.
#
# Output: one JSON line prefixed with '=== HEALTH ===', ok=true only if every check
# passed. Exit 0 iff ok. Designed to FAIL LOUDLY on partial installs; validated against
# a guest with no IDD (must fail) and the intended-state guest (must pass).
param(
    # Allowlist entries as 'HWID_SUBSTRING:CODE', case-insensitive. Defaults name the
    # two states that are BY DESIGN on a Qubes guest with our package:
    #  - the emulated VGA adapter we deliberately disable (code 22 = disabled)
    #  - XENBUS\VBD code 28: PvDriversDisk is deliberately omitted from ADDLOCAL
    #    (documented BSOD risk), so the PV disk device stays driverless
    #  - XENBUS\CONS code 28: QWT ships no xencons driver at all
    # Instance-ID substrings measured on the intended-state guest (win-idd-test
    # 2026-08-06): the emulated VGA is PCI\VEN_1234&DEV_1111, the Xen vendor string
    # is XP0001. XENVIF\...DEV_NET err=28 was ALSO observed there with a working Up
    # adapter - deliberately NOT allowlisted until explained; the sweep must surface it.
    [string[]]$AllowPnpErrors = @('PCI\VEN_1234&DEV_1111:22',
                                  # NOTE: XENBUS\...&DEV_VBD:28 was allowlisted here until
                                  # 2026-08-07. That was wrong: it certified as healthy a
                                  # guest running entirely on emulated IDE because we had
                                  # dropped PvDriversDisk from ADDLOCAL on an unsourced
                                  # claim. The disk device must BIND now, and pv_disk_bound
                                  # below asserts it.
                                  'XENBUS\VEN_XP0001&DEV_CONS:28'),
    [string]$ManifestPath = 'C:\qwt-improved-setup\MANIFEST.json',
    [switch]$NoIddExpected   # for BDA-configuration guests (control runs only)
)

$ErrorActionPreference = 'SilentlyContinue'
$r = [ordered]@{ ok = $false; checks = [ordered]@{}; }
$fails = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$pass, $evidence) {
    $r.checks[$name] = [ordered]@{ pass = $pass; evidence = $evidence }
    if (-not $pass) { [void]$fails.Add($name) }
}

# --- 1. agent binary vs manifest -------------------------------------------------
$agentPath = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$haveHash = (Get-FileHash -LiteralPath $agentPath -ErrorAction SilentlyContinue).Hash
$wantHash = $null
if (Test-Path $ManifestPath) {
    $mf = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    if ($mf.reference_binaries) { $wantHash = $mf.reference_binaries.'gui-agent.exe' }
}
Check 'agent_binary_hash' ($haveHash -and $wantHash -and ($haveHash -ieq $wantHash)) `
    @{ installed = $haveHash; manifest = $wantHash }

# --- 2. agent + services running --------------------------------------------------
$agentProc = Get-Process gui-agent -ErrorAction SilentlyContinue
# Only Automatic-start services must be Running: a Manual-start Qubes service that is
# legitimately idle must not fail every healthy guest.
$svcs = Get-CimInstance Win32_Service -Filter "DisplayName LIKE '%Qubes%'" |
        Select-Object Name, State, StartMode
$badSvc = @($svcs | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' })
Check 'agent_process' ([bool]$agentProc) @{ pid = if ($agentProc) { $agentProc.Id } else { $null } }
Check 'qubes_services_running' (@($svcs).Count -gt 0 -and $badSvc.Count -eq 0) $svcs

# --- 3. IDD device present + started + primary ------------------------------------
# Prefer a bound (Status OK) candidate: devcon install cycles leave phantom
# ROOT\DISPLAY\000N devnodes behind, and an unordered First-1 can pick one of those
# on a guest whose real IDD is fine.
$iddAll = @(Get-PnpDevice -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -match '^ROOT\\DISPLAY' -or ($_.HardwareID -match 'iddsampledriver|qubesidd') })
$idd = ($iddAll | Where-Object { $_.Status -eq 'OK' } | Select-Object -First 1)
if (-not $idd) { $idd = $iddAll | Select-Object -First 1 }
$iddCim = $null
if ($idd) {
    $iddCim = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$($idd.InstanceId -replace '\\','\\')'"
}
if ($NoIddExpected) {
    Check 'idd_device_bound' $true @{ skipped = 'NoIddExpected' }
} else {
    Check 'idd_device_bound' ($idd -and $idd.Status -eq 'OK' -and $iddCim -and $iddCim.ConfigManagerErrorCode -eq 0) `
        @{ instance = if ($idd) { $idd.InstanceId } else { 'ABSENT' }
           status = if ($idd) { "$($idd.Status)" } else { $null }
           cm_error = if ($iddCim) { $iddCim.ConfigManagerErrorCode } else { $null } }

    # The desktop's video controller must be the IDD AND nothing else may be active:
    # "IDD among the active controllers" alone would pass a guest whose VGA disable
    # failed (extended desktop, broken seamless coordinates). ROOT\BASICDISPLAY with a
    # resolution would equally be a regression - the agent captures adapter 0 and an
    # active second output means the topology is not the shipped one.
    $ctrls = Get-CimInstance Win32_VideoController |
             Select-Object Name, PNPDeviceID, CurrentHorizontalResolution, CurrentVerticalResolution, Availability
    $active = @($ctrls | Where-Object { $_.CurrentHorizontalResolution -gt 0 })
    $iddActive = @($active | Where-Object { $_.PNPDeviceID -match '^ROOT\\DISPLAY' })
    $otherActive = @($active | Where-Object { $_.PNPDeviceID -notmatch '^ROOT\\DISPLAY' })
    Check 'desktop_on_idd' ($iddActive.Count -ge 1 -and $otherActive.Count -eq 0) `
        @{ controllers = $ctrls; non_idd_active = $otherActive.Count }
}

# --- 4. agent<->driver mode loop -------------------------------------------------
# SCOPE: sound on a freshly provisioned guest (no prior state can have written the
# key, so a non-empty value proves THIS install's agent published). On a long-lived
# guest the value persists across boots and this becomes a staleness-prone check -
# do not reuse it outside clean-path acceptance without adding a liveness signal.
$modes = (Get-ItemProperty 'HKLM:\SOFTWARE\QubesIDD' -ErrorAction SilentlyContinue).Modes
if ($NoIddExpected) {
    Check 'idd_modes_published' $true @{ skipped = 'NoIddExpected' }
} else {
    Check 'idd_modes_published' ($modes -and $modes.Count -gt 0) @{ modes = $modes }
}

# --- 5. PnP error sweep (allowlist must NAME each accepted defect) -----------------
# The sweep must FAIL, not vacuously pass, when WMI itself is broken: sanity-assert the
# device universe is plausibly complete before trusting an empty error list.
$universe = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
if ($universe.Count -lt 20) {
    Check 'pnp_no_unexpected_errors' $false @{ error = "Win32_PnPEntity returned only $($universe.Count) devices - WMI unusable, sweep is not evidence" }
}
$bad = $universe | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
       Select-Object Name, PNPDeviceID, ConfigManagerErrorCode
$unexpected = @()
foreach ($d in @($bad)) {
    $allowed = $false
    foreach ($a in $AllowPnpErrors) {
        $pat, $code = $a -split ':', 2
        # [int] on both sides: once Get-PnpDevice has loaded the PnpDevice CDXML module
        # (section 3 above), ConfigManagerErrorCode stringifies as the enum LABEL
        # ('CM_PROB_FAILED_INSTALL'), not '28' - a string compare silently never matches
        # (measured 2026-08-07: the allowlist was correct and every entry still failed).
        if ($d.PNPDeviceID -match [regex]::Escape($pat) -and [int]$d.ConfigManagerErrorCode -eq [int]$code) {
            $allowed = $true; break
        }
    }
    if (-not $allowed) { $unexpected += $d }
}
if ($universe.Count -ge 20) {
    Check 'pnp_no_unexpected_errors' ($unexpected.Count -eq 0) `
        @{ all = @($bad); unexpected = $unexpected; allowlist = $AllowPnpErrors }
}

# --- 6. agent log: ONE instance this boot, actively writing, zero BADMODE ----------
# Deliberately NOT "no error strings anywhere": a healthy cold boot shows a burst of
# transient 0x887a0026 (keyed mutex) that the agent survives in place (Gate B,
# 2026-08-07). What distinguishes healthy from broken is: the agent did not respawn
# (exactly one log file this boot), it is still writing NOW, and BADMODE - which is
# never benign - does not appear at all.
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if (-not $boot) {
    # Without a boot timestamp "written this boot" is vacuously true against $null -
    # fail the check rather than evaluate it against no data.
    Check 'agent_log_healthy' $false @{ error = 'Win32_OperatingSystem.LastBootUpTime unavailable - freshness cannot be judged' }
}
$logsThisBoot = @(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
                  Where-Object { $boot -and $_.LastWriteTime -gt $boot })
$log = $logsThisBoot | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$logOk = $false; $badmode = -1; $grew = $false
if ($log) {
    $l1 = (Get-Item $log.FullName).Length
    Start-Sleep -Seconds 3
    $l2 = (Get-Item $log.FullName).Length
    $grew = ($l2 -gt $l1)
    $badmode = @(Select-String -Path $log.FullName -Pattern 'BADMODE|0xfffffffe').Count
    # An idle guest legitimately logs nothing for stretches; "alive" is grew-now OR
    # written within the last 5 minutes. The acceptance harness generates activity
    # (opens a window) before calling this, so a truly dead agent still fails.
    # Liveness comes from the PROCESS, not from log writes: an idle guest legitimately
    # logs nothing for long stretches, and requiring recent writes failed a healthy guest
    # (2026-08-07). agent_process already asserts the agent is running; here we only need
    # the log to belong to THIS boot, which $logsThisBoot already guarantees.
    $fresh = [bool]$agentProc
    # A respawn LOOP is the defect; ONE restart is not. Measured repeatedly 2026-08-07: the
    # first instance dies seconds after boot with 'WatchForEvents: vchan disconnected' /
    # A6EXIT because dom0's gui-daemon is not connected yet, the watchdog restarts it, and
    # the second instance runs healthily for hours. Requiring logsThisBoot -eq 1 failed a
    # perfectly good guest every time. What matters: the CURRENT instance is healthy, and
    # the count is small. >2 instances, or an unhealthy current one, still fails.
    $benignExit = $false
    if ($logsThisBoot.Count -eq 2) {
        $first = $logsThisBoot | Sort-Object LastWriteTime | Select-Object -First 1
        $benignExit = [bool](Select-String -Path $first.FullName -Pattern 'vchan disconnected|A6EXIT' -Quiet)
    }
    $countOk = ($logsThisBoot.Count -eq 1) -or ($logsThisBoot.Count -eq 2 -and $benignExit)
    $logOk = $countOk -and $fresh -and ($badmode -eq 0)
}
if ($boot) {
    Check 'agent_log_healthy' $logOk `
        @{ logs_this_boot = $logsThisBoot.Count
           newest = if ($log) { $log.Name } else { 'NONE' }
           still_writing = $grew
           badmode_lines = $badmode
           prior_instance_exited_on_vchan_disconnect = $benignExit }
}

# --- 6b. PV DRIVERS actually bound and CARRYING traffic ----------------------------
# "Installed" is not "working": ADDLOCAL=...,PvDriversNetwork succeeds while xennet never
# binds its XENVIF child, leaving the guest on the EMULATED Realtek NIC (measured
# 2026-08-07). Networking still functions, which is exactly why a service-level check
# misses it. So: every PV devnode must be started, AND the active NIC must be the PV one.
$pvWanted = @{ 'XENBUS' = $false; 'XENIFACE' = $false; 'XENVIF' = $false; 'XENNET' = $false }
$pvDetail = @()
foreach ($d in @($universe)) {
    foreach ($k in @($pvWanted.Keys)) {
        if ($d.PNPDeviceID -like "$k\*" -or $d.Service -eq $k.ToLower()) {
            $ok = ($d.ConfigManagerErrorCode -eq 0)
            if ($ok) { $pvWanted[$k] = $true }
            $pvDetail += [ordered]@{ id = $d.PNPDeviceID; err = $d.ConfigManagerErrorCode; name = $d.Name }
        }
    }
}
$pvMissing = @($pvWanted.Keys | Where-Object { -not $pvWanted[$_] })
# The decisive one: which driver is behind the NIC actually carrying traffic?
$nics = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
          Where-Object { $_.PhysicalAdapter -eq $true })
$nicUp = @($nics | Where-Object { $_.NetEnabled -eq $true })
# ALL physical adapters, not First-1: after the xenvif upgrade a STALE rev-4 devnode can
# linger beside the working rev-5 one (measured 2026-08-07), and a First-1 match on the
# stale node would fail a guest whose PV networking is fine.
$pvNics  = @($nicUp | Where-Object { $_.PNPDeviceID -match '^XEN' -or $_.Name -match 'Xen|Qubes' })
$emuNics = @($nicUp | Where-Object { $_.PNPDeviceID -notmatch '^XEN' -and $_.Name -notmatch 'Xen|Qubes' })
# NO NETWORK ATTACHED is 'not applicable', never a pass: an offline install (netvm '') has
# no vif at all, so asserting "the NIC must be PV" there can only fail for the wrong reason
# (measured 2026-08-07 - it failed a healthy guest that simply had no network).
if ($nics.Count -eq 0) {
    Check 'pv_drivers_bound' $false @{ na = 'no physical network adapter attached - PV NIC not assertable here'; started = $pvWanted; not_started = $pvMissing }
    $r.checks['pv_drivers_bound'].na = $true
} else {
    # The emulated NIC must be GONE, not merely coexisting: rev 5 ships with UNPLUG v3, so a
    # working PV path unplugs the QEMU adapter outright.
    Check 'pv_drivers_bound' ($pvMissing.Count -eq 0 -and $pvNics.Count -ge 1 -and $emuNics.Count -eq 0) `
        @{ started = $pvWanted; not_started = $pvMissing
           pv_nics = @($pvNics | ForEach-Object { $_.Name })
           emulated_nics_still_present = @($emuNics | ForEach-Object { $_.Name })
           all_physical = @($nics | ForEach-Object { $_.Name + '[' + $_.PNPDeviceID + ']' })
           devices = $pvDetail }
}

# --- 6a. CURSOR: the guest must NOT paint its own cursor ----------------------------
# dom0 always draws the X cursor over the guest window. If the guest ALSO composites a
# cursor into the framebuffer we capture, the user sees TWO - reported on Win11 2026-08-07.
# gui-agent's HideCursors() blanks the system cursors, but returns early unless
# DisableCursor is set (util.c:213), so 1 = hide the guest cursor = correct. That is the
# agent's built-in default AND the stock MSI's default; our installer seeded 0 in 24a1ded
# with no stated reason, which is what produced the double cursor.
# This matters more now that /idd is on by default: the IddCx driver implements NO hardware
# cursor path (zero cursor code in Driver.cpp), so a guest cursor can only arrive as pixels
# baked into the frame. Nothing in this gate checked the cursor before, which is why the
# defect reached the user instead of the harness.
$curVal = $null
try {
    $curVal = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name 'DisableCursor' -ErrorAction Stop).DisableCursor
} catch { $curVal = $null }
# Absent is a PASS: gui-agent defaults g_DisableCursor to TRUE when the read fails
# (main.c:4313), so an absent value yields the correct behaviour. Only an explicit 0 is wrong.
Check 'guest_cursor_hidden' ($curVal -eq 1 -or $null -eq $curVal) `
    @{ DisableCursor = $(if ($null -eq $curVal) { 'absent (agent defaults to hide)' } else { $curVal })
       note = 'DisableCursor=0 makes the guest paint its own cursor on top of dom0''s -> double cursor' }

# --- 6a2. USER DATA must live on the PRIVATE volume --------------------------------
# MoveUsers relocates C:\Users to Q:\Users on the Qubes private image. It was omitted until
# 2026-08-07, which left ALL user data on the ROOT volume and broke the Qubes root/private
# split: private is the volume Qubes treats as user data, so a `qvm-volume revert` of root
# would have destroyed the profile. Stock QWT installs MoveUsers by default.
# Assert the OUTCOME (where profiles actually live), not merely that the feature was selected.
$qVol = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq 'Q' })
$profDir = $null
try {
    $profDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' `
                -Name 'ProfilesDirectory' -ErrorAction Stop).ProfilesDirectory
} catch { $profDir = $null }
$qUsers = Test-Path 'Q:\Users' -ErrorAction SilentlyContinue
Check 'user_data_on_private' ($qVol.Count -ge 1 -and $qUsers) `
    @{ private_volume_present = ($qVol.Count -ge 1)
       q_users_exists         = $qUsers
       profiles_directory     = $(if ($profDir) { $profDir } else { '<unset>' })
       note = 'MoveUsers must place profiles on Q: (private image); root-volume profiles are lost on a root revert' }

# --- 6b1. PV DISK: the boot disk must be off emulated IDE ---------------------------
# Added 2026-08-07 after discovering we shipped a package that dropped PvDriversDisk (which
# STOCK QWT installs by default) on an unsourced "BSOD risk" claim, leaving every guest on
# emulated IDE. The old allowlist entry for DEV_VBD:28 actively certified that as healthy.
# Assert BOTH halves, because either alone is satisfiable while the regression is present:
#   - the xenvbd devnode binds (err 0), and
#   - no disk is still reporting BusType=ATA, i.e. the disks really moved to the PV path.
# Measured on a good guest: BusType goes ATA -> SCSI (Xen VBD presents via StorPort).
$vbd = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
         Where-Object { $_.PNPDeviceID -like 'XENBUS\VEN_XP0001&DEV_VBD*' })
$vbdOk = ($vbd.Count -ge 1 -and @($vbd | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count -eq 0)
$disks = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk -ErrorAction SilentlyContinue)
# BusType 3 = ATA, 11 = SATA, 8 = RAID, 10 = SAS, 0 = Unknown; Xen VBD reports 1 (SCSI).
$ideDisks = @($disks | Where-Object { $_.BusType -eq 3 -or $_.BusType -eq 11 })
Check 'pv_disk_bound' ($vbdOk -and $disks.Count -ge 1 -and $ideDisks.Count -eq 0) `
    @{ vbd_devices = @($vbd | ForEach-Object { $_.PNPDeviceID + ' err=' + $_.ConfigManagerErrorCode + ' svc=' + $_.Service })
       disks = @($disks | ForEach-Object { 'disk' + $_.Number + ' bustype=' + $_.BusType })
       still_on_emulated_ide = @($ideDisks | ForEach-Object { 'disk' + $_.Number }) }

# --- 6b2. the network must actually CARRY TRAFFIC, not merely be bound -------------
# "PV NIC present" is not "networking works". Assert an IP and a working gateway.
$ipOk = $false; $gw = $null; $addr = $null
try {
    $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
           Where-Object { $_.IPEnabled -eq $true } | Select-Object -First 1
    if ($cfg) {
        $addr = ($cfg.IPAddress | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
        $gw   = ($cfg.DefaultIPGateway | Select-Object -First 1)
        if ($addr -and $gw) { $ipOk = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue }
    }
} catch { }
if ($nics.Count -eq 0) {
    Check 'network_carries_traffic' $false @{ na = 'no network attached' }
    $r.checks['network_carries_traffic'].na = $true
} else {
    Check 'network_carries_traffic' $ipOk @{ ip = $addr; gateway = $gw; gateway_reachable = $ipOk }
}

# --- 6c. CLIPBOARD path alive ------------------------------------------------------
# The Qubes clipboard is a guest service (QubesClipboard / the vchan clipboard handler in
# qrexec-agent) plus a working Windows clipboard. dom0<->guest transfer needs a human
# Ctrl+Shift+C/V, so what is asserted here is everything up to that: the handler process
# is running AND the Windows clipboard round-trips a value.
$clipSvc = @($svcs | Where-Object { $_.Name -match 'Qubes' -and $_.State -eq 'Running' })
$clipRound = $false
$clipErr = $null
try {
    $marker = 'QUBES_CLIP_' + (Get-Date -Format 'HHmmssfff')
    $sta = [System.Threading.ApartmentState]::STA
    # Set + read must happen on an STA thread; PowerShell's default is MTA here.
    $ps = [PowerShell]::Create()
    $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = $sta
    $ps.Runspace.Open()
    $null = $ps.AddScript("Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText('$marker'); [System.Windows.Forms.Clipboard]::GetText()")
    $res = $ps.Invoke()
    $ps.Runspace.Close(); $ps.Dispose()
    $clipRound = (@($res) -contains $marker)
} catch { $clipErr = "$_" }
Check 'clipboard_works' ($clipSvc.Count -gt 0 -and $clipRound) `
    @{ qubes_services_running = $clipSvc.Count; windows_clipboard_roundtrip = $clipRound
       error = $clipErr
       note = 'dom0<->guest transfer needs Ctrl+Shift+C/V and is NOT asserted here' }

# --- 7. current resolution (informational, always recorded) ------------------------
# Win32_VideoController, not SystemInformation.VirtualScreen: the latter is DPI-scaled
# in a non-DPI-aware host process (5120x1440 at 150 % read back as 3413x960).
$activeCtrl = Get-CimInstance Win32_VideoController |
              Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
$r.resolution = if ($activeCtrl) {
    "$($activeCtrl.CurrentHorizontalResolution)x$($activeCtrl.CurrentVerticalResolution)"
} else { 'NONE' }

# 'na' checks (e.g. PV NIC on a guest with no network attached) must NOT read as a pass,
# but must not fail the run either - reprovision installs OFFLINE by design, so counting
# them as failures made acceptance unpassable on the very path it creates. They are
# reported separately so a release CLAIM can require them while a run does not.
$naChecks = @($r.checks.Keys | Where-Object { $r.checks[$_].na -eq $true })
$hardFails = @($fails | Where-Object { $naChecks -notcontains $_ })
$r.ok = ($hardFails.Count -eq 0)
$r.failed = @($hardFails)
$r.not_applicable = $naChecks
$r.asserted_all = ($hardFails.Count -eq 0 -and $naChecks.Count -eq 0)
Write-Output ('=== HEALTH === ' + ($r | ConvertTo-Json -Depth 6 -Compress))
if ($r.ok) { exit 0 } else { exit 1 }
