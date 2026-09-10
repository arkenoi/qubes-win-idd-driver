#!/bin/bash
# FAST REPRODUCER HUNT: does a plain REBOOT of an already-installed guest wedge it?
#
# WHY THIS SHAPE. Three wedges have now been caught (2026-09-09/10) and they do NOT share an install
# phase - two happened with the install fully complete (RESULT ok:true; "the guest carries a working
# QWT"), one happened two seconds into stage 2 before msiexec even ran. Three specific triggers were
# proposed from single cases and all three failed against the others: the emulated-VGA disable, the
# msiexec/PV-driver install, and a dirty volume. The ONLY factor common to all three is proximity to
# a BOOT OR REBOOT transition.
#
# That is consistent with the captured stack rather than an added assumption: Xen was caught spinning
# in flush_area_mask beneath hap_track_dirty_vram <- dm_op, in the vfree/vunmap TEARDOWN path, and a
# boot/shutdown display transition is exactly when QEMU's VGA dirty-tracking region changes and is
# torn down.
#
# So test the transition ALONE, with no install in the picture. A reboot is ~1 minute against ~7 for
# a clean install, which finally makes a useful sample size affordable: the observed rate is roughly
# 3 in 20 installs, so tens of iterations are needed, not four.
#
# NOTHING IS EVER KILLED. A wedged guest is left exactly as it stands and the loop STOPS, because a
# killed guest is contaminated evidence - that mistake has already cost three specimens, and the one
# time a specimen survived untouched is the only time this project learned anything (the Xen stack).
#
# Usage:  VM=win10-abt N=50 mgmt/harness/reboot-loop-wedge.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to an already-installed, qrexec-answering guest}"
N="${N:-50}"
OUT="${OUT:-/home/user/rel/reboot-loop-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
up(){ QTEST_VM=$VM timeout -k 5 25 ./tools/qtest run 'cmd /c echo UP' 2>/dev/null | tr -d '\r' | grep -qa UP; }
# cputime is what distinguishes a wedge from a slow boot: a spinning domain burns whole cores, a
# booting one does not. Measured on the real wedge: 181% of a core, and 100% per pegged vCPU.
cput(){ printf '' | qrexec-client-vm "$VM" admin.vm.CurrentState 2>/dev/null | tr -d '\000' | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }

# Serialise like every other VM-driving job here: a campaign cell rebooting this subject underneath
# the loop would make every reading meaningless.
source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

# g_boot_id: the reboot must be PROVEN, not inferred. Observing Halted is already strong here, but
# qrexec answering afterwards is not proof the guest is in a NEW boot - that is the async-shutdown
# defect this project has been bitten by twice (a test graded a still-running pre-reboot guest), and
# lint rule L2b exists to stop it recurring.
source mgmt/harness/e2e-wait.sh

say "=== reboot loop on $VM, $N iterations, nothing killed ==="
up || { say "VOID: $VM is not answering qrexec at the start - this needs an installed, working guest"; exit 2; }

for i in $(seq 1 "$N"); do
  # g_reboot_proven does the whole cycle and PROVES it: boot id before, guest OBSERVED Halted, start,
  # qrexec back, boot id CHANGED. Hand-rolling this was duplication, and the lint rule that caught it
  # (L2b) exists because a test here once graded a still-running pre-reboot guest as rebooted.
  if res=$(g_reboot_proven "$VM" "reboot-$i" 2>&1); then
    [ $((i % 5)) -eq 0 ] && say "  $i/$N reboots PROVEN clean (last: $res)"
  else
    # It failed. Distinguish a WEDGE from a slow or merely broken boot by what the domain is DOING:
    # a spinning domain burns whole cores (measured on the real wedge: 181% of a core, 100% per
    # pegged vCPU), a booting or dead one does not.
    a=$(cput); sleep 20; b=$(cput)
    burn="unknown"
    if [ -n "$a" ] && [ -n "$b" ]; then
      burn=$(python3 -c "print(f'{(int(\"$b\")-int(\"$a\"))/1e9/20*100:.0f}% of a core')" 2>/dev/null || echo unknown)
    fi
    say "REBOOT $i FAILED: $res"
    say "  state=$(state)  burning=$burn"
    case "$burn" in
      *"% of a core"*)
        say "  A SPINNING DOMAIN IS THE WEDGE. It is LEFT UNTOUCHED - capture it NOW, before anything"
        say "  else touches it, because every previous specimen was destroyed by being killed:"
        say "    dom0:  sudo ./11-wedge-forensics.sh $VM --nmi"
        say "    dom0:  sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > ~/wedge-regs.txt"
        say "           (the CALL TRACE is the whole point - that is what named flush_area_mask)" ;;
      *) say "  Not spinning, so this is a boot failure of some other kind, not the wedge under test." ;;
    esac
    exit 1
  fi
done
say "=== $N reboots, no wedge. Reboot alone does not reproduce it - the install IS implicated ==="
