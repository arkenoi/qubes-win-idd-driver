#!/bin/bash
# matrix-runinstall-grade-selftest.sh - run_install()'s refusals and outcome verdicts, driven.
#
# WHAT IT GRADES. run_install() writes a unique run marker into the guest's installer log, refuses to
# run if it cannot, guards against inherited-environment fault injection, and then names WHICH way
# the install ended. 7 ok()/no() decisions, counted as untested by tools/grader-census.py.
#
# WHY IT MATTERS, from its own notes - three measured incidents, all verdict defects:
#   * 2026-10-14, the acceptance campaign's WIN10-reinstall cell took "no answer" THREE SECONDS after
#     a successful guest read, refused to run the install, and graded itself INVALID-INSTRUMENT twice
#     over an install that had never been attempted. "A timeout is a failure only once cpu_time is
#     FLAT" - so a silent guest that is still EXECUTING must be retried, not failed.
#   * 2026-08-28: SEED_DELAY is an environment variable, so an inherited value injected a fault into
#     a cell that never declared itself seeded, and voided the whole WIN10 matrix.
#   * the outcome codes are five DIFFERENT facts (RESULT / recovery screen / deadline / halted /
#     stalled) and only two of them are failures; a harness that misnames the failure is how wrong
#     conclusions get written down.
#
# HOW IT IS DRIVEN. The SHIPPED function is extracted from matrix.sh and run with the guest probes
# stubbed (_mark_seen, w_cpu_moving, w_install, qrun, qtest, fetch_msi_verbose) and `sleep` made a
# no-op so the retry loop and the background probes cost nothing.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-runinstall.XXXXXX") || exit 2
# THE CLEANUP MUST NOT RUN IN A SUBSHELL. run_install spawns background `( ... ) &` probes, and a
# subshell INHERITS the EXIT trap - so when the probe exited (instantly here, because `sleep` is
# stubbed to a no-op) it ran this cleanup and deleted $T out from under the remaining cases. Every
# case from the fifth onwards then reported "could not enter the stub tree", which looked like a
# grader defect and was entirely this trap. $$ is no use for the guard: bash keeps the PARENT's pid
# in a subshell. $BASHPID is the real one.
MYPID=$BASHPID
trap 'rc=$?; [ "$BASHPID" = "$MYPID" ] || exit "$rc"; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

MSH="$ROOT/$(ls mgmt/harness/matri*.sh | head -1)"
eval "$(sed -n '/^run_install(){/,/^}$/p' "$MSH")"
declare -f run_install >/dev/null || { echo "FAIL could not extract run_install from $MSH"; exit 1; }
# ITS GLOBALS COME FROM THE FILE TOO, not from a copy here. run_install reads $INC (the guest's
# QubesIncoming path, matrix.sh:368) when it arms the reboot-dialog watcher; extracting only the
# function left it unset and the first run died with "INC: unbound variable". A transcription would
# pass while the real value drifted.
eval "$(grep -aE "^INC='" "$MSH")"
[ -n "${INC:-}" ] || { echo "FAIL could not read INC from $MSH"; exit 1; }

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ printf '%s' "$LINES" | grep -qa "$1"; }

mkdir -p "$T/tree/tools" "$T/tree/mgmt/harness"
printf '#!/bin/bash\nexit 0\n' > "$T/tree/tools/qtest"
printf '#!/bin/bash\nexit %s\n' '${ARM_RC:-0}' > "$T/tree/mgmt/harness/arm-module-bases.sh"
chmod +x "$T/tree/tools/qtest" "$T/tree/mgmt/harness/arm-module-bases.sh"

run_ri(){ # env: MARK_SEQ (space-separated _mark_seen answers), CPU_MOVING, WINSTALL_RC, SEED_DELAY, SEED_CELL
  OK=0; NO=0; LINES=""; CELL_RC=
  ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
  no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
  say(){ LINES="$LINES[SAY] $*"$'\n'; }
  # the guest probes
  # THE INDEX LIVES IN A FILE, because run_install calls _mark_seen inside a COMMAND SUBSTITUTION -
  # a subshell - so a shell variable incremented there is discarded and every call returned the
  # FIRST answer. The retry case then never saw its second answer and looked like a grader defect.
  echo 0 > "$T/markidx"
  _mark_seen(){ local i; i=$(cat "$T/markidx"); i=$((i+1)); echo "$i" > "$T/markidx"
                printf '%s\n' "$(printf '%s' "$MARK_SEQ" | cut -d' ' -f"$i")"; }
  w_cpu_moving(){ [ "${CPU_MOVING:-1}" = 1 ]; }
  w_install(){ return "${WINSTALL_RC:-0}"; }
  qrun(){ :; }
  fetch_msi_verbose(){ :; }
  sleep(){ :; }
  GLOG='C:\qwt-improved-install.log'
  STALL_SECS=300
  M="$T/m"; R="$T/run.log"; mkdir -p "$M"; : > "$R"
  local _cwd="$PWD"
  cd "$T/tree" || { no_ "could not enter the stub tree"; return; }
  run_install testvm cellA "$T/disc.iso"
  RI_RC=$?
  cd "$_cwd" || return
}

# ---- 1. the marker lands first time -> it proceeds --------------------------------------------
MARK_SEQ="PRESENT" WINSTALL_RC=0 run_ri
if [ "$RI_RC" = 0 ] && [ "$NO" = 0 ] && has 'run marker E2EMARK-'; then ok_ "a marker that lands first time: it proceeds and records the marker"
else no_ "a marker that lands first time proceeds" "rc=$RI_RC NO=$NO $LINES"; fi
if [ -s "$T/m/cellA-install.tail" ] && grep -qa 'E2EMARK-' "$T/m/cellA-install.tail"; then ok_ "and the marker is seeded into the LOCAL tail, not just hoped for from the guest"
else no_ "the marker is seeded locally" "$(ls "$T/m" 2>/dev/null)"; fi

# ---- 2. THE 2026-10-14 DEFECT: a silent guest that is EXECUTING is retried, not failed --------
MARK_SEQ="x PRESENT" CPU_MOVING=1 WINSTALL_RC=0 run_ri
if [ "$RI_RC" = 0 ] && has 'the guest IS EXECUTING' && has 'run marker written on retry'; then
  ok_ "a silent-but-executing guest is RETRIED and the marker lands (the 2026-10-14 defect)"
else no_ "a silent-but-executing guest is retried" "rc=$RI_RC $LINES"; fi

# ---- 3. a guest that is NOT executing is not retried six times --------------------------------
MARK_SEQ="x" CPU_MOVING=0 WINSTALL_RC=0 run_ri
if [ "$RI_RC" != 0 ] && has 'cpu_time FLAT' && has 'could not write the run marker'; then
  ok_ "a FLAT guest stops the retry loop and refuses to run - a cell it cannot tell apart"
else no_ "a flat guest refuses to run" "rc=$RI_RC $LINES"; fi
if ! has 'retry 6/6'; then ok_ "and it does not burn all six retries on a guest doing nothing"
else no_ "it stops early on a flat guest" "$LINES"; fi

# ---- 4. THE 2026-08-28 DEFECT: inherited SEED_DELAY must not inject -------------------------
MARK_SEQ="PRESENT" SEED_DELAY=30 SEED_CELL= WINSTALL_RC=0 run_ri
if has 'SEED_DELAY=30 is set but SEED_CELL=1 was not' && [ "${CELL_RC:-}" = 2 ]; then
  ok_ "inherited SEED_DELAY without SEED_CELL=1 refuses to inject (the 2026-08-28 voided matrix)"
else no_ "inherited SEED_DELAY refuses to inject" "CELL_RC=${CELL_RC:-unset} $LINES"; fi
MARK_SEQ="PRESENT" SEED_DELAY=30 SEED_CELL=1 WINSTALL_RC=0 run_ri
if ! has 'refusing to inject'; then ok_ "a cell that DECLARES itself seeded is allowed to inject"
else no_ "a declared seed cell is allowed" "$LINES"; fi

# ---- 5. the five outcome codes are five different facts, and only two are failures ------------
MARK_SEQ="PRESENT" WINSTALL_RC=0 run_ri
if has 'install reported a RESULT' && [ "$NO" = 0 ]; then ok_ "rc 0: a RESULT is reported, nothing graded"
else no_ "rc 0 is not a failure" "$LINES"; fi
MARK_SEQ="PRESENT" WINSTALL_RC=1 run_ri
if has 'recovery screen DURING the install' && [ "$NO" = 1 ]; then ok_ "rc 1: the recovery screen is named, and it IS a failure"
else no_ "rc 1 names the recovery screen" "$LINES"; fi
MARK_SEQ="PRESENT" WINSTALL_RC=2 run_ri
if has 'hit the 2400s deadline' && [ "$NO" = 1 ]; then ok_ "rc 2: the deadline is a different failure from the recovery screen"
else no_ "rc 2 is the deadline" "$LINES"; fi
MARK_SEQ="PRESENT" WINSTALL_RC=3 run_ri
if has 'halted during/after the install' && [ "$NO" = 0 ]; then ok_ "rc 3: a halt is EXPECTED for a two-stage install, not a failure"
else no_ "rc 3 is not a failure" "$LINES"; fi
MARK_SEQ="PRESENT" WINSTALL_RC=4 run_ri
if has 'install STALLED' && [ "$NO" = 1 ]; then ok_ "rc 4: a stall is its own failure, with the stall budget named"
else no_ "rc 4 is a stall" "$LINES"; fi

# ---- 6. SEEN TO FAIL --------------------------------------------------------------------------
MARK_SEQ="PRESENT" WINSTALL_RC=0 run_ri; a="$OK/$NO"
MARK_SEQ="PRESENT" WINSTALL_RC=1 run_ri; b="$OK/$NO"
if [ "$a" != "$b" ]; then ok_ "SEEN TO FAIL: the outcome verdict tracks w_install's code ($a vs $b)"
else no_ "SEEN TO FAIL: the outcome tracks w_install" "both gave $a - the grader is inert"; fi

printf 'matrix-runinstall-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
