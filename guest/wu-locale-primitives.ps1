<#
.SYNOPSIS
  Which PowerShell primitives that this codebase relies on actually change behaviour by locale?

.DESCRIPTION
  The culture bug in wu-update.ps1 was invisible to every test because our only guest is English.
  Rather than reason about which APIs are culture-sensitive, measure them: force the culture
  in-process and compare each primitive's output against en-US. Anything that differs is a live
  hazard wherever the codebase uses it; anything identical can be used freely and does not need
  defensive code.

  Cultures chosen for what they break, not for coverage:
    th-TH  Buddhist era      - year 2569 instead of 2026
    ar-SA  UmAlQura (Hijri)  - different year AND Arabic-Indic digit shapes
    ja-JP  CJK               - code page 932, Japanese era calendar available
    zh-CN  CJK               - code page 936
    tr-TR  dotless i         - the classic case-insensitive comparison trap
    he-IL  RTL               - Hebrew calendar available, bidi text
    de-DE  comma decimal     - the one we already know breaks, kept as a positive control

  ASCII-ONLY source: non-ASCII test data is built from code points ([char]0x0660 etc), because a
  literal CJK character in this directory was mangled to '?a??a?' in transit and broke the parse.
#>
$ErrorActionPreference = 'Continue'
$cultures = 'en-US','de-DE','th-TH','ar-SA','ja-JP','zh-CN','tr-TR','he-IL'

# Fixed instant, so a differing output is the CALENDAR talking, never the clock.
$when = [datetime]::new(2026, 8, 14, 13, 5, 9, [DateTimeKind]::Utc)
$iso  = '2026-08-14T13:05:09'

function Probe {
    param($name, [scriptblock]$sb)
    $row = [ordered]@{ name = $name }
    foreach ($c in $cultures) {
        [Threading.Thread]::CurrentThread.CurrentCulture   = [Globalization.CultureInfo]::GetCultureInfo($c)
        [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($c)
        try { $row[$c] = [string](& $sb) } catch { $row[$c] = 'THREW: ' + $_.Exception.GetType().Name }
    }
    [Threading.Thread]::CurrentThread.CurrentCulture   = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    $row
}

$probes = @()
# --- dates: formatted for later PARSING, and parsed back -------------------------------------
$probes += Probe 'Get-Date -Format yyyy-MM-dd'        { $when.ToString('yyyy-MM-dd') }
$probes += Probe 'ToString(yyyy-MM-dd HH:mm:ss)'      { $when.ToString('yyyy-MM-dd HH:mm:ss') }
$probes += Probe 'ToString(o) round-trip'             { $when.ToString('o').Substring(0,19) }
$probes += Probe 'ToString() default'                 { $when.ToString() }
$probes += Probe 'TryParse(ISO) -> yyyy-MM-dd'        {
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($iso, [ref]$d)) { $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } else { 'PARSE FAILED' } }
$probes += Probe 'Get-Date -Format HH:mm:ss'          { $when.ToString('HH:mm:ss') }

# --- numbers: produced then parsed, or sent over the dom0 protocol ---------------------------
$probes += Probe '"{0:0.0}" -f 75.5   (protocol)'     { "{0:0.0}" -f 75.5 }
$probes += Probe 'InvariantCulture Format 75.5'       { [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.0}',75.5) }
$probes += Probe '(75.5).ToString()'                  { (75.5).ToString() }
$probes += Probe '[math]::Round(4867.44,1).ToString()' { [math]::Round(4867.44,1).ToString() }
$probes += Probe '"{0:N1}" -f 4867.4'                 { "{0:N1}" -f 4867.4 }
$probes += Probe 'string interpolation of 75.5'       { "$([double]75.5)" }
$probes += Probe '[double]"75.5" (cast)'              { ([double]'75.5').ToString([Globalization.CultureInfo]::InvariantCulture) }
$probes += Probe '[int]"42"'                          { ([int]'42').ToString([Globalization.CultureInfo]::InvariantCulture) }
$probes += Probe 'ConvertTo-Json number'              { (@{ v = 75.5 } | ConvertTo-Json -Compress) }

# --- regex and comparison --------------------------------------------------------------------
# Arabic-Indic digits, built from code points to keep this file ASCII.
$arabicDigits = -join (0x0660,0x0661,0x0662 | ForEach-Object { [char]$_ })
$probes += Probe 'regex \d matches Arabic-Indic'      { if ($arabicDigits -match '^\d+$') { 'MATCHES' } else { 'no match' } }
$probes += Probe 'regex \d matches ASCII 123'         { if ('123' -match '^\d+$') { 'MATCHES' } else { 'no match' } }
$probes += Probe '"KB5121003" -match "kb"'            { if ('KB5121003' -match 'kb') { 'MATCHES' } else { 'NO MATCH' } }
$probes += Probe '"WINDOWS11.0" -match "windows11"'   { if ('WINDOWS11.0' -match 'windows11') { 'MATCHES' } else { 'NO MATCH' } }
$probes += Probe '"Installed" -eq "INSTALLED"'        { if ('Installed' -eq 'INSTALLED') { 'EQUAL' } else { 'NOT EQUAL' } }
$probes += Probe '"file".ToUpper()'                   { 'file'.ToUpper() }
$probes += Probe '"I".ToLower()'                      { 'I'.ToLower() }
$probes += Probe 'sort of x64,arm64,X64'              { (('x64','arm64','X64') | Sort-Object) -join ',' }

# --- report: flag anything that differs from the en-US baseline -------------------------------
Write-Output '=== RESULT ==='
$hazards = 0
foreach ($p in $probes) {
    $base = $p['en-US']
    $diff = @($cultures | Where-Object { $_ -ne 'en-US' -and $p[$_] -ne $base })
    if ($diff.Count) {
        $hazards++
        Write-Output ("HAZARD  {0}" -f $p.name)
        Write-Output ("        en-US = '{0}'" -f $base)
        foreach ($c in $diff) { Write-Output ("        {0,-6}= '{1}'" -f $c, $p[$c]) }
    }
}
Write-Output '--- locale-stable (identical in every culture tested) ---'
foreach ($p in $probes) {
    $base = $p['en-US']
    if (-not @($cultures | Where-Object { $_ -ne 'en-US' -and $p[$_] -ne $base }).Count) {
        Write-Output ("  stable  {0,-38} = '{1}'" -f $p.name, $base)
    }
}
Write-Output ("hazard_count = {0} of {1} primitives" -f $hazards, $probes.Count)
