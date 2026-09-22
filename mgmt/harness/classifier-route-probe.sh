#!/bin/bash
# classifier-route-probe.sh - does the classifier's verdict actually decide the route, on a guest?
#
# The change under test (60009f4/929cc81) lets a per-toast verdict route a toast from an app
# NOBODY allowlisted. Until then such a toast was skipped outright. Two cases decide it:
#
#   informational (no buttons) from a NON-allowlisted AUMID -> routed to the BRIDGE by verdict
#   realchoice    (buttons)    from a NON-allowlisted AUMID -> stays on the guest-window path
#
# and a third guards the machinery: no toast may be deferred past its pass cap.
#
# DONE = PIXELS, NOT ACKS: a bridge.log "route ... bridge" line proves the DECISION, not the
# delivery. dom0 rendering is mgmt/harness/dom0-notify-witness.sh's job.
#
#   VM=<guest> mgmt/harness/classifier-route-probe.sh
#
# Read-only against the product: it fires toasts and reads logs. It does not touch the
# allowlist - the whole point is an app that is NOT on it, which is asserted before firing.
#
# INSTRUMENT HISTORY (2026-09-23, both found by running it):
#  * the bridge-liveness gate asked `Get-Process notifhost` and aborted the probe as TERMINAL
#    on a guest where the bridge was perfectly alive: the launcher starts it from the 8.3 SHORT
#    path, so the image name is NOTIFH~1.EXE. The role lives in the command line - ask for that.
#  * toasts were fired with `qtest run`, i.e. as SYSTEM in session 0, where the user's
#    notification platform never sees them: the bridge logged nothing and the probe called it
#    "missing data". Toasts MUST be fired in the interactive user session (run-as-user), with
#    the FIRED confirmation checked - which is exactly what a0-lib.sh's fire_* already do.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${VM:?set VM to the guest carrying the build under test}"
export QTEST_VM="$VM"
. mgmt/harness/vmlock.sh
vm_lock "$VM"
. .claude/skills/win-guest-e2e/e2e-lib.sh

OUT="scratchpad/classroute-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
R="$OUT/probe.log"
log(){ echo "$(date -u +%H:%M:%SZ) classroute: $*" | tee -a "$R"; }
. mgmt/harness/a0-lib.sh
pass=0; fail=0
ok(){ log "PASS  $*"; pass=$((pass+1)); }
no(){ log "FAIL  $*"; fail=$((fail+1)); }

gq(){ QTEST_VM=$VM timeout -k 5 "${2:-90}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
# PowerShell goes over the wire BASE64-ENCODED, never as -Command with escaped quotes: each
# hop (qrexec -> cmd -> powershell) re-splits and strips them, and the failure is SILENT - the
# command runs with mangled arguments and prints nothing, which reads exactly like "the guest
# says no". Cost this project two debugging sessions; tools/lint-harness.py rule L3 now refuses
# the -Command form outright.
gqps(){ # $1=PowerShell source, $2=timeout
  local b64; b64=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  gq "powershell -NoProfile -EncodedCommand $b64" "${2:-90}"
}

log "subject $VM"

# 1. The bridge must be up, or every verdict below is vacuous.
if ! gqps '(Get-CimInstance Win32_Process -Filter "Name LIKE '"'"'%otifh%'"'"'" -EA SilentlyContinue | Where-Object { $_.CommandLine -match "--bridge" } | Measure-Object).Count' 60 | grep -qE '^[1-9]'; then
  log "TERMINAL: no notifhost --bridge process on $VM - nothing to probe"; exit 2
fi

# 2. The two AUMIDs this probe fires from must NOT be allowlisted, or "the verdict routed it"
# is indistinguishable from "the allowlist routed it" - the failure this probe exists to catch.
ALLOW=$(gqps '$k = "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent"
$v = (Get-ItemProperty -LiteralPath $k -Name NotifyBridgeAllow -EA SilentlyContinue).NotifyBridgeAllow
if ($v) { "ALLOW=" + ($v -join "|") } else { "ALLOW=<unset:defaults>" }' 60 | grep -ao 'ALLOW=.*' | tail -1)
log "${ALLOW:-ALLOW=<unreadable>}"
case "${ALLOW:-}" in
  ALLOW=) log "TERMINAL: could not read NotifyBridgeAllow - refusing to grade a vacuous probe"; exit 2 ;;
esac
if printf '%s' "$ALLOW" | grep -qiE 'powershell|Windows\.Explorer'; then
  log "TERMINAL: a probe AUMID is ON the allowlist ($ALLOW) - the route would prove nothing"; exit 2
fi

# 3. Offset FIRST: only lines written after this point are this probe's evidence.
OFF=$(gq "cmd /c for %I in ($BLOG) do @echo %~zI" 60 | grep -aoE '^[0-9]+$' | tail -1)
log "bridge.log offset before firing: ${OFF:-0} bytes"
tail_new(){ gqps "\$f = '$BLOG'
if (Test-Path \$f) { \$s = New-Object IO.FileStream(\$f,'Open','Read','ReadWrite'); \$s.Seek(${OFF:-0},'Begin') | Out-Null; (New-Object IO.StreamReader(\$s)).ReadToEnd() }" 120; }

# fire_info / fire_ctl fire IN THE USER SESSION and return non-zero unless the guest confirmed
# FIRED. A fire that did not happen is an INSTRUMENT MISS, never a product verdict.
log "case 1: informational (no buttons), AUMID $PSAUMID - not allowlisted"
if ! fire_info "classroute-info-$RANDOM" >/dev/null; then
  log "INSTRUMENT: the informational toast never confirmed FIRED - case 1 not graded"
else
  sleep 14   # >= 3 poll passes at the 2 s cadence, plus ETW/wpndb acquisition
  T=$(tail_new); printf '%s\n' "$T" > "$OUT/after-informational.log"
  LINES=$(printf '%s' "$T" | grep -aF "$PSAUMID" || true)
  if printf '%s' "$LINES" | grep -qaE 'route id=[0-9]+ .*\(bridge; classifier verdict\)'; then
    ok "the classifier's verdict routed a non-allowlisted informational toast to the bridge"
  elif printf '%s' "$LINES" | grep -qaE 'skip id=[0-9]+ '; then
    no "it took the window path - the verdict did not drive the route: $(printf '%s' "$LINES" | tail -2 | tr '\n' ' ')"
  else
    no "the bridge logged NOTHING for $PSAUMID - missing data, not a verdict"
  fi
fi

log "case 2: realchoice (buttons), AUMID $CTLAUMID - not allowlisted"
if ! fire_ctl "classroute-choice-$RANDOM" >/dev/null; then
  log "INSTRUMENT: the realchoice toast never confirmed FIRED - case 2 not graded"
else
  sleep 14
  T2=$(tail_new); printf '%s\n' "$T2" > "$OUT/after-realchoice.log"
  LINES2=$(printf '%s' "$T2" | grep -aF "$CTLAUMID" || true)
  if printf '%s' "$LINES2" | grep -qaE 'skip id=[0-9]+ .*\(window path; classifier verdict\)'; then
    ok "a buttoned toast stayed on the window path, by verdict - the user keeps its buttons"
  elif printf '%s' "$LINES2" | grep -qaE 'route id=[0-9]+ .*bridge'; then
    no "a BUTTONED toast was bridged - the user cannot act on it, the direction that must never fail"
  else
    no "no decision logged for the realchoice toast - missing data"
  fi
fi

log "case 3: nothing was deferred for ever"
printf '%s\n%s\n' "${T:-}" "${T2:-}" | grep -aE 'await id=[0-9]+ ' > "$OUT/awaits.txt" || true
AW=$(wc -l < "$OUT/awaits.txt")
# The cap is 3 passes per toast; two toasts fired here, so >6 await lines means something is
# being deferred past it.
if [ "${AW:-0}" -le 6 ]; then ok "deferrals bounded ($AW await lines, cap is 3 passes per toast)"
else no "$AW await lines - a toast is being deferred past its cap"; fi

dismiss_toasts >/dev/null 2>&1 || true
log "RESULT: $pass passed, $fail failed; evidence in $OUT"
[ "$fail" = 0 ] && [ "$pass" -ge 3 ]
