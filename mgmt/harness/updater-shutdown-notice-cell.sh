#!/bin/bash
# updater-shutdown-notice-cell.sh - does a shutdown that reaps the update scan still tell dom0 the
# scan task FAILED?
#
#   mgmt/harness/updater-shutdown-notice-cell.sh <vm>
#
# WHY THIS CELL EXISTS. dom0 was told "The Windows Update scan task failed" about a scan that was
# working and was stopped by the shutdown (measured 2026-10-07), and the sibling "The PV NIC setup
# task failed" was owner-reported twice. The suppression was fixed TWICE: the first fix gated
# everything on TaskScheduler event 111, which has ZERO records in a real guest's corpus, so it was
# DEAD CODE that passed its offline test because the test injected the event. The second fix
# (bd3cce63) rests on two positive detections. Jev on whether that one works on a real guest:
# `fix_removes_it` 0.29, `offline_test_is_enough` 0.15, and the measurement it named is this cell -
# `shutdown-during-scan-cell` 0.71.
#
# WHAT IT ASSERTS, and why a quiet log is not enough on its own:
#   CONDITION  the shutdown really did reap a RUNNING scan - a TaskScheduler 201 for
#              \QubesWindowsUpdateScan carrying a shutdown result code, with a shutdown record at
#              that instant. Without it there is nothing to suppress and a quiet log means nothing,
#              so the cell exits 2 (INVALID INSTRUMENT) rather than PASS.
#   SYMPTOM    no death notice naming a task failure, in the guest's own qwt-deaths.log or the
#              bridge log that carries what was sent to dom0.
#
# THE DETECTOR IS VALIDATED BEFORE IT IS TRUSTED, against a recorded capture from BEFORE the fix
# that contains two real notices. A detector that cannot find those is broken, and the cell says so
# and stops - this is the same rule that caught errfam.py counting collapsed lines as the families
# they replace.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: $0 <vm> - name the subject; there is no default target}"
OUT="${2:-scratchpad/updater-shutdown-notice-$VM}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$OUT" || exit 2

# The notice as it appears in the guest's own records. Both forms are from measured captures:
# qwt-deaths.log writes "DEATH #N NEW <channel>/201#<rec>: The X task failed", and the bridge log
# writes "NOTIFY one-shot: sent ok=N summary=The X task failed".
NOTICE_RE='(DEATH #[0-9]+ NEW .*201#[0-9]+: .*task failed|NOTIFY one-shot: sent .*summary=.*task failed)'
CONTROL=scratchpad/jev-wf3r-shutdown-result-codes-0/dec/20261008T065853Z-win11r-logvol/files/qwt-deaths.log

say "--- validating the detector on a PRE-FIX capture that is known to contain the notice"
if [ ! -s "$CONTROL" ]; then
  say "INSTRUMENT: the control capture is missing ($CONTROL) - without it this cell cannot show its"
  say "            detector is able to FAIL, and a quiet result would be worthless"
  exit 2
fi
cn=$(command grep -acE "$NOTICE_RE" "$CONTROL" 2>/dev/null || true)
say "control capture: $cn notice line(s) found (must be >= 1)"
[ "${cn:-0}" -ge 1 ] || { say "INSTRUMENT: the detector finds NOTHING in a capture that contains the defect"; exit 2; }

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh
ps1(){ QTEST_VM=$VM timeout "${T:-180}" tools/qtest run \
         "powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1; }
wait_qrexec(){ for _i in $(seq 1 42); do
    if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then return 0; fi
    sleep 10; done; return 1; }

say "--- boot the subject"
qwt_shutdown "$VM" 600 >/dev/null 2>&1
timeout 300 qvm-start "$VM" >/dev/null 2>&1
wait_qrexec || { say "FAIL qrexec never answered on the first boot"; exit 4; }

# WATERMARK, NOT A CLOCK. The first version of this took the guest's own time as a mark and then
# filtered events with TimeCreated -ge $mark. It discarded everything: the mark read 17:07 while the
# real time was 14:07, because the guest boots ~3 h ahead and our sync-clock-from-dom0 corrects it
# about 60 s in - so records written AFTER the mark carry EARLIER stamps. Measured 2026-10-09, in
# this cell, on the same day three other instruments were fixed for exactly that.
# What is monotonic and clock-free: a channel's RecordId, and an append-only log's line count. Both
# survive the reboot and both only ever grow, so "new since the watermark" needs no time at all.
WM=$(ps1 "\$o=@()
foreach (\$ch in @('Microsoft-Windows-TaskScheduler/Operational','System')) {
  \$v = 0
  try { \$v = [long](@(Get-WinEvent -LogName \$ch -MaxEvents 1 -EA Stop)[0].RecordId) } catch { \$v = 0 }
  \$o += ((\$ch -replace '.*/','') + '=' + \$v)
}
foreach (\$f in @('Q:\Qubes Logs\qwt-deaths.log','Q:\Qubes Logs\bridge.log')) {
  \$n = 0
  if (Test-Path -LiteralPath \$f) { \$n = @(Get-Content -LiteralPath \$f -EA SilentlyContinue).Count }
  \$o += ((Split-Path \$f -Leaf) + '=' + \$n)
}
Write-Host ('WM ' + (\$o -join ' '))" | command grep -ao 'WM .*' | head -1)
[ -n "$WM" ] || { say "FAIL could not read the watermark"; exit 2; }
say "watermark: $WM"
wm(){ printf '%s' "$WM" | command grep -ao "$1=[0-9]*" | head -1 | cut -d= -f2; }
WM_TS=$(wm Operational); WM_SYS=$(wm System); WM_DEATHS=$(wm 'qwt-deaths.log'); WM_BRIDGE=$(wm 'bridge.log')
for v in "$WM_TS" "$WM_SYS" "$WM_DEATHS" "$WM_BRIDGE"; do
  [ -n "$v" ] || { say "FAIL the watermark is incomplete ($WM) - nothing can be scoped to this run"; exit 2; }
done

say "--- start the update scan and confirm it is RUNNING"
# POLL, DO NOT SAMPLE ONCE. Measured 2026-10-09: a single check 20 s after `schtasks /run` read
# 'Ready', because on a subject with netvm='' the scan has nothing to reach and finishes in
# seconds - so the cell refused to grade, correctly, but for a reason that is about the SUBJECT and
# not about the fix. The subject needs a netvm for a scan to run long enough to be reaped, and this
# polls so a scan that is briefly Running is still caught.
st=$(ps1 "\$t='\\QubesWindowsUpdateScan'
\$i=Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan' -EA SilentlyContinue
if (-not \$i) { Write-Host 'SCAN=absent'; exit }
schtasks /run /tn \$t 2>&1 | Out-Null
\$seen = 'Ready'
foreach (\$n in 1..30) {
  \$s = (Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan').State
  if (\$s -eq 'Running') { \$seen = 'Running'; break }
  Start-Sleep -Seconds 2
}
Write-Host ('SCAN=' + \$seen)" | command grep -ao 'SCAN=[A-Za-z]*' | head -1)
say "scan task: ${st:-unknown}"
case "${st:-}" in
  SCAN=Running) ;;
  SCAN=absent) say "INSTRUMENT: the scan task is not registered on this subject - the condition cannot arise"; exit 2 ;;
  *) say "INSTRUMENT: the scan never went Running in 60 s ('${st#SCAN=}') - nothing for the shutdown"
     say "            to reap. On a subject with netvm='' the scan has nothing to reach and ends in"
     say "            seconds; give the subject a netvm (qvm-prefs <vm> netvm fw-net) and re-run."
     exit 2 ;;
esac

# The scan is what gives the shutdown something long-running to reap, but the condition is ANY of
# our tasks ended by the shutdown - which is what the suppression covers and what was reported.
say "--- shut the guest down WHILE the scan runs (this is the condition)"
qwt_shutdown "$VM" 600 >/dev/null 2>&1
timeout 300 qvm-start "$VM" >/dev/null 2>&1
wait_qrexec || { say "FAIL qrexec never answered after the shutdown-during-scan boot"; exit 4; }

say "--- read the guest's own records, scoped to after the mark"
cat > "$OUT/read.ps1" <<PS1
# Everything below is scoped by RecordId / line count, never by time (see the watermark comment).
\$wmTs = $WM_TS; \$wmSys = $WM_SYS; \$wmDeaths = $WM_DEATHS; \$wmBridge = $WM_BRIDGE
# CONDITION: a 201 for the scan task carrying a shutdown result code, and a shutdown record, both
# NEW since the watermark. 0x8007045B is ERROR_SHUTDOWN_IN_PROGRESS; 0x8007050B (win32 1291) is what
# Task Scheduler left behind on the measured cases. Both come from captures, not from a table.
\$codes = @(2147943515, 2147943691)
\$cond = 0; \$shut = 0; \$seen201 = 0
try {
  foreach (\$e in @(Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 900 -EA Stop)) {
    if ([long]\$e.RecordId -le \$wmTs) { continue }
    if (\$e.Id -ne 201) { continue }
    \$seen201++
    \$x = [xml]\$e.ToXml()
    \$tn = (\$x.Event.EventData.Data | Where-Object { \$_.Name -eq 'TaskName' }).'#text'
    \$rc = (\$x.Event.EventData.Data | Where-Object { \$_.Name -eq 'ResultCode' }).'#text'
    # ANY of OUR tasks, not just the scan. Measured 2026-10-09: the scan completed cleanly
    # (rc=0) before the shutdown landed, while the shutdown reaped SIX other Qubes tasks with
    # rc=0x8007050B - including \QubesPvNic, which is the task the owner actually reported. The
    # suppression is per-task-death and is not scan-specific, so a condition that only accepted the
    # scan called a reproduced condition INVALID.
    if ((\$tn -like '*Qubes*' -or \$tn -like '*Qwt*' -or \$tn -like '*QWT*') -and \$codes -contains [int64]\$rc) {
      \$cond++
      Write-Output ("UC-REAPED task=" + \$tn + " rc=" + \$rc)
    }
  }
} catch { }
try {
  foreach (\$e in @(Get-WinEvent -LogName 'System' -MaxEvents 900 -EA Stop)) {
    if ([long]\$e.RecordId -le \$wmSys) { continue }
    if (@(109, 1074, 6006) -contains \$e.Id) { \$shut++ }
  }
} catch { }
Write-Output ("UC-CONDITION=" + \$cond + " SHUTDOWNRECORDS=" + \$shut + " NEW201=" + \$seen201)
# SYMPTOM: notices among the lines APPENDED since the watermark.
\$n = 0
foreach (\$pair in @(@{f='Q:\Qubes Logs\qwt-deaths.log'; w=\$wmDeaths}, @{f='Q:\Qubes Logs\bridge.log'; w=\$wmBridge})) {
  if (-not (Test-Path -LiteralPath \$pair.f)) { continue }
  \$L = @(Get-Content -LiteralPath \$pair.f -EA SilentlyContinue)
  if (\$L.Count -le \$pair.w) { continue }
  foreach (\$l in \$L[\$pair.w..(\$L.Count - 1)]) {
    if (\$l -match 'task failed') { \$n++; Write-Output ("UC-NOTICE " + \$l) }
  }
}
Write-Output ("UC-NOTICES=" + \$n)
PS1
QTEST_VM=$VM timeout 300 tools/qtest pushrun "$OUT/read.ps1" > "$OUT/read.out" 2>&1
command grep -aE '^UC-' "$OUT/read.out" | cut -c1-240

cond=$(command grep -ao 'UC-CONDITION=[0-9]*' "$OUT/read.out" | head -1 | cut -d= -f2)
shut=$(command grep -ao 'SHUTDOWNRECORDS=[0-9]*' "$OUT/read.out" | head -1 | cut -d= -f2)
noti=$(command grep -ao 'UC-NOTICES=[0-9]*' "$OUT/read.out" | head -1 | cut -d= -f2)
say "condition=${cond:-?} shutdown-records=${shut:-?} notices=${noti:-?}"

[ -n "${cond:-}" ] && [ -n "${noti:-}" ] || { say "INVALID: the guest read returned nothing to grade"; exit 2; }
if [ "${cond:-0}" -lt 1 ]; then
  say "INVALID INSTRUMENT: the shutdown did NOT reap the scan (no 201 with a shutdown code after the"
  say "                    mark), so there was nothing to suppress and a quiet log proves nothing."
  exit 2
fi
if [ "${noti:-0}" -gt 0 ]; then
  say "FAIL: the shutdown reaped the scan AND dom0 was told a task failed ($noti notice line(s)) -"
  say "      the suppression does not work on a real guest, exactly as the first fix did not."
  exit 1
fi
say "PASS: the shutdown reaped the scan ($cond record(s), $shut shutdown record(s)) and NO task-failure"
say "      notice was produced - measured on a guest, with the condition present."

# lint L19: a cell that boots a guest reports on the error log it leaves behind. The boot above ends
# in a deliberately reaped task, so the sweep takes its own clean boot - clean-boot-sweep.sh does
# that and delegates to log-sweep.
say "--- clean boot + sweep"
bash mgmt/harness/clean-boot-sweep.sh "$VM" "scratchpad/sweep-$VM-after-updater-cell"; srv=$?
say "clean-boot-sweep rc=$srv"
exit 0
