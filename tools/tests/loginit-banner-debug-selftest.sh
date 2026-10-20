#!/usr/bin/env bash
# loginit-banner-debug-selftest.sh - patches/windows-utils-loginit-banner-debug.patch, OFFLINE.
# No guest, no CI.
#
# WHAT IT GUARDS. qrexec-wrapper is a SHORT-LIVED process spawned once per qrexec call, and
# windows-utils' LogInit emits six LogInfo lines every time one starts - Log started / System
# uptime / Running as user / Module version / Session / Command line. Measured on acceptance run
# 39225775322, one brief WIN10-clean cell: 155 invocations, ~1085 of that module's 1250 lines were
# that banner - 87% of the file a process announcing its own birth - and the whole guest session
# read 2535 INFO against 52 WARN and 2 ERROR. Owner 2026-10-20: "it is NOT normal to have
# thousands of lines of log during the brief normal run ... ok for debug purposes but not on a
# product session."
#
# The fix demotes them to LogDebug: gone at the default level, all back at LOG_LEVEL_DEBUG, which
# is where a startup banner belongs. The lines are NOT deleted - losing them would cost the one
# thing they are good for, telling support which build wrote a log.
#
# ORDER MATTERS: one-log-per-module.patch is the only other patch touching log.c, and this one is
# generated against the file AFTER it. The test applies both in the CI order, so a future patch
# that collides is caught here rather than in a build.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
pass=0; fail=0
ok(){  pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }

UP=upstream/ro/qubes-windows-utils/src/log.c
# upstream/ro is gitignored (.gitignore), so a checkout without it cannot run this. That is
# INCONCLUSIVE, not a pass: a suite that quietly skips is a suite that reports success.
[ -f "$UP" ] || { echo "INCONCLUSIVE: $UP absent (upstream/ro is gitignored) - nothing checked"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src"; cp "$UP" "$T/src/log.c"
( cd "$T" && git init -q . && git add src/log.c && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1

# the banner is at INFO before anything is applied - the control for everything below
if command grep -qE 'LogInfo\("Log started' "$T/src/log.c"; then
  ok "control: upstream emits the startup banner at INFO"
else
  bad "control: upstream does not emit LogInfo(\"Log started\")" "the patch's premise is gone; re-read upstream before trusting this suite"
fi

a=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-one-log-per-module.patch" 2>&1); arc=$?
[ "$arc" = 0 ] && ok "one-log-per-module applies (it is applied first in CI)" \
                || bad "one-log-per-module did not apply" "$(printf '%s' "$a" | tail -1)"
b=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-loginit-banner-debug.patch" 2>&1); brc=$?
[ "$brc" = 0 ] && ok "loginit-banner-debug applies AFTER it, in the CI order" \
                || bad "loginit-banner-debug did not apply after one-log-per-module" "$(printf '%s' "$b" | tail -1)"

src=$T/src/log.c
# every banner line demoted...
for m in 'Log started, module name' 'System uptime: %.3f seconds' 'Running as user: %s' 'Module version: %d' 'Session: %lu' 'Command line: %s'; do
  if command grep -q "LogDebug(\"$(printf '%s' "$m" | cut -c1-20)" "$src" 2>/dev/null \
     || command grep -qF "LogDebug(\"$m" "$src"; then
    ok "demoted to LogDebug: $m"
  else
    bad "still not at LogDebug: $m" "$(command grep -nF "$m" "$src" | head -1 | cut -c1-110)"
  fi
done
# ...and NOT deleted: the banner must survive, just quieter
kept=$(command grep -c 'LogDebug("Log started\|LogDebug("System uptime\|LogDebug("Running as user\|LogDebug("Module version\|LogDebug("Session:\|LogDebug("Command line' "$src")
[ "$kept" -ge 6 ] && ok "the banner is KEPT at debug ($kept line(s)), not deleted" \
                  || bad "banner lines were lost, not demoted ($kept found)" "support loses which build wrote a log"
# ...and none left at INFO
left=$(command grep -c 'LogInfo("Log started\|LogInfo("System uptime\|LogInfo("Running as user\|LogInfo("Module version\|LogInfo("Session:\|LogInfo("Command line' "$src")
[ "$left" = 0 ] && ok "no banner line is left at INFO" \
                || bad "$left banner line(s) still at INFO" "a product session keeps flooding"

echo
echo "loginit-banner-debug-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
