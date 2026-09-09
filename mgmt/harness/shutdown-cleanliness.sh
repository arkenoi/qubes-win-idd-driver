#!/bin/bash
# DOES OUR INSTALLER'S POWER-OFF LEAVE THE VOLUME UNCLEAN?
#
# WHY. Install-QwtImproved's inter-stage transition is `shutdown.exe /s /f /t 2`
# (Emit-ResultThenPowerOff), chosen so the domain ALWAYS dies - a Qubes HVM is on_poweroff=destroy,
# so the toolstack tears the domain down the moment the guest signals S5. Owner hypothesis
# 2026-09-09: that may not be as graceful as it reads, and could leave the volume dirty. A dirty
# volume's next boot goes to Startup Repair, where there is no qrexec, no xencons and no mapped
# window - which is indistinguishable from the "guest never came back from its post-install reboot"
# stalls that cost two subjects that day.
#
# THIS DOES NOT NEED A STALL TO HAPPEN. It exercises the shutdown mechanism directly and asks the
# next boot whether it was clean, so the answer does not depend on catching a rare failure.
#
# A CONTAMINATED SUBJECT PROVES NOTHING (owner, same day): a guest that was qvm-kill'ed is dirty
# because of the kill. This never kills the subject - a run that cannot halt the guest cleanly is
# reported as VOID rather than graded.
#
#   poweroff : `shutdown /s /f /t 2` in the guest - EXACTLY what the installer issues
#   acpi     : `qvm-shutdown` from the host - the control, a different route to the same S5
#
# Usage:  VM=win-idd-test ROUNDS=2 mgmt/harness/shutdown-cleanliness.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM}"
ROUNDS="${ROUNDS:-2}"
OUT="${OUT:-/home/user/rel/shutdown-clean-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
psp(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-120}" \
       | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }
state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }

wait_up(){ for i in $(seq 1 50); do gq 'cmd /c echo UP' 25 | grep -qa UP && return 0; sleep 15; done; return 1; }
wait_halt(){ for i in $(seq 1 60); do [ "$(state)" = Halted ] && return 0; sleep 5; done; return 1; }

# The two signals nobody was asking. Kernel-Power 41 is the OS saying it "rebooted without cleanly
# shutting down first"; the NTFS dirty bit is the filesystem's own verdict. Read AFTER the boot that
# follows the shutdown under test, scoped to that shutdown.
probe(){
  psp CLEAN '
$b=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$e=@(Get-WinEvent -FilterHashtable @{LogName="System";Id=41,6008;StartTime=$b.AddMinutes(-20)} -MaxEvents 10 -EA SilentlyContinue)
$ids=($e | ForEach-Object { $_.Id }) -join ","
$d=(& fsutil.exe dirty query $env:SystemDrive 2>&1 | Out-String).Trim()
Write-Host ("CLEAN=boot:" + $b.ToUniversalTime().ToString("o") + "|events:" + $(if($ids){$ids}else{"none"}) + "|" + $d)'
}

say "=== shutdown cleanliness on $VM, $ROUNDS round(s) ==="
wait_up || { say "VOID: $VM never answered qrexec at the start"; exit 2; }

for r in $(seq 1 "$ROUNDS"); do
  for mode in poweroff acpi; do
    before=$(psp BOOT 'Write-Host ("BOOT=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"))')
    [ -n "$before" ] || { say "VOID r$r/$mode: could not read the boot id before"; continue; }

    if [ "$mode" = poweroff ]; then
      # EXACTLY the installer's line. Fire and forget: the guest dies mid-call.
      gq 'cmd /c shutdown.exe /s /f /t 2' 30 >/dev/null 2>&1 || true
    else
      qvm-shutdown "$VM" >/dev/null 2>&1
    fi

    if ! wait_halt; then
      # NEVER kill the subject to hurry this along - a killed guest is dirty BECAUSE of the kill,
      # and grading that would manufacture the very result being tested.
      say "VOID r$r/$mode: guest did not halt within 300s - NOT killing it, this round is ungraded"
      continue
    fi
    qvm-start "$VM" >/dev/null 2>&1
    if ! wait_up; then
      say "r$r/$mode: guest did NOT come back after the shutdown - that is the stall itself"
      say "  leaving it as it stands for inspection; stopping here"
      exit 1
    fi
    after=$(probe)
    say "r$r/$mode: $after"
    case "$after" in
      *events:none*NOT\ Dirty*) say "  -> clean" ;;
      *)                        say "  -> UNCLEAN (this is the hypothesis confirmed for '$mode')" ;;
    esac
  done
done
say "=== done: $OUT ==="
