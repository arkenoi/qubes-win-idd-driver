# What did the update pass ACTUALLY change on this guest? (log lines are not evidence)
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}
$r.build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
            Select-Object -Property CurrentBuild, UBR, DisplayVersion)
$r.hotfixes = @(Get-HotFix -EA SilentlyContinue |
                Sort-Object InstalledOn -Descending |
                Select-Object -First 8 |
                ForEach-Object { "$($_.HotFixID) $($_.InstalledOn)" })
$r.pending_reboot = @{
    cbs    = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    wu     = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}
# what is sitting in the download cache (the pass installs whatever .msu it finds there)
$dl = 'C:\ProgramData\Qubes\updates'
$r.cache_dir = $dl
$r.cached_files = @(Get-ChildItem -LiteralPath $dl -Filter *.msu -EA SilentlyContinue |
                    ForEach-Object { "$($_.Name) $([math]::Round($_.Length/1MB,1))MB $($_.LastWriteTime.ToString('yyyy-MM-dd'))" })
$r.au_noautoupdate = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -EA SilentlyContinue).NoAutoUpdate
$r.workdir_exists = (Test-Path (Join-Path $env:SystemDrive 'run\qubes-update'))
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4 -Compress
