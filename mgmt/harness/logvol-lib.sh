# mgmt/harness/logvol-lib.sh - the SECONDARY LOG VOLUME for harness-driven test cells (PLAN-acceptance-
# optimization section 3). Source it from a harness that already holds the per-guest lock; nothing here
# takes the lock, boots a guest, or runs on its own.
#
# THE CASE THIS IS DESIGNED FOR (owner, 2026-10-13): the guest WEDGES - qrexec dead, GUI frozen,
# nothing can be asked of it - and we still need QWT's own per-module logs RIGHT UP TO the moment it
# hung, because the last lines before a hang are where vchan pressure shows itself. Product failures
# that bisect easily are the secondary use. Everything below is judged against the wedge.
#
# THE PATTERN (prime-run.sh lines 199-262, the DIAG stick, in daily use): a writable FAT image on its
# own loop device in THIS qube, assigned --required at frontend-dev=xvdj with read-only=false, riding
# the SAME nec-usb-xhci controller as a second REMOVABLE usb-storage device (a superfloppy FAT mounts
# on removable media only - as a plain Xen disk it came up with no volume and no letter, measured
# 2026-09-07), read back on the host with mtools. Because the volume is a plain image FILE mapped to
# a loop device, the host reads it with mdir/mcopy WITHOUT the guest's cooperation and WITHOUT
# detaching anything, while the guest runs, wedges or sits Halted - which is what lets a wedged
# specimen be read WHILE IT IS STILL WEDGED and left alive for forensics (plan section 4: "specimen
# stays alive until package verifies"). logvol_pull is that read; collect-failure.sh calls it first.
#
# DURABILITY - WHAT SURVIVES A WEDGE OR A HARD KILL, LAYER BY LAYER. Whatever the guest has not
# flushed is simply not in the backing file and mtools cannot recover it, so flushing and host-side
# readability are one requirement seen from two ends. Each layer is made write-through by
# construction, not by luck:
#   L1 the writer.  windows-utils composes each line into ONE WriteFile (ADR-logging). The binder
#      sets the ROOT registry value LogSafeFlush=1 (HKLM\Software\Invisible Things Lab\Qubes Tools;
#      CfgReadDword falls back from the module key to the root, config.c:64-94), which every
#      windows-utils module honours at its next LogInit by opening its log with
#      FILE_FLAG_WRITE_THROUGH (patches/windows-utils-one-log-per-module.patch, log.c). With that flag
#      fastfat completes the write - the data and the directory entry - at the device before WriteFile
#      returns. So EVERY LINE WHOSE WriteFile RETURNED is at the device.
#   L2 the device.  Windows' default policy for a removable usb-storage device is Quick removal
#      (device write caching disabled). Our -drive carries cache=writethrough, so qemu completes each
#      guest write only after it is flushed down the chain: usb-storage -> qemu block layer -> the
#      stubdom's blkfront -> this qube's blkback -> the loop device -> the image file's page cache IN
#      THIS QUBE. A guest wedge or a qvm-kill cannot reach that: the stubdom and this qube are
#      separate domains and neither is killed with the guest.
#   L3 the host.  mtools reads the image file through this qube's page cache, coherent with what the
#      loop driver wrote (udisksctl loop-setup is not --direct-io). No detach, no unmount, no guest.
# NOT GUARANTEED, and the header must not imply otherwise:
#   - the line IN FLIGHT at the wedge instant (its WriteFile never returned);
#   - any module whose LogSafeFlush was not yet in effect (the value is read at LogInit, i.e. at the
#     module's next start - the binder's effect is complete from the NEXT BOOT; until then a module
#     is covered only up to Windows' lazy-writer flush, a few seconds behind);
#   - writers that are not windows-utils loggers (PowerShell Add-Content/Out-File in our scripts,
#     the updater's logs): their close() hands the bytes to the file system, and whether fastfat
#     writes a quick-removal volume through without FILE_FLAG_WRITE_THROUGH is NOT MEASURED here;
#   - a FAT directory entry that lags its data: a handle without write-through can leave bytes in
#     allocated clusters that the recorded size does not cover; mcopy stops at the recorded size.
#     logvol_salvage scans the RAW IMAGE for log-shaped lines and returns every one it finds, which
#     is how such a tail is recovered; the package keeps both;
#   - anything written outside the redirected directory (the stray dirs the sweep collector scans).
# MEASUREMENT OWED (nothing here has run on a guest): on the first rig run, (i) the last line a module
# wrote before a forced wedge (M8 suspend, failproof-faultinject) is present in logvol_pull's copy
# read while the guest is still wedged; (ii) a line written one second before a qvm-kill is present.
# Until both are seen, "durable" is a design claim.
#
# TEST RUNS ONLY. Never a user guest, never a sealed golden: the attach changes qemu-extra-args and
# the block assignments of the qube it is given, and logvol_attach refuses a name that carries a
# committed seal (mgmt/goldens/<vm>.json).
#
# WHAT A HARNESS DOES (the retrofit is NOT in this file; matrix.sh / quick-upgrade.sh / prime-run.sh
# call these at cell start and cell end):
#     . mgmt/harness/logvol-lib.sh
#     IMG=$(logvol_image "$CELLID")                 # $LOGVOL_DIR/logs-<id>.img
#     logvol_create "$IMG" "$CELLID"                # archives the previous contents, then a fresh FAT
#     logvol_attach "$VM" "$IMG" "$MANIFEST"        # BEFORE the guest starts: loop + assign + qemu args
#     ... start the guest, wait for qrexec ...
#     logvol_bind_guest "$VM" "$CELLID"             # LogDir -> the volume, LogSafeFlush=1; next boot = full
#     ... the cell (its graded boot is after the bind) ...
#     logvol_pull "$IMG" "$OUT/logvol"              # read back on the host, guest alive, wedged or not
#     logvol_salvage "$IMG" "$OUT/logvol"           # raw-image scan for lines no directory entry covers
#     logvol_detach "$VM" "$MANIFEST"               # AFTER the guest halted: unassign, strip args, loop
#
# THE GUEST-SIDE BINDING (mgmt/harness/logvol-bind.ps1, run with tools/qtest pushrun). Two modes:
#   registry  (DEFAULT; Jev 2026-10-13 logvol_bind_mechanism = registry-logdir-redirect 0.52 over
#             pending-rename-junction 0.44, confidence 0.36 - a LOW-confidence verdict, so both are
#             implemented and the first rig run decides): the root LogDir value, which every
#             windows-utils writer reads once at its own LogInit and the sweep collector reads, is
#             pointed at <vol>:\qwt-logs\<id>; the old directory's contents are COPIED across at bind
#             time (the install-boot logs would otherwise stay behind - the disconfirming fact Jev
#             weighed); LogSafeFlush=1 is set at the root; the old values are saved for -Restore.
#             ADR-logging's contract (one file per module per day, append-only, single WriteFile,
#             pid:tid prefix) is untouched: the destination moves, and only for the test.
#   junction  (OPT-IN, LOGVOL_BIND_MODE=junction; UNMEASURED on this rig): an NTFS junction is made at
#             a sibling name and two PendingFileRenameOperations swap it into the log directory's
#             path at the next boot, before any service holds a log open (a LIVE log directory cannot
#             be renamed: the writers hold their files without FILE_SHARE_DELETE). Keeps every
#             consumer's path identical. Rests on smss processing pending renames for a path on the
#             Q: data volume, which nobody has measured here - that is why it is not the default.
#             LogSafeFlush=1 is set in this mode too.
#
# THE INSTALL PHASE (nice-to-have - owner 2026-10-13: "if we can insert junction earlier, it is good,
# but not really necessary"). It falls out of the design: logvol_attach runs BEFORE first boot and
# composes qemu-extra-args around an existing answer-stick controller, so on a vendor-media install
# the volume is simply the second removable USB device WinPE sees, and a windowsPE
# RunSynchronousCommand can copy X:\*.log onto it SYNCHRONOUSLY - mgmt/harness/logvol-winpe-copy.cmd
# is that command (a detached `start "" /min cmd /c ...` copier produced NOTHING on 2026-10-13: Setup
# reaps the child when the command returns). Staging it on the stick and naming it in the answer file
# are the caller's changes; mgmt/reprovision-usb.sh and mgmt/diskprep.cmd are not edited in this pass.
#
# EVERY STEP IS LOUD AND BOUNDED; nothing here sleeps on a timer or retries forever. Return codes:
# 0 done, 1 the step failed (said why on stderr), 2 refused (a seal, a missing tool, a bad argument).
# Self-test: tools/tests/logvol-lib-selftest.sh (PATH shims for udisksctl/qvm-device/qvm-features/
# losetup/qtest; mkfs.fat and mtools REAL on an image file; each defect knob seen to fail).

LOGVOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGVOL_ROOT="$(cd "$LOGVOL_LIB_DIR/../.." && pwd)"
LOGVOL_HOLDER="${LOGVOL_HOLDER:-win-idd-mgmt}"      # the qube that holds the loop device (this one)
LOGVOL_FRONTEND="${LOGVOL_FRONTEND:-xvdj}"           # prime-run's DIAG slot; xvdi is the answer stick
LOGVOL_LABEL="${LOGVOL_LABEL:-LOGVOL}"
LOGVOL_SIZE_MB="${LOGVOL_SIZE_MB:-256}"              # a day of module logs is ~0.2 MiB; MSI verbose logs are MBs
LOGVOL_DIR="${LOGVOL_DIR:-$HOME/win-iso/logvol}"     # images live OUTSIDE the repo (never a tracked path)
LOGVOL_ARCHIVE_DIR="${LOGVOL_ARCHIVE_DIR:-$LOGVOL_DIR/archive}"
LOGVOL_BIND_PS1="${LOGVOL_BIND_PS1:-$LOGVOL_LIB_DIR/logvol-bind.ps1}"
LOGVOL_QTEST="${QTEST_BIN:-$LOGVOL_ROOT/tools/qtest}"
LOGVOL_DRIVE_ID="logdrv"                             # our -drive id; the usb-storage device rides on it
LOGVOL_OWN_BUS="logusb"                              # the controller we add when the guest has none
LOGVOL_CACHE="writethrough"                          # L2 of the durability chain - never writeback here

_lv_say(){ echo "logvol: $*" >&2; }

# ---------------------------------------------------------------------------------------------- image
logvol_image(){ # <id> -> the image path for a cell/campaign id
  local id="${1:?[ERROR] logvol_image <id>}"
  case "$id" in *[!A-Za-z0-9._-]*|'') _lv_say "[ERROR] REFUSED: id '$id' is not [A-Za-z0-9._-]"; return 2 ;; esac
  printf '%s/logs-%s.img' "$LOGVOL_DIR" "$id"
}

# A STABLE VOLUME SERIAL PER ID. Windows persists a drive letter per volume serial (MountedDevices);
# mkfs.fat picks a random one unless told, and a letter that changes between boots breaks a LogDir
# that names it. Derived from the id, so a recreated image for the same cell keeps its letter.
_lv_serial(){ printf '%s' "$1" | sha256sum | cut -c1-8; }

logvol_create(){ # <img> <id> [size_mb] - a FRESH volume; the previous contents are archived first, never discarded
  local img="${1:?[ERROR] logvol_create <img> <id> [size_mb]}" id="${2:?[ERROR] logvol_create <img> <id> [size_mb]}" mb="${3:-$LOGVOL_SIZE_MB}"
  command -v mkfs.fat >/dev/null || { _lv_say "[ERROR] REFUSED: mkfs.fat is not installed"; return 2; }
  command -v mcopy >/dev/null || { _lv_say "[ERROR] REFUSED: mtools (mcopy) is not installed - memory: mtools-mcopy-recovery"; return 2; }
  case "$id" in *[!A-Za-z0-9._-]*|'') _lv_say "[ERROR] REFUSED: id '$id' is not [A-Za-z0-9._-]"; return 2 ;; esac
  mkdir -p "$(dirname "$img")" || return 1
  if [ -s "$img" ]; then
    # ARCHIVE BEFORE WIPING (prime-run's rule): the volume's contents are the only evidence a dead
    # cell leaves, and this reformat destroys them. Every set is kept, timestamped, before the wipe.
    local arch="$LOGVOL_ARCHIVE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$id"
    if logvol_pull "$img" "$arch" >/dev/null 2>&1; then _lv_say "previous contents archived to $arch"   # GUARD:archive DEFECT: if false; then :
    else rm -rf "$arch"; _lv_say "previous image held nothing readable (no archive made)"; fi
  fi
  # THE LOOP DEVICE CACHES THE BACKING FILE'S CAPACITY (prime-run.sh:149): an image that is already on
  # a loop must keep its size, or the guest sees a stale geometry.
  local cur; cur=$(logvol_loop_of "$img")
  if [ -n "$cur" ]; then
    local have; have=$(( $(stat -c%s "$img") / 1024 / 1024 ))
    [ "$have" = "$mb" ] || { _lv_say "image is on /dev/$cur at ${have}M - keeping that size, not ${mb}M"; mb=$have; }
    # mkfs below rewrites the file in place (same inode, same size): the loop keeps serving it.
    : > "$img"
  else
    rm -f "$img"
  fi
  truncate -s "${mb}M" "$img" || { _lv_say "[ERROR] could not size $img"; return 1; }
  mkfs.fat -F 32 -n "$LOGVOL_LABEL" -i "$(_lv_serial "$id")" "$img" >/dev/null 2>&1 \
    || { _lv_say "mkfs.fat failed on $img"; return 1; }
  local tag; tag=$(mktemp)
  printf 'id=%s\ncreated=%s\nlabel=%s\nfrontend=%s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOGVOL_LABEL" "$LOGVOL_FRONTEND" > "$tag"
  mcopy -i "$img" "$tag" ::/LOGVOL.TAG && mmd -i "$img" ::/qwt-logs || { rm -f "$tag"; _lv_say "[ERROR] could not write LOGVOL.TAG"; return 1; }
  rm -f "$tag"
  _lv_say "created $img (${mb}M, label $LOGVOL_LABEL, serial $(_lv_serial "$id"), id $id)"
  return 0
}

# ----------------------------------------------------------------------------------------------- loop
logvol_loop_of(){ # <img> -> loopN if the image is already on a loop device (READ is unprivileged)
  local img; img=$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")
  losetup -l 2>/dev/null | awk -v f="$img" '$6==f{sub("/dev/","",$1); print $1; exit}'
}

logvol_loop(){ # <img> -> loopN (reused when present; else udisksctl loop-setup, writable - ROOT-FREE here)
  local img="${1:?[ERROR] logvol_loop <img>}" dev
  dev=$(logvol_loop_of "$img")
  if [ -n "$dev" ] && [ -e "/dev/$dev" ]; then printf '%s' "$dev"; return 0; fi
  dev=$(udisksctl loop-setup -f "$img" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
  [ -n "$dev" ] || { _lv_say "udisksctl loop-setup failed for $img"; return 1; }
  printf '%s' "${dev#/dev/}"
}

logvol_loop_release(){ # <loopN>
  local dev="${1:?[ERROR] logvol_loop_release <loopN>}"
  udisksctl loop-delete -b "/dev/$dev" >/dev/null 2>&1 || { _lv_say "[ERROR] could not delete /dev/$dev - free it by hand: udisksctl loop-delete -b /dev/$dev"; return 1; }
}

# ----------------------------------------------------------------------------------------- assignment
logvol_assign(){ # <vm> <loopN> - --required: the assignment is satisfied at domain creation, so the
  # stubdomain's qemu finds /dev/xvdj at start (a PLAIN assignment attaches after creation and qemu
  # aborts the create - measured 2026-09-22, prime-run.sh:226-234). "already assigned" is success.
  local vm="${1:?[ERROR] logvol_assign <vm> <loopN>}" dev="${2:?[ERROR] logvol_assign <vm> <loopN>}" out
  out=$(qvm-device block assign --required -o frontend-dev="$LOGVOL_FRONTEND" -o devtype=disk -o read-only=false \
          "$vm" "$LOGVOL_HOLDER:$dev" 2>&1)
  local rc=$?
  if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -qi 'already assigned'; then
    _lv_say "assign failed for $vm <- $LOGVOL_HOLDER:$dev: $(printf '%s' "$out" | tail -1)"; return 1
  fi
  return 0
}

logvol_unassign(){ # <vm> <loopN>
  local vm="${1:?[ERROR] logvol_unassign <vm> <loopN>}" dev="${2:?[ERROR] logvol_unassign <vm> <loopN>}"
  qvm-device block unassign "$vm" "$LOGVOL_HOLDER:$dev" >/dev/null 2>&1 || { _lv_say "unassign of $LOGVOL_HOLDER:$dev from $vm failed (stale claims make a guest UNSTARTABLE - findings/rig.md)"; return 1; }
}

# -------------------------------------------------------------------------------------- qemu-extra-args
# COMPOSE, NEVER OVERWRITE. qemu-extra-args is ONE feature value; prime-run.sh and reprovision-usb.sh
# set it to the answer stick's controller + device. Writing ours over it would silently drop the
# answer stick from the guest. So: reuse an existing nec-usb-xhci controller (its id is read, not
# assumed), add our own only when there is none, and never touch anything that is not ours. Pure
# functions: string in, string out. The drive carries cache=writethrough - L2 of the durability chain.
logvol_qemu_args_compose(){ # <existing> -> the value with our drive + device added (idempotent)
  local cur="${1:-}" bus
  case " $cur " in *" -drive "*"id=$LOGVOL_DRIVE_ID"*) printf '%s' "$cur"; return 0 ;; esac    # GUARD:idempotent DEFECT: case " $cur " in *"never-matches"*) printf '%s' "$cur"; return 0 ;; esac
  bus=$(printf '%s' "$cur" | grep -oE -- '-device nec-usb-xhci,id=[A-Za-z0-9_]+' | head -1 | sed 's/.*id=//')
  local add=""
  if [ -z "$bus" ]; then bus="$LOGVOL_OWN_BUS"; add="-device nec-usb-xhci,id=$bus "; fi
  add="$add-drive file=/dev/$LOGVOL_FRONTEND,format=host_device,if=none,id=$LOGVOL_DRIVE_ID,cache=$LOGVOL_CACHE -device usb-storage,bus=$bus.0,drive=$LOGVOL_DRIVE_ID,removable=on"   # GUARD:writethrough DEFECT: add="$add-drive file=/dev/$LOGVOL_FRONTEND,format=host_device,if=none,id=$LOGVOL_DRIVE_ID -device usb-storage,bus=$bus.0,drive=$LOGVOL_DRIVE_ID,removable=on"
  if [ -n "$cur" ]; then printf '%s %s' "$cur" "$add"; else printf '%s' "$add"; fi   # GUARD:compose DEFECT: printf '%s' "$add"
}

logvol_qemu_args_strip(){ # <existing> -> the value with our fragments removed (and our controller, if unused)
  local cur="${1:-}" out
  out=$(printf '%s' "$cur" \
    | sed -E "s#-drive file=/dev/[a-z]+,format=host_device,if=none,id=$LOGVOL_DRIVE_ID(,cache=[a-z]+)?##; s#-device usb-storage,bus=[A-Za-z0-9_]+\.0,drive=$LOGVOL_DRIVE_ID,removable=on##")
  if ! printf '%s' "$out" | grep -q "bus=$LOGVOL_OWN_BUS\."; then
    out=$(printf '%s' "$out" | sed -E "s#-device nec-usb-xhci,id=$LOGVOL_OWN_BUS##")
  fi
  printf '%s' "$out" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

logvol_qemu_apply(){ # <vm> - set the composed value on the qube; prints the previous value on stdout
  local vm="${1:?[ERROR] logvol_qemu_apply <vm>}" cur new
  cur=$(qvm-features "$vm" qemu-extra-args 2>/dev/null || true)
  new=$(logvol_qemu_args_compose "$cur")
  qvm-features "$vm" qemu-extra-args -- "$new" >/dev/null || { _lv_say "[ERROR] could not set qemu-extra-args on $vm"; return 1; }
  printf '%s' "$cur"
}

logvol_qemu_remove(){ # <vm>
  local vm="${1:?[ERROR] logvol_qemu_remove <vm>}" cur new
  cur=$(qvm-features "$vm" qemu-extra-args 2>/dev/null || true)
  [ -n "$cur" ] || return 0
  new=$(logvol_qemu_args_strip "$cur")
  if [ -z "$new" ]; then qvm-features --unset "$vm" qemu-extra-args >/dev/null 2>&1 || return 1
  else qvm-features "$vm" qemu-extra-args -- "$new" >/dev/null || return 1; fi
}

# ------------------------------------------------------------------------------------------- manifest
# The campaign manifest records the volume path (plan section 3) so the failure collector can find it
# without the harness that attached it: {"logvol": [{"vm","id","image","loop","frontend","holder",
# "qemu_extra_args_before","attached_utc"}]}. Appended, never rewritten from memory.
logvol_manifest_record(){ # <manifest.json> <vm> <id> <img> <loopN> <qemu-args-before>
  python3 - "$@" <<'PY'
import json, os, sys, time
mf, vm, cid, img, loop, before = sys.argv[1:7]
rec = {}
if os.path.exists(mf):
    try: rec = json.load(open(mf, encoding="utf-8"))
    except ValueError: rec = {}
lst = [e for e in rec.get("logvol", []) if e.get("vm") != vm]
lst.append({"vm": vm, "id": cid, "image": os.path.abspath(img), "loop": loop,
            "frontend": os.environ.get("LOGVOL_FRONTEND", "xvdj"), "holder": os.environ.get("LOGVOL_HOLDER", "win-idd-mgmt"),
            "qemu_extra_args_before": before, "attached_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
rec["logvol"] = lst
os.makedirs(os.path.dirname(os.path.abspath(mf)), exist_ok=True)
json.dump(rec, open(mf, "w", encoding="utf-8"), indent=1)
PY
}

logvol_manifest_lookup(){ # <manifest.json> <vm> <field> -> the recorded value (empty when absent)
  python3 - "$@" <<'PY'
import json, sys
mf, vm, field = sys.argv[1:4]
try:
    for e in json.load(open(mf, encoding="utf-8")).get("logvol", []):
        if e.get("vm") == vm:
            print(e.get(field, "") or ""); break
except (OSError, ValueError):
    pass
PY
}

# --------------------------------------------------------------------------------------------- attach
logvol_attach(){ # <vm> <img> <manifest.json> - BEFORE the guest starts (first boot of an install included)
  local vm="${1:?[ERROR] logvol_attach <vm> <img> <manifest>}" img="${2:?[ERROR] }" mf="${3:?[ERROR] logvol_attach <vm> <img> <manifest>}" dev before cid
  [ -s "$img" ] || { _lv_say "[ERROR] REFUSED: no image at $img (logvol_create first)"; return 2; }
  # NEVER A SEALED GOLDEN. A golden that is booted is not a golden any more (mgmt/golden.sh), and
  # the assignment persists while loop numbers do not - a stale claim makes the guest unstartable.
  if [ -f "$LOGVOL_ROOT/mgmt/goldens/$vm.json" ] && [ "${GOLDEN_UNSEAL:-}" != "$vm" ]; then   # GUARD:seal DEFECT: if false; then
    _lv_say "[ERROR] REFUSED: $vm carries a committed seal (mgmt/goldens/$vm.json) - test cells clone a golden, never attach to it"; return 2
  fi
  cid=$(mcopy -i "$img" ::/LOGVOL.TAG - 2>/dev/null | sed -n 's/^id=//p' | head -1)
  [ -n "$cid" ] || { _lv_say "[ERROR] REFUSED: $img carries no LOGVOL.TAG - not a volume logvol_create made"; return 2; }
  dev=$(logvol_loop "$img") || return 1
  logvol_assign "$vm" "$dev" || return 1
  before=$(logvol_qemu_apply "$vm") || return 1
  logvol_manifest_record "$mf" "$vm" "$cid" "$img" "$dev" "$before" || { _lv_say "manifest $mf not written"; return 1; }
  echo "LOGVOL-ATTACHED vm=$vm id=$cid image=$img loop=$dev frontend=$LOGVOL_FRONTEND cache=$LOGVOL_CACHE manifest=$mf"
}

logvol_detach(){ # <vm> <manifest.json> - AFTER the guest halted (the loop must not go while the guest holds it)
  local vm="${1:?[ERROR] logvol_detach <vm> <manifest>}" mf="${2:?[ERROR] logvol_detach <vm> <manifest>}" dev st rc=0
  dev=$(logvol_manifest_lookup "$mf" "$vm" loop)
  [ -n "$dev" ] || { _lv_say "no logvol recorded for $vm in $mf - nothing to detach"; return 0; }
  logvol_unassign "$vm" "$dev" || rc=1
  logvol_qemu_remove "$vm" || rc=1
  st=$(QTEST_VM="$vm" timeout 25 "$LOGVOL_QTEST" state 2>/dev/null | grep -aoE 'power_state=[A-Za-z]+' | head -1)
  if [ "$st" = "power_state=Halted" ]; then logvol_loop_release "$dev" || rc=1
  else _lv_say "$vm is '${st:-unreadable}', not Halted - /dev/$dev LEFT IN PLACE; free it once the guest is down: udisksctl loop-delete -b /dev/$dev"; fi
  echo "LOGVOL-DETACHED vm=$vm loop=$dev rc=$rc"
  return $rc
}

# ----------------------------------------------------------------------------------------------- pull
logvol_pull(){ # <img> <outdir> - read the volume on the HOST: guest running, wedged or Halted; nothing detached
  # A live read (the guest may be mid-write), exactly like prime-run's marker reads; the listing and
  # the copy are both kept so a short file can be seen for what it is.
  local img="${1:?[ERROR] logvol_pull <img> <outdir>}" out="${2:?[ERROR] logvol_pull <img> <outdir>}" n
  [ -s "$img" ] || { _lv_say "no image at $img"; return 1; }
  mkdir -p "$out/files" || return 1
  mdir -i "$img" -/ ::/ > "$out/listing.txt" 2>"$out/listing.err" || { _lv_say "mdir failed on $img: $(tail -1 "$out/listing.err")"; return 1; }
  mcopy -s -n -Q -i "$img" ::/ "$out/files/" >"$out/mcopy.out" 2>&1 || _lv_say "mcopy reported a problem (partial copy kept): $(tail -1 "$out/mcopy.out")"
  n=$(find "$out/files" -type f | wc -l)
  printf 'image=%s\nread_utc=%s\nfiles=%s\n' "$img" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" > "$out/pull.txt"
  [ "$n" -gt 0 ] || { _lv_say "the volume holds no files"; return 1; }   # GUARD:pullempty DEFECT: true
  echo "LOGVOL-PULLED image=$img files=$n out=$out"
}

# THE TAIL A DIRECTORY ENTRY DOES NOT COVER. A handle without write-through can leave a line's bytes in
# allocated clusters while the recorded size still predates it; mcopy stops at the size. The bytes are
# in the image (L2/L3 above), so a raw scan for log-shaped lines returns them. Everything mcopy
# returned is in here too - salvage.txt is a superset to be diffed against the copy, never the copy.
logvol_salvage(){ # <img> <outdir> -> <outdir>/salvage.txt, prints the count of lines found
  local img="${1:?[ERROR] logvol_salvage <img> <outdir>}" out="${2:?[ERROR] logvol_salvage <img> <outdir>}" n
  [ -s "$img" ] || { _lv_say "no image at $img"; return 1; }
  mkdir -p "$out" || return 1
  # windows-utils lines: [yyyymmdd.hhmmss.mmm-pid:tid-L] or the pre-4.3.33 [date.time.ms-tid-L];
  # EV event records; the BLog/PowerShell '[yyyy-mm-dd hh:mm:ss' shapes. Null bytes and CRs stripped.
  tr -d '\000\r' < "$img" \
    | grep -a -oE '(\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9:]+-[A-Z]\] [^[:cntrl:]]*|EV (NONE|ERR|[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+) [^[:cntrl:]]*|\[[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.]+[^]]*\] [^[:cntrl:]]*)' \
    > "$out/salvage.txt" 2>/dev/null
  n=$(wc -l < "$out/salvage.txt")
  echo "LOGVOL-SALVAGE image=$img lines=$n out=$out/salvage.txt"
}

# --------------------------------------------------------------------------------------- guest binding
logvol_bind_guest(){ # <vm> <id> - push the binder and run it; the LOGVOL-BIND line is the receipt
  local vm="${1:?[ERROR] logvol_bind_guest <vm> <id>}" id="${2:?[ERROR] logvol_bind_guest <vm> <id>}" mode="${LOGVOL_BIND_MODE:-registry}" out line
  [ -f "$LOGVOL_BIND_PS1" ] || { _lv_say "[ERROR] REFUSED: $LOGVOL_BIND_PS1 is missing"; return 2; }
  case "$mode" in registry|junction) ;; *) _lv_say "[ERROR] REFUSED: LOGVOL_BIND_MODE must be registry or junction (got '$mode')"; return 2 ;; esac
  out=$(QTEST_VM="$vm" timeout -k 10 240 "$LOGVOL_QTEST" pushrun "$LOGVOL_BIND_PS1" -Id "$id" -Mode "$mode" 2>&1 | tr -d '\r')
  # KEEP THE WHOLE TRANSCRIPT. This used to report only `tail -2` of it, and on 2026-10-14 both
  # upgrade cells of a full campaign failed here with the entire diagnosis reduced to
  # "  C:\Windows\system32>" - the cmd prompt. The bind failed, the volume stayed empty, those cells
  # kept logging to C:, and the ONE thing that could say why had been thrown away before anyone
  # read it (findings/issues.md LOGVOLBINDUPGRADE). LOGVOL_BIND_OUT names the file; otherwise it
  # goes beside the volume so it is never nowhere.
  local bindlog="${LOGVOL_BIND_OUT:-${LOGVOL_DIR:-scratchpad}/logvol-bind-$vm.transcript}"
  mkdir -p "$(dirname "$bindlog")" 2>/dev/null
  printf '%s\n' "$out" > "$bindlog" 2>/dev/null
  line=$(printf '%s\n' "$out" | grep -a '^LOGVOL-BIND ' | tail -1)
  if [ -z "$line" ]; then
    # Say WHICH failure shape it is, because they need different fixes: a script that never
    # arrived, one that threw, or one that ran and printed nothing.
    local shape="ran and printed no receipt"
    printf '%s' "$out" | grep -qaiE 'cannot find path|does not exist|is not recognized|FileNotFound' && shape="the binder never arrived in QubesIncoming"
    printf '%s' "$out" | grep -qaiE 'Exception|FullyQualifiedErrorId|At line:' && shape="the binder threw"
    _lv_say "no LOGVOL-BIND line from $vm ($shape) - full transcript: $bindlog"
    _lv_say "  [ERROR] first error-shaped line: $(printf '%s' "$out" | grep -aiE 'error|exception|cannot|not recognized|denied' | head -1 | cut -c1-150)"
    return 1
  fi
  echo "$line"
  case "$line" in "LOGVOL-BIND ok "*) return 0 ;; *) return 1 ;; esac
}

logvol_unbind_guest(){ # <vm> - put LogDir and LogSafeFlush back (registry mode) or queue the reverse renames (junction)
  local vm="${1:?[ERROR] logvol_unbind_guest <vm>}" out line
  out=$(QTEST_VM="$vm" timeout -k 10 240 "$LOGVOL_QTEST" pushrun "$LOGVOL_BIND_PS1" -Restore 2>&1 | tr -d '\r')
  line=$(printf '%s\n' "$out" | grep -a '^LOGVOL-BIND ' | tail -1)
  [ -n "$line" ] || { _lv_say "[ERROR] no LOGVOL-BIND line came back from $vm"; return 1; }
  echo "$line"
  case "$line" in "LOGVOL-BIND restored "*) return 0 ;; *) return 1 ;; esac
}
