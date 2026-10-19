#!/bin/bash
# logvol-chain-check.sh - does the log volume ATTACH, MOUNT, CARRY THE LOGS, and SURVIVE A REBOOT?
#
#   mgmt/harness/logvol-chain-check.sh <vm>
#
# WHY THIS EXISTS, and it is not a flattering reason. The log volume was wired into the acceptance
# campaign on 2026-10-14 and broke the first cell three runs in a row. Each run cost 10-15 minutes
# of rig time to reach the same failure, and each time I fixed ONE link and declared it done:
#   run 1  the leftover sweep DETACHED the volume mid-cell          -> agent_log_healthy false
#   run 2  the sweep's blanket `qvm-features --unset qemu-extra-args` deleted the volume's -drive
#          and usb-storage lines and the shared controller          -> same failure, one boot later
#   run 3  the agent logged to the volume on one boot and NOTHING after the park/restore: LogDir
#          names a REMOVABLE volume that need not be mounted when a service starts
# The owner, after the third: "incredibly pathetic. what prevents you from systemically make sure it
# attaches and stays, not iteratively pass one fuckup at a time?" Nothing prevented it. This does.
#
# IT CHECKS EVERY LINK AND REPORTS THEM ALL. No link short-circuits the rest, so ONE run shows every
# break instead of the first one - that is the whole point. The chain, in order:
#   H1 the image exists and is on a loop device
#   H2 the guest carries a --required claim for it at the expected frontend
#   H3 qemu-extra-args carries OUR drive, OUR usb-storage device, and a controller for it to ride
#   G1 the guest has the volume MOUNTED, and at which drive letter (reported, never assumed)
#   G2 LogDir names a directory ON that volume
#   G3 a QWT log file exists there AND IS HELD OPEN by a process - what health-check asserts
#   H4 the host can read that log with mtools, and it has lines
#   -- REBOOT, the link that broke every time --
#   G4 the volume is mounted again, at the same letter
#   G5 a QWT log there is held open again
#   H5 NEW lines appeared after the reboot
#
# Exit: 0 every link held; 1 at least one broke (each named). Run it on a subject that already
# carries the build - a few minutes - instead of discovering the next break four hours into a
# campaign.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${1:?usage: $0 <vm>}"
say(){ echo "[$(date -u +%H:%M:%S)] chain[$VM]: $*"; }
ok_n=0; bad_n=0
good(){ ok_n=$((ok_n+1)); say "  OK   $*"; }
broke(){ bad_n=$((bad_n+1)); say "  BROKE $*"; }

# shellcheck disable=SC1091
source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
# shellcheck disable=SC1091
source mgmt/harness/logvol-lib.sh
# shellcheck disable=SC1091
source mgmt/harness/e2e-wait.sh
# shellcheck disable=SC1091
source mgmt/harness/shutdown-lib.sh

OUT="scratchpad/logvol-chain-$VM-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
say "evidence -> $OUT"

IMG=$(logvol_image "$VM")
MF="$OUT/manifest.json"

# ---------------------------------------------------------------- prepare: the guest must be down
st=$(w_state "$VM")
[ "$st" = Halted ] || { say "[ERROR] $VM is '$st' - this check attaches before a boot, so it needs it Halted"; exit 2; }

logvol_create "$IMG" "$VM" >>"$OUT/setup.out" 2>&1 || { say "[ERROR] could not create $IMG"; exit 2; }
logvol_attach "$VM" "$IMG" "$MF" >>"$OUT/setup.out" 2>&1 || { say "[ERROR] could not attach $IMG"; exit 2; }

# ---------------------------------------------------------------- H1-H3: the host side of the chain
dev=$(logvol_loop_of "$IMG")
[ -n "$dev" ] && [ -e "/sys/block/$dev/loop/backing_file" ] \
  && good "H1 image on /dev/$dev with a backing file" \
  || broke "H1 no loop device with a backing file for $IMG"

claims=$(python3 - "$VM" <<'PY'
import sys, qubesadmin
try: coll = qubesadmin.Qubes().domains[sys.argv[1]].devices['block']
except KeyError: sys.exit(0)
for a in coll.get_assigned_devices(): print(str(a), (getattr(a,'options',{}) or {}).get('frontend-dev',''))
PY
)
printf '%s\n' "$claims" | command grep -q "$LOGVOL_FRONTEND" \
  && good "H2 claim present at $LOGVOL_FRONTEND ($(printf '%s' "$claims" | tr '\n' ' '))" \
  || broke "H2 no claim at $LOGVOL_FRONTEND (claims: $(printf '%s' "$claims" | tr '\n' ' '))"

qargs=$(qvm-features "$VM" qemu-extra-args 2>/dev/null || true)
nd=$(printf '%s' "$qargs" | command grep -c "id=$LOGVOL_DRIVE_ID" || true)
ndev=$(printf '%s' "$qargs" | command grep -c "drive=$LOGVOL_DRIVE_ID" || true)
nbus=$(printf '%s' "$qargs" | command grep -c 'nec-usb-xhci' || true)
{ [ "$nd" -ge 1 ] && [ "$ndev" -ge 1 ] && [ "$nbus" -ge 1 ]; } \
  && good "H3 qemu-extra-args carries our drive, our device and a controller" \
  || broke "H3 qemu-extra-args incomplete (drive=$nd device=$ndev controller=$nbus): [$qargs]"

# ---------------------------------------------------------------- boot and bind
say "starting $VM"
qvm-start "$VM" >>"$OUT/setup.out" 2>&1 || { say "[ERROR] could not start $VM"; exit 2; }
alive=0; w_alive_wait "$VM" 400 10 && alive=1   # one probe, not forty abandoned ones
[ "$alive" = 1 ] || { say "[ERROR] qrexec never answered"; exit 2; }
good "boot 1: qrexec answers"

logvol_bind_guest "$VM" "$VM" >>"$OUT/bind.out" 2>&1 \
  && good "bind: LogDir pointed at the volume" \
  || broke "bind: failed (see $OUT/bind.out: $(tail -1 "$OUT/bind.out" 2>/dev/null | cut -c1-120))"

# One guest probe answering several questions at once: the volume's letter and label, LogDir, and
# whether any file under LogDir is held open. Asked as ONE call so the answers are consistent.
probe(){ # -> KEY=value lines
  local ps
  ps='$v=Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq "__LABEL__" };
if ($v) { "VOL_LETTER=" + $v.DriveLetter; "VOL_FS=" + $v.FileSystem } else { "VOL_LETTER="; "VOL_FS=" }
$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -EA SilentlyContinue).LogDir; "LOGDIR=" + $d
if ($d -and (Test-Path $d)) {
  $f=@(Get-ChildItem $d -Filter "*.log" -EA SilentlyContinue); "LOGFILES=" + $f.Count
  $held=0; foreach ($x in $f) { try { $s=[IO.File]::Open($x.FullName,"Open","Write","None"); $s.Close() } catch { $held++ } }
  "LOGHELD=" + $held
  $ga=@(Get-ChildItem $d -Filter "gui-agent-*.log" -EA SilentlyContinue); "AGENTLOG=" + $ga.Count
  if ($ga.Count) { "AGENTLINES=" + (@(Get-Content $ga[0].FullName -EA SilentlyContinue).Count) } else { "AGENTLINES=0" }
} else { "LOGFILES=-1"; "LOGHELD=-1"; "AGENTLOG=-1"; "AGENTLINES=-1" }'
  # THE LABEL COMES FROM THE LIBRARY, never from a string here: this check reported six broken
  # links on 2026-10-15 because it still looked for 'LOGVOL' after the sticks were collapsed onto the
  # install's own 'DIAG' label - a hardcoded name in the checker, which is the very class of bug it
  # exists to catch. LogDir was Z: and the logs were arriving the whole time.
  ps=${ps//__LABEL__/$LOGVOL_LABEL}
  QTEST_VM="$VM" timeout -k 5 120 ./tools/qtest run \
    "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$ps")" \
    2>/dev/null | tr -d '\r'
}
p1=$(probe); printf '%s\n' "$p1" > "$OUT/probe-boot1.txt"
g(){ printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1; }

L1=$(g "$p1" VOL_LETTER)
[ -n "$L1" ] && good "G1 the volume is MOUNTED at ${L1}: (fs $(g "$p1" VOL_FS))" \
             || broke "G1 no volume labelled $LOGVOL_LABEL is mounted in the guest"
LD1=$(g "$p1" LOGDIR)
case "$LD1" in
  "${L1}:"*) good "G2 LogDir is on the volume ($LD1)" ;;
  *) broke "G2 LogDir is '$LD1', not on the volume (letter ${L1:-none})" ;;
esac
[ "$(g "$p1" AGENTLOG)" -ge 1 ] 2>/dev/null \
  && good "G3a an agent log exists under LogDir ($(g "$p1" AGENTLINES) lines)" \
  || broke "G3a no gui-agent log under LogDir (files=$(g "$p1" LOGFILES))"
[ "$(g "$p1" LOGHELD)" -ge 1 ] 2>/dev/null \
  && good "G3b $(g "$p1" LOGHELD) log file(s) HELD OPEN - what health-check asserts" \
  || broke "G3b no log under LogDir is held open (health-check's agent_log_healthy fails on this)"

logvol_pull "$IMG" "$OUT/pull1" >>"$OUT/setup.out" 2>&1
n1=$(command grep -rhoaE '^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+' "$OUT/pull1/files" 2>/dev/null | wc -l)
[ "$n1" -gt 0 ] && good "H4 the host reads $n1 QWT line(s) off the volume with mtools" \
               || broke "H4 the host read NO QWT lines off the volume"

# ---------------------------------------------------------------- THE REBOOT, which broke it every time
say "rebooting - this is the link that failed on all three campaign runs"
qwt_shutdown "$VM" 600 >>"$OUT/setup.out" 2>&1
[ "$(w_state "$VM")" = Halted ] || { broke "reboot: $VM did not halt"; say "RESULT: $ok_n held, $bad_n broke"; exit 1; }
qvm-start "$VM" >>"$OUT/setup.out" 2>&1 || { broke "reboot: could not start again"; say "RESULT: $ok_n held, $bad_n broke"; exit 1; }
alive=0; w_alive_wait "$VM" 400 10 && alive=1   # one probe, not forty abandoned ones
[ "$alive" = 1 ] && good "boot 2: qrexec answers" || { broke "boot 2: qrexec never answered"; say "RESULT: $ok_n held, $bad_n broke"; exit 1; }

p2=$(probe); printf '%s\n' "$p2" > "$OUT/probe-boot2.txt"
L2=$(g "$p2" VOL_LETTER)
[ -n "$L2" ] && good "G4a the volume is mounted after the reboot (${L2}:)" \
             || broke "G4a NO volume labelled $LOGVOL_LABEL after the reboot - a removable volume need not be mounted when a service starts"
[ -n "$L2" ] && [ "$L1" = "$L2" ] && good "G4b same drive letter across the reboot (${L1}:)" \
                                  || broke "G4b the letter CHANGED across the reboot (${L1:-none}: -> ${L2:-none}:) - LogDir names a letter, so it now points nowhere"
[ "$(g "$p2" LOGHELD)" -ge 1 ] 2>/dev/null \
  && good "G5 a log under LogDir is held open after the reboot" \
  || broke "G5 nothing under LogDir is held open after the reboot (files=$(g "$p2" LOGFILES)) - this is the failure the campaign hit"

logvol_pull "$IMG" "$OUT/pull2" >>"$OUT/setup.out" 2>&1
n2=$(command grep -rhoaE '^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+' "$OUT/pull2/files" 2>/dev/null | wc -l)
[ "$n2" -gt "$n1" ] && good "H5 NEW lines after the reboot ($n1 -> $n2) - the volume keeps carrying the logs" \
                    || broke "H5 no new lines after the reboot ($n1 -> $n2) - the guest stopped logging to the volume"

say "RESULT: $ok_n link(s) held, $bad_n broke   (evidence $OUT)"
[ "$bad_n" -eq 0 ]
