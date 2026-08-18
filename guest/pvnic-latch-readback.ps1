$ErrorActionPreference = 'SilentlyContinue'
$u = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug'
schtasks /query /tn QubesPvNic 2>$null | Out-Null; $t1 = ($LASTEXITCODE -eq 0)
schtasks /query /tn QubesPvNicRearm 2>$null | Out-Null; $t2 = ($LASTEXITCODE -eq 0)
Write-Output 'MARKJSON'
[pscustomobject]@{
    nics = $u.NICS
    disks = $u.DISKS
    vif_enum_key = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001&DEV_VIF')
    task_main = $t1; task_rearm = $t2
    payload_sha256 = (Get-FileHash 'C:\Program Files\Qubes Tools\bin\pvnic-boot.ps1' -Algorithm SHA256).Hash.ToLower()
    marker = (Test-Path 'C:\ProgramData\QubesPvNic-FAILED.txt')
    boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    log_tail = ((Get-Content 'C:\ProgramData\QubesPvNic.log' -Tail 6) -join ' // ')
} | ConvertTo-Json -Compress
