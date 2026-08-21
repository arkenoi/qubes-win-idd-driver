# I3: why does an AppVM's console session never leave ConnQ?
#
# Ruled out already, by measurement: profile presence/ACLs/SID, credentials, account state, the
# autologon registry values (including DefaultPassword), the guard task, and - just now, against the
# template as a control - the display configuration (both have the IDD started and the Basic Display
# Adapter disabled, and the template logs on fine).
#
# Winlogon writes NOTHING to its operational channel on the AppVM, so it never begins a logon. This
# captures the layer BELOW that: is winlogon/csrss even alive for session 1, did the session manager
# create the session, is C: writable (an AppVM's root is a CoW overlay), and did anything error at
# boot. One shot, because this guest stops answering qrexec after a few minutes.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\i3-probe.txt'
$L=@()
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$L += ("host=" + $env:COMPUTERNAME + " boot=" + $boot + " uptime_min=" + [math]::Round(((Get-Date)-$boot).TotalMinutes,1))

$L += "--- session-critical processes (session id matters) ---"
foreach($n in 'winlogon','csrss','logonui','userinit','explorer','dwm','sihost','fontdrvhost'){
  $p=Get-Process $n -EA SilentlyContinue
  if($p){ foreach($x in $p){ $L += ("  " + $n + " pid=" + $x.Id + " session=" + $x.SessionId) } }
  else { $L += ("  " + $n + " NOT RUNNING") }
}

$L += "--- sessions ---"
foreach($line in (query session 2>&1)){ $L += ("  " + $line) }

$L += "--- is C: writable? (AppVM root is a CoW overlay) ---"
try{ $t="C:\ProgramData\Qubes\i3-write-test.tmp"; Set-Content -LiteralPath $t -Value 'x' -EA Stop; Remove-Item $t -Force -EA SilentlyContinue; $L += "  C: writable YES" }
catch{ $L += ("  C: writable NO - " + $_.Exception.Message) }
foreach($d in 'C','Q'){
  try{ $x=Get-PSDrive $d -EA Stop; $L += ("  " + $d + ": used=" + [math]::Round($x.Used/1GB,2) + "GB free=" + [math]::Round($x.Free/1GB,2) + "GB") }catch{ $L += ("  " + $d + ": ABSENT") }
}

$L += "--- services that session creation depends on ---"
foreach($s in 'Winlogon','UserManager','ProfSvc','Themes','TermService','seclogon','UmRdpService'){
  $svc=Get-Service $s -EA SilentlyContinue
  if($svc){ $L += ("  " + $s + " " + $svc.Status + " start=" + (Get-CimInstance Win32_Service -Filter "Name='$s'" -EA SilentlyContinue).StartMode) }
  else { $L += ("  " + $s + " (no such service)") }
}

$L += "--- ANY error/critical events since boot, any channel ---"
try{
  $ev=Get-WinEvent -FilterHashtable @{LogName=@('System','Application');StartTime=$boot;Level=@(1,2)} -EA SilentlyContinue | Select-Object -First 15
  if(-not $ev){ $L += "  (none)" }
  foreach($x in $ev){ $L += ("  " + $x.TimeCreated.ToString('HH:mm:ss') + " [" + $x.ProviderName + "] id=" + $x.Id + " " + (($x.Message -split [char]10)[0])) }
}catch{ $L += ("  ERR " + $_.Exception.Message) }

$L += "--- autologon values as seen right now ---"
$w='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
foreach($v in 'AutoAdminLogon','DefaultUserName','DefaultDomainName','DefaultPassword','AutoLogonCount','AutoLogonSID','Userinit','Shell'){
  $val=(Get-ItemProperty -Path $w -Name $v -EA SilentlyContinue).$v
  $L += ("  " + $v + " = " + $(if($null -ne $val){"[$val]"}else{'(absent)'}))
}
$L | Out-File -LiteralPath $out -Encoding ASCII
Write-Output ("=== I3 PROBE WRITTEN === " + $L.Count + " lines")
