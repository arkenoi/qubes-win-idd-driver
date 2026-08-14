# Prove the DEPLOYED stack is the one we think it is, by hash - not by assertion.
#
# The reproduction of a "known-working configuration" is worth nothing if the artifacts on disk
# differ from the ones intended. This hashes every file the updater path actually loads and prints
# it, so the caller can compare against the expected hashes computed in the repo.
#
# Note the relay is COMPILED on-guest, so its .exe cannot be compared to a source hash; we hash the
# .cs that was pushed (the compiler input) and record the .exe's size/timestamp separately.
$ErrorActionPreference = 'Continue'
$bin = 'C:\Program Files\Qubes Tools\bin'
$rpc = 'C:\Program Files\Qubes Tools\qubes-rpc-services'
Write-Output '=== RESULT ==='
$targets = [ordered]@{
    'qubes-windows-update.ps1' = Join-Path $bin 'qubes-windows-update.ps1'
    'wu-update.ps1'            = Join-Path $rpc 'wu-update.ps1'
    'vmupdate-shim.ps1'        = Join-Path $rpc 'vmupdate-shim.ps1'
    'ensure-autologon.ps1'     = Join-Path $rpc 'ensure-autologon.ps1'
    'VMExec.ps1'               = Join-Path $rpc 'VMExec.ps1'
}
foreach ($k in $targets.Keys) {
    $p = $targets[$k]
    if (Test-Path -LiteralPath $p) {
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower().Substring(0,16)
        $len = (Get-Item -LiteralPath $p).Length
        Write-Output ("{0,-28} {1}  {2,7} bytes" -f $k, $h, $len)
    } else {
        Write-Output ("{0,-28} MISSING at {1}" -f $k, $p)
    }
}
$exe = Join-Path $bin 'qubes-updates-relay.exe'
if (Test-Path $exe) {
    $i = Get-Item $exe
    Write-Output ("qubes-updates-relay.exe      compiled {0}  {1} bytes" -f $i.LastWriteTime.ToString('HH:mm:ss'), $i.Length)
}
# The compiler INPUT is what we can compare to the repo.
$src = Get-ChildItem 'C:\Users\user\Documents\QubesIncoming' -Recurse -Filter 'qubes-updates-relay.cs' -EA SilentlyContinue | Select-Object -First 1
if ($src) {
    $h = (Get-FileHash -LiteralPath $src.FullName -Algorithm SHA256).Hash.ToLower().Substring(0,16)
    Write-Output ("qubes-updates-relay.cs       {0}  {1,7} bytes  (compiler input)" -f $h, $src.Length)
}
# Anything of ours that should NOT be present in a clean reproduction.
foreach ($stray in 'proxy-probe.exe','relay-pre.exe') {
    $p = Join-Path 'C:\ProgramData\Qubes\wu' $stray
    if (Test-Path $p) { Write-Output ("STRAY PRESENT: {0} (diagnostic left over - not part of the stack)" -f $stray) }
}
