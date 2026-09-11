#!/bin/bash
# IS THE MISSING INGREDIENT DEVICE RE-ENUMERATION ON A FRESH DEVICE MODEL?
#
# WHERE THIS COMES FROM. Class A (findings/issues.md, guest-stability P1) is a guest whose vCPUs are
# blocked in wait_for_io because QEMU's main loop stopped running. It has been captured once, during
# a clean install, 2 SECONDS into stage 2 - i.e. in the first seconds of a freshly created device
# model, BEFORE msiexec, when almost no I/O had happened. Three cheaper conditions are already
# EXCLUDED by measurement:
#     PV-path idle proven reboots ......... 0/50
#     EMULATED-path idle proven reboots ... 0/30   (every cycle a full destroy-and-start, so a FRESH
#                                                   QEMU each time - freshness alone is NOT enough)
#     EMULATED-path 1 GB write rounds ..... 0/20   (10 flushing, 10 not, interleaved)
# so it is not the disk path, not bulk I/O, not booting, and not flushing. Only a real install has
# ever produced it, at ~14 minutes a round.
#
# THE ONE INGREDIENT THOSE ARMS ALL LACK is what an install does and a boot does not: it INSTALLS
# DRIVERS AND RE-ENUMERATES DEVICES while the device model is still young. That is a DEVICE-MODEL
# workload, not a Windows one - a PnP rescan makes the guest re-probe hardware, which is traffic the
# emulated device model must answer, and the captured stall is precisely the device model failing to
# answer.
#
# So drive THAT and nothing else. `pnputil /scan-devices` forces a PnP re-enumeration on demand,
# needs no installer, no payload and no reboot, and takes seconds - which turns a 14-minute
# reproducer into a ~2-minute one IF this is the ingredient.
#
# WHY IT IS AIMED AT A FRESH DOMAIN, with an aged control. Each round starts with a PROVEN reboot
# (destroy + start, boot id changed) and then hits the guest immediately, inside the window the
# capture points at. The AGED arm runs the same storm after the domain has been up AGE_S seconds.
# If only the fresh arm stalls, the device model's early life is the variable, and the S5 stage-1
# change - which took fresh-domain transitions from ~60% to 100% - is implicated as an EXPOSURE
# amplifier (not as a bug: it closed a measured leak and must not be reverted on this reasoning).
# If neither arm stalls, re-enumeration is excluded too and the remaining difference is narrower.
#
# PRECONDITION ASSERTED ON THE SIGNAL THAT MATTERS: the boot disk must be EMULATED, read from the
# disk's own bus type rather than from the job name (experimenter rule 5b). On the PV path the
# guest's disk I/O never reaches QEMU at all, so the mechanism cannot fire and a clean result would
# mean nothing.
#
# CLASSIFICATION, and it is the OPPOSITE of the old "burning means wedged" reading:
#     deaf and NOT burning  -> CLASS A candidate (vCPUs BLOCKED in wait_for_io)
#     deaf and BURNING      -> CLASS B (a Windows pause-spin), a different defect
# The decisive read is pause_flags and that needs dom0, so the commands are printed, never guessed.
# NOTHING IS EVER KILLED.
#
# STATUS 2026-09-11: WRITTEN, NEVER RUN, AND ITS PREMISE IS NOW PARTLY SUPERSEDED. It was built when
# the remaining unexplained difference between a real install and every cheap fixture looked like
# device re-enumeration. The mechanism workflow then named a spinning primitive that needs no device
# enumeration at all - xenbus StoreSubmitRequest looping unbounded at DISPATCH_LEVEL under
# Context->Lock, with xenstore as the likely shared dependency of both the guest spin and the stalled
# device model (findings/issues.md, guest-stability P1). So this is kept as a DESIGNED BUT UNTESTED
# arm, not a recommendation: re-enumeration is still the one install-only ingredient the exclusion
# table has never covered, and if the xenstore identification is confirmed by harvesting module
# bases, a rescan storm is a plausible way to PROVOKE xenstore traffic on demand. Decide before
# spending rig time on it.
#
# Usage:  VM=win10-enum BASE=win10-base W=<work dir with dl/> ROUNDS=10 mgmt/harness/enum-storm-repro.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM - an EXPENDABLE subject name}"
BASE="${BASE:-win10-base}"
JOB="${JOB:-ours-nopvdisk}"
ROUNDS="${ROUNDS:-10}"
SCANS="${SCANS:-8}"          # rescans per round
AGE_S="${AGE_S:-300}"        # how long the aged arm lets the domain run before the storm
PRIME="${PRIME:-1}"
OUT="${OUT:-/home/user/rel/enum-storm-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
psp(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-180}" \
       | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }
state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
cput(){ printf '' | qrexec-client-vm "$VM" admin.vm.CurrentState 2>/dev/null | tr -d '\000' | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }

if [ "$PRIME" = 1 ]; then
  W="${W:?set W to the work dir holding dl/qwt-improved-setup}"
  qvm-ls --raw-data --fields NAME | grep -qx "$VM" && { say "removing previous subject $VM"; qvm-remove -f "$VM" >/dev/null 2>&1; }
  say "=== priming $VM from $BASE job $JOB (all disks emulated ATA) ==="
  ./mgmt/harness/prime-run.sh "$BASE" "$VM" "$JOB" --payload "$W/dl/qwt-improved-setup" >"$OUT/prime.log" 2>&1
  rc=$?; say "prime rc=$rc"
  [ "$rc" = 0 ] || { say "VOID: prime failed, no subject"; exit 2; }
fi
w_alive "$VM" || { say "VOID: $VM not answering qrexec"; exit 2; }

bus=$(psp BUS '
$d = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk -EA SilentlyContinue |
       Where-Object { $_.IsBoot } | Select-Object -First 1)
if ($d) { Write-Host ("BUS=" + $d.BusType + "|" + ($d.Model).Trim()) } else { Write-Host "BUS=unknown" }' 150)
say "boot disk: ${bus:-<unreadable>}"
case "${bus:-}" in
  3\|*|2\|*) say "precondition OK: boot disk on the EMULATED ATA path" ;;
  1\|*) say "REFUSED: boot disk is PV (BusType 1). The guest's disk I/O never reaches QEMU, so the"
        say "         mechanism cannot fire and a clean result would prove nothing."; exit 2 ;;
  *) say "REFUSED: bus type unreadable ('${bus:-}'). Missing data fails."; exit 2 ;;
esac

# Arm the Class B resolver BEFORE any load: if this trips Class B instead, its RIPs must be
# resolvable, and that needs the module bases recorded on THIS boot while the guest still answers.
if VM="$VM" OUT="$OUT/modbases" ./mgmt/harness/arm-module-bases.sh >"$OUT/arm.log" 2>&1; then
  say "Class B resolution armed"
else
  say "WARNING: module-base arming failed - a Class B hit here would be UNRESOLVABLE (see $OUT/arm.log)"
fi

# The storm, verified per round: one that silently did nothing would turn every round into an idle
# round and the whole run into a false negative.
storm(){
  psp STORM "
\$ok = 0; \$fail = 0
for (\$i = 0; \$i -lt $SCANS; \$i++) {
  & pnputil.exe /scan-devices 2>&1 | Out-Null
  if (\$LASTEXITCODE -eq 0) { \$ok++ } else { \$fail++ }
}
Write-Host (\"STORM=ok:\" + \$ok + \"|fail:\" + \$fail)" 600
}

classify(){                       # $1 = context label
  local ctx=$1 x y burn
  say "  no answer during $ctx - classifying by CPU burn, not by the silence"
  x=$(cput); sleep 20; y=$(cput)
  burn=unknown
  [ -n "$x" ] && [ -n "$y" ] && burn=$(python3 -c "print(f'{(int(\"$y\")-int(\"$x\"))/1e9/20*100:.0f}')" 2>/dev/null || echo unknown)
  say "  state=$(state)  burn=${burn}% of a core"
  if [ "$burn" = unknown ]; then
    say "  UNCLASSIFIED - cputime unreadable; recording as neither class."
  elif [ "${burn%%.*}" -lt 40 ] 2>/dev/null; then
    say "  *** CLASS A CANDIDATE ($ctx): deaf and NOT burning - consistent with vCPUs BLOCKED in"
    say "      wait_for_io. LEFT UNTOUCHED. Confirm in dom0 (pause_flags=4 is decisive):"
    say "        sudo xl dmesg -c >/dev/null; sudo xl debug-keys q; sudo xl dmesg > ~/A-domains.txt"
    say "        sudo xl vcpu-list $VM > ~/A-vcpu.txt; sudo xentop -b -i2 > ~/A-xentop.txt"
    say "        sudo tail -80 /var/log/xen/qemu-dm-${VM}.log     # the stubdom's own last words"
  else
    say "  CLASS B signature ($ctx): deaf but BURNING ${burn}% - a Windows pause-spin, a different"
    say "  defect. Module bases were armed, so its RIPs are resolvable this time:"
    say "        sudo xl dmesg -c >/dev/null; sudo xl debug-keys v; sudo xl dmesg > ~/B-v.txt"
    say "        then: VM=$VM mgmt/harness/arm-module-bases.sh --dump; tools/resolve-guest-rip.py <file> <rip>"
  fi
  say "  stopping with the subject PRESERVED, not restarted."
}

say "=== $ROUNDS rounds: FRESH-domain storm vs AGED-domain storm ($SCANS rescans each, age ${AGE_S}s) ==="
printf 'round\tarm\tresult\n' > "$OUT/table.tsv"
for r in $(seq 1 "$ROUNDS"); do
  # INTERLEAVED so anything drifting over the run cannot land in one arm only.
  if [ $((r % 2)) -eq 1 ]; then arm=fresh; else arm=aged; fi
  say "--- round $r/$ROUNDS arm=$arm"

  if ! res=$(g_reboot_proven "$VM" "r$r-$arm" 2>&1); then
    say "  reboot not proven: $res"
    classify "the reboot"; exit 1
  fi
  if [ "$arm" = aged ]; then
    say "  aged arm (the control): letting the domain run ${AGE_S}s before the storm"
    sleep "$AGE_S"
    w_alive "$VM" || { classify "the ageing wait"; exit 1; }
  else
    say "  fresh arm: storm IMMEDIATELY, inside the window the capture points at"
  fi

  out=$(storm)
  case "$out" in
    STORM=ok:*) say "  round $r ($arm): $out"
                printf '%s\t%s\t%s\n' "$r" "$arm" "$out" >> "$OUT/table.tsv" ;;
    "")         classify "the $arm storm"; exit 1 ;;
    *)          say "  VOID round $r ($arm): storm returned '$out' - not a stall, but not graded either"
                printf '%s\t%s\t%s\n' "$r" "$arm" "VOID:$out" >> "$OUT/table.tsv" ;;
  esac
done

say "=== table ==="; column -t "$OUT/table.tsv" 2>/dev/null | tee -a "$OUT/summary.log" || cat "$OUT/table.tsv"
fresh_n=$(awk -F'\t' '$2=="fresh" && $3 ~ /^STORM=ok/' "$OUT/table.tsv" | wc -l)
aged_n=$(awk -F'\t' '$2=="aged"  && $3 ~ /^STORM=ok/' "$OUT/table.tsv" | wc -l)
say "graded rounds: fresh=$fresh_n aged=$aged_n, stalls=0"
say "VERDICT: device re-enumeration on a fresh device model did NOT reproduce it in $fresh_n fresh rounds."
say "         With 0 events the 95% upper bound on the per-round rate is about $(python3 -c "print(f'{3/max($fresh_n,1):.2f}')")."
say "         Combined with the 0/30 idle and 0/20 write arms, the remaining difference between these"
say "         fixtures and a real install narrows to DRIVER INSTALLATION itself - driver-store writes,"
say "         service creation, boot-critical driver changes - not a PnP rescan of unchanged hardware."
