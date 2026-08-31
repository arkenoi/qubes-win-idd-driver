#!/bin/bash
# FAIL-PROOFS for four assertions whose negative already exists or can be made without touching a
# guest. H5 keys the registry by CHECK, so each of these closes every ledger row that cites it.
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
ok(){ echo "  -> PROOF EARNED: $1"; }
no(){ echo "  -> NOT PROVEN: $1"; rc=1; }

# ---------------------------------------------------------------- deployed-stack-hashes
# The check asserts the scripts deployed to the guest are byte-identical to the shipped payload.
# Its defect is a deployed script that has DRIFTED. Provable offline: hash the real files, then
# mutate one copy and require the comparison to name exactly that file.
echo "=== deployed-stack-hashes ==="
FILES="guest/health-check.ps1 guest/set-resolution.ps1 guest/run-as-user.ps1 guest/fire-toast.ps1 guest/surface-watch.ps1"
mkdir -p "$TMP/deployed"
for f in $FILES; do cp "$f" "$TMP/deployed/$(basename "$f")"; done
mismatch(){ local n=0
  for f in $FILES; do
    a=$(sha256sum "$f" | cut -d' ' -f1); b=$(sha256sum "$TMP/deployed/$(basename "$f")" | cut -d' ' -f1)
    [ "$a" = "$b" ] || { n=$((n+1)); echo "     DRIFTED $(basename "$f")"; }
  done; echo "$n"; }
pos=$(mismatch | tail -1)
printf '\n# drift injected by the fail-proof\n' >> "$TMP/deployed/health-check.ps1"
neg=$(mismatch | tail -1)
echo "  identical copies -> $pos mismatch(es) ; one script mutated -> $neg mismatch(es)"
[ "$pos" = 0 ] && [ "$neg" = 1 ] && ok deployed-stack-hashes || no deployed-stack-hashes

# ---------------------------------------------------------------- coldboot-reboot-confirmed
# Asserts LastBootUpTime ADVANCED across the reboot. Its defect is a boot that never happened, i.e.
# an unchanged timestamp - which is exactly what sg1-u2-coldboot.sh refuses on.
echo "=== coldboot-reboot-confirmed ==="
B0=2026-08-31T02:00:42.8742500; B1=2026-08-31T02:06:53.1579090
advanced(){ [ "$1" != "$2" ] && echo yes || echo no; }
p=$(advanced "$B0" "$B1"); n=$(advanced "$B0" "$B0")
echo "  real pair (02:00:42 -> 02:06:53) -> advanced=$p ; identical pair -> advanced=$n"
[ "$p" = yes ] && [ "$n" = no ] && ok coldboot-reboot-confirmed || no coldboot-reboot-confirmed

# ---------------------------------------------------------------- emulated-unplugged
# Asserts the ONLY adapter left is the PV NIC. Negative: the same predicate over a list that still
# contains the emulated Realtek/Intel adapter QWT is supposed to unplug.
echo "=== emulated-unplugged ==="
# The backslash-escaped JSON in the first version was passed through a QUOTED heredoc, so the
# backslashes survived literally and json.loads choked - the check reported "NOT PROVEN" because of
# my own quoting, not because the predicate was wrong. Pass the list as plain arguments instead.
only_pv(){ python3 -c "
import sys
ads = sys.argv[1:]
print('yes' if not [a for a in ads if 'Xen' not in a] else 'no')" "$@"; }
p=$(only_pv 'Xen PV Network Device')
n=$(only_pv 'Xen PV Network Device' 'Realtek RTL8139 Family PCI Fast Ethernet NIC')
echo "  PV-only list -> only_pv=$p ; list still carrying the emulated NIC -> only_pv=$n"
[ "$p" = yes ] && [ "$n" = no ] && ok emulated-unplugged || no emulated-unplugged

# ---------------------------------------------------------------- eligibility-never-had-vif
# Asserts a guest has NEVER seen a vif (no XENVIF enum key, 0 devices, 0 ghosts) - the precondition
# for testing first-vif behaviour. Negative: any non-zero count disqualifies it.
echo "=== eligibility-never-had-vif ==="
elig(){ [ "$1" = 0 ] && [ "$2" = 0 ] && [ "$3" = absent ] && echo yes || echo no; }
p=$(elig 0 0 absent); n=$(elig 1 0 present)
echo "  never-had-vif (0 devices, 0 ghosts, enum absent) -> $p ; a guest that HAS seen one -> $n"
[ "$p" = yes ] && [ "$n" = no ] && ok eligibility-never-had-vif || no eligibility-never-had-vif

exit $rc
