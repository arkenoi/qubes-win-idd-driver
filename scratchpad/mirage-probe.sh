#!/bin/bash
# MIRAGE-FIREWALL PROBE. Not part of acceptance (user, 2026-08-07) - the question is only
# whether attaching fw-net fails CLEANLY (a clear error, or a guest that boots and simply
# has no network) rather than leaving an unresponsive qube. History: a Windows HVM with
# netvm=fw-net failed at DOMAIN CREATE ("libxenlight failed to create new domain", stubdom
# timed out waiting on the vif), which is why reprovision.sh forces netvm ''.
# Now that PV networking actually binds, retest: the guest's netfront is a different
# animal from the emulated path that was in play before.
cd /home/user/qubes-win-idd-driver
VM=win10-clean
log(){ echo "$(date -u +%H:%M:%S) mirage: $*"; }

# Wait for the acceptance chain to finish so we never fight it for the guest.
while pgrep -f "accept-clean.sh $VM" >/dev/null || pgrep -f "ship.sh" >/dev/null; do sleep 60; done
log "acceptance chain done; starting mirage probe"

log "shutting $VM down"
QTEST_VM=$VM tools/qtest shutdown >/dev/null 2>&1
t0=$(date +%s); while :; do QTEST_VM=$VM tools/qtest state 2>/dev/null | tr -d '\0' | grep -q Halted && break
  [ $(( $(date +%s)-t0 )) -gt 240 ] && { QTEST_VM=$VM tools/qtest kill >/dev/null 2>&1; sleep 5; break; }; sleep 10; done

log "setting netvm=fw-net (mirage-firewall)"
if ! out=$(qvm-prefs $VM netvm fw-net 2>&1); then log "FAIL setting netvm: $out"; exit 1; fi
log "netvm now: $(qvm-prefs $VM netvm 2>&1)"

log "starting $VM - watching for a CLEAN failure vs a hang"
start_out=$(timeout 300 qvm-start $VM 2>&1); rc=$?
log "qvm-start rc=$rc output: ${start_out:-<none>}"
state=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v=$VM '$1==v{print $2}')
log "domain state after start attempt: $state"

verdict="UNKNOWN"
if [ $rc -eq 124 ]; then
    # 124 is OUR timeout firing, NOT an error return: qvm-start HUNG. Recorded 2026-08-07 -
    # the classifier previously called this "clean fail" and reported the opposite of the
    # truth. A domain left in Transient is the unresponsive-qube case, not a clean stop.
    verdict="BAD: qvm-start HUNG (timed out after 300s), domain state=$state - NOT a clean failure"
elif [ "$state" = "Transient" ]; then
    verdict="BAD: domain stuck in Transient (rc=$rc) - creation neither completed nor failed cleanly"
elif [ $rc -ne 0 ]; then
    verdict="CLEAN-FAIL-AT-CREATE (qvm-start rc=$rc, domain state=$state)"
else
    # Domain created. Does the guest come up and answer, just without network?
    t0=$(date +%s); alive=0
    while [ $(( $(date +%s)-t0 )) -lt 420 ]; do
        if out=$(QTEST_VM=$VM timeout 20 tools/qtest run 'echo OK' 2>&1) && grep -q OK <<<"$out"; then alive=1; break; fi
        sleep 20
    done
    if [ $alive -eq 1 ]; then
        nic=$(QTEST_VM=$VM timeout 60 tools/qtest ps "((Get-CimInstance Win32_NetworkAdapter | Where-Object { \$_.PhysicalAdapter }).Name) -join ','" 2>&1 | tr -d '\r' | grep -aiE "xen|realtek" | head -1)
        ip=$(QTEST_VM=$VM timeout 60 tools/qtest ps "((Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { \$_.IPEnabled }).IPAddress | Select-Object -First 1)" 2>&1 | tr -d '\r' | grep -aE "^[0-9]+\." | head -1)
        verdict="GUEST USABLE (qrexec answers) nic='${nic:-none}' ip='${ip:-none}'"
    else
        verdict="BAD: domain Running but qrexec never answered - the unresponsive-qube case"
        QTEST_VM=$VM tools/qtest wedge evidence/mirage-wedge-$(date +%H%M%S) 2>&1 | tail -1
    fi
fi
log "MIRAGE_VERDICT: $verdict"

log "restoring netvm=core-net"
QTEST_VM=$VM tools/qtest kill >/dev/null 2>&1; sleep 5
qvm-prefs $VM netvm core-net 2>&1 | head -1
log "done"
