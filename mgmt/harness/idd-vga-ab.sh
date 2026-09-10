#!/bin/bash
# DOES THE IDD's VGA-DISABLE TRIGGER THE XEN DIRTY-VRAM WEDGE?
#
# THE HYPOTHESIS, and it is testable rather than plausible. A live wedge captured 2026-09-10
# (wedge-regs.txt) showed Xen 4.19.4 spinning in the hypervisor with this stack:
#     flush_area_mask <- map_pages_to_xen <- virt_to_xen_l3e <- vunmap <- vfree
#                     <- hap_track_dirty_vram <- dm_op
# flush_area_mask is the TLB-shootdown broadcast that spins until every IPI'd CPU acknowledges;
# dm_op is a hypercall FROM THE DEVICE MODEL, so the wedged vCPU is QEMU's stubdomain. Critically
# the stack is in a FREE path (vfree/vunmap) - the device model TEARING DOWN its dirty-VRAM
# tracking, which is what disabling the display adapter causes. Install-QwtImproved activates the
# IDD - and disables the emulated VGA (PCI\VEN_1234&DEV_1111 -> code 22) - "right before the stage-2
# reboot", which is exactly when the stall happens.
#
# THE TEST. Two prime jobs identical but for one installer flag:
#     ours        - default, activates the IDD and disables the emulated VGA
#     ours-noidd  - /noidd, leaves the BDA alone and never triggers the teardown
# Interleaved, not blocked, so anything drifting on the rig over an hour cannot be mistaken for the
# effect. If the stall appears only in the IDD arm, the causal link is established and the fix is the
# already-open "IDD VGA-disable deferral" - disable on the NEXT boot, not in the same breath as the
# reboot. If BOTH arms stall, the VGA-disable is exonerated and the trigger is elsewhere.
#
# NOTHING IS EVER KILLED. A stalled guest is left exactly as it stands and the run STOPS: a killed
# guest is contaminated evidence, and that mistake already cost two specimens.
#
# Usage:  N=4 W=<acceptance work dir with dl/> SUBJ=win10-abt mgmt/harness/idd-vga-ab.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

N="${N:-4}"
W="${W:?set W to the acceptance work dir holding dl/}"
SUBJ="${SUBJ:-win10-abt}"
BASE="${BASE:-win10-base}"
SETUP="$W/dl/qwt-improved-setup"
OUT="${OUT:-/home/user/rel/idd-vga-ab-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

say "=== IDD VGA-disable A/B: $N rounds x (ours | ours-noidd), subject $SUBJ ==="
idd=0; noidd=0
for r in $(seq 1 "$N"); do
  for job in ours ours-noidd; do
    for vm in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}'); do
      qvm-shutdown --wait --timeout 300 "$vm" >/dev/null 2>&1
      st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$vm" '$1==v{print $2}')
      [ "$st" = Halted ] || { say "STOP: $vm is $st and will not halt - NOT killing it, that is the evidence"; exit 2; }
    done
    L="$OUT/r$r-$job.log"
    say "--- round $r, job $job"
    ./mgmt/harness/prime-run.sh "$BASE" "$SUBJ" "$job" --payload "$SETUP" >"$L" 2>&1
    rc=$?
    stalled=$(grep -ac 'did not return within\|DEADLINE' "$L")
    say "  round $r $job: rc=$rc stalled=$stalled"
    if [ "$stalled" -gt 0 ] || [ "$rc" = 2 ]; then
      [ "$job" = ours ] && idd=$((idd+1)) || noidd=$((noidd+1))
      say "STALL in the '$job' arm - stopping with the guest UNTOUCHED (pristine for forensics)."
      say "  tally so far: IDD-arm=$idd  noidd-arm=$noidd"
      say "  capture it with: sudo ./11-wedge-forensics.sh $SUBJ   (dom0, before anything else)"
      exit 1
    fi
  done
done
say "=== $N rounds each, no stalls: IDD-arm=$idd noidd-arm=$noidd ==="
