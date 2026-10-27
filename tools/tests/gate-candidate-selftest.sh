#!/bin/bash
# gate-remainder's assert_candidate REFUSES a guest that is not running the candidate binary.
# run: tools/tests/gate-candidate-selftest.sh
# pass: exit 0
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
