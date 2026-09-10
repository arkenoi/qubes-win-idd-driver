#!/bin/bash
# CLASS A REPRODUCER: does heavy I/O on the EMULATED disk block the guest in wait_for_io?
#
# THE MECHANISM THIS TESTS, which is measured rather than guessed (findings/issues.md, the
# guest-stability P1, 2026-09-10). Specimen 1 - the install stall - was captured with:
#   * VCPU2 and VCPU3 at pause_flags=4 = VPF_blocked_in_xen. That flag is set ONLY by
#     wait_on_xen_event_channel, whose only callers are ioreq.c:186 (wait_for_io) and ioreq.c:1295.
#     So those vCPUs were waiting for the DEVICE MODEL to answer an emulated-I/O request, and never
#     got an answer - which is why their cputime was frozen while vCPU0/1 burned a core each.
#   * the stubdomain BLOCKED at 0.0%, having emitted its QMP greeting advertising "oob" (which
#     proves the monitor ran in its IOThread) while never dispatching qmp_capabilities (which runs
#     on the MAIN LOOP). IOThread alive, main loop not running.
#   * and 100% of that guest's disk I/O going through QEMU: the guest's own VBD counters ALL ZERO
#     across its entire life while its stubdom did 28256 reads / 9634 writes, every disk on
#     `-drive file=/dev/xvd?,if=ide,...,cache=writeback`.
# Put together: a long synchronous operation in QEMU's main loop while it services emulated IDE
# leaves the guest's vCPUs blocked in wait_for_io indefinitely. That mechanism PREDICTS a write-load
# correlation, which is the correlation the install stalls have always shown.
#
# WHY THE PRECONDITION IS A FIXTURE AND NOT A WINDOW. On a finished install the boot disk is PV
# (xenvbd), so the emulated path is only exposed during stage 1 and until the reboot after the PV
# drivers bind - minutes, and not on demand. The `ours-nopvdisk` prime job makes it PERMANENT:
# "QWT working, every disk on emulated ATA". Same guest, same load, one variable changed.
#
# THE CONTROL ALREADY EXISTS AND IS NOT RE-RUN HERE BY DEFAULT: the identical load on a PV-disk
# guest measured 0 stalls in 6 loaded shutdown cycles plus 50 idle reboots (flush-ab-poweroff,
# flush-ab-concurrent, reboot-loop). If this arm stalls where that one did not, the DISK PATH is the
# variable and Class A is reproduced.
#
# THE LOAD IS WRITE PLUS FLUSH, not write alone. With cache=writeback the interesting event is the
# FLUSH: QEMU must push the stubdom's page cache down to the backing device, and a flush is the
# operation most likely to sit in its main loop. Write-without-flush was already measured harmless
# on the PV path; here each batch is followed by an explicit Write-VolumeCache.
#
# HOW A STALL IS RECOGNISED - and it must be told apart from CLASS B, the Windows PAUSE spin, which
# looks superficially identical (Running, deaf, no window). The discriminator is CPU:
#   CLASS A - the guest's vCPUs BLOCK. Guest cputime goes nearly FLAT (the blocked vCPUs stop
#             accruing entirely) and the stubdom is blocked too. Little or no burn.
#   CLASS B - three vCPUs SPIN in a pause loop, burning ~150-400% of a core.
# So a deaf guest that is NOT burning is the Class A candidate, and a deaf guest that IS burning is
# Class B. This is the opposite of the old "burning means wedged" reading, which conflated them.
# The definitive read is pause_flags, and that needs dom0: the commands are printed, not guessed at.
#
# NOTHING IS EVER KILLED. Both classes are left exactly as they stand.
#
# Usage:  VM=win10-ioreq BASE=win10-base W=<acceptance work dir with dl/> mgmt/harness/ioreq-stall-repro.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM - an EXPENDABLE subject name; it will be primed from BASE}"
BASE="${BASE:-win10-base}"
JOB="${JOB:-ours-nopvdisk}"
ROUNDS="${ROUNDS:-20}"
LOAD_MB="${LOAD_MB:-1024}"
PRIME="${PRIME:-1}"          # 0 = the subject already exists in the right state, do not re-prime
OUT="${OUT:-/home/user/rel/ioreq-repro-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

# NEVER this guest: it is the preserved Class B specimen.
[ "$VM" = win10-abt ] && { echo "REFUSED: win10-abt is the preserved Class B specimen. Pick another name."; exit 2; }

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
  W="${W:?set W to the acceptance work dir holding dl/qwt-improved-setup}"
  qvm-ls --raw-data --fields NAME | grep -qx "$VM" && { say "removing the previous subject $VM"; qvm-remove -f "$VM" >/dev/null 2>&1; }
  say "=== priming $VM from $BASE with job $JOB (every disk on emulated ATA) ==="
  ./mgmt/harness/prime-run.sh "$BASE" "$VM" "$JOB" --payload "$W/dl/qwt-improved-setup" >"$OUT/prime.log" 2>&1
  rc=$?
  say "prime rc=$rc (log: $OUT/prime.log)"
  [ "$rc" = 0 ] || { say "VOID: priming failed - no subject to test"; exit 2; }
fi

w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

# ARM CLASS B RESOLUTION BEFORE DRIVING ANY LOAD. This harness can trip either class - it says so
# below - and if it trips Class B the guest becomes unaskable, exactly as specimen 2 did. The module
# bases needed to name the spinning code exist ONLY during the boot that later wedges, so record
# them now, while the guest still answers. Failure to arm is logged and does NOT abort: Class A is
# what this run is for, and it is measurable without the Class B arming.
if VM="$VM" OUT="$OUT/modbases" ./mgmt/harness/arm-module-bases.sh >"$OUT/arm-modbases.log" 2>&1; then
  say "Class B resolution ARMED on $VM (module bases recorded this boot)"
else
  say "WARNING: could not arm module-base recording (see $OUT/arm-modbases.log). If this run trips"
  say "         CLASS B instead of Class A, its RIPs will be UNRESOLVABLE - same dead end as specimen 2."
fi

# ASSERT THE PRECONDITION ON THE SIGNAL THAT MATTERS. "ours-nopvdisk was requested" is not "the boot
# disk is emulated" - a cell that asserts its precondition on a different signal from the one the
# mechanism depends on is not a test (experimenter rule 5b). The mechanism needs the BOOT disk to be
# served by QEMU, so read the bus type of the boot disk itself.
bus=$(psp BUS '
$d = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk -EA SilentlyContinue |
       Where-Object { $_.IsBoot } | Select-Object -First 1)
if ($d) { Write-Host ("BUS=" + $d.BusType + "|" + ($d.Model).Trim()) } else { Write-Host "BUS=unknown" }' 150)
say "boot disk: ${bus:-<unreadable>}"
case "${bus:-}" in
  3\|*|2\|*)  say "precondition OK: the boot disk is on the EMULATED ATA/ATAPI path (BusType ${bus%%|*})" ;;
  1\|*)       say "REFUSED: the boot disk is on the PV path (BusType 1, SCSI/PVDISK). That is the CONTROL"
              say "         condition, already measured at 0 stalls - running the load here tests nothing."
              exit 2 ;;
  *)          say "REFUSED: could not establish the boot disk's bus type ('${bus:-}'). Missing data fails;"
              say "         a run whose precondition is unknown cannot be graded."; exit 2 ;;
esac

# The write+flush load, in the guest, bounded. Verified: a load that silently wrote nothing would
# make every round a no-op and the whole run a false negative.
load_once(){
  psp DID "
\$ErrorActionPreference='Stop'
\$dir = Join-Path \$env:SystemDrive 'ioreqload'
if (-not (Test-Path \$dir)) { New-Item -ItemType Directory -Path \$dir | Out-Null }
\$buf = New-Object byte[] (1MB)
(New-Object Random 11).NextBytes(\$buf)
\$mb = 0
for (\$i = 0; \$i -lt $((LOAD_MB/32)); \$i++) {
  \$fs = [IO.File]::Create((Join-Path \$dir \"i\$i.bin\"))
  for (\$j = 0; \$j -lt 32; \$j++) { \$fs.Write(\$buf, 0, \$buf.Length); \$mb++ }
  \$fs.Close()
}
# THE FLUSH IS THE POINT. With cache=writeback the guest's writes sit in the STUBDOM's page cache;
# this is what forces QEMU to push them down, which is the operation most likely to sit in its main
# loop. A write-only load was already measured harmless on the PV path.
\$flushed = 'no'
try { Write-VolumeCache -DriveLetter (\$env:SystemDrive.TrimEnd(':')) -EA Stop; \$flushed = 'yes' } catch {}
Remove-Item (Join-Path \$dir '*') -Force -EA SilentlyContinue
Write-Host (\"DID=\" + \$mb + \"MB|flushed:\" + \$flushed)" 900
}

say "=== $ROUNDS rounds of ${LOAD_MB}MB write+flush on the EMULATED boot disk ==="
stalls=0
for r in $(seq 1 "$ROUNDS"); do
  a=$(cput)
  res=$(load_once)
  if [ -n "$res" ]; then
    b=$(cput); d=unknown
    [ -n "$a" ] && [ -n "$b" ] && d=$(python3 -c "print(f'{(int(\"$b\")-int(\"$a\"))/1e9:.1f}')" 2>/dev/null || echo unknown)
    say "  round $r/$ROUNDS: $res (guest burned ${d}s CPU)"
    continue
  fi

  # No answer. CLASSIFY - and the classification is the whole point of this harness.
  say "  round $r: NO ANSWER from the guest. Classifying by CPU burn, not by the silence."
  x=$(cput); sleep 20; y=$(cput)
  burn=unknown
  [ -n "$x" ] && [ -n "$y" ] && burn=$(python3 -c "print(f'{(int(\"$y\")-int(\"$x\"))/1e9/20*100:.0f}')" 2>/dev/null || echo unknown)
  say "  state=$(state)  burn=${burn}% of a core"
  if [ "$burn" = unknown ]; then
    say "  UNCLASSIFIED - cputime unreadable. Not recording this as either class."
  elif [ "${burn%%.*}" -lt 40 ] 2>/dev/null; then
    stalls=$((stalls+1))
    say "  *** CLASS A CANDIDATE: deaf and NOT burning (${burn}%) - consistent with vCPUs BLOCKED in"
    say "      wait_for_io while the device model does not answer. THIS IS THE HYPOTHESIS REPRODUCED."
    say "      LEFT UNTOUCHED. Confirm it in dom0 - pause_flags=4 on the blocked vCPUs is decisive:"
    say "        sudo xl dmesg -c >/dev/null; sudo xl debug-keys q; sudo xl dmesg > ~/A-domains.txt"
    say "        grep -A2 'for domain <domid>' ~/A-domains.txt      # look for pause_flags=4"
    say "        sudo xl vcpu-list $VM > ~/A-vcpu.txt; sudo xentop -b -i2 > ~/A-xentop.txt"
    say "      and the stubdom's QMP/monitor state, which is the other half of the mechanism:"
    say "        sudo xl list -l ${VM}-dm 2>/dev/null; sudo tail -50 /var/log/xen/qemu-dm-${VM}.log"
  else
    say "  NOT Class A: deaf but BURNING ${burn}% of a core - that is the CLASS B signature (a Windows"
    say "  pause-spin), a different defect. Left untouched; capture with debug-keys d AND v, twice,"
    say "  with a recorded interval, and see mgmt/harness/arm-module-bases.sh for resolving its RIPs."
  fi
  say "  stopping: the subject is in a terminal state and is being preserved, not restarted."
  exit 1
done
say "=== $ROUNDS rounds, $stalls stalls. No Class A stall on the emulated path in this run ==="
say "    Against the PV-path control (0 stalls) that means the disk path alone has NOT been shown to"
say "    matter yet. With 0 events in $ROUNDS rounds the 95% upper bound on the per-round rate is"
say "    about $(python3 -c "print(f'{3/$ROUNDS:.2f}')"), so this run can only exclude rates above that."
