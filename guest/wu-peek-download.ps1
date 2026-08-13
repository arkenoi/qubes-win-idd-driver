# What did we actually receive for a .msu that failed the CAB-magic check? Prints the first
# bytes as text and hex, plus the size, for every .msu under the update work dir.
$ErrorActionPreference = 'Continue'
$root = 'C:\ProgramData\Qubes\wu'
foreach ($f in Get-ChildItem -Path $root -Filter *.msu -Recurse -EA SilentlyContinue) {
    Write-Output "--- $($f.FullName) ($($f.Length) bytes) ---"
    try {
        $fs = [IO.File]::OpenRead($f.FullName)
        $buf = New-Object byte[] 220
        $n = $fs.Read($buf, 0, $buf.Length)
        $fs.Close()
        $hex = ($buf[0..7] | ForEach-Object { $_.ToString('X2') }) -join ' '
        $txt = ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -replace '[^\x20-\x7E]', '.')
        Write-Output "  first8hex: $hex"
        Write-Output "  as text  : $txt"
    } catch { Write-Output "  unreadable: $($_.Exception.Message)" }
}
Write-Output '=== RESULT === done'
