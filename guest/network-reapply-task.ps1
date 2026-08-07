# Re-apply the Qubes network configuration whenever a network interface appears.
# QWT applies the qubesdb-driven static IP with network-setup.exe at boot, but nothing
# re-runs it when a vif is hot-plugged, so the guest lands on APIPA (169.254.*) with no
# gateway until a reboot (measured 2026-08-07). This registers an EVENT-TRIGGERED task so
# the repair happens by itself.
#
# Trigger: Microsoft-Windows-NetworkProfile/Operational event 10000 = "network connected",
# which fires when an interface comes up - including a hot-plugged Xen vif.
$ErrorActionPreference = 'Stop'
$exe = 'C:\Program Files\Qubes Tools\bin\network-setup.exe'
if (-not (Test-Path $exe)) { Write-Output 'ABORT: network-setup.exe not found'; exit 1 }

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Re-apply Qubes network config when an interface appears</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT3S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
  </Settings>
  <Actions Context="Author"><Exec><Command>"$exe"</Command></Exec></Actions>
</Task>
"@
$f = "$env:TEMP\qubes-netauto.xml"
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesNetworkReapply /xml $f /f 2>&1
Write-Output ("REGISTER: " + ($o -join ' '))
Write-Output ("RC=" + $LASTEXITCODE)
