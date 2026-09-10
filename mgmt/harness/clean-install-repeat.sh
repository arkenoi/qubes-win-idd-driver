#!/bin/bash
# HUNT THE POST-INSTALL-REBOOT STALL, WITH THE SHUTDOWN ASSERTION LIVE AND NOTHING KILLED.
#
# THE OPEN QUESTION. Two subjects were lost on 2026-09-09/10 to "guest never came back from its
# post-install reboot" - once on win10-upgrade, once on win10-clean, the latter after prime-run had
# waited 900 s, so it is NOT the harness race that was fixed the same day. The suspected mechanism
# (owner hypothesis) is an unclean shutdown leaving a volume that the next boot must repair, and
# Startup Repair is exactly where a guest has no qrexec, no xencons and no mapped window. That
# mechanism is UNPROVEN at both ends: the installer's own transition was never shown to leave a
# dirty volume, and a dirty volume was never shown to have caused those two stalls.
#
# WHY EARLIER EVIDENCE WAS WORTHLESS, and the rule this script exists to obey: both wedges were
# qvm-kill'ed during investigation before being parked. A killed guest is dirty BECAUSE of the kill
# (proven by injection: a hard kill mid-write reports Kernel-Power 41,6008), so the Automatic Repair
# screen photographed afterwards said nothing about the original fault. THIS SCRIPT NEVER KILLS.
# A stalled guest is LEFT EXACTLY AS IT IS and the run stops, so the first uncontaminated wedge
# survives for forensics - SrtTrail.txt on that disk records why Startup Repair triggered.
#
# WHAT IS NEW SINCE THOSE STALLS: health-check.ps1 now asserts prev_shutdown_orderly (Kernel-Power
# 41/6008 + the NTFS dirty bit), and it has been SEEN TO FAIL. So a clean install that goes through
# the installer's power-off now REPORTS whether that shutdown was orderly, instead of leaving us to
# infer it from a stall hours later. Every run records that verdict per round.
#
# The stall was roughly 1 in 5. N=10 is the point of this: two clean campaigns proved little.
#
# Usage:  N=10 W=<acceptance work dir with dl/> mgmt/harness/clean-install-repeat.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

N="${N:-10}"
W="${W:?set W to the acceptance work dir holding dl/}"
OS="${OS:-win10}"                    # both stalls were win10
OUT="${OUT:-/home/user/rel/clean-repeat-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

SETUP="$W/dl/qwt-improved-setup"
ISO="$W/dl/qwt-improved-iso/qwt-improved-setup.iso"
VER=$(python3 -c "import json;print(json.load(open('$SETUP/MANIFEST.json'))['package_version'])" 2>/dev/null)
say "=== clean-install repeat: $N rounds of $OS-clean, package $VER ==="
say "    nothing is killed; a stalled guest is left as it stands and the run STOPS"

stalls=0
for r in $(seq 1 "$N"); do
  # Settle WITHOUT killing: a guest that will not halt is itself the condition under test, so stop
  # rather than force it and destroy the evidence.
  for vm in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}'); do
    say "  settling $vm"
    if ! qvm-shutdown --wait --timeout 300 "$vm" >/dev/null 2>&1; then
      st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$vm" '$1==v{print $2}')
      if [ "$st" != Halted ]; then
        say "STOP: $vm is $st and will not halt - NOT killing it. That is the failure state; it is"
        say "      preserved for forensics. Read SrtTrail.txt / the event log from its disk."
        exit 2
      fi
    fi
  done

  L="$OUT/run$r.log"
  say "--- round $r/$N"
  MATRIX_WORK="$W" RELEASE_SETUP="$SETUP" RELEASE_ISO="$ISO" \
    CELLS="$OS-clean" MATRIX_OUT="$OUT/m$r" \
    ./mgmt/harness/matrix.sh >"$L" 2>&1
  rc=$?

  verdict=$(grep -a '=== MATRIX:' "$L" | tail -1)
  # The two signals that decide whether the suspected mechanism is present at all.
  orderly=$(grep -ao '"prev_shutdown_orderly"[^}]*"pass": *[a-z]*' "$L" | grep -o 'true\|false' | head -1)
  stalled=$(grep -ac 'did not return within\|did not answer qrexec' "$L")
  say "  round $r: rc=$rc | ${verdict:-<no footer>}"
  say "    prev_shutdown_orderly=${orderly:-not-reported}  postinstall-stall=$stalled"

  if [ "$stalled" -gt 0 ]; then
    stalls=$((stalls+1))
    say "STALL REPRODUCED on round $r - stopping with the guest UNTOUCHED so the disk is pristine."
    say "  evidence: $L and the guest as it stands (do not kill it)"
    exit 1
  fi
done
say "=== $N rounds, $stalls stalls, no guest killed ==="
