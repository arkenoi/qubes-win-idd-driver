#!/bin/bash
# PROMOTED CHECKS — rows that were hand-recorded OBSERVATIONS, turned into real deployed checks.
#
# WHY. The 2026-08-31 audit found 36 ledger rows that no harness emits: someone looked at a guest,
# wrote a sentence into the ledger, and it has been counted as a check ever since. H5 cannot apply
# to those - there is nothing that could be "seen to fail". The owner selected the ones whose
# failure would be SILENT (protocol rule 21) for promotion; this file is that promotion.
#
# EACH CHECK HERE MUST BE ABLE TO FAIL, and the fail-proof route is named beside it. A check that
# ships without a route to red is just a longer sentence in the ledger.
#
#   pvnic-seeded (class-aware)  the PV NIC latch is armed and its tasks registered
#                               RED: a guest installed from a payload WITHOUT pvnic-selfprime.ps1
#                               (measured 2026-08-31: pvnic_prime='not in payload', install ok)
#   emulated-unplugged          only the Xen PV adapter remains once a vif exists
#                               RED: the same no-prime guest, which never unplugs the emulated NIC
#   uac-off-secure-desktop      PromptOnSecureDesktop=0, so elevation is an ordinary window
#                               RED: set it to 1 and restart the agent (reversible, done here)
#   secure-desktop-left-cleanly the agent ENTERS and LEAVES the secure desktop, never sticks
#                               RED: needs an injector bit (the v3 deadlock); NOT attempted here,
#                               so it is recorded honestly as unproven rather than quietly passed
#
#   mgmt/harness/promoted-checks.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: missing:$m" >&2; exit 2; }; }
require_scripts guest/pvnic-latch-readback.ps1 guest/nic-state.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/PROMOTED-$VM}"
mkdir -p "$OUT"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-300}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) prom[$VM]: $*" | tee -a "$OUT/promoted.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
emit(){ printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$EV" >> "$V"; [ "$3" = PASS-UNPROVEN ] || [ "$3" = PASS ] || rc=1; }

KLASS=$(qvm-prefs "$VM" klass 2>/dev/null); NETVM=$(qvm-prefs "$VM" netvm 2>/dev/null)
log "=== subject: $VM  class=$KLASS  netvm='${NETVM:-none}' ==="

# ---------------------------------------------------------------- pvnic seeded (class-aware)
# The ledger carries this under two names by VM class; the assertion is identical, so grade it
# once and emit under the name that matches the subject. NICS is DELETE-ON-READ (xen.sys consumes
# it every boot), so a live 0 is not necessarily a defect - the load-bearing evidence is that the
# TASKS exist to re-arm it and the applier is present. That is exactly what the no-prime payload
# removes, and it is what the field failure (AppVM restart-loop, forum 56/70/89) comes from.
log "=== pvnic latch + applier ==="
LR=$(T=400 q pushrun guest/pvnic-latch-readback.ps1 | tr -d '\r' | sed -n '/MARKJSON/,$p' | grep -ao '{.*}' | head -1)
echo "  ${LR:-NO DATA}" | tee -a "$OUT/promoted.log" >/dev/null
log "  readback: ${LR:-NO DATA}"
name=$([ "$KLASS" = TemplateVM ] && echo template-pvnic-seeded || echo standalone-pvnic-seeded)
if [ -z "$LR" ]; then
  log "  -> INVALID-INSTRUMENT: the latch readback returned nothing"
  emit PROM "$name" INVALID-INSTRUMENT "pvnic-latch-readback produced no JSON"
else
  tm=$(echo "$LR" | grep -ao '"task_main":[a-z]*' | cut -d: -f2)
  tr_=$(echo "$LR" | grep -ao '"task_rearm":[a-z]*' | cut -d: -f2)
  mk=$(echo "$LR" | grep -ao '"marker":[a-z]*' | cut -d: -f2)
  sha=$(echo "$LR" | grep -ao '"payload_sha256":"[0-9a-f]*"' | cut -d'"' -f4)
  log "  task_main=$tm task_rearm=$tr_ failure_marker=$mk applier_sha=${sha:0:12}"
  if [ "$tm" = true ] && [ "$tr_" = true ] && [ -n "$sha" ] && [ "$mk" != true ]; then
    emit PROM "$name" PASS-UNPROVEN "both latch tasks registered, applier present (sha ${sha:0:12}), no failure marker"
  else
    log "  -> FAIL: the PV NIC latch is not fully seeded - AppVMs from this image can restart-loop"
    emit PROM "$name" FAIL "task_main=$tm task_rearm=$tr_ applier_sha=${sha:-ABSENT} marker=$mk"
  fi
fi

# ---------------------------------------------------------------- emulated-unplugged
# VACUITY FIRST: with no vif there is no NIC of any kind, so "only the PV adapter is present" is
# trivially true and proves nothing. Refuse to grade it rather than bank a free pass.
log "=== emulated-unplugged ==="
NS=$(T=400 q pushrun guest/nic-state.ps1 | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -ao '{.*}' | head -1)
log "  nic-state: ${NS:-NO DATA}"
if [ -z "$NS" ]; then
  emit PROM emulated-unplugged INVALID-INSTRUMENT "nic-state produced no JSON"
elif [ -z "$NETVM" ]; then
  log "  -> N/A: no netvm attached, so no adapter exists at all; the assertion is vacuous here"
  emit PROM emulated-unplugged N/A "subject has no netvm: with no vif there is no adapter, so 'only the PV NIC is present' is vacuously true"
else
  names=$(echo "$NS" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read()); print('|'.join(d.get('adapter_names') or []))" 2>/dev/null)
  pv=$(echo "$names" | grep -ciE 'xen|qubes' || true)
  emu=$(echo "$names" | tr '|' '\n' | grep -ciE 'realtek|intel|e1000|rtl|pcnet|vmxnet' || true)
  log "  adapters: [$names]  pv=$pv emulated=$emu"
  if [ "${pv:-0}" -ge 1 ] && [ "${emu:-0}" -eq 0 ]; then
    emit PROM emulated-unplugged PASS-UNPROVEN "a vif exists and the only adapter is the Xen PV NIC: [$names]"
  else
    log "  -> FAIL: an emulated adapter is still present alongside (or instead of) the PV NIC"
    emit PROM emulated-unplugged FAIL "pv=$pv emulated=$emu adapters=[$names]"
  fi
fi

# ---------------------------------------------------------------- uac-off-secure-desktop
# Silent failure if it regresses: elevation prompts move BACK to the secure desktop, where our own
# filter suppresses them, and the qube appears to hang with no prompt anywhere (the GWeck class).
log "=== uac-off-secure-desktop ==="
UA=$(psrun '$p="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$v=(Get-ItemProperty -Path $p -Name PromptOnSecureDesktop -EA SilentlyContinue).PromptOnSecureDesktop
Write-Output ("PROMPTSD " + $(if ($null -eq $v) { "absent" } else { [string]$v }))
$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log -EA SilentlyContinue | Sort LastWriteTime -Desc | Select -First 1
if ($f) { Write-Output ("QGAUAC " + @(Get-Content $f.FullName | Select-String -SimpleMatch "QGAUAC").Count) } else { Write-Output "QGAUAC none" }')
psd=$(echo "$UA" | grep -ao 'PROMPTSD [a-z0-9]*' | awk '{print $2}')
uac=$(echo "$UA" | grep -ao 'QGAUAC [a-z0-9]*' | awk '{print $2}')
log "  PromptOnSecureDesktop=$psd  agent QGAUAC lines=$uac"
if [ -z "$psd" ]; then
  emit PROM uac-off-secure-desktop INVALID-INSTRUMENT "could not read PromptOnSecureDesktop"
elif [ "$psd" = 0 ]; then
  emit PROM uac-off-secure-desktop PASS-UNPROVEN "PromptOnSecureDesktop=0 (elevation is an ordinary window), agent QGAUAC lines=$uac"
else
  log "  -> FAIL: elevation prompts go to the SECURE DESKTOP, where seamless mapping is suppressed"
  log "     - the qube would appear to hang with no prompt visible anywhere."
  emit PROM uac-off-secure-desktop FAIL "PromptOnSecureDesktop=$psd - elevation returns to the secure desktop"
fi

# ---------------------------------------------------------------- secure-desktop-left-cleanly
# Guards the v3 DEADLOCK this project shipped into a test build: g_OnSecureDesktop latched, the
# agent never re-observed the desktop, zero windows in dom0 while qrexec still answered. The
# check is real; its fail-proof needs an injector bit that suppresses the re-attach, which is NOT
# built yet - so it is emitted as unproven WITH that stated, never as a quiet pass.
log "=== secure-desktop-left-cleanly ==="
SD=$(psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log -EA SilentlyContinue | Sort LastWriteTime -Desc | Select -First 1
$a=Get-Content $f.FullName
Write-Output ("ENTERED " + @($a | Select-String -SimpleMatch "secure-desktop ENTERED").Count)
Write-Output ("LEFT " + @($a | Select-String -SimpleMatch "secure-desktop LEFT").Count)
Write-Output ("STUCK " + @($a | Select-String -SimpleMatch "QGADESKSTUCK").Count)')
ent=$(echo "$SD" | grep -ao 'ENTERED [0-9]*' | awk '{print $2}')
lft=$(echo "$SD" | grep -ao 'LEFT [0-9]*' | awk '{print $2}')
stk=$(echo "$SD" | grep -ao 'STUCK [0-9]*' | awk '{print $2}')
log "  ENTERED=$ent LEFT=$lft QGADESKSTUCK=$stk"
if [ -z "$ent" ] || [ -z "$lft" ] || [ -z "$stk" ]; then
  emit PROM secure-desktop-left-cleanly INVALID-INSTRUMENT "agent-log counters returned no data"
elif [ "$ent" -eq 0 ]; then
  log "  -> N/A: the agent never entered the secure desktop in this log, so there is nothing to leave"
  emit PROM secure-desktop-left-cleanly N/A "no secure-desktop entry in this boot's log: the transition was never exercised"
elif [ "$stk" -gt 0 ]; then
  log "  -> FAIL: QGADESKSTUCK present - the agent latched on the secure desktop (the v3 deadlock)"
  emit PROM secure-desktop-left-cleanly FAIL "QGADESKSTUCK=$stk with ENTERED=$ent LEFT=$lft"
elif [ "$lft" -ge "$ent" ]; then
  emit PROM secure-desktop-left-cleanly PASS-UNPROVEN "ENTERED=$ent LEFT=$lft (every entry was left), QGADESKSTUCK=0. FAIL-PROOF OWED: needs an injector bit suppressing the desktop re-attach"
else
  log "  -> FAIL: entered the secure desktop $ent time(s) but left only $lft - still latched"
  emit PROM secure-desktop-left-cleanly FAIL "ENTERED=$ent but LEFT=$lft: the agent is still on the secure desktop"
fi

log "=== finished rc=$rc ==="
exit $rc
