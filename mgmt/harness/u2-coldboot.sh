#!/bin/bash
# U2 — the QdbDaemon startup-race fix, on a real cold boot of a TEMPLATE, with the scan ARMED.
#
# WHY THIS IS A SEPARATE RUNNER FROM SG1. Their preconditions CONTRADICT each other:
#   * SG1 (and every RND/BENCH cell) requires `QubesWindowsUpdateScan` DISARMED - a boot+2min scan
#     raises the proxy and churns qrexec, which is a named wedge trigger under rendering load.
#   * U2 requires that exact boot-triggered pass to RUN, because the fault under test is the pass
#     misreading the VM class at early boot.
# Measured 2026-08-31: running them on one boot produced `class_lines:0, class_correct:false` on a
# genuine TemplateVM - not a product failure, but my own disarm having removed the thing under test.
# Two cells with opposite preconditions must not share a boot.
#
# SUBJECT MUST BE A TemplateVM. The fault is "a TemplateVM read as a standalone at early boot"; on a
# StandaloneVM there is no misclassification to make and `qdb_retry_evidence:false` is correct.
#
# NO RENDERING LOAD HERE. This runner does nothing but boot and read - the wedge exposure the P3
# rule guards against comes from combining the scan with SendInput/capture load, not from the scan
# itself, which is ordinary product behaviour on every boot.
#
#   mgmt/harness/u2-coldboot.sh <template-vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: required guest script(s) missing:$m" >&2; exit 2; }; }
require_scripts guest/wu-boot-acceptance-arm.ps1 guest/wu-boot-acceptance-check.ps1

VM="${1:?usage: $0 <template-vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/U2-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
q(){ QTEST_VM=$VM timeout -k 8 "${T:-200}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
log(){ echo "$(date -u +%H:%M:%S) u2[$VM]: $*" | tee -a "$OUT/u2.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0

klass=$(qvm-prefs "$VM" klass 2>/dev/null)
[ "$klass" = TemplateVM ] || { log "REFUSING: $VM is a $klass. The QdbDaemon race is template-specific."; exit 2; }

alive(){ r 'cmd /c echo ALIVE' | grep -qa ALIVE; }
alive || { log "FATAL: $VM not answering qrexec"; exit 2; }

# ---------------------------------------------------------------- scan must be ARMED, not disarmed
log "=== ENSURE the boot scan is ENABLED (the opposite of every rendering cell) ==="
r 'cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable & schtasks /query /tn QubesWindowsUpdateScan /fo list | findstr /i status' \
  | grep -ai status | sed 's/^/  /' | tee "$OUT/scan-state.txt"
grep -qi 'ready' "$OUT/scan-state.txt" || { log "FATAL: the scan task is not Ready; U2 cannot be exercised"; exit 2; }

log "=== ARM the acceptance baseline BEFORE the reboot ==="
T=300 q pushrun guest/wu-boot-acceptance-arm.ps1 2>/dev/null | tr -d '\r' | grep -aE 'boot_time_before|vm_class_now|enabled' | sed 's/^/  /'

# CLEAR THE DEBOUNCE, or this cell measures my own previous activity.
# The -Scheduled scan (which is what the boot trigger runs) has a 30-MINUTE DEBOUNCE: it skips when
# a completed pass already left an answer in update-status.json. Measured 2026-08-31: three manual
# U1 scans at 02:24-02:26 wrote an answer, the boot pass fired correctly at 02:35:26 (lastresult=0)
# 9 minutes later, and skipped - writing nothing. `class_lines:0` was therefore MY OWN earlier runs
# suppressing the thing under test, not a defect. The updater's own comment describes exactly this
# case. Removing the status file puts the guest in the state U2 is about: a boot with no recent
# answer, where the boot scan is the recovery path.
log "=== clear the scan debounce (update-status.json) so the boot pass is not suppressed ==="
r 'cmd /c del /q C:\ProgramData\Qubes\update-status.json 2>nul & if exist C:\ProgramData\Qubes\update-status.json (echo STILL_THERE) else (echo CLEARED)' | grep -aE 'CLEARED|STILL_THERE' | sed 's/^/  /'

bootid(){ r 'cmd /c powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString(\"o\")"' | grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+' | head -1; }
B0=$(bootid); log "  LastBootUpTime before: ${B0:-unknown}"

log "=== COLD BOOT ==="
timeout -k 10 320 qvm-shutdown --wait --timeout 260 "$VM" >/dev/null 2>&1; sleep 4
[ "$(qvm-ls --raw-data --fields STATE "$VM" | tail -1)" = Halted ] || { log "FATAL: $VM did not halt"; exit 2; }
timeout -k 10 200 qvm-start "$VM" >/dev/null 2>&1 & disown
sleep 45
for _ in $(seq 1 40); do alive && break; sleep 15; done
alive || { log "FATAL: no qrexec after the cold boot"; exit 2; }
B1=$(bootid); log "  LastBootUpTime after: ${B1:-unknown}"
[ -n "$B0" ] && [ "$B0" = "$B1" ] && { log "FATAL: boot time unchanged - no cold boot happened"; exit 2; }
log "  COLD BOOT PROVEN"

# The scan task fires at boot + PT2M. Wait past it, with margin, or the pass has not run yet and
# `class_lines:0` would mean "too early", not "it did not classify".
log "=== waiting out the boot-triggered scan (trigger is boot + PT2M) ==="
for i in $(seq 1 12); do
  sleep 30
  n=$(r 'cmd /c powershell -NoProfile -Command "@(Select-String -Path (Get-ChildItem \"C:\ProgramData\Qubes\qubes-windows-update*.log\" | Sort LastWriteTime -Desc | Select -First 1).FullName -Pattern \"VM class\" -EA SilentlyContinue).Count"' | grep -aoE '^[0-9]+$' | head -1)
  log "  +$((i*30))s: 'VM class' lines in the updater log: ${n:-?}"
  [ "${n:-0}" -gt 0 ] && break
done

log "=== U2 CHECK ==="
U=$(T=400 q pushrun guest/wu-boot-acceptance-check.ps1 | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -ao '{.*}' | head -1)
echo "  ${U:-NO RESULT}" | tee "$OUT/u2.json"
if [ -z "$U" ]; then
  log "  -> INVALID-INSTRUMENT: no RESULT block"
  printf 'U2\tcoldboot-classification\tINVALID-INSTRUMENT\tno RESULT block\t%s\n' "$EV" >> "$V"; rc=1
else
  cc=$(echo "$U" | grep -ao '"class_correct":[a-z]*' | cut -d: -f2)
  qr=$(echo "$U" | grep -ao '"qdb_retry_evidence":[a-z]*' | cut -d: -f2)
  cl=$(echo "$U" | grep -ao '"class_lines":[0-9]*' | cut -d: -f2)
  se=$(echo "$U" | grep -ao '"saw_empty_class":[a-z]*' | cut -d: -f2)
  log "  class_lines=$cl class_correct=$cc saw_empty_class=$se qdb_retry_evidence=$qr"
  if [ "${cl:-0}" -eq 0 ]; then
    log "  -> INVALID-VACUOUS: the boot pass logged no class line at all, so nothing classified"
    log "     anything - this grades the SCAN not having run, not the fix."
    printf 'U2\tcoldboot-classification\tINVALID-VACUOUS\tclass_lines=0: the boot-triggered pass produced no class line\t%s\n' "$EV" >> "$V"; rc=1
  elif [ "$cc" = true ]; then
    log "  -> PASS: the boot pass classified this TemplateVM CORRECTLY from qubesdb on a real cold boot"
    printf 'U2\tcoldboot-classification\tPASS-UNPROVEN\tclass_correct=true, class_lines=%s, on a proven cold boot of a TemplateVM\t%s\n' "$cl" "$EV" >> "$V"
    printf 'U2\tqdbdaemon-race-fix-exercised\tPASS-UNPROVEN\tqdb_retry_evidence=%s saw_empty_class=%s - the daemon was waited out rather than read empty\t%s\n' "$qr" "$se" "$EV" >> "$V"
  else
    log "  -> FAIL: a TemplateVM was NOT classified correctly on a cold boot"
    printf 'U2\tcoldboot-classification\tFAIL\tclass_correct=false with class_lines=%s: %s\t%s\n' "$cl" "$U" "$EV" >> "$V"; rc=1
  fi
fi
log "=== finished rc=$rc ==="
exit $rc
