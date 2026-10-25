#!/usr/bin/env bash
# relay-vouch-selftest.sh - the updater deploy must PROVE what it built, OFFLINE.
#
# WHY. Measured on win11de-tup 2026-10-22, three template-update rounds: the deploy logged
# "updater agent deployed" while every relay launched afterwards bound the PASS'S OWN PID as its
# listen port (600, 2880, 4184, 5548, 6688, 8228) with no `parent=` on its listen line - so none was
# the shipped binary, nothing served 8082, and every update pass went SILENT. It had been reported
# FIXED (87e3a746) on offline legs and Jev scores, with no receipt that the new relay had ever run.
# $SetupRoot on a guest is a COPY (C:\qwt-improved-setup); a stale copy compiles an old binary while
# every step reports success, and the whole busy path keys on port 8082, which a pid-port defeats.
#
# The suite extracts RELAYSOURCEVOUCH, RELAYEXEVOUCH and RELAYBYIMAGE from the shipped
# guest/install-updater-agent.ps1 and RUNS them: the shipped .cs must pass, a source with any one
# capability marker removed must be refused, a binary without the UTF-16 marker must be refused
# (and an ASCII-only occurrence must NOT satisfy it), and a relay on our exe must be ended by pid
# whatever port it holds. This is offline and proves the CHECKS; the relay actually serving 8082 is
# a guest receipt and is not claimed here.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/tools/tests/relay-vouch-test.ps1"
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  $SUITE is missing - nothing ran"; exit 2; }
out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out"
n=$(printf '%s\n' "$out" | command grep -c '^ok  ')
f=$(printf '%s\n' "$out" | command grep -c '^FAIL')
if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 21 ]; then
  say "PASS  clean: rc=0 ok=$n fail=0"
else
  say "FAIL  clean: rc=$rc ok=$n fail=$f"; exit 1
fi
