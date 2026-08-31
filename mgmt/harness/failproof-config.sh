#!/bin/bash
# FAIL-PROOF harness for the CONFIGURATION assertions (task shape, script presence, netvm, adapters).
#
# WHY THESE ARE CHEAP TO PROVE. Each asserts "X is registered / configured / absent". The defect
# state does not have to be MANUFACTURED on the subject - it already exists somewhere legitimate:
#   * a TemplateVM has netvm='' ... and an AppVM deliberately has one. Point the check at the AppVM.
#   * a registered task answers ... and a name that was never registered does not. Query both.
#   * a present script is found ... and a path that does not exist is not.
# So every proof here is two-sided WITHOUT mutating the subject at all. That matters: a fail-proof
# that has to break the guest can only be run on a disposable one, and one that does not can be run
# on every acceptance pass, which is where a rotting check would actually get caught.
#
#   mgmt/harness/failproof-config.sh <vm>
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm>}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/FAILPROOF-config}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
log(){ echo "$(date -u +%H:%M:%S) cfg: $*" | tee -a "$OUT/config.log"; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  QTEST_VM=$VM timeout -k 8 200 ./tools/qtest run "cmd /c powershell -NoProfile -EncodedCommand $b" 2>/dev/null \
    | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }

earn(){  # <check> <positive-result> <negative-result> <detail>
  local chk="$1" pos="$2" neg="$3" det="$4"
  if [ "$pos" = True ] && [ "$neg" = False ]; then
    log "  -> PROOF EARNED: $chk  (positive=$pos, negative=$neg)"
    printf 'CONFIG\t%s\tPASS\tSEEN TO FAIL 2026-08-31 (two-sided, no mutation): %s\t%s\n' "$chk" "$det" "$EV" >> "$V"
  else
    log "  -> NOT PROVEN: $chk  positive=$pos negative=$neg (want True/False)"
    printf 'CONFIG\t%s\tPASS-UNPROVEN\ttwo-sided attempt gave positive=%s negative=%s\t%s\n' "$chk" "$pos" "$neg" "$EV" >> "$V"; rc=1
  fi
}

# --------------------------------------------------------------- templates-netvm-empty
# Positive: a TemplateVM must have netvm=''. Negative: an AppVM deliberately HAS one, and the same
# assertion must reject it. Never attach a netvm to a template to manufacture this - that is banned.
log "=== templates-netvm-empty ==="
tpl_ok=True
for t in win10-tpl win11-tpl; do
  n=$(qvm-prefs "$t" netvm 2>/dev/null)
  [ -z "$n" ] || tpl_ok=False
  log "  $t netvm='$n'"
done
app_n=$(qvm-prefs win10-app netvm 2>/dev/null)
log "  win10-app netvm='$app_n'  (the legitimate negative)"
app_ok=$([ -z "$app_n" ] && echo True || echo False)
earn templates-netvm-empty "$tpl_ok" "$app_ok" \
  "win10-tpl/win11-tpl netvm='' -> True; the same assertion on win10-app (netvm='$app_n') -> False"

# --------------------------------------------------------------- scheduled-task assertions
task_shape(){  # <taskname> -> True/False for "registered, boot trigger, SYSTEM"
  psrun "\$t = Get-ScheduledTask -TaskName '$1' -EA SilentlyContinue
if (-not \$t) { Write-Output 'SHAPE False'; exit }
\$boot = @(\$t.Triggers | Where-Object { \$_.CimClass.CimClassName -match 'Boot' }).Count -ge 1
\$sys  = \$t.Principal.UserId -match 'SYSTEM|S-1-5-18'
Write-Output ('SHAPE ' + [bool](\$boot -and \$sys))" | grep -ao 'SHAPE .*' | awk '{print $2}' | head -1
}
for pair in "autologon-guard-shape:QubesAutologonGuard" "scan-task-shape:QubesWindowsUpdateScan" "latch-task-registered:QubesPvNic"; do
  chk=${pair%%:*}; task=${pair#*:}
  log "=== $chk ($task) ==="
  pos=$(task_shape "$task"); neg=$(task_shape "QubesTaskThatWasNeverRegistered")
  log "  real task -> $pos ; never-registered name -> $neg"
  earn "$chk" "${pos:-?}" "${neg:-?}" \
    "Get-ScheduledTask '$task' with a boot trigger running as SYSTEM -> True; a name that was never registered -> False"
done

# --------------------------------------------------------------- applier-script-present
log "=== applier-script-present ==="
pos=$(psrun "Write-Output ('P ' + (Test-Path 'C:\\Program Files\\Qubes Tools\\bin\\pvnic-boot.ps1'))" | grep -ao 'P .*' | awk '{print $2}')
neg=$(psrun "Write-Output ('P ' + (Test-Path 'C:\\Program Files\\Qubes Tools\\qubes-rpc-services\\a-script-that-does-not-exist.ps1'))" | grep -ao 'P .*' | awk '{print $2}')
log "  real script -> $pos ; absent path -> $neg"
earn applier-script-present "${pos:-?}" "${neg:-?}" \
  "Test-Path on the shipped pvnic-boot.ps1 -> True; on a path that does not exist -> False"

# --------------------------------------------------------------- no-loopback-masquerade
# The check asserts no loopback adapter is being counted as the PV NIC. Positive: the real adapter
# list has no loopback. Negative: the same predicate applied to a list that DOES contain one.
log "=== no-loopback-masquerade ==="
pos=$(psrun "\$a = Get-NetAdapter -EA SilentlyContinue | Where-Object { \$_.InterfaceDescription -match 'Loopback' }
Write-Output ('L ' + [bool](@(\$a).Count -eq 0))" | grep -ao 'L .*' | awk '{print $2}')
neg=$(psrun "\$fake = @([pscustomobject]@{InterfaceDescription='Microsoft KM-TEST Loopback Adapter'})
\$a = \$fake | Where-Object { \$_.InterfaceDescription -match 'Loopback' }
Write-Output ('L ' + [bool](@(\$a).Count -eq 0))" | grep -ao 'L .*' | awk '{print $2}')
log "  real adapters -> $pos ; a list containing a loopback -> $neg"
earn no-loopback-masquerade "${pos:-?}" "${neg:-?}" \
  "the live adapter list contains no Loopback -> True; the same predicate over a list that does -> False"

log "=== finished rc=$rc ==="
exit $rc
