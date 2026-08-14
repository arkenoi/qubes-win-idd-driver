# Does a non-ASCII argument survive the VMExec decoder?
#
# dom0's encode_for_vmexec percent-encodes the UTF-8 BYTES of each argument as -HH. The stock
# decoder resolves each escape with Encoding.ASCII, which maps every byte above 0x7F to '?', so a
# German umlaut, a Cyrillic letter or a CJK character is destroyed before cmd.exe sees it.
#
# Control included: the STOCK decoder must FAIL on the same input, or this proves nothing.
# ASCII-only source - test strings are built from code points.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
$stock = "$env:QUBES_TOOLS\qubes-rpc-services\VMExec-Decode.ps1"
if (Test-Path $stock) { . $stock } else { Write-Output 'stock decoder missing'; exit 1 }

# The fixed decoder, copied verbatim from guest/VMExec.ps1.
function VMExec-DecodeUtf8([string]$part) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $part.Length) {
        if ($part[$i] -eq '-') {
            if ($i + 1 -lt $part.Length -and $part[$i + 1] -eq '-') { $bytes.Add([byte][char]'-'); $i += 2; continue }
            if ($i + 2 -lt $part.Length) {
                $hex = [string]$part[$i + 1] + [string]$part[$i + 2]
                $val = 0
                if ([int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
                    $bytes.Add([byte]$val); $i += 3; continue
                }
            }
            throw "invalid escape"
        }
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes([string]$part[$i]))
        $i++
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

# Encode the way dom0 does: everything outside [A-Za-z0-9_.] becomes -HH per UTF-8 byte.
function Encode-LikeDom0([string]$s) {
    $out = ''
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($s)) {
        $c = [char]$b
        if ($c -match '[A-Za-z0-9_.]') { $out += $c } else { $out += ('-{0:X2}' -f $b) }
    }
    return $out
}

$cases = @(
    @{ n='ascii path';    s='C:\Users\user\Documents\file.txt' },
    @{ n='german umlaut'; s=('C:\Users\' + [char]0x00E4 + [char]0x00F6 + [char]0x00FC + '\datei.txt') },
    @{ n='cyrillic';      s=('C:\' + (-join (0x041F,0x0440,0x0438 | ForEach-Object { [char]$_ })) + '\f.txt') },
    @{ n='cjk';           s=('C:\' + (-join (0x66F4,0x65B0 | ForEach-Object { [char]$_ })) + '\f.txt') },
    @{ n='arabic';        s=('C:\' + (-join (0x0627,0x0644,0x062A | ForEach-Object { [char]$_ })) + '\f.txt') }
)

$stockOk = 0; $fixedOk = 0
foreach ($c in $cases) {
    $enc = Encode-LikeDom0 $c.s
    try { $viaStock = VMExec-Decode $enc } catch { $viaStock = 'THREW' }
    try { $viaFixed = VMExec-DecodeUtf8 $enc } catch { $viaFixed = 'THREW' }
    $sOk = ($viaStock -ceq $c.s); $fOk = ($viaFixed -ceq $c.s)
    if ($sOk) { $stockOk++ }
    if ($fOk) { $fixedOk++ }
    # Print code points, not glyphs - the console code page would lie about what came back.
    $cpFixed = (([int[]][char[]]$viaFixed) | ForEach-Object { '{0:X4}' -f $_ }) -join ' '
    $cpWant  = (([int[]][char[]]$c.s)      | ForEach-Object { '{0:X4}' -f $_ }) -join ' '
    Write-Output ("{0,-14} stock={1,-6} fixed={2,-6}" -f $c.n, $(if($sOk){'ok'}else{'MANGLED'}), $(if($fOk){'ok'}else{'MANGLED'}))
    if (-not $fOk) {
        Write-Output ("    wanted : " + $cpWant)
        Write-Output ("    got    : " + $cpFixed)
    }
}
Write-Output ("stock decoder correct: {0} of {1}   fixed decoder correct: {2} of {1}" -f $stockOk, $cases.Count, $fixedOk)
if ($stockOk -eq $cases.Count) { Write-Output 'INCONCLUSIVE: stock decoder handled everything - no defect to fix'; exit 2 }
if ($fixedOk -ne $cases.Count) { Write-Output 'FAIL: the fixed decoder still mangles input'; exit 1 }
Write-Output 'PASS: fixed decoder round-trips every case, and the stock one demonstrably does not'
