# Is ToString('s') calendar-invariant?
#
# It matters because qubes-windows-update.ps1:81 stamps the status file with
# (Get-Date).ToString('s'), and wu-update.ps1:90 parses that back and compares it against
# $script:StartedAt to drop stale lines. Those two run in DIFFERENT PROCESSES - the agent as a
# SYSTEM scheduled task, the handler as the logged-on user - so they can carry different cultures.
# If 's' takes the year from the culture's calendar, a th-TH or ar-SA guest writes a year the other
# side reads differently, and the freshness guard either drops every line (dom0 sees no progress
# and no messages) or accepts stale ones.
#
# The docs say the 's' PATTERN is culture-independent. The pattern is not the question - the
# CALENDAR supplying the year is. Measure it.
$ErrorActionPreference = 'Continue'
$when = [datetime]::new(2026, 8, 14, 13, 5, 9)
Write-Output '=== RESULT ==='
$base = $null
foreach ($c in 'en-US','de-DE','th-TH','ar-SA','ja-JP','he-IL') {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($c)
    $s   = $when.ToString('s')
    $o   = $when.ToString('o').Substring(0,19)
    $inv = $when.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
    # Round-trip the way the handler does it, in THIS culture.
    $d = [datetime]::MinValue
    $rt = if ([datetime]::TryParse($s, [ref]$d)) { $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } else { 'PARSE FAILED' }
    if (-not $base) { $base = $s }
    Write-Output ("{0,-6} ToString('s')='{1}'  invariant='{2}'  'o'='{3}'  parsed-back={4}" -f $c, $s, $inv, $o, $rt)
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

# The cross-process case that actually bites: written under one culture, read under another.
Write-Output '--- cross-culture round trip (agent SYSTEM culture -> handler user culture) ---'
foreach ($w in 'en-US','th-TH','ar-SA') {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($w)
    $written = $when.ToString('s')
    foreach ($r in 'en-US','th-TH','ar-SA') {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($r)
        $d = [datetime]::MinValue
        $ok = [datetime]::TryParse($written, [ref]$d)
        $got = if ($ok) { $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } else { 'PARSE FAILED' }
        $verdict = if ($got -eq '2026-08-14') { 'ok' } else { 'WRONG' }
        Write-Output ("  write {0,-6} -> read {1,-6} : '{2}' -> {3}  {4}" -f $w, $r, $written, $got, $verdict)
    }
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
