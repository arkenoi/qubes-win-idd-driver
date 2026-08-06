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
                                  'XENBUS\VEN_XP0001&DEV_CONS:28',
                                  'XENBUS\VEN_XP0001&DEV_VBD:28'),
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
    $fresh = $grew -or ($log.LastWriteTime -gt (Get-Date).AddMinutes(-5))
    $logOk = ($logsThisBoot.Count -eq 1) -and $fresh -and ($badmode -eq 0)
}
if ($boot) {
    Check 'agent_log_healthy' $logOk `
        @{ logs_this_boot = $logsThisBoot.Count
           newest = if ($log) { $log.Name } else { 'NONE' }
           still_writing = $grew
           badmode_lines = $badmode }
}

# --- 7. current resolution (informational, always recorded) ------------------------
# Win32_VideoController, not SystemInformation.VirtualScreen: the latter is DPI-scaled
# in a non-DPI-aware host process (5120x1440 at 150 % read back as 3413x960).
$activeCtrl = Get-CimInstance Win32_VideoController |
              Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
$r.resolution = if ($activeCtrl) {
    "$($activeCtrl.CurrentHorizontalResolution)x$($activeCtrl.CurrentVerticalResolution)"
} else { 'NONE' }

$r.ok = ($fails.Count -eq 0)
$r.failed = @($fails)
Write-Output ('=== HEALTH === ' + ($r | ConvertTo-Json -Depth 6 -Compress))
if ($r.ok) { exit 0 } else { exit 1 }
