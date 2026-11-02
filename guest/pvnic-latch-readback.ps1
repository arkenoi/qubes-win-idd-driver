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
    # The payload's log moved into the one log directory (docs/ADR-logging.md, Decision 2026-11-01): its newest
    # per-day file there, the directory by log.ps1's rule (the registry LogDir, else <SystemDrive>\Qubes Logs),
    # and only on a guest with none of those the old C:\ProgramData\QubesPvNic.log. Below the hash line on
    # purpose: tools/lint-baseline.txt names that line by number.
    log_tail = $(
        $pvLogDir = $null
        try { $pvLogDir = Get-ItemPropertyValue 'HKLM:\Software\Invisible Things Lab\Qubes Tools' LogDir -ErrorAction Stop } catch { }
        if (-not $pvLogDir) { $pvLogDir = Join-Path $env:SystemDrive 'Qubes Logs' }
        $pvLog = 'C:\ProgramData\QubesPvNic.log'
        $pvNew = Get-ChildItem -LiteralPath $pvLogDir -Filter 'pvnic-boot.ps1-*.log' -EA SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($pvNew) { $pvLog = $pvNew.FullName }
        ((Get-Content -LiteralPath $pvLog -Tail 6) -join ' // ')
    )
} | ConvertTo-Json -Compress
