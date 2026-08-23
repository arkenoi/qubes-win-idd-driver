# Netvm-free PV NIC self-priming: install on a TEMPLATE (persistent root). AppVMs need nothing.
#
# WHY (measured 2026-08-17/18; verified in pvdrivers source 2026-08-18; adversarially reviewed):
# the first time a vif appears, xenvif's NET-child START handler fails with
# STATUS_PNP_REBOOT_REQUIRED (problem 14) unless the boot-time emulated-NIC unplug already
# happened in that same boot. The unplug is gated on Services\XEN\Unplug\NICS, which xen.sys
# CONSUMES (delete-on-read) at every boot and VETOES unless some Enum\XENBUS subkey name
# contains 'VIF'. An AppVM's volatile root discards the half-finished install every boot ->
# endless reset loop. Seeding the latch + veto key makes the per-boot fresh install complete in
# ONE boot at problem 0, no netvm ever attached (measured). What the latch does NOT provide is
# L3 config: the adapter is born with a new NetCfgInstanceId every boot, no DHCP exists on the
# PV vif path (the DHCP server lives in the stubdom and serves only the emulated NIC), and
# stock network-setup.exe runs once at QrexecAgent start - usually before the install finishes -
# then maps "no matching adapter" to silent success. Hence APIPA.
#
# THIS INSTALLER is transactional (panel amendment A2-op): it registers and verifies the tasks
# FIRST; the latch is only ever armed BY the task, so a failed registration leaves the template
# un-latched (the known LOUD crash state), never latched-without-applier (the forbidden SILENT
# APIPA state).
#
# Tasks registered (both SYSTEM):
#   QubesPvNic       boot trigger + NetworkProfile event 10000: re-arm latch, then bounded
#                    verify-retry of the applier with settle re-verification; loud on failure
#                    (marker file + event log + interactive msg - amendment A4).
#   QubesPvNicRearm  System/User32 event 1074 (shutdown initiated): re-arm only. Covers the
#                    'boot -> QWT/PV upgrade rewrites NICS=0 (INF has no NOCLOBBER) -> shutdown'
#                    clobber and boots that die before the startup task (amendment A3).
#
# Also seeds (amendment A9): NewNetworkWindowOff, DriverSearching SearchOrderConfig=0 (no WU
# driver search on the per-boot install), powercfg /h off (no fast-startup hive weirdness).
#
# Output: one MARKJSON line consumed by the harness.
$ErrorActionPreference = 'SilentlyContinue'

$bindir   = 'C:\Program Files\Qubes Tools\bin'
$payload  = Join-Path $bindir 'pvnic-boot.ps1'
$fail = @{}

# "Is QWT installed here?" - do NOT sentinel on network-setup.exe. That binary is RETIRED (this
# applier replaced it), so once it stops shipping, keying off it would abort on a perfectly good
# install. qrexec-agent.exe is the right sentinel: it is the core of QWT, always present, and
# nothing we do removes it.
if (-not (Test-Path (Join-Path $bindir 'qrexec-agent.exe'))) {
    Write-Output 'MARKJSON'
    [pscustomobject]@{ ok=$false; error='qrexec-agent.exe not found in the QWT bin dir - QWT not installed?' } | ConvertTo-Json -Compress
    exit 1
}

# RETIRE the stock network applier. QWT's own "Autostart" value makes QrexecAgent run
# network-setup.exe at every agent start - which, now that this applier owns the same job, means TWO
# mechanisms writing the same L3 config at different moments. That is precisely the sort of split
# that makes a boot non-deterministic, and the stock one runs at the worst possible time (usually
# before the install has finished). Clear it here, where the replacement is installed, so the
# hand-over happens in one step rather than leaving both live.
$qwtKey = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
try {
    $auto = (Get-ItemProperty -Path $qwtKey -Name Autostart -EA SilentlyContinue).Autostart
    if ($auto -and $auto -match 'network-setup\.exe') {
        Remove-ItemProperty -Path $qwtKey -Name Autostart -EA Stop
        Write-Output "retired stock autostart: $auto"
    } elseif ($auto) {
        Write-Output "left Autostart alone (not network-setup.exe): $auto"
    }
} catch { Write-Output "WARNING: could not clear the stock Autostart value: $($_.Exception.Message)" }

# ---------------- per-boot payload (persistent path on the template root) ----------------
# NOTE on qubesdb: qubesdb VALUE READS work in-process via the client DLL (qdb_open/qdb_read; see
# guest/qubesdb-read.ps1). The earlier "in-process P/Invoke fails / reads are broken" belief was a
# marshaling bug in the probe, now retired; what is genuinely broken is the qubesdb-cmd CLI (the
# optind bug) and qubesdb WRITES. This applier reads everything it needs STRAIGHT FROM QUBESDB and
# no longer runs network-setup.exe at all:
#   - netvm presence: qdb_open succeeds (up) + /qubes-ip present. /qubes-ip is written pre-unpause
#     on every netvm boot, so 'up + /qubes-ip absent + no XENBUS/XENVIF vif device' = NO NETVM
#     (quiet exit); 'up + absent + vif device present' = keys not published yet (retry).
#   - L3 values: /qubes-ip //qubes-netmask //qubes-gateway, applied by ifIndex (below).
# This replaces network-setup.exe, whose exit-code oracle and log-parse we used ONLY because the
# reads were (wrongly) believed unavailable.
#
# The 2026-08-19 verification of this read path was done on a guest attached to a REAL netvm, and
# that session is what left a DHCP lease, a NetworkList profile and a DHCPv6 DUID inside the
# template image - inherited by every AppVM, and racing this applier at every boot. Do not verify
# this way again: mgmt/clone-to-template.sh now scrubs network identity on its own offline boot,
# and the addresses that run recorded are deliberately not repeated here.
$body = @'
param([switch]$RearmOnly)
# QubesPvNic per-boot payload. Runs as SYSTEM. See pvnic-selfprime.ps1 for the full why.
$ErrorActionPreference = 'SilentlyContinue'
$log  = 'C:\ProgramData\QubesPvNic.log'
$mark = 'C:\ProgramData\QubesPvNic-FAILED.txt'
function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
if ((Get-Item $log -EA SilentlyContinue).Length -gt 262144) { Remove-Item $log -Force }

# 1. RE-ARM THE LATCH. xen.sys deleted the value at this boot's start (delete-on-read);
#    writing it now arms the NEXT boot. Harmless on AppVMs (volatile root, and xenvif re-arms
#    on device start anyway). Runs on every trigger including shutdown (1074).
reg add "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF" /f | Out-Null
if ($RearmOnly) { L 'rearm-only trigger: latch re-armed'; exit 0 }
# LogDir is global to all QWT modules; keep it bounded (template root is persistent).
Get-ChildItem 'C:\ProgramData\QubesLogs' -Filter '*.log' -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -EA SilentlyContinue
L "--- run start (boot=$((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')))"
L "latch re-armed NICS=$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug').NICS)"

function Loud($why) {
    L "FAILED: $why"
    Set-Content $mark ("QubesPvNic FAILED: {0} at {1}" -f $why, (Get-Date -Format o))
    New-EventLog -LogName Application -Source QubesPvNic -EA SilentlyContinue
    Write-EventLog -LogName Application -Source QubesPvNic -EntryType Error -EventId 1000 -Message "PV NIC: $why" -EA SilentlyContinue
    # Interactive alert (amendment A4): dom0 sees no guest network state, an in-guest file is
    # a marker nobody reads - put pixels in front of the human. Console session ONLY (msg *
    # also targets session 0; suspected - unproven - of wedging qrexec on the D2 test boot),
    # and persistent (default msg timeout is ~60 s, which made the D2 pixel capture miss it).
    & msg.exe console /time:86400 "Qubes PV network configuration FAILED: $why (see C:\ProgramData\QubesPvNic-FAILED.txt)" 2>$null
    exit 1
}

# 2. APPLY + VERIFY, bounded by wall clock. Source is qubesdb directly (see the NOTE above):
#    QdbUp gates readiness; QdbValues gives ip/netmask/gateway; VifDevicePresent distinguishes
#    'no netvm' (quiet exit) from 'keys not published yet' (retry). Applied by ifIndex because the
#    fresh-install adapter is named 'Xen PV Network Device' WITHOUT the ' #0' suffix stock strcmp
#    expects (that suffix only exists in netcfg state a PRIMED template persisted).
#    DNS: Qubes DNS is constant by design (net.py: always 10.139.1.1/10.139.1.2).
$deadline = (Get-Date).AddSeconds(300)

function PvAdapter { Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.PnPDeviceID -like 'XENVIF\*' } | Select-Object -First 1 }
function VifDevicePresent {
    # Bus-level view: a PRESENT XENBUS VIF PDO (pre-driver) or XENVIF devnode. Present iff a vif
    # exists in xenstore, i.e. iff a netvm is attached - independent of driver state. MUST filter to
    # present devices (-PresentOnly): a netvm that was once attached then removed leaves a GHOST
    # devnode (Status=Unknown, Present=False) that must NOT count as a live vif, or the no-netvm
    # quiet-exit would hang until the deadline on any guest that was ever networked.
    $d = Get-PnpDevice -PresentOnly -EA SilentlyContinue | Where-Object { $_.InstanceId -like 'XENBUS\VEN_XP0001&DEV_VIF*' -or $_.InstanceId -like 'XENVIF\*' }
    return (@($d).Count -gt 0)
}
function QdbType {
    if (-not ('QdbP' -as [type])) {
        Add-Type @"
using System; using System.Runtime.InteropServices;
public static class QdbP {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr qdb_open(IntPtr v);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)] public static extern IntPtr qdb_read(IntPtr h, string p, out uint l);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void qdb_close(IntPtr h);
}
"@
    }
}
function QdbGet([string]$path) {
    # Reliable qubesdb value read via the client DLL (mirror of guest/qubesdb-read.ps1). The old
    # "in-process reads are broken" belief was a P/Invoke marshaling bug; this is measured working.
    try {
        QdbType
        $h = [QdbP]::qdb_open([IntPtr]::Zero)
        if ($h -eq [IntPtr]::Zero) { return $null }
        try {
            $l = [uint32]0
            $p = [QdbP]::qdb_read($h, $path, [ref]$l)
            if ($p -eq [IntPtr]::Zero) { return $null }
            return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$l)
        } finally { [QdbP]::qdb_close($h) }
    } catch { return $null }
}
function QdbUp {
    # qubesdb daemon reachable? (qdb_open succeeds) - replaces network-setup.exe's rc 21 oracle.
    try { QdbType; $h = [QdbP]::qdb_open([IntPtr]::Zero); if ($h -eq [IntPtr]::Zero) { return $false }; [QdbP]::qdb_close($h); return $true } catch { return $false }
}
function QdbValues {
    # L3 config straight from qubesdb - the ONLY source now. network-setup.exe matched the adapter
    # by NAME and failed on the fresh-install adapter (the ' #0'-suffix problem), which is exactly
    # why we apply by ifIndex ourselves; it gave us nothing the direct read does not. All three
    # keys must be present and dotted-decimal, else $null (qubesdb not ready / no netvm yet).
    $ip = QdbGet '/qubes-ip'; $mask = QdbGet '/qubes-netmask'; $gw = QdbGet '/qubes-gateway'
    if (-not ($ip -and $mask -and $gw)) { return $null }
    if ($ip -notmatch '^[0-9.]+$' -or $mask -notmatch '^[0-9.]+$' -or $gw -notmatch '^[0-9.]+$') { return $null }
    $prefix = 0
    foreach ($o in $mask.Split('.')) { $b = [convert]::ToString([int]$o, 2); $prefix += ($b.ToCharArray() | Where-Object { $_ -eq '1' }).Count }
    # DNS comes from the same place as everything else. It used to be hardcoded here because the
    # Qubes dns property is invariant, but qubesdb publishes it per-VM (verified 2026-08-23:
    # /qubes-primary-dns, /qubes-secondary-dns present alongside /qubes-ip), so reading it removes
    # the one value this applier was still assuming. The well-known pair stays as a fallback: a
    # missing key must not leave the guest with no resolver.
    $dns = @($(QdbGet '/qubes-primary-dns'), $(QdbGet '/qubes-secondary-dns')) |
           Where-Object { $_ -match '^[0-9.]+$' }
    if (-not $dns) { $dns = @('10.139.1.1', '10.139.1.2') }
    @{ ip = $ip; prefix = $prefix; gw = $gw; dns = $dns }
}
$script:want = $null
function Applied {
    $ad = PvAdapter
    if (-not $ad) { return $false }
    $good = @(Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -EA SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '0.0.0.0' } | ForEach-Object IPAddress)
    if ($good.Count -eq 0) { return $false }
    if ($script:want -and ($good -notcontains $script:want.ip)) { return $false }
    $rt = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
          Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.NextHop -ne '0.0.0.0' } | Select-Object -First 1
    if (-not $rt) { return $false }
    if ($script:want -and $rt.NextHop -ne $script:want.gw) { return $false }
    # REACHABILITY IS DELIBERATELY NOT PART OF THE VERDICT.
    # This used to end with `Test-Connection $rt.NextHop`, i.e. it required the gateway to
    # answer ICMP echo. A mirage-firewall netvm does not: measured on the rig, ping to the
    # gateway 10.138.21.72 fails while ping to 8.8.8.8 THROUGH that same gateway succeeds and
    # the link carries 12 MB/s. Qubes also uses point-to-point /32 routing with the well-known
    # fe:ff:ff:ff:ff:ff peer MAC, so there is no ARP entry to fall back on either.
    # The result was a false alarm on every boot behind such a netvm: the applier re-applied a
    # perfectly correct configuration every 12 s until it gave up and popped
    # "network configuration FAILED" at the user, while the network worked the whole time.
    # What this function exists to catch - APIPA, a missing or wrong address, a missing or
    # wrong default route, a dead adapter - is fully covered by the checks above. Whether a
    # given netvm chooses to answer pings is not a property of our configuration.
    return $true
}

# Event-triggered run on an already-correct state: converge fast (self-retrigger guard).
if (Applied) { L 'already applied on entry'; Remove-Item $mark -Force -EA SilentlyContinue; exit 0 }

$qdbEverUp = $false
$sawAdapter = $false
$ok = $false
while ((Get-Date) -lt $deadline) {
    $ad = PvAdapter
    if ($ad) { $sawAdapter = $true }
    L ("apply pass (adapter=" + $(if ($ad) { "ifIndex $($ad.ifIndex) $($ad.Status)" } else { 'none' }) + ")")
    if (-not (QdbUp)) { L 'qubesdb not reachable yet - waiting'; Start-Sleep -Seconds 2; continue }
    $qdbEverUp = $true
    $script:want = QdbValues            # L3 config straight from qubesdb - the ONLY source
    if (-not $script:want) {
        # qubesdb up but /qubes-ip not published. No vif device => no netvm => nothing to apply.
        if (-not (VifDevicePresent)) {
            L 'qubesdb up, /qubes-ip absent, no vif device: no netvm, nothing to apply'
            Remove-Item $mark -Force -EA SilentlyContinue
            exit 0
        }
        L 'qubesdb up, vif present, /qubes-ip not yet published - waiting'
        Start-Sleep -Seconds 2; continue
    }
    if ($ad) {
        L ("direct apply " + $script:want.ip + "/" + $script:want.prefix + " gw " + $script:want.gw + " on ifIndex " + $ad.ifIndex + " (src=qubesdb)")
        # Turn DHCP off FIRST. Qubes configures guests statically from qubesdb, so the DHCP
        # client has no job here - but it keeps a cached lease, and an AppVM's volatile root
        # restores the template's stale one on every boot. Measured on win10-app 2026-08-23:
        # lease 10.137.0.70 surfaced alongside the correct 10.137.0.72 and traffic stopped for
        # ~13 s mid-boot while a later applier pass tore the addresses down and rebuilt them.
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -Dhcp Disabled -EA SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -EA SilentlyContinue |
            Where-Object { $_.IPAddress -ne $script:want.ip } |
            Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
        if (-not (Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -EA SilentlyContinue |
                  Where-Object { $_.IPAddress -eq $script:want.ip })) {
            New-NetIPAddress -InterfaceIndex $ad.ifIndex -IPAddress $script:want.ip -PrefixLength $script:want.prefix -PolicyStore ActiveStore -EA SilentlyContinue | Out-Null
        }
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
            Where-Object { $_.ifIndex -ne $ad.ifIndex -or $_.NextHop -ne $script:want.gw } |
            Remove-NetRoute -Confirm:$false -EA SilentlyContinue
        if (-not (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
                  Where-Object { $_.ifIndex -eq $ad.ifIndex -and $_.NextHop -eq $script:want.gw })) {
            New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $ad.ifIndex -NextHop $script:want.gw -PolicyStore ActiveStore -EA SilentlyContinue | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $script:want.dns -EA SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if (Applied) {
        # Settle re-verify (amendment A2): a first-install adapter re-bind can wipe the
        # non-persistent runtime config AFTER a one-shot verify. Two stable confirmations
        # 30 s apart, re-entering the apply loop on regression.
        L 'verified; settle re-verify (+30s, +60s)'
        $stable = $true
        foreach ($i in 1..2) {
            Start-Sleep -Seconds 30
            if (-not (Applied)) { L "settle re-verify #$i FAILED - state regressed, re-applying"; $stable = $false; break }
        }
        if ($stable) { $ok = $true; break }
    }
    Start-Sleep -Seconds 2
}

if ($ok) {
    $echo = [bool](Test-Connection -ComputerName $script:want.gw -Count 1 -Quiet -EA SilentlyContinue)
    L ("SUCCESS: non-APIPA IP + default route, stable on XENVIF adapter (gateway echo: " +
       $(if ($echo) { 'yes' } else { 'no - normal for a mirage-firewall netvm' }) + ")")
    Remove-Item $mark -Force -EA SilentlyContinue
    exit 0
}
if (-not $qdbEverUp) { Loud 'qubesdb never became reachable within the deadline' }
elseif ($sawAdapter) { Loud ("network config never stably applied (last qubesdb ip: " + $(if ($script:want) { $script:want.ip } else { 'none' }) + ")") }
else { Loud 'PV adapter never appeared within the deadline' }
'@
Set-Content -Path $payload -Value $body -Encoding ASCII
if (-not (Test-Path $payload)) { $fail.payload = 'could not write payload' }
$payloadHash = (Get-FileHash $payload -Algorithm SHA256).Hash.ToLower()

# ---------------- tasks (registered and verified BEFORE any latch exists) ----------------
function Register-Xml($name, $xml) {
    $f = "$env:TEMP\$name.xml"
    [IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
    $out = & schtasks /create /tn $name /xml $f /f 2>&1
    if ($LASTEXITCODE -ne 0) { return "register failed: $($out -join ' ')" }
    & schtasks /query /tn $name | Out-Null
    if ($LASTEXITCODE -ne 0) { return 'query-after-register failed' }
    return $null
}

$actMain  = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$payload`""
$actRearm = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$payload`" -RearmOnly"

$xmlMain = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Qubes PV NIC self-prime: re-arm unplug latch + apply qubesdb network config</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT3S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>$actMain</Arguments></Exec></Actions>
</Task>
"@

$xmlRearm = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Qubes PV NIC latch re-arm at shutdown (INF clobber defense)</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='User32'] and EventID=1074]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>$actRearm</Arguments></Exec></Actions>
</Task>
"@

$e = Register-Xml 'QubesPvNic' $xmlMain;      if ($e) { $fail.task_main = $e }
$e = Register-Xml 'QubesPvNicRearm' $xmlRearm; if ($e) { $fail.task_rearm = $e }

# ---------------- transactionality: no tasks -> no latch, roll back everything ----------------
if ($fail.Count -gt 0) {
    schtasks /delete /tn QubesPvNic /f 2>$null | Out-Null
    schtasks /delete /tn QubesPvNicRearm /f 2>$null | Out-Null
    Remove-Item $payload -Force -EA SilentlyContinue
    reg delete "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS /f 2>$null | Out-Null
    reg delete "HKLM\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF" /f 2>$null | Out-Null
    Write-Output 'MARKJSON'
    [pscustomobject]@{ ok=$false; rolled_back=$true; errors=$fail } | ConvertTo-Json -Compress
    exit 1
}

# ---------------- side seeds (A9) ----------------
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v SearchOrderConfig /t REG_DWORD /d 0 /f | Out-Null
powercfg /h off 2>$null | Out-Null
# QWT logging on (Info): the applier reads qubesdb directly and no longer parses this log, but
# LogDir/LogLevel are still seeded so stock network-setup.exe (which QrexecAgent runs at startup,
# independent of us) leaves a readable trace for debugging the network path.
New-Item -ItemType Directory -Path 'C:\ProgramData\QubesLogs' -Force | Out-Null
reg add "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v LogDir /t REG_SZ /d "C:\ProgramData\QubesLogs" /f | Out-Null
reg add "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v LogLevel /t REG_DWORD /d 3 /f | Out-Null
# Updates are dom0-owned (standing project rule): guest auto-update OFF. This matters more
# with the latch, because AppVMs now have working network every boot and WU would pull
# updates into a volatile root each time. NoAutoUpdate does NOT affect the dom0-driven
# template updater (it uses explicit WU COM calls, which stay functional). The driver
# exclusion also guards against WU-delivered Xen PV packages whose INF AddReg would rewrite
# Unplug\NICS=0 (the re-arm tasks are the second line of defense).
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f | Out-Null

# ---------------- arm now, via the task itself, and verify ----------------
& schtasks /run /tn QubesPvNic | Out-Null
$armed = $false
foreach ($i in 1..12) {
    Start-Sleep -Seconds 5
    $n = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS
    $k = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF'
    if ($n -eq 1 -and $k) { $armed = $true; break }
}
if (-not $armed) {
    schtasks /delete /tn QubesPvNic /f 2>$null | Out-Null
    schtasks /delete /tn QubesPvNicRearm /f 2>$null | Out-Null
    Remove-Item $payload -Force -EA SilentlyContinue
}

Write-Output 'MARKJSON'
[pscustomobject]@{
    ok           = $armed
    armed        = $armed
    nics         = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS
    vif_enum_key = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF')
    payload_sha256 = $payloadHash
    task_main    = ((& schtasks /query /tn QubesPvNic 2>&1 | Select-String QubesPvNic | Select-Object -First 1) -replace '\s+',' ')
    task_rearm   = ((& schtasks /query /tn QubesPvNicRearm 2>&1 | Select-String QubesPvNicRearm | Select-Object -First 1) -replace '\s+',' ')
    hibernation_off = -not (Test-Path 'C:\hiberfil.sys')
    bootlog      = ("$(Get-Content 'C:\ProgramData\QubesPvNic.log' -Raw -EA SilentlyContinue)" -replace '\s+',' ')
} | ConvertTo-Json -Compress
