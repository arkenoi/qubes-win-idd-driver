#!/bin/bash
# accept-reinstall-replay.sh <vm> [overall-watchdog-seconds]
#
# WHY THIS SCRIPT, AND WHY IT IS NOT A REWRITE OF cell_reinstall. The owner asked for the
# win10-reinstall acceptance cell's EXACT sequence replayed against win10-acc, "no step may be
# deleted", install.cmd IN SCOPE this time. That cell (mgmt/harness/matrix.sh:2422-2441,
# cell_reinstall) is: unpark_installed (matrix.sh:1410-1476) -> boot_with_release_iso
# (matrix.sh:1057-1097) -> w_session -> logvol_bind_now -> locate_release_disc
# (matrix.sh:1099-1146) -> run_install (matrix.sh:1609+, the SAME function win10-clean uses,
# including the install.cmd launch at matrix.sh:1741-1742) -> detach_release_iso
# (matrix.sh:1148-1160) -> start_vm if Halted (matrix.sh:780-807) -> verify_installed -> accept_grade.
#
# Hand-porting that chain into a second script would be exactly the mistake this project's own
# rules forbid ("Never invent a procedure") AND the mistake the owner is actively correcting
# (silently substituting an equivalent for a committed step). unpark_installed alone has a graceful
# ACPI drain, a 660s stable-halt wait, and a qvm-kill-as-a-committed-last-resort with its own
# cpu-state read first - re-typing that from memory would not be "the exact sequence", it would be
# a DIFFERENT sequence that merely looks similar, which is the specific thing the owner's brief
# (quoted to this agent) says was already done wrong once today.
#
# So this script does not reimplement cell_reinstall. It INVOKES THE REAL mgmt/harness/matrix.sh,
# scoped with CELLS=win10-reinstall (or win11-reinstall), against the subject's OWN release
# package, exactly the way mgmt/harness/matrix.sh:2888 and tools/release-acceptance.sh already do
# in production. That is the one committed door into this sequence; this script is the thin,
# auditable wrapper around it that this task's evidence/reporting needs:
#   * refuses a VM that is not the cell's own fixed churn target (A10=win10-acc / A11=win11-acc -
#     matrix.sh's own comment calls overriding that "a deviation from the committed procedure");
#   * refuses to run if the guest is not already Running/Transient, or if the 'installed' park
#     (ckpt-<vm>-installed) the cell's entry depends on does not exist - both are read-only checks,
#     exactly what unpark_installed itself asserts before touching anything, just surfaced earlier
#     with a plainer message;
#   * NEVER calls qvm-start/qvm-kill/checkpoint.sh itself - matrix.sh's own cell_reinstall does, and
#     this script lets it, because that IS the sequence (the owner's correction: "a reboot/halt
#     that the PRODUCT or the COMMITTED CELL performs as part of the sequence is the sequence and
#     you let it happen" - the only thing withheld is THIS SCRIPT inventing lifecycle calls of its
#     own, which it does not);
#   * logs every line of the real run with a timestamp to its own evidence file;
#   * on top, parses the SAME classification the real harness already produces (the
#     `=== MATRIX: N passed, M failed ===` / `ABORTED` footer, any `UNUSABLE` verdict line, and
#     whether a NEW `unusable-<cell>` failure package appears under the campaign's own $M dir) -
#     because that classifier is the proven instrument that produced the 19709 evidence this task
#     was opened to reproduce, and a second, blinder "120s of silence = stall" timer bolted on from
#     outside would misfire constantly here: this cell is SUPPOSED to go qrexec-silent for minutes
#     at a time (the 660s ACPI drain in unpark_installed, the CD boot, the installer's own
#     reboots) - treating ordinary silence as a stall is exactly the false alarm the real harness
#     already knows how to avoid and this script must not reintroduce.
#
# Evidence: scratchpad/accept-reinstall-replay-<vm>-<UTC-start>/  (run.log = matrix.sh's own
# stdout+stderr, byte for byte; RESULT.txt = this wrapper's summary)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HERE" || exit 2

VM="${1:?usage: accept-reinstall-replay.sh <vm> [overall-watchdog-seconds]  -- NO default target, ever}"
WATCHDOG_S="${2:-5400}"
case "$WATCHDOG_S" in ''|*[!0-9]*) echo "accept-reinstall-replay.sh: watchdog seconds must be an integer, got '$WATCHDOG_S'" >&2; exit 2 ;; esac

# THE CELL'S SUBJECT IS FIXED, NOT A PARAMETER (matrix.sh:2954-2967, TARGET MODEL comment at :1-51):
# win10-reinstall always targets A10 (default win10-acc), win11-reinstall always targets A11
# (default win11-acc). Pointing it at anything else is, in the source's own words, "a deviation
# from the committed procedure" that needs its own justification - this script does not invent
# that override capability.
case "$VM" in
  win10-acc) CELLS=win10-reinstall ;;
  win11-acc) CELLS=win11-reinstall ;;
  *) echo "accept-reinstall-replay.sh: '$VM' is not a cell_reinstall subject - this cell is HARDWIRED to win10-acc (win10-reinstall) or win11-acc (win11-reinstall), per matrix.sh's own TARGET MODEL. Refusing rather than inventing an A10/A11 override." >&2
     exit 2 ;;
esac

# PRECONDITION 1: already Running/Transient. This script never starts a Halted guest - that
# decision belongs to the operator, same rule as accept-load-loop.sh.
VMSTATE="$(qvm-ls --raw-data --fields state "$VM" 2>/dev/null)"
if [ -z "$VMSTATE" ]; then
  echo "accept-reinstall-replay.sh: '$VM' does not exist - refusing to guess or create it." >&2
  exit 2
fi
if [ "$VMSTATE" != Running ] && [ "$VMSTATE" != Transient ]; then
  echo "accept-reinstall-replay.sh: '$VM' is $VMSTATE, not Running - this script does not start a Halted guest. If that is deliberate, start it yourself first and re-run." >&2
  exit 2
fi

# PRECONDITION 2: the 'installed' park cell_reinstall unparks from must exist (matrix.sh:1429-1432
# asserts the identical fact; surfaced here first so a missing park fails in one line instead of
# diving into the real harness's own, much longer FATAL path).
CK="ckpt-$VM-installed"
if ! qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$CK"; then
  echo "accept-reinstall-replay.sh: no '$CK' park exists - the win10-clean cell that creates it (and that just ran) must have completed and parked before this cell can run." >&2
  exit 2
fi

# PRECONDITION 3: the release package this replay installs FROM, and that the subject's own
# package_version was installed FROM, must be the one already verified today (matrix.log's own
# Gate-0 line). Overridable, but defaults to the one this run already confirmed exists and matches.
MATRIX_WORK="${MATRIX_WORK:-/home/user/qwt-accept/rel-40470106070}"
if [ ! -f "$MATRIX_WORK/dl/qwt-improved-setup/MANIFEST.json" ] || [ ! -f "$MATRIX_WORK/dl/qwt-improved-iso/qwt-improved-setup.iso" ]; then
  echo "accept-reinstall-replay.sh: MATRIX_WORK=$MATRIX_WORK does not look like a verified release work dir (missing dl/qwt-improved-setup/MANIFEST.json or dl/qwt-improved-iso/qwt-improved-setup.iso)." >&2
  exit 2
fi

RUNSTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVID="$HERE/scratchpad/accept-reinstall-replay-${VM}-${RUNSTAMP}"
mkdir -p "$EVID"
RUNLOG="$EVID/run.log"
utc(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "$(utc) accept-reinstall-replay START vm=$VM cells=$CELLS matrix_work=$MATRIX_WORK watchdog=${WATCHDOG_S}s" | tee -a "$EVID/wrapper.log"

# A WATCHDOG, NOT A STALL DETECTOR. This process does ONE thing: if the overall WATCHDOG_S elapses
# before matrix.sh itself exits, it says so (loudly, to wrapper.log) WITHOUT touching the guest -
# it exists only so a genuinely wedged run is visible in wall-clock terms rather than silently
# consuming the rest of the session. It never kills matrix.sh, never kills the guest, never issues
# any qvm-*/qtest/qrexec call - the real harness's own internal timeouts (w_session 900s,
# w_install 2400s, the 660s ACPI drain, etc.) are what actually bound this run; this is a tripwire
# on top of them, not a replacement.
(
  sleep "$WATCHDOG_S"
  echo "$(utc) WATCHDOG: ${WATCHDOG_S}s elapsed and the replay has not finished - NOT touching the guest or the job, just flagging it" >> "$EVID/wrapper.log"
) &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null' EXIT

# RUN THE REAL CELL. MATRIX_OUT left unset so matrix.sh picks its own fresh timestamped dir under
# ~/qwt-matrix/ (same as every other invocation, including today's win10-clean run) - this wrapper
# does not invent a campaign output layout either.
set +e
# B11 IS win11r-base, NOT win11-base. matrix.sh:2952 is `B11="${B11:?...}"` - a presence check,
# so the retired name would pass and only the churn-target test at :2982 would look at it; with
# CELLS=win10-reinstall its seal is never verified (:3059), so a dead name would have run fine
# and been copied into the next invocation that DOES need it. win11-base was retired in b1fb0cea
# (the eval-based golden replaced by retail win11r-base); `qvm-ls` lists win10-base and
# win11r-base, nothing else matching win1?-base.
CELLS="$CELLS" B10=win10-base B11=win11r-base MATRIX_WORK="$MATRIX_WORK" \
  "$HERE/mgmt/harness/matrix.sh" > "$RUNLOG" 2>&1
MRC=$?
set -e
kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null
echo "$(utc) matrix.sh exited rc=$MRC" | tee -a "$EVID/wrapper.log"

# CLASSIFY FROM THE REAL HARNESS'S OWN OUTPUT - the same anchors matrix.sh and
# tools/release-acceptance.sh already use (matrix.sh:3736, :3738), plus the UNUSABLE verdict lines
# (matrix.sh:91/3074/3173/3190/3738) and whether a fresh unusable-<cell> failure package appeared
# under matrix's own $M (unusable_verdict's own output location, matrix.sh:178/3157) - NOT a
# separately-invented liveness timer. See the header for why.
FOOTER=$(grep -aE '^=== MATRIX: [0-9]+ passed, [0-9]+ failed ===' "$RUNLOG" | tail -1)
ABORTED=$(grep -aE '=== MATRIX: .* ABORTED' "$RUNLOG" | tail -1)
UNUSABLE_LINES=$(grep -ai 'UNUSABLE' "$RUNLOG" || true)
MOUT=$(grep -aoE '/home/[^ ]*/qwt-matrix/[0-9]{8}-[0-9]{6}' "$RUNLOG" | head -1)
UNUSABLE_DIR=""
if [ -n "$MOUT" ] && [ -d "$MOUT" ]; then
  UNUSABLE_DIR=$(find "$MOUT" -maxdepth 1 -type d -name 'unusable-*' 2>/dev/null | head -1)
fi

STALL_OBSERVED=NO
if [ -n "$UNUSABLE_LINES" ] || [ -n "$UNUSABLE_DIR" ]; then
  STALL_OBSERVED=YES
fi

{
  echo "accept-reinstall-replay RESULT"
  echo "vm=$VM"
  echo "cells=$CELLS"
  echo "matrix_work=$MATRIX_WORK"
  echo "matrix_sh_rc=$MRC"
  echo "matrix_output_dir=${MOUT:-<not found in run.log>}"
  echo "footer=${FOOTER:-<none - matrix.sh did not reach its own footer>}"
  echo "aborted_line=${ABORTED:-<none>}"
  echo "stall_or_unusable_observed=$STALL_OBSERVED"
  if [ -n "$UNUSABLE_DIR" ]; then
    echo "unusable_evidence_dir=$UNUSABLE_DIR"
  fi
  if [ -n "$UNUSABLE_LINES" ]; then
    echo "unusable_lines:"
    printf '%s\n' "$UNUSABLE_LINES" | sed 's/^/  /'
  fi
  echo "guest_state_at_end=$(qvm-ls --raw-data --fields state "$VM" 2>/dev/null)"
  echo "guest left exactly as the real cell's own run_install/verify_installed/accept_grade left it - this wrapper took no lifecycle action of its own"
} > "$EVID/RESULT.txt"

cat "$EVID/RESULT.txt"
echo "run.log: $RUNLOG"
echo "evidence: $EVID"
[ "$STALL_OBSERVED" = YES ] && exit 1
exit "$MRC"
