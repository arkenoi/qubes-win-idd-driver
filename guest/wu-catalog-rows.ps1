<#
.SYNOPSIS
  Why does the catalog's response language flip? Dump EVERY candidate row, repeatedly.

.DESCRIPTION
  Observed: the same KB, same guest, resolved with a German title at 09:54 and an English one at
  10:21; and asking for Accept-Language fr-FR returned an ITALIAN title. Something decides this and
  it is not our request. Two hypotheses, and they have very different consequences:

    H1  SERVER-SIDE LOCALE. One row per update; the backend renders its title in a language chosen
        per request/node. Consequence: cosmetic - the row identity (GUID) is stable.

    H2  ROW SET / ORDER. The search returns MANY rows for a KB, in assorted languages, and the
        order varies. Our picker takes the FIRST row passing its filters, so what flips is WHICH
        ROW WE PICK. Consequence: not cosmetic at all - rows can differ in product and edition, so
        a reorder could select a different package.

  Discriminator: GUIDs. If one GUID keeps changing its title, that is H1. If titles are attached to
  distinct GUIDs and the ORDER or MEMBERSHIP of the list moves between requests, that is H2.

  Dumps every row (GUID + title), repeatedly, and diffs the runs.
#>
param(
  [string]$Kb = 'KB5121003',
  [int]$Repeats = 4,
  # Also POST DownloadDialog per row and print the .msu filenames. Needed to answer whether a
  # "Dynamic Cumulative Update" row - which carries the SAME KB number as the real cumulative -
  # can be told apart by FILENAME, or only by asking DISM whether the package is applicable.
  [switch]$WithFiles,
  [string]$RelayExe = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$Proxy = 'http://127.0.0.1:8082',
  [string]$WorkDir = 'C:\ProgramData\Qubes\wu'
)
$ErrorActionPreference = 'Continue'
$out = Join-Path $WorkDir 'catalog-rows.txt'
New-Item -ItemType Directory -Force $WorkDir | Out-Null
Remove-Item -LiteralPath $out -Force -EA SilentlyContinue

$worker = @"
`$ErrorActionPreference = 'Continue'
function W(`$m){ Add-Content -LiteralPath '$out' -Value `$m }

# proxy up (same way the agent does it)
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
`$IS = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path `$IS -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path `$IS -Name ProxyServer -Value '127.0.0.1:8082'
if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    Start-Process -FilePath '$RelayExe' -ArgumentList '--listen','8082','--target','@default','--log','$WorkDir' -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

`$rx = [regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
`$runs = @()
for (`$i = 1; `$i -le $Repeats; `$i++) {
    try {
        `$r = Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$Kb" -Proxy '$Proxy' -UseBasicParsing -TimeoutSec 60
    } catch { W ("run `$i FAILED: " + `$_.Exception.Message); continue }
    W ("=== run `$i ===")
    foreach (`$h in 'Server','Set-Cookie','X-Powered-By','Date') {
        if (`$r.Headers[`$h]) { W ("  hdr " + `$h + ": " + (`$r.Headers[`$h] -join '; ')) }
    }
    `$rows = @()
    foreach (`$m in `$rx.Matches(`$r.Content)) {
        `$t = (`$m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
        `$rows += [pscustomobject]@{ guid = `$m.Groups[1].Value; title = `$t }
    }
    W ("  rows = " + `$rows.Count)
    `$n = 0
    foreach (`$row in `$rows) {
        `$n++
        W ("  [" + `$n + "] " + `$row.guid + "  " + `$row.title)
        if (`$$WithFiles -and `$i -eq 1) {
            `$json = '[{"size":0,"languages":"","uidInfo":"' + `$row.guid + '","updateID":"' + `$row.guid + '"}]'
            try {
                `$dl = Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=`$json} -Proxy '$Proxy' -UseBasicParsing -TimeoutSec 60
                `$fs = @([regex]::Matches(`$dl.Content,"url\s*=\s*'(http[^']+)'") | ForEach-Object { `$_.Groups[1].Value } | Sort-Object -Unique)
                if (-not `$fs.Count) { W ("        (no files)") }
                foreach (`$u in `$fs) {
                    `$nm = if (`$u -match '/([^/?]+)`$') { `$Matches[1] } else { `$u }
                    W ("        file: " + `$nm)
                }
            } catch { W ("        (download dialog failed: " + `$_.Exception.Message + ")") }
            Start-Sleep -Seconds 2
        }
    }
    `$runs += ,@(`$rows)
    Start-Sleep -Seconds 4
}

W '=== ANALYSIS ==='
if (`$runs.Count -ge 2) {
    # H1 vs H2: does a given GUID keep its title across runs?
    `$titlesByGuid = @{}
    foreach (`$run in `$runs) {
        foreach (`$row in `$run) {
            if (-not `$titlesByGuid.ContainsKey(`$row.guid)) { `$titlesByGuid[`$row.guid] = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]`$titlesByGuid[`$row.guid].Add(`$row.title)
        }
    }
    `$unstable = @(`$titlesByGuid.Keys | Where-Object { `$titlesByGuid[`$_].Count -gt 1 })
    W ("distinct GUIDs seen        = " + `$titlesByGuid.Count)
    W ("GUIDs whose TITLE changed  = " + `$unstable.Count + "   (>0 => H1 server-side locale)")
    foreach (`$g in (`$unstable | Select-Object -First 5)) {
        W ("  " + `$g)
        foreach (`$t in `$titlesByGuid[`$g]) { W ("      " + `$t) }
    }
    # order / membership stability
    `$sigs = @(`$runs | ForEach-Object { ((`$_ | ForEach-Object { `$_.guid }) -join ',') })
    `$distinctOrder = @(`$sigs | Sort-Object -Unique)
    W ("distinct ROW ORDERS across runs = " + `$distinctOrder.Count + "   (>1 => H2 order flips)")
    `$sets = @(`$runs | ForEach-Object { ((`$_ | ForEach-Object { `$_.guid } | Sort-Object) -join ',') })
    W ("distinct ROW SETS across runs   = " + @(`$sets | Sort-Object -Unique).Count + "   (>1 => membership changes)")
    # how many languages are present WITHIN a single response?
    `$first = `$runs[0]
    `$langish = @(`$first | Where-Object { `$_.title -notmatch 'Cumulative Update|Update for' })
    W ("rows in run 1 whose title is NOT English-looking = " + `$langish.Count + " of " + `$first.Count)
}

& netsh winhttp reset proxy | Out-Null
Set-ItemProperty -Path `$IS -Name ProxyEnable -Value 0 -Type DWord
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { `$_.Kill() }
W 'DONE'
"@
$wp = Join-Path $WorkDir 'catalog-rows-worker.ps1'
Set-Content -LiteralPath $wp -Value $worker -Encoding ASCII

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG research: catalog row set/order/language stability</Description></RegistrationInfo>
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
$f = Join-Path $env:TEMP 'wu-catalog-rows.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
& schtasks /create /tn QwtCatalogRows /xml "$f" /f | Out-Null
& schtasks /run /tn QwtCatalogRows | Out-Null
Write-Output ("=== RESULT ===`narmed for {0} x{1} (rc {2}); poll {3}" -f $Kb, $Repeats, $LASTEXITCODE, $out)
