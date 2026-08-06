#!/bin/bash
# Re-provision a CLEAN Windows test qube from the unattended ISO, end to end.
# User rule 2026-08-06: "whatever we get fixed, at the end acceptance requires end to end
# test on clean system" - so every acceptance run starts from a destroyed-and-recreated
# qube, never from one an earlier attempt touched.
#
# Usage: scratchpad/reprovision.sh <vm> <loop-device-name>
#   e.g. scratchpad/reprovision.sh win10-fresh loop0
set -u
VM="${1:?usage: $0 <vm> <loopN>}"
LOOP="${2:?usage: $0 <vm> <loopN>}"
HOLDER=win-idd-mgmt

log() { echo "$(date -u +%H:%M:%S) reprovision: $*"; }

# One instance per VM. Two concurrent runs interleave their output in the same log and,
# worse, both restart the guest - one can qvm-start a VM the other just killed, or start it
# WITHOUT the CD mid-install. Hit 2026-08-06: a killed run kept polling and restarting the
# VM a second run had recreated, producing spliced log lines and an unattributable result.
exec 9>"/tmp/reprovision-$VM.lock"
flock -n 9 || { log "another reprovision is already running for $VM - refusing"; exit 1; }
state() { qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

if [ -n "$(state)" ]; then
    log "shutting down $VM"
    timeout 200 qvm-shutdown --wait "$VM" >/dev/null 2>&1
    for _ in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done
    [ "$(state)" = Halted ] || { log "force kill"; timeout 60 qvm-kill "$VM" >/dev/null 2>&1; sleep 5; }
    log "removing $VM (clean-slate rule)"
    timeout 200 qvm-remove -f "$VM" >/dev/null 2>&1 || { log "FAIL remove"; exit 1; }
fi

log "creating $VM"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$VM" || exit 1
qvm-prefs "$VM" memory 8192
qvm-prefs "$VM" maxmem 8192
qvm-prefs "$VM" vcpus 4
qvm-prefs "$VM" qrexec_timeout 300
# netvm MUST be set explicitly: the inherited default (fw-net, a Mirage unikernel)
# never brings its vif backend up, so the stubdom times out and the DOMAIN FAILS TO
# CREATE - "libxenlight failed to create new domain" with no other clue (measured
# 2026-08-06; cost several hours). Install offline; attach core-net later for the
# networking/Windows Update tests.
qvm-prefs "$VM" netvm ''
qvm-volume extend "$VM:root" 80GiB
qvm-features "$VM" os Windows
qvm-tags "$VM" add win-idd-testbed
log "created and tagged"

log "booting from $HOLDER:$LOOP (unattended Windows install)"
qvm-start "$VM" --cdrom="$HOLDER:$LOOP" || exit 1

# The installer reboots several times; a guest reboot destroys the domain
# (on_reboot=destroy), so restart WITHOUT the CD until qrexec answers.
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 4500 ]; do
    if [ "$(QTEST_VM=$VM timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | tr -d '\r\0' | grep -c BOOT_OK)" -ge 2 ]; then
        log "qrexec alive after $(( $(date +%s) - t0 ))s"
        QTEST_VM=$VM timeout 90 ./tools/qtest run "powershell -NoProfile -Command \"[Environment]::OSVersion.Version.ToString(); (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion\"" 2>&1 | tr -d '\r' | grep -E '^10\.|^2[0-9]H' | head -2
        exit 0
    fi
    [ "$(state)" = Halted ] && { log "install-phase halt -> restarting without CD"; timeout 90 qvm-start "$VM" >/dev/null 2>&1; }
    sleep 30
done
log "FAIL: never reached qrexec within 75 min"
exit 1
