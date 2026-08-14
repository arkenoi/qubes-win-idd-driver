# Why did the staged cumulative not apply at boot?
#
# The pass staged TWO packages in one servicing session - KB5120710 (.NET) then KB5121003 (the OS
# cumulative) - with no reboot between them. After the reboot: KB5120710 is installed, KB5121003 is
# NOT, RebootPending is gone and the build did not move. So the first staged package applied and
# the second was discarded rather than rolled back loudly.
#
# This reads what CBS actually did, and what state each package is in, instead of inferring it.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output ("build = {0}.{1}" -f $cv.CurrentBuild, $cv.UBR)

# CBS package states for both KBs. 'CurrentState' 112 = Installed, 5 = Resolving/Staged, 0 = Absent.
$pkgRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
foreach ($kb in '5120710','5121003','5043080') {
    $hits = @(Get-ChildItem $pkgRoot -EA SilentlyContinue | Where-Object { $_.PSChildName -match $kb })
    Write-Output ("KB{0}: {1} CBS package entries" -f $kb, $hits.Count)
    foreach ($h in ($hits | Select-Object -First 3)) {
        $st = (Get-ItemProperty $h.PSPath -EA SilentlyContinue).CurrentState
        Write-Output ("   state={0}  {1}" -f $st, $h.PSChildName)
    }
}

# What the most recent CBS log says about the boot-time servicing.
$f = Get-ChildItem 'C:\Windows\Logs\CBS\*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($f) {
    Write-Output ("--- {0} (last write {1}) ---" -f $f.Name, $f.LastWriteTime.ToString('HH:mm:ss'))
    $pat = 'Rollback|rollback|0x8007|0x800f|abandon|Abandon|Failed to|error STATUS|Startup|Shutdown|Reboot mark'
    Get-Content $f.FullName -Tail 600 -EA SilentlyContinue |
        Where-Object { $_ -match $pat } |
        Select-Object -Last 12 |
        ForEach-Object { Write-Output ("   " + $_.Trim().Substring(0, [Math]::Min(160, $_.Trim().Length))) }
}
