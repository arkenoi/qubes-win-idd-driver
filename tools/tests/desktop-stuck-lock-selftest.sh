#!/usr/bin/env bash
# A CONSOLE USER WITHOUT A SHELL IS A LOGON, NOT A LOCK - desktop-stuck needs a shell seen.
# run: tools/tests/desktop-stuck-lock-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
SRC=agent/gui-agent/main.c
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }
[ -f "$SRC" ] || { echo "FAIL $SRC is missing - nothing ran (missing data fails)"; exit 2; }

G=$(command grep -n "QerrTextFind(\"desktop-stuck\")" "$SRC" | tail -1 | cut -d: -f1)
[ -n "$G" ] || { bad "the desktop-stuck notification call is gone"; echo "  ---- $pass passed, $fail failed"; exit 1; }
GATE=$(awk -v e="$G" 'NR>=e-6 && NR<=e' "$SRC")

command grep -q "consoleUser && shellSeen" <<< "$GATE" \
  && ok "the lock arm requires a shell to have been seen - a logon in flight is not a lock" \
  || bad "the lock arm fires on a console user alone; an ordinary autologon boot satisfies it"
command grep -q "!autoArmed" <<< "$GATE" \
  && ok "unarmed autologon still notifies - the case the route was built for" \
  || bad "unarmed autologon no longer notifies; that is the conclusive case"
command grep -q "SECURE_DESKTOP_NOTIFY_ARMED_MS" <<< "$GATE" \
  && ok "the backstop survives for armed autologon that never completes" \
  || bad "the backstop is gone; armed-but-never-completing would never be reported"
# the fast path must keep its own shell requirement, which this change is modelled on
command grep -q "lockRead.ShellSeen" "$SRC" \
  && ok "the fast-path lock report still rests on a shell having been seen" \
  || bad "the fast path lost its shell requirement"

# SEEN TO FAIL: with the shell requirement dropped, a console user alone fires the notification.
D=$(mktemp -d "${TMPDIR:-/tmp}/deskstuck-XXXXXX"); trap 'rm -rf "$D"' EXIT
sed -E 's/consoleUser \&\& shellSeen \&\& !s_LockReported/consoleUser \&\& !s_LockReported/' "$SRC" > "$D/regressed.c"
RG=$(command grep -n "QerrTextFind(\"desktop-stuck\")" "$D/regressed.c" | tail -1 | cut -d: -f1)
RGATE=$(awk -v e="$RG" 'NR>=e-6 && NR<=e' "$D/regressed.c")
command grep -q "consoleUser && shellSeen" <<< "$RGATE" \
  && bad "the regression copy still requires a shell - the case cannot be driven" \
  || ok "SEEN TO FAIL: without it, a console user with no shell notifies during an ordinary autologon"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
