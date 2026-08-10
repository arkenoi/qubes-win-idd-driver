# Windows Update SCAN instrument (Stage 0, PLAN-updates-proxy.md).
# COM, not UsoClient: IUpdateSearcher.Search returns a concrete HRESULT and a count,
# so the check can actually FAIL visibly. UsoClient is fire-and-forget and cannot.
#
# Emits one === RESULT === JSON line (house pattern). Read the hresult:
#   0x00000000 (S_OK) with count>0  -> scan reached the update source (proxy working)
#   0x80240438 / 0x8024402C family  -> connectivity failure (the no-proxy baseline)
# The scan is deliberately ONLINE (ServerSelection = ssWindowsUpdate): a cached/offline
# source would let this pass with no network and void every later comparison.
$ErrorActionPreference = 'Stop'
$out = [ordered]@{ ok = $false; hresult = $null; hresult_hex = $null; count = $null; error = $null; seconds = $null }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    # Force the real Windows Update server, never WSUS/offline: this instrument must
    # exercise the network path we are proving out.
    $searcher.ServerSelection = 2   # ssWindowsUpdate
    $searcher.Online = $true
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $out.ok = $true
    $out.hresult = 0
    $out.hresult_hex = '0x00000000'
    $out.count = $result.Updates.Count
} catch {
    $hr = $null
    if ($_.Exception -and $_.Exception.InnerException) { $hr = $_.Exception.InnerException.HResult }
    if ($null -eq $hr -and $_.Exception) { $hr = $_.Exception.HResult }
    $out.hresult = $hr
    if ($null -ne $hr) { $out.hresult_hex = ('0x{0:X8}' -f ($hr -band 0xFFFFFFFF)) }
    $out.error = $_.Exception.Message
}
$sw.Stop()
$out.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress))
