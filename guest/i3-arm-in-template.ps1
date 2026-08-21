# Arm I3 diagnostics IN THE TEMPLATE, so every AppVM built on it captures its own failing boot.
#
# Why here: an AppVM answers qrexec for only a couple of minutes after boot and then goes silent
# (idle - 0.00 cores - so it is waiting, not spinning), which is far too little time to enable log
# channels and run a probe by hand. The template's root volume IS the AppVM's root volume, so
# anything configured here is present on the AppVM's very first boot.
#
# Two parts:
#   1. ENABLE the operational channels. "No Winlogon events" is not evidence if the channel is
#      switched off - Microsoft-Windows-TaskScheduler/Operational was off by default and cost a
#      wrong conclusion earlier today. Verify enabled state rather than assuming it.
#   2. A boot-triggered SYSTEM task that writes diagnostics to Q:\ - the PRIVATE volume, which
#      survives the AppVM's reboots, unlike C: which is a discarded CoW overlay.
$ErrorActionPreference='Continue'
$L=@()

foreach ($ch in @('Microsoft-Windows-Winlogon/Operational',
                  'Microsoft-Windows-User Profile Service/Operational',
                  'Microsoft-Windows-TaskScheduler/Operational')) {
  $before = (& wevtutil gl "$ch" 2>&1 | Select-String '^\s*enabled:' | Select-Object -First 1)
  & wevtutil sl "$ch" /e:true 2>&1 | Out-Null
  $after  = (& wevtutil gl "$ch" 2>&1 | Select-String '^\s*enabled:' | Select-Object -First 1)
  $L += ("channel [$ch] " + ($before -replace '\s+',' ') + " -> " + ($after -replace '\s+',' '))
}

# the probe the AppVM will run at its own boot
$probe = @'
$ErrorActionPreference='Continue'
$out = 'Q:\i3-boot-probe.txt'
$L=@()
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$L += ("=== boot " + $boot + "  probed " + (Get-Date) + "  host " + $env:COMPUTERNAME)
$L += "--- sessions ---"
foreach($line in (query session 2>&1)){ $L += ("  " + $line) }
$L += "--- session processes ---"
foreach($n in 'winlogon','csrss','logonui','userinit','explorer','dwm','sihost'){
  $p=Get-Process $n -EA SilentlyContinue
  if($p){ foreach($x in $p){ $L += ("  $n pid=" + $x.Id + " session=" + $x.SessionId) } } else { $L += "  $n NOT RUNNING" }
}
$L += "--- Winlogon / ProfSvc events this boot ---"
foreach($ch in 'Microsoft-Windows-Winlogon/Operational','Microsoft-Windows-User Profile Service/Operational'){
  try{
    $e=Get-WinEvent -FilterHashtable @{LogName=$ch;StartTime=$boot} -EA SilentlyContinue | Select-Object -First 10
    if(-not $e){ $L += ("  [" + $ch + "] no events") }
    foreach($x in $e){ $L += ("  [" + $ch + "] " + $x.TimeCreated.ToString('HH:mm:ss') + " id=" + $x.Id + " " + (($x.Message -split [char]10)[0])) }
  }catch{ $L += ("  [" + $ch + "] ERR " + $_.Exception.Message) }
}
$L += "--- errors/criticals this boot ---"
try{
  $e=Get-WinEvent -FilterHashtable @{LogName=@('System','Application');StartTime=$boot;Level=@(1,2)} -EA SilentlyContinue | Select-Object -First 12
  if(-not $e){ $L += "  (none)" }
  foreach($x in $e){ $L += ("  " + $x.TimeCreated.ToString('HH:mm:ss') + " [" + $x.ProviderName + "] id=" + $x.Id + " " + (($x.Message -split [char]10)[0])) }
}catch{}
$L += "--- autologon values ---"
$w='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
foreach($v in 'AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount','AutoLogonSID'){
  $val=(Get-ItemProperty -Path $w -Name $v -EA SilentlyContinue).$v
  $L += ("  $v = " + $(if($null -ne $val){"[$val]"}else{'(absent)'}))
}
$L | Out-File -LiteralPath $out -Encoding ASCII -Append
'@
$dst = 'C:\Program Files\Qubes Tools\bin\i3-boot-probe.ps1'
Set-Content -LiteralPath $dst -Value $probe -Encoding UTF8
$L += ("probe written: " + (Test-Path $dst))

# boot-triggered, SYSTEM, 45 s in - late enough for the session to have settled or failed
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>I3 diagnostics: capture session state at boot to the private volume</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT45S</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT3M</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$dst"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'i3task.xml'
$xml | Out-File -LiteralPath $f -Encoding Unicode
$o = & schtasks /create /tn QwtI3Probe /xml "$f" /f 2>&1
$L += ("task registered rc=$LASTEXITCODE : " + ($o -join ' '))
$L | ForEach-Object { Write-Output $_ }
