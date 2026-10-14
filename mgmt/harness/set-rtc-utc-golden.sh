#!/bin/bash
# set-rtc-utc-golden.sh - set RealTimeIsUniversal=1 in ONE sealed golden, in place, and re-seal.
#
#   mgmt/harness/set-rtc-utc-golden.sh <golden>
#
# WHY IN PLACE RATHER THAN A REBUILD. The images on this rig differ from what we want by exactly
# one registry DWORD: Windows with RealTimeIsUniversal unset reads the hardware clock as LOCAL
# time, so a guest computes its UTC off by its own zone offset - measured 2026-10-14 as a permanent
# +3 h on every acceptance cell (CLOCKRTCLOCALTIME). The answer file now sets it, which fixes images
# we INSTALL; this fixes the images we already have. Reinstalling Windows to change one value costs
# ~45 minutes per image and risks leaving the rig with no base if an install fails - the owner's
# call, and the right one: "we just need to adjust single registry entry on images and re-seal".
#
# WHAT THIS SPENDS. Booting a sealed golden consumes a revision, and revisions_to_keep is 2, so the
# recovery window is two shutdowns wide. That is why this starts the guest ONCE, changes one value,
# and shuts down - and why it refuses to run at all if anything else is up.
#
# EVERY STEP IS PROVEN, NOT ASSUMED: the value is read back from the guest, the seal is re-verified
# afterwards, and any failure stops the script rather than leaving a golden unsealed or half-done.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${1:-}"
[ -n "$VM" ] || { echo "usage: $0 <golden>" >&2; exit 2; }

say(){ echo "[$(date -u +%H:%M:%S)] rtc-golden[$VM]: $*"; }
die(){ say "[ERROR] $*"; exit 1; }

[ -f "mgmt/goldens/$VM.json" ] || die "no seal at mgmt/goldens/$VM.json - this is not a sealed golden"

# SERIAL, like every VM-mutating job here: two guests up at once interleave their probes and
# fabricate verdicts. The first version of this listed every Running qube and refused on dom0 and
# the management qube, which are always up - which is why the sanctioned helper exists.
# shellcheck disable=SC1091
source mgmt/harness/serial-rig.sh
assert_sole_guest "$VM" || die "another guest is up - run this serially"

st=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
[ "$st" = Halted ] || die "$VM is '$st', not Halted"

# The seal must be intact BEFORE we touch it: re-sealing over an already-drifted golden would
# record our change and silently bless whatever else had happened to it.
./mgmt/golden.sh verify "$VM" >/dev/null 2>&1 || die "$VM does not match its seal - fix that first, do not re-seal over it"
say "seal verified before the change"

say "starting (authorised with GOLDEN_UNSEAL - a golden is normally CLONED, never STARTED)"
GOLDEN_UNSEAL="$VM" qvm-start "$VM" >/dev/null 2>&1 || die "could not start $VM"

# shellcheck disable=SC1091
source mgmt/harness/shutdown-lib.sh
# shellcheck disable=SC1091
source mgmt/harness/e2e-wait.sh
ok=0
for _ in $(seq 1 60); do
    if w_alive "$VM"; then ok=1; break; fi
    sleep 10
done
[ "$ok" = 1 ] || { qwt_shutdown "$VM" 600 >/dev/null 2>&1; die "qrexec never answered - nothing changed, guest shut down"; }
say "qrexec answers"

# w_rtc_utc sets the value AND reads it back; a write that cannot be confirmed is a failure here,
# because the whole point of this run is that the image carries it.
w_rtc_utc "$VM" say || { qwt_shutdown "$VM" 600 >/dev/null 2>&1; die "could not set RealTimeIsUniversal - nothing re-sealed"; }

say "shutting down cleanly (qwt_shutdown: --wait KILLS at its timeout, and a killed golden is a contaminated one)"
qwt_shutdown "$VM" 900
st=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
[ "$st" = Halted ] || die "$VM is '$st' after shutdown - not re-sealing a guest that is not down"

# THE RE-SEAL IS A RECORDED ACT. The reason is written into the seal so a later reader knows this
# golden was changed deliberately and what for - the rule exists because a re-seal that abandons a
# state nobody can reach again is how win10-base was lost on 2026-10-11.
GOLDEN_RESEAL_REASON="RealTimeIsUniversal=1 set in place 2026-10-14 (CLOCKRTCLOCALTIME): the hardware clock is UTC and the OS applies the zone. One registry value, no reinstall." \
  ./mgmt/golden.sh seal "$VM" "RealTimeIsUniversal=1; hardware clock is UTC" || die "re-seal failed - this golden is now MODIFIED and UNSEALED, fix before use"
say "re-sealed"

./mgmt/golden.sh verify "$VM" || die "the new seal does not verify"
say "DONE: $VM carries RealTimeIsUniversal=1 and verifies against its new seal"
