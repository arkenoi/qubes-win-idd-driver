#!/bin/bash
# clone-guest.sh - copy a HALTED guest to a new qube of the SAME class, from this dev qube.
#
# Usage: mgmt/clone-guest.sh <src> <dst>
#
# WHY THIS EXISTS. `qvm-clone` DOES NOT WORK on this testbed and never has: dom0 policy here is
# tag-based, and qvm-clone creates the qube and copies its volumes BEFORE any tag exists, so the
# volume call lands on a qube policy does not yet cover and the whole thing dies with
# "Service call error: Request refused". mgmt/clone-to-template.sh already worked around this for
# the Standalone -> Template + AppVM shape (create -> tag -> copy), but nothing did the plain
# same-class copy, so the documented instruction for re-testing a field report was a command that
# cannot succeed. Measured again 2026-09-20: `qvm-clone win11de-qwt win11de-e2e` -> Request refused
# in 8 s. The order below is the whole fix.
#
# It copies volumes, the prefs that decide whether a Windows HVM can boot at all (a fresh qube's
# defaults are Linux-shaped - without virt_mode=hvm and an EMPTY kernel the guest never reaches its
# own bootloader), and the features dom0 uses to decide how to talk to it.
. "$(dirname "$0")/harness/shutdown-lib.sh"
set -u

SRC="${1:?usage: $0 <src> <dst>}"
DST="${2:?usage: $0 <src> <dst>}"

log() { echo "$(date -u +%H:%M:%S) clone-guest: $*"; }
state() { qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

qvm-check "$SRC" >/dev/null 2>&1 || { log "FAIL: source $SRC does not exist"; exit 1; }
# A running source gives an inconsistent copy - the same rule clone-to-template.sh enforces.
[ "$(state "$SRC")" = Halted ] || { log "FAIL: $SRC must be Halted (a running source gives an inconsistent copy)"; exit 1; }

CLASS=$(qvm-ls --raw-data --fields class "$SRC" 2>/dev/null)
[ -n "$CLASS" ] || { log "FAIL: could not read the class of $SRC"; exit 1; }

if qvm-check "$DST" >/dev/null 2>&1; then
    log "removing existing $DST"
    qwt_shutdown "$DST" 600 || { log "$DST did not halt in 600s - killing it (it is being removed anyway)"; timeout 60 qvm-kill "$DST" >/dev/null 2>&1; }
    timeout 300 qvm-remove -f "$DST" >/dev/null 2>&1 || { log "FAIL: could not remove $DST"; exit 1; }
fi

log "creating $DST (class $CLASS)"
qvm-create --class "$CLASS" --label red "$DST" || { log "FAIL: create"; exit 1; }
# TAG IMMEDIATELY - this is the entire reason qvm-clone cannot be used. Everything below needs it.
qvm-tags "$DST" add win-idd-testbed || { log "FAIL: tag"; exit 1; }

log "copying volumes and settings (this is the slow part)"
python3 - "$SRC" "$DST" <<'PY' || exit 1
import sys, qubesadmin
app = qubesadmin.Qubes()
src, dst = app.domains[sys.argv[1]], app.domains[sys.argv[2]]
for v in ('root', 'private'):
    try:
        dst.volumes[v].clone(src.volumes[v])
        print('  volume %s cloned' % v)
    except Exception as e:
        print('  FAIL cloning volume %s: %s' % (v, e)); raise SystemExit(1)
for p in ('virt_mode', 'kernel', 'memory', 'maxmem', 'vcpus', 'qrexec_timeout', 'netvm', 'default_user'):
    try:
        setattr(dst, p, getattr(src, p))
    except Exception as e:
        print('  note: pref %s not copied (%s)' % (p, e))
for f in ('os', 'gui', 'qrexec', 'stubdom-qrexec', 'vmexec', 'audio-model', 'timezone',
          'no-monitor-layout', 'rpc-clipboard', 'gui-emulated'):
    try:
        dst.features[f] = src.features[f]
    except KeyError:
        pass
# A PARKED SOURCE MUST NOT PARK THE CLONE. Checkpoints are stored with their resources wound
# down to save host RAM - ckpt-win11de-gwt-pretuesday sits at memory=400, vcpus=2 - and copying
# prefs verbatim hands that to a guest which then has to BOOT WINDOWS. Measured 2026-09-21:
# win11de-ctlc came up with 400 MB and no ballooning (maxmem=0), went deaf during its install,
# and cost a staged-pending proof plus an incorrect self-diagnosis about host pressure. A clone
# is made to RUN, so give it runnable resources whenever the source's are below what a Windows
# guest needs. Override with CLONE_MEMORY / CLONE_VCPUS.
import os
want_mem = int(os.environ.get('CLONE_MEMORY') or 8192)
want_cpu = int(os.environ.get('CLONE_VCPUS') or 4)
try:
    if int(getattr(dst, 'memory', 0) or 0) < want_mem:
        print('  source is PARKED at memory=%s - raising the clone to %d' % (getattr(src, 'memory', '?'), want_mem))
        dst.memory = want_mem
    if int(getattr(dst, 'vcpus', 0) or 0) < want_cpu:
        dst.vcpus = want_cpu
except Exception as e:
    print('  note: could not raise resources (%s)' % e)
print('  prefs and features copied')
PY

# The private volume must be at least as large as the source's, or Q:\Users does not fit and
# qubes.Filecopy fails with "getting Documents path failed" - nothing can be pushed to the guest.
SP=$(qvm-volume info "$SRC":private 2>/dev/null | awk '/^size/{print $2}')
DP=$(qvm-volume info "$DST":private 2>/dev/null | awk '/^size/{print $2}')
if [ -n "${SP:-}" ] && [ -n "${DP:-}" ] && [ "$DP" -lt "$SP" ]; then
    log "extending $DST:private $((DP/1073741824))GiB -> $((SP/1073741824))GiB"
    qvm-volume extend "$DST":private "$SP" || { log "FAIL: extend private"; exit 1; }
fi

log "done: $DST is a $CLASS clone of $SRC, tagged win-idd-testbed, Halted"
qvm-ls --raw-data --fields NAME,CLASS,STATE "$DST"
