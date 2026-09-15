#!/bin/bash
# private-disk-gate-guest-test.sh - exercise the private-disk gate on a REAL Windows guest.
#
# The offline selftest proves the CLASSIFIER against synthetic tables. It cannot prove the three
# things that only a live Windows can: that Get-Disk/Update-HostStorageCache behave as assumed under
# SYSTEM PowerShell 5.1, that MSFT_StorageEvent can actually be subscribed to, and that the wait
# loop / deadline / finally path runs end to end. A fix verified on synthetic input alone is the
# procedure failure the owner called out on 2026-09-14 - so this runs the gate's real code on a
# real guest before it is allowed to gate an install.
#
# NON-DESTRUCTIVE. It formats nothing and changes no disk. Refusal branches are exercised by
# handing the classifier the REAL disk table with forced -QPresent/serial-list parameters, and the
# wait/deadline paths by shadowing the classifier with a forced-state stub AFTER the real one is
# loaded (a later PowerShell function definition wins). Fail is stubbed to throw, so the try/finally
# unregister path is exercised instead of the process exiting.
#
#   VM=win10-acc tools/tests/private-disk-gate-guest-test.sh
# Needs: the guest Halted-or-Running with QWT installed (Q: present) and qrexec answering.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${VM:?set VM to a guest carrying QWT with qrexec answering}"
SRC=packaging/setup/Install-QwtImproved.ps1
OUT="${OUT:-scratchpad/gate-guest-test/$VM-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }

# ---- assemble the guest script from the WORKING TREE code -----------------------------------
grep -q QWT-GATE-BEGIN "$SRC" && grep -q QWT-GATE-END "$SRC" || { say "FATAL: gate markers missing"; exit 2; }
{
  cat <<'HDR'
$ErrorActionPreference = 'Continue'
$script:Result = @{ detail = @{} }
function Write-Log { param([string]$m, [string]$lvl = 'INFO') Write-Host "GATELOG[$lvl] $m" }
function Fail { param([string]$m) Write-Host "GATETEST FAIL-CALLED: $($m.Substring(0, [Math]::Min(160, $m.Length)))"; throw "QWTFAIL" }
HDR
  awk '/QWT-GATE-BEGIN/{f=1;next} /QWT-GATE-END/{f=0} f' "$SRC"
  # function-boundary extraction: from the gate's definition up to (not including) the next function
  awk '/^function Wait-PrivateDiskReady/{f=1} /^function Wait-WindowsInstallerIdle/{f=0} f' "$SRC"
  cat <<'BODY'
$pass = 0; $fail = 0
function T([string]$name, [bool]$ok, [string]$detail) { if ($ok) { $script:pass++; Write-Host "GATETEST PASS  $name  ($detail)" } else { $script:fail++; Write-Host "GATETEST FAIL  $name  ($detail)" } }
function Elapsed([scriptblock]$b) { $t = [Diagnostics.Stopwatch]::StartNew(); $r = & $b; $t.Stop(); ,@($r, [int]$t.Elapsed.TotalSeconds) }

# T0 environment facts the gate assumes
T 'Update-HostStorageCache exists' ([bool](Get-Command Update-HostStorageCache -ErrorAction SilentlyContinue)) "PS $($PSVersionTable.PSVersion)"
$real = @(Get-Disk -ErrorAction SilentlyContinue)
T 'Get-Disk returns a table' ($real.Count -gt 0) "$($real.Count) disks"
foreach ($d in ($real | Sort-Object Number)) { Write-Host ("GATETEST TABLE #{0} '{1}' {2}GB style={3} sn='{4}'" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size/1GB,1), $d.PartitionStyle, $d.SerialNumber) }

# T1 the real gate on this guest (Q: present) must return fast on READY-Q-PRESENT, no subscription
$r = Elapsed { Wait-PrivateDiskReady -TimeoutSec 20 }
T 'real gate: Q: present -> returns $true fast' (($r[0] -eq $true) -and ($r[1] -le 5)) "t=$($r[1])s detail='$($script:Result.detail.private_disk_gate)'"
T 'real gate: state is READY-Q-PRESENT' ("$($script:Result.detail.private_disk_gate)" -like 'READY-Q-PRESENT*') "$($script:Result.detail.private_disk_gate)"
T 'real gate: left no event subscriber behind' (@(Get-EventSubscriber -ErrorAction SilentlyContinue).Count -eq 0) "subscribers=$(@(Get-EventSubscriber -ErrorAction SilentlyContinue).Count)"

# T2-T4 refusal branches on the REAL table, with Q: forced absent
$c = Classify-PrivateDiskState -Disks $real -QPresent $false
T 'real table, Q: forced absent -> NONRAW-AT-1 (private is GPT now)' ($c.state -eq 'NONRAW-AT-1') "$($c.state): $($c.why)"
$c = Classify-PrivateDiskState -Disks $real -QPresent $false -PrivateSerials @('QM00003','0002') -VolatileSerials @('QM00002','0001')
T 'real table, roles swapped -> VOLATILE-AT-1 refusal' ($c.state -eq 'VOLATILE-AT-1') "$($c.state)"
$c = Classify-PrivateDiskState -Disks $real -QPresent $false -PrivateSerials @('NOPE') -VolatileSerials @('NOPE2')
T 'real table, unknown serial scheme + non-RAW #1 -> NOT-READY (would wait, then deadline-fail)' ($c.state -eq 'NOT-READY') "$($c.state)"

# T5 the event mechanism itself
$subOk = $false; $waitNull = $false; $err = ''
try {
  Register-CimIndicationEvent -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_StorageEvent' -SourceIdentifier 'GateProbe' -ErrorAction Stop | Out-Null
  $subOk = $true
  $ev = Wait-Event -SourceIdentifier 'GateProbe' -Timeout 3
  $waitNull = ($null -eq $ev)
} catch { $err = $_.Exception.Message } finally { Unregister-Event -SourceIdentifier 'GateProbe' -ErrorAction SilentlyContinue; Get-Event -SourceIdentifier 'GateProbe' -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue }
T 'MSFT_StorageEvent subscription succeeds under this context' $subOk "err='$err'"
T 'Wait-Event -Timeout returns $null on timeout without throwing' $waitNull ''

# T6 the wait loop end to end: shadow the classifier - NOT-READY twice, then READY
$script:n = 0
function Classify-PrivateDiskState { param($Disks, $QPresent, $StockNames, $PrivateSerials, $VolatileSerials) $script:n++; if ($script:n -lt 3) { @{ state = 'NOT-READY'; why = 'forced by test' } } else { @{ state = 'READY'; why = 'forced by test' } } }
$script:Result.detail.Remove('private_disk_gate')
$r = Elapsed { Wait-PrivateDiskReady -TimeoutSec 60 }
T 'wait loop: NOT-READY x2 then READY -> returns $true after ~10s' (($r[0] -eq $true) -and ($r[1] -ge 8) -and ($r[1] -le 25)) "t=$($r[1])s detail='$($script:Result.detail.private_disk_gate)'"
T 'wait loop: subscribed (event-driven path taken)' ("$($script:Result.detail.private_disk_gate)" -match 'checks=3') "$($script:Result.detail.private_disk_gate)"
T 'wait loop: unregistered on exit' (@(Get-EventSubscriber -ErrorAction SilentlyContinue).Count -eq 0) ''

# T7 the deadline path: always NOT-READY, 8 s deadline -> Fail called, table dumped, finally ran
function Classify-PrivateDiskState { param($Disks, $QPresent, $StockNames, $PrivateSerials, $VolatileSerials) @{ state = 'NOT-READY'; why = 'forced never-ready' } }
$script:Result.detail.Remove('private_disk_gate')
$failed = $false; $r = Elapsed { try { Wait-PrivateDiskReady -TimeoutSec 8 } catch { if ("$_" -match 'QWTFAIL') { $script:failed = $true } } }
T 'deadline: Fail is called (not a silent return)' $failed "t=$($r[1])s"
T 'deadline: detail records FAIL NOT-READY' ("$($script:Result.detail.private_disk_gate)" -like 'FAIL NOT-READY*') "$($script:Result.detail.private_disk_gate)"
T 'deadline: finally unregistered the subscriber' (@(Get-EventSubscriber -ErrorAction SilentlyContinue).Count -eq 0) ''

Write-Host "GATETEST === $pass passed, $fail failed ==="
BODY
} > "$OUT/gate-guest-test.ps1"
say "assembled $OUT/gate-guest-test.ps1 ($(wc -l < "$OUT/gate-guest-test.ps1") lines)"

# ---- ship and run as SYSTEM over qubes.VMShell ------------------------------------------------
INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)
QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push "$OUT/gate-guest-test.ps1" >/dev/null 2>&1 || { say "FATAL: push failed"; exit 1; }
QTEST_VM=$VM timeout -k 10 400 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\gate-guest-test.ps1\"" 2>/dev/null \
  | tr -d '\r' | tee "$OUT/guest.out" | grep -aE '^GATETEST|^GATELOG\[WARN\]|DISKGATE\['
echo
p=$(grep -aoE 'GATETEST === [0-9]+ passed, [0-9]+ failed' "$OUT/guest.out" | tail -1)
say "result: ${p:-NO SUMMARY LINE - the script did not complete (see $OUT/guest.out)}"
[ -n "$p" ] && [[ "$p" == *", 0 failed" ]]
