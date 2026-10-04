#!/usr/bin/env bash
# drop-core.sh <core> - delete a wedge memory image ONLY once its small state is safely on disk.
#
# WHY: 2026-10-02 an 8.6 GB SPIN core was deleted for space after being read for RIP and CR3 only; the stuck vCPU's RAX - which
# hypercall it sat in - went with it. mgmt/harness/fetch-wedge-core.sh now writes <core>.small/ the moment an image lands
# (tools/xen-core-rip.py --small). This is the one sanctioned way to delete an image: it refuses unless that directory holds every
# vCPU's registers, re-extracting once if it is missing, so space can be freed without losing the part that is small and decisive.
#   exit 0 deleted (the .small dir and its log stay); 1 refused (nothing deleted); 2 usage
set -uo pipefail
CORE="${1:?usage: drop-core.sh <core>}"
cd "$(git rev-parse --show-toplevel)" || exit 2
[ -f "$CORE" ] || { echo "drop-core: no such file: $CORE"; exit 2; }
S="$CORE.small"
ok(){ local n
  [ -s "$S/vcpu-regs.txt" ] && [ -s "$S/xen_prstatus.bin" ] || return 1
  n=$(sed -n 's/^vcpus=\([0-9]\{1,\}\)$/\1/p' "$S/vcpu-regs.txt")
  [ -n "$n" ] && [ "$n" -gt 0 ] || return 1
  [ "$(grep -c '^vcpu[0-9]\{1,\} rip=' "$S/vcpu-regs.txt")" = "$n" ] || return 1
  [ "$(stat -c %s "$S/xen_prstatus.bin")" = $(( n * 0x1430 )) ]; }
if ! ok; then
  echo "drop-core: no complete small state at $S - extracting it now"
  python3 tools/xen-core-rip.py "$CORE" --small "$S" > "$S.log" 2>&1
  ok || { echo "drop-core: REFUSED - the small state could not be extracted (see $S.log); this image is the only copy of the registers"; exit 1; }
fi
sz=$(stat -c %s "$CORE")
rm -f "$CORE" "$CORE.SMALL-FAILED" || { echo "drop-core: could not delete $CORE"; exit 1; }
echo "drop-core: deleted $CORE ($sz bytes); kept $S/ ($(du -sh "$S" | cut -f1)) - $(grep -c '^vcpu[0-9]* rip=' "$S/vcpu-regs.txt") vCPU(s) of registers"
