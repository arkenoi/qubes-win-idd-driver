# After a commit boot: did the updates the pass claimed actually land, and does a fresh scan
# still offer them? Also pulls the DISM verdict for any package that failed.
$ErrorActionPreference = 'Continue'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output "build: $($cv.CurrentBuild).$($cv.UBR) $($cv.DisplayVersion)"

$log = 'C:\ProgramData\Qubes\wu\dism.log'
if (Test-Path $log) {
    Write-Output '--- last DISM errors ---'
    Get-Content $log -Tail 4000 |
        Where-Object { $_ -match 'Error|0x8|failed' } |
        Select-Object -Last 8 |
        ForEach-Object { Write-Output ("  " + $_.Trim()) }
}

Write-Output '--- fresh scan (scan-only, installs nothing) ---'
& 'C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1' -Action scan 2>&1 |
    Select-String -Pattern 'scan:|available|proxy' | ForEach-Object { Write-Output ("  " + $_.Line) }

$st = Get-Content 'C:\ProgramData\Qubes\update-status.json' -Raw -EA SilentlyContinue | ConvertFrom-Json
Write-Output "=== RESULT ==="
Write-Output ("count=" + $st.count + " kbs=" + (@($st.available | ForEach-Object { $_.kb }) -join ','))
