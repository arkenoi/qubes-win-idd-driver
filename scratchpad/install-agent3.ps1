# Install a gui-agent build by explicit source file + expected hash, stopping the running
# agent GRACEFULLY (Global\QGA_SHUTDOWN) instead of Stop-Process -Force.
#
# Verified semantics (FINDINGS 2026-08-04 cont, all file:line-cited):
# - Stopping QubesGuiWatchdog does NOT kill the agent; it only stops the respawner. So the
#   order is: stop watchdog (else it respawns the agent within 1 s of exit), then signal
#   the shutdown event, then wait for exit.
# - A graceful stop can stall indefinitely if gui-daemon died dirty with a full write ring
#   (VchanSendBuffer spins forever). Hence the bounded wait with a LOUD force-kill fallback:
#   the fallback leaks grants and loses the daemon, so it is reported in the result line and
#   the caller must treat FALLBACK=forced as a degraded install (reboot restores everything).
# - Copy over a running image silently fails; the hash check below is what actually protects
#   the "artefact under test is installed" rule.
param(
  [Parameter(Mandatory=$true)][string]$SrcName,   # file name in QubesIncoming, or 'ORIG'
  [Parameter(Mandatory=$true)][string]$ExpectHash, # first 16 hex chars of SHA256
  [int]$WaitExitSec = 20
)

$ErrorActionPreference = 'Stop'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$target   = Join-Path $bin 'gui-agent.exe'
$src      = if ($SrcName -eq 'ORIG') { Join-Path $bin 'gui-agent.exe.orig' } else { Join-Path $incoming $SrcName }

if (-not (Test-Path $src)) { Write-Output "INSTALL=FAIL reason=missing_source src=$SrcName"; exit 1 }
$srcHash = (Get-FileHash $src).Hash.Substring(0,16)
if ($srcHash -ne $ExpectHash) {
  Write-Output "INSTALL=FAIL reason=source_hash_mismatch src=$SrcName got=$srcHash want=$ExpectHash"; exit 1 }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Ev {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetEvent(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@

Stop-Service QubesGuiWatchdog -ErrorAction SilentlyContinue   # stops respawn only, agent keeps running
Start-Sleep -Seconds 1

$fallback = 'none'
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
if ($p) {
  $h = [Ev]::OpenEvent(0x0002, $false, 'Global\QGA_SHUTDOWN')   # EVENT_MODIFY_STATE
  if ($h -ne [IntPtr]::Zero) {
    [void][Ev]::SetEvent($h); [void][Ev]::CloseHandle($h)
    for ($i = 0; $i -lt $WaitExitSec; $i++) {
      Start-Sleep -Seconds 1
      if (-not (Get-Process gui-agent -ErrorAction SilentlyContinue)) { break }
    }
  } else { $fallback = 'openevent_failed' }
  if (Get-Process gui-agent -ErrorAction SilentlyContinue) {
    if ($fallback -eq 'none') { $fallback = 'forced_after_timeout' }
    Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
  } else { if ($fallback -eq 'none') { $fallback = '' } }
}
if ($fallback -eq '') { $fallback = 'graceful' } elseif ($fallback -eq 'none') { $fallback = 'not_running' }

try { Copy-Item $src $target -Force -ErrorAction Stop }
catch { Write-Output ("INSTALL=FAIL reason=copy_failed stop=$fallback msg=" + $_.Exception.Message); exit 1 }

$h2 = (Get-FileHash $target).Hash.Substring(0,16)
if ($h2 -ne $ExpectHash) { Write-Output "INSTALL=FAIL reason=hash_mismatch got=$h2 want=$ExpectHash"; exit 1 }
Write-Output "INSTALL=OK src=$SrcName hash=$h2 stop=$fallback"
