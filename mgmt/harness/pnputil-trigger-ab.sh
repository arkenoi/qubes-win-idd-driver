#!/bin/bash
# pnputil-trigger-ab.sh - PROVE, or refute, that `pnputil /add-driver xenbus.inf /install`
# is what wedges a guest, by deliberately re-introducing it.
#
#   mgmt/harness/pnputil-trigger-ab.sh <release.iso> [rounds]
#
# WHY THIS EXISTS. The installer used to run `/install` on the PV bus that hosts the live boot
# disk. PnP therefore tried to restart that device, every process vetoed the removal (a
# Kernel-PnP 225 per process for XENBUS\VEN_XP0001&DEV_VBD), pnputil returned 3010 "reboot
# required", and two guests went deaf within ~90 s of that storm on 2026-09-12. The installer
# now STAGES the driver instead (no /install). That reasoning is a causal CLAIM, and this
# project's rule is that a check is only evidence once it has been seen to FAIL with the defect
# deliberately put back. So:
#
#   arm INJECT  = pnputil /add-driver <cd>\pv-drivers\xenbus\xenbus.inf /install   (the old way)
#   arm STAGE   = pnputil /add-driver <cd>\pv-drivers\xenbus\xenbus.inf            (the new way)
#
# Nothing else differs: same golden, same package, same boot, one command apart. If INJECT
# wedges and STAGE does not, the trigger is named. If NEITHER wedges, the claim is WRONG and
# the commit message that asserts it must be corrected - say so, do not quietly re-run.
#
# WHAT COUNTS AS A WEDGE (the measured fingerprint, not a guess): the domain stays Running,
# qrexec stops answering, and cpu_time CLIMBS across two samples. A guest that merely reboots,
# or that answers again later, is NOT a wedge and is recorded as such.
#
# A wedged guest is LEFT RUNNING AND UNTOUCHED, the run stops that arm, and the module-base
# recorder was armed beforehand so its RIP can be resolved to driver+offset (tools/
# resolve-guest-rip.py) instead of becoming another raw address.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

ISO="${1:?usage: pnputil-trigger-ab.sh <release.iso> [rounds]}"
ROUNDS="${2:-3}"
GOLDEN="${GOLDEN:-win11-qwt}"
SUBJ="${SUBJ:-win11-trig}"
OUT="${OUT:-/home/user/rel/pnputil-trigger-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }
V="$OUT/verdicts.tsv"; : > "$V"

[ -f "$ISO" ] || { say "REFUSED: no such ISO: $ISO"; exit 2; }
source mgmt/harness/e2e-wait.sh

# One owner per guest, for the whole run - the subject name is reused across rounds even though
# the guest behind it is recreated each time, so the lock is taken once here.
source mgmt/harness/vmlock.sh
vm_lock "$SUBJ"
trap 'vm_unlock "$SUBJ" 2>/dev/null' EXIT

# ---- the ISO, read-only, root-free (the idiom quick-upgrade uses) ----------------------
dev=$(udisksctl loop-setup -r -f "$ISO" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
[ -n "$dev" ] || { say "REFUSED: udisksctl loop-setup failed for $ISO"; exit 2; }
LOOP=${dev#/dev/}
say "release ISO on $dev"
cleanup_loop(){ udisksctl loop-delete -b "/dev/$LOOP" >/dev/null 2>&1; }

PRESERVED=""
finish(){
  [ -n "$PRESERVED" ] && {
    say ""
    say "SPECIMEN PRESERVED: $PRESERVED is Running, deaf and UNTOUCHED. Do not kill it."
    say "  module bases were armed, so the RIP resolves:"
    say "    VM=$PRESERVED mgmt/harness/arm-module-bases.sh --dump"
    say "    tools/resolve-guest-rip.py <rip> <dump>"
    say "  dom0 forensics (owner): xl vcpu-list $PRESERVED; xl debug-keys d, twice, 30 s apart"
  }
  say "evidence: $OUT"
  cleanup_loop
  exit "${1:-0}"
}

# ---- is the guest wedged? Running + deaf + cpu climbing -------------------------------
cpu_of(){ printf '' | timeout 20 qrexec-client-vm "$1" admin.vm.Stats 2>/dev/null \
          | tr -d '\0' | grep -aoE 'cpu_time[0-9]+' | head -1 | grep -aoE '[0-9]+'; }

classify(){ # $1=vm -> WEDGED | ALIVE | HALTED | UNKNOWN
  local vm=$1 st a b
  st=$(w_state "$vm")
  [ "$st" = Halted ] && { echo HALTED; return; }
  if w_alive "$vm"; then echo ALIVE; return; fi
  a=$(cpu_of "$vm"); sleep 30; b=$(cpu_of "$vm")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] 2>/dev/null; then
    # deaf, still Running, and burning: the measured fingerprint
    echo WEDGED
  else
    # MISSING DATA IS NOT A PASS. Deaf with no readable cpu_time proves nothing either way.
    echo UNKNOWN
  fi
}

run_round(){ # $1=arm (INJECT|STAGE) $2=round
  local arm=$1 r=$2 flag="" verdict
  [ "$arm" = INJECT ] && flag=" /install"

  say ""
  say "==== round $r arm $arm (pnputil /add-driver ...\\xenbus.inf${flag:-<none>}) ===="

  # A FRESH SUBJECT EVERY ROUND. Never reuse a guest that was wedged or hard-stopped: its
  # volume state is contaminated and the next measurement is unreliable.
  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ" && {
    w_drain_and_shutdown "$SUBJ" say
    w_halt_stable "$SUBJ" 300 "$arm-$r-pre" say >/dev/null 2>&1
    qvm-remove -f "$SUBJ" >/dev/null 2>&1
  }
  # CREATE -> TAG -> COPY VOLUMES, in that order, and NOT qvm-clone. Tag-based policy refuses
  # qvm-clone because it copies volumes before the tag exists - the idiom quick-upgrade.sh
  # documents at its line 222, which I ignored and had refused back at me.
  qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$SUBJ" \
    >/dev/null 2>&1 || { say "  REFUSED: could not create $SUBJ"; return 2; }
  qvm-tags "$SUBJ" add win-idd-testbed >/dev/null 2>&1 || { say "  REFUSED: could not tag $SUBJ"; return 2; }
  qvm-features "$SUBJ" os Windows >/dev/null 2>&1
  for kv in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do
    qvm-prefs "$SUBJ" "${kv%%:*}" "${kv##*:}" >/dev/null 2>&1
  done
  qvm-prefs "$SUBJ" netvm '' >/dev/null 2>&1
  cerr=$(python3 - "$GOLDEN" "$SUBJ" 2>&1 <<'PYV'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PYV
  ) || { say "  REFUSED: volume clone failed: $(echo "$cerr" | tail -1 | cut -c1-160)"; return 2; }
  say "  created and tagged $SUBJ, volumes copied from $GOLDEN"

  timeout 300 qvm-start "$SUBJ" --cdrom="win-idd-mgmt:$LOOP" >/dev/null 2>&1
  w_session "$SUBJ" 900 "$arm-$r-boot" "$OUT" say || { say "  VOID: no session"; return 2; }

  # Armed BEFORE the injection, so a wedge leaves a resolvable RIP.
  if VM="$SUBJ" OUT="$OUT/modbases-$arm-$r" ./mgmt/harness/arm-module-bases.sh >>"$OUT/arm.log" 2>&1; then
    say "  module-base recorder armed"
  else
    say "  WARNING: module-base recorder NOT armed - a wedge here leaves a raw RIP"
  fi

  local cd_inf='D:\pv-drivers\xenbus\xenbus.inf'
  local before; before=$(cpu_of "$SUBJ")
  say "  firing: pnputil /add-driver $cd_inf$flag"
  QTEST_VM=$SUBJ timeout -k 10 300 ./tools/qtest run \
    "cmd /c pnputil /add-driver $cd_inf$flag & echo RC=%errorlevel%" \
    > "$OUT/$arm-$r-pnputil.out" 2>&1
  tr -d '\r' < "$OUT/$arm-$r-pnputil.out" | tail -6 | sed 's/^/    /' | tee -a "$OUT/summary.log"

  # The wedge on 2026-09-12 landed ~90 s after the 225 storm, so watch well past that.
  local i
  for i in $(seq 1 10); do
    sleep 30
    verdict=$(classify "$SUBJ")
    say "  t+$((i*30))s: $verdict (state=$(w_state "$SUBJ"))"
    [ "$verdict" = WEDGED ] && break
  done

  printf '%s\t%s\t%s\n' "$arm" "$r" "$verdict" >> "$V"

  if [ "$verdict" = WEDGED ]; then
    say "  *** WEDGED on arm $arm round $r - preserving this guest and stopping ***"
    PRESERVED="$SUBJ"
    return 1
  fi
  return 0
}

say "=== pnputil /install trigger A/B: golden $GOLDEN, $ROUNDS round(s) per arm ==="
say "    INJECT = the removed /install (expected to wedge if the claim holds)"
say "    STAGE  = the shipping behaviour (expected healthy)"

for r in $(seq 1 "$ROUNDS"); do
  # INTERLEAVED, per the evidence rules: never all of one arm then all of the other.
  for arm in INJECT STAGE; do
    run_round "$arm" "$r" || finish 1
  done
done

say ""
say "=== RESULT ==="
for arm in INJECT STAGE; do
  w=$(awk -F'\t' -v a="$arm" '$1==a && $3=="WEDGED"' "$V" | wc -l)
  n=$(awk -F'\t' -v a="$arm" '$1==a' "$V" | wc -l)
  say "  $arm: $w wedged of $n"
done
say ""
say "READ IT HONESTLY: if INJECT never wedged, the trigger claim is NOT supported by this run"
say "and the installer commit's causal statement must be corrected - an intermittent defect"
say "needs more rounds before a negative means anything, and that is a reason to say"
say "'unproven', never to assume the fix works."
finish 0
