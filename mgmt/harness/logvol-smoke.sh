#!/usr/bin/env bash
# logvol-smoke.sh - can a guest actually SEE the log volume, and does evidence reach the image?
#
#   mgmt/harness/logvol-smoke.sh [--golden win11r-qwt] [--subject logvol-smoke] [--keep]
#
# WHY THIS EXISTS, and it is the gap the owner named. Campaign 40134888669 ABORTED 11 minutes in, on
# its first cell, because `logvol_bind_guest` refused with
# `no_volume_labelled_DIAG_with_LOGVOL.TAG`. The preparation gates written afterwards
# (mgmt/harness/campaign-preflight.sh section 2b) check everything AROUND that bind - mtools on
# PATH, every existing image carrying LOGVOL.TAG, no stale block claim, free pool space - and NOT
# ONE of them checks the thing that failed. The preflight would have cleared just as happily.
# Owner 2026-10-25: "and why we did not smoke test the bind". Exactly.
#
# A preflight cannot answer this: before a campaign there is no guest, and the property is about a
# GUEST seeing a device. So it is a cell, and it runs BEFORE the eight that cost hours.
#
# HYPOTHESIS: a subject cloned from the QWT golden, with a DIAG volume attached BEFORE its first
#   boot, enumerates that volume, and `logvol_bind_guest` writes LogDir to it and says ok; then a
#   nonce written inside the guest is readable off the IMAGE with mtools and no guest at all.
#   REFUTED BY: the bind refusing, or the round-trip not arriving - which is the campaign's abort,
#   found in minutes instead of after an install.
# BASELINE: the clone itself. A golden that will not boot and answer qrexec fails this as INVALID-RIG
#   rather than as a bind failure - the two are different findings and this says which.
# VARIABLE: the log volume's attach and bind. Nothing else is done to the guest.
# INSTRUMENT: the bind's own receipt, the round-trip's nonce, and ON FAILURE the guest's own disk and
#   volume inventory - the three states `no volume labelled DIAG` cannot tell apart (never
#   enumerated / enumerated with NO partition / present but unletterable). It can FAIL: --no-attach
#   runs the identical sequence with the volume NOT attached, and the bind MUST refuse. That arm is
#   what makes a pass mean anything, and tools/tests/logvol-smoke-selftest.sh asserts both shapes.
# BUDGET: ~8 min. Three exits, each named: bound and proved / a terminal rig state / the deadline.
#
# IT CLEANS UP AFTER ITSELF. The subject is removed and the loop released on every exit, --keep
# leaves it for inspection, and a kill is never used on a guest that might be reused - this one is
# discarded by construction, so the usual prohibition does not bite.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

GOLDEN="win11r-qwt"; SUBJ="logvol-smoke"; KEEP=0; ATTACH=1; DEADLINE=600
while [ $# -gt 0 ]; do
  case "$1" in
    --golden)  GOLDEN="${2:?}"; shift 2 ;;
    --subject) SUBJ="${2:?}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    --no-attach) ATTACH=0; shift ;;          # the refutation arm: the bind MUST refuse
    --deadline) DEADLINE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

GOLDEN_SH="${GOLDEN_SH:-mgmt/golden.sh}"
CLONE_SH="${CLONE_SH:-mgmt/clone-guest.sh}"
OUT="${LOGVOL_SMOKE_OUT:-$HOME/qwt-logvol-smoke/$(date -u +%m%d-%H%M%S)}"
mkdir -p "$OUT" || exit 2
say(){ printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*" | tee -a "$OUT/smoke.log"; }
verdict(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT/verdict.tsv"; say "$1  $2 -- $3"; }

# THE LIBRARIES ARE OVERRIDABLE TOO, for the same reason as QTEST: every arm of this cell is a
# different answer from logvol_bind_guest / logvol_prove_roundtrip, and a suite that cannot make
# them answer cannot drive a single refusal. Nothing stubs this script itself.
LOGVOL_LIB="${LOGVOL_LIB:-mgmt/harness/logvol-lib.sh}"
SHUTDOWN_LIB="${SHUTDOWN_LIB:-mgmt/harness/shutdown-lib.sh}"
VMLOCK_LIB="${VMLOCK_LIB:-mgmt/harness/vmlock.sh}"
# shellcheck disable=SC1091
. "$LOGVOL_LIB"
# shellcheck disable=SC1091
. "$SHUTDOWN_LIB" 2>/dev/null || true
# shellcheck disable=SC1091
. "$VMLOCK_LIB" 2>/dev/null || true
command -v vm_lock >/dev/null 2>&1 || vm_lock(){ return 0; }
command -v qwt_shutdown >/dev/null 2>&1 || qwt_shutdown(){ return 0; }

# QTEST THROUGH A VARIABLE, so a suite can stub it. `timeout` EXECs the binary, so a shell-function
# stub cannot intercept it (this project's 2026-10-21 lesson, and the CI red of 2026-10-25) - and a
# rig script whose only instrument cannot be stubbed has no suite, which is how a gate ends up
# unproven.
QTEST="${QTEST:-./tools/qtest}"
q(){ QTEST_VM="$SUBJ" timeout "${QT_T:-120}" "$QTEST" "$@"; }
state(){ qvm-ls --raw-data --fields STATE "$SUBJ" 2>/dev/null | tr -d '\n'; }

cleanup(){
  local rc=$?
  if [ "$KEEP" = 1 ]; then say "--keep: leaving $SUBJ in place for inspection"; return $rc; fi
  if [ -n "$(state)" ]; then
    qwt_shutdown "$SUBJ" 300 >>"$OUT/teardown.out" 2>&1 \
      || { say "teardown: $SUBJ would not halt politely - killing it (it is being discarded)"; qvm-kill "$SUBJ" >/dev/null 2>&1; }
    qvm-remove -f "$SUBJ" >>"$OUT/teardown.out" 2>&1 && say "teardown: $SUBJ removed"
  fi
  [ -n "${SMOKE_LOOP:-}" ] && logvol_loop_release "$SMOKE_LOOP" >>"$OUT/teardown.out" 2>&1
  return $rc
}
trap cleanup EXIT

say "logvol smoke: golden=$GOLDEN subject=$SUBJ attach=$ATTACH out=$OUT"
vm_lock "$SUBJ" || { verdict INVALID-RIG "the rig lock for $SUBJ is held" "another job owns it"; exit 2; }

# ---- 1. a clone of the golden, and a golden that does not verify is not our finding -------------
"$GOLDEN_SH" verify "$GOLDEN" >>"$OUT/clone.out" 2>&1 \
  || { verdict INVALID-RIG "the golden verifies before it is cloned" "$GOLDEN does not verify - fix the rig, this says nothing about the bind"; exit 2; }
[ -z "$(state)" ] || qvm-remove -f "$SUBJ" >>"$OUT/clone.out" 2>&1
bash "$CLONE_SH" "$GOLDEN" "$SUBJ" >>"$OUT/clone.out" 2>&1 \
  || { verdict INVALID-RIG "the golden clones" "clone-guest.sh failed: $(tail -2 "$OUT/clone.out" | tr '\n' ' ' | cut -c1-140)"; exit 2; }
say "cloned $GOLDEN -> $SUBJ"

# ---- 2. the volume, attached BEFORE the first boot (a --required claim is satisfied at creation) --
IMG=$(logvol_image "$SUBJ")
if [ "$ATTACH" = 1 ]; then
  logvol_create "$IMG" "$SUBJ" >>"$OUT/attach.out" 2>&1 \
    && logvol_attach "$SUBJ" "$IMG" "$OUT/logvol-manifest.json" >>"$OUT/attach.out" 2>&1 \
    || { verdict INVALID-RIG "the volume attaches" "logvol_create/attach failed: $(tail -2 "$OUT/attach.out" | tr '\n' ' ' | cut -c1-140)"; exit 2; }
  SMOKE_LOOP=$(logvol_loop_of "$IMG")
  # THE GRADED PHASE, from the SAME declaration the matrix uses. This is the whole point of the
  # owner's "you organically cannot keep matrix and smoke test configurations in sync": if this cell
  # composed its own device set it would be proving a configuration no campaign runs. The subject is
  # Halted here (it has never been started), so the boundary rule is satisfied.
  logvol_devices_apply "$SUBJ" graded \
    || { verdict INVALID-RIG "the graded device set applies" "logvol_devices_apply refused - see $OUT/attach.out"; exit 2; }
  say "attached $IMG (loop ${SMOKE_LOOP:-?}) and applied the GRADED device set before first boot"
else
  say "--no-attach: NOTHING attached - the bind below MUST refuse"
fi

# ---- 3. boot, and THREE EXITS ------------------------------------------------------------------
qvm-start "$SUBJ" >>"$OUT/boot.out" 2>&1 || { verdict INVALID-RIG "the subject starts" "qvm-start failed: $(tail -1 "$OUT/boot.out")"; exit 2; }
_why=""; _d=$((SECONDS+DEADLINE))
while [ $SECONDS -lt $_d ]; do
  [ "$(state)" = Halted ] && { _why="the guest halted"; break; }
  # CAPTURE, THEN MATCH. A guest probe piped into `grep -q` SIGPIPEs the qrexec client mid-connect:
  # the guest logs QGAVCHANFAIL request dropped and pipefail grades a LIVE guest dead. lint L23.
  _up=$(q run 'cmd /c echo UP' 2>/dev/null || true)
  case "$_up" in *UP*) _why="up"; break ;; esac
  sleep 10
done
[ -n "$_why" ] || _why="the ${DEADLINE}s deadline expired"
say "boot wait exit: $_why"
[ "$_why" = up ] || { verdict INVALID-RIG "the subject answers qrexec" "$_why - a guest that never came up says nothing about the bind"; exit 2; }

# ---- 4. THE PROPERTY: the bind, and the evidence round trip -------------------------------------
# EVERY FAILURE BRANCH STOPS HERE, which lint L29 requires of a log-device primitive and which the
# first cut of this file got wrong: it stored the outcome in a variable and decided later. That is
# the shape that let run 39225775322 carry on after a failed bind until the guest went SPIN with no
# instrument that survives it. Each arm therefore tests the bind itself and exits on the spot.
if [ "$ATTACH" = 0 ]; then
  # THE REFUTATION ARM. With nothing attached the bind must refuse; a bind that "succeeds" here
  # means the receipt is not about the volume at all, and every pass of this smoke test is void.
  if logvol_bind_guest "$SUBJ" "$SUBJ" >>"$OUT/bind.out" 2>&1; then
    verdict FAIL "with NO volume attached the bind REFUSES" "it reported success with nothing attached - the receipt does not measure the volume, so a PASS of this cell proves nothing"
    exit 1
  fi
  verdict PASS "with NO volume attached the bind REFUSES" "$(tail -1 "$OUT/bind.out" | cut -c1-160)"
  exit 0
fi

if ! logvol_bind_guest "$SUBJ" "$SUBJ" >>"$OUT/bind.out" 2>&1; then
  # the three states the binder's one sentence cannot tell apart, captured while the guest is up
  q run 'powershell -NoProfile -Command "Get-Disk | Format-Table -Auto Number,FriendlyName,BusType,Size,PartitionStyle,IsOffline | Out-String -Width 200; Get-CimInstance Win32_DiskDrive | Format-Table -Auto Model,InterfaceType,Size,Partitions | Out-String -Width 200; Get-Volume | Format-Table -Auto DriveLetter,FileSystemLabel,FileSystem,DriveType,Size | Out-String -Width 200"' \
    > "$OUT/guestview.out" 2>&1
  verdict FAIL "the guest sees the log volume and the bind succeeds" \
          "$(tail -1 "$OUT/bind.out" | cut -c1-120) - the guest's own disk/volume inventory is in $OUT/guestview.out (never enumerated / no partition / unletterable are different findings)"
  exit 1
fi
say "bind ok: $(command grep -ao 'LOGVOL-BIND[^|]*' "$OUT/bind.out" | tail -1)"

# AND PROVE EVIDENCE ARRIVES, because a bind that returned ok is not evidence that evidence will.
if logvol_prove_roundtrip "$SUBJ" "$IMG" "$SUBJ" >>"$OUT/roundtrip.out" 2>&1; then
  verdict PASS "the guest sees the volume, the bind succeeds, and a nonce written inside reaches the IMAGE" \
          "read back with mtools and no guest; receipts in $OUT"
  exit 0
fi
verdict FAIL "a nonce written inside the guest reaches the image" \
        "the bind said ok but the round trip did not arrive: $(tail -1 "$OUT/roundtrip.out" | cut -c1-140)"
exit 1
