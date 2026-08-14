# Do bidi marks in an update TITLE break anything, and is a CJK/Arabic title survivable as data?
#
# This needs no Arabic Windows: bidi marks and CJK text are DATA, not UI language. Arabic and
# Hebrew update titles carry invisible LRM/RLM marks (U+200E/U+200F), and those titles are
#   * used as hash keys by wu-update.ps1's Msg() de-duplication,
#   * concatenated into messages sent to dom0 over stderr,
#   * written into update-status.json and read back by another process.
# A mark that survives one hop but not another produces the duplicate-message bug we already hit
# once with a last-value-only de-dup check.
#
# ASCII-ONLY SOURCE: every non-ASCII string here is built from code points, because a literal was
# mangled in transit and broke a parse.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='

$LRM = [char]0x200E; $RLM = [char]0x200F
$arabic = -join (0x0627,0x0644,0x062A,0x062D,0x062F,0x064A,0x062B | ForEach-Object { [char]$_ })
$hebrew = -join (0x05E2,0x05D3,0x05DB,0x05D5,0x05DF | ForEach-Object { [char]$_ })
$cjk    = -join (0x66F4,0x65B0,0x7A0B,0x5E8F | ForEach-Object { [char]$_ })

$titles = @(
    @{ n='ascii';        s='2026-08 Cumulative Update (KB5121003)' },
    @{ n='arabic+RLM';   s=("$RLM$arabic (KB5121003)") },
    @{ n='hebrew+LRM';   s=("$LRM$hebrew (KB5121003)") },
    @{ n='cjk';          s=("$cjk (KB5121003)") },
    @{ n='ascii+hidden'; s=("2026-08 Cumulative Update$LRM (KB5121003)") }
)

# 1. Hashtable key identity - the de-dup mechanism. Two titles differing ONLY by an invisible mark
#    must NOT collide, and the same title must always hit the same key.
$h = @{}
foreach ($t in $titles) { $h[$t.s] = 1 + [int]$h[$t.s] }
Write-Output ("distinct hash keys = {0} of {1} titles  (expect {1}: an invisible mark must not merge rows)" -f $h.Count, $titles.Count)
$plain = '2026-08 Cumulative Update (KB5121003)'
$withMark = "2026-08 Cumulative Update$LRM (KB5121003)"
Write-Output ("plain -eq with-hidden-mark : {0}  (expect False - they are different strings)" -f ($plain -eq $withMark))

# 2. The KB extraction the whole pipeline depends on must still work through bidi/CJK.
foreach ($t in $titles) {
    $kb = if ($t.s -match '(KB\d{6,7})') { $Matches[1] } else { 'NO MATCH' }
    $digits = $t.s -replace '\D',''
    Write-Output ("{0,-12} len={1,-3} kb={2,-12} digits='{3}'" -f $t.n, $t.s.Length, $kb, $digits)
}

# 3. JSON round trip - written by the agent, read by the handler.
$tmp = Join-Path $env:TEMP 'bidi-roundtrip.json'
$obj = [ordered]@{ available = @($titles | ForEach-Object { @{ kb='KB5121003'; title=$_.s } }) }
($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
$back = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
$ok = 0; $bad = 0
for ($i = 0; $i -lt $titles.Count; $i++) {
    if ($back.available[$i].title -ceq $titles[$i].s) { $ok++ } else {
        $bad++
        Write-Output ("  ROUNDTRIP CHANGED: {0}  in-len={1} out-len={2}" -f $titles[$i].n, $titles[$i].s.Length, $back.available[$i].title.Length)
    }
}
Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
Write-Output ("json round trip byte-identical: {0} ok, {1} changed" -f $ok, $bad)

# 4. What dom0 would do with such a message: it must NOT parse as a float, or the title would be
#    swallowed as a progress value instead of shown.
foreach ($t in $titles) {
    $lastToken = ($t.s -split '\s+')[-1]
    $d = 0.0
    $isNum = [double]::TryParse($lastToken, [ref]$d)
    if ($isNum) { Write-Output ("  WARNING {0}: last token '{1}' parses as a number - dom0 would eat it as progress" -f $t.n, $lastToken) }
}
Write-Output 'checked: last token of every title is non-numeric'
