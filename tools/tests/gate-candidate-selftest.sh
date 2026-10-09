#!/bin/bash
# Does gate-remainder's assert_candidate refuse a subject that is not running the candidate?
#
# WHY THIS TEST EXISTS. gate-preflight and log-sweep grade $VM11 AS IT IS - neither installs
# anything. At HEAD fe4337174ba8 that guest was still carrying agent 4.3.32.612 while the candidate
# package was 4.3.36+agent.eb24cb5115ba, and nothing checked: the gate spent a whole run grading a
# binary that was never the candidate, and reported a FIXED defect as present (the two keyed-mutex
# DXGI_ERROR_ACCESS_LOST error lines, whose guard is present in eb24cb5115ba and so could not have
# come from it - the sweep's archived logs name Module version 4.3.32.612 for every instance).
#
# The ACCEPT path cannot be driven on the rig without a guest that happens to run the reference
# binary, and pulling the guest's exe out to hash it locally corrupts it (the VMShell stream carries
# cmd's banner). So the guest call goes through QTEST_BIN, overridden here by a stand-in that also
# EMITS THAT BANNER - because tolerating it is part of what is being tested.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fakeqtest" <<'FAKE'
#!/bin/bash
# stands in for tools/qtest: answers RUNSHA with $FAKE_RUNSHA, behind cmd's banner
[ "${1:-}" = run ] && {
  printf 'Microsoft Windows [Version 10.0.26300.9457]\r\n(c) Microsoft Corporation. All rights reserved.\r\n\r\nRUNSHA %s\r\n' "${FAKE_RUNSHA:-none}"
  exit 0
}
exit 0
FAKE
chmod +x "$TMP/fakeqtest"

# assert_candidate reads $SETUP, $DRY, $LOG and say(); provide them, then source the function
# ITSELF out of the harness so this test cannot drift from the code it checks.
DRY=0; LOG=/dev/null
say(){ printf '%s\n' "$*"; }
eval "$(sed -n '/^assert_candidate() {/,/^}/p' tools/gate-remainder.sh)"
command -v assert_candidate >/dev/null || { echo "FAIL could not extract assert_candidate from tools/gate-remainder.sh"; exit 2; }

export QTEST_BIN="$TMP/fakeqtest"
SETUP="$TMP/setup"; mkdir -p "$SETUP/reference"
printf 'pretend-agent-bytes\n' > "$SETUP/reference/gui-agent.exe"
REF=$(sha256sum "$SETUP/reference/gui-agent.exe" | cut -d' ' -f1)

pass=0; fail=0
chk(){ # <name> <got-rc> <want-rc>
  if [ "$2" = "$3" ]; then printf '  ok    %-52s rc=%s\n' "$1" "$2"; pass=$((pass+1))
  else printf '  FAIL  %-52s rc=%s (wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "=== gate-remainder assert_candidate"
FAKE_RUNSHA="$REF"     assert_candidate vmX >/dev/null 2>&1; chk "accepts the guest running the reference" $? 0
FAKE_RUNSHA="deadbeef" assert_candidate vmX >/dev/null 2>&1; chk "REFUSES another binary (the fe433717 case)" $? 2
FAKE_RUNSHA="none"     assert_candidate vmX >/dev/null 2>&1; chk "REFUSES when no agent runs" $? 2
FAKE_RUNSHA=""         assert_candidate vmX >/dev/null 2>&1; chk "REFUSES an unreadable answer" $? 2
FAKE_RUNSHA="$(printf '%s' "$REF" | tr 'a-f' 'A-F')" assert_candidate vmX >/dev/null 2>&1; chk "accepts regardless of hash case" $? 0

# And with no reference in the tree at all, it must refuse rather than pass vacuously.
rm -f "$SETUP/reference/gui-agent.exe"
FAKE_RUNSHA="$REF"     assert_candidate vmX >/dev/null 2>&1; chk "REFUSES when the package names no candidate" $? 2

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
