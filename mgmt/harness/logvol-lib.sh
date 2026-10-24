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
LOGVOL_FRONTEND="${LOGVOL_FRONTEND:-xvdj}"   # ONE stick, on the slot the DIAG stick has always used           # OUR OWN slot: xvdi is the answer stick, xvdj is prime-run's DIAG stick
                                                     # (it was xvdj until 2026-10-14, which collided with the DIAG stick and
                                                     #  is why this volume could not simply be attached on the prime-run path)
LOGVOL_LABEL="${LOGVOL_LABEL:-DIAG}"        # ONE stick: the label the install itself resolves at write time (`vol %d: | findstr /i "DIAG"`)
LOGVOL_SIZE_MB="${LOGVOL_SIZE_MB:-256}"              # a day of module logs is ~0.2 MiB; MSI verbose logs are MBs
LOGVOL_DIR="${LOGVOL_DIR:-$HOME/win-iso/logvol}"     # images live OUTSIDE the repo (never a tracked path)
LOGVOL_ARCHIVE_DIR="${LOGVOL_ARCHIVE_DIR:-$LOGVOL_DIR/archive}"
LOGVOL_BIND_PS1="${LOGVOL_BIND_PS1:-$LOGVOL_LIB_DIR/logvol-bind.ps1}"
LOGVOL_QTEST="${QTEST_BIN:-$LOGVOL_ROOT/tools/qtest}"
LOGVOL_DRIVE_ID="logdrv"                             # our -drive id; the usb-storage device rides on it
LOGVOL_OWN_BUS="logusb"                              # the controller we add when the guest has none
LOGVOL_CACHE="writethrough"                          # L2 of the durability chain - never writeback here

_lv_say(){ echo "logvol: $*" >&2; }

# Guest text is DATA, never part of the line's structure: the guest is untrusted and this logger
# declares severity, so a reply carrying "[ERROR]" or a newline could forge or mask a level for
# tools/sweep-gate.sh. Flatten it, take the brackets away, bound the length.
_lv_guest(){ printf '%s' "$1" | tr -d '\r\n' | tr '[]' '()' | cut -c1-160; }

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
  mkdir -p "$(dirname "$img")" || { _lv_say "[ERROR] could not create the image directory for $img"; return 1; }
  if [ -s "$img" ]; then
    # ARCHIVE BEFORE WIPING (prime-run's rule): the volume's contents are the only evidence a dead
    # cell leaves, and this reformat destroys them. Every set is kept, timestamped, before the wipe.
    local arch="$LOGVOL_ARCHIVE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$id"
    if logvol_pull "$img" "$arch" >/dev/null 2>&1; then _lv_say "previous contents archived to $arch"   # GUARD:archive DEFECT: if false; then :
    else rm -rf "$arch"; _lv_say "[WARN] previous image held nothing readable (no archive made)"; fi
  fi
  # THE LOOP DEVICE CACHES THE BACKING FILE'S CAPACITY (prime-run.sh:149): an image that is already on
  # a loop must keep its size, or the guest sees a stale geometry.
  local cur; cur=$(logvol_loop_of "$img")
  if [ -n "$cur" ]; then
    local have; have=$(( $(stat -c%s "$img") / 1024 / 1024 ))
    [ "$have" = "$mb" ] || { _lv_say "[WARN] image is on /dev/$cur at ${have}M - keeping that size, not ${mb}M"; mb=$have; }
    # mkfs below rewrites the file in place (same inode, same size): the loop keeps serving it.
    : > "$img"
  else
    rm -f "$img"
  fi
  truncate -s "${mb}M" "$img" || { _lv_say "[ERROR] could not size $img"; return 1; }
  mkfs.fat -F 32 -n "$LOGVOL_LABEL" -i "$(_lv_serial "$id")" "$img" >/dev/null 2>&1 \
    || { _lv_say "[ERROR] mkfs.fat failed on $img"; return 1; }
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
  [ -n "$dev" ] || { _lv_say "[ERROR] udisksctl loop-setup failed for $img"; return 1; }
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
    _lv_say "[ERROR] assign failed for $vm <- $LOGVOL_HOLDER:$dev: $(printf '%s' "$out" | tail -1)"; return 1
  fi
  return 0
}

logvol_unassign(){ # <vm> <loopN>
  local vm="${1:?[ERROR] logvol_unassign <vm> <loopN>}" dev="${2:?[ERROR] logvol_unassign <vm> <loopN>}"
  qvm-device block unassign "$vm" "$LOGVOL_HOLDER:$dev" >/dev/null 2>&1 || { _lv_say "[ERROR] unassign of $LOGVOL_HOLDER:$dev from $vm failed (stale claims make a guest UNSTARTABLE - findings/rig.md)"; return 1; }
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

logvol_qemu_args_keep_only_ours(){ # <existing> -> the value with the PRIMING sticks removed and ours kept
  # THE INVERSE OF logvol_qemu_args_strip, and it exists because a harness that finishes priming has
  # to drop the priming sticks WITHOUT dropping this volume, which rides the same controller.
  # WHY A BLANKET UNSET IS WRONG, measured twice on 2026-10-14/15: matrix.sh's clear_prime_leftovers
  # ended with `qvm-features --unset <vm> qemu-extra-args`, which deletes our -drive and usb-storage
  # lines AND the nec-usb-xhci controller they share with the answer stick. qemu-extra-args applies at
  # DOMAIN CREATION, so the running guest keeps its volume and the loss only appears at the cell's
  # next boot - the park/restore - where LogDir still names a drive letter that no longer exists.
  # The visible result was a product FAIL: `agent_log_healthy` false, "no agent log is held open by
  # any process", and the IDD check that reads that log failing with it.
  local cur="${1:-}" out
  [ -n "$cur" ] || { printf ''; return 0; }
  # Drop the answer stick and the DIAG stick by their ids, leaving the controller and ours.
  out=$(printf '%s' "$cur" | sed -E '
    s#-drive file=/dev/[a-z]+,format=host_device,if=none,readonly=on,id=ansdrv##g;
    s#-drive file=/dev/[a-z]+,format=host_device,if=none,id=(ansdrv|diagdrv)##g;
    s#-device usb-storage,bus=[A-Za-z0-9_]+\.0,drive=(ansdrv|diagdrv),removable=on(,bootindex=[0-9]+)?##g')
  # If OUR drive is gone too, there is nothing of ours to keep the controller for.
  case " $out " in
    *"id=$LOGVOL_DRIVE_ID"*) : ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s' "$out" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

# ---- THE ONE WRITER, AND IT REFUSES ON A LIVE DOMAIN -------------------------------------------
# `qemu-extra-args` is read at DOMAIN CREATION and nowhere else. Writing it while a domain is up
# therefore changes NOTHING the running guest can see, while making every later reader believe the
# device set it describes is the one in force - and that is not a theory.
#
# MEASURED, campaign 40134888669: matrix.sh rewrote these args at 22:12:18 to drop the priming
# sticks, "the log volume's device KEPT", against a RUNNING win10-acc. Eight seconds later the bind
# refused with `no_volume_labelled_DIAG_with_LOGVOL.TAG`, and the guest - asked directly - reported
# the 256 MB image as `XENSRC PVDISK bus=SCSI ... parts=0` with no USB disk device at all: the image
# is a partitionless superfloppy FAT, which Windows mounts on REMOVABLE media and not on a fixed
# SCSI disk. The args said one thing and the live domain was another. The campaign aborted on its
# first cell, 11 minutes in. Owner 2026-10-25: "no rewriting arguments on the fly."
#
# So every write goes through here, and it REFUSES unless the domain is Halted or absent. A caller
# that wants a different device set for the graded boots asks for it at a domain boundary, which is
# the only place the request means anything.
# LOGVOL_QEMU_WRITE_LIVE=1 is the single deliberate exemption, for a caller that has proved it wants
# the value changed for the NEXT creation and says so; it is logged at every use.
logvol_qemu_write(){ # <vm> <value|--unset> - the ONLY place qemu-extra-args is written
  local vm="${1:?[ERROR] logvol_qemu_write <vm> <value|--unset>}" val="${2?[ERROR] logvol_qemu_write <vm> <value|--unset>}" st
  st=$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tr -d '\n')
  if [ -n "$st" ] && [ "$st" != Halted ]; then
    if [ "${LOGVOL_QEMU_WRITE_LIVE:-0}" = 1 ]; then
      _lv_say "[WARN] writing qemu-extra-args on $vm while it is $st (LOGVOL_QEMU_WRITE_LIVE=1) - it takes effect at the NEXT domain creation, not now"
    else
      _lv_say "[ERROR] REFUSED: qemu-extra-args on $vm while it is $st - the value is read at DOMAIN CREATION, so this would change nothing the running guest sees while telling every later reader it did (campaign 40134888669 aborted on exactly that). Do it at a domain boundary, or set LOGVOL_QEMU_WRITE_LIVE=1 deliberately."
      return 3
    fi
  fi
  if [ "$val" = --unset ]; then
    qvm-features --unset "$vm" qemu-extra-args >/dev/null 2>&1 \
      || { _lv_say "[ERROR] could not unset qemu-extra-args on $vm"; return 1; }
  else
    qvm-features "$vm" qemu-extra-args -- "$val" >/dev/null 2>&1 \
      || { _lv_say "[ERROR] could not set qemu-extra-args on $vm"; return 1; }
  fi
}

logvol_qemu_apply(){ # <vm> - set the composed value on the qube; prints the previous value on stdout
  local vm="${1:?[ERROR] logvol_qemu_apply <vm>}" cur new
  cur=$(qvm-features "$vm" qemu-extra-args 2>/dev/null || true)
  new=$(logvol_qemu_args_compose "$cur")
  logvol_qemu_write "$vm" "$new" || return 1
  printf '%s' "$cur"
}

logvol_qemu_remove(){ # <vm>
  local vm="${1:?[ERROR] logvol_qemu_remove <vm>}" cur new
  cur=$(qvm-features "$vm" qemu-extra-args 2>/dev/null || true)
  [ -n "$cur" ] || return 0
  new=$(logvol_qemu_args_strip "$cur")
  if [ -z "$new" ]; then logvol_qemu_write "$vm" --unset || return 1
  else logvol_qemu_write "$vm" "$new" || return 1; fi
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
  logvol_manifest_record "$mf" "$vm" "$cid" "$img" "$dev" "$before" || { _lv_say "[ERROR] manifest $mf not written"; return 1; }
  echo "LOGVOL-ATTACHED vm=$vm id=$cid image=$img loop=$dev frontend=$LOGVOL_FRONTEND cache=$LOGVOL_CACHE manifest=$mf"
}

logvol_detach(){ # <vm> <manifest.json> - AFTER the guest halted (the loop must not go while the guest holds it)
  local vm="${1:?[ERROR] logvol_detach <vm> <manifest>}" mf="${2:?[ERROR] logvol_detach <vm> <manifest>}" dev st rc=0
  dev=$(logvol_manifest_lookup "$mf" "$vm" loop)
  [ -n "$dev" ] || { _lv_say "no logvol recorded for $vm in $mf - nothing to detach"; return 0; }
  # UNBIND BEFORE DETACHING, always. logvol_bind_guest points QWT's LogDir at this volume, so
  # taking the volume away without restoring LogDir leaves every module writing to a drive letter
  # that no longer exists. Measured 2026-10-14 on WIN10-clean, where a harness sweep detached the
  # volume mid-cell: `agent_log_healthy` came back false with "no agent log is held open by any
  # process: the agent is not logging", and the IDD check that reads a line out of that log failed
  # with it - a product FAIL manufactured by the instrument. A bind with no matching unbind is the
  # defect; this is the matching unbind. Best-effort on a guest that cannot answer: an unreachable
  # guest cannot be unbound, and that is not a reason to leave the volume attached.
  if logvol_unbind_guest "$vm" >/dev/null 2>&1; then
    _lv_say "LogDir restored on $vm before detaching the volume"
  else
    _lv_say "[WARN] could not restore LogDir on $vm (unreachable?) - if it comes back, its modules log to a volume that is gone"
  fi
  logvol_unassign "$vm" "$dev" || rc=1
  logvol_qemu_remove "$vm" || rc=1
  st=$(QTEST_VM="$vm" timeout 25 "$LOGVOL_QTEST" state 2>/dev/null | grep -aoE 'power_state=[A-Za-z]+' | head -1)
  if [ "$st" = "power_state=Halted" ]; then logvol_loop_release "$dev" || rc=1
  else _lv_say "[WARN] $vm is '${st:-unreadable}', not Halted - /dev/$dev LEFT IN PLACE; free it once the guest is down: udisksctl loop-delete -b /dev/$dev"; fi
  echo "LOGVOL-DETACHED vm=$vm loop=$dev rc=$rc"
  return $rc
}

# ----------------------------------------------------------------------------------------------- pull
logvol_pull(){ # <img> <outdir> - read the volume on the HOST: guest running, wedged or Halted; nothing detached
  # A live read (the guest may be mid-write), exactly like prime-run's marker reads; the listing and
  # the copy are both kept so a short file can be seen for what it is.
  local img="${1:?[ERROR] logvol_pull <img> <outdir>}" out="${2:?[ERROR] logvol_pull <img> <outdir>}" n
  [ -s "$img" ] || { _lv_say "[ERROR] no image at $img"; return 1; }
  mkdir -p "$out/files" || { _lv_say "[ERROR] could not create $out/files"; return 1; }
  mdir -i "$img" -/ ::/ > "$out/listing.txt" 2>"$out/listing.err" || { _lv_say "[ERROR] mdir failed on $img: $(_lv_guest "$(tail -1 "$out/listing.err")")"; return 1; }
  mcopy -s -n -Q -i "$img" ::/ "$out/files/" >"$out/mcopy.out" 2>&1 || _lv_say "[WARN] mcopy reported a problem (partial copy kept): $(_lv_guest "$(tail -1 "$out/mcopy.out")")"
  n=$(find "$out/files" -type f | wc -l)
  printf 'image=%s\nread_utc=%s\nfiles=%s\n' "$img" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" > "$out/pull.txt"
  [ "$n" -gt 0 ] || { _lv_say "[ERROR] the volume holds no files"; return 1; }   # GUARD:pullempty DEFECT: true
  echo "LOGVOL-PULLED image=$img files=$n out=$out"
}

# THE TAIL A DIRECTORY ENTRY DOES NOT COVER. A handle without write-through can leave a line's bytes in
# allocated clusters while the recorded size still predates it; mcopy stops at the size. The bytes are
# in the image (L2/L3 above), so a raw scan for log-shaped lines returns them. Everything mcopy
# returned is in here too - salvage.txt is a superset to be diffed against the copy, never the copy.
logvol_salvage(){ # <img> <outdir> -> <outdir>/salvage.txt, prints the count of lines found
  local img="${1:?[ERROR] logvol_salvage <img> <outdir>}" out="${2:?[ERROR] logvol_salvage <img> <outdir>}" n
  [ -s "$img" ] || { _lv_say "[ERROR] no image at $img"; return 1; }
  mkdir -p "$out" || { _lv_say "[ERROR] could not create $out"; return 1; }
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
    _lv_say "[ERROR] no LOGVOL-BIND line from $vm ($shape) - full transcript: $bindlog"
    _lv_say "  [ERROR] first error-shaped line: $(_lv_guest "$(printf '%s' "$out" | grep -aiE 'error|exception|cannot|not recognized|denied' | head -1)")"
    return 1
  fi
  echo "$line"
  case "$line" in
    "LOGVOL-BIND ok "*) return 0 ;;
    *) _lv_say "[ERROR] the binder refused: $(_lv_guest "$line")"; return 1 ;;
  esac
}

logvol_unbind_guest(){ # <vm> - put LogDir and LogSafeFlush back (registry mode) or queue the reverse renames (junction)
  local vm="${1:?[ERROR] logvol_unbind_guest <vm>}" out line
  out=$(QTEST_VM="$vm" timeout -k 10 240 "$LOGVOL_QTEST" pushrun "$LOGVOL_BIND_PS1" -Restore 2>&1 | tr -d '\r')
  line=$(printf '%s\n' "$out" | grep -a '^LOGVOL-BIND ' | tail -1)
  [ -n "$line" ] || { _lv_say "[ERROR] no LOGVOL-BIND line came back from $vm"; return 1; }
  echo "$line"
  case "$line" in
    "LOGVOL-BIND restored "*) return 0 ;;
    *) _lv_say "[ERROR] the binder did not restore: $(_lv_guest "$line")"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------- the evidence path, PROVEN
# WHY THIS EXISTS. Four acceptance campaigns in a row were graded on an evidence path that was not
# working, and each time the harness found out AFTER the cells had been scored: the sweep read a
# LogDir nothing wrote to; the clause blamed a shell variable; crop-before-map searched a hard-coded
# Q:\Qubes Logs; the binder reported "no volume" for a volume that was attached and host-readable
# but carried no drive LETTER (Win32_LogicalDisk lists only lettered volumes). Four instances of ONE
# defect - the evidence path is ASSUMED, never proven - so fixing each instance only bought the next
# one. On 2026-10-20 that cost the first wedge captured since the stall fix: the guest went SPIN
# with no log volume bound, so nothing from inside it survived.
#
# The proof is end to end and it is the guest's OWN LogDir, resolved the way the product resolves
# it (the per-module key first, then the root - log.c:358 / CfgOpenKey), never a path this harness
# believes in. The guest writes a nonce there; this qube reads the IMAGE with mtools - no guest
# needed, which is the whole point of the volume - and looks for that nonce. Only both halves
# passing proves a cell can produce evidence. Either half failing says WHICH half, because "no
# evidence" with no side named is what sent three investigations at the wrong component.
logvol_clear_guest(){ # <vm> - REMOVE LogDir so the product falls to its own default
  # WHY REMOVE AND NOT REWRITE. An AppVM inherits its registry from the template, whose root is the
  # churn subject's park, so it boots believing LogDir=<letter>:\qwt-logs\<churn>. MEASURED on all
  # six appvm boots of run 39476792836: `found=D: letter=pinned` - Windows letters the volume D: at
  # boot and the bind pins Z: AFTERWARDS, so at the moment the boot-time modules start, the
  # inherited value names a letter that does not exist. log.c:256 CreateDirectory fails and :289's
  # fallback is stderr only: NO FILE. Both cells produced zero agent-family logs on every boot.
  # With no value at all, log.c:236-253 builds "<system drive>\Qubes Logs" and CREATES it - no
  # letter, no inheritance - and the collector searches that path as of 9e314357.
  # The per-boot bind still runs and still governs modules that start LATER (qrexec-wrapper per
  # call, file-receiver per transfer), which is why those two are the only logs on an appvm stick
  # today. Clearing costs nothing that exists: no agent-family log has ever been on one.
  local vm="${1:?[ERROR] logvol_clear_guest <vm>}" out line
  out=$(QTEST_VM="$vm" timeout -k 10 240 "$LOGVOL_QTEST" pushrun "$LOGVOL_BIND_PS1" -Clear 2>&1 | tr -d '\r')
  line=$(printf '%s\n' "$out" | command grep -aE '^LOGVOL-BIND ' | tail -1)
  case "$line" in
    "LOGVOL-BIND cleared "*) echo "$line"; return 0 ;;
    *) _lv_say "[ERROR] the binder did not clear LogDir: $(_lv_guest "${line:-no LOGVOL-BIND line: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-160)}")"; return 1 ;;
  esac
}

logvol_prove_roundtrip(){ # <vm> <img> [tag] [--require-agent-logs] -> LOGVOL-PROOF ok|fail
  # THE NONCE IS NOT THE PROPERTY. With --require-agent-logs the proof additionally requires that
  # the AGENT FAMILY has written into the directory the product resolves - which is the thing a
  # campaign depends on and the thing the nonce cannot see. Pass it at the PRE-GRADING call site,
  # not at the bind: a bind takes effect at a module's NEXT start, so zero agent logs immediately
  # after a bind is correct and expected. Before the pull it is a blind cell.
  local vm="${1:?[ERROR] logvol_prove_roundtrip <vm> <img> [tag] [--require-agent-logs]}" img="${2:?[ERROR] logvol_prove_roundtrip <vm> <img> [tag]}"
  local tag="${3:-proof}" nonce ps out line dir seen tmp agentlogs require_agent=0
  case " $* " in *" --require-agent-logs "*) require_agent=1 ;; esac
  nonce="LVPROOF-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  tmp=$(mktemp -d) || { _lv_say "[ERROR] no temp dir"; return 2; }
  ps="$tmp/logvol-proof.ps1"
  cat > "$ps" <<'PSEOF'
param([string]$Nonce = 'LVPROOF')
$ErrorActionPreference = 'Continue'
# the product's own resolution order: the per-module key, then the root. Never a path we chose.
$dir = $null
foreach ($k in @('HKLM:\Software\Invisible Things Lab\Qubes Tools\gui-agent','HKLM:\Software\Invisible Things Lab\Qubes Tools')) {
  try { $v = (Get-ItemProperty -Path $k -Name LogDir -ErrorAction Stop).LogDir } catch { $v = $null }
  if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $dir = [string]$v; break }
}
if (-not $dir) { Write-Output 'LOGVOL-PROOF-GUEST fail reason=no_LogDir_in_registry'; exit 1 }
if (-not (Test-Path -LiteralPath $dir)) { Write-Output ("LOGVOL-PROOF-GUEST fail reason=LogDir_does_not_exist dir=" + $dir); exit 1 }
try {
  $p = Join-Path $dir ($Nonce + '.proof')
  Set-Content -LiteralPath $p -Value $Nonce -Encoding ASCII -ErrorAction Stop
  # flush: a file in a cache the host cannot see yet is not evidence
  try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'None'); $fs.Close() } catch { }
  # AND COUNT WHAT THE AGENT FAMILY ACTUALLY WROTE HERE. The nonce proves only that THIS process
  # can write to the directory THIS process resolved, a moment after the bind. The agent family
  # resolved its own LogDir at ITS OWN START, which on an AppVM is BEFORE the bind and from a
  # registry the volatile root has since discarded - so it can be logging nowhere while the nonce
  # round-trips perfectly. That is why LOGVOLBINDLATE survived eight days and five fixes with
  # "18 proofs, 0 blind cells" on the record: the proof measured the prover.
  $agent = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '(?i)^(gui-agent|gui-watchdog|qrexec-agent|qubesdb)' })
  # A NAME IS NOT A WRITE. Counting files whose name matches the agent family says only that such a
  # file EXISTS - and in a cell that reboots more than once, a log left by an EARLIER boot satisfies
  # that while the boot being graded writes nowhere. That reproduces the very defect the count was
  # added to catch, one layer deeper; found by the component re-grade, 2026-10-21, hours after the
  # count went in.
  # TWO ANCHORS, both read INSIDE the guest so a host/guest clock skew cannot enter: written since
  # THIS boot, and - the stronger one - currently held OPEN by someone. Opening with share None
  # fails exactly when another handle is on the file, which is what "the agent is writing here now"
  # looks like from outside the agent.
  # The gate is on FRESH, not on OPEN: a log that is appended and closed between writes would make
  # an open-handle gate flap. agentopen is reported as the stronger evidence, not demanded.
  # THE ONE WAY A STALE LOG COULD LOOK FRESH is the bind's own copy of the old directory onto the
  # volume. It cannot: logvol-bind.ps1 copies with `robocopy /E`, whose default /COPY:DAT carries
  # Timestamps, so a log written on an earlier boot arrives with its original LastWriteTime. That
  # default is load-bearing for this gate - tools/tests/logvol-lib-selftest.sh asserts the bind
  # never passes a /COPY: that drops T.
  # LVFRESH-A  (to the B marker: extracted and executed under pwsh by
  # tools/tests/logvol-lib-selftest.sh; neither marker names the other)
  # ANCHOR ON THE PID, NEVER ON A CLOCK. The first version of this compared each file's
  # LastWriteTime against Win32_OperatingSystem.LastBootUpTime - two readings of a guest clock that
  # THIS RIG CORRECTS BY 10800 SECONDS on every boot after the first (timezone=localtime, the guest
  # reads a dom0-local RTC as UTC and the puller corrects it; logvol-lib's own header records
  # clock_boot_correction_s = 10800). Files written before the correction carry pre-correction
  # stamps while the recomputed boot time sits three hours later, so EVERY file reads as older than
  # its own boot and agentfresh came back 0 on a volume that held 260 fresh lines.
  # MEASURED 2026-10-21, the hard way: that false 0 aborted a release campaign in cell 1. The
  # collected evidence settled it - the volume's gui-agent log carried pid 3904 with LifecycleStart
  # at 21:34:19, a NEW process in the graded boot, while the install boot's agent was pid 3976.
  # The standing rule names this exactly: anchor freshness on the pid the process wrote plus an open
  # handle, never on a clock. The comment that replaced this said a host/guest skew could not enter
  # because both reads were inside the guest; the skew is INSIDE the guest, across the correction.
  # SO: a log is FRESH when its own tail carries a pid that is RUNNING NOW. No clock is consulted.
  # THE BOUND: a pid could in principle be reused by another agent-family process across a boot.
  # It must be reused by one of THESE names and appear in THIS file's tail, which is far narrower
  # than a three-hour clock jump that fires every time.
  $live = @{}
  foreach ($pr in (Get-Process -ErrorAction SilentlyContinue)) {
    if ($pr.Name -match '(?i)^(gui-agent|gui-watchdog|qrexec-agent|qubesdb)') { $live[[int]$pr.Id] = $true }
  }
  # FileShare.ReadWrite because the writers hold their logs open - the collector reads them the same
  # way; Get-Content would throw on a locked file and make every file look stale.
  $fresh = @($agent | Where-Object {
    $hit = $false
    try {
      $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
      try {
        if ($fs.Length -gt 8192) { [void]$fs.Seek(-8192, 'End') }
        $sr = New-Object IO.StreamReader($fs)
        foreach ($ln in $sr.ReadToEnd() -split "`n") {
          if ($ln -match '-(\d+):\d+-[IWEDV]\]' -and $live[[int]$Matches[1]]) { $hit = $true; break }
        }
      } finally { $fs.Close() }
    } catch { }
    $hit
  })
  $open = 0
  foreach ($f in $fresh) {
    try { $h = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $h.Close() } catch { $open++ }
  }
  # LVFRESH-B
  Write-Output ("LOGVOL-PROOF-GUEST ok dir=" + $dir + " agentlogs=" + $agent.Count +
                " agentfresh=" + $fresh.Count + " agentopen=" + $open + " file=" + $p)
} catch { Write-Output ("LOGVOL-PROOF-GUEST fail reason=write_failed dir=" + $dir); exit 1 }
PSEOF
  out=$(QTEST_VM="$vm" timeout -k 10 180 "$LOGVOL_QTEST" pushrun "$ps" -Nonce "$nonce" 2>&1 | tr -d '\r')
  line=$(printf '%s\n' "$out" | command grep -aE '^LOGVOL-PROOF-GUEST ' | tail -1)
  rm -rf "$tmp"
  case "$line" in
    "LOGVOL-PROOF-GUEST ok"*)
      dir=$(printf '%s' "$line" | sed -E 's/.* dir=(.*) agentlogs=.*/\1/')
      agentlogs=$(printf '%s' "$line" | sed -E 's/.* agentlogs=([0-9]+).*/\1/')
      # A FIELD THAT DID NOT PARSE IS NOT A ZERO AND NOT A PASS. sed leaves the line untouched when
      # it does not match, so an unparsed count would arrive here as the whole line and -eq would
      # error out mid-grade; anything that is not digits becomes MISSING and fails below.
      agentfresh=$(printf '%s' "$line" | sed -E 's/.* agentfresh=([0-9]+).*/\1/')
      agentopen=$(printf '%s' "$line" | sed -E 's/.* agentopen=([0-9]+).*/\1/')
      case "$agentfresh" in ''|*[!0-9]*) agentfresh=MISSING ;; esac
      case "$agentopen" in ''|*[!0-9]*) agentopen=MISSING ;; esac ;;
    "LOGVOL-PROOF-GUEST fail"*)
      echo "LOGVOL-PROOF fail half=guest ${line#LOGVOL-PROOF-GUEST fail }"; return 1 ;;
    *)
      # no line at all: the guest never answered, which is itself the finding and is NOT a volume fault
      echo "LOGVOL-PROOF fail half=guest reason=no_answer_from_guest (transcript: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200))"; return 1 ;;
  esac
  # HOST HALF: read the IMAGE, not the guest. mdir works while the guest runs and while it is wedged.
  seen=$(mdir -i "$img" -/ ::/ 2>/dev/null | command grep -ac "$nonce")
  if [ "${seen:-0}" -gt 0 ]; then
    # THE NONCE MADE IT. That is the writable-path half. Now the half that matters.
    if [ "$require_agent" = 1 ] && [ "$agentfresh" = MISSING ]; then
      echo "LOGVOL-PROOF fail half=agent reason=agentfresh_not_reported_by_the_guest_probe dir=$dir agentlogs=${agentlogs:-NA} nonce_roundtripped=1 img=$img"
      echo "  the guest answered without the freshness field, so whether the agent wrote anything THIS" >&2
      echo "  boot is unknown. Missing data fails - that is the whole reason the field exists." >&2
      return 1
    fi
    # FRESH, NOT PRESENT. The gate was on agentlogs, the count of files whose NAME matches the agent
    # family, so a log left by an earlier boot of the same cell satisfied it while this boot wrote
    # nowhere - the proof measuring the prover again, one layer down (re-grade, 2026-10-21).
    if [ "$require_agent" = 1 ] && [ "${agentfresh:-0}" -eq 0 ]; then
      echo "LOGVOL-PROOF fail half=agent reason=no_agent_family_log_written_since_this_boot dir=$dir agentlogs=${agentlogs:-NA} agentfresh=0 agentopen=${agentopen:-NA} nonce_roundtripped=1 img=$img"
      echo "  the path is writable and the nonce came back, so the VOLUME is fine - what is missing is the" >&2
      echo "  product's own log. The agent family resolved its LogDir at its start, which is BEFORE this" >&2
      echo "  bind, and on an AppVM from a registry the volatile root has since discarded. Grading this" >&2
      echo "  cell would read a capture that cannot contain an agent error (LOGVOLBINDLATE)." >&2
      return 1
    fi
    echo "LOGVOL-PROOF ok dir=$dir nonce=$nonce seen_in_image=1 agentlogs=${agentlogs:-NA} agentfresh=${agentfresh:-NA} agentopen=${agentopen:-NA}"
    return 0
  fi
  echo "LOGVOL-PROOF fail half=host reason=nonce_written_by_guest_not_in_image dir=$dir nonce=$nonce img=$img"
  return 1
}
