#!/usr/bin/env bash
# relay-close-selftest.sh - offline proof matrix for the relay's close/refusal contract
# (guest/qubes-updates-relay.cs, file header "THE RELAY SERVES OR REFUSES"): no silent close, no
# keep-alive lie, no transient answer to a sanctioned request, denied svchosts named by the services
# they host. Measured defect 2026-09-17 on win11de-gwt: 21 connections reset by the relay's side with
# no log line for any of them (findings/issues.md P1 "A KILLED UPDATE PASS COSTS dom0 TWO SILENT HOURS").
#
# Runs on this dev qube with the linux pwsh; no rig, no guest, no qrexec. The suite is
# tools/tests/relay-close-test.ps1, which compiles the SHIPPED source with Add-Type and drives the real
# HandleInbound over loopback sockets, a fake qrexec-client-vm and a scripted SCM.
#
#   no env                    full matrix: the clean leg must PASS, and each defect knob must make the
#                             suite FAIL on the check it targets and only inside its own case family
#                             (a guard never seen to fail is decoration). Exit 0 only if every leg came
#                             out as required.
#   RELAYCLOSE_DEFECT=silent  run ONLY that knob (bare closes, uncounted DENY repeats) and exit with
#   RELAYCLOSE_DEFECT=keepalive  the suite's own code - i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${RELAYCLOSE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/relay-close-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/relay-close-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check each knob must break, and the check-name prefixes its failures are allowed to carry.
target_of() {
    case "$1" in
        silent)    printf '%s' "readfirst: a connection that sent nothing -> exactly one CLOSE reason=read-first-empty line naming the peer" ;;
        keepalive) printf '%s' "keepalive-buffered: a warm channel answered Connection: keep-alive -> the client got Connection: close, exactly once" ;;
        *)         return 1 ;;
    esac
}
allowed_of() {
    case "$1" in
        silent)    printf '%s' '^FAIL (readfirst|nochannel-plain|nochannel-connect|deny)' ;;
        keepalive) printf '%s' '^FAIL (keepalive-buffered|keepalive-streamed|selftest)' ;;
    esac
}

if [ -n "${RELAYCLOSE_DEFECT:-}" ]; then
    target_of "$RELAYCLOSE_DEFECT" >/dev/null || { say "FAIL  unknown RELAYCLOSE_DEFECT='$RELAYCLOSE_DEFECT' (silent|keepalive)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$RELAYCLOSE_DEFECT"; rc=$?
    say "--- defect knob $RELAYCLOSE_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 24 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

for d in silent keepalive; do
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
    want="$(target_of "$d")"
    stray=$(grep '^FAIL' "$OUT/defect-$d.out" | grep -vE "$(allowed_of "$d")" | head -3 | cut -c6-120)
    if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out" && [ -z "$stray" ]; then
        say "PASS  defect $d: suite FAILED as required on its target and only within its case family (rc=$rc, $f failing checks)"
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out"; then
        say "FAIL  defect $d: target failed but so did checks outside its family: $stray"; bad=1
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
        say "FAIL  defect $d: suite failed (rc=$rc) but NOT on its target check '$want' - the knob broke something else"; bad=1
    else
        say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
    fi
done

say "--- outputs in $OUT"
exit $bad
