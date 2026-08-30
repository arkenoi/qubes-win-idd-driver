#!/bin/bash
# PROVE THE PRIMER CHANNEL WORKS - clone a base golden, attach a job stick, and read the result
# off the SCREEN, because a primed guest is pristine Windows with no QWT and therefore no qrexec.
#
# Run this BEFORE trusting any real prime job. If the channel is broken, a real job (stock-422,
# ours-nopvdisk) fails in a way that looks like an installer defect and costs a day chasing the
# wrong layer - which is precisely how the 1603 hunt began.
#
# Usage: mgmt/prime-selftest.sh <base-golden> [churn-qube] [job]
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE" || exit 1
BASE="${1:?usage: $0 <base-golden> [churn-qube] [job]}"
CHURN="${2:-prime-selftest}"
JOB="${3:-selftest}"
HOLDER=win-idd-mgmt
STICKIMG=/home/user/win-iso/answer-usb.img
log(){ echo "$(date -u +%H:%M:%S) prime-selftest: $*"; }
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

# H3.6: never with another Windows guest running.
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2!="Halted" && $1 ~ /^win(10|11)/ {print $1}' | tr '\n' ' ')
[ -z "${running// /}" ] || { log "REFUSING: not Halted: $running"; exit 1; }

# The golden must be intact before we clone it, and cloning must not disturb it.
mgmt/golden.sh verify "$BASE" || { log "REFUSING: $BASE failed its seal check"; exit 1; }
[ "$(state "$BASE")" = Halted ] || { log "REFUSING: $BASE is not Halted"; exit 1; }

STICKSIZE=$(( $(stat -c%s "$STICKIMG") / 1024 / 1024 ))
log "building the '$JOB' job stick into $STICKIMG (${STICKSIZE}M, size must not change - the loop caches capacity)"
PRIME_JOB="mgmt/prime-jobs/$JOB" OUT="$STICKIMG" SIZE_MB="$STICKSIZE" \
    mgmt/build-answer-stick.sh >/dev/null || { log "FAIL: stick build"; exit 1; }
STICKLOOP=$(losetup -l | awk -v f="$STICKIMG" '$6==f{sub("/dev/","",$1); print $1; exit}')
[ -n "$STICKLOOP" ] || { log "FAIL: $STICKIMG is not on a loop device"; exit 1; }
log "job stick on /dev/$STICKLOOP"

log "recreating churn qube $CHURN from $BASE"
qvm-remove -f "$CHURN" >/dev/null 2>&1
# create -> TAG -> copy volumes. qvm-clone in one shot fails here: it copies volumes before tags
# exist, and policy is tag-based, so the volume call hits a qube policy does not yet cover.
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$CHURN" || exit 1
qvm-tags "$CHURN" add win-idd-testbed || exit 1
qvm-features "$CHURN" os Windows
for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:300; do qvm-prefs "$CHURN" "${p%%:*}" "${p##*:}"; done
qvm-prefs "$CHURN" netvm '' 2>/dev/null
python3 - "$BASE" "$CHURN" <<'EOF' || exit 1
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
EOF
log "cloned"

log "attaching the job stick as an emulated USB device"
qvm-features "$CHURN" qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99' || exit 1
qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$CHURN" "$HOLDER:$STICKLOOP" || exit 1

SHOTDIR="$HERE/evidence/prime-selftest-$CHURN-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$SHOTDIR"
log "booting $CHURN - the hook should fire, run the job, and reboot"
qvm-start "$CHURN" >/dev/null 2>&1

# The job reboots the guest, and on_reboot=destroy means that HALTS it. Restarting is this script's
# job - it is the sole owner of this guest for the duration (protocol 0.8: one owner per guest).
t0=$(date +%s); restarts=0
while [ $(( $(date +%s) - t0 )) -lt 900 ]; do
    sleep 30
    st=$(state "$CHURN")
    if [ "$st" = Halted ]; then
        restarts=$((restarts+1))
        log "  guest halted (the job rebooted it) - restart #$restarts"
        qvm-start "$CHURN" >/dev/null 2>&1
        continue
    fi
    rm -f "$SHOTDIR"/s.tar "$SHOTDIR"/win-*.png 2>/dev/null
    if QTEST_VM=$CHURN timeout 90 ./tools/qtest shot "$SHOTDIR/s.tar" >/dev/null 2>&1; then
        tar -xf "$SHOTDIR/s.tar" -C "$SHOTDIR" 2>/dev/null
        big=$(ls -S "$SHOTDIR"/*.png 2>/dev/null | head -1)
        [ -n "$big" ] && cp "$big" "$SHOTDIR/latest.png"
    fi
    log "  t+$(( $(date +%s) - t0 ))s state=$st restarts=$restarts"
    [ "$restarts" -ge 1 ] && [ $(( $(date +%s) - t0 )) -ge 240 ] && break
done

log "READ $SHOTDIR/latest.png"
log "  PASS looks like: Notepad showing 'PRIMER SELFTEST PASSED', whoami = nt authority\\system,"
log "  and 'QubesPrime' reported as NOT FOUND (the hook unregisters itself before running a job)."
log "  A bare desktop with no Notepad means the hook did NOT fire - the channel is broken."
exit 3
