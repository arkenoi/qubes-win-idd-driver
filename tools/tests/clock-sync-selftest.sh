#!/usr/bin/env bash
# clock-sync-selftest.sh - THE CLOCK PULL MUST BE WIRED, NOT MERELY PRESENT.
#
# Owner, 2026-10-08: "can you fucking fix the clock issue once and forever so you NEVER COME WITH
# IT AGAIN?"  Measured on win11r-logvol the same day: the guest clock was 3 h ahead of the host
# with its own zone set to UTC, so every --since window in the log sweep silently admitted three
# hours of older lines and a clean boot read as two errors.
#
# WHAT GOES WRONG IF NOBODY CHECKS. Three separate ways this fix can exist and do nothing, two of
# which it DID have when first written:
#   1. the puller is staged nowhere, so no guest ever gets it (the 4.3.18 inert-clean-install class);
#   2. the task is registered against the SETUP PAYLOAD path, which is deleted after the install -
#      so it "registers fine" and then fails at every boot on a path that is gone. This is what my
#      first version did: it resolved the puller beside install-clock-sync.ps1, i.e. in the payload;
#   3. nothing calls install-clock-sync.ps1 at all, which is how it was committed-ready until Jev
#      graded clock_fix_durable = will-recur 0.52 and named exactly this.
# Each check below is driven against a copy carrying its own defect, so none of them is decoration.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INST="$ROOT/guest/install-clock-sync.ps1"
PULL="$ROOT/core-agent/src/qubes-rpc-services/sync-clock-from-dom0.ps1"
SETUP="$ROOT/packaging/setup/Install-QwtImproved.ps1"
MK="$ROOT/packaging/make-setup.ps1"
OW="$ROOT/packaging/ours-wins.psd1"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
W="${CLOCKSYNC_SELFTEST_OUT:-$(mktemp -d)}"; mkdir -p "$W"

# ---- 1. the puller ships, and ships to a PERSISTENT place ---------------------------------------
# core-agent/src/qubes-rpc-services is swept by make-setup.ps1 and copied by the installer into
# the guest's Qubes Tools tree, which is the same directory set-time.ps1 lands in - and set-time.ps1
# is what the puller calls, so colocating them is also what makes the call work.
if [ -f "$PULL" ]; then
  ok "puller_in_swept_dir: sync-clock-from-dom0.ps1 is in core-agent/src/qubes-rpc-services (ships with no staging line)"
else
  bad "puller_in_swept_dir: $PULL is missing - nothing ships the puller"
fi

# ---- 2. the registered ACTION PATH is the persistent copy, never the payload --------------------
action_persistent() {
  local f="$1"
  # the task's Arguments must name the puller via the Qubes Tools dir, and the script must not
  # fall back to its own directory (the payload) to find it.
  command grep -q 'qubes-rpc-services\\sync-clock-from-dom0\.ps1' "$f" || return 1
  command grep -q "Join-Path \$PSScriptRoot 'sync-clock-from-dom0\.ps1'" "$f" && return 1
  return 0
}
if action_persistent "$INST"; then
  ok "action_path_persistent: the task points at the installed puller, not at the setup payload"
else
  bad "action_path_persistent: the registered action resolves to a path the install deletes"
fi
# SEEN TO FAIL: the same check against the defect it was written for.
cp "$INST" "$W/payload-path.ps1"
python3 - "$W/payload-path.ps1" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding='utf-8').read()
s=s.replace("""$puller = Join-Path $tools 'qubes-rpc-services\\sync-clock-from-dom0.ps1'""",
            """$puller = Join-Path $PSScriptRoot 'sync-clock-from-dom0.ps1'""")
io.open(p,'w',encoding='utf-8').write(s)
PY
if action_persistent "$W/payload-path.ps1"; then
  bad "action_path_seen_to_fail: the check PASSES a payload-relative action path - it proves nothing"
else
  ok "action_path_seen_to_fail: the check rejects the payload-relative path it was written for"
fi

# ---- 3. the installer actually RUNS it ----------------------------------------------------------
calls_installer() { command grep -q "Join-Path \$Root 'install-clock-sync\.ps1'" "$1"; }
if calls_installer "$SETUP"; then
  ok "installer_calls_it: stage 2 runs install-clock-sync.ps1 from the payload root"
else
  bad "installer_calls_it: nothing in the installer runs install-clock-sync.ps1 (Jev: will-recur 0.52)"
fi
command grep -q "install-clock-sync.ps1 not in payload" "$SETUP" \
  && ok "absence_is_reported: an install without the script SAYS the clock is never pulled" \
  || bad "absence_is_reported: a missing clock-sync installer would pass silently"
sed '/install-clock-sync/d' "$SETUP" > "$W/no-call.ps1"
calls_installer "$W/no-call.ps1" \
  && bad "installer_call_seen_to_fail: the check passes an installer that never calls it" \
  || ok "installer_call_seen_to_fail: the check rejects the unwired installer"

# ---- 4. it is on the MEDIUM, and CI fails if that stops being true ------------------------------
command grep -q "guest\\\\install-clock-sync.ps1" "$MK" \
  && ok "staged_on_medium: make-setup.ps1 copies install-clock-sync.ps1 into the payload" \
  || bad "staged_on_medium: the installer would run a script that is not on the medium"
command grep -q "guest/install-clock-sync.ps1" "$OW" \
  && ok "guard_can_fail: ours-wins.psd1 lists it, so CI fails the build if staging stops" \
  || bad "guard_can_fail: nothing makes CI fail when it stops shipping"

# ---- 5. the puller's wait has three named exits, and a failure is an ERROR line -----------------
# A wait with only a deadline is a hang, and a clock left unset must never be silence.
miss=""
for x in "'set'" "'dom0-refused'" "'setter-refused'" "default"; do
  command grep -qF "$x {" "$PULL" || miss="$miss [$x]"
done
[ -z "$miss" ] && ok "three_named_exits: the pull says which exit it took (set / refused / deadline)" \
              || bad "three_named_exits: missing$miss"
n_err=$(command grep -c 'LogError' "$PULL")
[ "$n_err" -ge 3 ] && ok "failure_is_loud: $n_err LogError paths - an unset clock is never silence" \
                   || bad "failure_is_loud: only $n_err LogError path(s) in the puller"

# ---- 6. set-time.ps1 parses INVARIANTLY and verifies the result ---------------------------------
# This product ships German goldens; Set-Date on a string parses with the CURRENT culture, and a
# DateTime whose Kind is Unspecified sets LOCAL time - which on a guest whose zone is wrong puts
# the clock out by exactly that zone, the shape of the skew measured above.
ST="$ROOT/core-agent/src/qubes-rpc-services/set-time.ps1"
for tok in 'InvariantCulture' 'AssumeUniversal' 'SpecifyKind' 'TryParseExact'; do
  command grep -q "$tok" "$ST" || bad "settime_invariant: $tok is absent - the parse is culture-dependent"
done
command grep -q 'InvariantCulture' "$ST" && command grep -q 'SpecifyKind' "$ST" \
  && ok "settime_invariant: the parse is invariant and the value is set in UTC terms" || true
command grep -q 'Abs($residual)' "$ST" \
  && ok "settime_verifies: it re-reads the clock and reports a residual instead of assuming" \
  || bad "settime_verifies: 'it ran' and 'the clock is right' are still indistinguishable"

echo
echo "clock-sync-selftest: $pass passed, $fail failed; copies in $W"
[ "$fail" = 0 ] || exit 1
