#!/usr/bin/env bash
# desktop-stuck-lock-selftest.sh - A CONSOLE USER WITHOUT A SHELL IS A LOGON, NOT A LOCK.
#
# `desktop-stuck` is a QERR_SEV_ACTION notification: it tells the user to go and sign in. It must go
# out only on positive evidence of the fault it names, never on elapsed time alone - that is the
# contract written above the gate in main.c.
#
# MEASURED win11-reinstall, campaign run 38971675274, agent pid 4184:
#   02:14:13.452  Default -> Winlogon, secure-desktop ENTERED
#   02:14:44.077  QGADESKSTUCK ... for 30 s ... (autologon=armed for 'user' console-user=1 shell-seen=0)
#   02:14:45.915  desktop-stuck sent to dom0
#   02:14:52.057  Winlogon -> Default   <- autologon completed, 8 s after the notification
# autologon was ARMED and the 600 s backstop was nowhere near, so the arm that fired was
# `consoleUser && !s_LockReported`, whose reasoning is "a human locked it". Nobody had: autologon
# creates the console session BEFORE the shell starts, so an ordinary autologon boot satisfies it.
#
# The fast-path lock report already requires a shell, from the owner's 2026-10-10 instruction
# ("NEVER assume there is as based on inaccurate measurements"). This holds the slow path to the
# same rule, and holds the backstop in place for armed-autologon-that-never-completes.
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
