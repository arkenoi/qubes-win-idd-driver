#!/usr/bin/env bash
# loginit-banner-debug-check.sh - patches/windows-utils-loginit-banner-debug.patch, OFFLINE.
#
# windows-utils' LogInit emitted six LogInfo lines on every process start, and qrexec-wrapper starts
# once per qrexec call: measured on run 39225775322, 155 invocations wrote ~1085 of that module's
# 1250 lines. Owner 2026-10-20: "it is NOT normal to have thousands of lines of log during the brief
# normal run". The patch demotes the six to LogDebug and single-birth-line.patch gives back ONE INFO
# line carrying the facts tools/log-sweep.py needs to bill a line to a build.
#
# THIS SUITE CHECKS THAT PATCH AND NOTHING ELSE. Everything it used to assert about the sweep's
# PARSER - version inheritance, 0.0.0.0, pid reuse, the debug-level double count - belongs to
# log-sweep.py and is tested where that code lives. Applied in the CI order, because
# one-log-per-module.patch is the only other patch touching log.c and this one is generated against
# the file after it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
pass=0; fail=0
ok(){  pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }

UP=upstream/ro/qubes-windows-utils/src/log.c
# upstream/ro is gitignored, so a checkout without it cannot run this: INCONCLUSIVE, not a pass.
[ -f "$UP" ] || { echo "INCONCLUSIVE: $UP absent (upstream/ro is gitignored) - nothing checked"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src"; cp "$UP" "$T/src/log.c"
( cd "$T" && git init -q . && git add src/log.c && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1

src=$T/src/log.c
command grep -qE 'LogInfo\("Log started' "$src" \
  && ok "control: upstream emits the startup banner at INFO" \
  || bad "upstream does not emit LogInfo(\"Log started\")" "the patch's premise is gone - re-read upstream"

rc=""
for p in one-log-per-module loginit-banner-debug single-birth-line; do
  o=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-$p.patch" 2>&1)
  r=$?; rc="$rc $p=$r"
  [ "$r" = 0 ] && ok "$p applies, in the CI order" \
               || bad "$p did not apply" "$(printf '%s' "$o" | tail -1)"
done

# Comments stripped before any source assertion: the explanations here name the very tokens the
# legs require and forbid, and an unfiltered grep finds its own prose.
code=$(command grep -v '^[[:space:]]*//' "$src")

# ---- the six banner lines: demoted, kept, none left at INFO -------------------------------------
for m in 'Log started, module name' 'System uptime: %.3f seconds' 'Running as user: %s' \
         'Module version: %d' 'Session: %lu' 'Command line: %s'; do
  case "$code" in
    *"LogDebug(\"$m"*) ok "demoted to LogDebug: $m" ;;
    *) bad "still not at LogDebug: $m" "a product session keeps flooding" ;;
  esac
done
left=$(printf '%s' "$code" | command grep -c 'LogInfo("Log started\|LogInfo("System uptime\|LogInfo("Running as user\|LogInfo("Module version\|LogInfo("Session:\|LogInfo("Command line')
[ "$left" = 0 ] && ok "no banner line is left at INFO" || bad "$left banner line(s) still at INFO" "the demotion was undone"

# ---- the birth line: ONE statement, and every token checked INSIDE IT ----------------------------
# NEVER GREP THE WHOLE FILE FOR THESE TOKENS. That is what this suite did until 2026-10-26: a token
# sitting in any unrelated statement satisfied a check whose own heading says "in ONE line", and a
# token missing from the birth line but present elsewhere satisfied it too.
# NOR a sed range: `/LogInfo("QWTBIRTH module=/,/);/p` does not test the end pattern on the line
# that opened the range, so a one-line statement runs on to the next `);` or to EOF and admits
# unrelated code's tokens - the same false pass (Jev: can_miss_or_overmatch 0.92). Flatten, take the
# text after the opening, cut at the FIRST `);`. $birth is the only thing the loop may read.
flat=$(printf '%s' "$code" | tr '\n' ' ' | tr -s ' ')
case "$flat" in
  *'LogInfo("QWTBIRTH module='*)
    birth=${flat#*'LogInfo("QWTBIRTH module='}
    birth="LogInfo(\"QWTBIRTH module=${birth%%');'*}"
    ok "the birth line is emitted at INFO, so a product session carries it" ;;
  *) birth=""
    bad "no LogInfo(\"QWTBIRTH module=\" in the patched source" "the sweep has no build to bill a line to" ;;
esac
# A failing leg must say what it read. CI run 40281268355 reported "the birth line omits
# ver=%d.%d.%d.%d" on a tree where the token is there, and carried no evidence at all.
receipt="apply rc:$rc; upstream $(command sha256sum "$UP" | cut -c1-12); birth=<${birth:-ABSENT}>"
for k in 'module=%s' 'ver=%d.%d.%d.%d' 'pid=%lu' 'session=%lu' 'uptime=%.3f'; do
  case "$birth" in
    *"$k"*) ok "the birth line states $k" ;;
    *)      bad "the birth line omits $k" "log-sweep.py cannot rebuild the init record without it - $receipt" ;;
  esac
done
n=$(printf '%s' "$code" | command grep -c 'LogInfo("QWTBIRTH')
[ "$n" = 1 ] && ok "one process start costs exactly one INFO line (not six)" \
             || bad "$n QWTBIRTH INFO lines in LogInit" "the volume objection is back"

# ---- the producer's spelling must satisfy its two consumers --------------------------------------
# Quoted from the consumers, not invented here: sweep-gate.sh greps 'QWTBIRTH module=' and
# log-sweep.py tests msg.startswith("QWTBIRTH ").
command grep -q "QWTBIRTH module=" tools/sweep-gate.sh \
  && ok "sweep-gate.sh still greps the marker this patch writes" \
  || bad "sweep-gate.sh no longer greps QWTBIRTH module=" "the life gate went blind to the producer"
command grep -q 'msg.startswith("QWTBIRTH ")' tools/log-sweep.py \
  && ok "log-sweep.py still reads the marker this patch writes" \
  || bad "log-sweep.py has no QWTBIRTH handler" "the producer would land with no consumer"

echo
echo "loginit-banner-debug-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
