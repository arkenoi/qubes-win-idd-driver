#!/bin/bash
# matrix-appvmcell-grade-selftest.sh - the appvm cell's PRECONDITIONS and per-boot verdicts.
#
# WHAT IT GRADES. cell_appvm() restores an 'installed' park into a template, derives an AppVM from it
# and cold-boots it three times. Its window verdict was split out into grade_appvm_window() (suite:
# matrix-appvmwindow-grade-selftest.sh); what remains here is the entry refusals, the per-boot
# session/shell verdicts, and the all-boots instrument verdict.
#
# WHAT IT PINS, each a measured incident recorded in matrix.sh itself:
#   * an ABSENT template is an infrastructure fact knowable in one call, not a guest that refused to
#     halt. w_state returns an EMPTY string for a VM that does not exist, and "" != Halted, so an
#     absent template used to be waited on for 420 s and then failed as "template would not halt" -
#     "FOUR of that campaign's ELEVEN failures were this one message" (run 9).
#   * a missing 'installed' park is a HARD refusal: without it there is no deterministic
#     release-carrying state to derive from, and "AS-IS" would mean "whatever the template last held".
#   * an AppVM is RE-CREATED, never reused. Its private volume seeds from the template AT CREATION
#     ONLY, so re-basing a template under an existing AppVM leaves a stale private - no profile, no
#     shell (owner correction 2026-09-04). A reused one must read as STALE PRIVATE VOLUME, never as a
#     product defect.
#   * an empty dom0 capture on EVERY boot is the capture never working; on SOME boots alongside one
#     that mapped a window it is a dom0 desktop switch, which the owner confirmed on 2026-10-10 and
#     which is NOT graded.
#
# WHY IT IS SHAPED LIKE THIS. Two earlier attempts at this suite were FLAKY - 14/1, 15/0, 10/5 and
# then 19/1, 16/4, 19/1 - and both times the nondeterminism was in the HARNESS, not the function:
# a case file read by external stub programs, assignment prefixes on a function call that did not
# reach those programs, a cleanup trap inherited by a background subshell, and a stub defined inside
# one helper shadowing the real function for another (bash function definitions are global). Driven
# the plain way - stubs as ordinary shell functions reading ordinary variables, no PATH tricks, no
# subshells, no case files - cell_appvm is perfectly deterministic. A flaky suite was never evidence
# about the product; it was evidence about me.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"
T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-appvmcell.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

eval "$(sed -n '/^cell_appvm(){/,/^}$/p' "$ROOT/mgmt/harness/matrix.sh")"
declare -f cell_appvm >/dev/null || { echo "FAIL could not extract cell_appvm"; exit 1; }

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
logvol_bind_now(){ :; }
# The appvm cell attaches its own evidence volume before the first boot, and since 2026-10-20 a
# failure there ABORTS the campaign rather than grading a guest whose wedge would be unreadable.
# Stub the primitives so the cell can run here; LOGVOL_FAIL=1 drives the failure path.
logvol_image(){ printf '%s\n' "$T/logs-$1.img"; }
logvol_create(){ [ "${LOGVOL_FAIL:-0}" = 1 ] && return 1; : > "$1" 2>/dev/null; return 0; }
logvol_attach(){ [ "${LOGVOL_FAIL:-0}" = 1 ] && return 1; return 0; }
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

reset_case(){ OK=0; NO=0; LINES=""
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

# THE CELL MUST POINT THE APPVM AT ITS OWN VOLUME. It creates and attaches one before the first
# boot but, until 2026-10-20, never bound it - and an AppVM inherits the TEMPLATE's registry, so
# LogDir named the template's directory. On run 39225775322 both appvm cells swept
# Z:\qwt-logs\win10-acc while holding a volume with id win10-app, their collector reported
# logdir.exists=0, and both failed INVALID-SWEEP-BLIND with 0 QWT lines.
# The predicate is the call the cell actually makes on its OWN subject ($app), not the mention of
# a function name: a bind of the churn subject would read the same to a careless grep.
_appvm_fn=$(sed -n '/^cell_appvm(){/,/^}$/p' mgmt/harness/matrix.sh)
[ -n "$_appvm_fn" ] || _appvm_fn=$(sed -n '/appvm) /,/^  }/p' mgmt/harness/matrix.sh)
if printf '%s' "$_appvm_fn" | command grep -qE 'logvol_bind_now "\$app"'; then
  ok_ "the appvm cell binds the log volume it attached, on its OWN subject"
else
  no_ "the appvm cell binds its own volume" "no logvol_bind_now \"\$app\" in the cell body"
fi
if printf '%s' "$_appvm_fn" | command grep -qE '\[ "\$b" = 1 \].*logvol_bind_now|b" = 1 \]'; then
  ok_ "...once, on the first boot, so boots 2 and 3 write where boot 1 pointed"
else
  no_ "the appvm bind is guarded to the first boot" "no first-boot guard around it"
fi

# A LOG-DEVICE FAILURE ABORTS, IT DOES NOT DOWNGRADE. Until 2026-10-20 this path printed
# "[WARN] log volume not attached", blanked LOGVOL_IMG and graded the cell anyway - which is how
# two consecutive campaigns graded both appvm cells blind, and how WIN10-clean reached a SPIN wedge
# with nothing readable inside it. The cell must stop, and the campaign with it: every later cell
# would be graded by the same broken instrument.
reset_case; LOGVOL_FAIL=1
# say() appends to $LINES, and the cell EXITS, so nothing after it runs and the subshell takes
# $LINES with it. Redefine say to print, for this one call only.
_abort_out=$( (say(){ printf "[SAY] %s\n" "$*"; }; call) 2>&1 ); _abort_rc=$?
LOGVOL_FAIL=0
if [ "$_abort_rc" -ne 0 ]; then
  ok_ "a log-device failure ABORTS the cell (rc=$_abort_rc), it does not grade on"
else
  no_ "a log-device failure must abort" "rc=0 - the cell carried on with no instrument that survives a wedge"
fi
case "$_abort_out$LINES" in
  *"NOT ATTACHED"*) ok_ "...and it says the volume was not attached, as the reason" ;;
  *) no_ "the abort names the log device" "got: $(printf '%s' "$_abort_out$LINES" | tr '\n' '|' | cut -c1-160)" ;;
esac

printf 'matrix-appvmcell-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
