# Swap qrexec-wrapper.exe, WITH A DEAD-MAN ROLLBACK.
#
# Every qrexec call into this guest runs through this binary. If the replacement is bad, the guest
# stops answering qrexec entirely and cannot be repaired from outside - the exact "unmanageable
# qube" state this project has already hit once. So the swap arms a scheduled task that restores the
# backup a few minutes from now unless it is explicitly cancelled after the new binary is proven to
# work. Failure mode of the SAFETY NET itself is "the old binary comes back", which is safe.
#
# -Revert restores the backup immediately. -Confirm cancels the pending rollback (call it only after
# qrexec has been shown to still work with the new binary).
param(
  [string]$New = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\qrexec-wrapper.exe',
  [int]$RollbackMinutes = 8,
  [switch]$Revert,
  [switch]$Confirm
)
$ErrorActionPreference = 'Continue'
$dst  = 'C:\Program Files\Qubes Tools\bin\qrexec-wrapper.exe'
$bak  = "$dst.orig"
$task = 'QwtWrapperRollback'
$r = [ordered]@{}

function H($p) { if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0,16) } else { 'none' } }

if ($Confirm) {
  & schtasks /delete /tn $task /f 2>&1 | Out-Null
  $r['rollback_cancelled'] = -not [bool](Get-ScheduledTask -TaskName $task -EA SilentlyContinue)
  $r['in_place'] = H $dst
  Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress)); exit 0
}

if ($Revert) {
  if (Test-Path $bak) { Copy-Item -LiteralPath $bak -Destination $dst -Force }
  & schtasks /delete /tn $task /f 2>&1 | Out-Null
  $r['reverted_to'] = H $dst
  Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress)); exit 0
}

if (-not (Test-Path $New)) { $r['error'] = "new wrapper not pushed: $New"; $r['ok'] = $false
  Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress)); exit 1 }

$r['before'] = H $dst
$r['new']    = H $New
if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $dst -Destination $bak -Force; $r['backup_made'] = $true }
else { $r['backup_made'] = 'already existed (kept)' }
$r['backup'] = H $bak

# Arm the dead-man BEFORE touching the live binary, so a swap that kills qrexec still gets undone.
$when = (Get-Date).AddMinutes($RollbackMinutes).ToString('HH:mm')
$cmd  = "cmd /c copy /y \`"$bak\`" \`"$dst\`""
& schtasks /create /tn $task /f /sc once /st $when /ru SYSTEM /rl HIGHEST /tr $cmd 2>&1 | Out-Null
$r['rollback_armed_for'] = $when
$r['rollback_task'] = [bool](Get-ScheduledTask -TaskName $task -EA SilentlyContinue)

# qrexec-wrapper is spawned per call, not held open, so it can be replaced in place.
Copy-Item -LiteralPath $New -Destination $dst -Force -EA SilentlyContinue
$r['after'] = H $dst
$r['swapped'] = ($r['after'] -eq $r['new'])
$r['ok'] = ($r['swapped'] -and $r['rollback_task'])
Write-Output ("=== RESULT === " + ($r | ConvertTo-Json -Compress))
