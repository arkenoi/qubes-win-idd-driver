<#
.SYNOPSIS
  Tests two claims: (a) most of the skipped payload is language packages, (b) the byte overhead is
  therefore far below the 55.7% package-count overhead.

.DESCRIPTION
  Part 1 - from the CBS install log, split the packages CBS walked past (Absent) and the ones it
  applied (Installed) by whether they carry a language tag (~xx-XX~). That settles (a) exactly.

  Part 2 - the log cannot give bytes, so measure a PROXY from the component store instead: the
  on-disk size of language-tagged WinSxS components versus neutral ones. If language components are
  small, then a payload dominated by them is far cheaper in bytes than in package count, and the
  "2x" reading is wrong.

  This is a measured proxy, not the real byte split of the .msu - WinSxS holds EXPANDED files while
  the payload is compressed, and it only holds what was INSTALLED. It bounds the argument; it does
  not replace expanding the ESD. Labelled as such in the output.
#>
param([string]$Path = '')
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
$log = $Path
if (-not $log) {
    $c = @(Get-ChildItem 'C:\Windows\Logs\CBS\*.log' -EA SilentlyContinue | Sort-Object Length -Descending)
    if ($c.Count) { $log = $c[0].FullName }
}

# ---- Part 1: is the skipped payload mostly language packages? -------------------------------
$absent = New-Object 'System.Collections.Generic.HashSet[string]'
$inst   = New-Object 'System.Collections.Generic.HashSet[string]'
if ($log -and (Test-Path $log)) {
    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object IO.StreamReader($fs)
    while ($null -ne ($l = $sr.ReadLine())) {
        if ($l -notmatch 'applicable state') { continue }
        if ($l -match 'Evaluating package applicability for package ([^,]+), applicable state:\s*(\w+)') {
            if ($Matches[2] -eq 'Absent') { [void]$absent.Add($Matches[1].Trim()) }
            else { [void]$inst.Add($Matches[1].Trim()) }
        }
    }
    $sr.Close(); $fs.Close()
}
function LangSplit($set, $label) {
    $lang = 0; $neutral = 0
    foreach ($p in $set) { if ($p -match '~[a-z]{2}-[A-Z]{2}~') { $lang++ } else { $neutral++ } }
    $tot = $lang + $neutral
    if ($tot -eq 0) { Write-Output ("{0}: none" -f $label); return }
    Write-Output ("{0,-28} total={1,6:N0}  language-tagged={2,6:N0} ({3,5:N1}%)  neutral={4,6:N0}" -f `
        $label, $tot, $lang, (100*$lang/$tot), $neutral)
}
LangSplit $absent 'packages WALKED PAST (Absent)'
LangSplit $inst   'packages APPLIED (Installed)'

# ---- Part 1b: what KIND of package was rejected? --------------------------------------------
# Rules are ordered, first match wins. Raw name families are printed afterwards so the buckets can
# be checked against the actual data instead of taken on trust.
function Categorize($p) {
    if ($p -match 'LanguageFeatures-(Basic|Handwriting|OCR|Speech|TextToSpeech)') { return 'LanguageFeatures FoD (handwriting/OCR/speech)' }
    if ($p -match 'LanguagePack|-LanguagePack~|Client-LanguagePack')              { return 'Language pack (UI translation)' }
    if ($p -match 'FoD-Package|FeaturesOnDemand|-FoD~')                            { return 'Feature on Demand (tools/roles)' }
    if ($p -match 'OptionalFeature|Client-Features|-Feature-Package')              { return 'Optional Windows feature' }
    if ($p -match 'Edition~|Edition-|EditionSpecific|ServerCore|Enterprise|Education|ProfessionalN') { return 'Other Windows edition' }
    if ($p -match 'Printing|Print-')                                               { return 'Printing components' }
    if ($p -match 'Hyper-V|Containers|WSL|Subsystem')                              { return 'Virtualisation / subsystems' }
    if ($p -match 'Font|Typography')                                               { return 'Fonts' }
    if ($p -match 'Wrapper')                                                       { return 'Package wrapper (metadata shell)' }
    return 'Other component'
}
$cat = @{}
foreach ($p in $absent) { $c = Categorize $p; $cat[$c] = 1 + [int]$cat[$c] }
Write-Output '--- REJECTED packages by category ---'
foreach ($k in ($cat.Keys | Sort-Object { -$cat[$_] })) {
    Write-Output ("  {0,-46} {1,6:N0}  ({2,5:N1}%)" -f $k, $cat[$k], (100*$cat[$k]/[math]::Max($absent.Count,1)))
}

# Raw evidence for the buckets above: the most common name families among rejected packages.
$fam = @{}
foreach ($p in $absent) {
    $n = $p -replace '~.*$', ''          # strip ~publisher~arch~lang~version
    $n = $n -replace '-Package(-Wrapper)?$', ''
    $fam[$n] = 1 + [int]$fam[$n]
}
Write-Output '--- most common REJECTED package families (raw, for checking the buckets) ---'
foreach ($k in ($fam.Keys | Sort-Object { -$fam[$_] } | Select-Object -First 20)) {
    Write-Output ("  {0,6:N0}  {1}" -f $fam[$k], $k)
}

# ---- Part 2: are language components actually small? ----------------------------------------
# WinSxS component dirs are named like amd64_microsoft-windows-foo_31bf..._10.0.26100.9168_en-us_hash
# Group by whether the name carries a locale, and compare sizes. PROXY - expanded, installed-only.
Write-Output '--- WinSxS component sizes: language-tagged vs neutral (PROXY: expanded + installed only) ---'
$langBytes = [int64]0; $langDirs = 0
$neutBytes = [int64]0; $neutDirs = 0
foreach ($d in (Get-ChildItem 'C:\Windows\WinSxS' -Directory -Force -EA SilentlyContinue)) {
    $n = $d.Name
    if ($n -in 'Manifests','Catalogs','FileMaps','Temp','Backup','InstallTemp','ManifestCache') { continue }
    $sz = (Get-ChildItem $d.FullName -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $sz) { $sz = 0 }
    if ($n -match '_[a-z]{2}-[a-z]{2}_') { $langBytes += $sz; $langDirs++ }
    else { $neutBytes += $sz; $neutDirs++ }
}
if ($langDirs) {
    Write-Output ("language components : {0,7:N0} dirs  {1,9:N2} GB  mean {2,8:N0} KB" -f `
        $langDirs, ($langBytes/1GB), ($langBytes/$langDirs/1KB))
}
if ($neutDirs) {
    Write-Output ("neutral components  : {0,7:N0} dirs  {1,9:N2} GB  mean {2,8:N0} KB" -f `
        $neutDirs, ($neutBytes/1GB), ($neutBytes/$neutDirs/1KB))
}
if ($langDirs -and $neutDirs) {
    Write-Output ("mean size ratio language:neutral = 1 : {0:N1}" -f (($neutBytes/$neutDirs)/($langBytes/$langDirs)))
}
