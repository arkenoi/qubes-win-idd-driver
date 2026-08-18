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

if (-not (Test-Path (Join-Path $bindir 'network-setup.exe'))) {
    Write-Output 'MARKJSON'
    [pscustomobject]@{ ok=$false; error='network-setup.exe not found - QWT not installed?' } | ConvertTo-Json -Compress
    exit 1
}

# ---------------- per-boot payload (persistent path on the template root) ----------------
# NOTE on qubesdb: the CLI (qubesdb-cmd) is UNUSABLE on this build (arg parsing broken - the
# known optind bug; measured 2026-08-18: usage text on every read form, meaningless rc), and
# in-process qdb_open via P/Invoke fails where network-setup.exe's succeeds (unexplained;
# 15x retry measured failing). The oracle used instead is network-setup.exe's OWN exit code,
# read from its source: 21 ERROR_NOT_READY = qubesdb unreachable for 60 s; 1287
# ERROR_UNIDENTIFIED_ERROR = qubesdb answered but /qubes-ip is absent = NO NETVM (network
# keys are written pre-unpause on every netvm boot, so 1287 cannot occur on one); 0 = keys
# read and config attempted (INCLUDING the silent no-matching-adapter case, so rc 0 proves
# nothing - the outcome state is what is verified).
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
    # a marker nobody reads - put pixels in front of the human. msg.exe works offline.
    & msg.exe * "Qubes PV network configuration FAILED: $why (see C:\ProgramData\QubesPvNic-FAILED.txt)" 2>$null
    exit 1
}

# 2. APPLY + VERIFY, bounded by wall clock. network-setup.exe serves as the qubesdb oracle
#    AND the value source (see installer header for why the CLI and P/Invoke are out):
#    rc 21 = qubesdb down (retry, loud at deadline); rc 1287 = qubesdb up, /qubes-ip ABSENT
#    = no netvm (quiet exit - only with no XENVIF/XENBUS-VIF device present; 1287 WITH a vif
#    device is an anomaly and stays loud); rc 0 = keys read - but MEASURED 2026-08-18: on the
#    per-boot fresh install GetAdaptersInfo reports the adapter as 'Xen PV Network Device'
#    WITHOUT the ' #0' suffix stock strcmp expects (the suffix only exists in netcfg state a
#    PRIMED template persisted), so stock can NEVER configure on this path and instead we
#    parse the values it logs (SetupNetwork: ip/netmask/gateway, needs QWT LogDir set - the
#    installer seeds it) and apply them DIRECTLY to the XENVIF adapter by ifIndex.
#    DNS: Qubes DNS is constant by design (net.py: always 10.139.1.1/10.139.1.2).
$ns = 'C:\Program Files\Qubes Tools\bin\network-setup.exe'
$nslogdir = 'C:\ProgramData\QubesLogs'
$deadline = (Get-Date).AddSeconds(300)

function PvAdapter { Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.PnPDeviceID -like 'XENVIF\*' } | Select-Object -First 1 }
function VifDevicePresent {
    # Bus-level view: the XENBUS VIF PDO (pre-driver) or any XENVIF devnode. Present iff a
    # vif exists in xenstore, i.e. iff a netvm is attached - independent of driver state.
    $d = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -like 'XENBUS\VEN_XP0001&DEV_VIF*' -or $_.InstanceId -like 'XENVIF\*' }
    return (@($d).Count -gt 0)
}
function NsValues {
    # Latest 'SetupNetwork: ip: A, netmask: B, gateway: C' line from the newest ns log.
    $f = Get-ChildItem $nslogdir -Filter 'network-setup-*' -EA SilentlyContinue |
         Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $f) { return $null }
    $m = Select-String -Path $f.FullName -Pattern 'SetupNetwork: ip: ([0-9.]+), netmask: ([0-9.]+), gateway: ([0-9.]+)' |
         Select-Object -Last 1
    if (-not $m) { return $null }
    $mask = $m.Matches[0].Groups[2].Value
    $prefix = 0
    foreach ($o in $mask.Split('.')) { $b = [convert]::ToString([int]$o, 2); $prefix += ($b.ToCharArray() | Where-Object { $_ -eq '1' }).Count }
    @{ ip = $m.Matches[0].Groups[1].Value; prefix = $prefix; gw = $m.Matches[0].Groups[3].Value }
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
    return (Test-Connection -ComputerName $rt.NextHop -Count 2 -Quiet -EA SilentlyContinue)
}

# Event-triggered run on an already-correct state: converge fast (self-retrigger guard).
if (Applied) { L 'already applied on entry'; Remove-Item $mark -Force -EA SilentlyContinue; exit 0 }

$rcHist = @()
$sawAdapter = $false
$ok = $false
while ((Get-Date) -lt $deadline) {
    $ad = PvAdapter
    if ($ad) { $sawAdapter = $true }
    L ("apply pass (adapter=" + $(if ($ad) { "ifIndex $($ad.ifIndex) $($ad.Status)" } else { 'none' }) + ")")
    $p = Start-Process -FilePath $ns -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(90000)) { $p.Kill(); $rc = -1; L 'network-setup.exe timed out - killed' }
    else { $rc = $p.ExitCode; L "network-setup.exe rc=$rc" }
    $rcHist += $rc
    if ($rc -eq 1287 -and -not (VifDevicePresent)) {
        L 'qubesdb up, /qubes-ip absent, no vif device: no netvm, nothing to apply'
        Remove-Item $mark -Force -EA SilentlyContinue
        exit 0
    }
    $script:want = NsValues
    if ($script:want -and $ad) {
        L ("direct apply " + $script:want.ip + "/" + $script:want.prefix + " gw " + $script:want.gw + " on ifIndex " + $ad.ifIndex)
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
        # Qubes DNS is invariant (net.py dns property): 10.139.1.1 / 10.139.1.2.
        Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses @('10.139.1.1','10.139.1.2') -EA SilentlyContinue
    }
    Start-Sleep -Seconds 3
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
    Start-Sleep -Seconds 5
}

if ($ok) {
    L 'SUCCESS: non-APIPA IP + default route + reachable gateway, stable on XENVIF adapter'
    Remove-Item $mark -Force -EA SilentlyContinue
    exit 0
}
$hist = ($rcHist | Select-Object -Last 8) -join ','
if ($rcHist -and (@($rcHist | Where-Object { $_ -ne 21 }).Count -eq 0)) { Loud "qubesdb unreachable throughout (network-setup rc history: $hist)" }
elseif ($sawAdapter) { Loud "network config never stably applied (rc history: $hist)" }
else { Loud "PV adapter never appeared (rc history: $hist)" }
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
# QWT logging on (Info): the payload PARSES network-setup's log for the qubesdb values
# (SetupNetwork: ip/netmask/gateway) because both the CLI and in-process reads are broken.
New-Item -ItemType Directory -Path 'C:\ProgramData\QubesLogs' -Force | Out-Null
reg add "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v LogDir /t REG_SZ /d "C:\ProgramData\QubesLogs" /f | Out-Null
reg add "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v LogLevel /t REG_DWORD /d 3 /f | Out-Null

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
