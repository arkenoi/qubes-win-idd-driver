#!/bin/bash
# Clone a HALTED Windows StandaloneVM into a TemplateVM, then create an AppVM on it.
# This is the configuration in forum 42717 post 56 ("an AppVM based on the Windows 10
# template starts and then shuts down silently") and nothing in this project had ever
# exercised it - every test guest here is standalone.
#
# Usage: mgmt/clone-to-template.sh <src-standalone> <new-template> <new-appvm>
#
# qvm-clone in one shot FAILS on this testbed: policy is tag-based, and qvm-clone creates
# the qube and copies volumes into it BEFORE the tags are applied, so the volume call hits
# a qube policy does not yet cover. Create, tag, then copy - that order satisfies policy.
set -u
SRC="${1:?usage: $0 <src-standalone> <new-template> <new-appvm>}"
TPL="${2:?}"
APP="${3:?}"

log() { echo "$(date -u +%H:%M:%S) clone-to-template: $*"; }
state() { qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

[ "$(state "$SRC")" = Halted ] || { log "FAIL: $SRC must be Halted (a running source gives an inconsistent copy)"; exit 1; }

for v in "$TPL" "$APP"; do
    if qvm-check "$v" >/dev/null 2>&1; then
        log "removing existing $v"
        timeout 120 qvm-shutdown --wait "$v" >/dev/null 2>&1
        timeout 300 qvm-remove -f "$v" >/dev/null 2>&1 || { log "FAIL: could not remove $v"; exit 1; }
    fi
done

log "creating template $TPL"
qvm-create --class TemplateVM --label red "$TPL" || exit 1
qvm-tags "$TPL" add win-idd-testbed || exit 1

python3 - "$SRC" "$TPL" <<'EOF' || exit 1
import sys, qubesadmin
app = qubesadmin.Qubes()
src, dst = app.domains[sys.argv[1]], app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
# A fresh TemplateVM's defaults are Linux-shaped: without virt_mode=hvm and an EMPTY kernel
# the guest never reaches its own bootloader.
for p in ('virt_mode', 'kernel', 'memory', 'maxmem', 'vcpus', 'qrexec_timeout', 'netvm'):
    setattr(dst, p, getattr(src, p))
for f in ('os', 'gui', 'qrexec', 'stubdom-qrexec', 'vmexec', 'audio-model', 'timezone',
          'no-monitor-layout', 'rpc-clipboard', 'gui-emulated'):
    try:
        dst.features[f] = src.features[f]
    except KeyError:
        pass
print('cloned volumes, prefs and features')
EOF

log "creating AppVM $APP on $TPL"
qvm-create --class AppVM --template "$TPL" --label red "$APP" || exit 1
qvm-tags "$APP" add win-idd-testbed || exit 1
for p in virt_mode kernel memory maxmem vcpus qrexec_timeout netvm; do
    v=$(qvm-prefs "$TPL" "$p" 2>/dev/null)
    qvm-prefs "$APP" "$p" "$v" >/dev/null 2>&1
done

# --- prime the PV network device (see FINDINGS 2026-08-17) --------------------------------
# WHY THIS EXISTS. The first time a vif appears, Windows installs xennet on the XENVIF NET
# child and the device lands in CM_PROB_NEED_RESTART (problem 14) - it cannot start until a
# reboot. A TEMPLATE has a persistent root, so that reboot completes the install once and for
# all. An APP QUBE does not: its system volume is discarded every boot, so it reinstalls,
# demands a restart, resets, and Qubes halts it. Measured: an app qube from an unprimed
# template dies ~4 s after DHCP forever; from a primed one it runs indefinitely.
#
# This cannot be done offline. On a pristine template there is NO VIF class device, NO NET
# child and NO xennet service at all - the devnodes only exist once a vif has appeared - so
# there is nothing for the installer to install against. The device has to arrive once.
#
# THE TEMPLATE STILL NEVER REACHES A NETWORK. It is given a netvm with a drop-everything
# firewall, so the vif device is enumerated and the driver install completes, while no traffic
# can leave. The netvm is detached again immediately afterwards.
prime_pv_nic() {
    local vm="$1" net="$2"
    [ -n "$net" ] || { log "no netvm given, skipping PV NIC priming (app qubes will loop when networked)"; return 0; }

    log "priming PV network device on $vm via $net (traffic blocked)"
    qvm-prefs "$vm" netvm "$net" || return 1
    qvm-firewall "$vm" reset >/dev/null 2>&1
    qvm-firewall "$vm" add action=drop >/dev/null 2>&1

    qvm-start "$vm" >/dev/null 2>&1
    # The guest resets itself once to complete the install; wait for it to settle rather than
    # racing it. Two minutes is generous - the install happens seconds after the vif appears.
    local i
    for i in $(seq 1 24); do
        sleep 5
        [ "$(qvm-check --running "$vm" >/dev/null 2>&1; echo $?)" = "0" ] || qvm-start "$vm" >/dev/null 2>&1
    done

    qvm-shutdown --wait "$vm" >/dev/null 2>&1
    qvm-prefs "$vm" netvm '' || true
    qvm-firewall "$vm" reset >/dev/null 2>&1
    log "PV NIC primed; $vm is offline again"
}

# Priming is opt-out: PRIME_NETVM= to skip it, otherwise the app qube's netvm is used.
if [ "${PRIME_NETVM-unset}" = "unset" ]; then
    PRIME_NETVM="$(qvm-prefs "$APP" netvm 2>/dev/null)"
fi
prime_pv_nic "$TPL" "$PRIME_NETVM"

log "done: template=$TPL appvm=$APP"
qvm-ls --fields NAME,STATE,KLASS,TEMPLATE "$TPL" "$APP" 2>/dev/null | tail -3
