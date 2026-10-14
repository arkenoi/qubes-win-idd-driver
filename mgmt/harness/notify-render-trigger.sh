#!/bin/bash
# notify-render-trigger.sh - fire ONE notification through the shipped helper, for a render witness.
#
#   NV_VM=<vm> NV_ROOT=<repo root> NV_HELPER=<guest path to qwt-notify-error.ps1> NV_ID=<unique id> \
#     mgmt/harness/notify-render-trigger.sh
#
# WHY IT IS ITS OWN FILE. dom0-notify-witness.sh takes a TRIGGER COMMAND - the thing that should
# make dom0 paint something - and then photographs the dom0 desktop, because a notification bubble
# is override-redirect and no per-window capture can see it. The trigger was written inline in
# notify-errors-guest-test.sh; a second inline copy is how two implementations of one step drift
# apart, which cost a whole acceptance cell earlier today when only one copy of the run-marker read
# had been fixed.
#
# THE ID MUST BE UNIQUE PER RUN: the route deliberately sends a given (component,id) only once per
# boot, so a repeated id is SUPPRESSED and the witness would photograph a screen with nothing new
# on it and call the route broken.
set -uo pipefail
cd "${NV_ROOT:?NV_ROOT is the repo root}" || exit 2
: "${NV_VM:?NV_VM is the guest}"
: "${NV_HELPER:?NV_HELPER is the guest path to the shipped helper}"
: "${NV_ID:?NV_ID must be unique per run - a repeat is suppressed by design}"

# The per-guest lock, which is RE-ENTRANT: a caller already holding it (the witness runs inside a
# cell that does) passes straight through, and running this standalone still cannot collide with
# another job on the same guest.
# shellcheck disable=SC1091
source mgmt/harness/vmlock.sh
vm_lock "$NV_VM"
trap 'vm_unlock "$NV_VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
PS=". '$NV_HELPER'; Write-Host ('W=' + (Send-QwtError -Component 'acceptance' -Id '$NV_ID' -Severity ACTION -Header 'Render witness: a human should see this' -Next 'No action needed; this is a test of the dom0 notification path'))"
QTEST_VM="$NV_VM" timeout -k 5 120 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$PS")" 2>/dev/null \
  | tr -d '\r' | grep -aoE '^W=.*'
