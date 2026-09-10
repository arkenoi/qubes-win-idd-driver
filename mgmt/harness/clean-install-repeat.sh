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

  # ARM CLASS B RESOLUTION ON THE BOOT THAT WILL WEDGE. Specimen 3 (2026-09-10) is the best
  # characterised wedge this project has caught - a byte-frozen vCPU2 at pause_flags=4 beside a
  # vCPU0 spinning a full core in an identified 2-byte pause loop - and its spinning function STILL
  # cannot be named, because a guest RIP is meaningless without THAT boot's module bases and nothing
  # was recording them. The gap was in THIS script: the arming existed only in the newer reproducers,
  # so the specimen this hunt's own round 2 caught is unresolvable.
  #
  # WHY ARMING ONCE IS ENOUGH, given KASLR re-randomises every boot: arm-module-bases.sh installs an
  # ONSTART TASK, so arming on the install's FIRST boot records bases on every LATER boot of that
  # install - including the stage-2 boot where the wedge lands (~2 min after a domain start; the
  # stubdom log dates specimen 3's onset to 15:48:13Z against a 15:46:08Z start).
  #
  # LIVENESS IS PROBED WITH qrexec-client-vm, NOT tools/qtest, deliberately: all guest-driving stays
  # inside arm-module-bases.sh, which takes the per-VM lock itself. Nothing in this hunt's chain
  # acquires that lock - matrix.sh and prime-run.sh never call vm_lock, and run-lib only ever calls
  # vm_unlock, which is a no-op in a process that did not acquire - so the child locks cleanly.
  # Detached, so it never blocks the round; matrix.sh owns the guest and this only watches for it.
  # A failure to arm is LOUD but not fatal: the round still measures the stall rate.
  if [ "${ARM_MODBASES:-1}" = 1 ]; then
    ( for i in $(seq 1 120); do
        v=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null \
            | awk -F'|' '$1 ~ /^win1[01]-/ && $2!="Halted"{print $1; exit}')
        if [ -n "$v" ] && printf 'cmd /c echo UP\n' \
             | timeout -k 5 30 qrexec-client-vm "$v" qubes.VMShell 2>/dev/null | grep -qa UP; then
          VM=$v OUT="$OUT/modbases-r$r" ./mgmt/harness/arm-module-bases.sh \
            && echo "ARMED $v" || echo "ARM FAILED on $v"
          exit 0
        fi
        sleep 5
      done
      echo "no guest answered qrexec within 10 min - NOT armed" ) >"$OUT/armwatch-r$r.log" 2>&1 &
    say "  module-base arming watcher started - a wedge this round should be RESOLVABLE"
  fi
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

  say "    arming: $(tail -1 "$OUT/armwatch-r$r.log" 2>/dev/null)"

  if [ "$stalled" -gt 0 ]; then
    stalls=$((stalls+1))
    say "STALL REPRODUCED on round $r - stopping with the guest UNTOUCHED so the disk is pristine."
    say "  evidence: $L and the guest as it stands (do not kill it)"
    say "  CAPTURE IT NOW in dom0, read-only. This is the sequence that gave specimen 3 a complete"
    say "  picture; note the QUBES stubdom log path - /var/log/xen/qemu-dm-*.log is bare-Xen and"
    say "  returns 0 bytes here. Substitute the wedged guest for VM:"
    say "    mkdir -p ~/w && cd ~/w; date -u +%FT%T.%NZ | tee -a times.txt"
    say "    sudo xl dmesg -c >/dev/null; sudo xl debug-keys q; sudo xl dmesg > q1.txt  # pause_flags: 4=blocked"
    say "    sudo xl dmesg -c >/dev/null; sudo xl debug-keys v; sudo xl dmesg > v1.txt  # exit reason + guest RIP"
    say "    sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > d1.txt"
    say "    sleep 30; date -u +%FT%T.%NZ | tee -a times.txt"
    say "    sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > d2.txt"
    say "    sudo xl vcpu-list VM > vcpu.txt; sleep 600; sudo xl vcpu-list VM > vcpu2.txt   # a FROZEN counter proves the block"
    say "    sudo tail -300 /var/log/xen/console/guest-VM-dm.log > qemu-dm.txt"
    say "  then, and this is the part no specimen has had yet:"
    say "    VM=<the guest> mgmt/harness/arm-module-bases.sh --dump"
    say "    tools/resolve-guest-rip.py <the dump> <the spinning RIP from v1.txt>"
    exit 1
  fi
done
say "=== $N rounds, $stalls stalls, no guest killed ==="
