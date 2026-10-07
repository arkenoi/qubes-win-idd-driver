# guest/relay-own.ps1 - the updates relay OWNED BY HANDLE, for the dev/test scripts that start one.
# NOT SHIPPED (packaging/make-setup.ps1 stages named files only). Dot-source next to the script
# that was pushed with it:   . "$PSScriptRoot\relay-own.ps1"
#
# WHY. The updater test scripts used to free port 8082 with `Get-Process qubes-updates-relay |
# Stop-Process` / `.Kill()` or by killing the port's owning pid - ANY relay, whoever started it,
# including the one a running updater pass owns (and that pass's task relaunches it). Owner
# 2026-10-07: nothing is killed by name, and nothing ends what it did not start. This mirrors the
# SHIPPED shape (guest/qubes-windows-update.ps1 Get-RelayPortOwner / Start-Relay / Stop-OwnRelay,
# docs/ADR-updater.md 12.4): the port's owner is read first and a port that is not free is a
# REFUSAL naming the owner - never adopted, never killed; the relay THIS script starts is the only
# one it stops, by the handle it kept; --parent-pid makes the relay leave with the script anyway.

function Get-RelayPortOwner([int]$Port = 8082) {
  # Who LISTENS on 127.0.0.1:<port>: the owning pid, 0 when nobody does, -1 when the table cannot be
  # read (UNKNOWN IS NOT ZERO). Found by the PORT, identified by its PID - never by a process name.
  $ev = @()
  try { $l = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue -ErrorVariable ev) } catch { return -1 }
  if ($l.Count -gt 0) { return [int]$l[0].OwningProcess }
  foreach ($e in $ev) { if ("$($e.CategoryInfo.Category)" -ne 'ObjectNotFound') { return -1 } }
  return 0
}

function Format-RelayRefusal([int]$Owner, [int]$Port = 8082) {
  if ($Owner -lt 0) { return "REFUSED: cannot read who listens on 127.0.0.1:$Port (Get-NetTCPConnection failed), so the port cannot be shown free - this script never adopts a relay it did not start; nothing was started" }
  $who = ''
  try { $op = Get-Process -Id $Owner -ErrorAction SilentlyContinue; if ($op) { $who = " ($($op.ProcessName), started $($op.StartTime.ToString('s')))" } } catch { }
  return "REFUSED: 127.0.0.1:$Port is already served by pid $Owner$who, which this script did not start - a running updater pass owns its relay and its task relaunches it; end that pass (schtasks /end /tn QubesWindowsUpdateScan or QubesWindowsUpdateRun) or wait for it. It was NOT killed; nothing was started"
}

function Start-OwnRelay {
  # Starts the relay by handle, ONLY when the port is free, and proves the listener is ours.
  # Throws the refusal text otherwise. The handle, pid and start time are the only identity
  # Stop-OwnRelay ever acts on.
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [int]$Port = 8082, [int]$SettleSec = 2)
  if (-not (Test-Path -LiteralPath $Exe)) { throw "relay not found at $Exe" }
  $owner = Get-RelayPortOwner $Port
  if ($owner -ne 0) { throw (Format-RelayRefusal $owner $Port) }
  $args2 = @($Arguments)
  if ($args2 -notcontains '--parent-pid') { $args2 += @('--parent-pid', "$PID") }
  $p = Start-Process -FilePath $Exe -ArgumentList $args2 -WindowStyle Hidden -PassThru
  $script:OwnRelay = $p
  $script:OwnRelayPid = 0
  $script:OwnRelayStart = ''
  if ($p) { $script:OwnRelayPid = [int]$p.Id; try { $script:OwnRelayStart = $p.StartTime.ToString('s') } catch { } }
  Start-Sleep -Seconds $SettleSec
  $owner = Get-RelayPortOwner $Port
  if ($owner -ne $script:OwnRelayPid) {
    Stop-OwnRelay
    throw ("REFUSED: after the start, 127.0.0.1:$Port is served by pid $owner, not the relay this script started (pid $($script:OwnRelayPid)) - never adopted; ours was stopped")
  }
  return $p
}

function Stop-OwnRelay {
  # Stops exactly the relay THIS script started, by the handle Start-OwnRelay kept - never by name,
  # never by port. Every outcome is reported; a relay this script did not start is never touched.
  $p = $script:OwnRelay
  if (-not $p) { Write-Output 'relay: this script holds no relay handle - nothing of ours to stop (a relay it did not start is never touched)'; return }
  $script:OwnRelay = $null
  $id = $script:OwnRelayPid
  try {
    if ($p.HasExited) { Write-Output ("relay pid {0} had already exited (exit code {1}) - nothing to stop" -f $id, $p.ExitCode); return }
    $p.Kill()
    if ($p.WaitForExit(10000)) { Write-Output ("relay pid {0} stopped by this script (exit code {1})" -f $id, $p.ExitCode) }
    else { Write-Output ("ANOMALY: relay pid {0} did not exit within 10 s of being stopped by this script" -f $id) }
  } catch { Write-Output ("ANOMALY: relay pid {0} NOT stopped: {1}" -f $id, $_.Exception.Message) }
}

function Wait-RelayPortFree([int]$Port = 8082, [int]$TimeoutSec = 20) {
  # For a relay SOMEONE ELSE owns (an updater pass): wait for it to leave the port, never end it.
  # $true when the port is free inside the bound; $false (and the owner is the caller's to report).
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    if ((Get-RelayPortOwner $Port) -eq 0) { return $true }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return ((Get-RelayPortOwner $Port) -eq 0)
}
