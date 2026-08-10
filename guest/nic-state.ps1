# Network-interface + connectivity-status instrument (Stage 0, PLAN-updates-proxy.md).
# Proves the guest has NO network adapter and that NLM/NCSI report no connectivity -
# the structural "general networking is impossible" precondition, and the exact state
# under which Stage 1 asks whether wuauserv will still dial a loopback proxy.
# Emits one === RESULT === JSON line.
$ErrorActionPreference = 'Continue'
$out = [ordered]@{
    adapters_up = $null; adapters_all = $null; adapter_names = @()
    nlm_connected = $null; nlm_internet = $null; ncsi_state = $null; error = $null
}
try {
    $ad = @(Get-NetAdapter -ErrorAction Stop)
    $out.adapters_all = $ad.Count
    $out.adapters_up = @($ad | Where-Object { $_.Status -eq 'Up' }).Count
    $out.adapter_names = @($ad | ForEach-Object { "$($_.Name):$($_.Status)" })
} catch {
    # No Net* cmdlets, or none present - fall back to a raw count.
    $out.error = "Get-NetAdapter: $($_.Exception.Message)"
    try { $out.adapters_all = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()).Count } catch {}
}
try {
    # INetworkListManager (CLSID DCB00C01-570F-4A9B-8D69-199FDBA5723B): the same
    # connectivity oracle wuauserv/DO consult.
    $nlm = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'))
} catch { $nlm = $null }
if ($nlm) {
    try { $out.nlm_connected = [bool]$nlm.IsConnected } catch {}
    try { $out.nlm_internet  = [bool]$nlm.IsConnectedToInternet } catch {}
}
try {
    $ncsi = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' -ErrorAction SilentlyContinue
    if ($ncsi) { $out.ncsi_state = "probe=$($ncsi.EnableActiveProbing)" }
} catch {}
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress))
