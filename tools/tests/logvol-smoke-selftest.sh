#!/usr/bin/env bash
# logvol-smoke-selftest.sh - the bind smoke test's own verdicts, every one seen to fire.
#
# mgmt/harness/logvol-smoke.sh exists because campaign 40134888669 aborted 11 minutes in on a log
# volume the guest could not see, and the preparation gates written afterwards check everything
# AROUND that bind and not the bind itself (owner: "and why we did not smoke test the bind"). A
# smoke test nobody has watched refuse is the same mistake one layer up, so every arm is driven here
# against stub libraries: no guest, no loop device, no rig call.
#
# THE ARM THAT MATTERS MOST is --no-attach. With nothing attached the bind MUST refuse; if it
# "succeeds" there then its receipt is not about the volume at all and every PASS of the smoke test
# is void. That is asserted in both directions.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/logvol-smoke-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$T/bin"

# ---- the rig, stubbed: nothing here touches a qube ----------------------------------------------
# qvm-ls answers the one query the script makes (STATE of the subject) from a file, so "the guest
# halted" and "the guest never existed" are both drivable.
cat > "$T/bin/qvm-ls" <<'EOF'
#!/bin/bash
cat "${SUBJ_STATE_FILE:-/dev/null}"
EOF
for c in qvm-start qvm-remove qvm-kill qvm-device qvm-features qvm-tags udisksctl; do
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/$c"
done
chmod +x "$T/bin"/*

# golden.sh verifies unless told otherwise; clone-guest succeeds unless told otherwise
cat > "$T/golden.sh" <<'EOF'
#!/bin/bash
[ "${GOLDEN_BAD:-0}" = 1 ] && { echo "does not verify"; exit 1; }
exit 0
EOF
cat > "$T/clone.sh" <<'EOF'
#!/bin/bash
[ "${CLONE_BAD:-0}" = 1 ] && { echo "clone refused"; exit 1; }
printf '%s|Halted\n' "$2" > "${SUBJ_STATE_FILE:?}"
exit 0
EOF
# qtest: 'run' answers UP unless the guest is meant never to come up
cat > "$T/qtest" <<'EOF'
#!/bin/bash
case "${GUEST_UP:-1}" in 0) exit 1 ;; esac
echo UP
exit 0
EOF
chmod +x "$T/golden.sh" "$T/clone.sh" "$T/qtest"

# the library, stubbed: each function answers from a variable
cat > "$T/logvol-lib.sh" <<'EOF'
logvol_image(){ echo "${LV_IMG:-/tmp/stub.img}"; }
logvol_create(){ [ "${LV_CREATE_FAIL:-0}" = 1 ] && { echo "create failed"; return 1; }; return 0; }
logvol_attach(){ [ "${LV_ATTACH_FAIL:-0}" = 1 ] && { echo "attach failed"; return 1; }; return 0; }
logvol_loop_of(){ echo loop9; }
logvol_loop_release(){ return 0; }
logvol_bind_guest(){ if [ "${LV_BIND_OK:-1}" = 1 ]; then echo "LOGVOL-BIND ok drive=Z:"; return 0; fi
                     echo "LOGVOL-BIND fail reason=no_volume_labelled_DIAG_with_LOGVOL.TAG"; return 1; }
logvol_prove_roundtrip(){ [ "${LV_RT_OK:-1}" = 1 ] && return 0; echo "nonce never arrived"; return 1; }
# THE PHASE APPLIER. The smoke test applies the GRADED device set from logvol-lib's single
# declaration - the whole point of it existing, since a cell composing its own set would be proving
# a configuration no campaign runs. Drivable so its refusal is a leg too.
logvol_devices_apply(){ [ "${LV_PHASE_OK:-1}" = 1 ] && { echo "device set '$2' applied to $1"; return 0; }
                        echo "REFUSED: device set '$2' on $1"; return 2; }
EOF
printf 'qwt_shutdown(){ return 0; }\n' > "$T/shutdown-lib.sh"
printf 'vm_lock(){ [ "${LOCK_HELD:-0}" = 1 ] && return 1; return 0; }\nvm_unlock(){ return 0; }\n' > "$T/vmlock.sh"

run(){ # -> rc; output in $T/out, verdicts in $T/o/verdict.tsv
  rm -rf "$T/o"; mkdir -p "$T/o"
  printf 'logvol-smoke|Halted\n' > "$T/state"
  PATH="$T/bin:$PATH" \
  SUBJ_STATE_FILE="${SUBJ_STATE_FILE_OVERRIDE:-$T/state}" \
  LOGVOL_SMOKE_OUT="$T/o" QTEST="$T/qtest" GOLDEN_SH="$T/golden.sh" CLONE_SH="$T/clone.sh" \
  LOGVOL_LIB="$T/logvol-lib.sh" SHUTDOWN_LIB="$T/shutdown-lib.sh" VMLOCK_LIB="$T/vmlock.sh" \
  LV_IMG="$T/stub.img" \
  GOLDEN_BAD="${GOLDEN_BAD:-0}" CLONE_BAD="${CLONE_BAD:-0}" GUEST_UP="${GUEST_UP:-1}" \
  LV_BIND_OK="${LV_BIND_OK:-1}" LV_RT_OK="${LV_RT_OK:-1}" LOCK_HELD="${LOCK_HELD:-0}" \
  LV_CREATE_FAIL="${LV_CREATE_FAIL:-0}" LV_ATTACH_FAIL="${LV_ATTACH_FAIL:-0}" \
  LV_PHASE_OK="${LV_PHASE_OK:-1}" \
    bash mgmt/harness/logvol-smoke.sh --deadline 1 "$@" > "$T/out" 2>&1
  echo $?
}
vtsv(){ cat "$T/o/verdict.tsv" 2>/dev/null | tr '\t' ' '; }

# ---- 1. the clear case ------------------------------------------------------------------------
rc=$(run)
if [ "$rc" = 0 ] && command grep -qa '^PASS' "$T/o/verdict.tsv" 2>/dev/null; then
  ok "attached, bound, and the nonce reaches the image -> PASS"
else no "the clear case passes" "rc=$rc $(vtsv)"; fi

# ---- 2. THE REFUTATION ARM, both directions ----------------------------------------------------
rc=$(LV_BIND_OK=0 run --no-attach)
if [ "$rc" = 0 ] && command grep -qa 'with NO volume attached the bind REFUSES' "$T/o/verdict.tsv"; then
  ok "--no-attach + the bind refusing is a PASS - that is what makes a real PASS mean something"
else no "--no-attach with a refusing bind passes" "rc=$rc $(vtsv)"; fi

rc=$(LV_BIND_OK=1 run --no-attach)
if [ "$rc" = 1 ] && command grep -qa 'does not measure the volume' "$T/o/verdict.tsv"; then
  ok "--no-attach + the bind SUCCEEDING is a FAIL - the receipt would not be about the volume"
else no "--no-attach with a succeeding bind fails" "rc=$rc $(vtsv)"; fi

# ---- 3. the failure this cell exists for -------------------------------------------------------
rc=$(LV_BIND_OK=0 run)
if [ "$rc" = 1 ] && command grep -qa 'the guest sees the log volume and the bind succeeds' "$T/o/verdict.tsv"; then
  ok "attached but the bind REFUSES -> FAIL, which is campaign 40134888669 caught in minutes"
else no "a refusing bind with the volume attached fails" "rc=$rc $(vtsv)"; fi
if command grep -qa 'guestview.out' "$T/o/verdict.tsv"; then
  ok "...and it names the guest's own disk inventory, not just the binder's one sentence"
else no "the FAIL names the guest inventory" "$(vtsv)"; fi

# ---- 4. a bind that says ok while no evidence arrives ------------------------------------------
rc=$(LV_RT_OK=0 run)
if [ "$rc" = 1 ] && command grep -qa 'reaches the image' "$T/o/verdict.tsv"; then
  ok "bound but the ROUND TRIP never arrives -> FAIL: an ok receipt is not evidence that evidence will"
else no "a failed round trip fails the cell" "rc=$rc $(vtsv)"; fi

# ---- 5. rig states are INVALID-RIG, never a bind finding ---------------------------------------
rc=$(GOLDEN_BAD=1 run)
if [ "$rc" = 2 ] && command grep -qa 'INVALID-RIG' "$T/o/verdict.tsv"; then
  ok "a golden that does not verify is INVALID-RIG - it says nothing about the bind"
else no "a bad golden is INVALID-RIG" "rc=$rc $(vtsv)"; fi

rc=$(CLONE_BAD=1 run)
if [ "$rc" = 2 ] && command grep -qa 'the golden clones' "$T/o/verdict.tsv"; then
  ok "a clone that fails is INVALID-RIG"
else no "a failed clone is INVALID-RIG" "rc=$rc $(vtsv)"; fi

rc=$(GUEST_UP=0 run)
if [ "$rc" = 2 ] && command grep -qa 'answers qrexec' "$T/o/verdict.tsv"; then
  ok "a guest that never answers qrexec is INVALID-RIG, with the wait exit named"
else no "a guest that never comes up is INVALID-RIG" "rc=$rc $(vtsv)"; fi

rc=$(LV_ATTACH_FAIL=1 run)
if [ "$rc" = 2 ] && command grep -qa 'the volume attaches' "$T/o/verdict.tsv"; then
  ok "an attach that fails is INVALID-RIG, not a FAIL about the guest"
else no "a failed attach is INVALID-RIG" "rc=$rc $(vtsv)"; fi

rc=$(LV_PHASE_OK=0 run)
if [ "$rc" = 2 ] && command grep -qa 'the graded device set applies' "$T/o/verdict.tsv"; then
  ok "a graded device set that cannot be applied is INVALID-RIG - the cell never boots a guest whose device set is unknown"
else no "a refused device set is INVALID-RIG" "rc=$rc $(vtsv)"; fi

rc=$(LOCK_HELD=1 run)
if [ "$rc" = 2 ] && command grep -qa 'rig lock' "$T/o/verdict.tsv"; then
  ok "a held rig lock refuses - one VM-mutating job at a time"
else no "a held lock refuses" "rc=$rc $(vtsv)"; fi

# ---- 6. it cleans up after itself, and --keep does not ------------------------------------------
rc=$(run)
if command grep -qa 'teardown: .* removed' "$T/out"; then
  ok "the subject is removed on the way out - a smoke test does not leave a leftover"
else no "it tears the subject down" "$(tail -2 "$T/out" | tr '\n' ' ')"; fi
rc=$(run --keep)
if command grep -qa 'leaving .* in place' "$T/out"; then
  ok "--keep leaves it for inspection instead"
else no "--keep leaves the subject" "$(tail -2 "$T/out" | tr '\n' ' ')"; fi

echo
printf 'logvol-smoke-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
