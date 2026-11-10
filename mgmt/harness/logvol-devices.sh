#!/bin/bash
# logvol-devices.sh - THE single entry point that puts a log-volume device phase on a guest.
#
#   mgmt/harness/logvol-devices.sh --vm <vm> --phase priming|graded|answer|none [--image <img>]
#
# Owner 2026-11-10: «no free form arguments anymore. single script with uniform arguments and sanity
# checks that confirm the device is correct and accessible.»
#
# WHAT WAS WRONG. Nine call sites each hand-picked a phase WORD and called logvol_devices_apply
# directly; the only validation anywhere was that the word was one of four. Nothing tied the word to
# the boot it would govern, nothing proved a backend existed for qemu to open, and nothing read the
# value back. tools/smoke/logvol-smoke.sh:141 picks `graded` and passes; mgmt/harness/prime-run.sh:327
# provisions with `priming` and the clean cell binds several reboots later with `priming` STILL in
# force - so a green pre-matrix smoke could not cover the cell it preceded, and cell one of eight
# failed with the log stick absent from the guest's own disk inventory and seven cells ungraded.
#
# EVERY argument is named and enumerated; there are no positional arguments and no ambient globals.
# Every check refuses IMMEDIATELY and names the link it broke:
#   1  --phase is one of the four declared phases, exactly
#   2  --image is required by, and accepted only by, the phases whose string names the log stick
#   3  the image file exists and is not empty
#   4  the image is on a loop device and that device node exists
#   5  the volume is ACCESSIBLE - mtools reads its filesystem host-side, no guest and no root
#   6  the volume is CORRECT - that same read gets the LOGVOL.TAG logvol_create writes
#   7  the guest holds a --required claim for that loop at the frontend the device string names
#   8  the domain is Halted: qemu-extra-args is read at DOMAIN CREATION and nowhere else
#   9  the value read back after the write is BYTE-IDENTICAL to the declaration for that phase
#
# Nothing here repairs anything. A repair is precisely what the order above rules out: a missing
# backend is reported and refused, never created on the way past.
#
# Exit: 0 applied and read back identical; 2 usage; 4 a sanity check refused (named); 1 the write
# itself failed.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM=""; PHASE=""; IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vm)    VM="${2:-}";    shift 2 || exit 2 ;;
    --phase) PHASE="${2:-}"; shift 2 || exit 2 ;;
    --image) IMAGE="${2:-}"; shift 2 || exit 2 ;;
    *) echo "[ERROR] unknown argument '$1' - the only arguments are --vm, --phase, --image" >&2; exit 2 ;;
  esac
done

say(){ echo "[$(date -u +%H:%M:%S)] logvol-devices[${VM:-?}/${PHASE:-?}]: $*"; }
refuse(){ say "[ERROR] REFUSED ($1): $2"; exit 4; }

[ -n "$VM" ]    || { echo "usage: $0 --vm <vm> --phase priming|graded|answer|none [--image <img>]" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "usage: $0 --vm <vm> --phase priming|graded|answer|none [--image <img>]" >&2; exit 2; }

# 1 -------------------------------------------------------------------------------- the phase itself
case "$PHASE" in
  priming|graded|answer|none) ;;
  *) refuse phase "'$PHASE' is not a declared phase - the set is priming|graded|answer|none and it is closed" ;;
esac

# shellcheck disable=SC1091
source mgmt/harness/logvol-lib.sh

# 2 ------------------------------------------------------------- --image, required by exactly these
case "$PHASE" in
  priming|graded)
    [ -n "$IMAGE" ] || refuse image "phase '$PHASE' names the log stick, so --image is required - nothing else identifies the volume whose loop backs /dev/$LOGVOL_FRONTEND" ;;
  answer|none)
    [ -z "$IMAGE" ] || refuse image "phase '$PHASE' does not name the log stick, so --image must not be given (got '$IMAGE') - an argument that changes nothing is how the wrong phase goes unnoticed" ;;
esac

if [ -n "$IMAGE" ]; then
  # 3 ------------------------------------------------------------------------------------- the file
  [ -s "$IMAGE" ] || refuse file "$IMAGE does not exist or is empty"

  # 4 ------------------------------------------------------------------------------------- the loop
  DEV=$(logvol_loop_of "$IMAGE")
  [ -n "$DEV" ] && [ -e "/dev/$DEV" ] \
    || refuse loop "$IMAGE is on NO loop device - the device string names file=/dev/$LOGVOL_FRONTEND and qemu would be asked at domain creation to open a backend that does not exist"
  say "  loop        /dev/$DEV backs $IMAGE"

  # 5+6 ------------------------------------- ACCESSIBLE and CORRECT, in the one read available here.
  # NOT a read off /dev/$DEV: the loop nodes are root-owned and this qube creates them through
  # udisksctl without gaining read access to the node - measured, the probe refused the HEALTHY case
  # (loop3 backing a sound win11-acc volume) exactly as it refused the broken ones, which is a check
  # that cannot discriminate. The read that works here is the one the failure collector already
  # relies on: mtools against the IMAGE, no guest and no root.
  # KEYED TO THE SIGNAL THE CONSUMER READS. The guest resolves this stick BY FAT LABEL at write time
  # (`vol %d: | findstr /i "DIAG"`) and stores nothing, so the property is "mtools can read a FAT
  # whose label is $LOGVOL_LABEL". LOGVOL.TAG is narrower - only volumes logvol_create made carry one
  # - and mgmt/reprovision-usb.sh legitimately attaches its own completion-marker volume at this same
  # frontend, so requiring the tag would refuse a site that is not ours to refuse.
  LABEL=$(minfo -i "$IMAGE" 2>/dev/null | sed -n 's/^disk label="\(.*\)"$/\1/p' | sed 's/ *$//')
  [ -n "$LABEL" ] \
    || refuse volume "$IMAGE is not readable as a FAT volume from this qube (mtools: $(minfo -i "$IMAGE" 2>&1 | head -1)) - Windows mounts a superfloppy only when there is a filesystem at sector 0, so the guest's 'vol | findstr /i $LOGVOL_LABEL' scan would find nothing"
  [ "$LABEL" = "$LOGVOL_LABEL" ] \
    || refuse volume "$IMAGE is labelled '$LABEL', not '$LOGVOL_LABEL' - the guest resolves this stick by label and would take a different volume, or none"
  CID=$(mcopy -i "$IMAGE" ::/LOGVOL.TAG - 2>/dev/null | sed -n 's/^id=//p' | head -1)
  say "  volume      readable, label $LABEL${CID:+, LOGVOL.TAG id=$CID}"

  # 7 ------------------------------------------------- the claim, at the frontend the string names.
  # `qvm-device block list` is POLICY-REFUSED from this qube (mgmt/CLAUDE.md); this read is the
  # documented alternative and, unlike re-issuing `assign`, it does NOT create the claim.
  FE=$(python3 -c "import sys,qubesadmin; a=qubesadmin.Qubes(); print(next((x.options.get('frontend-dev','') for x in a.domains[sys.argv[1]].devices['block'].get_assigned_devices() if sys.argv[2]+'::' in str(x)), ''))" "$VM" "$DEV" 2>/dev/null)
  [ "$FE" = "$LOGVOL_FRONTEND" ] \
    || refuse claim "$VM holds no --required claim for $LOGVOL_HOLDER:$DEV at frontend $LOGVOL_FRONTEND (read back: '${FE:-none}') - the device string would name a frontend the domain never gets"
  say "  claim       $LOGVOL_HOLDER:$DEV at $FE"
fi

# 8 ------------------------------------------------------------------------- the domain MUST be down
ST=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tr -d '\n')
[ -n "$ST" ] || refuse domain "cannot read the power state of $VM"
[ "$ST" = Halted ] \
  || refuse domain "$VM is $ST - qemu-extra-args is read at DOMAIN CREATION and nowhere else, so writing it now would change nothing this guest can see while telling every later reader it had changed (campaign 40134888669 aborted on exactly that)"
say "  domain      Halted"

# ---------------------------------------------------------------------------------------- the write
WANT=$(logvol_devices_for "$PHASE") || refuse phase "the declaration for '$PHASE' could not be composed"
logvol_devices_apply "$VM" "$PHASE" "$IMAGE" || { say "[ERROR] the write failed for phase '$PHASE'"; exit 1; }

# 9 ----------------------------------------------------------------- read it back, byte for byte
GOT=$(qvm-features "$VM" qemu-extra-args 2>/dev/null || true)
if [ -z "$WANT" ]; then
  [ -z "$GOT" ] || refuse readback "phase 'none' was applied but qemu-extra-args still reads '$GOT'"
else
  [ "$GOT" = "$WANT" ] \
    || refuse readback "the value on $VM is NOT the declaration for '$PHASE'
    declared: $WANT
    read back: $GOT"
fi
say "  readback    byte-identical to the declaration for '$PHASE'"
say "APPLIED phase '$PHASE' to $VM"
