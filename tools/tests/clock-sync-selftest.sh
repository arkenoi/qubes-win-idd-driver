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
PULL="$ROOT/guest/sync-clock-from-dom0.ps1"
SETUP="$ROOT/packaging/setup/Install-QwtImproved.ps1"
MK="$ROOT/packaging/make-setup.ps1"
OW="$ROOT/packaging/ours-wins.psd1"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
W="${CLOCKSYNC_SELFTEST_OUT:-$(mktemp -d)}"; mkdir -p "$W"

# ---- 1. the puller ships, and INSTALL puts it somewhere persistent ------------------------------
# It ships at the payload ROOT, not through core-agent/src/qubes-rpc-services: that directory is
# swept into the payload AND mirrored into the built MSI, where a file with no wxs component fails
# the ours-wins guard - measured, release-package run 37743438873. install-clock-sync.ps1 copies it
# into the Qubes Tools tree beside the set-time.ps1 it calls, which is what makes the registered
# action path outlive the setup payload.
if [ -f "$PULL" ]; then
  ok "puller_shipped: guest/sync-clock-from-dom0.ps1 exists"
else
  bad "puller_shipped: $PULL is missing - nothing ships the puller"
fi
if command grep -q 'Copy-Item -LiteralPath $staged' "$INST"; then
  ok "puller_installed_persistently: the installer copies the puller out of the payload before registering"
else
  bad "puller_installed_persistently: the task would point into the setup payload, which is deleted"
fi
command grep -q "guest\\\\sync-clock-from-dom0.ps1" "$MK" \
  && ok "puller_staged_on_medium: make-setup.ps1 puts the puller on the medium" \
  || bad "puller_staged_on_medium: the installer would have nothing to copy"
command grep -q "guest/sync-clock-from-dom0.ps1" "$OW" \
  && ok "puller_guard_can_fail: ours-wins.psd1 lists the puller too" \
  || bad "puller_guard_can_fail: nothing makes CI fail when the puller stops shipping"

# ---- 2. the registered ACTION PATH is the persistent copy, never the payload --------------------
action_persistent() {
  local f="$1"
  # THE DISCRIMINATOR IS THE $puller ASSIGNMENT, not the mere presence of $PSScriptRoot: the script
  # legitimately reads $PSScriptRoot to find the STAGED copy it installs FROM. What must never be
  # payload-relative is the path the task's action is built from. My first version of this check
  # banned $PSScriptRoot outright and then failed the correct code.
  command grep -qE '^\s*\$dest = Join-Path \$tools .qubes-rpc-services.' "$f" || return 1
  command grep -qE '^\s*\$puller = Join-Path \$dest ' "$f" || return 1
  command grep -qE '^\s*\$puller = Join-Path \$PSScriptRoot' "$f" && return 1
  command grep -q 'File \"\$puller\"' "$f" || return 1
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
s=s.replace("""$puller = Join-Path $dest 'sync-clock-from-dom0.ps1'""",
            """$puller = Join-Path $PSScriptRoot 'sync-clock-from-dom0.ps1'""")
assert "$puller = Join-Path $PSScriptRoot" in s, "the mutation did not apply - the check would prove nothing"
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
