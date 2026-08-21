# U6, last cell: a StandaloneVM WITH DIRECT INTERNET.
#
# The branch under test (qubes-windows-update.ps1): a StandaloneVM that can reach the internet
# updates ITSELF through Windows Update, so the qubes proxy updater must disable itself AND undo the
# NoAutoUpdate=1 policy it would otherwise leave behind - otherwise the guest would sit with Windows
# Update switched off and no proxy driving it, i.e. never updated by anyone.
#
# Asserted here:
#   1. the classifier reports StandaloneVM
#   2. Test-DirectInternet actually finds a route (otherwise this measures the OFFLINE branch and
#      proves nothing about this one - the failure mode that makes a cell look covered when it is not)
#   3. NoAutoUpdate is REMOVED
#   4. still no proxy acquired and no relay started
# Restores NoAutoUpdate afterwards so the guest goes back to the dom0-owned-updates posture.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\standalone-online.txt'
$agent='C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1'
$au='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$tmp='C:\ProgramData\Qubes\sa-online'; New-Item -ItemType Directory -Force $tmp | Out-Null
$r=[ordered]@{}
$r['host']=$env:COMPUTERNAME
$r['agent_hash16']=(Get-FileHash $agent -Algorithm SHA256).Hash.Substring(0,16)

# does this guest ACTUALLY have a route? same probes the updater uses
$reach=$false
foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt','http://www.msn.com/') {
  try {
    $req=[System.Net.HttpWebRequest]::Create($u); $req.Timeout=15000; $req.Proxy=$null
    $resp=$req.GetResponse(); if ([int]$resp.StatusCode -ge 200) { $reach=$true }; $resp.Close()
  } catch {}
  if ($reach) { break }
}
$r['direct_internet_reachable']=$reach

# make the thing we expect to be removed definitely present first
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
$r['NoAutoUpdate_before']=(Get-ItemProperty -Path $au -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate

$IS='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$r['proxy_before']=(Get-ItemProperty $IS -EA SilentlyContinue).ProxyServer
$st=Join-Path $tmp 'status.json'; Remove-Item $st -Force -EA SilentlyContinue
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agent -Action scan `
    -StatusFile $st -WorkDir (Join-Path $tmp 'wu') 2>&1 | Out-Null
$r['exit_code']=$LASTEXITCODE
if (Test-Path $st) { $r['phase']=(Get-Content $st -Raw | ConvertFrom-Json).phase } else { $r['phase']='(none)' }

$r['NoAutoUpdate_after']=(Get-ItemProperty -Path $au -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate
$r['noautoupdate_removed']=($null -eq $r['NoAutoUpdate_after'])
$r['proxy_after']=(Get-ItemProperty $IS -EA SilentlyContinue).ProxyServer
$r['proxy_unchanged']=($r['proxy_before'] -eq $r['proxy_after'])
$r['no_relay_started']=(-not [bool](Get-Process qubes-updates-relay -EA SilentlyContinue))
$lg=Join-Path $tmp 'wu\agent.log'
if (Test-Path $lg) {
  $m=Select-String -Path $lg -Pattern 'VM class \(live from qubesdb\)|StandaloneVM' -EA SilentlyContinue | Select-Object -Last 3
  $r['log_lines']=(@($m | ForEach-Object { $_.Line.Trim() }) -join ' || ')
}
$r['took_direct_internet_branch']=[bool]($r['log_lines'] -match 'direct internet')
$r['ok']=($r['exit_code'] -eq 0) -and $reach -and $r['noautoupdate_removed'] `
         -and $r['took_direct_internet_branch'] -and $r['proxy_unchanged'] -and $r['no_relay_started']

# restore the dom0-owned-updates posture
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
$r['NoAutoUpdate_restored']=(Get-ItemProperty -Path $au -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate
($r | ConvertTo-Json -Compress) | Out-File -LiteralPath $out -Encoding ASCII
Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress))
