#!/bin/bash
# notify-errors: first guest run. QUICK-UPGRADE cycle (.claude/skills/rig-cycle) - this is a feature
# test, not a clean-install test.
#
# WHAT IS ACTUALLY BEING ASSERTED. Send-QwtError returns a contract string, so every check compares
# against a documented value rather than "did something happen":
#     send | gated | rejected:severity | rejected:name | rejected:redact | suppressed:duplicate
#       | suppressed:cap | failed:transport
# NOTE the success value is 'send', not 'sent' - guest/qwt-notify-error.ps1 header and the C side's
# QERR_SEND agree. I expected 'sent' on the first run because I took it from a summary instead of
# the source, and would have reported a working feature as broken.
#
# THE ORDER IS DELIBERATE. The NEGATIVE CONTROL runs first: gate ON, healthy guest, nobody calling -
# ZERO notifications. A route that notifies dom0 when nothing is wrong is worse than no route, and
# that is the one property no offline test can establish.
#
# WHAT 'send' MEANS, corrected 2026-09-10. It means notifhost.exe was LAUNCHED - nothing more.
# Send-QwtError deliberately does not wait, so at that point nothing has heard from dom0. This header
# used to claim "a 'sent' means accepted-by-dom0", and that claim is exactly why a route which never
# delivered a single notification reported 10/10 for two consecutive releases: notifhost was failing
# with "relay never connected" and every check here was blind to it.
# The run therefore ENDS ON PIXELS - a dom0 render witness that photographs the desktop and requires
# a bubble-shaped block where the desktop is ambiently quiet. That is the only check in this file
# that speaks for dom0.
# Also untested here: the C call sites in gui-agent (they need a real agent fault to fire); this
# exercises the PowerShell twin, which is the half the .ps1 call sites use.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2

# Parameterised so a campaign can point it at its own subject and package. Defaults are the
# throwaway subject this test was written against.
VM="${VM:-win11-ne}"
PKG="${PKG:?set PKG to the release setup tree under test}"
LOG="${LOG:-/home/user/rel/notify-errors-guest-test-$VM.log}"
OS_FAMILY="${OS_FAMILY:-win11}"   # which golden quick-upgrade.sh upgrades over
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
pass=0; fail=0
ok(){ say "PASS  $*"; pass=$((pass+1)); }
no(){ say "FAIL  $*"; fail=$((fail+1)); }

gq(){ QTEST_VM=$VM timeout -k 5 "${2:-90}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
# -ExecutionPolicy Bypass, because these probes DOT-SOURCE a shipped .ps1 and the default policy
# blocks that ("running scripts is disabled"), returning nothing at all. Production runs every guest
# script as -NoProfile -ExecutionPolicy Bypass -File, so this matches it.
ps_probe(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-120}" \
            | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }
state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
boot_id(){ ps_probe BOOT 'Write-Host ("BOOT=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"))'; }

# send KEY COMPONENT ID SEVERITY SUMMARY -> the contract string
send(){
  local k="$1" comp="$2" id="$3" sev="$4" sum="$5"
  ps_probe "$k" ". '$HELPER'; Write-Host (\"$k=\" + (Send-QwtError -Component '$comp' -Id '$id' -Severity '$sev' -Summary '$sum'))"
}
# MARKERS FROM *THIS* BOOT ONLY, and only real ones. Counting every file in the state directory
# reported "3 marker(s) on an idle healthy guest" on 2026-09-13 when the truth was ONE: the other
# two were `.count` (the per-boot counter) and `out-gui-agent-1.txt` (captured helper output), and
# the one real marker it did find - gui-agent.broker-missing - carried a DIFFERENT boot id, i.e. it
# was left over from an earlier boot. A negative control that counts bookkeeping files and history
# cannot distinguish "the route fired" from "the directory is not empty".
# `.count` names the current boot (`boot=<id> count=<n>`), so it is the reference.
markers(){ ps_probe MK '$d="$env:ProgramData\Qubes\notify-errors"
if (-not (Test-Path $d)) { Write-Host "MK=0"; exit }
$c = Join-Path $d ".count"
if (-not (Test-Path $c)) { Write-Host "MK=0"; exit }
$b = ((Get-Content $c -Raw) -split "\s+" | Where-Object { $_ -like "boot=*" } | Select-Object -First 1)
if (-not $b) { Write-Host "MK=0"; exit }
$n = 0
foreach ($f in Get-ChildItem $d -File -EA SilentlyContinue) {
  if ($f.Name -eq ".count" -or $f.Name -like "out-*") { continue }
  $t = (Get-Content $f.FullName -Raw -EA SilentlyContinue)
  if ($t -and ($t -split "\s+") -contains $b) { $n++ }
}
Write-Host ("MK=" + $n)'; }

reboot_proven(){
    local label="$1" before after i
    before=$(boot_id); [ -n "$before" ] || { no "$label: no LastBootUpTime BEFORE"; return 1; }
    QTEST_VM=$VM timeout -k 5 90 ./tools/qtest shutdown >/dev/null 2>&1
    for i in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 10; done
    [ "$(state)" = Halted ] || { no "$label: never Halted (state=$(state))"; return 1; }
    qvm-start "$VM" >/dev/null 2>&1
    for i in $(seq 1 60); do gq 'cmd /c echo PING=UP' 30 | grep -q 'PING=UP' && break; sleep 10; done
    gq 'cmd /c echo PING=UP' 30 | grep -q 'PING=UP' || { no "$label: no qrexec within 10 min"; return 1; }
    after=$(boot_id); [ -n "$after" ] || { no "$label: no LastBootUpTime AFTER"; return 1; }
    [ "$after" != "$before" ] || { no "$label: boot UNCHANGED ($after)"; return 1; }
    ok "$label: reboot PROVEN ($before -> $after)"; return 0
}

for i in $(seq 1 90); do
  pgrep -f "[a]cceptance-races|[m]gmt/harness/matrix.sh|[p]rime-run.sh|[q]uick-upgrade.sh" >/dev/null 2>&1 || break
  [ "$i" = 1 ] && say "waiting for the rig"; sleep 30
done
say "rig free"
source mgmt/harness/vmlock.sh
vm_lock "$VM"
qvm-kill "$VM" >/dev/null 2>&1; sleep 3; qvm-remove -f "$VM" >/dev/null 2>&1

# UNSET BEFORE THE GUEST BOOTS. qubesdb is populated from the features AT VM START and the helper
# lets qubesdb WIN over the registry, so a leftover service.notify-errors=1 from an earlier run is
# still in this boot's qubesdb no matter what we unset afterwards - which is why the registry-based
# explicit-off leg below reported "explicit off did NOT gate (got: send)" on 2026-09-14. Clearing it
# here, before quick-upgrade's boots, is what makes the registry the deciding source in this run.
qvm-features --unset "$VM" service.notify-errors >/dev/null 2>&1
say "quick-upgrade over win11-qwt with $(python3 -c "import json;m=json.load(open('$PKG/MANIFEST.json'));print(m['package_version'],'rev',m['build_rev'])")"
./mgmt/harness/quick-upgrade.sh "$PKG" "$VM" "$OS_FAMILY" >>"$LOG" 2>&1
prc=$?; say "quick-upgrade rc=$prc"
[ "$prc" -eq 0 ] || { say "FATAL: upgrade did not complete"; vm_unlock "$VM"; exit 1; }

# The helper lives in the PAYLOAD dir beside activate-idd.ps1 (make-setup.ps1:330 - "dot-sourced by
# activate-idd.ps1 / deactivate-idd.ps1 from $PSScriptRoot"), which the installer stages to
# C:\qwt-improved-setup. Probing bin\ called a correctly shipped helper "absent" on the first run.
HELPER='C:\qwt-improved-setup\qwt-notify-error.ps1'
v=$(ps_probe H "if (Test-Path '$HELPER') { Write-Host 'H=present' } else { Write-Host 'H=absent' }")
if [ "$v" = present ]; then ok "qwt-notify-error.ps1 shipped to the guest"; else no "helper not installed (got: ${v:-<none>}) - every PS call site is an inert no-op"; vm_unlock "$VM"; exit 1; fi

# The gate is per-qube state that OUTLIVES a run: an aborted earlier attempt left
# service.notify-errors set, so "default OFF" would have been tested against a gate someone else
# turned on. Set the precondition, never inherit it.
qvm-features --unset "$VM" service.notify-errors >/dev/null 2>&1

# --- 1. GATE DEFAULT OFF -----------------------------------------------------------------------
# DEFAULT IS **ON** since 2026-09-13 (agent 2862c13 + guest/qwt-notify-error.ps1): an ACTION fault
# that needs a human is worth telling dom0 about, and service.notify-errors=0 turns it off. This
# check used to assert `gated`, i.e. the OLD default - so when the default flipped it PASSED while
# the C agent and the PowerShell helper had silently DISAGREED with each other, which is the very
# thing it is here to catch. It now asserts the shipped default, and the explicit-off case below
# covers the gate actually gating.
v=$(send G1 acceptance gate-default ACTION 'gate default check')
if [ "$v" = send ]; then ok "gate is ON by default: $v"; else no "gate not ON by default (got: ${v:-<none>}) - the C agent and the PS helper must agree, see QVM-FEATURES.md"; fi
# EXPLICIT OFF, VIA THE GUEST-LOCAL REGISTRY - not qvm-features. `qvm-features` writes
# /qubes-service/<name> into qubesdb AT VM START, so setting it on a RUNNING guest changes
# nothing until the next boot: the first version of this leg set the feature and sent
# immediately, saw the (correct) default `send`, and reported "explicit off did NOT gate". It
# also WROTE A REAL MARKER that the negative control below then counted. The registry DWORD is
# read on every call, so this proves the gate gates without a third reboot and without leaving
# a marker behind.
ps_probe RO 'New-ItemProperty -Path "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent" -Name NotifyErrors -PropertyType DWord -Value 0 -Force | Out-Null; Write-Host "RO=set"' >/dev/null
v=$(send G2 acceptance gate-off ACTION 'explicit off must gate')
if [ "$v" = gated ]; then ok "explicit NotifyErrors=0 gates: $v"; else no "explicit off did NOT gate (got: ${v:-<none>})"; fi
ps_probe RC 'Remove-ItemProperty -Path "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent" -Name NotifyErrors -EA SilentlyContinue; Write-Host "RC=cleared"' >/dev/null

# --- 2. NEGATIVE CONTROL: gate ON, healthy guest, nobody calling -> ZERO ------------------------
# CLEAR THE STATE DIRECTORY FIRST. The checks ABOVE deliberately send, and with the default now ON
# they return `send` and WRITE MARKERS - which this control then counted as faults on an "idle
# healthy guest" (2 of them on 2026-09-14, exactly the two sends above; 1 on the run before). A
# control that counts the test's own earlier traffic is not a control. Nothing has called the route
# since the reboot below, so an empty directory here is the correct starting state.
ps_probe CL '$d="$env:ProgramData\Qubes\notify-errors"; if (Test-Path $d) { Remove-Item "$d\*" -Force -Recurse -EA SilentlyContinue }; Write-Host "CL=cleared"' >/dev/null
qvm-features "$VM" service.notify-errors 1 >/dev/null 2>&1
say "gate enabled via qvm-features service.notify-errors 1 (dom0 wins over the registry)"
reboot_proven "reboot 1 (pick up the gate)" || { say "=== notify-errors: $pass passed, $fail failed ==="; vm_unlock "$VM"; exit 1; }
m=$(markers)
if [ "${m:-x}" = 0 ]; then ok "NEGATIVE CONTROL: gate ON, healthy guest, 0 notifications sent"; else no "NEGATIVE CONTROL FAILED: $m marker(s) on an idle healthy guest"; fi

# --- 3. an ACTION error is sent, exactly once --------------------------------------------------
v=$(send S1 acceptance probe-one ACTION 'acceptance probe: a human should act')
# NOT "accepted by dom0" - that wording was wrong and is exactly the over-claim that let a route
# which never delivered anything report 10/10 for two releases. Send-QwtError returns 'send' as soon
# as notifhost is LAUNCHED; it deliberately does not wait, and nothing here has heard from dom0. The
# only check in this file that speaks for dom0 is the render witness at the end.
if [ "$v" = send ]; then ok "ACTION error handed to notifhost (launched, NOT yet delivered): $v"; else no "ACTION error not sent (got: ${v:-<none>})"; fi
v=$(send S2 acceptance probe-one ACTION 'acceptance probe: a human should act')
if [ "$v" = 'suppressed:duplicate' ]; then ok "same (component,id) again this boot: $v"; else no "dedupe failed (got: ${v:-<none>})"; fi

# --- 4. below-threshold severity is refused ----------------------------------------------------
v=$(send D1 acceptance degraded-probe DEGRADED 'degraded, should not notify')
if [ "$v" = 'rejected:severity' ]; then ok "DEGRADED refused: $v"; else no "severity threshold failed (got: ${v:-<none>})"; fi

# --- 5. redaction refuses a secret-shaped summary ----------------------------------------------
v=$(send R1 acceptance redact-probe ACTION 'failed with password hunter2 in the message')
if [ "$v" = 'rejected:redact' ]; then ok "credential-shaped summary refused: $v"; else no "redaction failed (got: ${v:-<none>})"; fi

# --- 6. once-per-boot: the marker must NOT survive a reboot ------------------------------------
reboot_proven "reboot 2 (once-per-boot)" || { say "=== notify-errors: $pass passed, $fail failed ==="; vm_unlock "$VM"; exit 1; }
v=$(send S3 acceptance probe-one ACTION 'acceptance probe: a human should act')
if [ "$v" = send ]; then ok "ONCE PER BOOT: the same error sends again after a proven reboot: $v"; else no "once-per-boot failed (got: ${v:-<none>})"; fi

# --- 7. THE ONLY CHECK THAT MATTERS: DID A HUMAN SEE IT? ---------------------------------------
# Every check above is an ACK. Send-QwtError returns 'send' the moment notifhost is LAUNCHED - it
# deliberately does not wait - so 'send' means "a process started", not "dom0 drew anything". This
# suite was fully green for a route that had NEVER delivered a single notification: notifhost's
# relay needs the interactive session and every caller is SYSTEM in session 0, so it failed with
# "relay never connected" every time and no check here could see it.
#
# So the run now ends on PIXELS. The witness photographs the dom0 desktop around a real send and
# requires a bubble-shaped block that the same desktop does not produce with no trigger at all.
# THE SEND MUST *BE* THE WITNESS'S TRIGGER. Sending first and witnessing afterwards would put the
# bubble on screen before the 'pre' capture, so the delta would be empty and a WORKING route would
# read as a failure. The trigger takes its parameters from the environment - interpolating them into
# a heredoc is how this got miswritten the first time.
TRIG="${TMPDIR:-/tmp}/notify-render-trigger-$$.sh"
cat >"$TRIG" <<'TRIGEOF'
#!/bin/bash
# Fires ONE ACTION error through the shipped helper. NV_ID is unique per run because the route
# deliberately sends a given (component,id) only once per boot.
cd "$NV_ROOT" || exit 2
b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
PS=". '$NV_HELPER'; Write-Host ('W=' + (Send-QwtError -Component 'acceptance' -Id '$NV_ID' -Severity ACTION -Summary 'render witness: a human should see this'))"
QTEST_VM="$NV_VM" timeout -k 5 120 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$PS")" 2>/dev/null \
  | tr -d '\r' | grep -aoE '^W=.*'
TRIGEOF
chmod +x "$TRIG"
# THE WITNESS HAS THREE VERDICTS, AND THEY ARE NOT ALL "the product failed".
# It emits WITNESS=RENDERED, WITNESS=capture-failed(...) or WITNESS=undecidable(...). This used to
# grep for RENDERED and report EVERYTHING ELSE as "NOT RENDERED: nothing visible appeared", with a
# hint pointing at the session-0 relay defect. On 2026-09-13 the witness said:
#   WITNESS=undecidable(no quiet baseline after 10 attempts - grading against a contaminated
#   control would be worse than no verdict)
# i.e. it never fired the trigger, because the dom0 desktop would not go quiet (the owner was
# using it). That was recorded as a product FAIL, and the hint sent me to read bridge.log for a
# defect that had nothing to do with it. An instrument saying "I cannot tell" must never be
# graded as "the product is broken" - the same mistake prime-run's settle block produced earlier
# the same day.
NV_OUT="$(NV_ROOT="$(pwd)" NV_VM="$VM" NV_HELPER="$HELPER" NV_ID="render$(date -u +%H%M%S)" \
   ./mgmt/harness/dom0-notify-witness.sh "$VM" notifyerr-acceptance "$TRIG" 2>&1 | tee -a "$LOG")"
NV_VERDICT="$(printf '%s' "$NV_OUT" | grep -aoE 'WITNESS=[a-z-]+' | tail -1)"
case "$NV_VERDICT" in
  WITNESS=undecidable|WITNESS=capture-failed)
    say "INVALID-INSTRUMENT  render witness could not decide: $(printf '%s' "$NV_OUT" | grep -aoE 'WITNESS=.*' | tail -1)"
    say "                    This is NOT a product result. The dom0 desktop must be quiet for the"
    say "                    ambient control; re-run when it is. The route's own legs above still stand."
    ;;
esac
if printf '%s' "$NV_OUT" | grep -q 'WITNESS=RENDERED'; then
  ok "RENDERED: the notification was PHOTOGRAPHED on the dom0 desktop"
else
  case "$NV_VERDICT" in
    WITNESS=undecidable|WITNESS=capture-failed)
      : ;;   # already reported as INVALID-INSTRUMENT above; not counted as a product failure
    *)
      no "NOT RENDERED: the witness fired the trigger and NOTHING visible appeared ($NV_VERDICT). Check C:\ProgramData\qubes-toast-bridge\bridge.log on the guest for 'relay never connected' - that is the session-0 defect" ;;
  esac
fi
rm -f "$TRIG"

say "=== notify-errors guest test: $pass passed, $fail failed ==="
qvm-features --unset "$VM" service.notify-errors >/dev/null 2>&1
vm_unlock "$VM"
[ "$fail" -eq 0 ] || exit 1
