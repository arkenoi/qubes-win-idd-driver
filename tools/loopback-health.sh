#!/bin/bash
# loopback-health.sh - the state of THIS qube's block-backend side, in one read.
#
# WHY IT EXISTS: on 2026-09-21 a provisioning failure was diagnosed for a day and a half without
# anyone once looking at the loop devices or at the Xen block BACKEND this qube runs for the guests.
# The owner's point, 2026-09-22: "you did not even check health of loopback block devices". Every
# read here is unprivileged and passive, so it is safe next to a live job and can be taken AT THE
# MOMENT OF FAILURE - which is the only moment it is worth anything.
#
#   tools/loopback-health.sh [loopN ...]     (default: every loop with a backing file)
#
# WHAT TO LOOK AT, in order:
#   backing file present and not (deleted)   - a recycled loop is the documented stale-claim trap
#   READ-BACK ok                             - proves the device still serves I/O, not just exists
#   xen-backend vbd entries + their state    - 4=connected; anything stuck below 4 is a BACKEND that
#                                              never completed the handshake, which is what a
#                                              stubdomain waiting for /dev/xvdX looks like from here
#   inflight                                 - non-zero with no traffic means requests are parked
set -u
cd "$(dirname "$0")/.." 2>/dev/null || true
say(){ printf '%s\n' "$*"; }
DOMID=$(xenstore-read domid 2>/dev/null || echo '?')
say "=== loopback + block-backend health $(date -u +%Y-%m-%dT%H:%M:%SZ)  (this qube domid=$DOMID)"

LOOPS=("$@")
if [ ${#LOOPS[@]} -eq 0 ]; then
    mapfile -t LOOPS < <(losetup -l --noheadings -O NAME,BACK-FILE 2>/dev/null | awk '$2!=""{sub("/dev/","",$1);print $1}')
fi
say "--- loop devices (${#LOOPS[@]})"
for l in ${LOOPS[@]+"${LOOPS[@]}"}; do
    d=/sys/block/$l
    [ -d "$d" ] || { say "  $l: NO sysfs node - the device does not exist"; continue; }
    bf=$(cat "$d/loop/backing_file" 2>/dev/null)
    ro=$(cat "$d/ro" 2>/dev/null); sz=$(cat "$d/size" 2>/dev/null)
    inflight=$(cat "$d/inflight" 2>/dev/null)
    # A device that exists but cannot serve a read is the failure mode a listing cannot show.
    # /dev/loopN is root:disk 0660 and this account is in neither, so a plain read fails with
    # EACCES - which is NOT ill health. Distinguish it, or the probe reports a permission as a
    # fault, which is the exact class of defect this file exists to stop.
    err=$(dd if="/dev/$l" of=/dev/null bs=4096 count=1 iflag=direct status=none 2>&1); drc=$?
    if [ $drc = 0 ]; then rb=ok
    else
      err2=$(dd if="/dev/$l" of=/dev/null bs=4096 count=1 status=none 2>&1); drc2=$?
      if [ $drc2 = 0 ]; then rb=ok-buffered
      elif printf '%s' "$err$err2" | grep -qi "permission denied"; then rb="n/a-not-in-disk-group"
      else rb="FAILED: $(printf '%s' "$err2" | tr '\n' ' ' | cut -c1-60)"; fi
    fi
    say "  $l ro=$ro sectors=$sz readback=$rb inflight=[${inflight:-?}]"
    say "      backing=${bf:-<none>}"
    case "$bf" in *'(deleted)'*) say "      *** BACKING FILE DELETED - any claim on this loop is stale ***" ;; esac
done

say "--- xen block backends this qube is serving"
found=0
for e in /sys/bus/xen-backend/devices/vbd-*; do
    [ -e "$e" ] || continue
    found=1
    n=$(basename "$e"); st=$(cat "$e/state" 2>/dev/null)
    # sysfs prints the WORD (Connected/InitWait/...); xenstore prints the number. Accept both.
    case "$st" in
      4|Connected)            w="connected" ;;
      1|Initialising)         w="INITIALISING - handshake never completed" ;;
      2|InitWait)             w="INIT-WAIT - waiting for the frontend" ;;
      3|Initialised)          w="INITIALISED" ;;
      5|6|Closing)            w="closing" ;;
      7|Closed)               w="closed" ;;
      *)                      w="UNKNOWN state string - read it, do not assume health" ;;
    esac
    dom=${n#vbd-}; dom=${dom%%-*}
    say "  $n -> domain $dom  state=$st ($w)"
done
[ "$found" = 1 ] || say "  none - this qube is serving no block device to any domain right now"

say "--- xenstore backend tree (authoritative on which DOMAIN each device serves)"
t=$(xenstore-ls -f "/local/domain/$DOMID/backend" 2>/dev/null)
if [ -n "$t" ]; then printf '%s\n' "$t" | sed 's/^/  /'; else say "  (empty - no backend entries)"; fi

say "--- module state"
say "  xen-blkback loaded: $(grep -qw xen_blkback /proc/modules && echo yes || echo 'no (built in or absent)')"
say "  loop devices in use: $(losetup -l --noheadings 2>/dev/null | wc -l); free minors: $(( $(ls /dev/loop[0-9]* 2>/dev/null | wc -l) - $(losetup -l --noheadings 2>/dev/null | wc -l) ))"
