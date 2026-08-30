#!/bin/bash
# PRIME-RUN — drive a prime job into a clone of a sealed base golden, and hand back a guest that
# answers qrexec.
#
# WHY THIS EXISTS. Three separate campaign fixtures (clean install of N, our previous release for
# the C3 upgrade, stock 4.2.2 for C4) all need the identical sequence: verify the base seal, stage a
# payload, build a job stick, clone, attach, boot, survive the job's own reboots, then wait for the
# guest to come back with QWT running. `mgmt/prime-selftest.sh` already does the first half but ends
# by asking a human to read a screenshot, because the guest it produces has no qrexec by design.
# Writing that sequence three more times by hand is exactly what protocol H0 forbids
# ("The harness already exists. Do not write another one. If a primitive is missing, ADD IT").
#
# WHAT IT DOES NOT DO. It does not grade the install. It gets a guest to the point where the cell
# can be graded through qrexec, prints where the evidence is, and stops. Grading belongs to the
# cell, which knows what it asked for.
#
#   mgmt/harness/prime-run.sh <base-golden> <churn-qube> <job> [--payload DIR] [--flag NAME]...
#
#     --payload DIR   copy DIR to mgmt/prime-jobs/<job>/setup before building the stick (the jobs
#                     expect a setup\ tree; it is release-specific and deliberately uncommitted)
#     --flag NAME     touch mgmt/prime-jobs/<job>/NAME before building (e.g. --flag c12.flag)
#     --deadline SEC  overall budget, default 3600. NEVER unbounded (H2).
#
# Exits: 0 = guest is up and answering qrexec; 1 = TERMINAL (refused preconditions, clone/stick/boot
# failure, guest died); 2 = DEADLINE. Every exit says which one it took, so "it did not finish" can
# never be read as "it worked".
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

BASE=""; CHURN=""; JOB=""; PAYLOAD=""; DEADLINE=3600; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --payload)  PAYLOAD="$2"; shift 2 ;;
    --flag)     FLAGS+=("$2"); shift 2 ;;
    --deadline) DEADLINE="$2"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 1 ;;
    *)  if   [ -z "$BASE"  ]; then BASE="$1"
        elif [ -z "$CHURN" ]; then CHURN="$1"
        elif [ -z "$JOB"   ]; then JOB="$1"
        else echo "unexpected argument $1" >&2; exit 1; fi; shift ;;
  esac
done
[ -n "$BASE" ] && [ -n "$CHURN" ] && [ -n "$JOB" ] || {
  echo "usage: $0 <base-golden> <churn-qube> <job> [--payload DIR] [--flag NAME] [--deadline SEC]" >&2
  exit 1; }

HOLDER=win-idd-mgmt
STICKIMG=/home/user/win-iso/answer-usb.img
JOBDIR="mgmt/prime-jobs/$JOB"
log(){ echo "$(date -u +%H:%M:%S) prime-run[$CHURN]: $*"; }
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

[ -f "$JOBDIR/onboot.cmd" ] || { log "TERMINAL: no job at $JOBDIR/onboot.cmd"; exit 1; }

# H3.6 — one Windows guest at a time, and a campaign step starts with zero. Concurrent runs have
# rebooted each other's guests and destroyed hours of results.
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null \
          | awk -F'|' '$2!="Halted" && $1 ~ /^(win(10|11)|prime-)/ {print $1}' | tr '\n' ' ')
[ -z "${running// /}" ] || { log "TERMINAL: refusing, these are not Halted: $running"; exit 1; }

# Golden custody (0.4). An unsealed or drifted base fails CLOSED: every clone would inherit
# whatever changed, silently.
./mgmt/golden.sh verify "$BASE" || { log "TERMINAL: $BASE failed its seal check"; exit 1; }
[ "$(state "$BASE")" = Halted ] || { log "TERMINAL: $BASE is not Halted"; exit 1; }

# --- stage the payload and flags into the job -----------------------------------------------
if [ -n "$PAYLOAD" ]; then
  [ -d "$PAYLOAD" ] || { log "TERMINAL: --payload $PAYLOAD is not a directory"; exit 1; }
  rm -rf "$JOBDIR/setup"
  cp -r "$PAYLOAD" "$JOBDIR/setup" || { log "TERMINAL: could not stage payload"; exit 1; }
  # The jobs run C:\qwtsetup\install.cmd; if the tree has no install.cmd at its root the job dies
  # in-guest where nothing can see it. Fail here instead, where the message is readable.
  [ -f "$JOBDIR/setup/install.cmd" ] || {
    log "TERMINAL: staged payload has no install.cmd at its root ($JOBDIR/setup)"; exit 1; }
  log "payload staged: $(find "$JOBDIR/setup" -type f | wc -l) files from $PAYLOAD"
fi
# CLEAR STALE FLAGS FIRST. Flags are files in the job directory, and the job directory persists
# between runs - so a run that set c12.flag would leave it there and the NEXT run, which never asked
# for C12, would silently get it too. That is the same class as the stale-payload and stale-log
# traps the harness already guards: state from a previous cell being read as this cell's. Clearing
# is unconditional, so "no --flag" always means "no flags".
for stale in "$JOBDIR"/*.flag; do [ -e "$stale" ] && { rm -f "$stale"; log "cleared stale flag: $(basename "$stale")"; }; done
for f in ${FLAGS+"${FLAGS[@]}"}; do : > "$JOBDIR/$f"; log "flag set: $f"; done

# --- build the job stick ---------------------------------------------------------------------
# The loop device caches the backing file's capacity, so the image size must not change or the
# guest sees a stale geometry.
STICKSIZE=$(( $(stat -c%s "$STICKIMG") / 1024 / 1024 ))
log "building the '$JOB' stick into $STICKIMG (${STICKSIZE}M)"
PRIME_JOB="$JOBDIR" OUT="$STICKIMG" SIZE_MB="$STICKSIZE" \
    ./mgmt/build-answer-stick.sh >"$HERE/.prime-stick.log" 2>&1 || {
    log "TERMINAL: stick build failed - $(tail -3 "$HERE/.prime-stick.log")"; exit 1; }
STICKLOOP=$(losetup -l | awk -v f="$STICKIMG" '$6==f{sub("/dev/","",$1); print $1; exit}')
[ -n "$STICKLOOP" ] || { log "TERMINAL: $STICKIMG is not on a loop device"; exit 1; }
log "stick on /dev/$STICKLOOP"

# --- clone the base --------------------------------------------------------------------------
log "recreating $CHURN from $BASE"
qvm-remove -f "$CHURN" >/dev/null 2>&1
# create -> TAG -> copy volumes, in that order. A single qvm-clone copies volumes before the tags
# exist, and dom0 policy here is TAG-based, so the volume call lands on a qube policy does not yet
# cover and is refused.
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$CHURN" \
  || { log "TERMINAL: could not create $CHURN"; exit 1; }
qvm-tags "$CHURN" add win-idd-testbed || { log "TERMINAL: could not tag $CHURN"; exit 1; }
qvm-features "$CHURN" os Windows
for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$CHURN" "${p%%:*}" "${p##*:}"; done
qvm-prefs "$CHURN" netvm '' 2>/dev/null
python3 - "$BASE" "$CHURN" <<'PY' || { log "TERMINAL: volume clone failed"; exit 1; }
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PY
log "cloned"

qvm-features "$CHURN" qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99' \
  || { log "TERMINAL: could not set qemu-extra-args"; exit 1; }
qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$CHURN" "$HOLDER:$STICKLOOP" \
  || { log "TERMINAL: could not assign the stick"; exit 1; }

OUT="$HERE/evidence/prime-$JOB-$CHURN-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
log "evidence -> $OUT"
log "booting; the job runs as SYSTEM, and its installer reboots - this guest halts on reboot, so"
log "  restarting it is THIS script's job (protocol 0.8: one owner per guest, watchers stay passive)"
qvm-start "$CHURN" >/dev/null 2>&1

# --- drive it to a qrexec-answering state -----------------------------------------------------
# The terminating signal is a POSITIVE fact - the guest answers qrexec - not a timer. Polling is
# >=20 s (H3.9: per-second qrexec churn triggered the IPI-shootdown wedge).
t0=$(date +%s); restarts=0; ready=0
while [ $(( $(date +%s) - t0 )) -lt "$DEADLINE" ]; do
    sleep 20
    el=$(( $(date +%s) - t0 ))
    st=$(state "$CHURN")
    if [ "$st" = Halted ]; then
        restarts=$((restarts+1))
        log "  t+${el}s guest halted (the job rebooted it) - restart #$restarts"
        qvm-start "$CHURN" >/dev/null 2>&1
        continue
    fi
    if QTEST_VM=$CHURN timeout -k 5 45 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null \
         | grep -qa QREADY; then
        ready=1
        log "  t+${el}s QREXEC ANSWERS after $restarts restart(s) - the guest carries a working QWT"
        break
    fi
    log "  t+${el}s state=$st restarts=$restarts (no qrexec yet)"
done

# Capture the job's own log and the installer's, whether or not we succeeded - a failed run's
# evidence is the point of preserving it (H3.5).
if [ "$ready" = 1 ]; then
    for f in 'C:\qubes-prime\ours.log' 'C:\qubes-prime\ours-nopvdisk.log' 'C:\qubes-prime\stock.log' \
             'C:\qwt-improved-install.log'; do
        n=$(basename "${f//\\//}")
        QTEST_VM=$CHURN timeout -k 5 90 ./tools/qtest run "cmd /c type $f" >"$OUT/$n" 2>/dev/null
        [ -s "$OUT/$n" ] && log "  captured $n ($(wc -l <"$OUT/$n") lines)"
    done
fi
QTEST_VM=$CHURN timeout -k 5 90 ./tools/qtest shot "$OUT/screen.tar" >/dev/null 2>&1 \
  && tar -xf "$OUT/screen.tar" -C "$OUT" 2>/dev/null

echo "restarts=$restarts" > "$OUT/prime-run.meta"
echo "job=$JOB base=$BASE churn=$CHURN" >> "$OUT/prime-run.meta"

# --- fixture provenance record ----------------------------------------------------------------
# Campaign fixtures are NOT sealed goldens (owner 2026-08-30: "we are not going to keep them
# forever as golden untouchables"), so `golden.sh verify` can never pass for one - it fails closed
# on anything unsealed, correctly. But the concern the seal exists for is still real: no cell may
# clone from a source of unknown provenance.
#
# A fixture's provenance is established by CONSTRUCTION rather than by a seal: it was built minutes
# ago, by this script, from a base golden whose seal was verified before the clone. Recording that
# lets `golden.sh fixture` re-check it later - and re-verify the BASE's seal at that moment, so a
# fixture whose base has since drifted stops being acceptable too. The record is per-campaign and
# dies with the fixture; it is not custody, it is a receipt.
if [ "$ready" = 1 ]; then
  mkdir -p "$HERE/mgmt/fixtures"
  python3 - "$CHURN" "$BASE" "$JOB" "$OUT" "${FLAGS[*]:-}" \
      > "$HERE/mgmt/fixtures/$CHURN.json" <<'PY'
import json, subprocess, sys, os
churn, base, job, out, flags = sys.argv[1:6]
seal = f"mgmt/goldens/{base}.json"
base_sealed = json.load(open(seal))["sealed_utc"] if os.path.exists(seal) else None
print(json.dumps({
    "vm": churn, "base": base, "base_sealed_utc": base_sealed, "job": job,
    "flags": flags.split() if flags else [],
    "evidence": os.path.basename(out),
    "built_utc": subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"],
                                capture_output=True, text=True).stdout.strip(),
}, indent=2, sort_keys=True))
PY
  log "fixture record -> mgmt/fixtures/$CHURN.json (base $BASE, job $JOB)"
fi

if [ "$ready" != 1 ]; then
    log "DEADLINE: ${DEADLINE}s elapsed with no qrexec after $restarts restart(s)."
    log "  Guest LEFT RUNNING and NOT removed - its state is the evidence (H3.5). Read $OUT."
    exit 2
fi
log "OK: $CHURN is up. Evidence in $OUT. The stick is still assigned --required and"
log "  qemu-extra-args is still set - clear both before using this guest as a cell subject."
exit 0
