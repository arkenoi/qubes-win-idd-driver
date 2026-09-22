#!/bin/bash
# fetch-wedge-core.sh - pull a wedged guest's MEMORY IMAGE into this qube, over qrexec.
#
#   mgmt/harness/fetch-wedge-core.sh <vm> [outfile]
#
# The dom0 service (local.WinWedgeCore, installed by dom0/17-install-wedge-core-service.sh)
# STREAMS the ELF core on stdout and writes nothing to dom0's filesystem - dom0 here does not have
# 8 GiB to spare, which is what made the previous store-then-copy design refuse at the only moment
# it mattered (owner, 2026-09-23).
#
# WHAT THIS GUARDS, because each one has cost a capture somewhere in this project:
#  * FREE SPACE HERE, checked BEFORE a byte is written. A core is the guest's whole RAM; filling
#    this qube's disk mid-stream would destroy the run AND the evidence.
#  * A SHORT STREAM IS A FAILED CAPTURE, never a small image. The service exits non-zero and this
#    keeps the partial file with a .partial suffix so it is never mistaken for a good one.
#  * The first four bytes must be \x7fELF. A refusal message captured into the file instead of an
#    image is the classic "the evidence is a policy error" trap.
#  * The domain is PAUSED while it is written and resumes afterwards; it is not killed, not
#    bugchecked, not rebooted. Do not shut the guest down while this runs.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: fetch-wedge-core.sh <vm> [outfile]}"
OUT="${2:-$HOME/wedge-cores/${VM}-$(date -u +%Y%m%dT%H%M%SZ).core}"
mkdir -p "$(dirname "$OUT")"

say(){ echo "$(date -u +%H:%M:%SZ) fetch-core: $*"; }

state=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}')
[ "$state" = Running ] || { say "TERMINAL: $VM is '$state', not Running - there is no memory to image"; exit 2; }

# Guest RAM decides the size; +1 GiB of headroom so this cannot be the thing that fills the disk.
ram_mb=$(qvm-prefs "$VM" memory 2>/dev/null)
[ -n "$ram_mb" ] || ram_mb=8192
need_kb=$(( ram_mb * 1024 + 1048576 ))
free_kb=$(df -Pk "$(dirname "$OUT")" | awk 'NR==2 {print $4}')
say "$VM has ${ram_mb} MiB RAM; need ~$(( need_kb/1048576 )) GiB, free $(( free_kb/1048576 )) GiB on $(dirname "$OUT")"
if [ "$free_kb" -lt "$need_kb" ]; then
  say "REFUSED: not enough free space. Free some first - an image half-written into a full disk is"
  say "  worse than no image, and the guest stays paused for the whole write."
  exit 1
fi

say "streaming (the guest is PAUSED while this runs - do not shut it down)"
t0=$(date +%s)
timeout -k 30 3600 qrexec-client-vm dom0 "local.WinWedgeCore+$VM" </dev/null > "$OUT.partial" 2>"$OUT.err"
rc=$?
took=$(( $(date +%s) - t0 ))
sz=$(stat -c %s "$OUT.partial" 2>/dev/null || echo 0)
magic=$(head -c 4 "$OUT.partial" 2>/dev/null | od -An -tx1 | tr -d ' \n')
say "rc=$rc bytes=$sz (${took}s) magic=$magic"
[ -s "$OUT.err" ] && sed 's/^/  dom0: /' "$OUT.err"

if [ "$rc" -ne 0 ]; then
  say "FAILED: the service did not complete - keeping $OUT.partial as evidence of the attempt."
  say "  A dump-core that fails on a wedge is itself a datum; read the dom0 lines above."
  exit 1
fi
if [ "$magic" != "7f454c46" ]; then
  say "FAILED: the stream is not an ELF image (first bytes: $magic). Most likely a refusal message."
  head -c 200 "$OUT.partial"; echo
  exit 1
fi
mv "$OUT.partial" "$OUT"
say "OK: $OUT"
say "  name the spinning code:  tools/xen-core-rip.py $OUT"
say "  resolve to a driver:     tools/resolve-guest-rip.py <module-bases.txt> 0x<rip>"
