#!/bin/bash
# seal-qwt-golden.sh - build/refresh the QWT-installed golden used by quick-upgrade.sh.
# Installs an N-1 release cleanly onto a fresh clone of <os>-base and seals it as <os>-qwt: a
# persistent, Halted clone-source with an OLDER QWT already installed. quick-upgrade then clones it
# and MSI-MajorUpgrades to the package under test.
#
#   seal-qwt-golden.sh <os> <release-setup-dir>
#     <os>                  win10 | win11
#     <release-setup-dir>   an N-1 RELEASE setup tree (install.cmd + MANIFEST.json at root)
#
# Refresh whenever the dev line bumps (the golden must stay strictly below dev's ProductVersion so
# the upgrade is a fast MajorUpgrade, not an uninstall-first). This is a rig op; run it serially.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1
OS="${1:?usage: seal-qwt-golden.sh <win10|win11> <release-setup-dir>}"
REL="${2:?need the N-1 release setup tree}"
BASE="$OS-base"; GOLD="$OS-qwt"
[ -f "$REL/install.cmd" ] || { echo "FATAL: $REL has no install.cmd"; exit 2; }
relver=$(grep -oE '"package_version"[^,]*' "$REL/MANIFEST.json" 2>/dev/null | grep -oE '4\.[0-9.]+' | head -1)
log(){ echo "[$(date +%H:%M:%S)] seal-qwt-golden: $*"; }

# preconditions: base present+Halted, nothing else running
[ "$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$BASE" '$1==v{print $2}')" = Halted ] \
  || { log "FATAL: $BASE is not present+Halted"; exit 1; }
# The golden-to-be is excluded: prime-run kills+recreates its churn (a leftover is discarded).
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v me="$GOLD" '$2!="Halted" && $1!=me && $1 ~ /^(win(10|11)|prime-)/ {print $1}')
[ -z "${running// /}" ] || { log "FATAL: not all Halted: $running"; exit 1; }

# install the release cleanly onto <os>-qwt (prime-run recreates the guest from base)
log "installing release $relver onto $GOLD (clean, from $BASE)"
./mgmt/harness/prime-run.sh "$BASE" "$GOLD" ours --payload "$REL"
rc=$?; [ $rc -eq 0 ] || { log "FATAL: prime-run rc=$rc"; exit 1; }

# turn the churn into a clean clone-SOURCE: drop the answer stick + qemu-extra-args, so booting the
# golden (or cloning it) never drags the one-shot install stick along.
log "sealing $GOLD as a clone source (unassign stick, clear qemu-extra-args)"
# prime-run ASSIGNS the stick (`qvm-device block assign --required`), so the verb that clears it
# is `unassign`, not `detach` - matrix.sh clear_prime_leftovers does exactly this by the loop
# backing answer-usb.img (`block list` is policy-refused here, so the assignment cannot be read).
stickloop=$(losetup -l 2>/dev/null | awk '$6 ~ /answer-usb\.img$/{sub("/dev/","",$1); print $1; exit}')
if [ -n "$stickloop" ]; then
  qvm-device block unassign "$GOLD" "win-idd-mgmt:$stickloop" >/dev/null 2>&1 \
    && log "primer stick unassigned (win-idd-mgmt:$stickloop)" \
    || log "WARNING: could not unassign the primer stick from $GOLD (a --required assignment left on a golden ties it to this qube's loop layout)"
else
  log "WARNING: no loop backing answer-usb.img found - primer stick assignment not cleared for $GOLD"
fi
qvm-device block detach "$GOLD" "win-idd-mgmt:${stickloop:-loop0}" >/dev/null 2>&1 || true   # best-effort
qvm-features --unset "$GOLD" qemu-extra-args 2>/dev/null || true
# make sure it is Halted (prime leaves it running or halted depending on the job)
st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$GOLD" '$1==v{print $2}')
[ "$st" = Halted ] || { qvm-shutdown --wait "$GOLD" >/dev/null 2>&1 || qvm-kill "$GOLD" >/dev/null 2>&1; }

# SEAL it as a proper golden (mgmt/goldens/<vm>.json) - prime-run REQUIRES `golden.sh verify` to
# pass on its base, a fixture record is not enough.
./mgmt/golden.sh seal "$GOLD" "QWT $relver golden for quick-upgrade" || { log "FATAL: golden.sh seal failed"; exit 1; }
# also record the version so quick-upgrade can advise on the ordering
mkdir -p mgmt/fixtures
printf '{"golden":"%s","base":"%s","sealed_version":"%s","sealed_utc":"%s"}\n' \
  "$GOLD" "$BASE" "${relver:-unknown}" "$(date -u +%FT%TZ)" > "mgmt/fixtures/$GOLD.json"
log "SEALED: $GOLD @ $relver (mgmt/fixtures/$GOLD.json). quick-upgrade a >$relver package with:"
log "  mgmt/harness/quick-upgrade.sh <pkg-setup-dir> <subject> $OS"
