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
    # NULL-SAFE ON PURPOSE. `.Hash.ToLower()` on a MISSING applier throws, and that killed the
    # whole object: measured 2026-08-31 on a deliberately unseeded guest, this probe printed
    # MARKJSON and then nothing at all, so the check that exists to detect a missing applier
    # could only ever report INVALID-INSTRUMENT for it. A probe must be able to describe the
    # defect it was written to find.
    payload_sha256 = $(if (Test-Path 'C:\Program Files\Qubes Tools\bin\pvnic-boot.ps1') {
        (Get-FileHash 'C:\Program Files\Qubes Tools\bin\pvnic-boot.ps1' -Algorithm SHA256).Hash.ToLower()
    } else { $null })
    marker = (Test-Path 'C:\ProgramData\QubesPvNic-FAILED.txt')
    boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    log_tail = ((Get-Content 'C:\ProgramData\QubesPvNic.log' -Tail 6) -join ' // ')
} | ConvertTo-Json -Compress
