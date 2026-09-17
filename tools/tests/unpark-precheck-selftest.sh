#!/bin/bash
# unpark-precheck-selftest.sh - prove the unpark path CLASSIFIES BEFORE IT DESTROYS.
#
# WHY THIS EXISTS. Release acceptance run 35171496552 (package 4.3.29+agent.0ca8a70b4eef,
# 2026-09-17) ended "56 passed, 2 failed", and the two failures were ONE event plus the harness
# stepping on its own evidence:
#
#   20:55:30  WIN11-clean: prime-run hit its DEADLINE on win11-acc - qrexec dead for 1083 s, domain
#             Running, per-window tar 0 bytes, cpu_time +35035 ms/20 s. Per H3.5 it left the guest
#             RUNNING and NOT removed, "its state is the evidence", and cell_clean returned
#             WITHOUT parking - so ckpt-win11-acc-installed was never created.
#   20:55:31  WIN11-reinstall began. Its entry state is that very park. unpark_installed halted the
#             subject FIRST and asked about the park LAST, so it:
#               - printed "no qrexec call pending ... (nothing to drain)" and never probed, because
#                 the dead-qrexec discriminator was nested inside the pending-calls branch and a
#                 long-dead qrexec has no pending clients left;
#               - waited 660 s for an ACPI shutdown a wedged guest cannot service;
#               - recorded only "screen=NOWINDOW" - no cpu number - and qvm-killed the specimen;
#               - graded the cell "subject would not halt for unpark" when the honest class was
#                 "qrexec was DEAD on a running guest";
#             all to reach an unpark that could not have succeeded.
#   21:07:54  the next cell recloned over the volumes. The specimen was gone 4 s after the kill.
#
# THREE CONTRACTS COME OUT OF THAT, and this test asserts each one against the SHIPPED code:
#
#   C1  unpark_installed must verify the 'installed' park EXISTS before it touches the subject.
#       With no park it must return non-zero having taken NO destructive action - no drain, no
#       shutdown, no halt wait, no kill - so a failed clean cell's evidence guest survives it.
#   C2  w_drain_and_shutdown must be able to report QREXECDEAD with ZERO pending qrexec calls.
#       That is the whole case it exists for.
#   C3  the last-resort kill must record a cpu_time reading as well as a screen verdict, because
#       the kill is irreversible and "NOWINDOW" alone cannot separate the open P1 stall from a
#       merely session-less guest.
#
# Per this project's rule that a check is unproven until it has been seen to FAIL, each contract is
# re-tested with the ORIGINAL DEFECT deliberately re-introduced behind a knob, and the run reports
# UNPROVEN unless every defect build is caught.
#
# Offline: every qube-touching call is stubbed. Touches no guest, runs in seconds.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
no_(){ fail=$((fail+1)); echo "FAIL  $*"; }

STUB=$(mktemp -d "${TMPDIR:-/tmp}/unparktest.XXXXXX")
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/mgmt/harness" "$STUB/bin"
ACT="$STUB/actions.log"

# --------------------------------------------------------------------------------- the stub rig
# checkpoint.sh is called by PATH-relative path (./mgmt/harness/checkpoint.sh), so it is stubbed by
# running the function from a scratch tree that carries a fake one.
cat >"$STUB/mgmt/harness/checkpoint.sh" <<EOF
#!/bin/bash
echo "checkpoint.sh \$*" >> "$ACT"
exit \${CKPT_RC:-0}
EOF
chmod +x "$STUB/mgmt/harness/checkpoint.sh"

for c in qvm-kill qvm-shutdown pkill; do
  cat >"$STUB/bin/$c" <<EOF
#!/bin/bash
echo "$c \$*" >> "$ACT"
EOF
  chmod +x "$STUB/bin/$c"
done
cat >"$STUB/bin/qvm-ls" <<EOF
#!/bin/bash
# NAMES is the rig's qube list for this scenario; the function greps it for subject and park.
printf '%s\n' \$NAMES
EOF
chmod +x "$STUB/bin/qvm-ls"
cat >"$STUB/bin/qvm-prefs" <<EOF
#!/bin/bash
echo "qvm-prefs \$*" >> "$ACT"
echo 600
EOF
chmod +x "$STUB/bin/qvm-prefs"
cat >"$STUB/bin/pgrep" <<'EOF'
#!/bin/bash
[ -n "${PENDING_PIDS:-}" ] && printf '%s\n' $PENDING_PIDS
exit 0
EOF
chmod +x "$STUB/bin/pgrep"
cat >"$STUB/bin/ps" <<'EOF'
#!/bin/bash
echo "  01:23 qrexec-client-vm stub"
EOF
chmod +x "$STUB/bin/ps"
export PATH="$STUB/bin:$PATH"

# Pull BOTH functions out of the shipped harnesses, so this test cannot drift from what runs.
eval "$(sed -n '/^unpark_installed()/,/^}/p'      "$ROOT/mgmt/harness/matrix.sh")"
eval "$(sed -n '/^w_drain_and_shutdown()/,/^}/p'  "$ROOT/mgmt/harness/e2e-wait.sh")"
declare -F unpark_installed     >/dev/null || { echo "FATAL: could not extract unpark_installed";     exit 2; }
declare -F w_drain_and_shutdown >/dev/null || { echo "FATAL: could not extract w_drain_and_shutdown"; exit 2; }

# Harness-side helpers the two functions call. Every one that MUTATES the guest writes to $ACT.
R=$STUB/run.log; M=$STUB
say(){ echo "SAY $*" >> "$STUB/out.log"; }
no(){  echo "NO $*"  >> "$STUB/out.log"; }
# shellcheck disable=SC2317
w_state(){ echo "${VMSTATE:-Running}"; }
_halt_other_windows(){ echo "halt_other_windows $1" >> "$ACT"; }
w_halt_stable(){ echo "w_halt_stable $1" >> "$ACT"; return "${HALT_STABLE_RC:-0}"; }
w_halt(){ echo "w_halt $1" >> "$ACT"; return 0; }
w_screen(){ echo SCREENTAKEN >> "$STUB/probe.log"; echo NOWINDOW; }
w_cpu_state(){ echo CPUTAKEN >> "$STUB/probe.log"; echo "MOVING 35035"; }
w_alive(){ [ "${QREXEC_ALIVE:-1}" = 1 ]; }
w_cpu_time(){ echo 1; }

reset_scenario(){ : >"$ACT"; : >"$STUB/out.log"; : >"$STUB/probe.log"; }

# ------------------------------------------------------------------- DEFECT KNOBS (re-introduce)
if [ "${UNPARK_DEFECT_NO_PARK_PRECHECK:-0}" = 1 ]; then
  # The pre-2026-09-17 ordering, verbatim in shape: halt the subject first, ask about the park last.
  unpark_installed(){
    local vm=$1 lbl=$2
    _halt_other_windows "$vm"
    qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$vm" || { no "$lbl: subject missing"; return 1; }
    if [ "$(w_state "$vm")" != Halted ]; then
      w_drain_and_shutdown "$vm" say
      w_halt_stable "$vm" 660 "$lbl-unpark-halt" say
      case $? in
        0) ;;
        *) say "  $lbl: ignored ACPI (screen=$(w_screen "$vm" "stuck-$vm" "$M")) - killing"
           qvm-kill "$vm" >/dev/null 2>&1
           w_halt "$vm" 120 "$lbl-unpark-kill" say
           no "$lbl: subject would not halt for unpark - KILLED"; return 1 ;;
      esac
    fi
    ./mgmt/harness/checkpoint.sh unpark "$vm" installed >>"$R" 2>&1 \
      || { no "$lbl: no restorable park"; return 1; }
  }
fi
if [ "${DRAIN_DEFECT_QREXECDEAD_NEEDS_PENDING:-0}" = 1 ]; then
  # The pre-2026-09-17 nesting: the liveness probe only runs when a client call happens to hang.
  w_drain_and_shutdown(){
    local vm=$1 log=$2 pend n
    W_DRAIN_PENDING=0; W_DRAIN_QREXEC_DEAD=0
    pend=$(pgrep -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null)
    if [ -n "$pend" ]; then
      n=$(printf '%s\n' "$pend" | grep -c .)
      W_DRAIN_PENDING=$n
      if [ "$(w_state "$vm")" != Halted ]; then
        if w_alive "$vm"; then :; else W_DRAIN_QREXEC_DEAD=1; fi
      fi
      pkill -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null
    else
      $log "  drain: no qrexec call pending for $vm (nothing to drain)"
    fi
    qvm-shutdown "$vm" >/dev/null 2>&1
  }
fi

cd "$STUB" || exit 2

# =============================================================== C1: no park -> no destructive act
reset_scenario
export NAMES="win11-acc win11-base win10-acc"   # NOTE: no ckpt-win11-acc-installed
export PENDING_PIDS=""; VMSTATE=Running; QREXEC_ALIVE=0; HALT_STABLE_RC=2
unpark_installed win11-acc WIN11-reinstall; rc=$?
[ "$rc" != 0 ] && ok "C1 no park: the cell fails (rc=$rc)" || no_ "C1 no park: the cell did NOT fail"
if grep -qE 'qvm-kill|w_halt_stable|qvm-shutdown|halt_other_windows|checkpoint.sh' "$ACT"; then
  no_ "C1 no park: the subject WAS touched - $(tr '\n' ';' <"$ACT")"
else
  ok "C1 no park: subject untouched (no drain, no shutdown, no halt wait, no kill)"
fi
grep -q "LEFT AS IT STANDS" "$STUB/out.log" \
  && ok "C1 no park: the verdict says the subject is left as it stands" \
  || no_ "C1 no park: the verdict does not say the subject was preserved"

# =============================================================== C1b: park present -> cell proceeds
reset_scenario
export NAMES="win11-acc ckpt-win11-acc-installed win11-base"
export PENDING_PIDS="" CKPT_RC=0; VMSTATE=Halted; QREXEC_ALIVE=1; HALT_STABLE_RC=0
unpark_installed win11-acc WIN11-reinstall; rc=$?
[ "$rc" = 0 ] && ok "C1b park present: the cell proceeds (rc=0)" || no_ "C1b park present: cell refused (rc=$rc)"
grep -q 'checkpoint.sh unpark win11-acc installed' "$ACT" \
  && ok "C1b park present: the unpark actually ran" \
  || no_ "C1b park present: the unpark never ran"

# ================================================= C3: the last-resort kill records a cpu reading
reset_scenario
export NAMES="win11-acc ckpt-win11-acc-installed"
export PENDING_PIDS=""; VMSTATE=Running; QREXEC_ALIVE=1; HALT_STABLE_RC=2
unpark_installed win11-acc WIN11-reinstall >/dev/null 2>&1
if grep -q 'qvm-kill' "$ACT"; then
  ok "C3 stuck subject: the kill path was reached"
  grep -q CPUTAKEN "$STUB/probe.log" \
    && ok "C3 stuck subject: a cpu_time reading was taken BEFORE the kill" \
    || no_ "C3 stuck subject: the guest was killed with NO cpu reading - the 2026-09-17 blind spot"
  grep -q 'cpu=MOVING' "$STUB/out.log" \
    && ok "C3 stuck subject: the cpu reading is in the recorded line" \
    || no_ "C3 stuck subject: the cpu reading was taken but never recorded"
else
  no_ "C3 stuck subject: the kill path was not reached at all"
fi

# ================================================ C2: QREXECDEAD with ZERO pending calls
reset_scenario
export PENDING_PIDS=""; VMSTATE=Running; QREXEC_ALIVE=0
W_DRAIN_QREXEC_DEAD=0
w_drain_and_shutdown win11-acc say
[ "${W_DRAIN_QREXEC_DEAD:-0}" = 1 ] \
  && ok "C2 dead qrexec, zero pending: graded QREXECDEAD" \
  || no_ "C2 dead qrexec, zero pending: NOT graded QREXECDEAD - the 2026-09-17 defect"

# C2b: a healthy guest must NOT be graded QREXECDEAD (the flag must stay a discriminator).
reset_scenario
export PENDING_PIDS=""; VMSTATE=Running; QREXEC_ALIVE=1
W_DRAIN_QREXEC_DEAD=0
w_drain_and_shutdown win11-acc say
[ "${W_DRAIN_QREXEC_DEAD:-0}" = 0 ] \
  && ok "C2b healthy guest, zero pending: NOT graded QREXECDEAD" \
  || no_ "C2b healthy guest: falsely graded QREXECDEAD"

# C2c: a Halted guest must not be probed or graded at all.
reset_scenario
export PENDING_PIDS=""; VMSTATE=Halted; QREXEC_ALIVE=0
W_DRAIN_QREXEC_DEAD=0
w_drain_and_shutdown win11-acc say
[ "${W_DRAIN_QREXEC_DEAD:-0}" = 0 ] \
  && ok "C2c halted guest: not graded QREXECDEAD" \
  || no_ "C2c halted guest: graded QREXECDEAD on a guest that is not even running"

cd "$ROOT" || exit 2
echo
echo "checks: $pass passed, $fail failed"

# ------------------------------------------------------------------- the defect-catch requirement
# A defect run exits NON-ZERO when it catches the defect (the normal path below), and ZERO when it
# does not - which is what the parent loop tests for. Do not "fix" that inversion: a defect build
# that goes green is the failure being reported.
[ "$fail" -eq 0 ] || exit 1
if [ "${UNPARK_SELFTEST_NO_DEFECT_RUN:-0}" = 1 ]; then
  echo "clean build green; defect runs SKIPPED by request - record this PASS as UNPROVEN"; exit 0
fi
# Prove the checks by re-introducing each defect and requiring a catch.
echo
for knob in UNPARK_DEFECT_NO_PARK_PRECHECK DRAIN_DEFECT_QREXECDEAD_NEEDS_PENDING; do
  echo "--- defect run: $knob=1"
  if env "$knob=1" UNPARK_SELFTEST_NO_DEFECT_RUN=1 bash "$0" >"$STUB/defect-$knob.out" 2>&1; then
    echo "FAIL  $knob: the defect build went GREEN - the checks do not cover it"
    sed 's/^/      /' "$STUB/defect-$knob.out"
    exit 1
  fi
  echo "      caught by $(grep -c '^FAIL' "$STUB/defect-$knob.out") check(s):"
  grep '^FAIL' "$STUB/defect-$knob.out" | sed 's/^/      /'
done
echo
echo "ALL CONTRACTS PROVEN: clean build green, both defect builds caught."
