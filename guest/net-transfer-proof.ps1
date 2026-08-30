# PROVE THE PV NIC CARRIES REAL TRAFFIC - by moving data, and by proving it crossed THAT adapter.
#
# WHY THIS EXISTS. "all drivers and network present" is an acceptance criterion, and the ways of
# checking it that feel obvious are all broken here:
#
#   * PINGING THE GATEWAY proves nothing. A Qubes netvm is a routing endpoint, not a host, and does
#     not answer ICMP - this reported "no traffic" on guests that were demonstrably online.
#   * "AN ADAPTER IS UP" proves nothing. A Microsoft KM-TEST Loopback Adapter reports
#     PhysicalAdapter=$true and will happily masquerade as both "a network is attached" and "the
#     adapter carrying traffic".
#   * "DNS RESOLVES" is a cheap smoke test, not proof of a working stack.
#
# Owner, 2026-08-29: "not ping the gw (not working), but file transfer (also checks if stack is
# sane)". So: fetch real bytes, and cross-check them against the PV adapter's OWN counter, because a
# transfer that succeeded over some other path would otherwise read as a PV NIC success.
#
# This was done once on 2026-08-29 (16 MB, RX delta 21,966,263) but only as ad-hoc commands, so the
# method died with that session and could not be re-run against a new package. Hence a script.
#
# Emits one '=== NETPROOF ===' JSON line. Exit 0 only if the bytes actually crossed the PV NIC.
[CmdletBinding()]
param(
    # 25 MB. Cloudflare's __down caps out below 100 MB (a 100 MB request returns 403 - measured),
    # and 25 MB is enough to dwarf background noise in the counter delta.
    [int]$Bytes = 25000000,
    [int]$SettleSeconds = 90        # H2 grading gate: measured inversion at +90 s
)
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

# --- 1. find the PV NIC by its DRIVER, never by name or "is it up" -------------------------
# XENVIF/XENNET is the PV path. Anything else - emulated Realtek, KM-TEST loopback - is exactly what
# this test must not be fooled by.
$pv = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
      Where-Object { $_.DriverFileName -match 'xennet|xenvif' -or $_.InterfaceDescription -match 'Xen' }
$loop = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'KM-TEST|Loopback' }
$emulated = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'Realtek|RTL|Intel\(R\) PRO' }

$r.pv_nic = if ($pv) { @($pv | ForEach-Object { $_.Name + ' [' + $_.InterfaceDescription + '] ' + $_.Status }) } else { @() }
$r.loopback_present = [bool]$loop
$r.emulated_left = if ($emulated) { @($emulated | ForEach-Object { $_.InterfaceDescription }) } else { @() }

if (-not $pv) {
    $r.ok = $false; $r.reason = 'no XENVIF/XENNET adapter present - the PV NIC never bound'
    Write-Output '=== NETPROOF ==='; Write-Output ($r | ConvertTo-Json -Compress); exit 1
}
$nic = @($pv)[0]
if ($nic.Status -ne 'Up') {
    $r.ok = $false; $r.reason = "PV NIC present but Status=$($nic.Status)"
    Write-Output '=== NETPROOF ==='; Write-Output ($r | ConvertTo-Json -Compress); exit 1
}

# --- 2. settle -----------------------------------------------------------------------------
# Measured 2026-08-29: the SAME guest read dns_resolves=False rx=153,487 immediately and
# dns_resolves=True rx=9,463,443 ninety seconds later. Grading early measures the boot, not the NIC.
Write-Output "settling $SettleSeconds s before grading (measured inversion at +90 s)"
Start-Sleep -Seconds $SettleSeconds

# --- 3. transfer, bracketed by the adapter's OWN counter -----------------------------------
$before = (Get-NetAdapterStatistics -Name $nic.Name -ErrorAction SilentlyContinue).ReceivedBytes
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$got = 0
try {
    $url = "https://speed.cloudflare.com/__down?bytes=$Bytes"
    $tmp = Join-Path $env:TEMP 'netproof.bin'
    Remove-Item $tmp -ErrorAction SilentlyContinue
    # TLS 1.2 explicitly: an older default silently fails on modern endpoints and looks like "no
    # network" rather than "handshake refused".
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
    $got = (Get-Item $tmp -ErrorAction SilentlyContinue).Length
    Remove-Item $tmp -ErrorAction SilentlyContinue
} catch {
    $r.transfer_error = $_.Exception.Message.Split([char]10)[0]
}
$sw.Stop()
$after = (Get-NetAdapterStatistics -Name $nic.Name -ErrorAction SilentlyContinue).ReceivedBytes

$r.bytes_requested = $Bytes
$r.bytes_received  = $got
$r.seconds         = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$r.pv_rx_before    = $before
$r.pv_rx_after     = $after
$r.pv_rx_delta     = $after - $before

# --- 4. verdict ----------------------------------------------------------------------------
# The delta must ACCOUNT FOR the transfer. If bytes arrived but this adapter's counter did not move,
# they came over something else and the PV NIC has proved nothing - which is the whole point of
# cross-checking rather than trusting the download alone.
$xferOk  = ($got -ge [math]::Floor($Bytes * 0.9))
$countOk = ($r.pv_rx_delta -ge [math]::Floor($got * 0.8))
$r.transfer_ok = $xferOk
$r.crossed_pv_nic = $countOk
$r.ok = ($xferOk -and $countOk)
if (-not $xferOk)       { $r.reason = 'transfer did not complete' }
elseif (-not $countOk)  { $r.reason = 'bytes arrived but NOT over the PV NIC (its RX counter barely moved)' }
else                    { $r.reason = 'bytes moved, and the PV adapter''s own counter accounts for them' }

Write-Output '=== NETPROOF ==='
Write-Output ($r | ConvertTo-Json -Compress)
if ($r.ok) { exit 0 } else { exit 1 }
