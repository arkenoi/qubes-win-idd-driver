<#
.SYNOPSIS
  Does catalog resolution pick the SAME package file when the catalog answers in another language?

.DESCRIPTION
  A real user runs a German edition of Windows, and the catalog's response language is not under
  our control - it has been measured varying on its own (same KB, same guest, German at 09:54 and
  English at 10:21). Resolution picks a row by matching TEXT in the title, so the question "does a
  German response still resolve to the right file" is a correctness question, not a cosmetic one.

  No German Windows image exists, and one is not needed for this: the catalog's language is chosen
  by the Accept-Language header, so an ENGLISH guest can ask for German titles and check the parse.

  THE INVARIANT: the chosen .msu FILENAME must be identical across response languages. Titles are
  allowed to differ - filenames are not. A mismatch means the picker is steering by localized text
  and would install a different package for GWeck than for an English user; a resolution FAILURE
  under one language means updates silently do nothing there.

  Runs the agent's OWN Resolve-Catalog through -Action resolve, so this tests the shipping code
  path rather than a copy of it that can drift.
#>
param(
  [string]$Kb = 'KB5121003',
  [string[]]$Languages = @('en-US', 'de-DE', 'fr-FR', 'ja-JP')
)
$ErrorActionPreference = 'Continue'
$bin   = 'C:\Program Files\Qubes Tools\bin'
$agent = Join-Path $bin 'qubes-windows-update.ps1'
$relay = Join-Path $bin 'qubes-updates-relay.exe'
$wu    = 'C:\ProgramData\Qubes\wu'
$out   = Join-Path $wu 'locale-invariant.txt'
New-Item -ItemType Directory -Force $wu | Out-Null
Remove-Item -LiteralPath $out -Force -EA SilentlyContinue

$langList = ($Languages | ForEach-Object { "'$_'" }) -join ','
$worker = @"
`$ErrorActionPreference = 'Continue'
function W(`$m){ Add-Content -LiteralPath '$out' -Value `$m }
`$results = @{}
foreach (`$lang in @($langList)) {
    W ("=== Accept-Language: " + `$lang + " ===")
    `$o = & '$agent' -Action resolve -OnlyKb '$Kb' -RelayExe '$relay' -AcceptLanguage `$lang *>&1
    `$files = @()
    foreach (`$l in `$o) {
        `$t = "`$l"
        if (`$t -match 'catalog pick:\s*(.+)$')  { W ("  title : " + `$Matches[1].Trim()) }
        if (`$t -match '(KEEP|DROP)\s+(\S+\.msu)') { `$files += (`$Matches[1] + ' ' + `$Matches[2]) }
        if (`$t -match 'no catalog entry matches') { W ("  RESOLUTION FAILED: " + `$t.Trim()) }
    }
    foreach (`$f in `$files) { W ("  file  : " + `$f) }
    `$results[`$lang] = (`$files | Sort-Object) -join '|'
    Start-Sleep -Seconds 3
}
W '=== VERDICT ==='
`$distinct = @(`$results.Values | Sort-Object -Unique)
`$empty    = @(`$results.Keys | Where-Object { -not `$results[`$_] })
foreach (`$k in (`$results.Keys | Sort-Object)) { W ("  " + `$k + " -> " + `$(if(`$results[`$k]){`$results[`$k]}else{'(nothing resolved)'})) }
if (`$empty.Count -gt 0) {
    W ("FAIL: resolution produced NO file for: " + (`$empty -join ', '))
} elseif (`$distinct.Count -eq 1) {
    W 'PASS: every response language resolved to the identical package file(s)'
} else {
    W ("FAIL: response language changes the chosen file - " + `$distinct.Count + " distinct outcomes")
}
W 'DONE'
"@
$wp = Join-Path $wu 'locale-invariant-worker.ps1'
Set-Content -LiteralPath $wp -Value $worker -Encoding ASCII

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: catalog resolution must be language-invariant</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$wp"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'wu-locale-invariant.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
& schtasks /create /tn QwtLocaleInvariant /xml "$f" /f | Out-Null
& schtasks /run /tn QwtLocaleInvariant | Out-Null
Write-Output ("=== RESULT ===`narmed for {0} across {1} (rc {2}); poll {3}" -f $Kb, ($Languages -join ','), $LASTEXITCODE, $out)
