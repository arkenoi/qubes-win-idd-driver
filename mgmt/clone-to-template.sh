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

log "done: template=$TPL appvm=$APP"
qvm-ls --fields NAME,STATE,KLASS,TEMPLATE "$TPL" "$APP" 2>/dev/null | tail -3
