#!/bin/bash
# qcon-session-selftest.sh - prove tools/qcon uses EXACTLY ONE attach per guest per session.
#
# WHY THIS EXISTS. Owner, 2026-09-17: "the proper way to use console is attach once and pray it
# won't break!" The old tools/qcon attached per invocation (a --raw probe, then a login attach,
# then one per command); the console admits one attacher, and on every stalled guest for a month
# the transcript read "login prompt, then nothing after the username, then nothing on every later
# attach" - written up ten times as guest death. Specimen 10 was lost by seven attaches in thirty
# minutes. This test runs the REBUILT tool against a fake console that behaves the measured way
# (tools/tests/qcon-fake-console.py: the first connection is served, every later one hears
# nothing, ever) and requires: open once -> run x3 -> close, every output complete and delimited;
# open twice REFUSED; run without open REFUSED (no implicit attach); a silent command reported as
# such with the session still usable; close removes the state; the attach ledger shows ONE attach.
#
# THE CHECK MUST BE SEEN TO FAIL. QCON_DEFECT=perattach re-introduces the old attach-per-command
# behaviour inside the shipped tool; run under it this test MUST fail on exactly "second command
# returns nothing" - the shape that lost specimen 10. The clean run spawns that defect run itself
# (case 9) and requires the failure to be that one, so a green clean run has watched the defect
# get caught. Only the attach primitive is swapped for the fake; everything else is shipped code.
#
#   tools/tests/qcon-session-selftest.sh             # clean run, exit 0 expected
#   QCON_DEFECT=perattach tools/tests/qcon-session-selftest.sh   # must FAIL on the named check
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

QCON=tools/qcon
FAKE=tools/tests/qcon-fake-console.py
pass=0; fail=0; failed_names=()
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
no(){
  fail=$((fail+1)); failed_names+=("$1"); echo "FAIL  $*"
  # Under the defect knob the run is FAIL-FAST: once the console has gone silent every later
  # check assumes a session that no longer answers, so listing them all would bury the one
  # failure that matters. The clean run never takes this exit.
  if [ -n "${QCON_DEFECT:-}" ]; then
    echo "=== qcon session selftest: $pass passed, $fail failed (QCON_DEFECT=$QCON_DEFECT, stopped at the first failure: '$1') ==="
    exit 1
  fi
}

INNER=0; [ "${1:-}" = "--inner" ] && INNER=1
T=$(mktemp -d "${TMPDIR:-/tmp}/qconsel.XXXXXX")
FAKEPIDS=()
cleanup(){
  for p in "${FAKEPIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  # any session daemon left behind by a failing case must not outlive the test
  for d in "$T"/state/qcon-*/; do
    [ -f "$d/pid" ] && kill "$(cat "$d/pid")" 2>/dev/null
  done
  rm -rf "$T"
}
trap cleanup EXIT

export QCON_STATE_ROOT="$T/state"
# Short budgets: the fake answers instantly, so these only bound the silent-command case.
export QCON_DEADLINE=6 QCON_STALL=2 QCON_LOGIN_DEADLINE=6 QCON_QUIET=0.4 QCON_BUDGET=120
LEDGER="$QCON_STATE_ROOT/qcon-attach-ledger.log"

start_fake(){ # <name> <extra args...> -> sets SOCK, appends to FAKEPIDS
  SOCK="$T/$1.sock"; shift
  python3 "$FAKE" "$SOCK" "$@" 2>>"$T/fake.log" &
  FAKEPIDS+=("$!")
  local i=0
  while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ -S "$SOCK" ] || { echo "FATAL: fake console did not come up"; exit 2; }
}
attaches(){ grep -c " ATTACH vm=$1 " "$LEDGER" 2>/dev/null; }
detaches(){ grep -c " DETACH vm=$1 " "$LEDGER" 2>/dev/null; }

# ================================================================== the main sequence
start_fake main --user tester --pass secret --host WIN-FAKE
export QCON_TRANSPORT="fake:$SOCK"
VM=fakevm

# ---- 1. open: ONE attach, wake, login ------------------------------------------------------
out=$($QCON open $VM --user tester --pass secret 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -d "$QCON_STATE_ROOT/qcon-$VM" ]; then
  ok "open succeeds (rc 0) and records its state"
else
  no "open" "open failed rc=$rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi
# The old tool had no `open` - under the knob it attaches nothing here, so this count is only
# meaningful for the shipped behaviour. The per-run attach count below covers the knob.
if [ -z "${QCON_DEFECT:-}" ]; then
  if [ "$(attaches $VM)" = 1 ] && printf '%s' "$out" | grep -q 'phase=shell'; then
    ok "open attached ONCE and logged in (ledger: 1 ATTACH, phase shell)"
  else
    no "open-once" "attaches=$(attaches $VM) after open: $(printf '%s' "$out" | tail -1)"
  fi
fi
if printf '%s' "$out" | grep -q '^qcon open:'; then
  ok "every open line says which verb it is in"
else
  no "open-lines" "open printed lines without the verb prefix"
fi

# ---- 2. run x3 through the ONE session - complete and delimited ----------------------------
# Checks are interleaved with the runs: an attach count taken after all three would not say
# WHICH run attached (the knob run's count read 3 "after run 1" while this was batched).
o1=$($QCON run $VM 'echo hello-1' 2>"$T/r1.err"); r1=$?
if [ $r1 -eq 0 ] && [ "$o1" = "hello-1" ]; then
  ok "run 1: output complete and delimited ('hello-1')"
else
  no "first-command" "first command wrong rc=$r1 out=$(printf '%q' "$o1") err=$(tr '\n' ' ' <"$T/r1.err")"
fi
if [ "$(attaches $VM)" = 1 ]; then
  ok "after the first command the ledger shows exactly ONE attach"
else
  no "attach-count-after-run1" "ledger shows $(attaches $VM) attaches after one command"
fi
o2=$($QCON run $VM 'ver' 2>"$T/r2.err"); r2=$?
if [ $r2 -eq 0 ] && printf '%s' "$o2" | grep -q 'Microsoft Windows \[Version' && [ -n "$o2" ]; then
  ok "run 2: second command through the SAME attach returns its output"
else
  # THE SHAPE THAT LOST SPECIMEN 10: the first attach answered, the second got nothing.
  no "second command returns nothing" "rc=$r2 out=$(printf '%q' "$o2") err=$(tr '\n' ' ' <"$T/r2.err")"
fi
o3=$($QCON run $VM 'echo one&echo two' 2>"$T/r3.err"); r3=$?
if [ $r3 -eq 0 ] && [ "$o3" = "$(printf 'one\ntwo')" ]; then
  ok "run 3: multi-line output complete ('one','two'), no marker or prompt leaked"
else
  no "third-command" "third command wrong rc=$r3 out=$(printf '%q' "$o3") err=$(tr '\n' ' ' <"$T/r3.err")"
fi
if [ "$(attaches $VM)" = 1 ]; then
  ok "after three commands the ledger still shows ONE attach"
else
  no "one-attach" "ledger shows $(attaches $VM) attaches for $VM after three commands"
fi

# ---- 3. open twice is REFUSED and names the holder ----------------------------------------
out=$($QCON open $VM --user tester --pass secret 2>&1); rc=$?
if [ $rc -eq 9 ] && printf '%s' "$out" | grep -q 'REFUSED' && printf '%s' "$out" | grep -q 'daemon pid' \
   && [ "$(attaches $VM)" = 1 ]; then
  ok "second open is REFUSED (rc 9), names the holder, and NO second attach happened"
else
  no "open-twice" "second open rc=$rc attaches=$(attaches $VM): $(printf '%s' "$out" | tail -1)"
fi
# the one-shot convenience must refuse too - it would be a second attach
out=$($QCON $VM 'echo sneaky' 2>&1); rc=$?
if [ $rc -eq 9 ] && [ "$(attaches $VM)" = 1 ]; then
  ok "one-shot form while a session exists is REFUSED (rc 9), no attach"
else
  no "oneshot-while-open" "one-shot rc=$rc attaches=$(attaches $VM): $(printf '%s' "$out" | tail -1)"
fi

# ---- 4. run without open is REFUSED - no implicit attach ------------------------------------
out=$($QCON run fakevm2 'echo nope' 2>&1); rc=$?
if [ $rc -eq 8 ] && [ "$(attaches fakevm2)" = 0 ] && [ -z "$(printf '%s' "$out" | grep -v '^qcon run:')" ]; then
  ok "run without open is REFUSED (rc 8) and attaches NOTHING"
else
  no "run-without-open" "rc=$rc attaches=$(attaches fakevm2): $(printf '%s' "$out" | tail -1)"
fi

# ---- 5. a silent command: reported as such, session LEFT OPEN and still usable -------------
o5=$($QCON run $VM --stall 1 --deadline 3 'hang 4' 2>"$T/r5.err"); r5=$?
if [ $r5 -eq 5 ] && grep -q 'no output in' "$T/r5.err" && grep -q 'LEFT OPEN' "$T/r5.err"; then
  ok "silent command -> rc 5 'no output in N s', session LEFT OPEN (no re-attach)"
else
  no "silent-command" "rc=$r5 out=$(printf '%q' "$o5") err=$(tr '\n' ' ' <"$T/r5.err")"
fi
st=$($QCON status $VM 2>&1); src=$?
if [ $src -eq 0 ] && printf '%s' "$st" | grep -q 'OPEN phase=shell'; then
  ok "status after the silent command: still OPEN, phase shell"
else
  no "status-open" "status rc=$src: $(printf '%s' "$st" | head -1)"
fi
sleep 3   # let the fake's hang expire; the late marker must be drained, not mistaken for output
o6=$($QCON run $VM 'echo after-silence' 2>"$T/r6.err"); r6=$?
if [ $r6 -eq 0 ] && [ "$o6" = "after-silence" ] && [ "$(attaches $VM)" = 1 ]; then
  ok "session usable after the silent command; late output of the stalled command not mistaken for this one"
else
  no "after-silence" "rc=$r6 out=$(printf '%q' "$o6") attaches=$(attaches $VM) err=$(tr '\n' ' ' <"$T/r6.err")"
fi

# ---- 6. close removes the state; ledger shows one ATTACH and one DETACH -------------------
out=$($QCON close $VM 2>&1); rc=$?
if [ $rc -eq 0 ] && [ ! -d "$QCON_STATE_ROOT/qcon-$VM" ] && [ "$(attaches $VM)" = 1 ] && [ "$(detaches $VM)" = 1 ]; then
  ok "close detaches, removes the state dir; ledger = 1 ATTACH + 1 DETACH"
else
  no "close" "close rc=$rc dir=$([ -d "$QCON_STATE_ROOT/qcon-$VM" ] && echo present || echo gone) attaches=$(attaches $VM) detaches=$(detaches $VM): $(printf '%s' "$out" | tail -1)"
fi
if [ -f "$QCON_STATE_ROOT/qcon-$VM.closed.log" ] && grep -q 'hello-1' "$QCON_STATE_ROOT/qcon-$VM.closed.log"; then
  ok "the raw transcript survives close (qcon-$VM.closed.log holds the exchanges)"
else
  no "transcript" "no closed transcript, or it lacks the exchanges"
fi
out=$($QCON status $VM 2>&1); rc=$?
if [ $rc -eq 8 ]; then
  ok "status after close: no session (rc 8)"
else
  no "status-after-close" "status rc=$rc: $(printf '%s' "$out" | head -1)"
fi

# ---- 7. THE FAKE ENFORCES ONE ATTACHER (validate the instrument, H5) ----------------------
# Everything above ran against the fake's FIRST connection. A fresh connection now must hear
# nothing, even after the first attacher has hung up - that is the measured shape, and if the
# fake did not enforce it the defect run below could not fail for the right reason.
got=$(python3 - "$SOCK" <<'EOF'
import socket, sys, select
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall(b"\r"); s.sendall(b"tester\r")
r, _, _ = select.select([s], [], [], 2.0)
print(len(s.recv(4096)) if r else 0)
EOF
)
if [ "$got" = 0 ]; then
  ok "fake console: a later attach hears NOTHING (the measured shape is modelled)"
else
  no "fake-one-attacher" "fake served a second attacher ($got bytes) - the fixture cannot reproduce the defect"
fi

# ---- 8. one-shot + shell on a fresh fake, still ONE attach each ---------------------------
start_fake second --user tester --pass secret --attaches-served 2
export QCON_TRANSPORT="fake:$SOCK"
o8=$($QCON fakevm3 --user tester --pass secret 'echo oneshot-ok' 2>"$T/r8.err"); r8=$?
if [ $r8 -eq 0 ] && [ "$o8" = "oneshot-ok" ] && [ "$(attaches fakevm3)" = 1 ] && [ "$(detaches fakevm3)" = 1 ] \
   && [ ! -d "$QCON_STATE_ROOT/qcon-fakevm3" ]; then
  ok "one-shot '<vm> <cmd>' = open+run+close in ONE attach, state removed"
else
  no "oneshot" "rc=$r8 out=$(printf '%q' "$o8") attaches=$(attaches fakevm3) detaches=$(detaches fakevm3) err=$(tr '\n' ' ' <"$T/r8.err")"
fi
# shell: opens (second served attach on this fake), forwards one typed line, leaves the session open
o9=$(printf 'echo via-shell\n' | $QCON shell fakevm3 --user tester --pass secret 2>"$T/r9.err"); r9=$?
sleep 0.5
if [ $r9 -eq 0 ] && printf '%s' "$o9" | grep -q 'via-shell' && [ "$(attaches fakevm3)" = 2 ] \
   && $QCON status fakevm3 >/dev/null 2>&1; then
  ok "shell: open + passthrough of a typed line, session still open, ONE attach for it"
else
  no "shell" "rc=$r9 attaches=$(attaches fakevm3) out=$(printf '%q' "$(printf '%s' "$o9" | tail -c 200)") err=$(tr '\n' ' ' <"$T/r9.err")"
fi
$QCON close fakevm3 >/dev/null 2>&1

# ---- 9. THE DEFECT KNOB IS CAUGHT (clean run only) ----------------------------------------
if [ $INNER -eq 0 ] && [ -z "${QCON_DEFECT:-}" ]; then
  dout=$(QCON_DEFECT=perattach bash "$0" --inner 2>&1); drc=$?
  dfail=$(printf '%s\n' "$dout" | grep '^FAIL' | sed 's/^FAIL  //; s/ .*//' )
  if [ $drc -ne 0 ] && [ "$dfail" = "second" ] \
     && printf '%s\n' "$dout" | grep -q '^FAIL  second command returns nothing' \
     && printf '%s\n' "$dout" | grep -q '^PASS  run 1: output complete'; then
    ok "DEFECT KNOB perattach: the test FAILS on exactly 'second command returns nothing' (first command still answered) - specimen 10's shape is caught"
  else
    no "defect-knob" "perattach run rc=$drc; failing checks: $(printf '%s' "$dfail" | tr '\n' ',') - expected exactly the second-command one"
  fi
fi

echo "=== qcon session selftest: $pass passed, $fail failed${QCON_DEFECT:+ (QCON_DEFECT=$QCON_DEFECT: a failure on 'second command returns nothing' is the EXPECTED outcome)} ==="
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
