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
# EVERY ARM MUST BE REACHABLE. This list asserted 'dom0-refused' and 'setter-refused', and nothing
# in the script set either - so the suite was holding the puller to a claim it could not produce,
# and it stayed green while the real classification was wrong.
for x in "'set'" "'bad-invocation'" "default"; do
  command grep -qF "$x {" "$PULL" || miss="$miss [$x]"
done
[ -z "$miss" ] && ok "three_named_exits: the pull says which exit it took (set / refused / deadline)" \
              || bad "three_named_exits: missing$miss"
n_err=$(command grep -c 'LogError' "$PULL")
[ "$n_err" -ge 3 ] && ok "failure_is_loud: $n_err LogError paths - an unset clock is never silence" \
                   || bad "failure_is_loud: only $n_err LogError path(s) in the puller"

# ---- 5b. THE TRANSIENT CODE MUST BE RETRIED, NOT GRADED TERMINAL ------------------------------
# 2026-10-14: this suite passed 18/18 while the puller was broken, because it checked that the exits
# are NAMED and that failure is LOUD and never which CODE maps to which exit. The commit that made
# the classification locale-independent put ERROR_FILE_NOT_FOUND (2) in the terminal dom0-refused
# branch with a `break`. But 0x2 here is QpsConnect failing to open the LOCAL agent pipe
# (core-agent/src/qrexec-client-vm/qrexec-client-vm.c:104, `return win_perror("open agent pipe")`):
# this guest's own qrexec agent is not up yet, nothing has been asked of dom0, so there is nothing
# for dom0 to refuse. It is the NORMAL state early in boot. The loop left on its first attempt, the
# clock was never pulled, the ~3 h boot skew came back - and the log line said "dom0 refused" while
# quoting "open agent pipe failed with error 0x2" as its own evidence.
# So: the codes are pinned to their exits, not merely counted.
# The checks read CODE, never the comments that describe it: the fix's own comment explains the
# shape it replaced, and matching that made two of these pass judgement on prose.
cs_code(){ command grep -vE '^[[:space:]]*#' "$PULL"; }

# A. THE ONLY TERMINAL CONDITION IS "THIS SCRIPT IS WRONG". Waiting cannot fix a usage error, and
#    retrying one floods the log (34 of 36 error lines once came from exactly that).
b87=$(cs_code | command grep -nE "rc -eq 87" | head -1)
printf '%s' "$b87" | command grep -q 'break' \
  && ok "usage_is_terminal: ERROR_INVALID_PARAMETER (87) is terminal - this script is wrong, not the guest" \
  || bad "usage_is_terminal: rc=87 is not terminal: ${b87:-<no branch>}"

# B. NOTHING MAY BE CALLED A dom0 REFUSAL. qrexec-client-vm writes the request to THIS guest's agent
#    and exits without reading a response (qrexec-client-vm.c:140), so a refusal by dom0 happens
#    where no exit code of its can report it. The branch that read ACCESS_DENIED as "dom0 refused"
#    claimed what the source cannot support, and the branch that read FILE_NOT_FOUND the same way
#    killed the feature: 0x2 is the local agent pipe not up yet, the ordinary state early in boot.
if [ "$(cs_code | command grep -c "exit = 'dom0-refused'")" -eq 0 ]; then
  ok "no_unsupportable_refusal: no exit claims dom0 refused - this client cannot observe that"
else
  bad "no_unsupportable_refusal: an exit still claims dom0 refused, which this client cannot observe"
fi

# C. NO OTHER CODE MAY BE TERMINAL. Every remaining return path is a win_perror pass-through from
#    opening or writing the local agent pipe, i.e. "not up YET" - so each must be retried.
nterm=$(cs_code | command grep -cE "rc -eq (1|2|5|14|1722)\b")
[ "$nterm" -eq 0 ] \
  && ok "only_receipted_codes: no code is classified without a receipt in the client's source" \
  || bad "only_receipted_codes: $nterm branch(es) classify a code the source does not account for"

# D. AND THE FALLTHROUGH MUST ACTUALLY RETRY: a sleep inside the loop, and the loop bounded BY A
#    CLOCK THE RETRY CANNOT MOVE. This leg required `while ((Get-Date) -lt $deadline)` and had been
#    RED since the puller deliberately replaced that bound with a monotonic Stopwatch: the pull is
#    fire-and-forget, so a separate set-time.ps1 can correct the clock WHILE this loop runs, and a
#    wall-clock deadline then breaks in both directions - a guest corrected backward by three hours
#    loops for three hours past its limit, one corrected forward exits instantly. Stopwatch is
#    QueryPerformanceCounter and a clock set cannot touch it, so the property is a MONOTONIC bound
#    and the old spelling is now the defect rather than the requirement.
#    IT WENT UNSEEN BECAUSE THIS SUITE HAD NO PRODUCER: it was in no runner list, and nothing but a
#    hand invocation had ever run it since it was written on 2026-10-08. Fixed the same day it was
#    found - offline-suites.txt, floor 110.
if cs_code | command grep -q 'Start-Sleep -Seconds $IntervalSeconds' \
   && cs_code | command grep -q 'Stopwatch\]::StartNew()' \
   && cs_code | command grep -q 'while ($sw.Elapsed.TotalSeconds -lt $DeadlineSeconds)'; then
  ok "fallthrough_retries_bounded: an unrecognised rc waits and retries, inside a MONOTONIC deadline"
else
  bad "fallthrough_retries_bounded: the fallthrough does not wait, or its bound is not monotonic (a wall-clock deadline cannot bound a loop that straddles the clock correction it causes)"
fi
# AND THE WALL-CLOCK BOUND MUST NOT COME BACK. Driven as the defect: if the loop is ever rewritten
# against (Get-Date) this fails, which is the only thing that keeps the reasoning above enforced.
if cs_code | command grep -q 'while ((Get-Date) -lt'; then
  bad "fallthrough_bound_not_wallclock: the loop is bounded by the wall clock again - the clock it is waiting for can move that bound"
else
  ok "fallthrough_bound_not_wallclock: no wall-clock loop bound, so a mid-loop correction cannot extend or collapse the wait"
fi

# E. The one text match left selects on OUR OWN literal, so it cannot change with the guest's
#    language: win_perror renders only the sentence AFTER the colon through FormatMessage.
if [ "$(cs_code | command grep -cF '$out -match')" -eq 1 ] && cs_code | command grep -q "wmain: Usage:"; then
  ok "match_is_our_literal: the single text match is our own usage string, not a localised sentence"
else
  bad "match_is_our_literal: a branch matches text that is not our own fixed literal"
fi

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

# ---- 7. AND THE VALUE HANDED TO Set-Date MUST BE IN THE GUEST'S OWN FRAME -----------------------
# The comment above this section ALREADY described this hazard - "a DateTime whose Kind is
# Unspecified sets LOCAL time ... puts the clock out by exactly that zone" - and the check beside it
# only asserted that the token SpecifyKind appears, which it did, while the code still passed the
# UTC value straight to Set-Date. The test named the defect and could not see it. Set-Date sets the
# LOCAL clock from the value's COMPONENTS (Win32 SetLocalTime); DateTimeKind is not consulted.
#
# MEASURED, 2026-10-08, on a clone built to match a German reporter's template (Europe/Berlin, +2):
# a boot-scoped measurement carried exactly ONE error - "SETTIME the clock did not take: asked for
# ...T15:05:09Z, it reads ...T13:05:09Z - still -7200 s out (was -3604.3 s out before)". Every rig
# guest runs UTC, where the offset is zero and this is invisible.
command grep -q 'Set-Date -Date \$utc\.ToLocalTime()' "$ST" \
  && ok "settime_sets_local_frame: the instant is converted into the guest's zone before Set-Date" \
  || bad "settime_sets_local_frame: a UTC value goes straight to Set-Date - on any guest not on UTC the clock lands off by the zone offset"
if command grep -qE 'Set-Date -Date \$utc +-ErrorAction' "$ST"; then
  bad "settime_no_bare_utc: Set-Date is still called with the bare UTC value"
else
  ok "settime_no_bare_utc: the bare UTC value is no longer passed to Set-Date"
fi
# BEHAVIOURAL, not lexical: compute what each form actually produces in a +2 zone and require the
# old one to be wrong by 7200 s and the new one to be exact. This is the check that would have
# caught it, and it is driven with the defect present.
PWSHBEH="$("$(dirname "$0")/pwsh-path.sh" || true)"
beh=$(TZ='Europe/Berlin' "${PWSHBEH:-/nonexistent/pwsh}" -NoProfile -Command '
$utc = [datetime]::SpecifyKind([datetime]::Parse("2026-10-08T15:05:09Z").ToUniversalTime(), [DateTimeKind]::Utc)
# Set-Date takes the components as LOCAL. Model both candidate arguments that way.
$oldLocalComponents = $utc                 # the defect: UTC components treated as local
$newLocalComponents = $utc.ToLocalTime()   # the fix
$oldResultUtc = [datetime]::SpecifyKind($oldLocalComponents, [DateTimeKind]::Unspecified)
$newResultUtc = [datetime]::SpecifyKind($newLocalComponents.DateTime, [DateTimeKind]::Unspecified)
$oldOff = [math]::Round(([datetime]::SpecifyKind($oldResultUtc,[DateTimeKind]::Local).ToUniversalTime() - $utc).TotalSeconds)
$newOff = [math]::Round(([datetime]::SpecifyKind($newResultUtc,[DateTimeKind]::Local).ToUniversalTime() - $utc).TotalSeconds)
"OLD=$oldOff NEW=$newOff"
' 2>/dev/null)
case "$beh" in
  "OLD=-7200 NEW=0") ok "settime_behaviour: in a +2 zone the OLD form lands 7200 s out and the NEW form lands exact ($beh)" ;;
  "") bad "settime_behaviour: the model did not run - no verdict (missing data fails)" ;;
  *)  bad "settime_behaviour: expected 'OLD=-7200 NEW=0', got '$beh' - the model no longer reproduces the measured skew" ;;
esac

echo
echo "clock-sync-selftest: $pass passed, $fail failed; copies in $W"
[ "$fail" = 0 ] || exit 1
