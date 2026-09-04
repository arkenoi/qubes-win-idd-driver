#!/bin/bash
# INSTALL/UPGRADE MATRIX - RELEASE-PACKAGE-ONLY (owner model, 2026-09-03).
#
# THE ONE RULE THAT SHAPES EVERY CELL: our code enters a guest ONLY from the release package.
# Owner: "the only source of our code for e2e testing is RELEASE PACKAGES, nothing else. no swap
# fuckery is ever permitted." The old cells pushed a payload tarball (push_payload q4315 - a
# stale 4.3.15 tree) over qrexec and ran install.cmd from the pushed copy; that pattern is GONE
# and must never come back. The two channels that remain, both carrying the published artifact:
#
#   PRISTINE entry   -> mgmt/harness/prime-run.sh <base> <subject> ours --payload $RELEASE_SETUP
#                       (a pristine guest has no qrexec; the primer stick is the only way in,
#                       and the payload it carries IS the release setup tree)
#   INSTALLED entry  -> the release ISO presented as a CD at BOOT (qvm-start --cdrom=..., the
#                       rig's proven ISO path - mgmt/reprovision-usb.sh boots the vendor ISO the
#                       same way; live block attach gets "empty response from qubesd" here), then
#                       <CD>:\install.cmd run from the disc over qrexec - delivering the README's
#                       "attach as a CD and run install.cmd elevated"
#
# THE CELLS:
#   clean       prime-run from the pristine base (win10-base/win11-base, the ONLY sealed
#               goldens). Bases carry testsigning OFF, so this is inherently the TRUE two-stage
#               path (stage 1, reboot, stage 2) - the old fresh/1stage/2stage constructions are
#               retired: they required a qrexec-carrying golden plus a pushed tarball, i.e. both
#               forbidden things at once. Ends by PARKING the installed state (see below).
#   reinstall   unpark the 'installed' snapshot -> same-version reinstall from the release ISO.
#   upgrade     reclone a previous-ours fixture (e.g. win10-iqi, shipped 4.3.17) -> release ISO
#               over it (in-place MSI major upgrade).
#   seeded      the field's state (armed xenbus_monitor + PV reboot Request mid-MSI) over an
#               existing install, from the release ISO.
#   stock       CAPABILITY ONLY, never a default cell (owner: never re-test stock per campaign):
#               reclone a stock-4.2.2 fixture built on demand by prime-run job stock-422, then
#               release ISO over it.
#   appvm       restore the 'installed' park into the TEMPLATE (volume restore), derive an
#               AppVM from it, cold boot it.
#   grade       grade-only battery against an already-installed guest (unchanged).
#
# TARGET MODEL (matrix-4318 lesson, 2026-09-03). The install cells (clean/reinstall/upgrade/
# seeded/stock) churn a DISPOSABLE per-OS StandaloneVM - win10-acc / win11-acc - that NOTHING
# depends on. They used to target win10-tpl/win11-tpl, but those are TemplateVMs with
# win10-app/win11-app bound to them, and prime-run RECREATES its target (qvm-remove +
# qvm-create), which dom0 refuses while an AppVM depends on the name: "prime-run TERMINAL:
# could not create win10-tpl", cascading into reinstall ("no restorable 'installed' park").
# prime-run creates the churn subject itself; the reclone-entry cells create it on first use
# (ensure_churn_target). The templates are touched ONLY by the appvm cell, and only by VOLUME
# restore (checkpoint.sh unpark <tpl> installed <acc> - a clone of the park's volumes, legal on
# a template with dependents), never by a recreate.
#
# SNAPSHOTS ARE THE OPTIMIZATION (owner 2026-09-01: "we do snapshots for optimizations"): the
# release is installed ONCE per OS per campaign - by the clean cell, which parks the installed
# state via mgmt/harness/checkpoint.sh (park <vm> installed, ~2 s). Every cell that merely needs
# "a guest carrying the release" unparks that snapshot instead of reinstalling. Only genuinely
# different entry states provision themselves: clean (prime-run from pristine) and
# upgrade/seeded/stock (reclone of a QWT-carrying fixture). Remove parks at campaign end
# (qvm-remove ckpt-<vm>-installed); NEVER park a golden (checkpoint.sh refuses anyway).
#
# Each cell states its own verdict. Cells are selected with CELLS="..." and run SERIALLY -
# concurrent VM-mutating jobs reboot each other, which has destroyed results here before.
set -uo pipefail
cd /home/user/qubes-win-idd-driver
# e2e-lib.sh hard-stops if QTEST_VM is unset, deliberately: a DEFAULT target once routed a whole
# run at whatever qube it named, and dom0 refuses an unknown target by writing nothing - which
# reads exactly like "the guest has no windows". That guard is correct and is not weakened here.
#
# Every guest call in this file sets QTEST_VM=$vm explicitly on the command, so the ambient value
# is never used for real work. It is set to a name that CANNOT exist so the guard is satisfied
# without inventing a default: if any call ever forgets its per-call target, qtest refuses the
# invalid name loudly instead of quietly operating on a real guest.
export QTEST_VM="${QTEST_VM:-__matrix_no_ambient_target__}"
source .claude/skills/win-guest-e2e/e2e-lib.sh
# P0-PRE (protocol H0): the wait primitives are sourced from the REPO, not from a session tmp
# directory. They used to live under /home/user/.claude/jobs/<id>/tmp, which is session-scoped and
# garbage-collectable - the same class of mistake that once nearly lost the only copy of a
# matrix's evidence. A harness whose wait library can vanish between campaigns is not a harness.
source "$(dirname "${BASH_SOURCE[0]}")/e2e-wait.sh"

# Results directory. It used to be hardcoded to a Claude session tmp
# (/home/user/.claude/jobs/<id>/tmp/matrix) — session-scoped and garbage-collectable, which is how
# the only copy of the 2026-08-28 matrix evidence came within a GC of being lost, and why the cell
# logs now live in evidence/2026-08-29-fresh-cell-contamination/. Default somewhere durable and let
# a caller override; never write a run's only record to a path that disappears with the session.
M="${MATRIX_OUT:-$HOME/qwt-matrix/$(date -u +%Y%m%d-%H%M%S)}"; mkdir -p "$M"
R=$M/matrix.log; : > "$R"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$R"; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); say "PASS  $*"; }
no(){ FAIL=$((FAIL+1)); say "FAIL  $*"; }
# qvm-start BLOCKS until qrexec connects (up to qrexec_timeout). On a guest that never boots
# that is dead silence for the whole timeout - measured today: 15 minutes of a harness that
# looked hung was simply sitting inside qvm-start. Fire it and poll the state ourselves.
start_vm(){ timeout -k 10 150 qvm-start "$1" >/dev/null 2>&1 & disown; sleep 8; }

GLOG='C:\qwt-improved-install.log'
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

# H3.6 ENFORCEMENT: exactly one Windows guest up at a time, structurally rather than by discipline.
# Cells never shut their target down when they finish, and reclone only halts its OWN target - so a
# cell list that crosses an OS boundary (…win10-stock win11-1stage…) leaves the previous guest
# RUNNING while the next one starts. Audit finding RB-05: 3 of the 6 cells in the documented example
# list did exactly that. Concurrent runs have destroyed each other's results here before, and three
# 8 GB guests starved qubesd. ACPI only - a killed guest leaves a dirty volume that blocks the next
# clone, which is the same reason reclone refuses to kill.
_halt_other_windows(){ # $1=the guest this cell is about to use
  local keep=$1 v
  for v in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | grep -E '^win1' | grep -v '|Halted' | cut -d'|' -f1); do
    [ "$v" = "$keep" ] && continue
    say "  H3.6: halting $v before working on $keep"
    qvm-shutdown --wait --timeout 300 "$v" >/dev/null 2>&1
    echo "$(qvm-ls --raw-data --fields STATE "$v" 2>/dev/null | tail -1)" | grep -qi Halted \
      || say "  WARNING: $v did not halt - refusing to run two Windows guests is now unenforceable"
  done
}

reclone(){ # $1=golden $2=target
  local g=$1 t=$2
  _halt_other_windows "$t"
  # NEVER KILL. Measured 2026-08-28: a guest sitting in the Windows recovery screen honours ACPI
  # shutdown and halts in 10 s, so the kill bought nothing - and it COST the next step, because a
  # killed guest leaves its volume dirty and qubesd then refuses the clone outright:
  #   "Cannot import to dirty volume qubes_dom0/vm-win10-tpl-private - start and stop a qube to
  #    cleanup"
  # which is how a cell that had already reproduced the bug failed with "could not reclone".
  if [ "$(w_state "$t")" != Halted ]; then
    qvm-shutdown "$t" >/dev/null 2>&1
    if ! w_halt "$t" 420 "shutdown-$t" say; then
      say "  $t ignored ACPI shutdown for 420 s (screen=$(w_screen "$t" "stuck-$t" "$M")) - killing as the last resort"
      qvm-kill "$t" >/dev/null 2>&1
      w_halt "$t" 120 "kill-$t" say >/dev/null 2>&1
      say "  NOTE: a killed guest leaves a dirty volume; the clone below may need the start/stop cycle"
    fi
  fi
  # Keep the error text. "could not reclone" told me nothing; the real message named the cause
  # exactly (dirty volume after a kill) and pointed straight at the fix.
  local cerr
  cerr=$(python3 - "$g" "$t" 2>&1 <<'EOF'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
dst.virt_mode='hvm'; dst.kernel=''
dst.memory=8192; dst.maxmem=0; dst.vcpus=4; dst.qrexec_timeout=600
EOF
  ) || { say "  clone attempt 1 FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"; }

  # RETRY WITH RECOVERY, up to three more times. A guest that was killed - or one that bricked and
  # never completed startup - leaves its volumes dirty and qubesd refuses the import. The error
  # names the remedy ("start and stop a qube to cleanup") and it works, but ONE cycle is not
  # always enough: measured 2026-08-28, the first retry cleared -root and then failed on
  # -private, and the single-shot version reported "could not reclone" on a rig that was one more
  # cycle from fine. A bricked guest never reaches Running, so the loop does not require it to.
  local att i
  for att in 2 3 4; do
    echo "$cerr" | grep -qa 'dirty volume' || break
    # REVERT, don't cycle. The documented remedy ("start and stop a qube to cleanup") assumes the
    # guest can BOOT - and the guests that dirty their volumes here are exactly the ones that
    # cannot: bricked, ignoring ACPI for 420 s, then killed. That cycle burned ~10 minutes per
    # attempt and still failed. admin.vm.volume.Revert is policied, needs no boot, and clears the
    # dirty state in seconds (measured 2026-08-28: revert root+private -> clone OK immediately).
    say "  dirty volume - reverting root+private to their last snapshot (clone attempt $att)"
    if [ "$(w_state "$t")" != Halted ]; then
      qvm-shutdown "$t" >/dev/null 2>&1
      w_halt "$t" 120 "revert-halt-$t" say >/dev/null 2>&1 || { qvm-kill "$t" >/dev/null 2>&1; sleep 10; }
    fi
    local v rev
    for v in root private; do
      rev=$(printf '' | timeout 15 qrexec-client-vm "$t" admin.vm.volume.ListSnapshots+$v 2>/dev/null | tr -d '\0' | tr ' ' '\n' | grep -a 'back' | head -1)
      [ -n "$rev" ] || { say "    no snapshot for $v - cannot revert"; continue; }
      printf '%s' "$rev" | timeout 60 qrexec-client-vm "$t" admin.vm.volume.Revert+$v >/dev/null 2>&1
      say "    reverted $v to $rev"
    done
    cerr=$(python3 - "$g" "$t" 2>&1 <<'EOF'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
dst.virt_mode='hvm'; dst.kernel=''
dst.memory=8192; dst.maxmem=0; dst.vcpus=4; dst.qrexec_timeout=600
EOF
) && { cerr=''; break; }
    say "  clone attempt $att FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"
  done
  [ -z "$cerr" ] || { say "  clone FAILED after every retry"; return 1; }
  say "  cloned $g -> $t"
}

# ------------------------------------------------------------------- release delivery + snapshots
# push_payload is GONE. Pushing a payload tarball and running install.cmd from the pushed tree is
# the forbidden pattern (owner: "no swap fuckery is ever permitted") - it let a stale 4.3.15 tree
# stand in for the release under test. Instruments (reboot-dialog-watch.ps1, health-check.ps1,
# uninstall/count scripts) may still be pushed: they are the harness, not the product. The PRODUCT
# only ever arrives via prime-run's primer stick or the release ISO presented as a CD at boot
# (qvm-start --cdrom; see boot_with_release_iso below).

ensure_release_loop(){ # resolves RELEASE_LOOP (loopN on THIS qube backing the release ISO)
  # Accepts an operator-provided RELEASE_LOOP, or RELEASE_ISO (a path), which is loop-set up
  # read-only via udisksctl - proven root-free on this rig (the "needs sudo losetup" blocker was
  # invented; findings/install.md [verified 2026-08-29]). Protocol 0.5 Route A requires the loop
  # to be backed by the intended file and NOT "(deleted)", or the guest reads a stale disc.
  if [ -z "${RELEASE_LOOP:-}" ]; then
    [ -n "${RELEASE_ISO:-}" ] || { say "FATAL: over-existing cells need RELEASE_ISO (path to qwt-improved-setup.iso) or RELEASE_LOOP (an existing loopN)"; exit 1; }
    [ -s "$RELEASE_ISO" ] || { say "FATAL: RELEASE_ISO=$RELEASE_ISO missing or empty"; exit 1; }
    local dev
    dev=$(udisksctl loop-setup -r -f "$RELEASE_ISO" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
    [ -n "$dev" ] || { say "FATAL: udisksctl loop-setup failed for $RELEASE_ISO"; exit 1; }
    RELEASE_LOOP=${dev#/dev/}
    say "  release ISO on /dev/$RELEASE_LOOP ($RELEASE_ISO)"
  fi
  local backing
  backing=$(losetup -l 2>/dev/null | awk -v d="/dev/$RELEASE_LOOP" '$1==d{print $6}')
  [ -n "$backing" ] || { say "FATAL: /dev/$RELEASE_LOOP is not an active loop device"; exit 1; }
  case "$backing" in *'(deleted)'*)
    say "FATAL: /dev/$RELEASE_LOOP backing file is DELETED - the guest would read a stale disc"; exit 1;; esac
  say "  /dev/$RELEASE_LOOP backed by $backing"
  # GATE-0 ON THE DISC ITSELF, not only on the setup tree: mount locally, run assert-payload
  # (sums + provenance commit + installer bytes), unmount. A truncated or stale ISO is caught
  # here, where the message is readable, instead of surfacing as an in-guest mystery.
  local mnt
  mnt=$(udisksctl mount --block-device "/dev/$RELEASE_LOOP" 2>/dev/null | sed -n 's/^Mounted .* at //p' | sed 's/\.$//')
  [ -n "$mnt" ] || mnt=$(findmnt -no TARGET "/dev/$RELEASE_LOOP" 2>/dev/null | head -1)
  [ -n "$mnt" ] || { say "FATAL: could not mount /dev/$RELEASE_LOOP to verify the ISO content"; exit 1; }
  if ./tools/assert-payload.sh "$mnt" "$RELEASE_REF" >"$M/iso-gate0.out" 2>&1; then
    say "  Gate-0 (ISO): $(tail -1 "$M/iso-gate0.out")"
  else
    say "FATAL: Gate-0 FAILED on the ISO at /dev/$RELEASE_LOOP:"
    tail -3 "$M/iso-gate0.out" | sed 's/^/    /' | tee -a "$R"
    udisksctl unmount --block-device "/dev/$RELEASE_LOOP" >/dev/null 2>&1
    exit 1
  fi
  udisksctl unmount --block-device "/dev/$RELEASE_LOOP" >/dev/null 2>&1
  findmnt -no TARGET "/dev/$RELEASE_LOOP" >/dev/null 2>&1 \
    && say "  WARNING: /dev/$RELEASE_LOOP is still mounted locally after unmount - attach proceeds read-only, but investigate"
}

# RELEASE-ISO DELIVERY: AT BOOT, VIA qvm-start --cdrom (2026-09-03, supersedes the live attach).
# The rig's PROVEN path for putting an ISO in front of a guest is presenting it as a CD when the
# domain STARTS - mgmt/reprovision-usb.sh boots the vendor ISO with exactly
# `qvm-start $VM --cdrom=$HOLDER:$LOOP`. Live `qvm-device block attach` against the running guest
# is NOT a mechanism this qube has: the matrix-4318-live run got "Got empty response from qubesd"
# from it (and block `list` is policy-refused outright). So the over-existing cells boot their
# churn target WITH the disc: reclone/unpark leaves the subject Halted -> boot_with_release_iso ->
# w_session -> entry preconditions -> locate_release_disc (content + provenance) -> install.cmd
# /auto from the disc. The CD is a start-time attach, so it drops at the guest's next shutdown -
# which every cell performs for grading - and the mid-install reboot never needs it (over-existing
# installs are ONE-stage: testsigning is already active on any QWT-carrying guest).

boot_with_release_iso(){ # $1=vm $2=label - boot a HALTED subject with the release ISO as its CD
  local vm=$1 lbl=$2
  if [ "$(w_state "$vm")" != Halted ]; then
    no "$lbl: INTERNAL - boot_with_release_iso needs $vm Halted (state=$(w_state "$vm")); the CD is a start-time attach and cannot be handed to a guest that is already up"
    return 1
  fi
  # Fire-and-poll like start_vm (same rationale: qvm-start blocks until qrexec connects, which on
  # a guest that never boots is dead silence for the whole qrexec_timeout). The start's output is
  # kept: if the disc never shows up in the guest, $M/$lbl-cdboot.out says whether the start
  # itself refused.
  say "  $lbl: booting $vm with the release ISO as CD (qvm-start --cdrom=win-idd-mgmt:$RELEASE_LOOP)"
  timeout -k 10 150 qvm-start "$vm" --cdrom="win-idd-mgmt:$RELEASE_LOOP" >"$M/$lbl-cdboot.out" 2>&1 & disown
  sleep 8
}

locate_release_disc(){ # $1=vm $2=label -> sets RELDISC (e.g. "E:") on success. Guest must be up
  # (booted via boot_with_release_iso, session established by the caller).
  local vm=$1 lbl=$2 a d
  # Locate the disc BY CONTENT, never by an assumed drive letter (a stale answer disc still
  # attached from provisioning would be picked up otherwise), and only among drives that carry
  # BOTH install.cmd and MANIFEST.json. Poll briefly anyway: a session can answer before the
  # drive letter is mounted.
  RELDISC=
  for a in 1 2 3 4 5 6; do
    sleep 5
    d=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run \
        'cmd /c for %d in (D E F G H I J K L M N) do @if exist %d:\install.cmd if exist %d:\MANIFEST.json echo RELDISC=%d:' \
        2>/dev/null | tr -d '\r' | grep -ao 'RELDISC=[D-N]:' | head -1 | cut -d= -f2)
    [ -n "$d" ] && { RELDISC=$d; break; }
  done
  [ -n "$RELDISC" ] || { no "$lbl: no drive carries install.cmd + MANIFEST.json - was this boot made by boot_with_release_iso? (start log: $M/$lbl-cdboot.out)"; return 1; }
  # Provenance of the DISC AS THE GUEST SEES IT - Gate-0's last leg. Its MANIFEST must name the
  # commit under test; a plausible-looking stale medium has voided a cell before (2026-08-29).
  local got
  got=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run "cmd /c type $RELDISC\\MANIFEST.json" 2>/dev/null \
        | tr -d '\r' | grep -a 'driver_repo_commit' | grep -ao '[0-9a-f]\{40\}' | head -1)
  if [ "${got:0:12}" != "${RELEASE_SHA:0:12}" ]; then
    no "$lbl: disc at $RELDISC was built from '${got:-unreadable}', expected ${RELEASE_SHA:0:12} - refusing to install from it"
    return 1
  fi
  ok "$lbl: release disc verified at $RELDISC (driver_repo_commit ${got:0:12})"
}

detach_release_iso(){ # $1=vm $2=label - best effort. The CD is a start-time attach
  # (qvm-start --cdrom), so it drops at the guest's next shutdown anyway (every cell reboots for
  # verify_installed) - a failed detach is logged, never fatal. NOTE: `qvm-device block list` is
  # policy-refused from this qube (findings/rig.md), so the detach verb is exercised
  # optimistically here - if dom0 refuses it too, the shutdown-drop covers us and the message
  # below says so.
  local vm=$1 lbl=$2
  if qvm-device block detach "$vm" "win-idd-mgmt:$RELEASE_LOOP" >/dev/null 2>&1; then
    say "  $lbl: release ISO detached"
  else
    say "  $lbl: could not detach the ISO (harmless: the start-time attach drops at the guest's next shutdown)"
  fi
}

clear_prime_leftovers(){ # $1=vm - prime-run's own exit text: "The stick is still assigned
  # --required and qemu-extra-args is still set - clear both before using this guest as a cell
  # subject." Without this, every later boot of the subject depends on this qube's loop layout.
  local vm=$1 stickloop
  stickloop=$(losetup -l 2>/dev/null | awk '$6 ~ /answer-usb\.img$/{sub("/dev/","",$1); print $1; exit}')
  if [ -n "$stickloop" ]; then
    if qvm-device block unassign "$vm" "win-idd-mgmt:$stickloop" >/dev/null 2>&1; then
      say "  $vm: primer stick unassigned (win-idd-mgmt:$stickloop)"
    else
      say "  WARNING: could not unassign the primer stick from $vm - its boots depend on this qube's loop layout until cleared"
    fi
  else
    say "  WARNING: no loop backing answer-usb.img found - primer stick assignment not cleared for $vm"
  fi
  qvm-features --unset "$vm" qemu-extra-args 2>/dev/null
}

qwt_products(){ # $1=vm - echo the count of MSI-REGISTERED QWT products; echo nothing if unreadable.
  # THE AUTHORITATIVE QWT-PRESENCE SIGNAL, restored from the pre-void cell_fresh (c910ff4):
  # "ASSERT ON THE SIGNAL THE CODE UNDER TEST USES" - Install-QwtImproved.ps1 decides
  # upgrade-vs-clean by enumerating MSI product registrations, which is exactly what
  # guest/count-qwt.ps1 counts. The ITL "Qubes Tools\Version" registry key is NOT that signal:
  # our NG QWT does not populate it at all. Measured 2026-09-03 (matrix-4318): win10-iqi carried
  # a working installed 4.3.17 (qrexec answering, whoami=SYSTEM) while the Version query returned
  # nothing, so the upgrade cell declared a QWT-carrying entry "carries NO installed QWT" and
  # voided itself. Callers: empty output = INVALID-INSTRUMENT (missing data fails, never "absent").
  #
  # INLINE OVER QREXEC + BOUNDED RETRY (matrix-4318-live). This used to `pushrun`
  # guest/count-qwt.ps1 once, and pushrun needs a LOGGED-ON user session - its Filecopy lands in
  # the user's Documents (memory: pushrun-needs-a-session) - while w_session's "session up" only
  # proves qrexec answers. cell_upgrade probed at t+0s, before autologon had finished, got nothing
  # back, and declared INVALID-INSTRUMENT against a perfectly readable guest. Two changes:
  #   1. the count runs INLINE via `qtest run` (needs only qrexec, no session) - the command below
  #      IS guest/count-qwt.ps1's logic verbatim, quoting per the DEV_CONS probe;
  #   2. an empty answer is retried a few times with a short sleep, so "guest not ready yet" and
  #      "genuinely unreadable" are told apart. Empty after ALL retries still reads as
  #      INVALID-INSTRUMENT at the caller - the retry never weakens the verdict, it only stops a
  #      too-early single shot from impersonating one.
  local vm=$1 a n
  for a in 1 2 3 4 5; do
    n=$(QTEST_VM=$vm timeout -k 8 60 ./tools/qtest run \
        "powershell -NoProfile -Command \"\$n=0; foreach(\$k in @('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*','HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')){foreach(\$p in Get-ItemProperty \$k -ErrorAction SilentlyContinue){if(\$p.DisplayName -like '*Qubes Windows Tools*'){\$n++}}}; Write-Host ('QWTPRODUCTS='+\$n)\"" \
        2>/dev/null | tr -d '\r' | grep -aoE 'QWTPRODUCTS=[0-9]+' | tail -1 | cut -d= -f2)
    [ -n "$n" ] && { echo "$n"; return 0; }
    [ "$a" -lt 5 ] && sleep 15
  done
  return 1
}

ensure_churn_target(){ # $1=vm - create the disposable churn StandaloneVM if it does not exist.
  # The reclone-entry cells (upgrade/seeded/stock) clone volumes INTO an existing qube, so on a
  # rig where the clean cell has not run yet (prime-run creates the subject) the churn target may
  # simply not exist. Create it exactly the way prime-run.sh does: create -> TAG -> everything
  # else, in that order - dom0 policy here is tag-based, so any call before the tag lands on a
  # qube policy does not yet cover and is refused.
  local vm=$1 p
  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$vm" && return 0
  say "  creating churn target $vm (disposable StandaloneVM; nothing may ever depend on it - prime-run recreates it freely)"
  qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$vm" \
    || { no "could not create churn target $vm"; return 1; }
  qvm-tags "$vm" add win-idd-testbed || { no "could not tag churn target $vm"; return 1; }
  qvm-features "$vm" os Windows
  for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$vm" "${p%%:*}" "${p##*:}"; done
  qvm-prefs "$vm" netvm '' 2>/dev/null
  return 0
}

park_installed(){ # $1=vm $2=label - halt and park the just-installed subject as the campaign's
  # 'installed' snapshot (owner 2026-09-01: "we do snapshots for optimizations"). The release is
  # installed ONCE per OS per campaign; later cells that merely need "a guest carrying the
  # release" unpark this in ~2 s instead of reinstalling.
  local vm=$1 lbl=$2 ck="ckpt-$vm-installed"
  if [ "$(w_state "$vm")" != Halted ]; then
    qvm-shutdown "$vm" >/dev/null 2>&1
    w_halt "$vm" 420 "$lbl-park-halt" say || { no "$lbl: subject would not halt for parking"; return 1; }
  fi
  if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$ck"; then
    say "  $lbl: replacing the previous campaign's park $ck"
    qvm-remove -f "$ck" >/dev/null 2>&1 || { no "$lbl: stale park $ck exists and cannot be removed"; return 1; }
  fi
  if ./mgmt/harness/checkpoint.sh park "$vm" installed >>"$R" 2>&1; then
    ok "$lbl: installed state parked ($ck) - remove at campaign end: qvm-remove $ck"
  else
    no "$lbl: park failed - snapshot cells will refuse until a park exists"
    return 1
  fi
}

unpark_installed(){ # $1=vm $2=label - restore the campaign's 'installed' snapshot into $vm.
  local vm=$1 lbl=$2
  _halt_other_windows "$vm"
  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$vm" \
    || { no "$lbl: subject $vm does not exist - run the clean cell first (it creates, installs and parks)"; return 1; }
  if [ "$(w_state "$vm")" != Halted ]; then
    qvm-shutdown "$vm" >/dev/null 2>&1
    w_halt "$vm" 420 "$lbl-unpark-halt" say || { no "$lbl: subject would not halt for unpark"; return 1; }
  fi
  if ./mgmt/harness/checkpoint.sh unpark "$vm" installed >>"$R" 2>&1; then
    say "  $lbl: unparked $vm from ckpt-$vm-installed (snapshot entry - the release is NOT reinstalled per cell)"
  else
    no "$lbl: no restorable 'installed' park for $vm - run the clean cell first (it installs ONCE and parks)"
    return 1
  fi
}

accept_grade(){ # $1=vm $2=label - the post-install acceptance battery, REUSED not reinvented
  # (owner model: grading an already-installed guest = tools/accept-clean.sh SKIP_PROVISION=1 -
  # boot-path reboot, WU posture, health-check.ps1, pixels-actually-change, window chrome).
  # verify_installed above grades the INSTALL (branch-vs-claim, release binary hash, monitor
  # state, autologon); this grades the RESULTING GUEST. Writing a second battery for that is what
  # protocol 0.8 forbids, and the last hand-rolled one returned 1603.
  local vm=$1 lbl=$2 nv allowna=0
  nv=$(qvm-prefs "$vm" netvm 2>/dev/null)
  # ALLOW_NA=1 is accept-clean's DOCUMENTED posture for a deliberately-offline subject
  # (netvm=''): the health-check's network assertions cannot apply there, and accept-clean warns
  # loudly about every tolerated NA. On a netvm-carrying subject every check must be asserted.
  [ -z "$nv" ] && allowna=1
  say "  $lbl: accept-clean SKIP_PROVISION=1 ALLOW_NA=$allowna (evidence: $M/$lbl-accept)"
  SKIP_PROVISION=1 ALLOW_NA=$allowna ./tools/accept-clean.sh "$vm" no-loop-in-skip-mode "$M/$lbl-accept" \
      >"$M/$lbl-accept.out" 2>&1
  local rc=$?
  say "  $lbl: accept-clean says: $(tail -1 "$M/$lbl-accept.out" | cut -c1-200)"
  if [ $rc -eq 0 ] && grep -qa 'ACCEPT=PASS' "$M/$lbl-accept.out"; then
    ok "$lbl: accept-clean battery PASS (boot path, WU posture, health, pixels, chrome)"
  else
    no "$lbl: accept-clean battery FAILED (see $M/$lbl-accept.out)"
  fi
}

# Run the installer and judge the outcome. Sets CELL_RC.
# $3 is the INSTALL SOURCE the guest runs install.cmd from - under the release-only model that is
# the CD drive returned by locate_release_disc (e.g. "E:"), never a pushed directory.
run_install(){ # $1=vm $2=label $3=install-source (drive/dir carrying install.cmd) $4=extra-args
  local vm=$1 lbl=$2 src=$3 extra=${4:-}
  # Clear BOTH logs. The MSI verbose log lives at a fixed path and survives from earlier installs,
  # so without this the capture can show a two-week-old install and read as this run's evidence.
  # VERIFY THE CLEAR (H1). A failed delete leaves the GOLDEN's own install log in place - every
  # clone inherits C:\qwt-improved-install.log from the ST2G build - and the next poll then reads
  # that build's RESULT as this cell's. Deleting and hoping is how a cell grades someone else's
  # install.
  QTEST_VM=$vm qrun "cmd /c del /f /q $GLOG 2>nul & del /f /q C:\\qwt-install.log 2>nul & echo CLEARED" >/dev/null 2>&1
  # RUN MARKER, not deletion. Deleting the guest log cannot be made reliable: boot tasks append to
  # the SAME file the installer uses (the autologon guard writes its banner there), so right after a
  # clone boots the delete races a live writer. Measured 2026-08-30: five attempts over 75 s all
  # returned STILLTHERE, while the identical delete on the same guest minutes later returned RC=0
  # GONE. Widening the window is guesswork about someone else's task.
  #
  # H1 already prescribes the answer - a run identity - so use it: append a unique marker and judge
  # ONLY what follows it. That is immune to other writers, needs no deletion, and makes "this cell's
  # output" a positive fact rather than the absence of someone else's.
  E2E_MARK="E2EMARK-$(date -u +%Y%m%d%H%M%S)-$$"
  export E2E_MARK
  QTEST_VM=$vm qrun "cmd /c echo $E2E_MARK >> $GLOG & del /f /q C:\\qwt-install.log 2>nul & echo MARKED" >/dev/null 2>&1
  local seen
  seen=$(QTEST_VM=$vm qrun "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT" 2>/dev/null | tr -d '\r' | grep -ao 'PRESENT\|ABSENT' | head -1)
  if [ "$seen" != PRESENT ]; then
    no "$lbl: could not write the run marker into $GLOG (got '${seen:-no answer}') - refusing to run, this cell could not be told apart from a previous one"
    return 1
  fi
  # SEED THE LOCAL CUMULATIVE TAIL WITH THE MARKER.
  # w_install samples the guest log with `Get-Content -Tail 15`. The marker is written BEFORE the
  # installer runs, and the install then emits ~120 lines, so the marker scrolls out of every
  # sample window and never reaches the cumulative tail - the slice finds nothing, .cur stays
  # empty, and the wait STALLS on an install that succeeded. Measured twice on 2026-08-30: cell
  # WIN10-1stage logged stage2-install ok:true and was still declared STALLED 300 s later, while
  # verify_installed - which reads the FULL guest log - passed every check.
  # The harness knows the marker, so it writes it locally instead of hoping to sample it back. It
  # goes in FIRST, so everything appended by later polls is unambiguously this run's.
  mkdir -p "$M"
  echo "$E2E_MARK" >> "$M/$lbl-install.tail"
  say "  $lbl: run marker $E2E_MARK"

  # ARM THE PREMATURE-REBOOT DIALOG WATCHER, through the install.
  # "premature reboot dialogs are gone" is an acceptance criterion, and until now NOTHING in these
  # cells looked for the dialog: the xenbus_monitor checks measure the MECHANISM (service disabled,
  # not running), which is not the same claim. Per the protocol's vacuity rule, "no dialog" from a
  # cell that never watched is INVALID-VACUOUS, never a PASS - so the absence has to be backed by a
  # timestamped record of having looked, at a known rate, over the interval that matters.
  QTEST_VM=$vm timeout -k 5 120 ./tools/qtest push guest/reboot-dialog-watch.ps1 >/dev/null 2>&1
  # -DurationSeconds, NOT -Minutes. The script's param block has no -Minutes (OutFile,
  # IntervalSeconds, DurationSeconds, Summary, SelfTest), so PowerShell rejected the unknown
  # parameter and the watcher exited INSTANTLY, every time, writing no log at all. The failure was
  # invisible because it is launched with `start /min` and its output goes nowhere: the cell then
  # reported "watcher produced NO summary - INVALID", which fails closed and so never produced a
  # false PASS - but it also meant the dialog criterion could never actually be met. Measured
  # 2026-08-30 on win10-app: no jsonl, no powershell process.
  QTEST_VM=$vm qrun "cmd /c start \"dlgwatch\" /min powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\reboot-dialog-watch.ps1 -DurationSeconds 2700" >/dev/null 2>&1
  say "  $lbl: reboot-dialog watcher armed"
  QTEST_VM=$vm qrun "cmd /c start \"\" /min $src\\install.cmd /auto /autologon:qubes $extra" >/dev/null 2>&1
  # SEED_DELAY: write the PV reboot Request mid-MSI, which is when the field gets it.
  #
  # CONTAMINATION GUARD, added 2026-08-29. SEED_DELAY is an ENVIRONMENT variable, so if it is set
  # anywhere in the calling environment it fires in EVERY cell — including cells named and reported
  # as unseeded — and its only record was a separate <label>-seed.log that the cell transcript never
  # references. That is exactly what happened: the 01:16 WIN10-fresh cell was seeded at install+25s
  # while matrix.log said nothing, and its brick observation is void. See FINDINGS 2026-08-29 and
  # evidence/2026-08-29-fresh-cell-contamination/.
  #
  # Two rules now: the seed state is ALWAYS written to the cell transcript (so "unseeded" is a
  # recorded fact, not an absence), and firing requires an explicit per-run opt-in — an inherited
  # SEED_DELAY alone is a hard abort, never a silent injection.
  say "  $lbl: SEED_DELAY=${SEED_DELAY:-unset} SEED_CELL=${SEED_CELL:-unset}"
  if [ -n "${SEED_DELAY:-}" ] && [ "${SEED_CELL:-}" != "1" ]; then
    no "$lbl: SEED_DELAY=${SEED_DELAY} is set but SEED_CELL=1 was not — refusing to inject into a"
    no "     cell that does not declare itself seeded. Export SEED_CELL=1 deliberately, or unset"
    no "     SEED_DELAY. (Inherited-env injection voided the 2026-08-28 WIN10 matrix.)"
    CELL_RC=2
    return 1
  fi
  if [ -n "${SEED_DELAY:-}" ]; then
    # Timestamp the injection from the same clock the installer logs with, so "before/after msiexec"
    # is decidable afterwards instead of inferred.
    say "  $lbl: SEEDED CELL — injecting PV reboot Request at install+${SEED_DELAY}s"
  fi
  if [ -n "${SEED_DELAY:-}" ]; then
    ( sleep "$SEED_DELAY"
      QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run \
        'cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request\xenvbd" /v Reboot /t REG_DWORD /d 1 /f /reg:64 & echo REQ_WRITTEN' \
        2>/dev/null | tr -d '\r' | grep -a REQ_WRITTEN >> "$M/$lbl-seed.log" 2>&1
      echo "request written at install+${SEED_DELAY}s ($(date +%H:%M:%S))" >> "$M/$lbl-seed.log" ) &
  fi
  # Probe the MONITOR PROCESS directly. tasklist is far cheaper than reading a growing log, so it
  # keeps answering while the guest is busy - which is exactly where every file-read poll lost the
  # race and cost us the six lines that mattered.
  ( for _p in $(seq 1 90); do
      echo "[$(date +%H:%M:%S)] $(QTEST_VM=$vm timeout -k 3 25 ./tools/qtest run \
        'cmd /c tasklist | findstr /i xenbus & sc query xenbus_monitor | findstr /i STATE' \
        2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-150)" >> "$M/$lbl-monitor.log" 2>&1
      sleep 5
    done ) &
  PROBE_PID=$!
  w_install "$vm" 2400 "$lbl" "$M" say "$GLOG"; CELL_RC=$?
  kill ${PROBE_PID:-0} 2>/dev/null
  case $CELL_RC in
    0) say "  $lbl: install reported a RESULT" ;;
    1) no "$lbl: guest went to the recovery screen DURING the install" ;;
    2) no "$lbl: install hit the 2400s deadline" ;;
    3) say "  $lbl: guest halted during/after the install (expected for a two-stage install)" ;;
    4) no "$lbl: install STALLED (no progress for ${STALL_SECS}s)" ;;
  esac
  return 0
}

_assert_not_primed(){ # $1=vm $2=label - a primed guest has had arbitrary SYSTEM code run in it
  # PROTOCOL 0.7c. Both base goldens carry the primer hook (a pristine guest has no qrexec, so it is
  # the only way to drive a clone without a 20-minute Windows reinstall). The hook is inert unless a
  # job stick is attached, and it leaves C:\qubes-prime\fired.mark when it has run. A guest that ran
  # a primer job is NOT a clean guest and must never be graded as one - unless the cell declares it,
  # via CELL_PRIMED=1.
  local vm=$1 lbl=$2 mark
  mark=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run \
      "cmd /c if exist C:\\qubes-prime\\fired.mark (echo PRIMED) else (echo CLEAN)" 2>/dev/null \
      | tr -d '\r\0' | grep -aoE '^(PRIMED|CLEAN)$' | tail -1)
  case "$mark" in
    CLEAN)  ok "$lbl: guest is not primed (no fired.mark)" ;;
    PRIMED)
      if [ "${CELL_PRIMED:-0}" = 1 ]; then
        ok "$lbl: guest is primed, and this cell declares it (CELL_PRIMED=1)"
      else
        no "$lbl: INVALID-PRECONDITION - guest carries C:\\qubes-prime\\fired.mark, so a primer job ran arbitrary SYSTEM code in it; this cell did not declare CELL_PRIMED=1"
      fi ;;
    *)
      # Missing data fails. A probe that cannot answer must never read as "clean".
      no "$lbl: INVALID-INSTRUMENT - could not read the primer marker (got '${mark:-nothing}')" ;;
  esac
}

verify_installed(){ # $1=vm $2=label   - the guest must be healthy and carry OUR build
  local vm=$1 lbl=$2 j
  # Report WHICH terminal state, never a guess. This line used to say "boots to the Windows
  # recovery screen" for every terminal verdict, and printed exactly that for a guest that was
  # black and still consuming CPU - a harness that misnames the failure is how wrong conclusions
  # get written down as facts.
  # THE INSTALLER EXPECTS THE CALLER TO REBOOT. Its own closing lines say so: "INSTALL COMPLETE -
  # the PV drivers bind at the guest's NEXT start ... -RebootAtEnd restores the old behaviour for a
  # caller that wants the finished state immediately (our own acceptance harness reboots by itself)".
  # On any path that installs the PV drivers FRESH, that swap tears down the vchan qrexec runs on,
  # so no session can appear until the guest restarts - and waiting 900 s for one and calling the
  # result a brick is what produced ten identical black screens.
  #
  # qrexec is gone, but admin.vm.Stats is not: CPU tells us when the install actually finished.
  if ! w_alive "$vm"; then
    say "  $lbl: no qrexec (expected while the MSI replaces the agent / swaps PV drivers) - waiting for the install to go quiet"
    local quiet=0 q c
    for q in $(seq 1 60); do
      # See the note in mgmt/reprovision-usb.sh:_cpu - this same probe was parsed wrongly. The
      # stats stream is NULL-separated records; deleting the separators runs each value into the
      # next record (3 reads as "31") and the sum then covers the entire stream window. Measured
      # 149 on a guest whose true usage was 3, so this "quiet" test could effectively never pass.
      c=$(printf '' | timeout 10 qrexec-client-vm "$vm" admin.vm.Stats 2>/dev/null | tr '\0' '\n' \
          | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print 9999; else print m}')
      if [ "${c:-9999}" -lt 15 ] 2>/dev/null; then quiet=$((quiet+1)); else quiet=0; fi
      [ $((q % 4)) -eq 0 ] && say "    t+$((q*15))s cpu=${c:-?} quiet=$quiet"
      [ "$quiet" -ge 3 ] && { say "  $lbl: CPU quiet - the install has finished working"; break; }
      w_alive "$vm" && { say "  $lbl: qrexec came back on its own at t+$((q*15))s"; break; }
      sleep 15
    done
    if ! w_alive "$vm"; then
      say "  $lbl: rebooting the guest, as the installer's contract requires of its caller"
      qvm-shutdown "$vm" >/dev/null 2>&1
      w_halt "$vm" 420 "$lbl-postinstall-halt" say || { qvm-kill "$vm" >/dev/null 2>&1; sleep 10; }
      start_vm "$vm"
    fi
  fi
  w_session "$vm" 900 "$lbl-back" "$M" say
  case $? in
    1) no "$lbl: BRICKED - $(grep -a "$lbl-back: TERMINAL" "$R" | tail -1 | sed 's/.*TERMINAL - //' | cut -c1-120)"; return 1 ;;
    2) no "$lbl: no session within 900s even after the post-install reboot (last screen: $(w_screen "$vm" "$lbl-final" "$M"))"; return 1 ;;
  esac
  ok "$lbl: guest came back with a session"
  _assert_not_primed "$vm" "$lbl"
  QTEST_VM=$vm timeout -k 5 120 ./tools/qtest run "cmd /c type \"$GLOG\"" 2>/dev/null \
    | tr -d '\r' | grep -av 'system32>' > "$M/$lbl-final.log"
  # Same discriminator as w_install: 111 guest scripts emit "=== RESULT ===" banners and the
  # installer logs their output, so `grep -ao '=== RESULT === .*'` can pick up a nested one
  # (e.g. "=== RESULT === changed=0 warnings=0") and every json check then fails against a
  # non-json string - reported as product FAILs. The installer's own trailer starts the line and
  # is followed by JSON.
  # Judge only past this run's marker, for the same reason w_install does: the log carries the
  # golden's own install RESULT and anything boot tasks appended, and `tail -1` alone would happily
  # return the newest of those if this cell's installer never wrote one.
  if [ -n "${E2E_MARK:-}" ] && grep -qa "$E2E_MARK" "$M/$lbl-final.log"; then
    sed -n "/$E2E_MARK/,\$p" "$M/$lbl-final.log" > "$M/$lbl-final.cur"
  elif [ "${ENTRY_PRISTINE:-0}" = 1 ]; then
    # PRISTINE-ENTRY CELLS (C1/C2 via the primer) have no run marker, because run_install never
    # ran - the installer was launched inside the guest by the primer job, which is the only way
    # into a guest that has no qrexec yet.
    #
    # The marker exists to stop a clone's inherited log being graded as this cell's. A pristine
    # base cannot have one: it has never had QWT, so it has never had an installer write to
    # C:\qwt-improved-install.log. That is not an assumption - it is CHECKED here, by requiring
    # the FIRST precondition line in the log to report a guest with no QWT and no testsigning.
    # If it does not, the entry was not pristine and the whole cell is INVALID-PRECONDITION
    # rather than a product verdict (H4.2). So this branch proves the same thing the marker does,
    # from the log's own contents, and proves the cell's entry state at the same time.
    local p1
    # NOT ANCHORED. The installer writes the PRECONDITION line through Write-Log, which prefixes a
    # timestamp and level ("2026-08-30 12:11:12 [INFO] === PRECONDITION === {...}"), while the
    # RESULT trailer is written raw and DOES start at column 0. Anchoring this one with ^ matched
    # nothing and would have reported INVALID-INSTRUMENT for every healthy guest - a false FAIL
    # introduced by assuming the two banners share a format. Verified against a real log.
    p1=$(grep -a '=== PRECONDITION === {' "$M/$lbl-final.log" | head -1)
    if [ -z "$p1" ]; then
      no "$lbl: no PRECONDITION line at all - INVALID-INSTRUMENT, nothing about this install was measured"
      return 1
    fi
    # FIELD NAMES ARE `testsigning_active` AND `installed_qwt_count`, verified against
    # Install-QwtImproved.ps1:2349/2357 - not `testsigning`/`installed_qwt` as the protocol prose
    # abbreviates them. And the COUNT is the discriminator, not the array: an empty PowerShell
    # array's ConvertTo-Json rendering is not something to bet a gate on, while
    # "installed_qwt_count":0 is unambiguous. Both error paths set the count to -1, so a failed
    # probe can never be mistaken for "no QWT installed".
    if echo "$p1" | grep -qa '"testsigning_active":false' && echo "$p1" | grep -qa '"installed_qwt_count":0'; then
      ok "$lbl: entry was genuinely PRISTINE (testsigning_active:false, installed_qwt_count:0) - clean-install path"
    else
      no "$lbl: INVALID-PRECONDITION - cell claims a pristine entry but the installer saw: $(echo "$p1" | cut -c1-200)"
      return 1
    fi
    # BRANCH AUTHORITY FOR A CLEAN INSTALL. `upgrade_mode` is only assigned inside the
    # "an existing QWT was found" branch (Install-QwtImproved.ps1:1105), so a genuine clean install
    # emits NO upgrade_mode at all - and EXPECT_MODE therefore cannot be the authority here. The
    # installer's own clean-install marker is (Install-QwtImproved.ps1:1021):
    #   "no previously installed Qubes Windows Tools found - clean install path"
    # Asserting it positively is what stops a silent D2 reinstall from being reported as D0, which
    # is exactly how campaign 20260830-062519 produced 36 green lines for a path that never ran.
    if grep -qa 'clean install path' "$M/$lbl-final.log"; then
      ok "$lbl: installer took the CLEAN INSTALL path (D0) - its own marker, not an inference"
    else
      no "$lbl: INVALID-PRECONDITION - no 'clean install path' marker; this was not a clean install"
    fi
    cp "$M/$lbl-final.log" "$M/$lbl-final.cur"
  else
    : > "$M/$lbl-final.cur"
  fi
  j=$(grep -a '^=== RESULT === {' "$M/$lbl-final.cur" | tail -1)
  if [ -z "$j" ]; then
    # Missing data FAILS, and says so as an instrument problem rather than as a product verdict:
    # without the trailer nothing about this install has been measured.
    no "$lbl: no installer RESULT trailer in the final log - INVALID-INSTRUMENT, not a product result"
    return 1
  fi
  say "  $lbl RESULT: $(echo "$j" | cut -c1-300)"
  echo "$j" | grep -qa "\"installed_gui_agent_sha256\":\"$ASHA" \
    && ok "$lbl: installed agent == release binary" || no "$lbl: installed agent is NOT the release binary"
  # DIALOG VERDICT. Read the watcher's own summary rather than inferring from silence: it reports
  # NO SAMPLES / BLIND / COVERAGE GAPS as distinct outcomes, and each of those means "this cell
  # cannot claim the dialog was absent" - not "it was absent".
  local dv
  # N/A-BY-DESIGN GATE, before the vacuity gate. The protocol's dialog-vacuity clause (P2) is
  # binding: the premature-reboot dialog is raised by "Xen PV Network Class" and therefore CANNOT
  # appear on a guest with no netvm. On such a guest neither verdict means anything - "no dialog"
  # is vacuous, and a FAIL for a missing watcher summary is equally meaningless, because there was
  # nothing for the watcher to see.
  #
  # This is NOT a way to skip the check where it counts. It fires only when netvm is literally
  # empty, it reports N/A rather than PASS so nothing can cite it as evidence, and it names the
  # cell that does own the claim (NET-6, on a guest that has never had a vif). Without it, every
  # primer-installed clean-install cell would carry a structural FAIL that says nothing about the
  # product.
  #
  # `return 0` HERE WOULD BE A BUG, and was one: it returns from verify_installed, so every check
  # AFTER the dialog block - PV console bound, autologon armed, installed version, xenbus_monitor
  # start type and state - silently never runs, while the summary still prints a clean
  # "N passed, 0 failed". Measured on the first C1 grade: 5 green lines, four checks skipped.
  # Skip the dialog check only; fall through to the rest.
  local nv; nv=$(qvm-prefs "$vm" netvm 2>/dev/null)
  if [ -z "$nv" ]; then
    say "  N/A   $lbl: premature-reboot dialog NOT APPLICABLE - $vm has netvm='' and the dialog is a"
    say "        Xen PV Network Class event, so it cannot occur here. NET-6 owns this claim."
    dv=SKIP
  else
  dv=$(QTEST_VM=$vm timeout -k 5 120 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\reboot-dialog-watch.ps1 -Summary" 2>/dev/null | tr -d '\r' | grep -a '=== REBOOTWATCH ===' | tail -1)
  if [ -z "$dv" ]; then
    no "$lbl: reboot-dialog watcher produced NO summary - 'no dialog' would be vacuous (INVALID)"
  elif echo "$dv" | grep -qai 'NO SAMPLES\|BLIND\|COVERAGE GAP'; then
    no "$lbl: reboot-dialog watch not credible: $(echo "$dv" | cut -c1-160)"
  elif echo "$dv" | grep -qai 'DIALOG OBSERVED'; then
    no "$lbl: a premature reboot DIALOG was observed: $(echo "$dv" | cut -c1-160)"
  else
    ok "$lbl: no premature reboot dialog, and the watcher proves it looked"
  fi
  fi

  # BRANCH-VS-CLAIM. The installer records which branch it took (`upgrade_mode`), and P1.0 names
  # that as THE AUTHORITY on the branch - "a harness probe disagreeing with either is the harness
  # being wrong". Nothing compared the two, so on 2026-08-30 four cells named "fresh" ran with
  # upgrade_mode:in-place-same-version-reinstall and reported 7/7 PASS each. The goldens carried the
  # candidate release, so every clone already had it and no clean install was possible - 36 green
  # lines describing a path that never executed.
  #
  # EXPECT_MODE names the branch a cell CLAIMS. A mismatch is INVALID-PRECONDITION (H5): the cell
  # could not establish its own entry state, which is not a product verdict and must never be
  # reported as one.
  local um
  um=$(echo "$j" | grep -ao '"upgrade_mode":"[^"]*"' | head -1 | cut -d'"' -f4)
  say "  $lbl: installer branch = ${um:-<none reported>}"
  if [ -n "${EXPECT_MODE:-}" ]; then
    if [ "$um" = "$EXPECT_MODE" ]; then
      ok "$lbl: branch matches the cell's claim ($um)"
    else
      no "$lbl: INVALID-PRECONDITION - cell claims '$EXPECT_MODE' but the installer took '${um:-none}'"
    fi
  fi

  # XENCONS (PV console) must be BOUND, not merely shipped. QWT historically vendored no xencons at
  # all, so XENBUS\VEN_XP0001&DEV_CONS sat at CM code 28 on every guest and that was allowlisted as
  # expected. Since 4.3.16 ships it, "code 28" changed from an expected state into a defect - and
  # "all drivers present" is an acceptance criterion, so a cell has to assert it rather than trust
  # that packaging staged the files.
  local cons
  cons=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run "powershell -NoProfile -Command \"(Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { \$_.PNPDeviceID -like 'XENBUS\\VEN_XP0001&DEV_CONS*' } | ForEach-Object { 'CONS:err='+\$_.ConfigManagerErrorCode+' svc='+\$_.Service })\"" 2>/dev/null | tr -d '\r' | grep -ao 'CONS:err=[0-9]* svc=[A-Za-z]*' | head -1)
  case "$cons" in
    "CONS:err=0 svc=xencons") ok "$lbl: PV console bound ($cons)" ;;
    "")                       no "$lbl: could not read DEV_CONS state - driver presence UNVERIFIED" ;;
    *)                        no "$lbl: PV console NOT bound ($cons)" ;;
  esac

  echo "$j" | grep -qa '"autologon":"armed"' \
    && ok "$lbl: autologon armed" || no "$lbl: autologon NOT armed ($(echo "$j" | grep -ao '"autologon":"[^"]*"'))"
  # INFORMATIONAL ONLY, and labeled so nobody re-derives the matrix-4318 false negative from this
  # line: the ITL Version key is a STOCK-era signal that our NG QWT leaves empty. Presence is
  # asserted elsewhere via qwt_products (MSI product registrations), never via this key.
  local ver; ver=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  $lbl ITL Version key (stock-era signal, empty on our NG QWT - not a presence check): ${ver:-<empty>}"

  # PROVE THE MECHANISM, not just the absence of a brick. The fix is in xenbus.inf: the monitor
  # service must be installed but DISABLED and NOT RUNNING after the driver install. Asserting
  # this is what separates "the fix works" from "this run happened not to lose the race" - the
  # old INF starts the service (SPSVCSINST_STARTSERVICE, StartType=auto), so on an unfixed build
  # this check FAILS, which is what makes its PASS evidence.
  local q; q=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run 'cmd /c sc qc xenbus_monitor & sc query xenbus_monitor' 2>/dev/null | tr -d '\r')
  local start state
  start=$(echo "$q" | grep -aiE 'START_TYPE' | head -1 | sed 's/^[[:space:]]*//')
  state=$(echo "$q" | grep -aiE '^\s*STATE' | head -1 | sed 's/^[[:space:]]*//')
  say "  $lbl xenbus_monitor: ${start:-<no service>} | ${state:-<no state>}"
  if echo "$start" | grep -qai 'DISABLED'; then
    ok "$lbl: xenbus_monitor is DISABLED by the shipped INF"
  else
    no "$lbl: xenbus_monitor start type is NOT disabled ($start) - the INF patch did not reach this guest"
  fi
  if echo "$state" | grep -qai 'STOPPED'; then
    ok "$lbl: xenbus_monitor is not running"
  else
    no "$lbl: xenbus_monitor is RUNNING ($state) - it can still restart the guest"
  fi
}

# GRADE-ONLY CELL. Runs the full verify_installed battery against a guest that is ALREADY
# installed, without recloning or reinstalling anything.
#
# Why it exists: the clean-install cells (C1/C2) cannot go through run_install at all. A pristine
# base has no qrexec, so the installer has to be launched inside the guest by the primer job
# (mgmt/harness/prime-run.sh), and by the time this qube can talk to the guest the install is
# already done. Without this selector the only way to grade that guest would be a second,
# hand-rolled battery - which is exactly the "write a second route to a result the rig already
# reaches" that protocol 0.8 forbids, and which returned 1603 the last time it was done.
#
# Set ENTRY_PRISTINE=1 for a clean-install subject: verify_installed then proves the entry state
# from the installer's own first PRECONDITION line instead of looking for a run marker that never
# existed. EXPECT_MODE still applies and is still the branch-vs-claim authority.
cell_grade(){ # $1=vm $2=tag
  say "######## CELL $2-grade (grade-only, no reclone, no reinstall) ########"
  local vm=$1
  if [ "$(w_state "$vm")" = Halted ]; then
    say "  $vm is Halted - starting it for grading"
    start_vm "$vm"
  fi
  verify_installed "$vm" "$2-grade"
}

# --------------------------------------------------------------------------- cells
cell_clean(){ # $1=pristine-base $2=subject $3=tag
  # THE clean-install cell (D0 x E1). A pristine base has NO qrexec, so the release setup tree
  # rides the primer stick and the guest installs itself as SYSTEM (prime-run job 'ours') - the
  # only channel into a pristine guest, and the payload it carries IS the release. Because the
  # bases keep testsigning OFF, this is inherently the TRUE two-stage path (stage 1, reboot,
  # stage 2). The old fresh-1stage/fresh-2stage constructions are retired: they needed a
  # qrexec-carrying golden AND a pushed tarball - both forbidden under the release-only model.
  #
  # ENDS BY PARKING: the release is installed ONCE per OS per campaign; the snapshot cells
  # (reinstall, grade re-entries) unpark this state in seconds instead of reinstalling.
  say "######## CELL $3-clean (prime-run from $1: pristine -> two-stage clean install of the RELEASE) ########"
  local base=$1 vm=$2 tag=$3
  _halt_other_windows "$vm"
  say "  prime-run $base -> $vm (job ours, payload $RELEASE_SETUP)"
  ./mgmt/harness/prime-run.sh "$base" "$vm" ours --payload "$RELEASE_SETUP" >"$M/$tag-clean-prime.log" 2>&1
  local prc=$?
  say "  prime-run tail: $(tail -1 "$M/$tag-clean-prime.log" | cut -c1-180)"
  case $prc in
    0) ok "$tag-clean: prime-run delivered a qrexec-answering installed guest" ;;
    1) no "$tag-clean: prime-run TERMINAL (see $M/$tag-clean-prime.log)"; return ;;
    2) no "$tag-clean: prime-run hit its deadline (see $M/$tag-clean-prime.log)"; return ;;
    *) no "$tag-clean: prime-run rc=$prc (see $M/$tag-clean-prime.log)"; return ;;
  esac
  clear_prime_leftovers "$vm"
  # Park FIRST, grade the parked state AFTER: the snapshot must be the clean installed state,
  # not one carrying grading residue (notepad, typed markers, an extra boot's mutations).
  park_installed "$vm" "$tag-clean" || say "  $tag-clean: continuing without a park - snapshot cells will refuse loudly"
  start_vm "$vm"
  w_session "$vm" 900 "$tag-clean-boot" "$M" say || { no "$tag-clean: installed guest did not come back for grading"; return; }
  # Grade the install. ENTRY_PRISTINE=1 proves the entry state from the installer's own first
  # PRECONDITION line (there is no run marker: the installer was launched by the primer job, not
  # by run_install) and demands the installer's own 'clean install path' marker. CELL_PRIMED=1
  # declares the primer honestly - under the release-only model the clean subject is primer-built
  # BY CONSTRUCTION, and _assert_not_primed still fails on an unreadable probe.
  E2E_MARK=""; ENTRY_PRISTINE=1; EXPECT_MODE=""; CELL_PRIMED=1
  verify_installed "$vm" "$tag-clean"
  ENTRY_PRISTINE=0
  accept_grade "$vm" "$tag-clean"
}

cell_reinstall(){ # $1=subject $2=tag - same-version reinstall of the release over itself (C6)
  # Entry = the campaign's 'installed' SNAPSHOT (unpark, ~2 s) - never a reinstall-from-scratch
  # and never a reclone: cell_clean installed the release once and parked it. Install source =
  # the release ISO presented as a CD at boot (boot_with_release_iso). The snapshot carries
  # exactly this release, so the installer's own branch authority must report the same-version
  # reinstall.
  say "######## CELL $2-reinstall (unpark 'installed' snapshot -> same-version reinstall from the release ISO) ########"
  local vm=$1 tag=$2
  unpark_installed "$vm" "$tag-reinstall" || return
  boot_with_release_iso "$vm" "$tag-reinstall" || return
  w_session "$vm" 900 "$tag-reinstall-boot" "$M" say || { no "$tag-reinstall: unparked subject did not boot"; return; }
  locate_release_disc "$vm" "$tag-reinstall" || return
  ENTRY_PRISTINE=0; EXPECT_MODE=in-place-same-version-reinstall; CELL_PRIMED=1
  run_install "$vm" "$tag-reinstall" "$RELDISC"
  detach_release_iso "$vm" "$tag-reinstall"
  if [ "$(w_state "$vm")" = Halted ]; then start_vm "$vm"; fi
  verify_installed "$vm" "$tag-reinstall"
  accept_grade "$vm" "$tag-reinstall"
}

cell_upgrade(){ # $1=previous-ours entry image $2=subject $3=tag - previous release -> this one
  # Entry = a guest CARRYING THE PREVIOUS RELEASE (e.g. win10-iqi with shipped 4.3.17), named via
  # G10/G11 and custody-gated at the driver (sealed golden or prime-run fixture record). reclone
  # - with its dirty-volume recovery - puts it into the subject; the release ISO as a CD installs
  # over it. EXPECT_MODE defaults to the in-place MSI major upgrade that the version-bump
  # discipline guarantees; override with UPGRADE_EXPECT_MODE only for a deliberate variant.
  say "######## CELL $3-upgrade (previous ours [$1] -> release, installed from the ISO) ########"
  local prev=$1 vm=$2 tag=$3
  ensure_churn_target "$vm" || return
  reclone "$prev" "$vm" || { no "$tag-upgrade: could not reclone"; return; }
  boot_with_release_iso "$vm" "$tag-upgrade" || return
  w_session "$vm" 900 "$tag-upgrade-boot" "$M" say || { no "$tag-upgrade: clone did not boot"; return; }
  # QWT presence via the installer's OWN signal (MSI product registrations - qwt_products), never
  # the ITL "Qubes Tools\Version" reg key: our NG QWT does not populate that key, so it
  # false-negatives on exactly the entries this cell exists for. Measured on matrix-4318:
  # win10-iqi ran a working installed 4.3.17 (qrexec answering) while the Version query returned
  # nothing, and this cell voided itself with "carries NO installed QWT".
  local before; before=$(qwt_products "$vm")
  say "  QWT products at entry: ${before:-<unreadable>}"
  if [ -z "$before" ]; then
    no "$tag-upgrade: INVALID-INSTRUMENT - could not count QWT products at entry (missing data fails; it never reads as 'absent')"; return
  elif [ "$before" -lt 1 ] 2>/dev/null; then
    no "$tag-upgrade: entry image carries NO installed QWT (QWTPRODUCTS=0) - not an upgrade cell, INVALID-PRECONDITION"; return
  fi
  ok "$tag-upgrade: entry carries an installed QWT (QWTPRODUCTS=$before)"
  locate_release_disc "$vm" "$tag-upgrade" || return
  ENTRY_PRISTINE=0; EXPECT_MODE="${UPGRADE_EXPECT_MODE:-in-place-msi-major-upgrade}"; CELL_PRIMED=1
  run_install "$vm" "$tag-upgrade" "$RELDISC"
  detach_release_iso "$vm" "$tag-upgrade"
  if [ "$(w_state "$vm")" = Halted ]; then start_vm "$vm"; fi
  verify_installed "$vm" "$tag-upgrade"
  accept_grade "$vm" "$tag-upgrade"
}

cell_seeded(){ # $1=QWT-carrying entry image $2=subject $3=tag
  # The field's state: an EXISTING QWT whose xenbus_monitor is armed AND RUNNING, plus a PV
  # reboot Request written MID-MSI (SEED_DELAY - opt-in via SEED_CELL=1, see run_install's
  # contamination guard). Entry = a QWT-carrying fixture named via G10/G11 (previous-ours is the
  # honest field entry); install source = the release ISO as a CD. EXPECT_MODE is the operator's
  # claim about the entry (previous-ours -> SEEDED_EXPECT_MODE=in-place-msi-major-upgrade).
  say "######## CELL $3-seeded (pending xenbus Request + monitor auto-start, install from the ISO) ########"
  say "  THIS IS THE SUSPECTED BRICK. Control (seed off) completed in 90 s and stayed healthy;"
  say "  the seeded run halted at 80 s mid-MSI and came back in Automatic Repair. n=2, unproven."
  ensure_churn_target "$2" || return
  reclone "$1" "$2" || { no "$3-seeded: could not reclone"; return; }
  boot_with_release_iso "$2" "$3-seeded" || return
  w_session "$2" 600 "$3-seeded-boot" "$M" say || { no "$3-seeded: clone did not boot"; return; }
  # The entry must CARRY a QWT: the seeded cell models a PV reboot Request arriving over an
  # EXISTING install (the field's state). Same authoritative presence signal as cell_upgrade -
  # MSI product registrations (qwt_products), never the ITL Version key, which is empty on our
  # NG QWT and false-negatived matrix-4318's upgrade cell.
  local sn; sn=$(qwt_products "$2")
  say "  QWT products at entry: ${sn:-<unreadable>}"
  if [ -z "$sn" ]; then
    no "$3-seeded: INVALID-INSTRUMENT - could not count QWT products at entry (missing data fails; it never reads as 'absent')"; return
  elif [ "$sn" -lt 1 ] 2>/dev/null; then
    no "$3-seeded: INVALID-PRECONDITION - entry carries NO installed QWT (QWTPRODUCTS=0); the seeded cell needs an existing install to seed over"; return
  fi
  ok "$3-seeded: entry carries an installed QWT (QWTPRODUCTS=$sn)"
  local XK='HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor'
  # TIMING IS THE WHOLE TEST, and the old timing made this cell meaningless. Writing the Request
  # BEFORE the install let the already-running, idle monitor act on it immediately: measured
  # 2026-08-29, event 1074 at 00:20:10Z versus the installer's first log line at 00:20:15 - the
  # restart was in flight five seconds before the installer existed. No installer-side fix can
  # prevent that, so six "failures" said nothing about the fix under test.
  #
  # The field's sequence is: installer runs -> stops/disables the monitor -> msiexec starts -> the
  # PV driver install files a Request MID-MSI. So arm auto-start here, and write the Request
  # DURING msiexec (run_install, SEED_DELAY) - after the installer has had its chance.
  # ARM *AND START*. `sc config start= auto` only sets the START TYPE; the service does not begin
  # running until the next boot. This cell reclones and boots BEFORE arming, so without an explicit
  # start the PRECONDITION reads `xenbus_monitor{start:2, status:Stopped}` - and the protocol's
  # armed-monitor variant (§5, C3/C4) requires `{Running, start:2}`. A cell that cannot establish
  # its own declared precondition is INVALID-PRECONDITION, not a product verdict (H4.2).
  #
  # Running is also the honest field state: it is exactly what stock QWT leaves behind, measured on
  # the C4 fixture (`xenbus_monitor{status:Running, start:2, pids:[2904]}`). A monitor that is merely
  # set to auto-start cannot restart anything during this install, so grading the installer's
  # kill-the-survivor logic against it would be vacuous - that logic exists precisely because
  # disabling the SERVICE does not stop the already-running PROCESS (the 81d2b79 brick).
  QTEST_VM=$2 qrun "cmd /c sc config xenbus_monitor start= auto >nul & sc start xenbus_monitor >nul 2>&1 & echo ARMED" 2>/dev/null \
    | grep -qa ARMED || { no "$3-seeded: could not arm - cell inconclusive"; return; }
  local mst; mst=$(QTEST_VM=$2 qrun 'cmd /c sc query xenbus_monitor' 2>/dev/null | tr -d '\r' | grep -aoE 'RUNNING|STOPPED' | head -1)
  if [ "$mst" = RUNNING ]; then
    ok "$3-seeded: monitor armed AND RUNNING (start=auto) - the field state"
  else
    # Report it rather than proceeding silently: the cell can still run, but it is no longer the
    # armed-monitor variant and must not be cited as one.
    no "$3-seeded: INVALID-PRECONDITION - monitor is '${mst:-unreadable}', not RUNNING; this is not the armed-monitor arm"
  fi
  locate_release_disc "$2" "$3-seeded" || return
  ENTRY_PRISTINE=0; EXPECT_MODE="${SEEDED_EXPECT_MODE:-}"; CELL_PRIMED=1
  run_install "$2" "$3-seeded" "$RELDISC"
  detach_release_iso "$2" "$3-seeded"
  if [ "$(w_state "$2")" = Halted ]; then
    say "  the guest HALTED during the install - this is the reproduction if it now fails to boot"
    start_vm "$2"
  fi
  verify_installed "$2" "$3-seeded"
  accept_grade "$2" "$3-seeded"
}

cell_stock(){ # $1=stock-4.2.2 fixture $2=subject $3=tag - CAPABILITY ONLY, never a default cell
  # Owner 2026-09-03: never RE-test stock per campaign. The capability stays for the rare
  # deliberate run, but the entry is a stock fixture built on demand by
  #     mgmt/harness/prime-run.sh <base> <fixture> stock-422
  # (provisioning, NEVER uninstalling: the old in-cell "uninstall ours, push the vendor MSI"
  # construction is gone - it pushed a payload, and stock preconditions built by uninstalling
  # were already ruled out in findings/install.md: the only proven route for the stock MSI is
  # the provisioning job). Then: the release ISO as a CD installs over stock.
  say "######## CELL $3-stock (stock 4.2.2 fixture [$1] -> release, installed from the ISO) ########"
  local entry=$1 vm=$2 tag=$3
  ensure_churn_target "$vm" || return
  reclone "$entry" "$vm" || { no "$tag-stock: could not reclone"; return; }
  boot_with_release_iso "$vm" "$tag-stock" || return
  w_session "$vm" 900 "$tag-stock-boot" "$M" say || { no "$tag-stock: clone did not boot"; return; }
  # PRESENCE via the authoritative signal (MSI product registrations - qwt_products); the ITL
  # Version key is then a legitimate STOCKNESS discriminator, because stock 4.2.2 writes it and
  # our NG QWT does not. So here "key empty" means "not stock" - never "no QWT", which qwt_products
  # has already ruled on. (Presence-by-reg-key is the exact false negative that voided
  # matrix-4318's upgrade cell.)
  local n; n=$(qwt_products "$vm")
  if [ -z "$n" ]; then
    no "$tag-stock: INVALID-INSTRUMENT - could not count QWT products at entry (missing data fails; it never reads as 'absent')"; return
  elif [ "$n" -lt 1 ] 2>/dev/null; then
    no "$tag-stock: entry carries NO installed QWT (QWTPRODUCTS=0) - build the fixture with prime-run job stock-422; cell INVALID"; return
  fi
  local sv; sv=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v Version' 2>/dev/null | tr -d '\r' | grep -a REG_SZ | head -1)
  say "  QWT at entry: QWTPRODUCTS=$n, ITL Version key: ${sv:-<empty - ours leaves it unset>}"
  case "$sv" in
    *4.2.2*) ok "$tag-stock: precondition real (stock 4.2.2 installed, QWTPRODUCTS=$n)" ;;
    *) no "$tag-stock: entry carries A QWT but not stock 4.2.2 (Version key: ${sv:-empty}) - build the fixture with prime-run job stock-422; cell INVALID"; return ;;
  esac
  locate_release_disc "$vm" "$tag-stock" || return
  ENTRY_PRISTINE=0; EXPECT_MODE=in-place-msi-major-upgrade; CELL_PRIMED=1
  run_install "$vm" "$tag-stock" "$RELDISC"
  detach_release_iso "$vm" "$tag-stock"
  if [ "$(w_state "$vm")" = Halted ]; then start_vm "$vm"; fi
  verify_installed "$vm" "$tag-stock"
  accept_grade "$vm" "$tag-stock"
}

cell_appvm(){ # $1=unused $2=tpl $3=tag $4=appvm $5=churn-subject (source of the 'installed' park)
  say "######## CELL $3-appvm (restore 'installed' park into the template, derive AppVM, cold boot) ########"
  local tpl=$2 app=${4:-} acc=${5:-}
  [ -n "$app" ] || { no "$3-appvm: no AppVM name"; return; }
  [ -n "$acc" ] || { no "$3-appvm: no churn-subject name (source of the 'installed' park)"; return; }
  # This cell derives an AppVM instead of recloning, so it never passed through reclone's H3.6
  # guard - and it is the cell most likely to follow an install cell on the other OS. Halt
  # everything else first, the template included (the AppVM must be derived from a HALTED template
  # anyway, which the check just below re-asserts).
  _halt_other_windows "$app"
  if [ "$(w_state "$tpl")" != Halted ]; then
    qvm-shutdown "$tpl" >/dev/null 2>&1
    w_halt "$tpl" 420 "$3-appvm-tplhalt" say || { no "$3-appvm: template would not halt"; return; }
  fi
  # SNAPSHOT ENTRY (owner: "we do snapshots for optimizations"). The AppVM boots the template's
  # system volume, so what this cell grades is whatever the template carries. Under the churn-
  # target model NO install cell touches the template any more - the ONLY way the release gets
  # onto it is the CROSS-VM volume restore of the campaign's 'installed' park (parked from the
  # churn subject by the clean cell): checkpoint.sh unpark <tpl> installed <acc>. A volume clone
  # is legal on a TemplateVM with a bound AppVM; a recreate is refused by dom0 while a dependent
  # exists - matrix-4318's upgrade cell failed exactly there ("could not create win10-tpl").
  # Without a park there is NO deterministic release-carrying state to derive from ("AS-IS" used
  # to mean "the previous install cell's result"; now it would mean "whatever the template last
  # happened to hold"), so a missing park is a hard refusal, not a downgrade.
  if ! qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "ckpt-$acc-installed"; then
    no "$3-appvm: no 'installed' park (ckpt-$acc-installed) - run the clean cell first; the appvm cell only ever enters from that park"
    return
  fi
  if ./mgmt/harness/checkpoint.sh unpark "$tpl" installed "$acc" >>"$R" 2>&1; then
    say "  $3-appvm: template $tpl restored from ckpt-$acc-installed (cross-vm volume restore - release installed)"
  else
    no "$3-appvm: cross-vm unpark of ckpt-$acc-installed into $tpl FAILED (see $R) - refusing to grade a template in an unknown state"
    return
  fi
  # AppVM private seeds from the template private AT CREATION only; re-basing a template under an
  # existing AppVM leaves a stale private (no profile -> no shell) - so re-create, never reuse.
  # (Owner correction, 2026-09-04.) QWT redirects C:\Users onto the private volume, and dom0
  # copies the template's private into an AppVM's private ONLY at qvm-create - neither
  # `qvm-prefs <app> template <tpl>` nor the volume restore above ever re-seeds it. Measured: the
  # reused AppVM autologons against the stale profile, explorer never starts, NO desktop shell,
  # and every pushrun/w_usersession dies as a silent timeout - while the template itself boots
  # fine. The line that stood here was exactly that reuse (`qvm-prefs "$app" template "$tpl"`).
  local applabel= appnetvm= had_app=0
  if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$app"; then
    had_app=1
    applabel=$(qvm-prefs "$app" label 2>/dev/null)
    appnetvm=$(qvm-prefs "$app" netvm 2>/dev/null)
    if [ "$(w_state "$app")" != Halted ]; then
      qvm-shutdown "$app" >/dev/null 2>&1
      w_halt "$app" 420 "$3-appvm-halt" say || { no "$3-appvm: $app would not halt for re-create"; return; }
    fi
    if ! qvm-remove -f "$app" >/dev/null 2>&1 || qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$app"; then
      no "$3-appvm: could not remove $app - REFUSING to reuse it (its private volume is stale; grading it would reproduce the no-shell defect)"
      return
    fi
    say "  $3-appvm: removed stale $app (label=${applabel:-?}, netvm='${appnetvm:-}' recorded for re-apply)"
  fi
  qvm-create --class AppVM --template "$tpl" --label "${applabel:-red}" "$app" \
    || { no "$3-appvm: qvm-create $app from $tpl FAILED - no subject to grade"; return; }
  # Re-apply what creation does not carry. TAG FIRST - dom0 policy is tag-based; every qtest/qvm
  # call below is refused until it lands. The pvnic latch and autologon live on the template ROOT
  # and need no re-apply. netvm was never this cell's contract (it never set one; the subject's
  # posture belonged to the caller) - restore exactly what the removed AppVM carried, and leave a
  # first-time subject offline; callers exercising the PV NIC attach their own.
  qvm-tags "$app" add win-idd-testbed \
    || { no "$3-appvm: could not TAG $app win-idd-testbed - dom0 policy will refuse every call to it; not proceeding"; return; }
  qvm-features "$app" os Windows >/dev/null 2>&1
  qvm-prefs "$app" memory 8192 >/dev/null 2>&1; qvm-prefs "$app" maxmem 0 >/dev/null 2>&1
  qvm-prefs "$app" vcpus 4 >/dev/null 2>&1; qvm-prefs "$app" qrexec_timeout 6000 >/dev/null 2>&1
  if [ "$had_app" = 1 ]; then
    qvm-prefs "$app" netvm "${appnetvm:-}" 2>/dev/null \
      || say "  WARNING: could not restore netvm='${appnetvm:-}' on $app - re-apply it before any network use"
  else
    qvm-prefs "$app" netvm '' >/dev/null 2>&1
  fi
  say "  $app re-created FRESH from $tpl (private auto-seeded from the template's private at creation)"
  local b
  for b in 1 2 3; do
    say "  --- $3 AppVM cold boot $b/3 ---"
    if [ "$(w_state "$app")" != Halted ]; then
      qvm-shutdown "$app" >/dev/null 2>&1; w_halt "$app" 420 "$3-appvm-b${b}-halt" say >/dev/null 2>&1
    fi
    start_vm "$app"
    w_session "$app" 900 "$3-appvm-b$b" "$M" say
    case $? in
      0) : ;;
      1) no "$3-appvm boot $b: terminal state, guest unusable"; return ;;
      2) no "$3-appvm boot $b: no session within 900s"; return ;;
    esac
    # MECHANIZED stale-private guard (e2e-wait.sh w_appvm_shell): w_session proves only the
    # SYSTEM qrexec channel, which a stale-private AppVM answers happily while explorer never
    # starts - the exact defect the re-create above removes. If it ever recurs (re-create
    # skipped, a future reuse path), it must fail HERE, loudly and self-diagnosed, not as a
    # silent pushrun timeout downstream. P2's boot path (protocol/steps/p2-network.json,
    # p2-boot-appvm) should chain this after its w_session/w_usersession pair too.
    w_appvm_shell "$app" 600 "$3-appvm-b$b-shell" "$M" say
    case $? in
      0) : ;;
      1) no "$3-appvm boot $b: logon session but NO desktop shell - STALE PRIVATE VOLUME (an AppVM reused across a template re-base; the re-create in this cell exists to prevent exactly this - see the w_appvm_shell diagnosis in $R)"; return ;;
      2) no "$3-appvm boot $b: no desktop shell within 600s"; return ;;
    esac
    # Pixels, not logs: open notepad and require a mapped, non-fullscreen window.
    QTEST_VM=$app timeout -k 5 45 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1
    local try W=0 big=0 f w h
    for try in 1 2 3 4 5 6; do
      sleep 7
      rm -f $M/$3-appvm-b$b.tar
      QTEST_VM=$app timeout -k 8 120 ./tools/qtest shot $M/$3-appvm-b$b.tar >/dev/null 2>&1
      [ -s $M/$3-appvm-b$b.tar ] && [ "$(tar tf $M/$3-appvm-b$b.tar 2>/dev/null | grep -c '\.png$')" -gt 0 ] && break
    done
    rm -rf $M/$3-appvm-b$b-png; mkdir -p $M/$3-appvm-b$b-png
    tar xf $M/$3-appvm-b$b.tar -C $M/$3-appvm-b$b-png 2>/dev/null
    for f in $M/$3-appvm-b$b-png/*.png; do
      [ -e "$f" ] || continue
      W=$((W+1)); read -r w h < <(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(33); w,h=struct.unpack('>II',d[16:24]); print(w,h)" "$f" 2>/dev/null)
      [ -z "${w:-}" ] && continue
      say "    $(basename $f) ${w}x${h}"
      [ "$w" -ge $(( 5120 * 99 / 100 )) ] && [ "$h" -ge $(( 1440 * 99 / 100 )) ] && big=1
    done
    QTEST_VM=$app timeout -k 5 45 ./tools/qtest run 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1
    if [ "$big" = 1 ]; then no "$3-appvm boot $b: a FULLSCREEN-SIZED window was mapped"
    elif [ "$W" -gt 0 ]; then ok "$3-appvm boot $b: $W window(s) mapped, none fullscreen-sized"
    else no "$3-appvm boot $b: notepad opened but dom0 got NO window"; fi
  done
}

# --------------------------------------------------------------------------- driver
# GATE-0: the release package is verified BEFORE anything touches a guest, and it is the ONLY
# source of our code in every cell. RELEASE_SETUP names the release setup tree (the extracted
# qwt-improved-setup artifact - prime-run's --payload); RELEASE_ISO/RELEASE_LOOP name the SAME
# release's ISO for the over-existing cells. Deliberately NO default: a default pointing at a
# stale tree is exactly how a 4.3.15 tarball once stood in for the release under test.
#
# BOOK INTERFACE (campaign.json s1-download -> s6-matrix, reconciled 2026-09-03): when the runner
# supplies MATRIX_WORK (the `gh run download` area the book stages in s1), the release inputs are
# DERIVED from it - {MATRIX_WORK}/dl is not "a default pointing at a stale tree", it is the very
# directory Gate-0 (s1-gate0) and the regate (s5) just verified, and deriving from it is what
# removes the per-run hand-editing the runner exists to abolish. An explicit RELEASE_SETUP /
# RELEASE_ISO / RELEASE_COMMIT always wins; with no MATRIX_WORK nothing is derived and the
# hard FATALs below keep their old bite.
if [ -z "${RELEASE_SETUP:-}" ] && [ -n "${MATRIX_WORK:-}" ] && [ -d "$MATRIX_WORK/dl/qwt-improved-setup" ]; then
  RELEASE_SETUP="$MATRIX_WORK/dl/qwt-improved-setup"
  say "RELEASE_SETUP derived from MATRIX_WORK: $RELEASE_SETUP"
fi
if [ -z "${RELEASE_ISO:-}" ] && [ -z "${RELEASE_LOOP:-}" ] && [ -n "${MATRIX_WORK:-}" ] \
   && [ -s "$MATRIX_WORK/dl/qwt-improved-iso/qwt-improved-setup.iso" ]; then
  RELEASE_ISO="$MATRIX_WORK/dl/qwt-improved-iso/qwt-improved-setup.iso"
  say "RELEASE_ISO derived from MATRIX_WORK: $RELEASE_ISO"
fi
[ -n "${RELEASE_SETUP:-}" ] || {
  say "FATAL: RELEASE_SETUP is unset. Point it at the release setup tree, e.g."
  say "  RELEASE_SETUP=\$HOME/deslice-dl-setup RELEASE_ISO=\$HOME/rel/qwt-improved-setup.iso \\"
  say "  RELEASE_COMMIT=<sha> CELLS=\"win10-clean win10-reinstall\" G10=win10-iqi mgmt/harness/matrix.sh"
  exit 1; }
[ -d "$RELEASE_SETUP" ] || { say "FATAL: RELEASE_SETUP=$RELEASE_SETUP is not a directory"; exit 1; }
# RELEASE_COMMIT, when the caller does not pin one, comes from the setup tree's OWN MANIFEST
# (source.driver_repo_commit) - the artifact then gates against the commit it says it was built
# from, which keeps Gate-0's sums/installer checks honest for a standalone invocation. A CAMPAIGN
# must still pin explicitly (campaign.json passes RELEASE_COMMIT={REL}): self-gating proves
# internal consistency, only the external pin proves it is the release the campaign intends.
# Falling back to HEAD is the last resort and says so - HEAD moves under a campaign.
if [ -z "${RELEASE_COMMIT:-}" ]; then
  RELEASE_COMMIT=$(python3 -c "import json;print((json.load(open('$RELEASE_SETUP/MANIFEST.json')).get('source') or {}).get('driver_repo_commit') or '')" 2>/dev/null)
  if [ -n "$RELEASE_COMMIT" ]; then
    say "RELEASE_COMMIT derived from the setup MANIFEST: ${RELEASE_COMMIT:0:12} (self-consistency only - a campaign passes the pin explicitly)"
  else
    say "WARNING: RELEASE_COMMIT unset and the MANIFEST names no commit - gating against HEAD, which is WRONG for a campaign"
  fi
fi
RELEASE_REF="${RELEASE_COMMIT:-HEAD}"
RELEASE_SHA=$(git rev-parse "$RELEASE_REF" 2>/dev/null)
[ -n "$RELEASE_SHA" ] || { say "FATAL: cannot resolve RELEASE_COMMIT='$RELEASE_REF' in this repo"; exit 1; }
if ./tools/assert-payload.sh "$RELEASE_SETUP" "$RELEASE_REF" >"$M/setup-gate0.out" 2>&1; then
  say "Gate-0 (setup tree): $(tail -1 "$M/setup-gate0.out")"
else
  say "FATAL: Gate-0 FAILED on RELEASE_SETUP=$RELEASE_SETUP:"
  tail -3 "$M/setup-gate0.out" | sed 's/^/  /' | tee -a "$R"
  exit 1
fi
# ASHA is the release binary's hash, and verify_installed greps the guest's RESULT for
# "installed_gui_agent_sha256":"$ASHA. If it were empty that grep would degenerate to matching the
# bare key - i.e. ANY result passes without ever checking which build installed (INVALID-
# WRONGBUILD). The release ships the byte-exact agent at reference/gui-agent.exe and names its
# hash in MANIFEST.json reference_binaries; require BOTH and require them to AGREE. Fail closed.
[ -s "$RELEASE_SETUP/reference/gui-agent.exe" ] || {
  say "FATAL: $RELEASE_SETUP/reference/gui-agent.exe missing - without it the agent-hash check"
  say "       silently matches any build and every cell would report a vacuous PASS."
  exit 1; }
ASHA=$(sha256sum "$RELEASE_SETUP/reference/gui-agent.exe" | cut -c1-12)
MSHA=$(python3 -c "import json;print((json.load(open('$RELEASE_SETUP/MANIFEST.json')).get('reference_binaries') or {}).get('gui-agent.exe',''))" 2>/dev/null | cut -c1-12)
{ [ -n "$ASHA" ] && [ "$ASHA" = "$MSHA" ]; } || {
  say "FATAL: reference/gui-agent.exe hash ('$ASHA') disagrees with MANIFEST reference_binaries ('$MSHA')"
  exit 1; }
PV=$(python3 -c "import json;print(json.load(open('$RELEASE_SETUP/MANIFEST.json'))['package_version'])")
# ENTRY IMAGES + CUSTODY GATE.
#
# B10/B11 = the pristine bases the clean cells prime from. These DEFAULT to win10-base/win11-base
# because the owner's model names exactly those two as the ONLY sealed goldens - there is nothing
# else a clean cell could legitimately enter from. Their seal is verified here AND again by
# prime-run itself (both fail closed).
#
# G10/G11 = the entry image for the OVER-EXISTING cells (upgrade/seeded: a previous-ours fixture
# such as win10-iqi; stock: a stock-422 fixture). NO DEFAULT (2026-08-30): the old default
# carried the release under test, which silently turned every upgrade cell into a same-version
# reinstall. Name it explicitly or the run does not start.
B10="${B10:-win10-base}"
B11="${B11:-win11-base}"

# A10/A11 = the DISPOSABLE per-OS churn subjects EVERY install cell targets (TARGET MODEL above).
# Fixed names, deliberately not knobs ("do not complicate the controls"): prime-run recreates
# them freely, ensure_churn_target creates them on demand, and nothing - no AppVM, no derived
# state - may ever bind to them. The templates (win10-tpl/win11-tpl) are NEVER an install-cell
# target; only the appvm cell touches them, by volume restore.
A10=win10-acc
A11=win11-acc

# CUSTODY GATE - two acceptable provenances, both strict, neither optional.
#   sealed golden : golden.sh verify   - untouched since it was sealed
#   fixture       : golden.sh fixture  - built by prime-run.sh from a base whose seal STILL verifies
# Owner decision 2026-08-30: only the pristine bases are sealed; software-carrying preconditions are
# transient fixtures. So demanding a seal from every entry image would block the upgrade cells
# entirely, while accepting anything unchecked is how a contaminated golden poisoned a whole
# campaign. Hence: one of the two, always, and say which.
# A churn target can never be an entry image: the install cells recreate/overwrite A10/A11
# freely (prime-run removes and recreates its target; reclone clones over the volumes), so an
# operator pointing an entry variable at one would have the cell destroy its own entry state.
for g in "$B10" "$B11" "${G10:-}" "${G11:-}"; do
  case "$g" in
    "$A10"|"$A11")
      say "FATAL: entry image '$g' is a CHURN TARGET (disposable install subject) - the cells"
      say "       recreate it freely, so it can never serve as an entry image. Name a sealed"
      say "       base (B10/B11) or a fixture (G10/G11) instead."
      exit 1 ;;
  esac
done
for g in "${G10:-}" "${G11:-}"; do
  [ -n "$g" ] || continue
  if ./mgmt/golden.sh verify "$g" >/dev/null 2>&1; then
    say "  entry $g: SEALED GOLDEN, intact"
  elif ./mgmt/golden.sh fixture "$g" >/dev/null 2>&1; then
    say "  entry $g: CAMPAIGN FIXTURE, $(./mgmt/golden.sh fixture "$g" | head -1 | sed 's/^FIXTURE //')"
  else
    say "FATAL: entry image $g has NEITHER an intact seal NOR a fixture record."
    say "       ./mgmt/golden.sh verify $g    # if it is meant to be a sealed golden"
    say "       ./mgmt/golden.sh fixture $g   # if it is meant to be a campaign fixture"
    say "       Cloning from it would inherit whatever it happens to contain."
    exit 1
  fi
done

say "=== MATRIX for $PV (agent $ASHA) ==="
# CELLS used to default to "seeded", which matches NO case arm below: the driver would fall
# straight through and print "0 passed, 0 failed" - a run that looks completed and tested nothing.
# A campaign with no cells is an operator error, not a default.
[ -n "${CELLS:-}" ] || {
  say "FATAL: CELLS is unset. Name the cells explicitly, e.g."
  say "  CELLS=\"win10-clean win10-reinstall win10-upgrade win10-appvm win11-clean win11-appvm\""
  say "  (win1X-stock exists as a capability but is never a default: stock is not re-tested per campaign)"
  exit 1; }
say "  cells: $CELLS"
# PER-CELL PREFLIGHT, before anything boots.
#  - over-existing cells (upgrade/seeded/stock) reclone from G10/G11: an unset G would hand
#    reclone an EMPTY golden name, so it is an operator error caught here;
#  - clean cells prime from B10/B11, whose SEAL must verify (they are the only sealed goldens;
#    prime-run re-verifies, but a drifted base should abort before any guest churn);
#  - every cell that installs from the ISO needs the release loop resolved and Gate-0'd.
NEED_ISO=0
for c in $CELLS; do
  case $c in
    win10-upgrade|win10-seeded|win10-stock)
      [ -n "${G10:-}" ] || { say "FATAL: cell '$c' needs G10 set (the Win10 entry image: previous-ours or stock fixture)"; exit 1; }
      NEED_ISO=1 ;;
    win11-upgrade|win11-seeded|win11-stock)
      [ -n "${G11:-}" ] || { say "FATAL: cell '$c' needs G11 set (the Win11 entry image: previous-ours or stock fixture)"; exit 1; }
      NEED_ISO=1 ;;
    win10-reinstall|win11-reinstall) NEED_ISO=1 ;;
    win10-clean)
      ./mgmt/golden.sh verify "$B10" >/dev/null 2>&1 \
        || { say "FATAL: base $B10 failed its seal check - a clean cell cannot enter from a drifted base"; exit 1; }
      say "  base $B10: SEALED GOLDEN, intact" ;;
    win11-clean)
      ./mgmt/golden.sh verify "$B11" >/dev/null 2>&1 \
        || { say "FATAL: base $B11 failed its seal check - a clean cell cannot enter from a drifted base"; exit 1; }
      say "  base $B11: SEALED GOLDEN, intact" ;;
  esac
done
[ "$NEED_ISO" = 1 ] && ensure_release_loop
for c in $CELLS; do
  case $c in
    # INSTALL CELLS churn the disposable subjects A10/A11 - NEVER win10-tpl/win11-tpl (TARGET
    # MODEL above; matrix-4318: prime-run cannot recreate a template with a bound AppVM). The
    # appvm cell is the only one that touches a template, and only by volume restore from the
    # churn subject's 'installed' park.
    win10-clean)     cell_clean     "$B10" "$A10" WIN10 ;;
    win11-clean)     cell_clean     "$B11" "$A11" WIN11 ;;
    win10-reinstall) cell_reinstall "$A10" WIN10 ;;
    win11-reinstall) cell_reinstall "$A11" WIN11 ;;
    win10-upgrade)   cell_upgrade   "$G10" "$A10" WIN10 ;;
    win11-upgrade)   cell_upgrade   "$G11" "$A11" WIN11 ;;
    win10-seeded)    cell_seeded    "$G10" "$A10" WIN10 ;;
    win11-seeded)    cell_seeded    "$G11" "$A11" WIN11 ;;
    win10-stock)     cell_stock     "$G10" "$A10" WIN10 ;;
    win11-stock)     cell_stock     "$G11" "$A11" WIN11 ;;
    grade10)         cell_grade     "${GRADE_VM:?set GRADE_VM to the guest to grade}" WIN10 ;;
    grade11)         cell_grade     "${GRADE_VM:?set GRADE_VM to the guest to grade}" WIN11 ;;
    win10-appvm)     cell_appvm     - win10-tpl WIN10 win10-app "$A10" ;;
    win11-appvm)     cell_appvm     - win11-tpl WIN11 win11-app "$A11" ;;
    # The RETIRED selectors fail with the reason, not as a bare typo: they are the cells that
    # installed from a PUSHED payload, which the owner forbids absolutely.
    win10-fresh|win11-fresh|win10-1stage|win11-1stage|win10-2stage|win11-2stage)
      say "FATAL: cell '$c' is RETIRED - it installed from a pushed payload tree (push_payload"
      say "       q4315), which is forbidden: our code enters a guest ONLY from the release"
      say "       package. Clean install = win1X-clean (prime-run from the pristine base; the"
      say "       base's testsigning OFF makes it the true two-stage path)."
      FAIL=$((FAIL+1)) ;;
    # An unknown selector must FAIL the campaign, not be narrated past: a typo would otherwise
    # silently shrink the matrix and the summary would still read as a clean run.
    *) say "FATAL: unknown cell '$c'"; FAIL=$((FAIL+1)) ;;
  esac
done
# PRECONDITION EVIDENCE for the book's s7 judgement (p1-precondition-authority): one entry per
# install cell, carrying the '=== PRECONDITION ===' line from THIS run's log slice (the .cur file
# verify_installed cut past the run marker; the full final log only when no slice exists). The
# installer's line is the authority on found state (P1.0); this file only COLLECTS it - the
# match-vs-label ruling belongs to the campaign's scorer (tools/rnd-score.py precondition-authority),
# never to the harness. Cells that died before verify_installed produce no entry, and the matrix's
# own non-zero exit has already failed the campaign step in that case.
{
  echo "Cell-by-cell PRECONDITION lines, extracted from each cell's install-log slice."
  echo "(The '=== PRECONDITION ===' line is the installer's own report of the state it FOUND;"
  echo "it is the authority on cell identity - P1.0.)"
  echo ""
  for f in "$M"/*-final.log; do
    [ -e "$f" ] || continue
    lbl=$(basename "$f"); lbl=${lbl%-final.log}
    src="$M/$lbl-final.cur"; [ -s "$src" ] || src="$f"
    pline=$(grep -a '=== PRECONDITION === {' "$src" | head -1 | sed 's/.*=== PRECONDITION === /=== PRECONDITION === /')
    echo "cell $lbl"
    if [ -n "$pline" ]; then echo "  $pline"; else echo "  <NO PRECONDITION LINE in $(basename "$src")>"; fi
    echo ""
  done
} > "$M/precondition-lines.txt"
say "precondition lines collected: $M/precondition-lines.txt"

say ""
# The footer and DONE marker are printed WITHOUT say's timestamp prefix, deliberately: they are
# the machine-readable contract the book keys on (campaign.json s6-matrix expects
# '^=== MATRIX: N passed, M failed ===$' and s6-nonvacuous greps the same anchor in matrix.log).
# A timestamped footer matches neither - measured as exactly the book<->code divergence class
# this file was reconciled for on 2026-09-03.
echo "=== MATRIX: $PASS passed, $FAIL failed ===" | tee -a "$R"
# Parks are campaign-scoped: pool cost grows as content diverges, so remove them when the
# campaign is DONE (not per cell - later cells unpark them). NEVER park or remove a golden.
parks=$(qvm-ls --raw-data --fields NAME 2>/dev/null | grep '^ckpt-' | tr '\n' ' ')
[ -n "${parks// /}" ] && say "parks on the rig (remove at campaign end with qvm-remove): $parks"
echo "=== DONE ===" | tee -a "$R"
# A failed or aborted cell fails the WHOLE invocation, mechanically. The 2026-08-30 campaign was
# reported complete over a failing matrix because the summary was prose and the exit code said
# nothing; campaign.json's s6-matrix (and its defect-cell-fail fixture) expect exit 1 here.
[ "$FAIL" -eq 0 ] || exit 1
exit 0
