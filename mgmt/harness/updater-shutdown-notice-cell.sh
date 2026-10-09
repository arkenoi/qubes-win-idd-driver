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

# MARK: everything graded below must be AFTER this instant, or a previous boot's records decide the
# verdict (the guest keeps per-day logs, so an unmarked read grades the whole day).
MARK=$(ps1 "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'" | tr -d '\r' | command grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}' | head -1)
[ -n "$MARK" ] || { say "FAIL could not read the guest clock for a mark"; exit 2; }
say "guest-side mark: $MARK"

say "--- start the update scan and confirm it is RUNNING"
st=$(ps1 "\$t='\\QubesWindowsUpdateScan'
\$i=Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan' -EA SilentlyContinue
if (-not \$i) { Write-Host 'SCAN=absent'; exit }
schtasks /run /tn \$t 2>&1 | Out-Null
Start-Sleep -Seconds 20
\$s=(Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan').State
Write-Host ('SCAN=' + \$s)" | command grep -ao 'SCAN=[A-Za-z]*' | head -1)
say "scan task: ${st:-unknown}"
case "${st:-}" in
  SCAN=Running) ;;
  SCAN=absent) say "INSTRUMENT: the scan task is not registered on this subject - the condition cannot arise"; exit 2 ;;
  *) say "INSTRUMENT: the scan task is '${st#SCAN=}', not Running - nothing for the shutdown to reap"; exit 2 ;;
esac

say "--- shut the guest down WHILE the scan runs (this is the condition)"
qwt_shutdown "$VM" 600 >/dev/null 2>&1
timeout 300 qvm-start "$VM" >/dev/null 2>&1
wait_qrexec || { say "FAIL qrexec never answered after the shutdown-during-scan boot"; exit 4; }

say "--- read the guest's own records, scoped to after the mark"
cat > "$OUT/read.ps1" <<PS1
\$mark = [datetime]'$MARK'
# CONDITION: a 201 for the scan task carrying a shutdown result code, plus a shutdown record at that
# instant. 0x8007045B is ERROR_SHUTDOWN_IN_PROGRESS; 0x8007050B (win32 1291) is what Task Scheduler
# left behind on the measured cases. Both are taken from captures, not from a table.
\$codes = @(2147943515, 2147943691)
\$cond = 0; \$shut = 0
try {
  \$evs = @(Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 600 -EA Stop |
            Where-Object { \$_.TimeCreated -ge \$mark })
  foreach (\$e in \$evs) {
    if (\$e.Id -ne 201) { continue }
    \$x = [xml]\$e.ToXml()
    \$tn = (\$x.Event.EventData.Data | Where-Object { \$_.Name -eq 'TaskName' }).'#text'
    \$rc = (\$x.Event.EventData.Data | Where-Object { \$_.Name -eq 'ResultCode' }).'#text'
    if (\$tn -like '*QubesWindowsUpdateScan*' -and \$codes -contains [int64]\$rc) { \$cond++ }
  }
} catch { }
foreach (\$q in @(@{l='System';i=109}, @{l='System';i=1074}, @{l='System';i=6006})) {
  try { \$shut += @(Get-WinEvent -LogName \$q.l -MaxEvents 400 -EA Stop |
                    Where-Object { \$_.Id -eq \$q.i -and \$_.TimeCreated -ge \$mark }).Count } catch { }
}
Write-Output ("UC-CONDITION=" + \$cond + " SHUTDOWNRECORDS=" + \$shut)
# SYMPTOM: the notice in the guest's own records, after the mark.
\$n = 0
foreach (\$f in @('Q:\Qubes Logs\qwt-deaths.log','Q:\Qubes Logs\bridge.log')) {
  if (-not (Test-Path -LiteralPath \$f)) { continue }
  foreach (\$l in (Get-Content -LiteralPath \$f -EA SilentlyContinue)) {
    if (\$l -notmatch 'task failed') { continue }
    if (\$l -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
      if ([datetime]\$Matches[1] -lt \$mark) { continue }
    }
    \$n++; Write-Output ("UC-NOTICE " + \$l)
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
