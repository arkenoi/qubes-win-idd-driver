#!/bin/bash
# vchan-collapse-cell.sh - demonstrate the ONE-LINE vchan failure report on a guest.
#
#   mgmt/harness/vchan-collapse-cell.sh <release-package-run-id> <subject>
#
# WHY THIS IS A TRACKED CELL. It is what caught three defects in the collapse that five Jev rounds
# and an offline renderer passed (findings/issues.md QGAVCHANFAIL): the records' own trailing
# newlines made the "one line" four physical lines, the 16-slot hold dropped the diagnostic tail,
# and the shape test matched DEBUG records so the line contradicted its own evidence. A cell that
# finds that belongs in the tree, not in a gitignored scratch directory.
#   HYPOTHESIS a failed vchan client connect now writes ONE QGAVCHANFAIL E line, not four.
#   BASELINE   the old build wrote four E lines + one W - measured on win10-acc (uptime 21 s) and
#              win11-acc; both captures are in scratchpad/sweep-*/logs.
#   VARIABLE   the binary only: core-agent dabaeed, delivered the sanctioned way (release package).
#   INSTRUMENT the guest's own qrexec-wrapper log for the boot: count E lines, grep QGAVCHANFAIL,
#              and assert the running binary's version first. Missing data FAILS.
#   BUDGET     package wait <=40 min; quick-upgrade <=35 min; induction 3 min; terminal exits named.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
RUN="${1:?usage: $0 <release-package-run-id>}"
VM="${2:?usage: $0 <release-package-run-id> <subject> - name the subject; there is no default target}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

t0=$SECONDS
while [ $((SECONDS-t0)) -lt 2400 ]; do
  st=$(gh run view "$RUN" --json status,conclusion -q '"\(.status)/\(.conclusion // "-")"' 2>/dev/null)
  case "$st" in
    completed/success) say "package $RUN green"; break ;;
    completed/*)       say "TERMINAL: package $RUN ended $st"; exit 4 ;;
  esac
  sleep 60
done
[ "${st:-}" = "completed/success" ] || { say "EXIT=deadline waiting for the package ($st)"; exit 4; }

DL=/home/user/qwt-accept/pkg-$RUN   # the RUN identifies the package; HEAD moves while this runs
mkdir -p "$DL" || exit 2
SETUP="$DL/qwt-improved-setup"
[ -s "$SETUP/install.cmd" ] || { rm -rf "$SETUP"; gh run download "$RUN" -n qwt-improved-setup -D "$SETUP" >/dev/null 2>&1 \
  || { say "FAIL could not download the setup tree"; exit 2; }; }
# PROVENANCE: the tree must carry the collapse, or the cell would measure the old binary.
# The marker lives in a L"..." literal, so in the PE it is UTF-16LE - an ASCII grep reports 0 on a
# perfectly good binary (measured 2026-10-09, and it failed this cell once).
python3 - "$SETUP/bin/qrexec-wrapper.exe" <<'PY' || { say "FAIL the packaged qrexec-wrapper.exe does not carry the collapse - wrong build"; exit 2; }
import sys
b=open(sys.argv[1],'rb').read()
n=b.count('QGAVCHANFAIL'.encode('utf-16-le'))+b.count(b'QGAVCHANFAIL')
print(f"  provenance: QGAVCHANFAIL present {n} time(s)")
sys.exit(0 if n else 1)
PY

say "--- quick-upgrade onto $VM (an INSTALL, which is when a departed peer happens)"
QU_OUT="$DL/qu" timeout 2400 mgmt/harness/quick-upgrade.sh "$SETUP" "$VM" "${VM%%-*}" > "$DL/qu.out" 2>&1; qrc=$?
say "quick-upgrade rc=$qrc"
command grep -aqE 'PASS  installed gui-agent.exe == package reference' "$DL/qu.out" \
  || { say "FAIL the upgrade did not verify - no verdict on the collapse"; tail -5 "$DL/qu.out"; exit 3; }

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh
say "--- induce a departed peer: the caller must depart BEFORE the guest starts the wrapper, which
say     is the early-boot window - a queued request whose client is already gone. 60 short calls."
qwt_shutdown "$VM" 600 >/dev/null 2>&1
timeout 300 qvm-start "$VM" >/dev/null 2>&1
for i in $(seq 1 60); do
  QTEST_VM=$VM timeout 1 tools/qtest run 'cmd /c ping -n 10 127.0.0.1' >/dev/null 2>&1 || true
done
up=0
for i in $(seq 1 30); do
  if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then up=1; break; fi
  sleep 10
done
[ "$up" = 1 ] || { say "FAIL qrexec never answered after the induction boot"; exit 4; }
say "qrexec up; reading the guest's own wrapper log"
cat > "$DL/probe.ps1" <<'PS1'
# Read EVERY wrapper log, never "the newest by LastWriteTime" - file metadata is not a usable
# anchor on this rig (the clock flips ~3 h about 60 s into every boot and NTFS updates mtime
# lazily for an open handle). The decisive facts are in the CONTENT: QGAVCHANFAIL can only come
# from the new binary, and the four-line pattern can only come from the old one.
$d='Q:\Qubes Logs'
$fs=@(Get-ChildItem -LiteralPath $d -Filter 'qrexec-wrapper*.log' -EA SilentlyContinue)
Write-Output ("PROOF-FILES=" + $fs.Count)
$tc=0; $to=0; $te=0
foreach ($f in $fs) {
  $L=@(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue)
  $c=@($L | Where-Object { $_ -match 'QGAVCHANFAIL' }).Count
  $o=@($L | Where-Object { $_ -match '-E\]' -and $_ -match 'libvchan_client_init.*libxenvchan_client_init.*failed' }).Count
  $x=@($L | Where-Object { $_ -match '-E\]' -and $_ -match 'XcStoreRead|libxenvchan_client_init|init_evt_cli|XcEvtchnBind' }).Count
  $e=@($L | Where-Object { $_ -match '-E\]' }).Count
  $u=(($L | Select-String -Pattern 'System uptime: ' | Select-Object -First 1) -replace '.*System uptime: ','')
  $tc+=$c; $to+=$o; $te+=$e
  Write-Output ("PROOF-FILE " + $f.Name + " lines=" + $L.Count + " E=" + $e + " collapsed=" + $c + " oldtail=" + $o + " libnoise=" + $x + " uptime=" + $u)
}
# DEFECT 1 CHECK: each held record used to carry its own trailing newline, so the ONE line was
# written as several physical lines - a continuation has no timestamp and starts with '|'.
$cont=0; $inc=0
foreach ($f in $fs) {
  $L=@(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue)
  $cont += @($L | Where-Object { $_ -match '^\s*\|' }).Count
  $inc  += @($L | Where-Object { $_ -match 'report is INCOMPLETE' }).Count
}
Write-Output ("PROOF-TOTAL collapsed=" + $tc + " oldtail=" + $to + " E=" + $te + " continuations=" + $cont + " incomplete=" + $inc)
foreach ($f in $fs) {
  foreach ($l in @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -match 'QGAVCHANFAIL' })) {
    Write-Output ("PROOF-LINE " + $l) }
}
PS1
QTEST_VM=$VM timeout 300 tools/qtest pushrun "$DL/probe.ps1" > "$DL/proof.txt" 2>&1
command grep -aE '^PROOF-' "$DL/proof.txt" | cut -c1-400
printf '%s\n' "$SETUP" > scratchpad/last-setup.txt   # named for the cell that grades next

# AND THEN SWEEP A CLEAN BOOT (lint L19: a run that does not read the guest's error log cannot
# report on it, and a clean error log is the gate condition). The induction above deliberately
# creates failures, so the sweep needs its own boot with the logs archived first - which is exactly
# what clean-boot-sweep.sh does, reading the installed tree from the file just written.
say "--- clean boot + sweep, so this cell reports on the error log it leaves behind"
bash mgmt/harness/clean-boot-sweep.sh "$VM" "scratchpad/sweep-$VM-after-collapse-cell"; srv=$?
say "clean-boot-sweep rc=$srv"
say "evidence: $DL/proof.txt  (installed tree recorded in scratchpad/last-setup.txt)"
