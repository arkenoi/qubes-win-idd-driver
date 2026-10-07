#!/usr/bin/env bash
# admin-target-gate-selftest.sh - the gate that stops us writing 'denied' lines into the owner's
# dom0 log. Each case is the SHAPE OF A REAL COMMAND, two of them copied from the journal the owner
# pasted on 2026-10-07; and the last case re-introduces the original state (nothing enforces) and
# must then NOT block, because a gate never seen to fail is decoration.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="$ROOT/tools/hooks/admin-target-gate.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -x "$G" ] || { echo "FAIL  $G missing or not executable"; exit 2; }
run(){ printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$1}}" | bash "$G" >/dev/null 2>&1; echo $?; }
j(){ python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

# the two shapes that produced all fourteen lines in the owner's journal
[ "$(run "$(j 'qvm-ls --raw-data --fields NAME,TAGS')" )" = 2 ] \
  && ok "C1 --fields NAME,TAGS (fans tag.List over every qube) -> BLOCKED" \
  || bad "C1 --fields NAME,TAGS was allowed"
[ "$(run "$(j 'qvm-tags win-idd-mgmt')" )" = 2 ] \
  && ok "C2 qvm-tags win-idd-mgmt -> BLOCKED" || bad "C2 allowed"
[ "$(run "$(j 'for v in win11r-gz win-idd-mgmt dom0; do qvm-tags "$v"; done')" )" = 2 ] \
  && ok "C3 the exact loop I ran at 18:28, dom0 and win-idd-mgmt in it -> BLOCKED" || bad "C3 allowed"
[ "$(run "$(j 'qvm-prefs dom0 netvm')" )" = 2 ] \
  && ok "C4 qvm-prefs dom0 -> BLOCKED" || bad "C4 allowed"

# and everything legitimate must still run
[ "$(run "$(j 'qvm-ls --raw-data --fields NAME,STATE')" )" = 0 ] \
  && ok "C5 qvm-ls NAME,STATE (targets dom0 as a service, no qube argument, permitted) -> allowed" \
  || bad "C5 a permitted listing was blocked"
[ "$(run "$(j 'qvm-tags win11de-amab add win-idd-testbed')" )" = 0 ] \
  && ok "C6 tagging a subject we just created -> allowed" || bad "C6 blocked"
[ "$(run "$(j 'qvm-shutdown --wait win11r-gz')" )" = 0 ] \
  && ok "C7 acting on a testbed subject -> allowed" || bad "C7 blocked"
[ "$(run "$(j 'qvm-device block attach --ro --option devtype=cdrom win11-base win-idd-mgmt:loop7')" )" = 0 ] \
  && ok "C8 win-idd-mgmt:loop7 is a DEVICE ID, not a target -> allowed" || bad "C8 blocked a device attach"
[ "$(run "$(j 'qrexec-client-vm dom0 local.WinWindowShot')" )" = 0 ] \
  && ok "C9 a dom0 SERVICE call that does have a rule -> allowed" || bad "C9 blocked a permitted service call"
[ "$(run "$(j 'echo qvm-tags dom0 is the thing we must not run')" )" = 2 ] \
  && ok "C10 even inside an echo it is refused (conservative: the text is the only signal)" \
  || ok "C10 an echo mentioning it is allowed - acceptable either way, recorded"

# THE OVER-BLOCK. The first version refused a command whose only offence was WRITING A FILE that
# quoted the forbidden spelling - the memory note recording this rule - and then refused the
# commands that tried to fix it. A gate that blocks its own documentation gets switched off, and
# the noise comes back. A heredoc body is data, not arguments.
hd=$(printf 'cat > m.md <<%sEOF%s\nnever qvm-ls --raw-data --fields NAME,TAGS, never qvm-tags dom0\nEOF\n' "'" "'")
[ "$(run "$(j "$hd")")" = 0 ] \
  && ok "C12 a heredoc that WRITES the forbidden spelling into a file -> allowed (it is data)" \
  || bad "C12 over-blocks a file write that merely quotes the command"

# the gate must be load-bearing
[ "$(ADMIN_TARGET_GATE_DEFECT=1 run "$(j 'qvm-ls --raw-data --fields NAME,TAGS')" )" = 0 ] \
  && ok "C11 DEFECT RE-INTRODUCED: C1 is NOT blocked, so C1 proves the gate" \
  || bad "C11 the defect knob did not disable the gate - C1 proves nothing"

echo
echo "admin-target-gate-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
