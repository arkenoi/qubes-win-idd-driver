#!/bin/bash
# the appvm cell's entry refusals and its per-boot session/shell and instrument verdicts hold.
# run: tools/tests/matrix-appvmcell-grade-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"
T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-appvmcell.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

eval "$(sed -n '/^cell_appvm(){/,/^}$/p' "$ROOT/mgmt/harness/matrix.sh")"
declare -f cell_appvm >/dev/null || { echo "FAIL could not extract cell_appvm"; exit 1; }
# THE SCOPE PREDICATE IS EXTRACTED, NOT STUBBED. It decides whether this cell touches the stick at
# all; a stub here would make every leg below a statement about the stub.
eval "$(sed -n '/^logvol_stick_scope(){/,/^}$/p' "$ROOT/mgmt/harness/matrix.sh")"
declare -f logvol_stick_scope >/dev/null || { echo "FAIL could not extract logvol_stick_scope"; exit 1; }

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ printf '%s' "$LINES" | grep -qa "$1"; }

# checkpoint.sh is invoked by relative path, so it needs a tree; everything else is a shell function.
mkdir -p "$T/tree/mgmt/harness" "$T/m"
printf '#!/bin/bash\nexit "${CKPT_RC:-0}"\n' > "$T/tree/mgmt/harness/checkpoint.sh"
chmod +x "$T/tree/mgmt/harness/checkpoint.sh"

# ---- the stubs, as ORDINARY SHELL FUNCTIONS over ORDINARY VARIABLES ---------------------------
ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
say(){ LINES="$LINES[SAY] $*"$'\n'; }
sleep(){ :; }
_halt_other_windows(){ :; }
w_halt(){ return "${HALT_RC:-0}"; }
w_state(){ printf 'Halted\n'; }
w_session(){ return "${SESSION_RC:-0}"; }
w_usersession(){ return "${SHELL_RC:-0}"; }
w_appvm_shell(){ return "${SHELL_RC:-0}"; }
w_screen(){ printf 'DESKTOP\n'; }
start_vm(){ :; }
reclone(){ return 0; }
# The sealed primitives cell_appvm now goes through. UNUSABLE_RC drives the step-15 gate's two arms:
# 0 = the evidence is on record and the unusable verdict is entitled, non-zero = it is withheld.
toolstack_accept(){ return 0; }
unusable_verdict(){ printf 'UNUSABLEEVIDENCE vm=%s last_qrexec=stub TOOLSTACKACCEPT accepted=1\n' "$1"; return "${UNUSABLE_RC:-0}"; }
# THE STICK PRIMITIVES ARE RECORDERS, not no-ops. Owner's ruling 2026-10-22 - "log stick exists for
# install testing. on appvms and feature tests it has zero sense" - means the property under test is
# that this cell calls NONE of them, which a no-op stub cannot see. $STICK collects the calls.
logvol_bind_now(){ STICK="$STICK bind:${2:-}"; }
# logvol_image is called inside $(...) - a subshell - so a variable recorder would be discarded and
# the leg would read green with the call still there. A file survives the subshell.
logvol_image(){ : > "$T/stick-image-called"; printf '%s\n' "$T/logs-$1.img"; }
logvol_create(){ STICK="$STICK create"; [ "${LOGVOL_FAIL:-0}" = 1 ] && return 1; : > "$1" 2>/dev/null; return 0; }
logvol_attach(){ STICK="$STICK attach"; [ "${LOGVOL_FAIL:-0}" = 1 ] && return 1; return 0; }
grade_appvm_window(){ return "${WIN_RC:-0}"; }
# the qvm-* family: EXISTS lists what the rig has, so "absent" and "present" are one variable
qvm-check(){ local v=${*: -1}; case " $EXISTS " in *" $v "*) return 0 ;; *) return 1 ;; esac; }
qvm-ls(){ printf '%s\n' $PARKS $EXISTS; }
qvm-create(){ return "${CREATE_RC:-0}"; }
qvm-tags(){ return "${TAG_RC:-0}"; }
# A SUCCESSFUL REMOVE MUST ACTUALLY REMOVE IT. The cell checks `qvm-remove || qvm-ls | grep -qx`,
# precisely so a remove that reports success but leaves the VM behind is caught - so a stub that
# returns 0 while still listing the name makes the cell refuse, correctly, and the case fails for
# the right reason. The stub now honours the contract it is standing in for.
qvm-remove(){ local rc=${REMOVE_RC:-0}
              [ "$rc" = 0 ] && EXISTS=$(printf '%s\n' $EXISTS | grep -vx "${*: -1}" | tr '\n' ' ')
              return "$rc"; }
qvm-features(){ :; }
qvm-prefs(){ printf '\n'; }
qvm-shutdown(){ :; }
qvm-kill(){ :; }

reset_case(){ OK=0; NO=0; LINES=""; STICK=""; rm -f "$T/stick-image-called"
  EXISTS="win10-tpl"; PARKS="ckpt-win10-acc-installed"
  # CKPT_RC is read by the ONE external stub (checkpoint.sh, called by relative path), so it has to
  # be exported; the rest are read by shell functions and must not be.
  export CKPT_RC=0
  CREATE_RC=0; TAG_RC=0; REMOVE_RC=0; HALT_RC=0; SESSION_RC=0; SHELL_RC=0; WIN_RC=0
  APP=win10-appvm; ACC=win10-acc; TPL=win10-tpl
  M="$T/m"; R="$T/run.log"; : > "$R"; rm -rf "$T/m"; mkdir -p "$T/m"
}
call(){ local c="$PWD"; cd "$T/tree" || return; cell_appvm unused "$TPL" c1 "$APP" "$ACC"; cd "$c" || return; }

# ---- 1. the arguments the cell cannot work without --------------------------------------------
reset_case; APP=""; call
has 'no AppVM name' && ok_ "no AppVM name is refused by name" || no_ "no AppVM name" "$LINES"
reset_case; ACC=""; call
has 'no churn-subject name' && ok_ "no churn-subject name is refused by name" || no_ "no churn name" "$LINES"

# ---- 2. THE RUN-9 DEFECT ----------------------------------------------------------------------
reset_case; EXISTS=""; call
if has 'DOES NOT EXIST' && has 'rebuild-rig.sh' && ! has 'would not halt'; then
  ok_ "an ABSENT template is named as absent, never as a guest that refused to halt (4 of 11 run-9 failures)"
else no_ "absent template" "$LINES"; fi

# ---- 3. a missing park is a HARD refusal ------------------------------------------------------
reset_case; PARKS=""; call
if has "no 'installed' park" && has 'run the clean cell first' && ! has 'AS-IS'; then
  ok_ "a missing park is refused outright, with no fallback to the template's last state"
else no_ "missing park" "$LINES"; fi

# ---- 4. an unpark that fails leaves the template UNKNOWN --------------------------------------
reset_case; export CKPT_RC=1; call
has 'unknown state' && ok_ "a failed unpark refuses to grade a template in an unknown state" || no_ "failed unpark" "$LINES"

# ---- 5. RE-CREATED, NEVER REUSED -------------------------------------------------------------
reset_case; EXISTS="win10-tpl win10-appvm"; REMOVE_RC=1; call
has 'REFUSING to reuse it' && ok_ "an AppVM that cannot be removed is NOT reused (stale private volume)" || no_ "un-removable AppVM" "$LINES"
reset_case; EXISTS="win10-tpl win10-appvm"; call
has 'removed stale' && ok_ "an existing AppVM IS removed and re-created, not re-pointed at the template" || no_ "existing AppVM is re-created" "$LINES"
reset_case; CREATE_RC=1; call
has 'no subject to grade' && ok_ "a failed create says there is no subject to grade" || no_ "failed create" "$LINES"
reset_case; TAG_RC=1; call
has 'dom0 policy will refuse' && ok_ "an untagged AppVM is refused, because every dom0 call to it would be" || no_ "untagged AppVM" "$LINES"

# ---- 6. the per-boot verdicts are distinct ----------------------------------------------------
reset_case; SESSION_RC=1; call
has 'terminal state, guest unusable' && ok_ "boot: a terminal state is its own verdict" || no_ "boot: terminal" "$LINES"
reset_case; SESSION_RC=2; call
has 'no session within 900s' && ok_ "boot: no session is a different verdict from a terminal state" || no_ "boot: no session" "$LINES"
reset_case; SHELL_RC=1; call
has 'STALE PRIVATE VOLUME' && ok_ "boot: a logon with no shell is STALE PRIVATE VOLUME, not a product defect" || no_ "boot: stale private" "$LINES"
reset_case; SHELL_RC=2; call
has 'no desktop shell within 600s' && ok_ "boot: no shell within the budget is its own verdict" || no_ "boot: no shell" "$LINES"

# ---- 7. the ALL-BOOTS instrument verdict (# GUARD:iirepeat) ----------------------------------
reset_case; WIN_RC=2; call
if has 'every boot with a guest-side window returned an empty dom0 capture'; then
  ok_ "an empty capture on ALL THREE boots is graded - the capture never worked"
else no_ "all-boots empty capture is graded" "$LINES"; fi
reset_case; WIN_RC=0; call
[ "$NO" = 0 ] && ok_ "three boots that mapped a window grade nothing" || no_ "a clean three boots grades nothing" "$LINES"

# ---- 8. SEEN TO FAIL, and DETERMINISM ---------------------------------------------------------
reset_case; call; a="$OK/$NO"
reset_case; EXISTS=""; call; b="$OK/$NO"
[ "$a" != "$b" ] && ok_ "SEEN TO FAIL: the cell's verdict tracks the rig state ($a vs $b)" || no_ "the verdict tracks the rig state" "both gave $a"
# THE SAME INPUTS MUST GIVE THE SAME ANSWER. Two earlier suites for this cell were flaky and the
# nondeterminism was in the harness; this asserts it is gone rather than assuming it.
reset_case; call; x="$OK/$NO/$(printf '%s' "$LINES" | md5sum | cut -c1-8)"
reset_case; call; y="$OK/$NO/$(printf '%s' "$LINES" | md5sum | cut -c1-8)"
reset_case; call; z="$OK/$NO/$(printf '%s' "$LINES" | md5sum | cut -c1-8)"
if [ "$x" = "$y" ] && [ "$y" = "$z" ]; then ok_ "DETERMINISTIC: three identical runs give the identical verdict and log ($x)"
else no_ "deterministic over three identical runs" "$x / $y / $z"; fi

# ---- 9. THE STICK IS NOT THIS CELL'S INSTRUMENT (owner's ruling, 2026-10-22) -----------------
# WAS, until today: this cell created, attached and per-boot bound an evidence stick, and three
# assertions here were greps for those call sites. The owner's ruling retires them: "log stick
# exists for install testing. on appvms and feature tests it has zero sense."
# The measurement behind it: an AppVM's ROOT volume is volatile, HKLM\Software lives on it, and
# Qubes re-derives it from the template at every start - so the bind's LogDir never survives a
# reboot (all three appvm boots of run 39476792836: old='Q:\Qubes Logs'), the agent's real LogDir
# is Q:\Qubes Logs on the PRIVATE volume, and logvol_prove_roundtrip --require-agent-logs can
# therefore never pass here. It FATALed win10-appvm and stopped the 4.3.37 matrix at 4 of 8.
# THESE LEGS EXECUTE THE CELL. The retired ones were greps over its body, which cannot tell a call
# that is present from a call that runs.
reset_case; call
if [ -z "$STICK" ] && [ ! -e "$T/stick-image-called" ]; then
  ok_ "the appvm cell calls NO stick primitive at all - no image, no create, no attach, no bind"
else
  no_ "the appvm cell touches the stick" "recorded:$STICK$([ -e "$T/stick-image-called" ] && printf ' image')"
fi
# AND NOTHING DOWNSTREAM IS ROUTED INTO THE PRE-GRADING PROOF. LOGVOL_IMG is the only thing that
# takes a cell into the driver's --require-agent-logs block, and this cell must leave it empty.
reset_case; LOGVOL_IMG="sentinel-from-the-previous-cell"; call
if [ "${LOGVOL_IMG:-}" = "sentinel-from-the-previous-cell" ]; then
  ok_ "the cell never assigns LOGVOL_IMG, so the driver's prove-pull block (and its proof) is not entered for it"
else
  no_ "the cell set LOGVOL_IMG" "it would be routed into the --require-agent-logs proof it cannot pass: ${LOGVOL_IMG:-}"
fi
unset LOGVOL_IMG
# AND IT STILL RUNS ALL THREE BOOTS AND GRADES THEM. A skip that quietly shortened the cell would
# be a behaviour change nobody asked for.
reset_case; WIN_RC=0; call
if [ "$NO" = 0 ] && [ "$(printf '%s' "$LINES" | command grep -c 'AppVM cold boot')" = 3 ]; then
  ok_ "with no stick the cell still runs and grades all three cold boots, and grades nothing against the release"
else
  no_ "three boots with no stick" "NO=$NO lines=$LINES"
fi
# SEEN TO FAIL: PUT THE SCOPE BACK THE WAY IT WAS. With the class exemption removed the cell
# creates, attaches and binds again - which is the defect this change removes, reproduced.
reset_case
_real_scope=$(declare -f logvol_stick_scope)
logvol_stick_scope(){ return 0; }
call
_defect="$STICK"
eval "$_real_scope"
[ -e "$T/stick-image-called" ] && _defect="image$_defect"
case "$_defect" in
  image*create*attach*bind*) ok_ "SEEN TO FAIL: with the class exemption removed the cell names, creates, attaches and binds the stick again ($_defect)" ;;
  *) no_ "the exemption is what suppresses the stick" "with it removed the cell recorded:${_defect:-nothing} - so these legs prove nothing" ;;
esac
# ...AND THE PER-BOOT BIND IS STILL THE SHAPE IT WAS, once a stick exists. An AppVM's volatile root
# discards LogDir at every shutdown, so a bind on boot 1 only is gone by the boot grading reads
# (run 39225775322: bound to win10-app at 13:27:25, collector read win10-acc exists=0 at 13:30:32).
# This says the call site is per-boot. It does NOT say the bind takes effect - it does not.
case "$_defect" in
  *"bind:c1-appvm-b1"*"bind:c1-appvm-b2"*"bind:c1-appvm-b3"*)
    ok_ "the per-boot bind call site is intact under a stick-bearing scope (three per-boot labels)" ;;
  *) no_ "the per-boot bind call site" "expected three per-boot labels, got:${_defect:-nothing}" ;;
esac
# ...AND A LOG-DEVICE FAILURE STILL ABORTS where a stick IS attached. The appvm cell no longer
# reaches this path, so it is driven under the stick-bearing scope: the rule - a failed log device
# aborts, it does not downgrade - is what two consecutive blind campaigns bought, and lint L29
# polices it. Removing the cell's stick must not quietly retire the rule with it.
reset_case; LOGVOL_FAIL=1
logvol_stick_scope(){ return 0; }
_abort_out=$( (say(){ printf "[SAY] %s\n" "$*"; }; call) 2>&1 ); _abort_rc=$?
eval "$_real_scope"
LOGVOL_FAIL=0
if [ "$_abort_rc" -ne 0 ] && case "$_abort_out" in *"NOT ATTACHED"*) true ;; *) false ;; esac; then
  ok_ "a log-device failure still ABORTS (rc=$_abort_rc) and names the volume as the reason, wherever a stick is attached"
else
  no_ "a log-device failure must abort and say why" "rc=$_abort_rc out=$(printf '%s' "$_abort_out" | tr '\n' '|' | cut -c1-160)"
fi


# THE LOG PATH'S BEHAVIOURAL PROOF IS NOT A GREP OF ANOTHER SELFTEST, and the leg that was here is
# DELETED. It required the string 'proof-agent' to appear in tools/tests/logvol-lib-selftest.sh - a
# file 92ef3414 removed as one of "the five tests-for-tests". So it asserted the contents of a suite
# that no longer exists and had been red ever since, unseen only because run-offline-suites.sh was
# itself inert (its floor stood at 148 against a list of 146, so it exited 2 and ran nothing).
# A test that greps another test is the shape the owner banned outright, and chasing the rename would
# have re-created it.
# WHAT ACTUALLY ENFORCES THE PROPERTY, and it is stronger than the grep ever was: logvol_prove_roundtrip
# is called by the CAMPAIGN - mgmt/harness/matrix.sh and tools/smoke/logvol-smoke.sh - so every
# acceptance run executes it against a real guest and fails on it. Measured in run 40297264818 at
# 11:54:58Z: "logvol smoke (bind arm) PASS - the guest sees the volume, the bind succeeds, and a nonce
# written inside reaches the IMAGE read back with mtools and no guest", with the refutation arm at
# 11:52:09Z proving the bind REFUSES with no volume attached. Both arms, every campaign.
# THE PREDICATE IS THE CALL, NOT THE FILE. A whole-file grep for the flag name passed with the
# flag REMOVED from the call, because the comment above the call explains the flag and the grep
# matched that - measured 2026-10-21 by removing it and watching this very assertion stay green.
# Third time in one session that a check of mine fired on its own documentation. So: the flag must
# appear on a LIVE logvol_prove_roundtrip line, comments excluded.
if command grep -nE 'logvol_prove_roundtrip[^#]*--require-agent-logs' "$ROOT/mgmt/harness/matrix.sh" 2>/dev/null \
     | command grep -qvE '^[0-9]+:[[:space:]]*#'; then
  ok_ "a cell whose agent wrote no log into the resolved LogDir FAILS before grading (asserted on the CALL)"
else
  no_ "the pre-grading proof does not require an agent log" "a blind appvm cell would be graded CLEAN again"
fi

printf 'matrix-appvmcell-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
