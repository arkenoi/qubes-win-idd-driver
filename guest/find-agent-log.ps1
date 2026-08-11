# Locate the gui-agent log directory/files on this guest.
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}
$r.qt_dirs = @(Get-ChildItem 'C:\Program Files\Qubes Tools' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$cands = @(
    'C:\Program Files\Qubes Tools\log',
    'C:\ProgramData\Qubes',
    'C:\ProgramData\Invisible Things Lab',
    "$env:ProgramData\Qubes Tools",
    'C:\Windows\Temp'
)
$r.log_files = @()
foreach ($d in $cands) {
    if (Test-Path $d) {
        $r.log_files += @(Get-ChildItem $d -Recurse -Filter '*gui-agent*' -ErrorAction SilentlyContinue |
            Select-Object -First 20 | ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTime.ToString('o'))" })
    }
}
# Registry may say where logs go
$reg = Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
$r.reg_qtools = if ($reg) { $reg | Select-Object -Property * -ExcludeProperty PS* | ConvertTo-Json -Compress } else { $null }
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4
