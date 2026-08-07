#!/bin/bash
# NETVM HOTPLUG PROBE (user, 2026-08-07). Historically a Windows HVM could not take a vif
# at runtime: `qvm-device block attach` to a RUNNING qube answered "empty response from
# qubesd", and PV networking never bound anyway so there was no frontend to plug into.
# Now that xennet binds and the emulated NIC is unplugged, retest properly:
#   detach netvm on a RUNNING guest -> does it survive and lose the NIC cleanly?
#   re-attach   netvm on a RUNNING guest -> does the NIC come back WITHOUT a reboot?
# "Works" = no reboot needed, guest stays responsive, IP returns and the gateway answers.
cd /home/user/qubes-win-idd-driver
VM=win10-clean
log(){ echo "$(date -u +%H:%M:%S) hotplug: $*"; }
nicip(){ QTEST_VM=$VM timeout 60 tools/qtest ps "'NIC=' + (((Get-CimInstance Win32_NetworkAdapter | Where-Object { \$_.PhysicalAdapter -and \$_.NetEnabled }).Name) -join ',') + ' IP=' + (((Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { \$_.IPEnabled }).IPAddress | Select-Object -First 1))" 2>&1 | tr -d '\r' | grep -a "^NIC=" | head -1; }

# run after acceptance AND after the mirage probe, so nothing contends for the guest
while pgrep -f "accept-clean.sh $VM" >/dev/null || pgrep -f "ship.sh" >/dev/null || pgrep -f "mirage.sh" >/dev/null; do sleep 60; done
log "prior chains done; starting hotplug probe"

t0=$(date +%s); until out=$(QTEST_VM=$VM timeout 20 tools/qtest run 'echo OK' 2>&1) && grep -q OK <<<"$out"; do
  [ $(( $(date +%s)-t0 )) -gt 600 ] && { log "guest not reachable - aborting"; exit 1; }; sleep 20; done
log "baseline: $(nicip)"

log "DETACH: qvm-prefs netvm '' on a RUNNING guest"
d_out=$(qvm-prefs $VM netvm '' 2>&1); d_rc=$?
log "detach rc=$d_rc ${d_out:+out=$d_out}"
sleep 25
if out=$(QTEST_VM=$VM timeout 25 tools/qtest run 'echo OK' 2>&1) && grep -q OK <<<"$out"; then
    log "after detach: guest RESPONSIVE - $(nicip)"
else
    log "after detach: guest UNRESPONSIVE (this alone is a defect)"
    QTEST_VM=$VM tools/qtest wedge evidence/hotplug-detach-wedge-$(date +%H%M%S) 2>&1 | tail -1
fi

log "ATTACH: qvm-prefs netvm core-net on a RUNNING guest"
a_out=$(qvm-prefs $VM netvm core-net 2>&1); a_rc=$?
log "attach rc=$a_rc ${a_out:+out=$a_out}"
# give the frontend time to appear and DHCP to complete
ok=0
for i in $(seq 1 12); do
    sleep 15
    r=$(nicip)
    # NOT *IP=1*: that matches APIPA 169.254.*, the exact failure being excluded.
    case "$r" in *IP=10.*|*IP=192.168.*) log "after attach: $r"; ok=1; break;; esac
done
[ $ok -eq 1 ] || log "after attach: no IP within 180s - last: $(nicip)"

gw=$(QTEST_VM=$VM timeout 60 tools/qtest ps "\$c = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { \$_.IPEnabled } | Select-Object -First 1; \$g = \$c.DefaultIPGateway | Select-Object -First 1; 'GWOK=' + (\$g -ne \$null -and (Test-Connection \$g -Count 2 -Quiet)) + ' gw=' + \$g" 2>&1 | tr -d '\r' | grep -a "^GWOK=" | head -1)
log "$gw"

case "$gw" in
  *GWOK=True*) log "HOTPLUG_VERDICT: WORKS - netvm re-attached at runtime, IP and gateway restored, NO reboot" ;;
  *) log "HOTPLUG_VERDICT: DOES NOT WORK at runtime (guest responsive=$([ -n "$gw" ] && echo yes || echo no)) - a reboot is still required" ;;
esac
log "done"
