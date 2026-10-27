#!/bin/bash
# WHO GETS THE EVIDENCE STICK, and WHO HANDS THE REGISTRY BACK on every exit of an install cell
# run: tools/tests/stick-scope-restore-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"
MX="$ROOT/mgmt/harness/matrix.sh"
QU="$ROOT/mgmt/harness/quick-upgrade.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/stickscope.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

pass=0; fail=0
ok_(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---- what is extracted, and the proof that it was found ----------------------------------------
# THE MARKED REGIONS ARE THE SUBJECT. If either goes missing this suite must say so, not pass on
# the functions alone: a scoping decision that is no longer at the call site is not in force.
SCOPE_SITE=$(awk '/# STICKSCOPE-A/,/# STICKSCOPE-B/' "$MX")
[ -n "$SCOPE_SITE" ] || { echo "FAIL  no marked region in $MX"; exit 1; }
[ "$(printf '%s\n' "$SCOPE_SITE" | grep -c 'STICKSCOPE-A')" = 2 ] \
  && ok_ "both marked regions are present in the shipped matrix (the class decision and the restore call)" \
  || no_ "the marked regions" "found $(printf '%s\n' "$SCOPE_SITE" | grep -c 'STICKSCOPE-A') of 2"

for fn in logvol_stick_scope logvol_restore_now logvol_bind_now cell_appvm cell_reinstall _matrix_release_loop; do
  eval "$(sed -n "/^$fn(){/,/^}\$/p" "$MX")"
  declare -F "$fn" >/dev/null || { echo "FAIL  could not extract $fn from matrix.sh"; exit 1; }
done
# THE PER-CELL JOIN POINT, which is top-level code rather than a function: every exit of every
# install cell continues here, so this is where the restore has to be and the order it runs in is
# the thing under test (proof, then pull, then restore).
JOIN=$(sed -n '/# PULL AFTER EVERY CELL/,/^  fi$/p' "$MX")
# THE RESTORE MOVED TO THE FOOT OF THE CELL LOOP, so the join the simulation runs is the pull block
# PLUS that foot. It had to move: mgmt/harness/log-sweep.sh runs its collector IN THE GUEST and
# Get-LswLogDir resolves the registry LogDir at COLLECTION TIME, so a restore before the sweep sent
# the sweep to the product default while the product had logged to the volume all cell - measured on
# win11-upgrade, restore 05:17:43, collector 05:18:01 reading Q:\Qubes Logs, FAIL 05:18:18, with the
# candidate's own log sitting ungraded in the 05:17:36 volume pull. Concatenating the two regions
# keeps this simulation faithful to the real order (pull, then restore) without needing to drive the
# sweep, which this suite cannot stub.
# The LAST marked region is the restore's; the first is the appvm class decision.
RESTORE_FOOT=$(awk '/# STICKSCOPE-A/{b=""} /# STICKSCOPE-A/,/# STICKSCOPE-B/{b=b $0 "\n"} /# STICKSCOPE-B/{last=b} END{printf "%s", last}' "$MX")
printf '%s\n' "$RESTORE_FOOT" | grep -q 'logvol_restore_now' \
  && ok_ "the last marked region is the restore's new home at the loop foot" \
  || no_ "no restore in the last marked region" "the legs below would be about the harness"
JOIN="$JOIN
$RESTORE_FOOT"
printf '%s\n' "$JOIN" | grep -q 'logvol_restore_now' \
  && ok_ "the extracted join point carries the restore call" \
  || no_ "the join point has no restore" "the legs below would be about the harness"

# AND THE SWEEP MUST COME BEFORE IT IN THE SHIPPED FILE. This is the defect itself, pinned
# structurally rather than by simulation: the guest-log sweep is the third reader of the stick and
# the restore has to follow it. Line numbers off the shipped matrix, comments excluded so the prose
# explaining this cannot satisfy it.
# THE LAST marked region is the join's restore; an EARLIER logvol_restore_now in the file is the
# EXIT trap's, which is a different call site with a different job (it fires when a bind-in-force
# exit never reached the join at all) and must not be what this leg measures. `head -1` picked the
# trap and the leg failed on correct code - so anchor on the marked region instead.
_sw=$(grep -nE '^[[:space:]]*grade_cell_logsweep "' "$MX" | head -1 | cut -d: -f1)
_rs=$(grep -nE '^[[:space:]]*# STICKSCOPE-A$' "$MX" | tail -1 | cut -d: -f1)
if [ -n "$_sw" ] && [ -n "$_rs" ] && [ "$_sw" -lt "$_rs" ]; then
  ok_ "the guest-log sweep (line $_sw) runs BEFORE the restore (line $_rs) - the sweep reads the stick through the registry"
else
  no_ "the restore must follow the guest-log sweep" "sweep at '${_sw:-?}', restore at '${_rs:-?}' - a restore first sends the collector to the product default"
fi
printf '%s\n' "$SCOPE_SITE" | grep -q 'logvol_stick_scope appvm' \
  && ok_ "the appvm cell's stick block is gated on the class decision" \
  || no_ "the appvm gate" "no logvol_stick_scope at the marked call site"

# ---- the rig: HKLM as files, the stick primitives as recorders -------------------------
mkdir -p "$T/tree/mgmt/harness" "$T/m"
printf '#!/bin/bash\nexit 0\n' > "$T/tree/mgmt/harness/checkpoint.sh"; chmod +x "$T/tree/mgmt/harness/checkpoint.sh"

# HKLM, AND THE CALL LOG, AS FILES. They have to be: logvol_restore_now reads the receipt with
# `line=$(logvol_unbind_guest ...)`, a COMMAND SUBSTITUTION - a subshell - so a variable store would
# lose every write the restore made and each leg below would read green with the registry untouched.
# Measured here: with variables, four legs passed over a LogDir that still named the stick.
# REG.LOGDIR is the root LogDir; REG.SAVED is LogDirPreLogvol, which the binder writes ONCE and
# -Restore consumes. The empty-SAVED case is the asymmetry that matters: -Restore then skips its
# write and STILL prints 'restored' and exits 0, so the word cannot be trusted.
rec(){ printf ' %s' "$1" >> "$T/calls"; }
calls(){ cat "$T/calls" 2>/dev/null; }
callsx(){ local x; x=$(calls); printf '%s' "${x:-nothing}"; }
reg(){ cat "$T/reg.logdir" 2>/dev/null; }
regset(){ printf '%s' "$1" > "$T/reg.logdir"; }
saved(){ cat "$T/reg.saved" 2>/dev/null; }
savedset(){ printf '%s' "$1" > "$T/reg.saved"; }
lines(){ cat "$T/lines" 2>/dev/null; }
reset_rig(){
  : > "$T/calls"; : > "$T/lines"; regset 'Q:\Qubes Logs'; savedset ''
  LOGVOL_VM=""; LOGVOL_IMG=""; LOGVOL_BOUND=0
  M="$T/m"; R="$T/run.log"; rm -rf "$T/m"; mkdir -p "$T/m"; : > "$R"
  PASS=0; FAIL=0; RUNNING=1; BIND_RECEIPT="ok"; CELL_FAILS_AT=""; NO_KEY=0
}
say(){ printf '%s\n' "$*" >> "$T/lines"; }
log(){ printf '%s\n' "$*" >> "$T/lines"; }
ok(){  printf '[OK] %s\n' "$*" >> "$T/lines"; }
no(){  printf '[NO] %s\n' "$*" >> "$T/lines"; }
sleep(){ :; }
clock_feature_report(){ :; }
logvol_image(){ printf '%s\n' "$T/logs-$1.img"; }
logvol_create(){ rec create; : > "$1" 2>/dev/null; return 0; }
logvol_attach(){ rec attach; return 0; }
# THE BIND WRITES THE REGISTRY, which is the whole reason a restore exists. It saves the original
# once - exactly as logvol-bind.ps1 does - so a second bind does not overwrite the saved value.
logvol_bind_guest(){ rec bind
  [ -n "$(saved)" ] || savedset "$(reg)"
  regset "Z:\\qwt-logs\\$2"
  [ "$BIND_RECEIPT" = ok ] || return 1
  echo "LOGVOL-BIND ok id=$2 new=$(reg)"; return 0; }
# -Restore, with its two documented asymmetries: it puts back what was SAVED, and when nothing was
# saved it leaves LogDir alone and still answers 'restored'. The receipt's logdir= is read AFTER
# the write, so it is the only field that betrays a restore that restored nothing.
logvol_unbind_guest(){ rec restore
  case "$NO_KEY" in 1) echo "LOGVOL-BIND fail reason=no_qubes_tools_key"; return 1 ;; esac
  [ -n "$(saved)" ] && { regset "$(saved)"; savedset ''; }
  printf 'LOGVOL-BIND restored mode=registry logdir=%s\n' "$(reg | base64 -w0)"
  return 0; }
logvol_clear_guest(){ rec clear; regset ''; savedset ''
  echo "LOGVOL-BIND cleared was=x modules= remaining=0"; return 0; }
logvol_prove_roundtrip(){ rec proof; return 0; }
logvol_pull(){ rec pull; return 0; }
qvm-check(){ [ "$RUNNING" = 1 ]; }
# THE BIND-FAILURE GUEST INVENTORY IS STUBBED, because it is a rig call and this is an offline
# suite. matrix.sh's FATAL bind path captures Get-Disk/Get-Volume from the guest; its first cut
# inlined `timeout 180 ./tools/qtest run` and the runner's rig shim correctly reported
# `TOUCHED-RIG ... qvm-check --quiet sub` - a function stub cannot intercept a binary that `timeout`
# EXECs. It is a named function now, which a suite can replace; this records what it would have done.
logvol_bind_guestview(){ echo "STUB logvol_bind_guestview $1 $2" >> "${GUESTVIEW_LOG:-/dev/null}"; }

# the cell's non-stick surroundings
w_state(){ printf 'Halted\n'; }
w_halt(){ return 0; }
w_session(){ return 0; }
w_usersession(){ return 0; }
w_appvm_shell(){ return 0; }
start_vm(){ :; }
reclone(){ return 0; }
_halt_other_windows(){ :; }
grade_appvm_window(){ return 0; }
qvm-ls(){ printf '%s\n' win10-tpl ckpt-win10-acc-installed; }
qvm-create(){ return 0; }
qvm-tags(){ return 0; }
qvm-remove(){ return 0; }
qvm-features(){ :; }
qvm-prefs(){ printf '\n'; }
qvm-shutdown(){ :; }
qvm-kill(){ :; }
# the install cell's surroundings. boot_with_release_iso is the site that gives an INSTALL cell its
# stick (matrix.sh, untouched by this change), so the stub does what it does: set the two globals.
unpark_installed(){ return 0; }
boot_with_release_iso(){ LOGVOL_VM="$1"; LOGVOL_IMG=$(logvol_image "$1"); rec create; rec attach; return 0; }
locate_release_disc(){ RELDISC="E:"; [ "$CELL_FAILS_AT" = disc ] && { no "$2: no release disc"; return 1; }; return 0; }
run_install(){ return 0; }
detach_release_iso(){ :; }
verify_installed(){ :; }
accept_grade(){ :; }
qwt_products(){ printf '1\n'; }

# the two drivers: a cell, then the join point - exactly the driver's own sequence
eval "drive_appvm(){ local app=win10-app; cell_appvm unused win10-tpl WIN10 win10-app win10-acc; local c=win10-appvm; $JOIN
}"
eval "drive_appvm_cell(){ local app=win10-app; cell_appvm unused win10-tpl WIN10 win10-app win10-acc
}"
eval "drive_reinstall(){ cell_reinstall win10-acc WIN10; local c=win10-reinstall; $JOIN
}"
call(){ local w="$PWD"; cd "$T/tree" || return; "$1"; local rc=$?; cd "$w" || return; return $rc; }

# ---- 1. AN APPVM CELL TOUCHES NO STICK, AND NEVER REACHES THE PROOF ---------------------------
reset_rig; call drive_appvm
case "$(calls)" in
  *create*|*attach*|*bind*) no_ "an appvm cell calls no stick primitive" "recorded:$(callsx)" ;;
  *) ok_ "an appvm cell calls neither create, attach nor bind (recorded:$(callsx))" ;;
esac
case "$(calls)" in
  *proof*) no_ "an appvm cell does not reach the pre-grading proof" "it did: $(calls) - and --require-agent-logs cannot pass there" ;;
  *) ok_ "an appvm cell never reaches the pre-grading --require-agent-logs proof (the FATAL that stopped 4.3.37 at 4 of 8)" ;;
esac
[ "$(reg)" = 'Q:\Qubes Logs' ] \
  && ok_ "an appvm cell leaves LogDir as it found it ('$(reg)')" \
  || no_ "an appvm cell must not write LogDir" "it reads '$(reg)'"

# SEEN TO FAIL: the class exemption put back the way it was.
reset_rig
_real_scope=$(declare -f logvol_stick_scope); logvol_stick_scope(){ return 0; }
call drive_appvm; _d="$(calls)"
eval "$_real_scope"
case "$_d" in
  *create*attach*bind*proof*) ok_ "SEEN TO FAIL: with the exemption removed the appvm cell binds again AND reaches the proof ($_d)" ;;
  *) no_ "the exemption is what suppresses the stick" "with it removed the cell recorded:${_d:-nothing}" ;;
esac
# AND THE REGISTRY WRITE IS THE DEFECT ITSELF, judged on the CELL alone. Judging it after the join
# point would read clean either way: with the exemption removed the cell binds and the join point
# then restores, so only the cell-scoped run shows what the AppVM was left holding.
reset_rig; logvol_stick_scope(){ return 0; }
call drive_appvm_cell; _dreg="$(reg)"
eval "$_real_scope"
case "$_dreg" in
  *qwt-logs*) ok_ "SEEN TO FAIL: ...and the AppVM's registry names the stick again ('$_dreg') - on a volatile root that discards it at the next start" ;;
  *) no_ "the control must reproduce the registry write" "LogDir read '$_dreg'" ;;
esac

# ---- 2. AN INSTALL CELL BINDS, AND RESTORES AFTER ITS PULL ------------------------------------
reset_rig; call drive_reinstall
case "$(calls)" in
  *bind*) ok_ "an install cell still binds the stick (recorded:$(callsx))" ;;
  *) no_ "an install cell must still bind" "recorded:$(callsx)" ;;
esac
case "$(calls)" in
  *proof*pull*restore*) ok_ "the restore runs AFTER the proof and AFTER the pull - both read the stick, and a restore before them manufactures an abort" ;;
  *) no_ "the restore must follow the proof and the pull" "order was:$(calls)" ;;
esac
case "$(reg)" in
  *qwt-logs*) no_ "an install cell must not leave LogDir naming the stick" "it reads '$(reg)'" ;;
  *) ok_ "after the cell LogDir reads '$(reg)' - it no longer names the stick" ;;
esac

# ---- 3. A CELL THAT FAILS MID-CELL STILL RESTORES ---------------------------------------------
# matrix.sh is `set -uo pipefail` with NO -e, so a failing step is a `return` out of the cell and
# lands at the same join point. This drives the reinstall cell's locate_release_disc failure, which
# is a post-bind return, and judges the registry afterwards.
reset_rig; CELL_FAILS_AT=disc; call drive_reinstall
case "$(calls)" in
  *bind*restore*) ok_ "a cell that FAILED after its bind still restores (recorded:$(callsx))" ;;
  *) no_ "a failure path must restore too" "recorded:$(callsx)" ;;
esac
lines | grep -q 'no release disc' \
  && ok_ "...and the cell really did take its failure path, so the leg above is not about a healthy cell" \
  || no_ "the failure was not injected" "$(lines)"
case "$(reg)" in
  *qwt-logs*) no_ "a failed cell must not leave LogDir naming the stick" "it reads '$(reg)'" ;;
  *) ok_ "after a FAILED cell LogDir reads '$(reg)'" ;;
esac

# SEEN TO FAIL: the restore call taken out of the join point. The install cell must then leave the
# stick path in the registry - the shipped state before today, reproduced.
reset_rig
_nores=$(printf '%s\n' "$JOIN" | grep -v 'logvol_restore_now')
eval "drive_norestore(){ cell_reinstall win10-acc WIN10; local c=win10-reinstall; $_nores
}"
call drive_norestore
case "$(reg)" in
  *qwt-logs*) ok_ "SEEN TO FAIL: with the restore call removed the guest's LogDir still reads '$(reg)'" ;;
  *) no_ "the restore call is what clears the stick path" "without it LogDir read '$(reg)' - the legs above prove nothing" ;;
esac

# ---- 4. QUICK-UPGRADE IS UNCHANGED, AND STILL BINDS ------------------------------------------
# Not narrowed: a wedge DURING an install is the one case the stick is readable for, and this is the
# project's short cycle (Jev: wedge_coverage_not_lost 0.32 on narrowing further). Its own bind block
# is extracted from the shipped file and RUN.
QBLK=$(awk '/^if \[ -n "\$LOGVOL_IMG" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$QU")
if printf '%s\n' "$QBLK" | grep -q 'logvol_bind_guest'; then
  reset_rig; LOGVOL_IMG="$T/logs-sub.img"; SUBJECT=sub; OUT="$T/m"
  eval "drive_qu(){ $QBLK
}"
  drive_qu
  case "$(calls)" in
    *bind*) ok_ "quick-upgrade still binds the stick over the golden - unchanged by this work (recorded:$(callsx))" ;;
    *) no_ "quick-upgrade must keep binding" "recorded:$(callsx)" ;;
  esac
  case "$(reg)" in
    *qwt-logs*) ok_ "...and its guest's LogDir names the stick, which is what makes a wedge mid-install readable" ;;
    *) no_ "quick-upgrade's bind did not take" "LogDir read '$(reg)'" ;;
  esac
  case "$(calls)" in
    *restore*) no_ "quick-upgrade must not have gained a restore" "recorded:$(callsx) - its subject is the short cycle's own guest" ;;
    *) ok_ "quick-upgrade gained no restore and no class gate - its block is byte-for-byte the shipped one" ;;
  esac
else
  no_ "quick-upgrade's bind block was not found" "the extraction returned $(printf '%s' "$QBLK" | wc -l) line(s)"
fi

# ---- 5. THE RESTORE'S OWN JUDGEMENT: the word 'restored' is not the property -----------------
# -Restore skips its write when LogDirPreLogvol is absent and STILL prints 'restored' and exits 0,
# so logvol_unbind_guest returns 0 over a registry that still names the stick. The park's -Clear
# deletes the saved value (logvol-bind.ps1), which is exactly how that state arises. The receipt's
# logdir= is read AFTER the write and is the only field that shows it.
reset_rig; LOGVOL_VM=sub; LOGVOL_BOUND=1; regset 'Z:\qwt-logs\sub'; savedset ''
logvol_restore_now nothing-saved; rc=$?
if [ "$rc" != 0 ] && [ -e "$T/m/nothing-saved-logvol-unrestored.marker" ]; then
  ok_ "a restore that reported success over an unchanged LogDir is caught (rc=$rc) and marked, not believed"
else
  no_ "the receipt must be decoded, not trusted" "rc=$rc marker=$([ -e "$T/m/nothing-saved-logvol-unrestored.marker" ] && echo yes || echo no)"
fi
lines | grep -q 'STILL reads' \
  && ok_ "...and it says what LogDir actually reads, so the next reader is not sent at the bind" \
  || no_ "the warning must quote the value" "$(lines)"

# SEEN TO FAIL: the same call with the saved value present must pass, or the leg above is just
# "the restore always fails".
reset_rig; LOGVOL_VM=sub; LOGVOL_BOUND=1; regset 'Z:\qwt-logs\sub'; savedset 'Q:\Qubes Logs'
logvol_restore_now saved; rc=$?
{ [ "$rc" = 0 ] && [ "$(reg)" = 'Q:\Qubes Logs' ] && [ ! -e "$T/m/saved-logvol-unrestored.marker" ]; } \
  && ok_ "with the original saved the same call succeeds and LogDir reads '$(reg)' (so the leg above is about the receipt, not the function)" \
  || no_ "a real restore must pass" "rc=$rc logdir='$(reg)'"

# ---- 6. THE GATE IS A BIND, NOT AN IMAGE -----------------------------------------------------
# The stick is attached unconditionally while the bind is gated on LOGVOL_BIND, so under
# LOGVOL_BIND=0 LOGVOL_IMG is set and nothing was ever bound. Gating on the image would push a
# pushrun at a guest whose registry nobody touched.
reset_rig; LOGVOL_VM=sub; LOGVOL_IMG="$T/x.img"; LOGVOL_BOUND=0
logvol_restore_now unbound; rc=$?
{ [ "$rc" = 0 ] && case "$(calls)" in *restore*) false ;; *) true ;; esac; } \
  && ok_ "with a stick attached but never bound the restore is a no-op (LOGVOL_BIND=0 runs on the stock log path)" \
  || no_ "the gate must be the bind" "rc=$rc recorded:$(callsx)"

# AND THE LATCH IS WHAT SETS IT. logvol_bind_now latches before calling the binder, because a bind
# can write LogDir and then return no 'ok' receipt - and that exit leaves the registry naming the
# stick. Driven through the real logvol_bind_now with a refusing binder.
reset_rig; LOGVOL_VM=sub; LOGVOL_IMG="$T/x.img"; BIND_RECEIPT=refuse
( logvol_bind_now sub lbl ) >/dev/null 2>&1
BIND_RECEIPT=ok
# the subshell above took the latch with it, so re-run it in this shell to read the latch
reset_rig; LOGVOL_VM=sub; LOGVOL_IMG="$T/x.img"; BIND_RECEIPT=refuse
exit(){ return 0; }   # the bind FATAL ends the campaign; here it must only end the call
logvol_bind_now sub lbl >/dev/null 2>&1
unset -f exit
[ "${LOGVOL_BOUND:-0}" = 1 ] \
  && ok_ "a bind that wrote the registry and then refused still arms the restore (latched before the call, not after)" \
  || no_ "the latch must precede the binder" "LOGVOL_BOUND=${LOGVOL_BOUND:-unset} after a refusing bind"

# ---- 7. AN UNREACHABLE GUEST IS A WARN, NEVER AN ABORT ---------------------------------------
# A wedge is the one case the stick exists for. Converting it into a campaign abort would break the
# instrument at exactly the moment it is the only one left.
reset_rig; LOGVOL_VM=sub; LOGVOL_BOUND=1; RUNNING=0
out=$(logvol_restore_now wedged 2>&1); rc=$?
if [ "$rc" != 0 ] && [ -e "$T/m/wedged-logvol-unrestored.marker" ] && case "$(calls)" in *restore*) false ;; *) true ;; esac; then
  ok_ "a guest that is not running is marked unrestored and never pushed at (rc=$rc), so a wedge is not turned into an abort"
else
  no_ "an unreachable guest must WARN and mark" "rc=$rc recorded:$(callsx)"
fi
lines | grep -q '\[WARN\]' \
  && ok_ "...and it is a [WARN], with the park-time clear named as the backstop" \
  || no_ "the miss must be a WARN line" "$(lines)"

# A KEY A PREVIOUS UNINSTALL TOOK IS A BENIGN OUTCOME, not a failed restore: with the key gone
# nothing names the stick either. matrix.sh re-asserts the bind after an install for this reason.
reset_rig; LOGVOL_VM=sub; LOGVOL_BOUND=1; NO_KEY=1
logvol_restore_now nokey; rc=$?; NO_KEY=0
{ [ "$rc" = 0 ] && [ ! -e "$T/m/nokey-logvol-unrestored.marker" ]; } \
  && ok_ "a missing Qubes Tools key is graded benign, not as a failed restore" \
  || no_ "no_qubes_tools_key must be benign" "rc=$rc"

# ---- 8. THE EXIT TRAP IS THE SAME TRAP, AND IT IS IDEMPOTENT ---------------------------------
# Five bind-in-force exits leave matrix.sh without passing the join point. Bash keeps ONE EXIT
# trap, so the restore is composed into the existing one rather than registered beside it - a
# second `trap ... EXIT` would silently discard the loop and claim release.
reset_rig; LOGVOL_VM=sub; LOGVOL_BOUND=1; regset 'Z:\qwt-logs\sub'; savedset 'Q:\Qubes Logs'
MATRIX_LOOP_CREATED=""; c=win10-clean
_matrix_release_loop >/dev/null 2>&1
case "$(reg)" in
  *qwt-logs*) no_ "the EXIT trap must restore on the paths that bypass the join point" "LogDir read '$(reg)'" ;;
  *) ok_ "the EXIT trap restores on a bind-in-force exit that never reached the join point (LogDir '$(reg)')" ;;
esac
# and a second pass does nothing, because the join point normally got there first
: > "$T/calls"; _matrix_release_loop >/dev/null 2>&1
case "$(calls)" in
  *restore*) no_ "the trap must be idempotent" "it pushed a second restore: $(calls)" ;;
  *) ok_ "a second pass is a no-op - the trap also fires at the normal end, after the join point restored" ;;
esac
# AND IT DID NOT REPLACE THE LOOP RELEASE. The function's own job must still run.
reset_rig; MATRIX_LOOP_CREATED=loop9; MATRIX_CDROM_CLAIMED="sub"; c=x
claim_drop_loop(){ rec claimdrop; return 0; }
udisksctl(){ rec loopdelete; return 0; }
_matrix_release_loop >/dev/null 2>&1
case "$(calls)" in
  *claimdrop*loopdelete*) ok_ "the trap still drops the cdrom claims and releases the loop - the restore was composed in, not substituted for it" ;;
  *) no_ "the trap's own work must survive" "recorded:$(callsx)" ;;
esac

# ---- 9. THE PARK-TIME CLEAR IS KEPT ----------------------------------------------------------
# -Clear is WIDER than -Restore (it strips LogDir from every subkey) and it REMOVES the value rather
# than writing one, which is what an AppVM must inherit; -Restore writes back the product's path,
# including the 'Q:\Qubes Logs' literal the bind synthesises when LogDir was absent. Jev scored
# deleting the clear 0.45: a cell that dies between bind and restore would otherwise park with the
# registry naming the stick. Driven by executing park_installed's clear arm.
eval "$(sed -n '/^park_installed(){/,/^}$/p' "$MX")"
w_drain_and_shutdown(){ :; }
w_halt_stable(){ return 0; }
checkpoint_sh(){ :; }
reset_rig; regset 'Z:\qwt-logs\win10-acc'; savedset 'Q:\Qubes Logs'; LOGVOL_IMG="$T/x.img"
w_state(){ printf 'Running\n'; }
( cd "$T/tree" && park_installed win10-acc WIN10-clean ) >/dev/null 2>&1
w_state(){ printf 'Halted\n'; }
case "$(calls)" in
  *clear*) ok_ "park_installed still CLEARS LogDir before the park, so what an AppVM inherits carries no value at all" ;;
  *) no_ "the park-time clear must be kept as the backstop" "recorded:$(callsx)" ;;
esac

printf '\nRESULT: %d passed, %d failed  (fixtures: %s)\n' "$pass" "$fail" "$T"
[ "$fail" -eq 0 ]
