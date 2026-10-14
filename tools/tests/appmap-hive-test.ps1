# appmap-hive-test.ps1 - does start-app.ps1 resolve the AppMap from the right hives, in the right
# order, and tell the two failure modes apart? Offline, no guest, no registry: the behaviour is read
# OUT of the script so the test cannot drift from the code it checks.
#
# APPMAPWRONGHIVE: dom0 syncs a template-based qube's app list in the TEMPLATE, writing HKCU there,
# while this handler runs in the APPVM against the appvm's own HKCU - which lives on the per-qube
# PRIVATE volume and can never be reached by a template sync. HKLM comes from the ROOT volume, which
# the appvm DOES inherit, so the mirror is what makes a template sync usable at all.
param([switch]$Defect)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\..\core-agent\src\qubes-rpc-services\start-app.ps1'
if (-not (Test-Path $src)) { Write-Output "FAIL  $src not found - nothing ran"; exit 2 }
$text = Get-Content -Raw $src
if ($Defect) { $text = $text -replace '\$RegistryMapPath,\s*\$RegistryMapPathMachine', '$RegistryMapPath' }

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { $script:pass++; Write-Output "  PASS  $name" }
    else       { $script:fail++; Write-Output "  FAIL  $name" }
}
Check 'the machine mirror path is defined'        ($text -match "RegistryMapPathMachine\s*=\s*'HKLM:")
Check 'both hives are searched'                   ($text -match '\$RegistryMapPath,\s*\$RegistryMapPathMachine')
Check 'HKCU is searched FIRST (own sync is freshest)' ($text -match 'foreach \(\$hive in @\(\$RegistryMapPath,')
Check 'the search stops at the first hit'         ($text -match '\$mapFrom = \$hive[\s\S]{0,40}break')
Check 'a missing entry is told apart from an empty one' (($text -match 'if \(-not \$mapHit\)') -and ($text -match 'if \(-not \$target\) \{ Fail'))
Check 'an EMPTY entry does not end the hive search'  ($text -match 'IsNullOrWhiteSpace\(\$v\)[\s\S]{0,60}continue')
Check 'an empty-only result is reported as empty'    ($text -match 'but it is EMPTY')
Check 'the failure names BOTH hives'              ($text -match 'either hive' -and $text -match 'RegistryMapPathMachine\\\$RegistryMapKey')
Check 'the failure names the remedy'              ($text -match 'qvm-sync-appmenus for THIS qube')
Check 'this handler never WRITES either hive'     (-not ($text -match '(Set|New)-ItemProperty[^\n]*RegistryMap'))
# THE SECOND CONSUMER. dom0 resolves ICONS through get-image-rgba, which read HKCU only. The first
# pass of this fix taught the launch path both hives and left the icon path on one, so a qube would
# have launched apps correctly and shown no icons. Found by listing every reader of the key.
$csrc = Join-Path $PSScriptRoot '..\..\core-agent\src\qubes-rpc-services\get-image-rgba\get-image-rgba.c'
if (-not (Test-Path $csrc)) { Write-Output "  FAIL  get-image-rgba.c not found"; $fail++ }
else {
    $c = Get-Content -Raw $csrc
    if ($Defect) { $c = $c -replace 'HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE', 'HKEY_CURRENT_USER' }
    Check 'icon lookup tries BOTH hives'            ($c -match 'HKEY_CURRENT_USER,\s*HKEY_LOCAL_MACHINE')
    Check 'icon lookup tries HKCU first'            ($c -match 'hives\[2\]\s*=\s*\{\s*HKEY_CURRENT_USER')
    Check 'an incomplete HKCU does not shadow HKLM' ($c -match 'RegCloseKey\(key\);[\s\S]{0,40}key = NULL;[\s\S]{0,20}\}')
    Check 'the size is reset per hive'              ($c -match 'size = linkPathLength \* sizeof\(WCHAR\); // buffer size, reset per hive')
}

Write-Output "RESULT: $pass passed, $fail failed"
exit $(if ($fail -gt 0) { 1 } else { 0 })
