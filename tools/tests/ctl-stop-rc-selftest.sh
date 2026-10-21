#!/bin/bash
# A CONTROL WINDOW THAT DID NOT CLOSE MUST NOT BE SILENT.
#
# MEASURED 2026-10-21 by the harness audit: ctl_stop's last command was its printf, so every
# outcome except a malformed pid returned 0 - "not-ours" (that pid belongs to a different process
# now, so OURS was never stopped) and "STILL-RUNNING" (stop sent, alive after 5 s) came back with
# the same exit code as a confirmed stop. matrix.sh's call site was
#     say "  notepad: $(QTEST_VM=$app T=45 ctl_stop "${nppid:-0}" "${npstart:-0}")"
# which prints the string and never branches, so a control window that failed to close stayed on
# the guest desktop to be counted by the window-map grading step later in the SAME cell.
#
# The mapping is extracted from the shipped library between its two markers and driven over every
# outcome string the guest side can produce.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
L=mgmt/harness/lifecycle-lib.sh
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

map=$(awk '/# CTL-STOP-RC-A/,/# CTL-STOP-RC-B/' "$L")
if [ -n "$map" ] && printf '%s' "$map" | command grep -qa 'STILL-RUNNING'; then
  ok "the exit mapping was extracted from $L ($(printf '%s' "$map" | wc -l) lines)"
else
  echo "FATAL: could not extract the ctl_stop exit mapping from $L"; exit 2
fi

# THE MAPPING MUST RUN INSIDE A FUNCTION, because it ends in `return`. The first version eval'd it
# at the top level of `bash -c`, where return does not return, so every outcome fell through to the
# sentinel and read as 99 - the harness failing, not the mapping. It is a function in the library,
# so it is a function here.
rc_of(){ # $1 = the line the guest side produced -> the exit code the mapping gives
  bash -c '
    _probe(){ out="$1"; eval "$2"; return 99; }
    _probe "$1" "$2"
  ' _ "$1" "$map" >/dev/null 2>&1; printf '%s' "$?"
}

for spec in "CTLSTOP stopped:0" "CTLSTOP gone:0" "CTLSTOP not-ours pid 1234 start 99:3" \
            "CTLSTOP STILL-RUNNING:4" "CTLSTOP unknown no-answer:2" "CTLSTOP unknown no-pid:2" \
            "garbage from the guest:2"; do
  line=${spec%:*}; want=${spec##*:}
  got=$(rc_of "$line")
  if [ "$got" = "$want" ]; then ok "'$line' -> exit $got"
  else no "'$line' gave exit $got, want $want" "a stop outcome that shares an exit with success is invisible"; fi
done

# the three failure outcomes must NOT share an exit with success
a=$(rc_of 'CTLSTOP stopped'); b=$(rc_of 'CTLSTOP STILL-RUNNING'); c=$(rc_of 'CTLSTOP not-ours x')
if [ "$a" != "$b" ] && [ "$a" != "$c" ] && [ "$b" != "$c" ]; then
  ok "stopped, STILL-RUNNING and not-ours are three DISTINCT exits ($a/$b/$c)"
else no "two outcomes share an exit ($a/$b/$c)" "the caller cannot tell them apart"; fi

# and the caller must branch on it, or the mapping is decoration
if command grep -qaE '_ctl_rc=\$\?' mgmt/harness/matrix.sh \
   && command grep -qaE 'case "\$_ctl_rc" in' mgmt/harness/matrix.sh \
   && command grep -qa 'the control window did NOT close' mgmt/harness/matrix.sh; then
  ok "matrix.sh captures the exit and grades 3 and 4 as cell failures"
else
  no "matrix.sh does not branch on ctl_stop's exit" "the mapping would be decoration"
fi

# SEEN TO FAIL: with the mapping removed, STILL-RUNNING is indistinguishable from stopped
got=$(bash -c 'out="$1"; printf "%s\n" "$out" >/dev/null; exit 0' _ 'CTLSTOP STILL-RUNNING' >/dev/null 2>&1; printf '%s' "$?")
[ "$got" = 0 ] && ok "SEEN TO FAIL: without the mapping STILL-RUNNING exits 0, like a real stop" \
               || no "the pre-fix shape did not reproduce (got $got)" "the check cannot be driven"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
