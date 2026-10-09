#!/usr/bin/env bash
# reporter-env-build.sh <vm> <reporter> - bring a SUBJECT to the reporter's recorded environment,
# for the facts a harness can actually build. Then env-assert.sh must pass on its own.
#
# WHY THIS EXISTS, MEASURED 2026-10-09. The 4.3.36 release gate's template-update test exited 2 -
# INSTRUMENT - on "env-assert win11de-tup gweck failed": open_shell_installed MISMATCH (got false)
# and service_enablewinkey MISSING (not measured). Both facts were added to mgmt/reporters/gweck.json
# on 2026-10-08 precisely because two P1s had been recorded "verified on his environment" from runs
# that had NEITHER, so the agent's injected Escape had nothing to land in. The subject is cloned
# from the sealed golden win11de-qwt, which carries no Open-Shell, and the golden must never be
# booted (owner 2026-09-16) - so the build belongs HERE, on the subject, after the clone.
# Until now it lived in scratchpad/install-openshell-for.sh: gitignored, hardcoded to one guest's
# user path, runnable by nobody but the session that wrote it. A release gate cannot depend on that.
#
# THE VENDOR BINARY IS NOT IN THIS REPO and never will be - the repo is PUBLIC. Point OPENSHELL_EXE
# at it, or accept the hard failure: a helper that silently skips is how an environment stops being
# the reporter's (helpers must be explicitly packaged; missing data FAILS).
#
# Idempotent: every step checks the guest's actual state first, so re-running costs seconds.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: $0 <vm> <reporter>}"
REPORTER="${2:?usage: $0 <vm> <reporter>}"
JSON="mgmt/reporters/${REPORTER}.json"
[ -f "$JSON" ] || { echo "FAIL  no reporter file $JSON - nothing to build towards"; exit 2; }
OPENSHELL_EXE="${OPENSHELL_EXE:-scratchpad/openshell/OpenShellSetup_4_4_198.exe}"
OUT="${OUT:-scratchpad/reporter-env-$VM}"
mkdir -p "$OUT" || exit 2
export QTEST_VM="$VM"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Which facts does this reporter ASSERT, and which of them can this script build?
want(){ python3 - "$JSON" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
f=(d.get("environment") or {}).get(sys.argv[2])
print(f.get("value","") if (f and f.get("assert")) else "")
PY
}
WANT_OPENSHELL=$(want open_shell_installed)
WANT_WINKEY=$(want service_enablewinkey)
say "reporter $REPORTER asserts: open_shell_installed='${WANT_OPENSHELL:-<not asserted>}' service_enablewinkey='${WANT_WINKEY:-<not asserted>}'"

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { echo "FAIL  could not take the vmlock for $VM"; exit 2; }

# ---- the qube-side fact first: it needs no session, and a reboot is not required ---------------
# service.enableWinKey is a QUBE feature, which is where env-assert.sh reads it from.
if [ -n "$WANT_WINKEY" ]; then
  have=$(qvm-features "$VM" service.enableWinKey 2>/dev/null)
  if [ "$have" = "$WANT_WINKEY" ]; then say "service.enableWinKey already $have"
  else
    qvm-features "$VM" service.enableWinKey "$WANT_WINKEY" \
      || { echo "FAIL  could not set service.enableWinKey on $VM"; exit 2; }
    say "set service.enableWinKey=$WANT_WINKEY (was '${have:-<unset>}')"
  fi
fi

[ "${WANT_OPENSHELL,,}" = "true" ] || { say "nothing else to build"; exit 0; }

# ---- is it already there? ask the GUEST, not a record ------------------------------------------
# The guest must be up for this, and THIS script does not start it: the caller owns the subject's
# lifecycle (template-update-test.sh halts it, sets guivm and starts it again in a fixed order).
# A halted guest is a TERMINAL state here, named at once rather than after a four-minute wait.
# grep -a: `qtest state` returns the raw admin response, which begins '0\0' - a NUL in the first
# bytes makes it a BINARY stream, and a grep without -a reports no match on a perfectly good
# answer. Measured here 2026-10-09; the same trap is recorded for guest log captures.
st=$(timeout 30 tools/qtest state 2>/dev/null | command grep -ao 'power_state=[A-Za-z]*')
case "${st:-}" in
  *Halted*) echo "FAIL  $VM is $st - start it before building the reporter's environment on it"; exit 2 ;;
esac
# Three exits: answered, terminal (qrexec gone), deadline.
up=0
for i in $(seq 1 24); do
  if timeout 30 tools/qtest run 'cmd /c echo QREXEC_UP' 2>/dev/null | command grep -qa '^QREXEC_UP'; then
      up=1; say "qrexec answered at t+$((i*10))s"; break; fi
  sleep 10
done
[ "$up" = 1 ] || { echo "FAIL  qrexec never answered on $VM within 240 s - nothing built"; exit 2; }

# -EncodedCommand, which is what lint-harness points at: escaped quotes inside -Command fail
# SILENTLY, and a cmd one-liner cannot carry these paths either - measured 2026-10-09 on
# win11de-tup, where `(if exist "..." echo EXE_PATH=C:\Program Files (x86)\...)` printed NOTHING
# because the unquoted parentheses of "(x86)" close cmd's own block. Base64 UTF-16LE has no
# quoting to get wrong, and it needs no session, so it can run before the session wait.
b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
probe_openshell(){
  local ps='$e=@("C:\Program Files\Open-Shell\StartMenu.exe","C:\Program Files (x86)\Open-Shell\StartMenu.exe") | Where-Object { Test-Path $_ }; foreach ($p in $e) { Write-Output ("EXE_PATH=" + $p) }; Write-Output "PROBE-DONE"'
  timeout 180 tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$ps")" 2>/dev/null
}
# A probe that did not run is not a negative answer: PROBE-DONE must be present either way.
probe_says_present(){   # $1 = probe output file
  command grep -qa '^PROBE-DONE' "$1" || { echo "FAIL  the Open-Shell probe did not complete - no verdict"; return 2; }
  command grep -qa '^EXE_PATH=' "$1"
}
probe_openshell > "$OUT/probe-before.txt" 2>&1
probe_says_present "$OUT/probe-before.txt"; pre=$?
[ "$pre" = 2 ] && { cat "$OUT/probe-before.txt"; exit 2; }
if [ "$pre" = 0 ]; then
  say "Open-Shell is already installed: $(command grep -a -m1 '^EXE_PATH=' "$OUT/probe-before.txt")"
  exit 0
fi

[ -s "$OPENSHELL_EXE" ] || {
  echo "FAIL  the reporter asserts Open-Shell and $VM does not have it, and the installer is not at"
  echo "      $OPENSHELL_EXE. The vendor binary is deliberately NOT in this public repo: place it"
  echo "      there (or set OPENSHELL_EXE) and re-run. Refusing to grade a subject that is not the"
  echo "      reporter's environment."
  exit 2
}

# THE FILE RECEIVER RUNS IN THE USER SESSION. qrexec answering is the pre-session SYSTEM channel;
# pushing before a session exists dies with "sent 0/NNNN KBEOF" (measured 2026-10-08 on win11de-ur1).
sess=0
for i in $(seq 1 30); do
  if timeout 30 tools/qtest run 'cmd /c query session' 2>/dev/null | command grep -aqE 'Aktiv|Active'; then
      sess=1; say "a session is active at t+$((i*10))s"; break; fi
  if ! timeout 20 tools/qtest run 'cmd /c echo ALIVE' 2>/dev/null | command grep -qa '^ALIVE'; then
      echo "FAIL  qrexec went away while waiting for a session - terminal, nothing pushed"; exit 2; fi
  sleep 10
done
[ "$sess" = 1 ] || { echo "FAIL  no active session within 300 s on $VM - nothing pushed"; exit 2; }

base=$(basename "$OPENSHELL_EXE")
say "pushing $(stat -c%s "$OPENSHELL_EXE") bytes ($base)"
# The Windows receiver NEVER overwrites: a name already in QubesIncoming fails rc=17, so clear it.
timeout 120 tools/qtest run "cmd /c del /q \"C:\\Users\\*\\Documents\\QubesIncoming\\win-idd-mgmt\\$base\" 2>nul & echo CLEARED" >/dev/null 2>&1
timeout 300 tools/qtest push "$OPENSHELL_EXE" > "$OUT/push.txt" 2>&1 \
  || { echo "FAIL  push failed"; tail -3 "$OUT/push.txt"; exit 2; }

# /qn is NOT a guessed switch: Open-Shell's Src/Setup/Setup.cpp accepts /qn|/q|/quiet|/passive and
# runs `msiexec.exe /i "<extracted msi>" <rest of the command line>` - documented by the source that
# builds this exact binary (no guesswork on vendor installers).
# A PUSHED SCRIPT, not an inline -Command: the quoting of the latter is what lint-harness refuses,
# and it has failed silently before. The script is generated here so the installer's name travels
# with it and nothing is hardcoded to one guest's user profile.
cat > "$OUT/openshell-install.ps1" <<PS1
# Stage the pushed installer out of QubesIncoming and run it silently.
# /qn is NOT guessed: Open-Shell's Src/Setup/Setup.cpp accepts /qn|/q|/quiet|/passive and then runs
# msiexec /i "<extracted msi>" with the rest of the command line.
\$ErrorActionPreference = 'Continue'
\$s = Get-ChildItem -Path C:\Users\*\Documents\QubesIncoming -Recurse -Filter '$base' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
if (-not \$s) { Write-Output 'STAGED=NONE'; exit 1 }
Copy-Item \$s.FullName C:\OpenShellSetup.exe -Force
Write-Output ("STAGED=" + \$s.FullName)
\$p = Start-Process C:\OpenShellSetup.exe -ArgumentList '/qn' -Wait -PassThru
Write-Output ("INSTALL_EXIT=" + \$p.ExitCode)
PS1
say "installing silently (/qn) via a pushed script"
timeout 900 tools/qtest pushrun "$OUT/openshell-install.ps1" > "$OUT/install.txt" 2>&1
command grep -a '^STAGED=' "$OUT/install.txt" || true
command grep -a '^INSTALL_EXIT=' "$OUT/install.txt" \
  || { echo "FAIL  the installer reported no INSTALL_EXIT line"; tail -5 "$OUT/install.txt"; exit 2; }

# VERIFY BY EFFECT, never by the installer's own word.
probe_openshell > "$OUT/probe-after.txt" 2>&1
probe_says_present "$OUT/probe-after.txt" \
  || { echo "FAIL  Open-Shell is still not present after the install"; cat "$OUT/probe-after.txt"; exit 2; }
say "verified by effect: $(command grep -a -m1 '^EXE_PATH=' "$OUT/probe-after.txt")"
say "built; env-assert.sh must now pass on its own"
exit 0
