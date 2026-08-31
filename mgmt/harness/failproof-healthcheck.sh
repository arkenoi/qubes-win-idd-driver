#!/bin/bash
# FAIL-PROOF HARNESS for the health-check battery.
#
# WHY. H5: "a check counts as evidence only once it has been seen to FAIL on a build with the defect
# deliberately re-introduced. Otherwise record its PASS as unproven." The battery in
# `guest/health-check.ps1` supplies 18 checks that appear in dozens of ledger rows, and NONE of them
# had ever been seen to go red - so every one of those rows could only ever say PASS-UNPROVEN.
# The registry is keyed by CHECK, not by row, so earning one proof closes every row that cites it.
#
# METHOD, per check: assert it is GREEN, plant a defect, assert THAT check (and, where stated, only
# that check) turns up in `failed`, then restore and assert green again. A plant that does not turn
# the check red means the check cannot detect the condition it claims to assert - which is a finding
# about the CHECK, not about the guest.
#
# ONLY SAFE, REVERSIBLE PLANTS ARE HERE. Deliberately excluded, with reasons, because a fail-proof
# that bricks the subject is worse than an unproven check:
#   * pv_disk_bound      - disabling xenvbd is the BOOT disk; a live disable can bugcheck and a
#                          reboot in that state may not come back.
#   * user_data_on_private - would require moving the profile off the private volume.
#   * pnp_no_unexpected_errors / boot_events_clean - no way to inject a genuine PnP/boot fault
#                          without damaging the image.
# Those stay PASS-UNPROVEN and are listed as owed, rather than being quietly counted as proven.
#
#   mgmt/harness/failproof-healthcheck.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: missing:$m" >&2; exit 2; }; }
require_scripts guest/health-check.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/FAILPROOF-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
q(){ QTEST_VM=$VM timeout -k 8 "${T:-300}" ./tools/qtest "$@" 2>/dev/null; }
# PLANTS GO THROUGH -EncodedCommand. A PowerShell one-liner with quotes and backslashes is re-split
# at every hop (bash -> qtest -> cmd.exe -> powershell) - protocol 0.8b rule 2, which I wrote and
# then broke here: the first pv_console_bound plant silently did NOTHING, the check stayed green,
# and the run concluded "the check cannot detect its own condition". Run through EncodedCommand and
# the identical plant sets problem=CM_PROB_DISABLED and the check goes red immediately.
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
log(){ echo "$(date -u +%H:%M:%S) fp[$VM]: $*" | tee -a "$OUT/failproof.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0

health(){ T=600 q pushrun guest/health-check.ps1 | tr -d '\r' | grep -ao '{.*}' | head -1; }
failed_list(){ echo "$1" | python3 -c "
import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print('PARSE_ERROR'); raise SystemExit
print(','.join(d.get('failed') or []) or 'NONE')"; }

log "=== baseline: the whole battery must be green before any plant ==="
H=$(health); F=$(failed_list "$H")
log "  failed=$F"
[ "$F" = NONE ] || { log "FATAL: battery is not green at baseline (failed=$F); a red later would be unattributable"; exit 2; }

# check | plant | restore | human note
run_proof(){
  local chk="$1" plant="$2" restore="$3" note="$4"
  log "=== $chk ==="
  log "  planting: $note"
  psrun "$plant" >/dev/null 2>&1
  sleep 6
  local H2 F2; H2=$(health); F2=$(failed_list "$H2")
  log "  with the defect present, failed=$F2"
  local red=no
  echo ",$F2," | grep -q ",$chk," && red=yes
  # restore FIRST, always - never leave the subject defective because a verdict was being written
  log "  restoring"
  psrun "$restore" >/dev/null 2>&1
  sleep 6
  local H3 F3; H3=$(health); F3=$(failed_list "$H3")
  log "  after restore, failed=$F3"
  if [ "$red" = yes ] && [ "$F3" = NONE ]; then
    log "  -> PROOF EARNED: $chk went red with the defect present and green again after restore"
    printf '%s\t%s\t%s\t%s\t%s\n' HEALTH "$chk" PASS "SEEN TO FAIL: $note -> failed=[$F2]; restored -> failed=NONE" "$EV" >> "$V"
  elif [ "$red" != yes ]; then
    log "  -> NOT RED: the plant did not make $chk fail. The check cannot detect the condition it"
    log "     asserts, OR the plant did not take. Either way $chk stays UNPROVEN."
    printf '%s\t%s\t%s\t%s\t%s\n' HEALTH "$chk" PASS-UNPROVEN "plant did not turn it red (failed=[$F2]) - check may not detect its own condition" "$EV" >> "$V"; rc=1
  else
    log "  -> RESTORE INCOMPLETE: failed=[$F3] after restore. Subject left dirty - fix before continuing."
    printf '%s\t%s\t%s\t%s\t%s\n' HEALTH "$chk" INVALID-INSTRUMENT "restore left failed=[$F3]" "$EV" >> "$V"; rc=1
    log "  ABORTING: every later check would be graded against a dirty baseline. Measured"
    log "  2026-08-31 - the agent_process plant left agent_log_healthy red and pv_console_bound"
    log "  then 'failed' on somebody else's red."
    exit 1
  fi
}

WU='HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

run_proof updates_dom0_owned \
  "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 0 -Type DWord" \
  "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord" \
  "NoAutoUpdate=0 - the guest would service itself, which is exactly what dom0-owned updates forbid"

# agent_process: NO SAFE PLANT. Killing gui-agent.exe does not turn it red - QubesGuiWatchdog
# restarts the agent faster than the battery runs - and it collaterally turns agent_log_healthy red
# (`still_writing:false`, `logs_this_boot:2`) which only a reboot clears. Measured 2026-08-31. A
# plant whose collateral outlasts its own signal is not a fail-proof; agent_process and
# agent_log_healthy stay OWED.

# NOTE: this plant also turns pnp_no_unexpected_errors red, correctly - a disabled device IS an
# unexpected PnP error. Both proofs are earned from this one run.
run_proof pv_console_bound \
  "Get-PnpDevice | Where-Object { \$_.InstanceId -like 'XENBUS\\VEN_XP0001&DEV_CONS*' } | Disable-PnpDevice -Confirm:\$false -ErrorAction Continue; Start-Sleep 3" \
  "Get-PnpDevice | Where-Object { \$_.InstanceId -like 'XENBUS\\VEN_XP0001&DEV_CONS*' } | Enable-PnpDevice -Confirm:\$false -ErrorAction Continue; Start-Sleep 3" \
  "disable the XENBUS PV console device - dom0 loses xl console into a guest whose qrexec is dead"

# qubes_services_running: stop an auto-start Qubes service. Safe and instantly reversible - the
# check asserts every Auto service is Running, so stopping one is exactly its own defect condition.
run_proof qubes_services_running \
  "Stop-Service QubesGuiWatchdog -Force -ErrorAction Continue; Start-Sleep 3" \
  "Start-Service QubesGuiWatchdog -ErrorAction Continue; Start-Sleep 3" \
  "stop the QubesGuiWatchdog service - an Auto service that is not Running is the condition this check asserts against"

log "=== finished rc=$rc ==="
log "OWED (no safe plant exists): pv_disk_bound (boot disk), user_data_on_private, pnp_no_unexpected_errors, boot_events_clean"
exit $rc
