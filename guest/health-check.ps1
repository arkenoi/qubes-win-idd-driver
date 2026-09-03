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
    # Allowlist entries as 'HWID_SUBSTRING:CODE', case-insensitive. The one default names the
    # single state that is BY DESIGN on a Qubes guest with our package: the emulated VGA
    # adapter we deliberately disable (code 22 = disabled).
    #
    # XENBUS\...&DEV_CONS:28 WAS allowlisted here, on the reason "QWT ships no xencons driver
    # at all" - true when written (2026-08-07: the Qubes PV-drivers repo vendored only
    # xenbus/xeniface/xennet/xenvbd/xenvif). It stopped being true the moment we started
    # shipping xencons in the package, and an allowlist outliving its premise is the exact
    # failure mode this file already carries one scar from: DEV_VBD:28 was allowlisted the
    # same way and certified as healthy a guest running entirely on emulated IDE. Keeping
    # CONS allowlisted now would hide the binding of the very driver we added to diagnose the
    # wedge - a check that cannot fail, guarding the instrument we most need to trust.
    # pv_console_bound below asserts it instead.
    #
    # Instance-ID substrings measured on the intended-state guest (win-idd-test
    # 2026-08-06): the emulated VGA is PCI\VEN_1234&DEV_1111, the Xen vendor string
    # is XP0001. XENVIF\...DEV_NET err=28 was ALSO observed there with a working Up
    # adapter - deliberately NOT allowlisted until explained; the sweep must surface it.
    [string[]]$AllowPnpErrors = @('PCI\VEN_1234&DEV_1111:22'),
    [string]$ManifestPath = 'C:\qwt-improved-setup\MANIFEST.json',
    [switch]$NoIddExpected,   # for BDA-configuration guests (control runs only)
    # For deliberate control runs against stock QWT or any pre-4.3.16 package, which ship no
    # xencons: report pv_console_bound as evidence without failing on it. Never pass this for
    # a package that is supposed to carry the console - it would turn the check into decoration.
    [switch]$ConsoleOptional,
    # Accept a guest that updates itself (the documented StandaloneVM-with-direct-internet
    # carve-out). Pass it ONLY when self-updating is genuinely intended for that guest - never
    # to quiet the check on a guest under acceptance, where a self-updating guest is exactly
    # the confound the check exists to catch.
    [switch]$SelfUpdatingAllowed
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
    # Manifest schema: current CI writes `binaries.<name>.sha256` (an object per binary); older
    # packages wrote a flat `reference_binaries.<name>` hash string. Read the current schema first,
    # fall back to the old one, so this instrument is not a false negative on the shipped package.
    if ($mf.binaries -and $mf.binaries.'gui-agent.exe' -and $mf.binaries.'gui-agent.exe'.sha256) {
        $wantHash = $mf.binaries.'gui-agent.exe'.sha256
    } elseif ($mf.reference_binaries) {
        $wantHash = $mf.reference_binaries.'gui-agent.exe'
    }
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
# Read the CONFIGURED log directory rather than assuming one. LogDir moved to the private
# volume (Q:\Qubes Logs) on 2026-08-07 when MoveUsers landed, and this check - which had a
# hardcoded C:\Program Files\Qubes Tools\log - then reported logs_this_boot=0 / newest=NONE
# on a perfectly healthy guest. A check that silently looks in the wrong place is worse than
# no check: it fails clean guests and would pass a guest whose logging is genuinely broken if
# the stale path happened to hold an old file.
$logDirs = @()
try {
    $cfgLogDir = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name 'LogDir' -ErrorAction Stop).LogDir
    if ($cfgLogDir) { $logDirs += $cfgLogDir }
} catch { }
# Fallbacks cover a guest installed before the move, and the MSI's other candidate.
$logDirs += 'Q:\Qubes Logs'
$logDirs += 'C:\Program Files\Qubes Tools\log'
$logDirs = @($logDirs | Where-Object { $_ } | Select-Object -Unique)
$logsThisBoot = @($logDirs | ForEach-Object {
                      Get-ChildItem $_ -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue } |
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
        @{ log_dirs_searched = $logDirs
           logs_this_boot = $logsThisBoot.Count
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
        # ToLowerInvariant, not ToLower: these are DEVICE identifiers, not human text, and
        # .ToLower() is culture-sensitive. Measured on tr-TR - 'XENIFACE'.ToLower() returns
        # x-e-n-U+0131-f-a-c-e (the dotless i), so the comparison against 'xeniface' is False and
        # the Xen PV driver check reports the interface missing on a Turkish guest. The console
        # renders the two strings identically; only the code points give it away.
        if ($d.PNPDeviceID -like "$k\*" -or $d.Service -eq $k.ToLowerInvariant()) {
            $ok = ($d.ConfigManagerErrorCode -eq 0)
            if ($ok) { $pvWanted[$k] = $true }
            $pvDetail += [ordered]@{ id = $d.PNPDeviceID; err = $d.ConfigManagerErrorCode; name = $d.Name }
        }
    }
}
$pvMissing = @($pvWanted.Keys | Where-Object { -not $pvWanted[$_] })
# The decisive one: which driver is behind the NIC actually carrying traffic?
# LOOPBACK ADAPTERS ARE NOT PHYSICAL NICs, whatever WMI says. Win32_NetworkAdapter reports
# PhysicalAdapter=$true for "Microsoft KM-TEST Loopback Adapter", so a guest carrying one looks
# network-attached to the not-applicable branch below and is then graded "PV NIC missing".
# Measured 2026-08-29: win11-fresh and win11-24h2 both carry two KM-TEST Loopback Adapters and
# reported three network FAILs, while win10-clean and win10-u10 - identical netvm='' condition,
# no loopback adapter - correctly reported "na" and ok:true. The asymmetry was entirely this
# predicate; nothing about those builds differed. A loopback adapter carries no traffic to a vif
# and can never be the PV NIC, so it must not count toward "is a network attached".
$nics = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
          Where-Object { $_.PhysicalAdapter -eq $true -and
                         $_.PNPDeviceID -notmatch '(?i)ROOT\\NET|\bMS_LOOPBACK\b' -and
                         $_.Name -notmatch '(?i)loopback' })
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
# Assert the MECHANISM, not just the symptom. Q:\Users existing could equally mean 'a copy
# was made and profiles still live on root'. The redirection is what matters, so require
# C:\Users to be a reparse point whose target is on Q:. ProfilesDirectory deliberately stays
# C:\Users - relocate-dir.exe leaves a link, and rewriting that registry value post-install
# is Microsoft's unsupported path and a known source of servicing failures.
$cu = Get-Item 'C:\Users' -Force -ErrorAction SilentlyContinue
$isLink = $false; $linkTarget = 'NONE'
if ($cu) {
    $isLink = [bool]($cu.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($cu.Target) { $linkTarget = ($cu.Target -join ';') }
}
$targetOnQ = ($linkTarget -match '^[Qq]:')
# Free space matters here: MoveUsers sends ALL user data to the private image, whose Qubes
# default is 2 GiB - a bare profile already uses ~546 MB. Warn loudly below 2 GiB free.
$qFreeGB = if ($qVol.Count -ge 1) { [math]::Round($qVol[0].SizeRemaining / 1GB, 1) } else { 0 }
Check 'user_data_on_private' ($qVol.Count -ge 1 -and $qUsers -and $isLink -and $targetOnQ) `
    @{ private_volume_present = ($qVol.Count -ge 1)
       q_users_exists         = $qUsers
       c_users_is_reparse     = $isLink
       c_users_target         = $linkTarget
       private_free_gb        = $qFreeGB
       low_space_warning      = ($qFreeGB -lt 2)
       profiles_directory     = $(if ($profDir) { $profDir } else { '<unset>' })
       note = 'MoveUsers must REDIRECT C:\Users to the private image; a mere copy would leave profiles on root' }

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

# --- 6b2. PV CONSOLE: the wedge instrument must actually be bound --------------------
# Replaces the DEV_CONS:28 allowlist deleted from $AllowPnpErrors above. We now ship xencons,
# so "CONS sits at code 28" changed from an expected state into a defect.
#
# This check exists because of HOW the driver is used. xencons is not a feature - nothing in
# QWT binds to it - it is the out-of-band channel for reading a wedged guest from dom0 with
# `xl console`. The wedge takes qrexec, window capture and the event log at the same instant
# (measured twice, 2026-08-29), which means it must be installed and bound BEFORE the failure:
# a wedged guest cannot be handed a driver afterwards. An unnoticed regression here would only
# ever be discovered at the exact moment the instrument was needed and found dead.
#
# EXPECTED TO FAIL on stock QWT and on any pre-4.3.16 package (neither ships xencons); that is
# correct - it distinguishes "console present" from "console absent", which is the whole point.
# $ConsoleOptional downgrades it to evidence-only for deliberate control runs against stock.
$cons = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
          Where-Object { $_.PNPDeviceID -like 'XENBUS\VEN_XP0001&DEV_CONS*' })
$consBound = ($cons.Count -ge 1 -and @($cons | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count -eq 0)
Check 'pv_console_bound' ($consBound -or $ConsoleOptional) `
    @{ cons_devices = @($cons | ForEach-Object { $_.PNPDeviceID + ' err=' + $_.ConfigManagerErrorCode + ' svc=' + $_.Service })
       bound = $consBound
       optional = [bool]$ConsoleOptional
       note = 'xencons gives dom0 `xl console` into a guest whose qrexec/event log are already dead' }

# --- 6b3. UPDATES ARE DOM0-OWNED: the guest must not be updating itself -------------
# Added 2026-08-30 after the owner saw a Windows Update toast on their screen from a guest that
# was MID-ACCEPTANCE. Investigation: win10-clean (StandaloneVM, netvm=fw-net) had NoAutoUpdate
# absent, wuauserv Running, 3 servicing processes, and RebootRequired=True - it had already
# installed updates on its own.
#
# The cause is deliberate code, not an omission: qubes-windows-update.ps1 classifies a
# StandaloneVM with direct internet as self-updating and REMOVES NoAutoUpdate. Attaching a
# netvm to StandaloneVMs for PV-network testing (which we began doing on 2026-08-29) therefore
# silently flips those guests into self-updating mode.
#
# Why this is a TEST-INTEGRITY defect and not a cosmetic one:
#   - a guest that services updates mid-cell is no longer the artifact under test, so the cell
#     grades something that no longer exists ("single package for all tests" is defeated from
#     inside the guest);
#   - Windows Update installs DRIVERS and sets a pending-reboot flag, which is an independent
#     source of the very reboot prompts an acceptance cell is grading as "gone";
#   - it adds heavy uncontrolled PnP/IO churn, which is exactly the load class the wedge feeds
#     on - a plausible reason the wedge appears more often lately with no code change to explain
#     it.
# Nothing in the acceptance path could have caught this: no check looked at WU state at all.
$nauPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$nau = (Get-ItemProperty -Path $nauPath -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
$wuSvc = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status
$wuPendingReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$servicing = @(Get-Process TiWorker, TrustedInstaller -ErrorAction SilentlyContinue).Count
$updatesOwned = ($nau -eq 1 -and -not $wuPendingReboot)
Check 'updates_dom0_owned' ($updatesOwned -or $SelfUpdatingAllowed) `
    @{ NoAutoUpdate = $nau
       wuauserv = "$wuSvc"
       wu_pending_reboot = $wuPendingReboot
       servicing_processes = $servicing
       allowed_by_switch = [bool]$SelfUpdatingAllowed
       note = 'dom0 owns every install; a guest updating itself mutates the artifact under test and can raise its own reboot prompts' }

# --- 6b1. THIS BOOT'S KERNEL/SERVICE EVENTS ------------------------------------------------
# Added 2026-08-29. Until now this script had ZERO Get-WinEvent calls, so it asserted the END state
# (device bound, desktop on the IDD) and was blind to a driver that FAILED TO LOAD and was retried,
# or to a service that died. The event that exposed the gap:
#     id 219  Kernel-PnP  "\Driver\WUDFRd failed to load. Device: ROOT\DISPLAY\0000
#                          Status: 0xC0000365"   (STATUS_DRIVER_FAILED_PRIOR_UNLOAD)
# on a boot where no windows were mapped. It is LEVEL 3 (Warning), and the project's two event
# scanners both filter Level 1-2, so nothing in the acceptance path could ever have seen it.
#
# Scope: THIS BOOT only (LastBootUpTime), and only signatures that bear on whether OUR stack came up.
# Reported as evidence always; it FAILS only on the signatures that mean a component of ours did not
# load, so unrelated Windows noise cannot fail an otherwise good guest.
$bootEvents = @(); $bootBad = @()
try {
    $since = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    foreach ($e in @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; Level=1,2,3} -MaxEvents 200 -ErrorAction SilentlyContinue)) {
        $msg = ($e.Message -replace "`r`n", ' ')
        # our stack failing to load / start
        $isOurs = ($e.Id -eq 219  -and $msg -match 'ROOT\\DISPLAY|Xen|WUDFRd') -or
                  ($e.Id -eq 7000 -and $msg -match 'Qubes|Xen|Qdb|Qrexec') -or
                  ($e.Id -eq 7043 -and $msg -match 'Qubes') -or
                  ($e.Id -eq 7031 -and $msg -match 'Qubes|Xen')
        if ($isOurs) {
            $rec = @{ id = $e.Id; level = $e.Level; provider = $e.ProviderName
                      time = $e.TimeCreated.ToUniversalTime().ToString('o')
                      msg = $msg.Substring(0, [Math]::Min(160, $msg.Length)) }
            $bootEvents += $rec
            # WHAT FAILS AND WHAT ONLY WARNS - decided by MEASUREMENT, 2026-08-29.
            #
            # First run of this check on the release ISO fired 219 (WudfRd failed to load for
            # ROOT\DISPLAY\0000) on a boot where idd_device_bound and desktop_on_idd BOTH PASSED -
            # i.e. the first load attempt failed, PnP retried, and the display came up correctly.
            # So 219 on its own is a RECOVERED TRANSIENT and must not fail a guest whose display
            # demonstrably works; failing on it would have failed all six acceptance cells for
            # nothing. This also settles the open question from the investigation (is 219 rare and
            # fatal, or common and benign): here it is benign, because the end state is good.
            #
            # But the signal is not thrown away - that would put us back to being blind. 219 FAILS
            # when the device did NOT recover, which is exactly the case that matters; the end-state
            # checks above already computed that. Everything else is recorded as a warning.
            #
            # 7043 is a shutdown-phase complaint about the PREVIOUS boot, not this one.
            $recovered = $false
            if ($e.Id -eq 219) {
                $recovered = ($r.checks['idd_device_bound'] -and $r.checks['idd_device_bound'].pass)
            }
            if ($e.Id -ne 7043 -and -not $recovered) { $bootBad += $rec }
        }
    }
    Check 'boot_events_clean' ($bootBad.Count -eq 0) `
        @{ failing = $bootBad; warnings_recovered = @($bootEvents | Where-Object { $bootBad -notcontains $_ })
           since = $since }
} catch {
    Check 'boot_events_clean' $false @{ error = "could not read the System log: $($_.Exception.Message)" }
}

# --- 6b2. the network must actually CARRY TRAFFIC, not merely be bound -------------
# "PV NIC present" is not "networking works". Assert an IP and a working gateway.
$ipOk = $false; $gw = $null; $addr = $null
try {
    # Pick the adapter that actually CARRIES traffic, not merely the first IP-enabled one.
    # `Select-Object -First 1` chose whatever WMI happened to enumerate first, which on a guest
    # with a Microsoft KM-TEST Loopback Adapter is the LOOPBACK - so this reported the loopback's
    # APIPA address and "no gateway" while the PV NIC sat there with a real Qubes IP and the
    # default route. Measured 2026-08-29 on win11-app: this check FAILED with ip 169.254.130.108
    # in the same run where pvnic_applier PASSED with pv_adapter_ips ["10.137.0.68"] and
    # default_route_on_pv true. Two checks, one guest, contradicting each other - and this one was
    # wrong. Same root as the physical-NIC predicate above: loopback adapters must not be treated
    # as the network.
    $cands = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
               Where-Object { $_.IPEnabled -eq $true })
    $cfg = $null
    foreach ($c in $cands) {
        $a = ($c.IPAddress | Where-Object { $_ -match '^\d+\.' -and $_ -notmatch '^169\.254\.' } | Select-Object -First 1)
        $g = ($c.DefaultIPGateway | Select-Object -First 1)
        if ($a -and $g) { $cfg = $c; break }
    }
    # Nothing routable: fall back to the first IP-enabled adapter so the evidence still shows what
    # WAS there, rather than reporting an empty record.
    if (-not $cfg) { $cfg = ($cands | Select-Object -First 1) }
    if ($cfg) {
        $addr = ($cfg.IPAddress | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
        $gw   = ($cfg.DefaultIPGateway | Select-Object -First 1)
        # DO NOT assert traffic by PINGING THE GATEWAY. A Qubes netvm does not answer ICMP - it is a
        # routing endpoint, not a host - so this reported "no traffic" on guests that were demonstrably
        # moving megabytes. Measured 2026-08-29 on win11-24h2: ping gateway FALSE, while TCP to the
        # Qubes DNS server connected, `Resolve-DnsName example.com` returned a real address, and the PV
        # adapter's own counters read rx=5,541,697 tx=620,926. The check was wrong, not the network.
        # Assert traffic the way traffic actually happens: a real DNS resolution or a TCP connect
        # through the adapter, with the byte counters recorded as corroboration. Ping is kept only as
        # a last resort and as evidence, never as the sole criterion.
        $dnsSrv = ($cfg.DNSServerSearchOrder | Select-Object -First 1)
        $pingOk = $false; $tcpOk = $false; $dnsOk = $false
        if ($addr -and $gw) { $pingOk = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue }
        if ($dnsSrv) {
            $c = New-Object Net.Sockets.TcpClient
            try { $ia = $c.BeginConnect($dnsSrv, 53, $null, $null)
                  $tcpOk = $ia.AsyncWaitHandle.WaitOne(4000, $false) -and $c.Connected } catch { }
            try { $c.Close() } catch { }
            $res = Resolve-DnsName -Name 'example.com' -Server $dnsSrv -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue
            $dnsOk = [bool]$res
        }
        $rx = 0; $tx = 0
        try {
            $s = Get-NetAdapterStatistics -ErrorAction SilentlyContinue |
                 Sort-Object ReceivedBytes -Descending | Select-Object -First 1
            if ($s) { $rx = $s.ReceivedBytes; $tx = $s.SentBytes }
        } catch { }
        $script:netEvidence = @{ ping_gateway = $pingOk; tcp_dns_53 = $tcpOk; dns_resolves = $dnsOk
                                 rx_bytes = $rx; tx_bytes = $tx; dns_server = $dnsSrv }
        $ipOk = ($dnsOk -or $tcpOk -or $pingOk)
    }
} catch { }
if ($nics.Count -eq 0) {
    Check 'network_carries_traffic' $false @{ na = 'no network attached' }
    $r.checks['network_carries_traffic'].na = $true
} else {
    $netEv = @{ ip = $addr; gateway = $gw; carries_traffic = $ipOk }
    if ($script:netEvidence) { foreach ($k in $script:netEvidence.Keys) { $netEv[$k] = $script:netEvidence[$k] } }
    Check 'network_carries_traffic' $ipOk $netEv
}

# --- 6b3. netvm-free PV NIC applier (M1 latch path) --------------------------------
# On a latch-seeded template the PV adapter is INSTALLED FRESH EVERY BOOT and the QubesPvNic
# task must land the qubesdb IP each time. Latched-without-applier is the forbidden SILENT
# state (survives with APIPA only, measured 2026-08-18) - pv_drivers_bound PASSES it, so this
# check exists to fail it. NA on guests without the M1 deployment (task not registered).
schtasks /query /tn QubesPvNic 2>$null | Out-Null
$pvnicTask = ($LASTEXITCODE -eq 0)
$pvnicMarker = Test-Path 'C:\ProgramData\QubesPvNic-FAILED.txt'
if (-not $pvnicTask) {
    Check 'pvnic_applier' $false @{ na = 'QubesPvNic task not registered - M1 latch deployment absent' }
    $r.checks['pvnic_applier'].na = $true
} elseif ($nics.Count -eq 0) {
    # Offline guest: the applier must have stayed quiet (no marker); nothing else assertable.
    Check 'pvnic_applier' (-not $pvnicMarker) @{ offline = $true; failure_marker_present = $pvnicMarker }
} else {
    # The assertion is outcome-shaped: a real (non-APIPA) IPv4 on the XENVIF adapter plus a
    # default route on its ifIndex. (qubesdb reads work fine in-guest now - see qubesdb-read.ps1,
    # the "qubesdb-cmd unusable" note was about the CLI only - so this could also assert the PV IP
    # equals /qubes-ip; kept outcome-shaped because it is netvm-backend-agnostic and needs no
    # dom0-side comparison.)
    $pvAd = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.PnPDeviceID -like 'XENVIF\*' } | Select-Object -First 1
    $pvIps = @(); $pvRoute = $null
    if ($pvAd) {
        $pvIps = @(Get-NetIPAddress -InterfaceIndex $pvAd.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | ForEach-Object { $_.IPAddress })
        $pvRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Where-Object { $_.ifIndex -eq $pvAd.ifIndex } | Select-Object -First 1
    }
    $apipa = @($pvIps | Where-Object { $_ -like '169.254.*' })
    $realIp = @($pvIps | Where-Object { $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
    Check 'pvnic_applier' ($realIp.Count -ge 1 -and $null -ne $pvRoute -and -not $pvnicMarker -and $apipa.Count -eq 0) `
        @{ pv_adapter_ips = $pvIps; apipa_present = $apipa; default_route_on_pv = ($null -ne $pvRoute)
           failure_marker_present = $pvnicMarker }
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
