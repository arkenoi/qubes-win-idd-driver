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
# EVERY LINE DECLARES ITS LEVEL - same reason as quick-upgrade.sh and matrix.sh: a gate that can
# only judge tagged lines is blind to the rest, and it will not gate until its coverage is real.
log(){ case "$*" in
         "[ERROR]"*|"[WARN]"*|"[WARNING]"*|"[INFO]"*|"[DEBUG]"*) _m="$*" ;;
         *) _m="[INFO] $*" ;;
       esac
       echo "$(date -u +%H:%M:%S) prime-run[$CHURN]: $_m"; }
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }

# --- lifecycle (run-lib.sh): a killed prime-run must leave NO orphans and a MARKED subject ---
# 2026-09-06, observed live: killing the calling harness left THIS script + its `sleep`s
# orphaned to init for 40+ minutes, churning the guest (and, under the old fd-inheriting
# vmlock, holding the dead job's guest lock). job_init's traps now TERM/KILL prime-run's own
# descendant tree on any exit. The abort hook fires ONLY on signals: a TERMINAL/DEADLINE exit
# still leaves the guest untouched as evidence (H3.5), but a kill mid-prime means the subject
# is half-built - it gets a CONTAMINATED marker (owner rule: never reuse a killed subject; the
# next prime-run recreates it from the sealed base and clears the marker after the clone).
source mgmt/harness/run-lib.sh
source mgmt/harness/prime-rescue-lib.sh   # rescue_quiet_step / rescue_noshow_step / rescue_should_fire
source mgmt/harness/logvol-lib.sh         # the secondary log volume: QWT's logs readable from THIS qube, with no guest
source mgmt/harness/rtc-lib.sh            # w_rtc_utc: called at line ~537 and UNRESOLVED until 2026-10-14, because it lived in e2e-wait.sh

# cpu_time is CUMULATIVE - flat across a sample means the domain is not executing. Local copy so
# prime-run stays independent of e2e-wait.sh, which it does not source. UNREADABLE = MOVING: a
# failed stats read must never manufacture a stall verdict.
_pr_cpu_time(){ printf '' | timeout 15 qrexec-client-vm "$1" admin.vm.Stats 2>/dev/null \
                | tr '\0' '\n' | awk '/^cpu_time$/{getline v; print v; exit}'; }
_pr_cpu_flat(){ local a b
  a=$(_pr_cpu_time "$1"); [ -n "$a" ] || return 1
  sleep "${2:-20}"
  b=$(_pr_cpu_time "$1"); [ -n "$b" ] || return 1
  [ "$a" = "$b" ]
}
# Three-way, and it reports the DELTA - same contract as e2e-wait.sh's w_cpu_state, duplicated here
# because prime-run deliberately does not source that file. "UNREADABLE" must never be logged as a
# measurement: callers printed "the guest IS EXECUTING" about domains that returned nothing at all.
# Echoes "FLAT 0" | "MOVING <delta>" | "UNREADABLE -".
_pr_cpu_state(){ local a b
  a=$(_pr_cpu_time "$1"); [ -n "$a" ] || { echo "UNREADABLE -"; return 0; }
  sleep "${2:-20}"
  b=$(_pr_cpu_time "$1"); [ -n "$b" ] || { echo "UNREADABLE -"; return 0; }
  if [ "$a" = "$b" ]; then echo "FLAT 0"; else echo "MOVING $(( b - a ))"; fi
}

job_init prime-run
job_on_abort(){
  [ -n "${CHURN:-}" ] || return 0
  mkdir -p mgmt/fixtures
  printf '{"vm":"%s","aborted_utc":"%s","via":"%s","note":"killed mid-prime - CONTAMINATED, never grade or reuse; re-run prime-run to recreate from the base"}\n' \
      "$CHURN" "$(date -u +%FT%TZ)" "$1" > "mgmt/fixtures/$CHURN.aborted"
  log "ABORTED mid-prime ($1): $CHURN is CONTAMINATED - marker mgmt/fixtures/$CHURN.aborted written; best-effort shutdown of the churn guest"
  qvm-shutdown "$CHURN" >/dev/null 2>&1
}

[ -f "$JOBDIR/onboot.cmd" ] || { log "[ERROR] TERMINAL: no job at $JOBDIR/onboot.cmd"; exit 1; }

# H3.6 — one Windows guest at a time, and a campaign step starts with zero. Concurrent runs have
# rebooted each other's guests and destroyed hours of results.
# THE CHURN ITSELF IS EXCLUDED (2026-09-06): this script is about to `qvm-remove -f` it and
# recreate it from the base, so a subject a previous run left Running is not a concurrent job -
# it is the thing being discarded. Refusing on it made every leftover a manual unblock. Every
# OTHER running win*/prime- guest still refuses.
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null \
          | awk -F'|' -v churn="$CHURN" '$2!="Halted" && $1!=churn && $1 ~ /^(win(10|11)|prime-)/ {print $1}' | tr '\n' ' ')
[ -z "${running// /}" ] || { log "[ERROR] TERMINAL: refusing, these are not Halted: $running"; exit 1; }

# Golden custody (0.4). An unsealed or drifted base fails CLOSED: every clone would inherit
# whatever changed, silently.
./mgmt/golden.sh verify "$BASE" || { log "[ERROR] TERMINAL: $BASE failed its seal check"; exit 1; }
[ "$(state "$BASE")" = Halted ] || { log "[ERROR] TERMINAL: $BASE is not Halted"; exit 1; }

# --- stage the payload and flags into the job -----------------------------------------------
if [ -n "$PAYLOAD" ]; then
  [ -d "$PAYLOAD" ] || { log "[ERROR] TERMINAL: --payload $PAYLOAD is not a directory"; exit 1; }
  # A PAYLOAD COPIED OFF AN ISO IS READ-ONLY, and so is the staging copy made from it: iso9660
  # gives every file mode 444 and every directory 555, `cp` carries that across, and the next run's
  # `rm -rf` then fails on each file while REPORTING only the symptom it hits afterwards ("staged
  # payload has no install.cmd at its root"). Measured 2026-10-14 staging the 4.3.35 release's own
  # setup tree as the N-1 entry payload: two launches lost to it. Make the tree writable before
  # removing it, and after copying, so neither end of the cycle depends on the source's modes.
  [ ! -e "$JOBDIR/setup" ] || chmod -R u+w "$JOBDIR/setup" 2>/dev/null
  rm -rf "$JOBDIR/setup"
  cp -r "$PAYLOAD" "$JOBDIR/setup" || { log "[ERROR] TERMINAL: could not stage payload"; exit 1; }
  chmod -R u+w "$JOBDIR/setup" 2>/dev/null
  # The jobs run C:\qwtsetup\install.cmd; if the tree has no install.cmd at its root the job dies
  # in-guest where nothing can see it. Fail here instead, where the message is readable.
  [ -f "$JOBDIR/setup/install.cmd" ] || {
    log "[ERROR] TERMINAL: staged payload has no install.cmd at its root ($JOBDIR/setup)"; exit 1; }
  log "payload staged: $(find "$JOBDIR/setup" -type f | wc -l) files from $PAYLOAD"
fi
# CLEAR STALE FLAGS FIRST. Flags are files in the job directory, and the job directory persists
# between runs - so a run that set c12.flag would leave it there and the NEXT run, which never asked
# for C12, would silently get it too. That is the same class as the stale-payload and stale-log
# traps the harness already guards: state from a previous cell being read as this cell's. Clearing
# is unconditional, so "no --flag" always means "no flags".
for stale in "$JOBDIR"/*.flag; do [ -e "$stale" ] && { rm -f "$stale"; log "cleared stale flag: $(basename "$stale")"; }; done
for f in ${FLAGS+"${FLAGS[@]}"}; do : > "$JOBDIR/$f"; log "flag set: $f"; done

# ATTACH A LOOP WITHOUT ROOT. This script used to REQUIRE the image to be on a loop already and
# die with "is not on a loop device" otherwise - a state a human had to fix with sudo losetup. But
# mgmt/harness/matrix.sh has done it root-free for months via udisksctl, and the blocker was only
# ever a missing call here. Measured 2026-09-21: /dev/loop0 backing the answer stick disappeared
# between campaigns, so the churn guest kept the assignment, libxenlight could not create the
# domain, and the restart loop above blamed the PRODUCT for "crash-looping" nine times over.
ensure_loop(){ # $1=image, $2=ro|rw -> prints loopN
    local img=$1 mode=${2:-rw} dev
    dev=$(losetup -l 2>/dev/null | awk -v f="$img" '$6==f{sub("/dev/","",$1); print $1; exit}')
    if [ -n "$dev" ] && [ -e "/dev/$dev" ]; then printf '%s' "$dev"; return 0; fi
    local ro=(); [ "$mode" = ro ] && ro=(-r)
    dev=$(udisksctl loop-setup "${ro[@]}" -f "$img" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
    [ -n "$dev" ] || return 1
    printf '%s' "${dev#/dev/}"
}

# --- build the job stick ---------------------------------------------------------------------
# The loop device caches the backing file's capacity, so the image size must not change or the
# guest sees a stale geometry.
STICKSIZE=$(( $(stat -c%s "$STICKIMG") / 1024 / 1024 ))
log "building the '$JOB' stick into $STICKIMG (${STICKSIZE}M)"
PRIME_JOB="$JOBDIR" OUT="$STICKIMG" SIZE_MB="$STICKSIZE" \
    ./mgmt/build-answer-stick.sh >"$HERE/.prime-stick.log" 2>&1 || {
    log "[ERROR] TERMINAL: stick build failed - $(tail -3 "$HERE/.prime-stick.log")"; exit 1; }
STICKLOOP=$(ensure_loop "$STICKIMG" ro)
[ -n "$STICKLOOP" ] || { log "[ERROR] TERMINAL: could not attach $STICKIMG to a loop device"; exit 1; }
log "stick on /dev/$STICKLOOP"

# --- clone the base --------------------------------------------------------------------------
log "recreating $CHURN from $BASE"
# A SPECIMEN IS NOT A LEFTOVER. This is the most destructive path in the harness - it kills and then
# qvm-removes the subject - and it consulted nothing before doing it. On 2026-10-20 a reliably
# captured wedge was lost because a campaign recreated the guest two minutes after it was
# classified; this is the shape of that loss.
#
# The guard uses specimen-lib, which is the LIVE mechanism: matrix.sh and e2e-wait.sh write the
# marker and tools/hooks/golden-boot-gate.sh reads it. mgmt/harness/evidence-lock.sh looks like it
# exists for exactly this, but MEASURED 2026-10-21: all five of its functions (ev_lock, ev_locked,
# ev_release, ev_reap, ev_lock_survivors) have ZERO consumers and no file sources it. Wiring a
# second, dead source of truth beside a working one would make two things to forget instead of one,
# so that library's fate is the owner's call and is filed, not decided here.
#
# Hard fail with the way out named, never a silent skip: a run that would destroy evidence must stop
# and say so. `specimen_clear` is the deliberate release, which is what a real recreate uses.
# THE GUARD MUST NOT BE SKIPPABLE BY ITS OWN FAILURE. This read
#     if type specimen_mark || source mgmt/harness/specimen-lib.sh 2>/dev/null; then
# so if the relative source failed for any reason - a wrong working directory, the file moved, a
# syntax error introduced in it - and specimen_mark was not already defined, the WHOLE block below
# including its TERMINAL exit was skipped with no line in the log, and the run fell straight through
# into killing and qvm-remove-ing a guest held as evidence. That is this harness's own most
# destructive path and this check is the only thing in front of it. A guard that disappears when its
# own library fails to load is not a guard. So: load it, and if it cannot be loaded, STOP.
# PRIME-EVIDENCE-GUARD-A   (the range between this marker and the B one is extracted and executed
# by tools/tests/specimen-not-a-leftover-selftest.sh; neither marker names the other, because a
# marker mentioned in prose closes its own range)
if ! type specimen_mark >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/specimen-lib.sh" \
      || { log "[ERROR] TERMINAL: cannot load specimen-lib.sh, so whether $CHURN is held as"; \
           log "  evidence cannot be determined - and the next step kills and removes it."; \
           exit 1; }
fi
for _fn in specimen_file specimen_why; do
    type "$_fn" >/dev/null 2>&1 || { log "[ERROR] TERMINAL: specimen-lib.sh loaded but $_fn is missing"; exit 1; }
done
if [ -f "$(specimen_file "$CHURN")" ]; then
    log "[ERROR] TERMINAL: $CHURN is held as EVIDENCE and this step would kill and remove it."
    log "  reason recorded: $(specimen_why "$CHURN" 2>/dev/null)"
    log "  Take what you need first, then release it deliberately:"
    log "    source mgmt/harness/specimen-lib.sh && specimen_clear $CHURN"
    exit 1
fi
# PRIME-EVIDENCE-GUARD-B
# A leftover churn that is still Running cannot be removed; kill it first. This is the one place
# a kill is permitted: its state is being discarded (volumes replaced by the clone below), so
# nothing that will be graded can be corrupted by it. It is NOT a way to stop a run.
if [ -n "$(state "$CHURN")" ] && [ "$(state "$CHURN")" != Halted ]; then
    log "leftover $CHURN is $(state "$CHURN") - killing it (being discarded, not reused)"
    qvm-kill "$CHURN" >/dev/null 2>&1
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(state "$CHURN")" = Halted ] && break; sleep 10; done
    [ "$(state "$CHURN")" = Halted ] || { log "[ERROR] TERMINAL: leftover $CHURN would not halt after qvm-kill"; exit 1; }
fi
qvm-remove -f "$CHURN" >/dev/null 2>&1
# create -> TAG -> copy volumes, in that order. A single qvm-clone copies volumes before the tags
# exist, and dom0 policy here is TAG-based, so the volume call lands on a qube policy does not yet
# cover and is refused.
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$CHURN" \
  || { log "[ERROR] TERMINAL: could not create $CHURN"; exit 1; }
qvm-tags "$CHURN" add win-idd-testbed || { log "[ERROR] TERMINAL: could not tag $CHURN"; exit 1; }
qvm-features "$CHURN" os Windows
# timezone: without it the RTC holds TRUE UTC while Windows reads it as LOCAL, so a
# non-UTC guest computes a UTC behind real UTC by its own offset and CI-minted driver
# catalogs come out not-yet-valid (0x800B0101, a 25-minute silent drvinst hang,
# measured 2026-09-25). The goldens carry timezone=localtime; a create path that copies
# only the volumes did not, so the subject differed from its golden in exactly that.
# SET `timezone=localtime` AT CREATE TIME, BEFORE THE GUEST EVER BOOTS. Xen reads this at DOMAIN
# CREATION and puts dom0's LOCAL time on the emulated clock; absent, it defaults to true UTC. dom0
# sets it by itself for any Windows qube - but only once the GUEST has reported os+qrexec, which
# cannot happen before the first install, so a qube created without it spends its whole install on a
# true-UTC clock and then has the clock change under it one boot later. That transition is the
# ENTIRE source of clock_boot_correction_s = 10800: one boot reading a UTC clock through dom0's
# zone (3 h behind), the next reading a dom0-local clock through a convention latched from the
# first (3 h ahead). Setting it here removes THAT window instead of converging out of it - the clock
# holds dom0 local on every boot, Windows reads it as local on every boot (its default; we declare
# nothing), and the guest's zone is dom0's on every boot.
# "NOTHING TO SETTLE" IS WHAT THIS SAID UNTIL 2026-10-25, AND A DST TRANSITION FALSIFIES IT. Windows
# converts the localtime RTC with the ActiveTimeBias ALREADY STORED in its registry, then refreshes
# that bias for today WITHOUT moving the clock it just set. So a base sealed in summer (bias -180)
# booted after the autumn transition reads dom0's winter local time (UTC+2) as if it were UTC+3:
# internal UTC lands one hour BEHIND real UTC and the displayed local clock reads UTC+1. It then
# stays behind, because a guest an hour short of its own 04:00 transition never reaches it. ONE
# successful set-time puller run breaks the loop - and the puller needs qrexec, so a subject whose
# install failed (win10-rc1, installer rc=10, qwt-logs EMPTY) runs the whole prime at UTC+1 and
# every stamp it writes is an hour short of this log's UTC. See ETWCLOCKDST in findings/issues.md;
# the two-sided catch is log-sweep's `windowunusable`, which is unconditional for exactly this sign.
# This is also what a user's qube ends up with, so it is the configuration to test, not a shortcut.
qvm-features "$CHURN" timezone localtime >/dev/null 2>&1 || true

for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$CHURN" "${p%%:*}" "${p##*:}"; done
qvm-prefs "$CHURN" netvm '' 2>/dev/null
python3 - "$BASE" "$CHURN" <<'PY' || { log "[ERROR] TERMINAL: volume clone failed"; exit 1; }
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PY
log "cloned"
# The subject was just recreated from the verified base: any CONTAMINATED marker a previous
# aborted prime left for this name is now about a qube that no longer exists.
rm -f "mgmt/fixtures/$CHURN.aborted"

# TWO STICKS, ONE JOB EACH (owner, 2026-09-07). The ANSWER stick is the medium under test and is
# attached READ-ONLY, exactly as a primed guest gets it. Making it writable to carry diagnostics -
# which is what this line did for a day - changes the configuration being tested and lets a guest
# write corrupt the FAT the next run reads. Stage markers go on a SEPARATE writable DIAG stick
# (xvdj, below), so observing the prime cannot alter it.
# The DIAG volume rides the SAME xhci controller as a second REMOVABLE usb-storage device. It has
# to be removable: both images are "superfloppies" (a FAT filesystem at sector 0, no partition
# table), and Windows mounts that layout on REMOVABLE media only. Attached as a plain Xen block
# disk it showed up as disk4, Online and writable, with NO volume and NO drive letter - so the
# job's label scan found nothing and wrote no markers (measured 2026-09-07 on win11-2stk).
# THE ANSWER STICK AND ITS CONTROLLER ONLY. The evidence stick's own -drive and usb-storage are
# added by logvol_attach below, which COMPOSES onto this value - so declaring xvdj here too put TWO
# drives on one frontend and qemu refused the domain outright: "libxenlight failed to create new
# domain", measured 2026-10-15 the first time the collapsed single stick was used. The old
# `diagdrv` fragment existed because prime-run attached its own DIAG volume; it does not any more.
# THROUGH THE GUARDED WRITER (logvol-lib), which refuses on a live domain. Here it always passes -
# this subject was just removed and recreated, so it is Halted - and that is the point: the one
# writer means a future change that moved this call after a start would be REFUSED instead of
# silently describing a device set the running domain does not have. Owner 2026-10-25: "no rewriting
# arguments on the fly."
# THE PRIMING PHASE, from the one declaration in logvol-lib. This used to be the fragment written
# out literally here, while matrix.sh carried a pattern to strip it and logvol-smoke composed its
# own - three copies of one fact, which is how they drifted and how a judged boot came to reference
# an unassigned loop. logvol_devices_apply composes the WHOLE value and refuses off a boundary; the
# subject was just removed and recreated, so it is Halted and this passes.
logvol_devices_apply "$CHURN" priming \
  || { log "[ERROR] TERMINAL: could not apply the priming device set"; exit 1; }
# NOT --required, MEASURED 2026-09-21. A `--required` assignment cannot be satisfied at domain
# creation on this rig at present: with one the domain is not created at all (6/6, across two
# subjects, a loop the guest had never seen, a different frontend slot, a different devtype, and a
# BRAND-NEW loop from a fresh backing file), while with nothing assigned it is created (4/4) and a
# LIVE attach of the same device to the same running guest is accepted. That failure is NOT
# understood - the reason is in dom0's libxl-driver.log, unreadable from here (findings/rig.md) -
# so this is a WORKAROUND, not a fix, and it must not be read as one.
# A plain assign auto-attaches: measured on win11-once, the domain is CREATED and the device is
# genuinely ATTACHED. What it gives up is --required's guarantee that the guest will not start
# WITHOUT its medium, and a stickless boot is exactly what makes a provisioning run look like a
# product failure - so that guarantee is re-imposed below, after the start, by assertion.
# MECHANIZED, not hand-rolled. PRIME_ASSIGN_MODE=required restores the historical `--required`
# so the question "does --required still work through THIS path" is answerable by running the
# harness, not by reconstructing it in a scratch script. That distinction is the whole lesson of
# 2026-09-21: --required succeeded through this harness at 12:07:17 and failed in every hand-built
# test afterwards, and I compared my reconstruction against itself and concluded dom0 had changed.
# Jev rated that claim 0.28 and the leading reading 'state accumulated after the first start' at
# 0.56 (conf 0.45) - i.e. still open. Default stays `plain`, which is measured to work.
# REVERTED 2026-09-22 to `required`, which is what this harness always used and what works.
# Yesterday's switch to `plain` was the defect, not the workaround: a plain assignment is attached
# AFTER the domain is created, so the stubdomain's qemu never finds /dev/xvdi at startup, the device
# model does not start, and libxl aborts the create - exactly the "Could not open '/dev/xvdi'" in the
# stubdom console and the bare "libxenlight failed to create new domain" outside it. Measured
# 2026-09-22, interleaved, 3 rounds on one subject: --required + qemu-extra-args rc=0 three times,
# plain + the same args rc=1 three times, --required with no args rc=0 three times.
PRIME_ASSIGN_MODE="${PRIME_ASSIGN_MODE:-required}"
_req=(); [ "$PRIME_ASSIGN_MODE" = required ] && _req=(--required)
log "stick assignment mode: $PRIME_ASSIGN_MODE${_req:+ (--required)}"
qvm-device block assign "${_req[@]}" -o frontend-dev=xvdi -o devtype=disk "$CHURN" "$HOLDER:$STICKLOOP" \
  || { log "[ERROR] TERMINAL: could not assign the stick"; exit 1; }

# --- DIAG stick: the instrument, kept off the medium under test --------------------------------
# A pristine base has no QWT, so a stalled prime has no qrexec, no gui-agent log and no xencons -
# every channel dies together and two such failures went unattributed. The job writes its stages to
# this small FAT volume (label DIAG) instead, and the HOST reads them back with mtools needing
# nothing from the guest. It is attached READ-WRITE because it is scratch; the answer stick above
# stays read-only because it is the thing being tested.
# ONE EVIDENCE STICK, carrying the install's markers AND QWT's logs. It used to be two volumes with
# identical plumbing - this DIAG stick, and a second "log volume" whose only difference was that it
# REDIRECTED LogDir and so recorded a drive letter that moved. The owner, seeing them side by side:
# "why the fuck did we need separate log stick when we have the same mechanism working as diag" -
# and he was right: the mechanism here is the one that always worked, because the install resolves
# the drive BY LABEL at write time (`vol %d: | findstr /i "DIAG"`) and stores nothing.
# So there is one image per subject, labelled DIAG, on xvdj, created and tagged by the library (which
# archives the previous contents instead of discarding them) and attached the same way. The guest's
# markers and its logs end up on the same volume, and one host-side read with mtools shows both.
OUT_SETUP="$HERE/evidence/prime-stick-$CHURN.out"
DIAGIMG=$(logvol_image "$CHURN")
if logvol_create "$DIAGIMG" "$CHURN" >>"$OUT_SETUP" 2>&1 \
   && logvol_attach "$CHURN" "$DIAGIMG" "$HERE/evidence/logvol-manifest-$CHURN.json" >>"$OUT_SETUP" 2>&1; then
    log "evidence stick on $LOGVOL_FRONTEND ($DIAGIMG, label $LOGVOL_LABEL) - markers and logs, read with mtools, no guest needed"
else
    # HARD. The stick is the only thing that survives a wedge - a guest that will not halt cannot
    # be asked for its logs, and mtools reads the image with no guest at all. Priming a subject
    # without it produces a guest that cannot be interrogated when it stalls, which is the one
    # case this whole instrument exists for. Blanking DIAGIMG and carrying on is how WIN10-clean
    # of run 39225775322 reached a SPIN wedge on 2026-10-20 with nothing readable inside it.
    # Enforced by lint L29.
    log "[ERROR] evidence stick NOT attached - refusing to prime a subject that cannot be read when it stalls: $(tail -1 "$OUT_SETUP" 2>/dev/null | cut -c1-140)"
    exit 2
fi

OUT="$HERE/evidence/prime-$JOB-$CHURN-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
log "evidence -> $OUT"

# --- THE SECONDARY LOG VOLUME ------------------------------------------------------------------
# QWT's own per-module logs, on a volume THIS qube reads with mtools - guest running, wedged or
# halted. Until 2026-10-14 this path had none: logvol_create/logvol_attach were called from exactly
# one place in matrix.sh (the release-ISO boot), so the CLEAN cell - the one that installs the
# release - ran with no log volume at all, and its grading then reported "guest logs incomplete
# (1 file, 0 QWT lines)" about an instrument that was never there. It could not simply be added
# either: the library's slot was xvdj, which is the DIAG stick above. It has its own now (xvdk),
# and this attach COMPOSES qemu-extra-args rather than overwriting the value set earlier.
# BEFORE THE START, and after qemu-extra-args: a --required assignment is satisfied at domain
# creation, so a volume attached later is invisible to the guest.
# The evidence stick is attached above - there is no second volume any more.
LOGVOL_IMG_PRIME="$DIAGIMG"

# --- LOOK AT THE SCREEN, do not infer from qrexec silence -------------------------------------
# Cost of not doing this, measured 2026-09-08: a clean install froze the guest, the wait below saw
# only "no qrexec" and reported the guest unreachable; I then called the IMAGE permanently broken
# and said a fresh clone of it failed too. Both were wrong. Booted with a camera on it, that same
# disk reaches a full Windows desktop in about seven minutes - it is qrexec that is dead, because
# the interrupted install left the PV stack half-registered. A picture would have said so in one
# poll. The emulated display is the ONLY boot-phase instrument available here: xencons binds only
# after a reboot (so it is absent for exactly the mid-install failures), and EMS/SAC is impossible
# because these HVMs have no UART at all (verified: no Win32_SerialPort, no PnP Ports class, no
# PNP0500/PNP0501 in the firmware tables).
# Per-window capture ONLY (local.WinScreenshot). NEVER fullshot: that photographs the whole dom0
# desktop, every other qube included, and three such captures reached a public repo once already.
mkdir -p "$OUT/screens"
screen_probe() {   # $1=tag -> echoes a one-word verdict, keeps the PNG as evidence
    # SEPARATE `local` statements on purpose: under `set -u` a variable declared in the SAME
    # local statement is not yet visible to a later assignment in it, so `local tag="$1"
    # tar=".../$tag.tar"` aborts the function with "tag: unbound variable" - to stderr, leaving a
    # silent empty result that looks exactly like "no window". Measured 2026-09-08.
    local tag="$1"
    local tar="$OUT/screens/$tag.tar"
    local v=NOWINDOW p
    QTEST_VM=$CHURN timeout -k 5 60 ./tools/qtest shot "$tar" >/dev/null 2>&1 || { echo SHOTFAIL; return; }
    [ -s "$tar" ] || { echo NOWINDOW; return; }
    tar -xf "$tar" -C "$OUT/screens" 2>/dev/null
    p=$(ls -1 "$OUT/screens"/win-*.png 2>/dev/null | head -1)
    [ -n "$p" ] || { echo NOWINDOW; return; }
    mv -f "$p" "$OUT/screens/$tag.png" 2>/dev/null
    rm -f "$OUT/screens"/win-*.png 2>/dev/null
    v=$(python3 tools/winshot.py --png "$OUT/screens/$tag.png" --classify 2>/dev/null | tr -d '\r' | tail -1)
    echo "${v:-UNKNOWN}"
}
log "booting; the job runs as SYSTEM, and its installer reboots - this guest halts on reboot, so"
log "  restarting it is THIS script's job (protocol 0.8: one owner per guest, watchers stay passive)"
# THE RC OF THIS START IS EVIDENCE. It was discarded here (only the RESTART loop below captured
# it, fixed in 0edc9af), so when the domain failed to be created the script walked on to the
# assertion below and reported "the guest started but the answer stick is NOT attached" - naming
# the wrong thing entirely, in two live campaigns. Measured 2026-09-21: the guest had not started
# at all. Capture it, and say what libxl actually said.
declare -F assert_sole_guest >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/serial-rig.sh"
assert_sole_guest "$CHURN" || exit 1
if ! _bootout=$(qvm-start "$CHURN" 2>&1); then
    log "[ERROR] TERMINAL: the DOMAIN WOULD NOT START - the guest never ran, so nothing about the stick,"
    log "  the payload or the product is inferable from this:"
    log "    ${_bootout}"
    exit 1
fi

# --- THE MEDIUM MUST ACTUALLY BE THERE --------------------------------------------------------
# This assertion replaces what `--required` used to guarantee (see the assign above). Without it a
# plain assign that failed to attach would boot the guest with NO answer stick, the job would sit
# waiting for a medium that is not there, and the run would look like a hung or broken guest - which
# is precisely the misreading that cost 2026-09-21. Assert it, name it, and stop.
sleep 15
_attached=$(timeout 90 python3 -c "
import qubesadmin
q=qubesadmin.Qubes(); me=q.domains['$HOLDER']
print(','.join(d.port_id for d in me.devices['block']
                if getattr(getattr(d,'attachment',None),'name','')=='$CHURN') or 'NONE')" 2>/dev/null)
case "$_attached" in
  *"$STICKLOOP"*) log "  answer stick $STICKLOOP is ATTACHED to $CHURN (asserted, not assumed)" ;;
  *) log "[ERROR] TERMINAL: the guest started but the answer stick is NOT attached (attached: ${_attached:-unreadable})."
     log "  A plain assign auto-attaches and this one did not, so the guest is booting with no medium."
     log "  It would sit waiting for a stick that is absent - NOT a guest defect, and not gradeable."
     exit 1 ;;
esac

# --- drive it to a qrexec-answering state -----------------------------------------------------
# The terminating signal is a POSITIVE fact - the guest answers qrexec - not a timer. Polling is
# >=20 s (H3.9: per-second qrexec churn triggered the IPI-shootdown wedge).
#
# THE ONE-SHOT RESCUE REBOOT - BACKUP ONLY, NOT THE NORMAL PATH. On a path that installs the PV
# drivers FRESH they bind only at the guest's NEXT start, so qrexec CANNOT answer in the boot the
# install ran in: the guest must reboot after stage 2. Every job is responsible for that reboot
# itself (stock-422 always did `shutdown /r`; the ours jobs pass `/reboot` -> -RebootAtEnd since
# 2026-09-03), so the normal signal is the guest HALTING, which the restart-on-Halt below turns
# into the qrexec-carrying boot within one poll. Measured cost of relying on the rescue instead:
# the 2026-09-03 prove-ours run sat at "state=Running (no qrexec yet)" from t+134s onward with the
# rescue never firing by t+1083s - the install itself was long finished. The rescue therefore
# exists ONLY for a job that fails its own contract: it fires at most ONCE, RESCUE_AFTER seconds
# after the LAST start AND after RESCUE_QUIET consecutive CPU-quiet reads (see below: 3 reads could
# land inside the resume task's own idle window and interrupt an install still working),
# and the cpu value is logged on every poll line so a rescue that cannot fire is visible in the
# log instead of being discovered after the deadline.
RESCUE_AFTER=${RESCUE_AFTER:-420}
# RESCUE GATES ARE MEASURED FROM THE LAST START, NOT FROM t0, AND NEED 8 QUIET READS (160 s), NOT 3
# (audit 2026-09-08, prime-run.sh:266). The guest is legitimately CPU-quiet for 60 s on the boot
# after stage 1: the resume task is `/SC ONSTART /DELAY 0000:30` (was 0001:00 until 2026-09-08, when
# the named readiness waits - PnP settled, Windows Installer idle - took over the boot-variable part
# of the wait), and stage 2 deletes that task the
# moment it starts (Clear-BootResume). When stage 1 + its reboot ran long, that idle window began
# after t0+420 s, three 20 s polls read cpu<15 while nothing was running yet, and the rescue
# `qvm-shutdown` landed exactly as stage 2 started - task already gone, so the restarted guest never
# ran stage 2 and the run polled "no qrexec yet" to DEADLINE: a false "install never completed" for a
# build that was fine (or a half-installed fixture if it landed mid-msiexec). Stage 2 itself also
# idles 2x30 s on the IDD bind polls. The DIAG marker is no help here: `installer rc=` is written
# when stage 1 RETURNS, i.e. right before its own `shutdown /r`, so it is present throughout the
# very window that must not be interrupted. Hence: no rescue within RESCUE_AFTER of the most
# recent qvm-start, and a quiet streak longer than every known idle window.
RESCUE_QUIET=8
# SECOND, INDEPENDENT RESCUE TRIGGER (2026-09-09): a persistently no-window screen. The CPU-quiet
# gate alone was defeated once when libxl stats went unreadable in the stuck state (see
# prime-rescue-lib.sh) - the quiet streak could never build. A screen that stays SHOTFAIL/NOWINDOW
# is the DIRECT observable of the "IDD activated, emulated VGA gone, PV bus never rebound" stall,
# needs no cpu stats, and is shotfail=0 in every clean-install PASS on record. RESCUE_NOSHOW
# consecutive no-window probes (~60 s apart) past RESCUE_AFTER fire the same one-shot rescue.
RESCUE_NOSHOW=${RESCUE_NOSHOW:-4}
# Terminal, not deadline, when the guest crash-loops: stage1 + stage2 + post-install is at most a
# handful of reboots; a guest that halts more than 8 times is cycling, and restarting it for the
# rest of the budget would just shred the evidence of why.
MAX_RESTARTS=${MAX_RESTARTS:-8}
t0=$(date +%s); restarts=0; ready=0; rescued=0; quiet=0; noshow=0; cpu=-; t_start=$t0
# DID THE AGENT EVER ANSWER IN THIS RUN? The deadline classifier below called a guest
# "EXECUTING-BUT-UNREACHABLE" on the strength of a moving cpu_time plus "qrexec dead for the whole
# deadline" - a conjunction that is ALSO satisfied, vacuously, by a guest whose QWT never installed
# and that therefore never had a channel to lose. Nothing in the script distinguished the two, so
# the one distinction the branch exists to make is the one it could not make. Measured 2026-10-25,
# WIN10-clean of acceptance 40210151847: 111 polls, every one "(no qrexec yet)", none "qrexec up";
# the guest painted screen=VERDICT=DESKTOP 3 s before the deadline, started its onboot job at
# 17:39:45Z (4 s BEFORE the deadline fired) and wrote `installer rc=1` to the DIAG volume at
# 17:41:07Z - 28 s AFTER being declared a P1 SPIN wedge, while its core was being imaged. Its four
# vCPUs were all at STI;HLT;RET with no hypercall at or near RIP. It was never wedged; the install
# failed and the guest was idle. Jev had already priced this exact wording on 2026-09-18:
# moving_establishes_spin 0.05, classifier_wording_is_sound 0.11 - i.e. 0.89 that it WOULD mislabel.
# lastscr carries the most recent screen verdict so PIXELS (a strong conjunct) can outvote cpu_time
# (the weak one) at the deadline instead of being printed beside it and ignored.
qrexec_ever=0; lastscr=-
while [ $(( $(date +%s) - t0 )) -lt "$DEADLINE" ]; do
    sleep 20
    el=$(( $(date +%s) - t0 ))
    st=$(state "$CHURN")
    # QUIET BOOT (QUIET_BOOT_SECS > 0; owner-approved serialize-and-pace, ADR-boot 1; Jev 0.93 after the 2026-10-04 PACED validation):
    # in each boot's first QUIET_BOOT_SECS seconds this script makes NO guest call at all - not even the qrexec detection probe, the
    # rescue evaluation or the cpu stats read. The validation install froze with a qrexec-wrapper held after a grant unmap although
    # the harness had made exactly ONE call in that boot (the detection probe at the first answer, inside stage 2's device work), so a
    # quiet window that starts AFTER the first answer is too late. A halt (a stage ended) is still seen: the state is read from dom0
    # every iteration and the Halted branch below restarts the guest and starts a new boot's window. A guest that is frozen when the
    # window ends gets no pass - the loop runs on to its deadline and the stall classification.
    if [ "${QUIET_BOOT_SECS:-0}" -gt 0 ] && [ "$st" = Running ] && [ $(( $(date +%s) - t_start )) -lt "${QUIET_BOOT_SECS}" ]; then   # GUARD:quietboot
        [ "${_qb_boot:-}" = "$t_start" ] || { log "  t+${el}s QUIET BOOT: no guest call for ${QUIET_BOOT_SECS}s after this boot's start, or until the domain leaves Running"; _qb_boot=$t_start; }
        continue
    fi
    # CPU quiescence, read the same way verify_installed reads it. The stats stream is
    # NULL-separated records; stripping the separators runs values together (3 becomes "31") and
    # the quiet test can then never pass - that bug was already found and fixed twice here.
    if [ "$st" = Running ] && [ "$ready" = 0 ]; then
        # END prints "NA" (not 9999) when there was NO cpu_usage_raw record: an unreadable stat is
        # NOT a busy guest, and the old 9999 sentinel made every unreadable poll reset the quiet
        # streak - which is what defeated the rescue in the 2026-09-09 win11-clean DEADLINE (stats
        # went unreadable at the instant the install stuck). rescue_quiet_step treats NA as quiet.
        cpu=$(printf '' | timeout 10 qrexec-client-vm "$CHURN" admin.vm.Stats 2>/dev/null | tr '\0' '\n' \
              | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print "NA"; else print m}')
        [ -n "$cpu" ] || cpu=NA
        quiet=$(rescue_quiet_step "$quiet" "$cpu")
        since_start=$(( $(date +%s) - t_start ))
        if rescue_should_fire "$rescued" "$since_start" "$RESCUE_AFTER" "$quiet" "$RESCUE_QUIET" "$noshow" "$RESCUE_NOSHOW"; then
            rescued=1
            log "  t+${el}s ANOMALY: no qrexec ${since_start}s after the last start; trigger: $(rescue_trigger_label "$quiet" "$RESCUE_QUIET" "$noshow" "$RESCUE_NOSHOW") (cpu=${cpu})"
            log "    - the install has finished but the job did not reboot the guest as"
            log "    its contract requires (a fresh PV install cannot produce qrexec in this boot)."
            # EVIDENCE BEFORE THE DESTRUCTIVE ACT (audit 2026-09-08, prime-run.sh:271). This state
            # is also what a "QrexecAgent started, then exited after WaitForQdb" guest looks like -
            # Running, quiet, no qrexec - and findings/install.md says that state must be PRESERVED
            # and interrogated, never restarted: two of them were destroyed exactly this way, and
            # the intermittent "never reproduced" in 13 cycles because this reboot cured and erased
            # it. The rescue stays (a job that forgot its reboot must not cost a whole deadline),
            # but it no longer fires blind: the screen, the DIAG markers and - where xencons is
            # already bound - the service state and SCM event log go to $OUT first, all bounded.
            log "    capturing rescue evidence: screen=$(screen_probe "rescue-t${el}")"
            mcopy -n -i "${DIAGIMG:-/nonexistent}" ::/prime-progress.log "$OUT/diag-markers-at-rescue.log" 2>/dev/null \
                && log "    diag markers at rescue -> $OUT/diag-markers-at-rescue.log" \
                || log "    no diag markers readable at rescue"
            if timeout -k 5 150 ./tools/qcon "$CHURN" \
                   'sc query QrexecAgent & sc query QdbDaemon & sc qfailure QrexecAgent & wevtutil qe System /c:40 /rd:true /f:text /q:"*[System[Provider[@Name='"'"'Service Control Manager'"'"']]]"' \
                   >"$OUT/rescue-console.txt" 2>"$OUT/rescue-console.err"; then
                log "    PV-console service dump -> $OUT/rescue-console.txt ($(wc -l <"$OUT/rescue-console.txt") lines)"
            else
                qrc=$?
                log "    PV console gave nothing (rc=$qrc, $(tail -c 200 "$OUT/rescue-console.err" | tr '\n' ' ')) - expected when xencons is not yet bound"
            fi
            log "    Rebooting ONCE as backup. This run will be stamped rescued=1 - it is NOT a clean pass."
            qvm-shutdown "$CHURN" >/dev/null 2>&1
        fi
    fi
    if [ "$st" = Halted ]; then
        restarts=$((restarts+1))
        if [ "$restarts" -gt "$MAX_RESTARTS" ]; then
            log "[ERROR] TERMINAL: guest halted for the ${restarts}th time - it is crash-looping, not installing."
            log "  Guest LEFT HALTED and NOT removed - its state is the evidence (H3.5). Read $OUT."
            exit 1
        fi
        log "  t+${el}s guest halted (the job rebooted it) - restart #$restarts"
        # A START THAT FAILS IS NOT A REBOOT. Measured 2026-09-21: every one of nine "restarts"
        # was `libxenlight failed to create new domain` - the domain never came up at all - and
        # this loop reported it as the guest rebooting, then concluded "crash-looping, not
        # installing". That is a confident wrong diagnosis of a product from a toolstack error,
        # and it cost a campaign cell plus the two cells that cascade off its park. Capture the
        # start's own error and say what actually happened.
        if ! _startout=$(qvm-start "$CHURN" 2>&1); then
            log "  TERMINAL: the DOMAIN WOULD NOT START (this is not the guest rebooting):"
            log "    ${_startout}"
            log "    Nothing is inferred about the install from this - the guest never ran."
            # exit, not return: this loop is at script level, and `return` there is a no-op that
            # printed an error and let the loop carry on to the wrong conclusion anyway.
            exit 1
        fi
        quiet=0; noshow=0; t_start=$(date +%s)   # the rescue clock runs from THIS boot, see RESCUE_QUIET
        continue
    fi
    # CAPTURE, then match - never pipe a probe into `grep -q`. grep exits at the first match, the
    # producer dies of SIGPIPE, timeout reports 141, and this script's `set -o pipefail` makes 141
    # the status: the guest ANSWERED and the probe said it did not. The three other probes in this
    # file were fixed on 2026-10-14; this one hid behind a line continuation, where lint L23's
    # per-line scan could not see it. It is the probe that decides a clean install succeeded.
    if command grep -qa '^QREADY' <<< "$(QTEST_VM=$CHURN timeout -k 5 45 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; then
        # LATCH FIRST: the agent has answered at least once in this run. Set before the quiet window
        # and before any `continue`, because the two paths that leave this block without ready=1 (the
        # guest going deaf in the quiet window, and the post-settle reboot that never comes back) are
        # exactly the GENUINE losses of reachability - the only ones for which "unreachable" means
        # anything. Latching after them would make this flag say "ready" and discriminate nothing.
        qrexec_ever=1
        # QUIET AFTER THE FIRST ANSWER (QUIET_AFTER_FIRST=1; owner-approved 2026-10-04, findings/wedge.md "REVERSE CODE QUALITY").
        # The stall is QEMU in the stub domain no longer completing the guest's requests, and it strikes in a fresh domain's first
        # minutes under concentrated activity. This script's first answer in stage 2 lands seconds after msiexec started QWT's
        # services, and it used to follow it AT ONCE with the module-base arming (several calls and a file copy) - in #3 and #5 that
        # arming call is the one that hung. So: after the first answer of a boot, make NO guest call until the domain leaves Running
        # (a stage ended - the loop's own Halted handling restarts it) or QUIET_WINDOW seconds pass; then ONE liveness probe. A guest
        # that went deaf while left alone gets no pass: the loop carries on to the deadline and its stall classification.
        # Only dom0-side state (qvm-ls) is read during the window.
        if [ "${QUIET_AFTER_FIRST:-0}" = 1 ]; then   # GUARD:quietfirst
            log "  t+${el}s FIRST ANSWER of this boot - QUIET: no guest call for up to ${QUIET_WINDOW:-300}s or until the domain leaves Running"
            _tq=$(date +%s); _left=0
            while [ $(( $(date +%s) - _tq )) -lt "${QUIET_WINDOW:-300}" ]; do
                rl_fg sleep 5
                [ "$(state "$CHURN")" = Running ] || { _left=1; break; }
            done
            if [ "$_left" = 1 ]; then
                log "  the domain left Running during the quiet window (state=$(state "$CHURN")) - a stage ended; the loop takes it from here"
                continue
            fi
            if ! command grep -qa '^QREADY' <<< "$(QTEST_VM=$CHURN timeout -k 5 45 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; then
                log "  NO ANSWER after the quiet window - the guest went deaf while nothing called it; NOT a pass, the loop runs on to its deadline"
                continue
            fi
            log "  still answering after the quiet window"
        fi
        ready=1
        log "  t+${el}s QREXEC ANSWERS after $restarts restart(s) - the guest carries a working QWT"
        # REPORT the convention; the PRODUCT decides it. This used to call w_rtc_utc, which WROTE
        # RealTimeIsUniversal=1 here - after the install, overwriting whatever the installer and the
        # per-boot task had derived, on every primed subject. Measured on run 11: the installer
        # logged "RealTimeIsUniversal set to 0 for the next boot" and the following boots ran with 1
        # and a three-hour error. A harness that sets the thing the gate is meant to measure cannot
        # measure it.
        w_rtc_report "$CHURN" log || true
        # ARM THE MODULE-BASE RECORDER, HERE, WHILE THE GUEST STILL ANSWERS.
        # Until 2026-09-23 this script's failure banner PROMISED the recorder was armed - "a RIP
        # captured with dom0 debug-keys d/v will resolve to driver+offset" - and nothing in this
        # script ever called arm-module-bases.sh. The promise cost a specimen the same day: a
        # clean-install stall on win10-acc was captured live, with one vCPU spinning at guest RIP
        # fffff8015d6bfa60, and that RIP could not be resolved to a driver because Windows KASLR
        # re-randomises the bases every boot and no table had been taken from THIS boot. Jev
        # ranked that table the single measurement that would most change the verdict (0.73).
        # The arming needs qrexec, which is exactly what a wedge takes away, so it happens at the
        # only moment it can: the first time the guest answers. It also takes the HOST-SIDE copy
        # (the script does that itself), because a table readable only over qrexec is unreadable
        # when it matters. Non-fatal: a run must not fail because its instrument did not arm - but
        # it says so LOUDLY, and the failure banner below no longer claims what it cannot know.
        MB_OUT="$OUT/modbases"
        if VM="$CHURN" OUT="$MB_OUT" bash mgmt/harness/arm-module-bases.sh >>"$OUT/arm-module-bases.log" 2>&1; then
            MB_ARMED=1
            log "  module-base recorder ARMED and host copy taken ($MB_OUT/module-bases.txt) - a wedge RIP is resolvable"
        else
            MB_ARMED=0
            log "  [WARN] module-base arming FAILED (see $OUT/arm-module-bases.log) - a wedge RIP on this boot will NOT resolve to a driver"
        fi
        break
    fi
    # Every third poll (~60 s) READ THE SCREEN. A verdict here separates the three states the
    # qrexec probe cannot tell apart: still booting, sitting at a desktop with a dead control
    # channel, or genuinely frozen/black. Non-fatal and never terminal on its own - it is
    # evidence, and the PNG is kept next to this log.
    scr=
    if [ $(( el / 60 )) -gt "${scrn:-0}" ]; then
        scrn=$(( el / 60 )); sv=$(screen_probe "t${el}"); scr=" screen=$sv"; lastscr=$sv
        # A no-window verdict feeds the screen-based rescue trigger (see RESCUE_NOSHOW). The
        # probe runs after the rescue check, so it acts on the next poll - a bounded ~60 s lag.
        noshow=$(rescue_noshow_step "$noshow" "$sv")
    fi
    log "  t+${el}s state=$st restarts=$restarts cpu=${cpu} quiet=$quiet noshow=$noshow (no qrexec yet)$scr"
done

# SETTLE BEFORE DECLARING SUCCESS. First qrexec is not the end of the job: `stock-422` installs,
# gets rc=3010 and then does `shutdown /r /t 15` to bind drivers, so the guest reboots AFTER
# answering. With on_reboot=destroy that reboot halts the domain, and because this script had
# already returned, nothing restarted it - measured 2026-08-30 on win11-stk, which was left
# Transient and then Halted, and whose first probe came back "Request refused" (the file copy could
# not reach a guest that was not up). Returning on the first sign of life reports a job finished
# while it is still working.
#
# So: confirm the guest is STILL answering after a settle window, and if it went away in the
# meantime, restart it and wait again. Bounded, and it re-uses the same restart loop's contract.
if [ "$ready" = 1 ]; then
    log "  qrexec answered - settling ${SETTLE_SECS:-90}s to catch a post-install reboot the job may still do"
    rl_fg sleep "${SETTLE_SECS:-90}"   # interruptible: a TERM must not defer teardown by the settle window
    if ! command grep -qa '^QREADY' <<< "$(QTEST_VM=$CHURN timeout -k 5 45 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; then
        log "  the guest stopped answering during the settle window - the job rebooted it after install"
        # WAIT FOR THE POWER-OFF TO LAND before deciding. This used to take ONE state sample, right
        # here - and a guest that is powering off reads Transient, not Halted, so the restart was
        # skipped every time. Proof from two runs of this same cell on 2026-09-13: NEITHER printed
        # "restart #N (post-install reboot)", one recovered in 44 s because its probe happened to
        # get through, the other sat out the whole 900 s and was written up as a GUEST STALL. The
        # main restart loop above never had this bug because it POLLS and acts on an OBSERVED
        # Halted; this block now does the same.
        st=$(state "$CHURN")
        t0=$(date +%s)
        while [ "$st" != Halted ] && [ $(( $(date +%s) - t0 )) -lt 120 ]; do
            sleep 5; st=$(state "$CHURN")
        done
        [ "$st" = Halted ] && { restarts=$((restarts+1)); log "  restart #$restarts (post-install reboot)"; qvm-start "$CHURN" >/dev/null 2>&1; }
        ready=0
        # DO NOT LET THE WAIT STARVE ITSELF. `timeout -k 5 45` kills the CLIENT; dom0 keeps the
        # queued call for qrexec_timeout, which prime-run sets to 600 for this subject. Probing
        # every 20 s for 900 s therefore parks ~45 calls, each holding a slot for ten minutes, and
        # later calls - including an operator's, afterwards - wait behind them. "No qrexec" becomes
        # self-inflicted and self-sustaining: that is the documented queued-qrexec pattern, and it
        # is what produced a Running/idle/deaf guest that looked exactly like a wedge.
        # So: drop the timeout for the duration of the wait, and restore the standing 600 after.
        qvm-prefs "$CHURN" qrexec_timeout 20 2>/dev/null
        t1=$(date +%s)
        while [ $(( $(date +%s) - t1 )) -lt 900 ]; do
            sleep 20
            [ "$(state "$CHURN")" = Halted ] && { log "  guest halted again - starting it"; qvm-start "$CHURN" >/dev/null 2>&1; continue; }
            [ "$(state "$CHURN")" = Running ] || continue   # Transient: mid-transition, do not probe
            if command grep -qa '^QREADY' <<< "$(QTEST_VM=$CHURN timeout -k 5 30 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; then
                ready=1; log "  qrexec back after the post-install reboot"; break
            fi
        done
        qvm-prefs "$CHURN" qrexec_timeout 600 2>/dev/null
        [ "$ready" = 1 ] || log "  [WARN] guest did not return within 900s of its post-install reboot (state=$(state "$CHURN")); before calling this a guest fault, DRAIN the qrexec queue - qrexec_timeout 15, probe, restore 600"
    else
        log "  still answering after the settle window - the job is genuinely finished"
    fi
fi

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
# `rescued` is recorded, not just `restarts`: a job that honoured its reboot contract and one that
# had to be rescue-rebooted by this script were indistinguishable in the meta (audit 2026-09-08).
echo "rescued=$rescued" >> "$OUT/prime-run.meta"
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
    mcopy -n -i "${DIAGIMG:-/nonexistent}" ::/prime-progress.log "$OUT/diag-markers.log" 2>/dev/null \
        && log "  diag markers saved to $OUT/diag-markers.log" \
        || log "  NO diag markers - the primer hook never ran the job"
    log "DEADLINE: ${DEADLINE}s elapsed with no qrexec after $restarts restart(s)."
    # SAY WHICH KIND OF FAILURE THIS IS. cpu_time is cumulative: flat across a sample means the
    # domain is not executing, moving means it is busy and merely silent. Validated on this rig
    # 2026-09-14 - three calls, twice busy where a stall verdict was FALSE, once frozen (0/20 s)
    # where it was TRUE. Without this line the next reader has to re-derive it, and this project
    # has repeatedly written up a busy guest as a wedge for want of exactly this measurement.
    # CLASSIFY the failure; do NOT excuse it - but classify it on the STRONG conjuncts, which this
    # block used to print and then ignore in favour of the weakest one it had.
    #
    # The weak one is cpu_time. Jev judged it on 2026-09-18 and the wire log holds the numbers:
    # moving_establishes_spin 0.05 (the delta ALONE establishing the spin fingerprint) and
    # classifier_wording_is_sound 0.11 (that this very sentence would NOT mislabel a busy-but-
    # reachable guest). The state it judged on measured a HEALTHY qrexec-answering guest of this
    # class at 327%/321%/262% of a core against the "spinning" one's 175% - the control burned
    # HARDER than the specimen. A number whose healthy and wedged ranges overlap that way cannot
    # decide WHETHER, only ever WHICH. The wording was left unchanged for five weeks and on
    # 2026-10-25 it did precisely what Jev priced at 0.89: see the qrexec_ever note at the top.
    #
    # So the first question is no longer "is it burning CPU" but "was there ever a channel to lose".
    _pr_cs=$(_pr_cpu_state "$CHURN")
    if [ "$qrexec_ever" != 1 ]; then
        # VACUOUS-UNREACHABLE. qrexec never answered once in this run, so "unreachable" is not a
        # finding about reachability - there was no agent. This is a PRIME/INSTALL failure and the
        # evidence that names it is the installer's own exit, on the DIAG volume, not a memory image.
        log "  the agent NEVER answered in this run (0 of the polls above saw qrexec). 'Unreachable'"
        log "  is therefore VACUOUS here - there was no channel to lose, so this is an INSTALL/PRIME"
        log "  failure until something shows otherwise, NOT a wedge. Read the installer's exit first:"
        log "    $OUT/diag-markers.log  (prime-progress.log from the DIAG volume: onboot START + installer rc)"
        log "  cpu_time over the sample: $_pr_cs - recorded, and NOT a wedge verdict either way."
    else
        # A GENUINE LOSS of reachability: the agent answered, then stopped. Only now do the wedge
        # classes apply, and even now cpu_time labels the SHAPE, never the fact.
        log "  the agent ANSWERED earlier in this run and then stopped - reachability was genuinely LOST."
        case "${_pr_cs%% *}" in
          FLAT)
            log "  cpu_time is FLAT over the sample: consistent with the BLOCKED shape (every vCPU idle"
            log "  around one held in Xen). FLAT/MOVING names WHICH shape, not WHETHER it is wedged." ;;
          MOVING)
            log "  cpu_time ADVANCED ${_pr_cs#* } over the sample: consistent with the SPIN shape. Note the"
            log "  bound: a healthy guest of this class measured HIGHER (327% of a core vs 175%), so this"
            log "  number corroborates a loss already established above - it does not establish one." ;;
          *)
            log "  cpu_time UNREADABLE: the shape is UNMEASURED. The loss of reachability still stands." ;;
        esac
    fi
    # THE STRONG CONJUNCTS, said out loud, because on 2026-10-25 every one of them read healthy
    # while the weak one carried the verdict. Pixels: the guest had painted a DESKTOP 3 s before the
    # deadline. ACPI: it had honoured a restart. Both were in the log, beside the SPIN sentence.
    log "  strong conjuncts at the deadline: agent_ever=$qrexec_ever last_screen=${lastscr:--} restarts=$restarts"
    case "$lastscr" in
      DESKTOP|RECOVERY)
        log "  PIXELS PRESENT (last screen verdict $lastscr). A guest that is painting is not frozen;"
        log "  if a wedge is claimed for this run it must be reconciled with that capture." ;;
    esac
    [ "$restarts" -gt 0 ] && log "  the guest HONOURED $restarts ACPI restart(s) in this run - its power path was alive."
    # CAPTURE THE SPECIMEN NOW, AUTOMATICALLY. Leaving the guest running is not enough: on
    # 2026-09-23 a wedge was caught inside an acceptance campaign, and the campaign's NEXT cell
    # would have recloned the guest and destroyed it - the specimen survived only because a human
    # stopped the campaign by hand within minutes. Unattended runs have no such human, so the
    # evidence is taken here, while the guest is still up, and survives whatever happens next.
    #
    # EVERY STALL IS CAPTURED (2026-10-04): this used to fire only on MOVING ("a frozen domain has nothing to image") - but the
    # BLOCKED shape, every vCPU idle around one held in Xen waiting for QEMU, is FLAT, and it is exactly what #4 and #5 were; its
    # memory and Xen's pause_flags are what named the mechanism. Only UNREADABLE (no cpu_time at all) is left uncaptured.
    if [ "${_pr_cs%% *}" = MOVING ] || [ "${_pr_cs%% *}" = FLAT ]; then   # GUARD:captureflat
        log "  capturing the specimen automatically (dom0 forensics, then a memory image)"
        if timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$CHURN" </dev/null \
             > "$OUT/forensics.tar" 2>"$OUT/forensics.err"; then
            log "    forensics -> $OUT/forensics.tar"
        else
            log "    [WARN] dom0 forensics capture failed - see $OUT/forensics.err"
        fi
        # fetch-wedge-core.sh refuses before writing a byte unless this qube has guest-RAM + 1 GiB
        # free, so a full disk costs a log line here rather than a half-written image.
        if bash mgmt/harness/fetch-wedge-core.sh "$CHURN" "$OUT/guest.core" >>"$OUT/core.log" 2>&1; then
            log "    memory image -> $OUT/guest.core"
            log "    name the code: tools/core-module-list.py $OUT/guest.core --contains 0x<rip>"
        else
            log "    memory image NOT taken (see $OUT/core.log) - the forensics above still stand"
        fi
    fi
    # SAY WHAT IS TRUE OF THIS RUN, not what the instrument is supposed to do. This banner used to
    # assert the recorder was armed while nothing in this script armed it (fixed 2026-09-23, after
    # a live specimen's RIP turned out to be unresolvable for exactly that reason).
    if [ "${MB_ARMED:-0}" = 1 ]; then
        log "  Module bases for THIS boot were recorded and copied host-side to $OUT/modbases/module-bases.txt,"
        log "  so a captured RIP resolves: tools/resolve-guest-rip.py $OUT/modbases/module-bases.txt 0x<rip>"
    else
        log "  NO module-base table was taken on this boot (arming never ran or failed), so a captured"
        log "  RIP will NOT resolve to a driver - Windows KASLR re-randomises the bases every boot."
    fi
    log "  Capture the rest NOW, while it is still running, from this qube:"
    log "    qrexec-client-vm dom0 local.WinWedgeForensics+$CHURN </dev/null > forensics.tar"
    log "  Guest LEFT RUNNING and NOT removed - its state is the evidence (H3.5). Read $OUT."
    exit 2
fi
mcopy -n -i "${DIAGIMG:-/nonexistent}" ::/prime-progress.log "$OUT/diag-markers.log" 2>/dev/null \
    && log "diag markers saved to $OUT/diag-markers.log"
if [ "$rescued" = 1 ]; then
    # Not a clean pass: qrexec only appeared because THIS script rebooted the guest. Either the job
    # broke its reboot contract or the guest's qrexec died after starting - both are defects, and
    # the pre-rescue evidence in $OUT is the only record of which. Exit stays 0 (the guest IS up,
    # which is all this script promises); the caller reads rescued=1 from prime-run.meta.
    log "OK-WITH-RESCUE: $CHURN is up ONLY because of the one-shot rescue reboot (rescued=1 in prime-run.meta)."
    log "  ANOMALY - grade the job's reboot contract / qrexec startup from $OUT/rescue-* before trusting this fixture."
fi
# THE BIND IS NOT DONE HERE, and the reason is measured. logvol_bind_guest writes LogDir with the
# volume's DRIVE LETTER as it is AT BIND TIME, and at this point the answer stick and the DIAG stick
# are still attached. The caller then unassigns both (matrix.sh's clear_prime_leftovers), the log
# volume moves UP the alphabet on the next boot, and LogDir points at a letter nothing answers to.
# MEASURED 2026-10-15, mgmt/harness/logvol-chain-check.sh on win10-acc: with the device set stable
# the whole chain holds - volume mounted at D:, LogDir on it, 7 log files held open, 266 QWT lines
# read host-side, and across a REBOOT the letter stayed D: with new lines arriving (266 -> 568),
# 15 links, 0 broken. In the campaign the same bind produced LogDir=F: and, once the two sticks were
# dropped, every log-derived check failed on a healthy guest for three runs running.
# So the CELL binds, after the device set is final: matrix.sh's logvol_bind_now.
log "OK: $CHURN is up. Evidence in $OUT. The stick is still assigned --required and"
log "  qemu-extra-args is still set - clear both before using this guest as a cell subject."
exit 0
