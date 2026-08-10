# Remedy probe for the NCSI/BITS gate (0x80200010). Tries, in order, to flip Windows'
# connectivity verdict to something BITS will accept, re-testing a direct BITS transfer after
# each. Assumes the proxy planes + relay are already set (run wu-diagnose.ps1 first).
$ErrorActionPreference = 'Continue'
$NLA = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
$cab = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }
function Conn { (Get-NetConnectionProfile -EA SilentlyContinue | ForEach-Object { "$($_.InterfaceAlias):$($_.IPv4Connectivity)" }) -join ',' }
function BitsTry {
    & bitsadmin /cancel wufix 2>&1 | Out-Null
    & bitsadmin /create wufix 2>&1 | Out-Null
    & bitsadmin /addfile wufix $cab 'C:\Users\Public\wufix.cab' 2>&1 | Out-Null
    & bitsadmin /setproxysettings wufix OVERRIDE '127.0.0.1:8082' 'NULL' 2>&1 | Out-Null
    & bitsadmin /setpriority wufix FOREGROUND 2>&1 | Out-Null
    & bitsadmin /resume wufix 2>&1 | Out-Null
    $st=''
    for ($i=0;$i -lt 8;$i++){ Start-Sleep -Seconds 2
        $info = & bitsadmin /info wufix /verbose 2>&1
        $st = (($info | Select-String 'STATE:') -join ' ')
        if ($st -match 'TRANSFERRED|ERROR') { break } }
    $b = (($info | Select-String 'BYTES:') -join ' ')
    $e = (($info | Select-String 'ERROR CODE:') -join ' ')
    & bitsadmin /cancel wufix 2>&1 | Out-Null
    Remove-Item 'C:\Users\Public\wufix.cab' -EA SilentlyContinue
    return ("state=[$st] bytes=[$b] err=[$e]").Trim()
}

$out = [ordered]@{}
$out.baseline_conn = Conn

# Attempt 1: just re-probe (NlaSvc restart) with the WinHTTP proxy already set - does NCSI
# honor the proxy on re-probe?
Restart-Service NlaSvc -Force -EA SilentlyContinue; Start-Sleep -Seconds 6
$out.after_reprobe_conn = Conn
$out.after_reprobe_bits = BitsTry

# Attempt 2: stop active probing entirely (no probe -> some builds stop marking NoTraffic).
SetV $NLA 'EnableActiveProbing' 0 'DWord'
Restart-Service NlaSvc -Force -EA SilentlyContinue; Start-Sleep -Seconds 6
$out.probing_off_conn = Conn
$out.probing_off_bits = BitsTry

# Attempt 3: point the NCSI probe at the host our proxy CAN reach, in case the probe honors
# the WinHTTP proxy but was caching the old default.
SetV $NLA 'EnableActiveProbing' 1 'DWord'
SetV $NLA 'ActiveWebProbeHost' 'www.msftconnecttest.com' 'String'
SetV $NLA 'ActiveWebProbePath' 'connecttest.txt' 'String'
SetV $NLA 'ActiveWebProbeContent' 'Microsoft Connect Test' 'String'
Restart-Service NlaSvc -Force -EA SilentlyContinue; Start-Sleep -Seconds 8
$out.probe_via_proxy_conn = Conn
$out.probe_via_proxy_bits = BitsTry

Write-Output ('=== WUFIX === ' + ($out | ConvertTo-Json -Compress))
