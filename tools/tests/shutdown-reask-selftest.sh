#!/bin/bash
# ASKING ONCE IS NOT WAITING FOR AN ANSWER - qwt_shutdown RE-ASKS, and never escalates to a kill
# run: tools/tests/shutdown-reask-selftest.sh
# pass: exit 0
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# $1=source file  $2=halt-after-seconds (0 = never)  $3=deadline -> "rc|asks|elapsed"
run_shutdown(){
  local src="$1" haltat="$2" dl="$3" d="$T/r.$RANDOM"
  mkdir -p "$d"
  ( cd "$d" || exit 2
    _NOW=1000000; _T0=$_NOW
    date(){ case "${1:-}" in +%s) echo "$_NOW" ;; *) command date "$@" ;; esac; }
    sleep(){ _NOW=$(( _NOW + ${1:-1} )); }
    # the guest: Running until $haltat seconds have passed, then Halted
    qvm_ls_state(){ if [ "$2" != 0 ] && [ $(( _NOW - _T0 )) -ge "$2" ]; then echo Halted; else echo Running; fi; }
    qvm-ls(){
      case "$*" in
        *NAME,STATE*) echo "somevm|$(qvm_ls_state x "$HALTAT")" ;;
        *) echo "somevm" ;;                       # the existence check
      esac
    }
    qvm-shutdown(){ echo ask >> "$d/asks"; return 0; }
    # qwt_shutdown asks through the sealed primitive now, and only the function text is extracted
    # here - so the primitive is stubbed to ISSUE the request, which is what these legs count.
    toolstack_accept(){ qvm-shutdown "$1"; }
    timeout(){ shift; "$@"; }                     # drop the bound, run the command
    _qwt_boottime(){ echo ""; }
    export HALTAT="$2"
    : > "$d/asks"
    eval "$(sed -n '/^qwt_shutdown()/,/^}/p' "$src")"
    qwt_shutdown somevm "$3" >/dev/null 2>&1; rc=$?
    printf '%s|%s|%s' "$rc" "$(command grep -c . "$d/asks" 2>/dev/null || echo 0)" "$(( _NOW - _T0 ))"
  )
}

CUR="$ROOT/mgmt/harness/shutdown-lib.sh"

# ---- a guest that ignores the first request must be asked again
r=$(HALTAT=0 run_shutdown "$CUR" 0 600); asks=$(echo "$r" | cut -d'|' -f2); el=$(echo "$r" | cut -d'|' -f3)
if [ "${asks:-0}" -ge 4 ] 2>/dev/null; then
  ok "a guest that never halts is asked $asks times across a 600s deadline, not once"
else
  no "only $asks ask(s) in 600s - the request is still issued once and then waited out"
fi

# ---- the deadline still bounds it; a re-ask must not extend the wait
[ "${el:-0}" -le 700 ] 2>/dev/null && ok "the deadline still bounds the wait (${el}s for a 600s deadline)" \
                                   || no "the wait ran to ${el}s past a 600s deadline"

# ---- a guest that halts promptly is NOT asked twice (no pointless re-ask)
r=$(run_shutdown "$CUR" 20 600); rc=$(echo "$r" | cut -d'|' -f1); asks=$(echo "$r" | cut -d'|' -f2)
if [ "$rc" = 0 ] && [ "${asks:-0}" = 1 ]; then
  ok "a guest that halts in 20s is asked exactly once and returns 0"
else
  no "a prompt halt gave rc=$rc with $asks ask(s) - expected rc=0 and one ask"
fi

# ---- NOTHING MAY KILL. A kill contaminates a subject; this path only ever requests.
if command grep -aE 'qvm-kill|admin\.vm\.Kill' "$CUR" | command grep -qav '^[[:space:]]*#'; then
  no "shutdown-lib.sh has a live kill - a killed subject is contaminated and must be redeployed"
else
  ok "no live kill in shutdown-lib.sh - it only ever asks"
fi

# ---- NEGATIVE CONTROL: the pre-fix loop, which asked once
CTL="$T/pre.sh"
python3 - "$CUR" "$CTL" <<'PYCTL'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
# remove the re-ask block and its setup, restoring "ask once then poll"
t = re.sub(r'\n    # ASK AGAIN\..*?\n    local reask=120 nextask asks=1\n    nextask=\$\(\( \$\(date \+%s\) \+ reask \)\)\n',
           '\n', t, flags=re.S)
t = re.sub(r'\n        if \[ "\$\(date \+%s\)" -ge "\$nextask" \]; then\n.*?\n        fi\n',
           '\n', t, flags=re.S)
open(sys.argv[2], "w", encoding="utf-8").write(t)
PYCTL
if [ -s "$CTL" ] && ! command grep -qa 'asking again' "$CTL"; then
  r=$(run_shutdown "$CTL" 0 600); casks=$(echo "$r" | cut -d'|' -f2)
  [ "${casks:-0}" = 1 ] && ok "negative control: the pre-fix loop asks exactly once across 600s" \
                        || no "negative control did not reproduce - it asked $casks times"
else
  no "negative control could not be built from the shipped file"
fi

# ---- AN UNREADABLE RIG IS NOT AN ABSENT QUBE AND NOT A CLEAN SHUTDOWN -------------------------
# Found by the component re-grade, 2026-10-21: both rig reads in this function piped qvm-ls with
# 2>/dev/null and never read its status, so a denial, a timeout or a truncated answer produced an
# empty list. The existence check then returned 0 - "does not exist - nothing to shut down" -
# WITHOUT ASKING, and the poll's own empty-state branch returned 0 saying "it is gone, not
# unresponsive". Callers that read only the exit code (mgmt/clone-guest.sh:36,
# mgmt/clone-to-template.sh:208) take that as a clean halt.
run_blind(){ # $1=source file $2=readable-calls-before-going-blind -> rc
  local src="$1" nread="$2" d="$T/b.$RANDOM"
  mkdir -p "$d"
  ( cd "$d" || exit 2
    _NOW=1000000
    date(){ case "${1:-}" in +%s) echo "$_NOW" ;; *) command date "$@" ;; esac; }
    sleep(){ _NOW=$(( _NOW + ${1:-1} )); }
    printf '0' > "$d/calls"
    qvm-ls(){
      local n; n=$(cat "$d/calls"); printf '%s' "$(( n + 1 ))" > "$d/calls"
      if [ "$n" -lt "$NREAD" ]; then echo "somevm|Running"; fi   # blind after NREAD answers
    }
    qvm-shutdown(){ return 0; }
    toolstack_accept(){ qvm-shutdown "$1"; }
    timeout(){ shift; "$@"; }
    _qwt_boottime(){ echo ""; }
    export NREAD="$2"
    eval "$(sed -n '/^qwt_shutdown()/,/^}/p' "$src")"
    qwt_shutdown somevm 600 >/dev/null 2>&1; echo $?
  )
}

rc=$(run_blind "$CUR" 0)
[ "$rc" != 0 ] && ok "a rig that cannot be read at all does NOT report a clean shutdown (rc=$rc)" \
               || no "an unreadable rig returned 0" "that is a clean-shutdown verdict on no information"
[ "$rc" = 4 ] && ok "and it has its own exit code (4), so no caller can read it as a measurement" \
              || no "the unreadable case does not have its own code (rc=$rc)"

# readable once - so the qube is known to exist - then blind for the whole poll
rc=$(run_blind "$CUR" 1)
[ "$rc" != 0 ] && ok "going blind MID-POLL does not report 'it is gone' either (rc=$rc)" \
               || no "a mid-poll blind rig returned 0" "the 'no longer listed' branch fired on missing data"

# SEEN TO FAIL: the pre-fix text returns 0 for both
git -C "$ROOT" show HEAD:mgmt/harness/shutdown-lib.sh > "$T/head-sl.sh" 2>/dev/null || cp "$CUR" "$T/head-sl.sh"
if command grep -qa 'the rig could not be read' "$T/head-sl.sh"; then
  ok "negative control: HEAD already carries the rig-read guard (nothing to reproduce)"
else
  rc0=$(run_blind "$T/head-sl.sh" 0); rc1=$(run_blind "$T/head-sl.sh" 1)
  { [ "$rc0" = 0 ] && [ "$rc1" = 0 ]; } \
    && ok "SEEN TO FAIL: the pre-fix text reports a clean shutdown for both blind cases (0 and 0)" \
    || no "the pre-fix text did not reproduce the false pass (rc=$rc0/$rc1)" "then these legs measure something else"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
