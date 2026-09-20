# wu-appx-carve-test.ps1 - offline proof for Get-EmbeddedAppx, the carve that lets the updater
# service a vendor installer which is really a CONTAINER (securityhealthsetup.exe exits 0 in under
# a second and does nothing on a routeless guest, while the .appx packages inside it provision in
# eleven seconds).
#
# It EXTRACTS the marked region of the shipped script, so what is tested is the code that ships.
# The fixture is built here - two ordinary (non-ZIP64) packages embedded in a blob with junk around
# and between them - which is deliberately the case the first version of this code MISSED: it keyed
# only on the ZIP64 end-of-central-directory, so an ordinary-sized embedded package was skipped and
# "found nothing" was indistinguishable from "there was nothing".
#
# The ZIP64 half is proven against the real 22 MB installer, not here: measured 2026-09-21, the
# shipped code carves all three of its members with the right identities, and with the
# `0xFFFFFFFF` literal restored (PowerShell parses it as Int32 -1) it finds ZERO.
#
#   -Defect zip64only   re-introduce "only ZIP64 archives are recognised"; the suite MUST then fail
param([string]$Defect = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src  = Get-Content -Raw (Join-Path $root 'guest/qubes-windows-update.ps1')
$m = [regex]::Match($src, "# ---- WU-APPX-CARVE-BEGIN(.*?)# ---- WU-APPX-CARVE-END", 'Singleline')
if (-not $m.Success) { Write-Output "INSTRUMENT: WU-APPX-CARVE region not found"; exit 2 }
$region = $m.Groups[1].Value
switch ($Defect) {
    'zip64only' { $region = $region.Replace('$start = [int64]$i - [int64]$cdsize - [int64]$cdoff', '$start = -1') }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown -Defect '$Defect' (zip64only)"; exit 2 }
}
Invoke-Expression $region

$pass = 0; $fail = 0
function Check($what, $got, $want) {
    if ("$got" -eq "$want") { Write-Output "  PASS  $what"; $script:pass++ }
    else { Write-Output "  FAIL  $what (got '$got', want '$want')"; $script:fail++ }
}

# ---- fixture: two synthetic packages, one framework and one main that depends on it
Add-Type -AssemblyName System.IO.Compression.FileSystem
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("carve-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force $tmp | Out-Null
function New-Appx($name, $ver, $isFramework) {
    $d = Join-Path $tmp ("src-" + $name); New-Item -ItemType Directory -Force $d | Out-Null
    $props = if ($isFramework) { "<Properties><Framework>true</Framework></Properties>" } else { "<Properties></Properties>" }
    @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$name" Version="$ver" ProcessorArchitecture="x64" />
  $props
</Package>
"@ | Set-Content -LiteralPath (Join-Path $d 'AppxManifest.xml') -Encoding UTF8
    'payload' | Set-Content -LiteralPath (Join-Path $d 'data.bin')
    $z = Join-Path $tmp ($name + ".zip")
    [IO.Compression.ZipFile]::CreateFromDirectory($d, $z)
    return $z
}
$a = New-Appx 'Contoso.MainApp' '1000.29628.1000.0' $false
$b = New-Appx 'Contoso.Framework' '14.0.33519.0' $true
$blob = Join-Path $tmp 'container.exe'
$fs = [IO.File]::Create($blob)
$junk = New-Object byte[] 4096; (New-Object Random 42).NextBytes($junk)
$fs.Write($junk, 0, $junk.Length)
foreach ($z in @($a, $b)) {
    $d = [IO.File]::ReadAllBytes($z); $fs.Write($d, 0, $d.Length)
    $fs.Write($junk, 0, 512)
}
$fs.Close()

$outDir = Join-Path $tmp 'carved'
$res = Get-EmbeddedAppx -ExePath $blob -OutDir $outDir
$res = @($res)
Check "both embedded packages are found in an ordinary (non-ZIP64) container" $res.Count 2
$main = @($res | Where-Object { $_.Name -eq 'Contoso.MainApp' })
$fw   = @($res | Where-Object { $_.Name -eq 'Contoso.Framework' })
Check "the main package is identified BY ITS MANIFEST, not by filename" $main.Count 1
Check "its version comes from the manifest too" (@($main)[0].Version) '1000.29628.1000.0'
Check "the framework package is found as well" $fw.Count 1
Check "each carved file is a readable archive" (@($res | Where-Object {
    try { $z = [IO.Compression.ZipFile]::OpenRead($_.Path); $n = $z.Entries.Count; $z.Dispose(); $n -gt 0 } catch { $false } }).Count) 2

Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
Write-Output "checks: $pass passed, $fail failed"
if ($fail -eq 0) { exit 0 } else { exit 1 }
