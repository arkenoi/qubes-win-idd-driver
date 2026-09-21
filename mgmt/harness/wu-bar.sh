#!/bin/bash
# wu-bar.sh - install a package on a guest, PROVE the artefact is really there, then run the
# update bar on it.
#
#   mgmt/harness/wu-bar.sh <vm> <out-dir> [package-dir]      (or PKG=... in the environment)
#   ROUNDS=<n> repeats the pass; one round proves the mechanism, repeats prove it is not a one-shot
#
# THE BAR: dom0 is settled by the pass AND unchanged by the NON-DEBOUNCED scan that follows it.
# A pass that clears dom0 and a scan that puts it straight back is not a pass - that is exactly
# how the 2026-09-20 run looked green at the pass level while dom0 oscillated 30 s later.
#
# Every guard here was paid for on 2026-09-20:
#  * IDEMPOTENT - if the installed script already matches the package byte for byte, pushing 31 MB
#    and reinstalling proves nothing.
#  * WAIT FOR THE BYTES, NOT FOR A MARKER. The first version waited for a GUARD marker the
#    PREVIOUS build also contains, so it broke at the first poll - 30 s into an installer that
#    needs minutes - and then failed the run for an install that had not happened yet. A wait whose
#    exit condition the OLD artefact already satisfies is not a wait.
#  * REFUSE TO GRADE unless the installed file matches the package. qvm-copy-to-vm silently refuses
#    to overwrite, install.cmd can be truncated when it restarts the agent, and a sealed golden can
#    simply predate the fix - all three happened, and all three printed success.
#  * NEVER read $? after a command substitution: it is the SUBSTITUTION's status. That printed
#    "exit=0" for a leg which had just refused to grade.
#  * TAKE THE LOCK HERE. The install phase drives the guest before wu-e2e.sh ever runs, so a
#    harness that leaves locking to its callee is unlocked for the whole install (caught by
#    tools/lint-harness.py L2 the moment this moved out of scratchpad).
#  * -EncodedCommand, never escaped quotes inside -Command: that is re-split at every hop and
#    FAILS SILENTLY (L3), which on a probe reads as "the file is absent".
set -u
VM="${1:?usage: wu-bar.sh <vm> <out-dir> [package-dir]}"; OUT="${2:?out-dir}"
cd "$(dirname "$0")/../.." || exit 2
PKG="${3:-${PKG:?package dir: pass it as $3 or in PKG}}"
PKGBYTES=$(wc -c < "$PKG/qubes-windows-update.ps1") || exit 2
export QTEST_VM=$VM

source mgmt/harness/vmlock.sh
source mgmt/harness/shutdown-lib.sh
vm_lock "$VM" || { echo "wu-bar: another job holds $VM - refusing to interleave"; exit 1; }

log(){ echo "$(date -u +%H:%M:%S) bar[$VM]: $*"; }
qstate(){ qvm-ls --raw-data --fields state "$VM" 2>/dev/null; }
enc(){ printf '%s' "$1" | iconv -f utf-8 -t utf-16le | base64 -w0; }
psrun(){ timeout -k 5 "${2:-150}" tools/qtest run "powershell -NoProfile -NonInteractive -EncodedCommand $(enc "$1")" 2>/dev/null | tr -d '\r'; }

wait_q(){ local d=$(( $(date +%s) + ${1:-900} ))
  while [ "$(date +%s)" -lt "$d" ]; do
    case "$(timeout -k 5 45 tools/qtest run 'cmd /c echo UP' 2>/dev/null | tr -d '\r\n')" in *UP*) return 0;; esac
    [ "$(qstate)" = Halted ] && return 1
    sleep 15
  done; return 2; }

INST_PS='$p = "C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1"
if (Test-Path $p) { $c = Get-Content -Raw $p
  Write-Output ("RESULT bytes=" + $c.Length + " scan=" + ([regex]::Matches($c,"GUARD:scanactioned").Count)) }
else { Write-Output "RESULT absent" }'
inst(){ psrun "$INST_PS" | grep -E '^RESULT' | tail -1; }


[ "$(qstate)" = Halted ] && timeout 300 qvm-start "$VM" >/dev/null 2>&1
wait_q 900 || { log "FAIL: no qrexec"; exit 1; }

# DISCOVER QubesIncoming FROM THE GUEST. Never inherit it: QTEST_INCOMING is commonly exported in
# a shell (and from ~/.bashrc) pointing at C:\Users\user\..., while this guest's account is
# gerd-test. Measured 2026-09-20 on the first run of this file: the pre-push delete then targeted a
# path that does not exist, `rmdir` reported nothing, and qvm-copy-to-vm refused with "a file named
# qwt-improved-setup/msi/installer.msi already exists" - i.e. the delete silently missed and the
# run would have graded the PREVIOUS build if the byte assertion had not stopped it.
INC=$(psrun 'Get-ChildItem C:\Users -Directory -EA SilentlyContinue |
  ForEach-Object { Join-Path $_.FullName "Documents\QubesIncoming\win-idd-mgmt" } |
  Where-Object { Test-Path $_ } | ForEach-Object { "INC " + $_ }' | grep -E '^INC ' | sed 's/^INC //' | tr -d '\r')
case "$(printf '%s' "$INC" | grep -c .)" in
  1) : ;;
  0) # A guest nobody has pushed to yet has NO QubesIncoming at all - the normal state of a fresh
     # clone, not an error. qvm-copy-to-vm creates it, so derive the path from the guest's own user
     # profile and let the push make it. Measured 2026-09-21: this aborted the staged-pending proof
     # on a clone four minutes old.
     INC=$(psrun 'Get-ChildItem C:\Users -Directory -EA SilentlyContinue |
       Where-Object { $_.Name -notin @("Default","Default User","Public","All Users") } |
       Where-Object { Test-Path (Join-Path $_.FullName "Documents") } |
       ForEach-Object { "INC " + (Join-Path $_.FullName "Documents\QubesIncoming\win-idd-mgmt") }' \
       | grep -E '^INC ' | sed 's/^INC //' | tr -d '\r')
     case "$(printf '%s' "$INC" | grep -c .)" in
       1) log "no QubesIncoming yet (fresh guest) - the push will create it" ;;
       0) log "FAIL: $VM has no usable user profile to push into"; exit 1;;
       *) log "FAIL: more than one user profile, refusing to guess:"; printf '%s\n' "$INC" | sed 's/^/      /'; exit 1;;
     esac ;;
  *) log "FAIL: more than one QubesIncoming candidate, refusing to guess:"; printf '%s\n' "$INC" | sed 's/^/      /'; exit 1;;
esac
export QTEST_INCOMING="$INC"
TREE="$INC\qwt-improved-setup"
log "QubesIncoming on this guest: $INC"

PUSHED_PS="\$f = \"$TREE\\qubes-windows-update.ps1\"
if (Test-Path \$f) { Write-Output (\"PUSHED \" + (Get-Content -Raw \$f).Length) } else { Write-Output \"PUSHED absent\" }"
log "installed BEFORE: $(inst)   package is $PKGBYTES bytes"

if inst | grep -q "bytes=$PKGBYTES"; then
  log "installed script already matches the package ($PKGBYTES bytes) - skipping push+install"
else
  timeout 200 tools/qtest run "cmd /c rmdir /s /q \"$TREE\"" >/dev/null 2>&1
  # ASSERT the delete took. qvm-copy-to-vm silently refuses to overwrite, so a delete that missed
  # means the installer runs the PREVIOUS tree and still prints INSTALL COMPLETE (ADR section 9).
  case "$(timeout 120 tools/qtest run "cmd /c if exist \"$TREE\" (echo STILL_PRESENT) else (echo GONE)" 2>/dev/null | tr -d '\r' | grep -oE 'STILL_PRESENT|GONE' | tail -1)" in
    GONE) : ;;
    *) log "FAIL: could not remove the previous tree at $TREE - refusing to push over it"; exit 1;;
  esac
  timeout 900 qvm-copy-to-vm "$VM" "$PKG" 2>&1 | tail -1
  pushed=$(psrun "$PUSHED_PS" | grep -E '^PUSHED' | tail -1)
  log "$pushed"
  case "$pushed" in *"$PKGBYTES"*) : ;; *) log "FAIL: push mismatch - refusing to grade"; exit 1;; esac
  # Detached, as SYSTEM: install.cmd restarts the gui-agent and would otherwise kill its own
  # qrexec parent half way through, leaving a TRUNCATED install that still reports success.
  timeout 200 tools/qtest run "cmd /c schtasks /create /tn QwtBar /tr \"cmd /c \\\"$TREE\\install.cmd\\\" /auto > C:\\bar.log 2>&1\" /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f && schtasks /run /tn QwtBar" >/dev/null 2>&1
  req=0; did=0
  for i in $(seq 1 60); do
    sleep 30
    st=$(qstate)
    # install.cmd /auto powers the guest off between stages - that is the GUEST asking, and it is
    # counted, not suppressed (ADR section 8: performed must equal requested).
    if [ "$st" = Halted ]; then
      req=$((req+1)); log "guest powered ITSELF off (#$req)"
      timeout 300 qvm-start "$VM" >/dev/null 2>&1; wait_q 900 && did=$((did+1))
    fi
    r=$(inst); log "t+$((i*30))s state=$st $r"
    case "$r" in *"bytes=$PKGBYTES"*) log "INSTALLED: bytes match the package"; break;; esac
  done
  log "install ledger: requested=$req performed=$did"
fi

case "$(inst)" in *"bytes=$PKGBYTES"*) : ;; *) log "FAIL: installed bytes != package bytes - refusing to grade"; exit 1;; esac
log "=== THE BAR: dom0 settled by the pass AND unchanged by the following scan ==="
# ROUNDS: one pass proves the mechanism, repeated passes prove it is not a one-shot. The goal
# record requires repeated stall-free cycles, so this is a knob, not a constant.
exec bash mgmt/harness/wu-e2e.sh "$VM" "${ROUNDS:-1}" "$OUT"
