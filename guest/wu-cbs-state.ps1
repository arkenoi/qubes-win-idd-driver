# What does a PENDING servicing transaction actually look like, versus a healthy image?
#
# The assumption being tested: my earlier guard used Test-Path on
# ...\Component Based Servicing\SessionsPending and called it "dirty". But that KEY exists on
# healthy Windows and is normally EMPTY - so the guard would refuse to run on any image at all.
# Existence of the key is not evidence of anything; its CONTENTS are.
$ErrorActionPreference = 'Continue'
$cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
Write-Output '=== RESULT ==='

foreach ($sub in 'SessionsPending', 'RebootPending', 'PackagesPending') {
    $p = Join-Path $cbs $sub
    $exists = Test-Path $p
    $vals = @(); $keys = @()
    if ($exists) {
        $item = Get-Item $p -ErrorAction SilentlyContinue
        if ($item) {
            $vals = @($item.GetValueNames() | Where-Object { $_ -ne '' })
            $keys = @($item.GetSubKeyNames())
        }
    }
    Write-Output ("{0,-16} exists={1,-5} values={2} subkeys={3}" -f $sub, $exists, $vals.Count, $keys.Count)
    foreach ($v in ($vals | Select-Object -First 5)) {
        Write-Output ("      value: {0} = {1}" -f $v, (Get-ItemProperty $p -Name $v -EA SilentlyContinue).$v)
    }
    foreach ($k in ($keys | Select-Object -First 5)) { Write-Output ("      subkey: {0}" -f $k) }
}

Write-Output ("winsxs_pending_xml = {0}" -f (Test-Path 'C:\Windows\WinSxS\pending.xml'))
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output ("build = {0}.{1}" -f $cv.CurrentBuild, $cv.UBR)

# The authoritative answer, which is what we should have been asking all along.
$dism = & DISM /Online /Cleanup-Image /CheckHealth /English 2>&1
Write-Output '--- DISM /CheckHealth ---'
foreach ($l in ($dism | Where-Object { $_ -match '\S' } | Select-Object -Last 6)) { Write-Output ("   " + $l.Trim()) }
