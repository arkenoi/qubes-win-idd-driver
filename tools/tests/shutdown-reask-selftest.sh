#!/bin/bash
# ASKING ONCE IS NOT WAITING FOR AN ANSWER.
#
# `qwt_shutdown` issued `timeout 120 qvm-shutdown <vm>` - a bare ACPI request that, as its own
# comment says, "returns immediately and kills nothing" - and then polled to its whole deadline
# without ever re-issuing it. A request that is lost, or that lands while the guest is still busy
# with first-boot work, therefore read as a guest refusing to stop.
#
# MEASURED TWICE on win11de-qwt 2026-10-15, both times right after a deliberate GOLDEN_UNSEAL boot
# that wrote to the registry: the request went at 14:39:06 and the guest was still Running at
# 14:54:15 - 909 seconds - and a SECOND ask was answered in seconds. It cost two golden seals.
#
# A re-ask is the SAME idempotent request, never an escalation: nothing in this path may kill a
# guest, because a killed subject is contaminated and has to be redeployed.
#
# qwt_shutdown is eval'd out of the shipped file with a virtual clock, so this cannot drift from the
# harness and needs no guest.
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
