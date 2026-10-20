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
. "$(dirname "$0")/shutdown-lib.sh"
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
source mgmt/harness/lifecycle-lib.sh   # ctl_start/ctl_stop: the notepad a cell starts is stopped by its recorded identity, never by name
source mgmt/harness/logvol-lib.sh
source mgmt/harness/specimen-lib.sh   # a cell that keeps its subject as evidence writes that down; the boot gate then refuses a hand-typed start
source mgmt/harness/blockclaim-lib.sh # a --required claim on a released loop makes a subject UNCREATABLE; swept before every start, dropped at exit
# THE SECONDARY LOG VOLUME (PLAN-acceptance-optimization section 3), for the WEDGE case: when a cell
# hangs with qrexec dead, QWT's per-module logs sit on a volume this qube reads with mtools - guest
# running or not, nothing detached. The library landed 2026-10-13 and NO harness called it, so a
# wedged cell still lost exactly the logs that show vchan pressure. LOGVOL_VM/LOGVOL_IMG are set
# when a subject boots and consumed by the pull after each cell.
LOGVOL_VM=""; LOGVOL_IMG=""
# Bind QWT's logs to the volume once a SESSION exists. The binder runs INSIDE the guest via
# `qtest pushrun`, which needs a logged-on session, so it cannot be done when the volume is attached
# (that happens before the guest is even created). Without this the volume is attached and stays
# EMPTY, and the pull after the cell yields nothing - an instrument that reports success and
# collects no data, which is worse than no instrument.
# Every caller of this has just finished an install, so the clock feature needs clearing here too.
logvol_bind_now(){ # $1=vm $2=label
  clock_feature_report "$1" "$2"
  # ON BY DEFAULT since 2026-10-19 (LOGVOL_BIND=0 to opt out). This default has been wrong in both directions and
  # its stated REASON has been wrong once more, so what was measured, what was judged and what is
  # still open are kept apart below.
  #
  # THE MECHANISM THIS COMMENT ASSERTED UNTIL 2026-10-19 IS REFUTED. It read: "the bind points
  # LogDir at a removable volume, which need not be mounted when a service starts; every QWT module
  # reads LogDir once, at its own LogInit; a USB volume behind an emulated xHCI controller enumerates
  # on its own schedule, so a module that starts first opens no log at all - and never retries."
  # Jev, over the complete run-8 artifact pack (~/qwt-accept/rel-38629737763-campaign-STOPPED-
  # logvolbind-run8/matrix, verdict in scratchpad/jev-logvolhyp2-out.json): h1_enumeration REFUTED
  # 0.96. The pack, with the clocks resolved (that matrix.log stamped dom0 LOCAL, the guest declared
  # tz=+00:00): WIN10-clean bound at `[01:59:49]` with the volume MOUNTED and the registry written -
  #   LOGVOL-BIND ok mode=registry id=win10-acc drive=Z: found=E: letter=pinned
  #     old=Q:\Qubes Logs new=Z:\qwt-logs\win10-acc copied=21
  # - and was graded at `[02:02:35] [WARN] FAIL  WIN10-clean: console-window check could not judge -
  # INVALID-INSTRUMENT: INSTRUMENT: no gui-agent log found in Z:\qwt-logs\win10-acc on win10-acc`,
  # its health.json reading "agent_pids":[3972], "agent_logs_seen":1, "any_agent_log_held_open":
  # false, "instance_log":"NONE", "log_dirs_searched":["Z:\\qwt-logs\\win10-acc",...] - the
  # registry still naming Z: at grading. WIN10-reinstall then bound at `[02:06:54]` with the volume
  # mounted AGAIN and the registry INTACT -
  #   LOGVOL-BIND ok ... drive=Z: found=D: letter=pinned old=Z:\qwt-logs\win10-acc
  #     new=Z:\qwt-logs\win10-acc copied=0
  # LogDir was consistent and the volume was there both times; what failed is that nothing WROTE
  # to it. This register already held the direct counter-measurement too: logvol-chain-check.sh on
  # win10-acc, 2026-10-15 - after a REBOOT a log on Z: still HELD OPEN, 279 -> 549 lines
  # (findings/issues.md LOGVOLLETTERMOVES) - a module opened its log on the volume at a LogInit
  # after boot, which the paragraph above said cannot happen.
  # The three explanations that paragraph led to were judged on the same pack: a cross-VM restore
  # rolling LogDir back (h2) REFUTED 0.79; the pinned letter dangling when the USB device set
  # changes (h3) REFUTED 0.87 - the pin SUCCEEDED on both binds above, found=E: then found=D:; the
  # installer re-seeding LogDir to Q:\Qubes Logs with `reg add /f`, twice per install, undoing the
  # bind (h4) UNRESOLVED - refuted 0.42 / well_supported 0.30 / plausible_unproven 0.26 - the leading
  # candidate, not called ON THAT PACK. The one measurement that settles h4 is
  #   reg query "HKLM\Software\Invisible Things Lab\Qubes Tools" /v LogDir
  # on a bound guest AFTER an install - and it was TAKEN the same day, on win11de-tup, by d1e2e348
  # (mgmt/harness/logvol-bind.ps1: "A direct read taken 2026-10-19 confirmed it: LogDir = 'Q:\Qubes
  # Logs', no per-module key"). The artifacts this qube holds agree, guest-local = UTC+03:00: the bind
  # `02:00:56` UTC (05:00:56 local); the stick's newest entry
  # `qrexec-wrapper-20261019-050148-10012.log` at 05:01:48; the installer's final.log:222
  # `2026-10-19 05:02:00 [INFO] seeded gui-agent registry defaults (SeamlessMode=1, DisableCursor=1,
  # LogDir)` twelve seconds later; pulls at 02:03:52Z and 02:08:48Z with nothing newer on the stick.
  # Jev on that sequence (scratchpad/jev-a-settled-out.json): a_logdir_shifted established 0.96,
  # stick_exonerated 0.76. d1e2e348 binds through the PER-MODULE key, which that commit shows
  # windows-utils reading before the root (log.c:358, config.c), so the installer's root seed no
  # longer undoes the bind. The run-8-pack verdict above is that pack's reading and stands as such.
  #
  # WHAT STAYS MEASURED (run 8, 2026-10-15): after the cell's park/restore NOTHING new reached the
  # volume - the pull at read_utc=2026-10-14T23:04:41Z lists 25 files whose newest guest-written
  # entries are 22:59 (the bind minute; guest tz=+00:00, so those FAT times ARE UTC) - while the
  # agent was alive and held no log open; the IDD check found no line to read; the console-window
  # check reported INVALID-INSTRUMENT. The same listing shows the trap this comment fell into: the
  # host-written `LOGVOL TAG 2026-10-15 1:50` sits three hours "later" than `win10-acc 2026-10-14
  # 22:59` for an event nine minutes EARLIER - mtools writes dom0 local, the guest wrote UTC.
  # THE PIN WAS NOT THE ANSWER TO THIS. Pin-LogVol fixed the LETTER - the volume is at Z: and stays
  # there across a reboot (logvol-chain-check.sh, 15 links, 0 broke). This comment once carried the
  # measurement AND "ON BY DEFAULT now that the letter is PINNED" in one paragraph, a theory
  # overriding a measurement; it then replaced that theory with the enumeration story, which
  # misled three successive explanations in one night (2026-10-19).
  # AND THE CONTROL IS UNAMBIGUOUS: WIN10-clean's accept battery PASSED in the campaigns before this
  # instrument was wired into it (rel-38522636380 `[10:10:18] PASS  WIN10-clean: accept-clean
  # battery PASS`, rel-38571770442 `[17:02:48] PASS  WIN10-clean: accept-clean battery PASS`) and
  # failed in every campaign since (run 8: `[02:04:41] [ERROR] FAIL  WIN10-clean: accept-clean
  # battery FAILED`). An acceptance run measures the SHIPPED configuration; redirecting the
  # product's log directory onto a test stick substitutes test conditions, and on an unwedged guest
  # qrexec pulls the logs anyway. LOGVOL_BIND=1 is for hunting a wedge, which is what the volume
  # was built for. The stick itself stays ATTACHED either way - it carries the installer's own diag
  # markers.
  # THE DEFAULT IS NOW 1, AND THE PARAGRAPH ABOVE IS WHY IT USED TO BE 0 - read it as history.
  # It rested on one correlation: WIN10-clean's battery passed before this instrument was wired in
  # and failed in every campaign after. Run 8's own lines say what that failure WAS:
  #   [01:59:49]  WIN10-clean: QWT logs bound to the log volume
  #   [02:02:35]  FAIL ... INVALID-INSTRUMENT: no gui-agent log found in Z:\qwt-logs\win10-acc
  #   health.json: agent_pids=[3972] any_agent_log_held_open=false instance_log=NONE
  # The agent was ALIVE and LogDir named a directory nothing was writing to - the LogDir-overwrite
  # defect (the installer forced the root value back five seconds after the bind; established 0.96),
  # not the redirect harming the product. With that fixed, the pin refusing rather than recording a
  # low letter, and the bind re-asserted after the install, the correlation is accounted for and
  # nothing is left that evidences perturbation (Jev perturbation_evidence_left 0.13;
  # substitutes_test_conditions 0.27 - only WHERE logs are written changes, not what is measured).
  # AND WE DEPEND ON IT. The volume exists to read a WEDGED guest, and the 4.3.37 campaign is the
  # case: win11-reinstall went silent after its install reboot ("guest did not answer qrexec after
  # reboot", ACPI ignored, killed) and the cell produced 2 files / 0 QWT lines - nothing to diagnose
  # it with, because the bind was off. Jev enable_for_release_run: enable 0.80, keep_off 0.01.
  # Set LOGVOL_BIND=0 to run on the stock log path deliberately; a bind that cannot pin a high
  # letter REFUSES loudly rather than recording one a PV volume can claim (logvol-bind.ps1).
  [ "${LOGVOL_BIND:-1}" = 1 ] || { say "  $2: log volume NOT bound (LOGVOL_BIND=0) - the guest logs where it ships to"; return 0; }
  [ -n "$LOGVOL_IMG" ] || return 0
  if logvol_bind_guest "$1" "$1" >>"$M/$2-logvol-bind.out" 2>&1; then
    say "  $2: QWT logs bound to the log volume"
    # AND PROVE IT, because a bind that returned ok is not evidence that evidence will arrive.
    # Every instrument failure of the last two campaigns was found AFTER cells were scored, and
    # each was the same class: the path was ASSUMED. This writes a nonce from inside the guest
    # into the LogDir the guest itself resolves, then reads it back off the IMAGE with mtools -
    # no guest needed, which is the property that matters when one wedges. Both halves or nothing.
    if ! logvol_prove_roundtrip "$1" "$LOGVOL_IMG" "$2" >>"$M/$2-logvol-proof.out" 2>&1; then
      say "[ERROR] FATAL: $2: the log path did NOT survive a round trip - $(tail -1 "$M/$2-logvol-proof.out" 2>/dev/null | cut -c1-150)"
      say "[ERROR] FATAL: the guest wrote where it says it writes, or this qube could not read it"
      say "[ERROR] FATAL: back off the image. Either way this cell cannot produce evidence and a"
      say "[ERROR] FATAL: wedge from here would be unreadable, so the campaign STOPS."
      say "=== MATRIX: ${PASS:-0} passed, $(( ${FAIL:-0} + 1 )) failed - ABORTED on an unproven log path ==="
      exit 2
    fi
    say "  $2: log path PROVEN end to end ($(command grep -ao 'nonce=[^ ]*' "$M/$2-logvol-proof.out" 2>/dev/null | tail -1))"
  else
    # HARD. A log device that failed is not a degraded run, it is a run with no instrument that
    # survives a wedge - and the wedge is what this volume exists for. Measured 2026-10-20, run
    # 39225775322 WIN10-clean: this printed [WARN] and carried on; eleven minutes later the guest
    # went SPIN and nothing from inside it survived. Enforced by lint L29.
    say "[ERROR] FATAL: $2: log-volume bind FAILED (see $M/$2-logvol-bind.out)"
    say "[ERROR] FATAL: the log volume is the ONLY instrument that survives a wedge - a guest that"
    say "[ERROR] FATAL: will not halt cannot be asked for its logs, and mtools reads the image with"
    say "[ERROR] FATAL: no guest at all. Grading ANY further cell now produces verdicts about"
    say "[ERROR] FATAL: nothing, so the campaign STOPS HERE rather than spending hours on them."
    say "=== MATRIX: ${PASS:-0} passed, $(( ${FAIL:-0} + 1 )) failed - ABORTED on a log-device failure ==="
    exit 2
  fi
}
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
# HERE was USED (the fallback agent-hash check, and now the boot-to-qrexec probe) but never
# DEFINED. Under `set -u` the reference aborts the surrounding $(...) subshell, so `fhash` came
# back empty and the fallback hash check silently degraded into its "could not hash" branch - a
# verification step that could never actually verify. Found 2026-09-08 while instrumenting boots.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="${MATRIX_OUT:-$HOME/qwt-matrix/$(date -u +%Y%m%d-%H%M%S)}"; mkdir -p "$M"
R=$M/matrix.log; : > "$R"
# UTC, LIKE THE RUNNER THAT DRIVES THIS. tools/release-acceptance.sh stamps `date -u` and this
# stamped `date` (local), so one campaign produced two logs three hours apart with neither line
# saying which: measured 2026-10-14, the driver wrote "[20:29:12] PASS release package verified"
# and this wrote "[23:29:13] Gate-0 ... PASS" for events seconds apart (CAMPAIGNLOGTZSPLIT).
# UTC is the one scale every HOST-side artefact of a campaign shares - every `date` stamp in
# mgmt/harness, tools and the e2e library is `date -u` (tools/tests/harness-clock-selftest.sh T1).
# GUEST-side stamps are NOT: a QWT log line and a log file name carry the guest's LOCAL time, and
# the sweep records the offset once per pull (`tz=+03:00` on win11de-tup, `tz=+00:00` on win10-acc,
# in the collector's BEGIN line). This comment said "guest-side stamps are UTC too" until
# 2026-10-19, the day that assumption read a stick file 42 s older than its bind as three hours
# newer. The say() below therefore writes the zone down as its FIRST line.
# EVERY LINE DECLARES ITS LEVEL - same reason as quick-upgrade.sh's log(): a sweep that can only
# judge the lines carrying a tag is blind to everything else, and it will not gate until its
# coverage is credible. The emitter declares; a caller that already passed a level keeps it.
#
# A LINE DECLARES ONE LEVEL, AND IT IS THE ONE THE SWEEP READS. This matched a level only at the
# very START of the message, and 23 call sites in this file write it after an indent or after the
# cell label - "  $lbl: [WARN] ..." - so each of them produced a line declaring BOTH: "[INFO]
# WIN11-upgrade: [WARN] MSI verbose log NOT retrieved". sweep-gate's level regex matches anywhere,
# so it judged those lines WARNING while they announced INFO, and the two readings of one line
# disagreed. Measured in run 38994277148 on the MSI line; the other 22 are the same shape, latent.
# So: prepend only when the message carries no level at all, which makes "what this line declares"
# single-valued and equal to what the gate reads.
#
# This does not widen the payload's reach. A payload that contains a bracketed level already
# decides how the gate reads the line, whatever this function prepends - the guard against that is
# `tr -d '[]'` where guest text is interpolated (quick-upgrade.sh:824, and the xenbus probe below),
# not a second level on the front.
say(){ case "$*" in
         *'[ERROR]'*|*'[WARN]'*|*'[WARNING]'*|*'[INFO]'*|*'[DEBUG]'*) _m="$*" ;;
         *) _m="[INFO] $*" ;;
       esac
       echo "[$(date -u +%H:%M:%S)] $_m" | tee -a "$R"; }
# THE ZONE IS WRITTEN DOWN ONCE, HERE, because no stamp below carries it. Run 8's matrix.log held
# three clocks: this logger's `date` (dom0 local, until ecf4d904), accept-clean's `date -u` quoted
# INSIDE the same line - "[02:04:41]   WIN10-clean: accept-clean says: 23:04:41 accept[win10-acc]:
# ACCEPT=FAIL" - and arm-module-bases' UTC "[23:02:30] ARMED AND PROVEN" under "[01:50:22] pool:".
# The guest's own stamps are GUEST-LOCAL (the sweep's BEGIN line carries tz=; +03:00 on win11de-tup,
# +00:00 on win10-acc), which is how a stick file 42 s OLDER than its bind read as "three hours
# later" (findings/issues.md AUTOPLAYTOASTTIMESTHESHELL, corrected 2026-10-19). This line keeps the
# `[HH:MM:SS] [INFO] ...` shape every reader of this log matches (sweep-gate.sh:143, :364), so
# declaring the zone moves no anchored field; tools/tests/harness-clock-selftest.sh holds it.
_clk_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ); _clk_loc=$(date +%:z)
say "clock: stamps here are UTC ($_clk_utc; host local is UTC$_clk_loc); guest log stamps and file names are guest-local - convert before comparing"
PASS=0; FAIL=0; INVALID=0
ok(){ PASS=$((PASS+1)); say "PASS  $*"; }

# ---- THIN-POOL FLOOR ---------------------------------------------------------------------------
# Owner, 2026-10-08: "watch the thin pool space meanwhile." This harness had NO space check of any
# kind, which is the worst shape for this failure: the pool fills partway through, a cell dies for a
# reason that looks like the product, and the whole campaign's results are untrustworthy rather than
# merely short. A campaign that REFUSES up front with a number costs minutes; one that dies at cell
# 11 costs the day and teaches nothing.
#
# WHERE THE NUMBER COMES FROM, so it is not invented: the largest Windows root volume measured on
# this rig is 15 GiB (win11de-base). A cell provisions a subject (~15 GiB) and may PARK an installed
# snapshot (~15 GiB more), so ~30 GiB is the worst case for one cell in flight. The floor is that
# plus one cell of slack - refusing with less than 60 GB free, and WARNING below 90 GB so a campaign
# that will get tight says so while there is still time to act.
#
# CORRECTED 2026-10-08, same day: an earlier reading of this rig estimated revisions as
# "usage x revisions" and predicted ~31 GiB back from removing one spent subject. Removing it
# returned 8.7 GB. Revisions are COPY-ON-WRITE and SHARE blocks with the live volume, so that
# arithmetic overestimates badly - which is exactly why this gate reads the pool's own usage figure
# and never computes a prediction from volume sizes.
POOL_FLOOR_GB="${POOL_FLOOR_GB:-60}"
POOL_WARN_GB="${POOL_WARN_GB:-90}"
pool_free_gb(){
    # Prints the free GB as an integer, or nothing if the pool cannot be read. POOL_FREE_GB_STUB
    # exists so this gate can be driven to its refusal without filling a disk (it is seen to fail in
    # tools/tests/matrix-pool-floor-selftest.sh); it is never set in a real run.
    if [ -n "${POOL_FREE_GB_STUB:-}" ]; then echo "$POOL_FREE_GB_STUB"; return 0; fi
    python3 - <<'PYF' 2>/dev/null
import qubesadmin
p = qubesadmin.Qubes().pools['vm-pool']
print(int((int(p.size) - int(p.usage)) / 1e9))
PYF
}
pool_gate(){   # $1 = what is about to run, for the message
    local free; free="$(pool_free_gb)"
    if [ -z "$free" ]; then
        # MISSING DATA FAILS. An unreadable pool is not "probably fine": the one thing this gate
        # exists to prevent is a campaign whose results cannot be trusted.
        say "[ERROR] INVALID-POOL  the thin pool's free space could not be read - refusing to start $1 blind"
        return 1
    fi
    if [ "$free" -lt "$POOL_FLOOR_GB" ]; then
        say "INVALID-POOL  only ${free} GB free on vm-pool, floor is ${POOL_FLOOR_GB} GB - refusing $1."
        say "              One cell needs ~30 GB at peak (a ~15 GiB subject plus a parked snapshot)."
        say "              Reclaim first; a pool that fills mid-campaign invalidates every cell, not just this one."
        return 1
    fi
    [ "$free" -lt "$POOL_WARN_GB" ] && say "[WARN] POOL  ${free} GB free on vm-pool (warn below ${POOL_WARN_GB}) - enough to start, tight to finish"
    say "pool: ${free} GB free on vm-pool (floor ${POOL_FLOOR_GB})"
    return 0
}
pool_gate "this campaign" || { say "=== MATRIX: 0 passed, 1 failed ==="; exit 2; }

# INVALID-* messages (a cell that did not run: precondition not met, instrument gave no data) are
# counted TWICE on purpose: into FAIL, because the footer '=== MATRIX: N passed, M failed ===' and
# the exit code are a machine-read contract (campaign.json s6-matrix + its defect-cell-fail
# fixture) that must keep meaning "not clean"; and into INVALID, so the classes line below tells
# a reader how many of the M are product defects and how many are ungraded cells - V2 ("INVALID-*
# is never folded into FAIL") applied additively, without touching the contract. The TSV ledger
# campaign-verdict.sh reads keeps the classes distinct already; this only stops the LOG from
# conflating them (the residual recorded in protocol/rule-coverage.json).
# Every failing check in this campaign is reported HERE, so this one line decides whether a sweep
# can see any of them. A product FAIL and an ungraded INVALID are different severities and say so.
no(){ FAIL=$((FAIL+1)); local _l="[ERROR] "; case "$*" in *INVALID*) INVALID=$((INVALID+1)); _l="[WARN] " ;; esac; say "${_l}FAIL  $*"; }

# GRADE THE SWEEP'S EXIT CODE, DO NOT READ IT AS A BOOLEAN. log-sweep.sh exits 0 CLEAN, 1 FINDINGS,
# 3 DATA (collected, but something was empty or unparseable), 4 INCOMPLETE (the judge never ran).
# The first version of this treated every non-zero rc as "collection FAILED ... no guest logs for
# this cell", and the first cell it ran on proved that wrong: rc=3 for ONE empty rotation file while
# 37 files and 2631 QWT-format lines sat in the output dir. So each code gets its own line, every
# line states what is actually on disk, and a finding reaches the TALLY rather than only printing -
# a line that only prints is a line nobody reads.
# LOGSWEEP_CMD exists so the self-test can drive each exit code without a guest.
# WHY THERE ARE NO QWT LINES, in the instrument's own terms. "guest logs incomplete (1 file(s), 0
# QWT line(s))" was printed for all four cells on 2026-10-14 and sent me looking at the guest; the
# cause was the instrument every time - no volume attached on the clean path, and a clone with no
# QWT on the ISO path. A data verdict that cannot distinguish "the guest wrote nothing" from "there
# was nothing to write to" is a verdict about nothing.
_matrix_logvol_state(){ # <cell> -> one clause naming the instrument's state
  local d="$M/logvol-$1/files"
  # READ THE FACT THE COLLECTOR ALREADY MEASURED BEFORE GUESSING FROM A VARIABLE. On the 4.3.37
  # campaign (run 39225775322) four of eight cells reported "0 QWT line(s)" and this clause said
  # "no log volume was attached for this cell" - which was FALSE for the two appvm cells, whose
  # volume had attached minutes earlier (LOGVOL-ATTACHED id=win10-app), and useless for the two
  # clean cells, whose bind receipt read LOGVOL-BIND ok with 21 files copied and 15 modules
  # written. LOGVOL_IMG describes a shell variable that the PREVIOUS cell's pull clears, not the
  # rig. The real reason was in the collector's own meta.json all along: logdir.exists=0 - LogDir
  # named a directory the guest could not see at sweep time, so the collector fell back to
  # Q:\Qubes Logs and read only install-era files. A wrong reason on a real failure cost an hour
  # aimed at the bind, which was working.
  local meta="$M/$1-guestlogs/logs/meta.json" lp lx
  if [ -r "$meta" ]; then
    lp=$(python3 -c 'import json,sys,base64; m=json.load(open(sys.argv[1])).get("logdir",{}); print(base64.b64decode(m.get("pathb64","")).decode("utf-8","replace"))' "$meta" 2>/dev/null)
    lx=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("logdir",{}).get("exists",""))' "$meta" 2>/dev/null)
    if [ "$lx" = 0 ] && [ -n "$lp" ]; then
      local onvol=0
      [ -d "$d/qwt-logs" ] && onvol=$(find "$d/qwt-logs" -type f 2>/dev/null | wc -l)
      echo "LogDir '$lp' did not exist in the guest at sweep time (meta.json logdir.exists=0) so the collector fell back and read none of it - the pulled volume holds $onvol file(s)"
      return
    fi
  fi
  [ -n "${LOGVOL_IMG:-}" ] || [ -d "$d" ] || { echo "no log volume was attached for this cell"; return; }
  [ -d "$d" ]              || { echo "the log volume was never pulled, so nothing could be read"; return; }
  [ -d "$d/qwt-logs" ]     || { echo "the volume carries no qwt-logs dir - attached, never bound"; return; }
  local n; n=$(find "$d/qwt-logs" -type f 2>/dev/null | wc -l)
  [ "$n" -gt 0 ]           || { echo "qwt-logs is EMPTY - the bind applies at a module's next start, and no boot followed it"; return; }
  echo "qwt-logs holds $n file(s), none in QWT's line shape"
}

# WHICH GUEST DOES THIS CELL'S SWEEP BELONG TO? A function, so it can be exercised without a
# guest - the same reason grade_cell_logsweep() is one. It was an inline prefix match,
# `win10-*) _slv="$A10"`, and `win10-appvm` matches `win10-*`: the appvm cell's sweep therefore
# targeted the CHURN subject (win10-acc) and not the AppVM it had just graded (win10-app). By
# sweep time the churn subject is parked, so the collector found nothing.
# MEASURED on acceptance run 38826875627: both appvm cells produced NO sweep verdict at all -
# `win10-appvm-guestlogs` held ONE file against win10-clean's FORTY - while the evidence stick they
# had just been given attached and pulled correctly. Two defects were stacked on the same cell, and
# fixing the visible one left it just as blind. The appvm arms must precede the prefix arms.
_matrix_sweep_subject(){ # <cell> <win10-churn> <win11-churn>
  case "$1" in
    win10-appvm) printf '%s' "win10-app" ;;
    win11-appvm) printf '%s' "win11-app" ;;
    win10-*)     printf '%s' "$2" ;;
    win11-*)     printf '%s' "$3" ;;
    *)           printf '%s' "" ;;
  esac
}

grade_cell_logsweep(){ # <cell> <vm> <matrix-dir>
  local c="${1:?grade_cell_logsweep <cell> <vm> <dir>}" vm="${2:?}" m="${3:?}" rc f q have
  # OWNER DECISION 2026-10-17 ("declare those 4 for now"): the geometry-changed branch of
  # RecreateDuplication is DECLARED, not demoted and not fixed. It is the only error line left on a
  # current build once the netsetup fix is packaged, and the gate cannot be satisfied without
  # settling it: rnd8-resolution.sh's own header says "demanding ZERO occurrences would fail a
  # correctly-behaving build", while error_lines_undeclared has max 0. The receipt that would settle
  # it needs a harness that knows about the de-slice, which this one does not
  # (GEOMETRYERRORUNSETTLEABLE). This is an OVERRIDE recorded as an override - the same shape as
  # cutting 4.3.36 on `core` - and it expires with that finding, not with this campaign.
  # THE DISCRIMINATOR IS GUARANTEE, NOT CAUSATION (Jev 0.90, after a first answer of 'caused' 0.91
  # that came from a brief which left this out). A fault injection GUARANTEES its error, so an
  # unmatched declaration means the injection did not happen. An empty netvm, or a probe whose
  # request may or may not still be queued when its bound expires, only PERMITS the line -
  # measured present on two cells of this campaign and absent on four. Absence then proves
  # nothing, and failing a cell for it fails a cell whose product wrote zero error lines.
  # So all three declarations below are TOLERATED (Jev 1.00, conf 1.00); only a guaranteed
  # stimulus is declared CAUSED.
  # TOLERATED, not CAUSED. A caused-style declaration claims a stimulus was applied, so matching
  # nothing is a breach - and this line only appears when a resolution changes, which most cells
  # never do. MEASURED 2026-10-17: as --declare-error it failed win10-appvm, a cell whose product
  # wrote ZERO error lines, on the declaration alone. --tolerate-error still suppresses the line
  # but does not count its absence against the run.
  # Narrow on purpose: it must not cover the FAILED-recovery branch, which is a different line
  # ("failed to recreate duplication after N attempt(s)") and stays an error.
  "${LOGSWEEP_CMD:-./mgmt/harness/log-sweep.sh}" "$vm" "$CAMPAIGN_SINCE" "$m/$c-guestlogs" \
      --tolerate-error '(SetupNetwork: Failed to get qubes-ip|QioWriteBuffer: WriteFile failed with error 0xe8|send_command_to_daemon: write to daemon failed with error 0xe8|wmain: open agent pipe failed with error 0x2)' \
                      'this campaign gives every cell subject an EMPTY netvm (CLAUDE.md: only a guest that TESTS PV networking gets one), so /qubes-ip legitimately does not exist and three modules say so. CAUSED, because the run chose that configuration: a cell WITH a netvm would not produce these, and this declaration would then breach as unmatched (Jev: caused 0.91 conf 0.86). Our own qwtng-netsetup is already at one read per boot; the DOUBLING is the upstream qubesdb client. RETRACTED 2026-10-17, and the retracted sentence was MINE: this used to end -network-setup 4.2.2.0 is stock QWT, neither is ours to change- which I wrote here on 2026-10-16 and then quoted back as the authority for reverting a fix to it. network-setup.exe is RETIRED in this project (guest/pvnic-selfprime.ps1, section REPLACE network-setup.exe FOR GOOD): our installer clears the QWT Autostart value AND DELETES the binary, because clearing Autostart alone was measured on 2026-08-23 not to stop it - it still ran twice per boot and the second run tore down an address that was already correct, recorded as the last per-boot outage. So it is not -not ours to change-, it is ours to REMOVE, and this line appearing at all means the retirement is not in force on that cell. MEASURED in run 38994277148: ZERO network-setup logs on five cells, TWO RUNS IN ONE BOOT on win11-upgrade. Whether it was deleted and returned or was never deleted on that entry fixture is NOT established - see NETSETUPLIVEONUPGRADECELL.' \
      --tolerate-error 'InitVchan: QGAVCHANFAIL .*request dropped' \
                      'the readiness wait abandons its own probe: w_alive bounds each call below the boot it waits for, the request is delivered from the queue when the agent starts, and the caller has gone - nothing a user had is lost (Jev: not hiding 0.27, declare-as-caused 0.72). The bound is fixed in e2e-wait.sh; this declaration covers a cell whose guest still outruns it.' \
      --tolerate-error 'RecreateDuplication: .*BUT THE GEOMETRY CHANGED' \
                      'owner 2026-10-17: a resolution change recovers in place (staging grant kept, work area re-applied, PWCARRY rows carried) and DXGI signals staleness this way by design; declared pending the pixel receipt in GEOMETRYERRORUNSETTLEABLE' \
      >"$m/$c-logsweep.out" 2>&1
  rc=$?
  f=$(find "$m/$c-guestlogs" -type f 2>/dev/null | wc -l)
  # QWT's own line shape, so "collected" is never satisfied by harness bash lines (LOGVOLBINDUPGRADE).
  q=$(grep -rhoaE '^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+' "$m/$c-guestlogs/logs" 2>/dev/null | wc -l)
  have="$f file(s), $q QWT line(s)"
  [ "$q" -gt 0 ] || have="$have; $(_matrix_logvol_state "$c")"
  case "$rc" in
    0) say "  $c: guest logs swept CLEAN ($have) -> $m/$c-guestlogs" ;;
    1) no "$c: the guest log sweep found a breach or a defect ($have). See $m/$c-logsweep.out" ;;
    3) no "$c: INVALID-SWEEP-DATA  guest logs incomplete ($have): $(sed -n 's/.*missing or unparseable data[^:]*: *//p' "$m/$c-logsweep.out" 2>/dev/null | head -1 | cut -c1-120)" ;;
    4) no "$c: INVALID-SWEEP-UNJUDGED  guest logs collected ($have) but the judge never ran - this cell has no sweep verdict" ;;
    # NOT "collection failed": an undocumented rc says nothing about what reached the disk, and the
    # counts beside it may show plenty. State the rc, state what is there, claim nothing more.
    *) no "$c: INVALID-SWEEP-RC  the guest log sweep exited rc=$rc, which it does not document ($have). See $m/$c-logsweep.out" ;;
  esac
  # RENDER WITNESS - OFF BY DEFAULT, FOR DEBUGGING NOTIFICATIONS THEMSELVES.
  # Whether dom0 PAINTED a notification cannot be read from any log: the bubble is override-redirect,
  # absent from _NET_CLIENT_LIST, so the only witness is a photograph of the dom0 desktop - which is
  # the OWNER'S screen, with whatever else is on it. That is why this is a knob and not a default.
  # The owner, asked: "behind a flag, but wtf. if something sends to dom0 and this fact cannot be
  # seen in the logs, it is wrong on so many levels. we need it only when we debug notifications
  # themselves." The logs now DO carry it - notifhost declares E on every delivery that did not land
  # ("NOTIFY one-shot: sent ok=0 ... LOST") and those lines are loudness candidates - so acceptance
  # judges delivery from logs, and this exists only for the case he named.
  if [ "${NOTIFY_WITNESS:-}" = 1 ] && [ -n "$_slv" ]; then
    _nvid="acc-$(date -u +%Y%m%d%H%M%S)-$$"
    _nvout=$(NV_VM="$_slv" NV_ROOT="$PWD" NV_ID="$_nvid" \
             NV_HELPER='C:\Program Files\Qubes Tools\qubes-rpc-services\qwt-notify-error.ps1' \
             ./mgmt/harness/dom0-notify-witness.sh "$_slv" "acc-$c" ./mgmt/harness/notify-render-trigger.sh 2>&1 | tail -40)
    case "$(printf '%s' "$_nvout" | grep -aoE 'WITNESS=[a-z-]+' | tail -1)" in
      WITNESS=RENDERED) say "  $c: dom0 RENDER witnessed (a notification was actually painted)" ;;
      WITNESS=*)        say "  $c: [WARN] render witness did not confirm a painted notification: $(printf '%s' "$_nvout" | grep -aoE 'WITNESS=[a-z-]+.*' | tail -1 | cut -c1-90)" ;;
      *)                say "  $c: [WARN] render witness produced no verdict - see its evidence dir" ;;
    esac
  fi

  # ONE CONDITION, ONE ENTRY IN THE TALLY. Every arm above except rc=0 has already raised, so
  # raising here as well would count a single failed collection twice. The case left to catch is
  # the dangerous one: a sweep that returns CLEAN having read no guest line at all - a clean
  # verdict over nothing, which is the 96-of-96 false comfort this step exists to end.
  if [ "$rc" = 0 ] && [ "$q" -eq 0 ]; then
    no "$c: INVALID-SWEEP-BLIND  the sweep returned CLEAN with no QWT-format line to read ($have)"
  fi
  return 0
}
# qvm-start BLOCKS until qrexec connects (up to qrexec_timeout). On a guest that never boots
# that is dead silence for the whole timeout - measured today: 15 minutes of a harness that
# looked hung was simply sitting inside qvm-start. Fire it and poll the state ourselves.
start_vm(){
  # BOOT-TO-QREXEC IS MEASURED HERE, at the one choke point every cold boot in this matrix goes
  # through. It is the number that actually matters for "how long until dom0 can talk to this
  # qube", and until now nothing recorded it: the cells logged "desktop shell up at t+16s", which
  # is a DIFFERENT quantity (autologon + profile + explorer) and says nothing about the control
  # channel. Measured out-of-band in the background so it cannot perturb what it measures and
  # cannot delay the caller - the caller's own w_session wait is untouched.
  local vm="$1" t0; t0=$(date +%s)
  declare -F assert_sole_guest >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/serial-rig.sh"
  assert_sole_guest "$vm" || exit 1
  timeout -k 10 150 qvm-start "$vm" >/dev/null 2>&1 & disown
  (
    for i in $(seq 1 150); do          # 150 x 4s = 10 min ceiling, then give up and SAY so
      sleep 4
      # CAPTURE, then match. Piped into `grep -q` the producer dies of SIGPIPE, timeout reports
      # 141, and pipefail makes 141 the status - a live guest graded dead. The continuation hid
      # this shape from lint L23 until 2026-10-14.
      if grep -qa QREADY <<< "$(QTEST_VM="$vm" timeout -k 5 20 "$HERE/tools/qtest" run 'cmd /c echo QREADY' 2>/dev/null)"; then
        printf '%s\t%s\t%s\n' "$vm" "$(( $(date +%s) - t0 ))" "answered" >> "$M/boot-to-qrexec.tsv"
        exit 0
      fi
    done
    # NEVER record a missing measurement as a number. A boot that did not reach qrexec inside the
    # ceiling is recorded as such, so an absent guest cannot masquerade as a fast one.
    printf '%s\t%s\t%s\n' "$vm" "-" "no-qrexec-within-600s" >> "$M/boot-to-qrexec.tsv"
  ) & disown
  sleep 8
}

# Release the loop THIS run created (never one it merely reused, and never one another run owns).
# Best-effort: a guest still holding the disc makes the delete fail, which is exactly when reuse
# above is what keeps the count flat.
MATRIX_LOOP_CREATED=""
# Every subject this run handed the release ISO to. `qvm-start --cdrom=<holder>:loopN` leaves a
# `--required` cdrom claim on the guest, and the loop below is then released from under it: from
# that moment the subject CANNOT BE CREATED, and Qubes says only "libxenlight failed to create new
# domain". Measured 2026-10-14 - win10-acc kept `win-idd-mgmt:loop14:*` after this very function
# released /dev/loop14 at 20:47:45, and stayed unstartable. So the claims go before the loop does.
MATRIX_CDROM_CLAIMED=""
_matrix_release_loop(){
  [ -n "${MATRIX_LOOP_CREATED:-}" ] || return 0
  local v
  for v in $MATRIX_CDROM_CLAIMED; do
    claim_drop_loop "$v" "$MATRIX_LOOP_CREATED" >/dev/null 2>&1 \
      && say "  $v: release-ISO claim on /dev/$MATRIX_LOOP_CREATED dropped" \
      || say "  $v: [WARN] could not drop the claim on /dev/$MATRIX_LOOP_CREATED - it may not start next time"
  done
  if udisksctl loop-delete -b "/dev/$MATRIX_LOOP_CREATED" >/dev/null 2>&1; then
    say "  released /dev/$MATRIX_LOOP_CREATED"
  else
    say "  NOTE: /dev/$MATRIX_LOOP_CREATED still in use - left attached (a later run will reuse it)"
  fi
}
trap _matrix_release_loop EXIT

GLOG='C:\qwt-improved-install.log'
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

# ONE READER FOR THE RUN MARKER, because two copies of this read is how the bug below survived.
# SELF-MATCH-SAFE: `qtest run` echoes the prompt line WITH THE COMMAND ON IT, and that command text
# carries both PRESENT and ABSENT. A `grep | head -1` therefore reports PRESENT off the echo
# whenever the guest answers at all - the check can never fail - and reports empty when it does not
# answer, so it is wrong in both directions. quick-upgrade.sh fixed exactly this and the fix was
# never ported here. Strip the banner, then take the guest's OWN last word.
_mark_seen(){ # <vm> -> PRESENT | ABSENT | (empty: no answer)
  QTEST_VM=$1 qrun "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT" 2>/dev/null \
    | tr -d '\r' | _shell_echo_strip | grep -ao 'PRESENT\|ABSENT' | tail -1
}

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
    # ACPI only, and NOTHING here kills: `--wait --timeout 300` was a kill AT 300 (see
    # shutdown-lib.sh), i.e. this guard violated the rule its own comment states.
    qwt_shutdown "$v" 300
    # POLL; do not trust qvm-shutdown's own wait. Measured 2026-09-10 (4.3.26 campaign): it returned
    # after ~60 s on a Windows AppVM that needed longer, this guard WARNED and then proceeded into
    # the prime-run refusal it had just predicted ("TERMINAL: refusing, these are not Halted:
    # win10-app"), failing WIN11-clean. The acceptance runner shut the same guest down 63 s later
    # without trouble - so the guest was fine and only the waiting was wrong. A guard that gives up
    # early and continues anyway is worse than no guard: it converts a rig condition into a
    # product-FAIL against the release.
    local _hi
    for _hi in $(seq 1 60); do
      [ "$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v n="$v" '$1==n{print $2}')" = Halted ] && break
      sleep 5
    done
    if [ "$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v n="$v" '$1==n{print $2}')" != Halted ]; then
      say "  [WARN] $v did not halt within 300s - refusing to run two Windows guests is now unenforceable"
    fi
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
  ) || { say "  [WARN] clone attempt 1 FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"; }

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
      [ -n "$rev" ] || { say "    [WARN] no snapshot for $v - cannot revert"; continue; }
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
    say "  [WARN] clone attempt $att FAILED: $(echo "$cerr" | tail -1 | cut -c1-200)"
  done
  [ -z "$cerr" ] || { say "  [ERROR] clone FAILED after every retry"; return 1; }
  say "  cloned $g -> $t"
  # The volumes just became a fresh copy of the entry image, so whatever this subject was
  # preserving is gone and its marker must go with it. A marker that outlives its specimen would
  # block the NEXT campaign, which is how a guard turns into something to switch off.
  specimen_clear "$t" >/dev/null || true
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
    [ -n "${RELEASE_ISO:-}" ] || { say "[ERROR] FATAL: over-existing cells need RELEASE_ISO (path to qwt-improved-setup.iso) or RELEASE_LOOP (an existing loopN)"; exit 1; }
    [ -s "$RELEASE_ISO" ] || { say "[ERROR] FATAL: RELEASE_ISO=$RELEASE_ISO missing or empty"; exit 1; }
    # REUSE AN EXISTING LOOP FOR THIS EXACT FILE INSTEAD OF ADDING ANOTHER. This function created a
    # fresh loop on every call and nothing ever removed it, so they accumulated for as long as the
    # rig ran: measured 2026-09-10, 45 loop devices, NINE of them backing the same 4.3.24 ISO and six
    # the same 4.3.21 one. quick-upgrade.sh already deletes its own; this one never did.
    #
    # Reuse is the durable half of the fix - it holds even when the delete below cannot run (a killed
    # run, or a guest still holding the disc). A read-only loop over an unchanged file is safe to
    # share: the Gate-0 backing-file and "(deleted)" checks below still run against whatever we end
    # up using, so a stale or wrong-file loop is caught exactly as before.
    local dev
    dev=$(losetup -l 2>/dev/null | awk -v f="$RELEASE_ISO" '$6==f{print $1; exit}')
    if [ -n "$dev" ]; then
      RELEASE_LOOP=${dev#/dev/}
      say "  release ISO already on /dev/$RELEASE_LOOP - reusing it ($RELEASE_ISO)"
    else
      dev=$(udisksctl loop-setup -r -f "$RELEASE_ISO" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
      [ -n "$dev" ] || { say "[ERROR] FATAL: udisksctl loop-setup failed for $RELEASE_ISO"; exit 1; }
      RELEASE_LOOP=${dev#/dev/}
      MATRIX_LOOP_CREATED="$RELEASE_LOOP"      # only OURS is released at exit
      say "  release ISO on /dev/$RELEASE_LOOP ($RELEASE_ISO)"
    fi
  fi
  local backing
  backing=$(losetup -l 2>/dev/null | awk -v d="/dev/$RELEASE_LOOP" '$1==d{print $6}')
  [ -n "$backing" ] || { say "[ERROR] FATAL: /dev/$RELEASE_LOOP is not an active loop device"; exit 1; }
  case "$backing" in *'(deleted)'*)
    say "[ERROR] FATAL: /dev/$RELEASE_LOOP backing file is DELETED - the guest would read a stale disc"; exit 1;; esac
  say "  /dev/$RELEASE_LOOP backed by $backing"
  # GATE-0 ON THE DISC ITSELF, not only on the setup tree: mount locally, run assert-payload
  # (sums + provenance commit + installer bytes), unmount. A truncated or stale ISO is caught
  # here, where the message is readable, instead of surfacing as an in-guest mystery.
  local mnt
  mnt=$(udisksctl mount --block-device "/dev/$RELEASE_LOOP" 2>/dev/null | sed -n 's/^Mounted .* at //p' | sed 's/\.$//')
  [ -n "$mnt" ] || mnt=$(findmnt -no TARGET "/dev/$RELEASE_LOOP" 2>/dev/null | head -1)
  [ -n "$mnt" ] || { say "[ERROR] FATAL: could not mount /dev/$RELEASE_LOOP to verify the ISO content"; exit 1; }
  # $RELEASE_SHA, not $RELEASE_REF: the ref is "HEAD" by default and resolving it HERE would
  # re-read the worktree, so a commit made while the campaign runs (which happens - a session
  # keeps working during the ~75 min) would turn this gate into a false FATAL. The SHA was
  # pinned once at campaign start and is what the whole run is graded against.
  if ./tools/assert-payload.sh "$mnt" "$RELEASE_SHA" >"$M/iso-gate0.out" 2>&1; then
    say "  Gate-0 (ISO): $(tail -1 "$M/iso-gate0.out")"
  else
    say "[ERROR] FATAL: Gate-0 FAILED on the ISO at /dev/$RELEASE_LOOP:"
    tail -3 "$M/iso-gate0.out" | sed 's/^/    /' | tee -a "$R"
    udisksctl unmount --block-device "/dev/$RELEASE_LOOP" >/dev/null 2>&1
    exit 1
  fi
  udisksctl unmount --block-device "/dev/$RELEASE_LOOP" >/dev/null 2>&1
  findmnt -no TARGET "/dev/$RELEASE_LOOP" >/dev/null 2>&1 \
    && say "  [WARN] /dev/$RELEASE_LOOP is still mounted locally after unmount - attach proceeds read-only, but investigate"
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
  # BEFORE the start: a --required assignment is satisfied at domain creation, so a volume attached
  # after the boot is invisible to it.
  # GATED WITH THE BIND. With LOGVOL_BIND unset nothing redirects the guest's logs, so an attached
  # volume would carry nothing - and it would still be an extra REMOVABLE device competing for the
  # drive letter the private volume normally takes, which decided a cell's verdict on 2026-09-08
  # (user_data_on_private and agent_log_healthy both failed on a guest whose install was perfect).
  # "Instrument off" has to mean nothing extra is attached.
  # ALWAYS: one evidence stick per subject, carrying the install markers and the logs. It is the
  # DIAG stick, which has been attached unconditionally since 2026-09-08.
  LOGVOL_VM="$vm"; LOGVOL_IMG=$(logvol_image "$vm")
  if true; then
    if logvol_create "$LOGVOL_IMG" "$vm" >>"$M/$lbl-logvol-setup.out" 2>&1 \
       && logvol_attach "$vm" "$LOGVOL_IMG" "$M/logvol-manifest.json" >>"$M/$lbl-logvol-setup.out" 2>&1; then
      say "  $lbl: log volume attached ($LOGVOL_IMG)"
    else
      # HARD, and LOGVOL_IMG is NOT cleared: blanking it is how "no volume attached" came to be
      # reported for cells whose volume was attached, and it turns a device failure into silence.
      say "[ERROR] FATAL: $lbl: log volume NOT ATTACHED - $(tail -1 "$M/$lbl-logvol-setup.out" 2>/dev/null | cut -c1-140)"
      say "[ERROR] FATAL: a wedge from here on is unreadable; the campaign STOPS rather than grade blind."
      say "=== MATRIX: ${PASS:-0} passed, $(( ${FAIL:-0} + 1 )) failed - ABORTED on a log-device failure ==="
      exit 2
    fi
  fi
  # A claim left by an EARLIER run on a loop that is now gone would make this start fail with
  # nothing but "libxenlight failed to create new domain" - swept here, where it is cheap.
  claim_sweep_stale "$vm" say || say "  $lbl: [WARN] a stale block claim survived - the start below may fail"
  say "  $lbl: booting $vm with the release ISO as CD (qvm-start --cdrom=win-idd-mgmt:$RELEASE_LOOP)"
  MATRIX_CDROM_CLAIMED="$MATRIX_CDROM_CLAIMED $vm"   # dropped before the loop is released
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
  # AN UNREADABLE MANIFEST IS NOT A WRONG DISC, AND ONE SILENT ANSWER IS NOT A READ.
  # This read once, then reported "built from 'unreadable'" - conflating an instrument failure with
  # a provenance failure, in a message that said so in plain sight. On 2026-10-14 it hard-FAILED
  # WIN10-reinstall on a medium Gate-0 had already verified from this side, 8 s after the log-volume
  # bind and ~48 s into a boot whose clock sync had died; the drive-letter probe just before it had
  # answered. A silent guest is not a dead one, so the read retries while cpu_time moves, and an
  # empty read is graded INVALID-INSTRUMENT: nothing is established about the medium either way.
  # No `| head -1` either: grep -q/-o into head closes the pipe and pipefail returns 141.
  local got _dtry
  for _dtry in 1 2 3 4; do
    got=$(QTEST_VM=$vm timeout -k 5 60 ./tools/qtest run "cmd /c type $RELDISC\\MANIFEST.json" 2>/dev/null \
          | tr -d '\r' | grep -a 'driver_repo_commit' | grep -aoEm1 '[0-9a-f]{40}')
    [ -n "$got" ] && break
    if w_cpu_moving "$vm" 10; then
      say "  $lbl: MANIFEST read came back empty while the guest IS EXECUTING - retry $_dtry/4"
    else
      say "  $lbl: MANIFEST read came back empty and cpu_time is FLAT - the guest is not executing"
      break
    fi
  done
  if [ -z "$got" ]; then
    no "$lbl: INVALID-INSTRUMENT - could not read $RELDISC\\MANIFEST.json ($_dtry attempt(s)); nothing is established about the medium"
    return 1
  fi
  if [ "${got:0:12}" != "${RELEASE_SHA:0:12}" ]; then
    no "$lbl: disc at $RELDISC was built from ${got:0:12}, expected ${RELEASE_SHA:0:12} - refusing to install from it"
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

# THE QUBE'S timezone FEATURE COMES BACK AT EVERY INSTALL, AND THAT IS THE USER'S CONFIGURATION.
# The feature decides what the qube's RTC holds: unset (the Qubes default, and what every Linux
# qube here has) means true UTC; `localtime` means DOM0 LOCAL. dom0 sets it to `localtime` for every
# os=Windows qube when it receives qubes.NotifyTools, so a user's Windows qube HAS it. Our images no
# longer declare a convention at all: Windows' default is to read the RTC as LOCAL time, which is
# the half that PAIRS with `localtime`, and the product derives the value per guest. This harness
# records which convention a cell ran under and changes nothing.
# MEASURED 2026-10-15 on the acceptance run: the harness unset it BEFORE the install, the install
# reported os=Windows to dom0 (core-agent/src/advertise-tools writes /qubes-tools/{version,os,qrexec,
# gui} and calls qubes.NotifyTools), and the feature came back as `localtime` on every QWT-carrying
# guest - win10-acc, win10-iqi, win11r-qwt, win11de-qwt - while the pristine bases and a fresh
# qvm-create qube have it unset. The guest then read a dom0-local RTC as UTC and sat 3 hours out on
# every boot after the first, our puller correcting it each time: clock_boot_correction_s = 10800
# against a max of 60, a P1 that failed the cell.
# Nothing in dom0 is touched by this - a qube's own feature is ours to set.
clock_feature_report(){ # <vm> <label> - REPORT the qube's clock convention; never change it.
  # THIS USED TO UNSET THE FEATURE, AND THAT HID A P1 FROM THE GATE. dom0 sets `timezone=localtime`
  # for every os=Windows qube when it receives qubes.NotifyTools, which makes the RTC hold DOM0 LOCAL
  # time; the product ships RealTimeIsUniversal=1, which declares the RTC holds UTC. The two
  # contradict, and the guest reads its dom0's offset ahead until the clock puller corrects it
  # mid-boot (measured 10800 s on every cell). Unsetting the feature here put the rig into the ONE
  # configuration where the shipped default is true, so the gate stopped measuring what a user gets.
  # Jev: harness_clear_hides_it 0.84, harness_feature_clear_is_substitution 0.74 (separate calls,
  # different sources). I added the unset to clear that P1, and clearing the P1 was the whole of what
  # it did - the same mistake as the log-volume redirect, in a different place.
  # So this now only RECORDS the convention, which is what the sweep's clock_boot_correction_s needs
  # to be read against. The defect belongs in the product: see RTIUWRONGDEFAULT.
  local tz; tz=$(qvm-features "$1" timezone 2>/dev/null)
  if [ -n "$tz" ]; then
    say "  $2: qube timezone feature is '$tz' - the RTC holds dom0 LOCAL time, as a user's qube does"
  else
    say "  $2: qube timezone feature is unset - the RTC holds true UTC"
  fi
}

clear_prime_leftovers(){ # $1=vm - prime-run's own exit text: "The stick is still assigned
  # --required and qemu-extra-args is still set - clear both before using this guest as a cell
  # subject." Without this, every later boot of the subject depends on this qube's loop layout.
  # BOTH STICKS. prime-run assigns TWO removable volumes - the answer stick on xvdi and, since
  # 2026-09-08, a writable DIAG stick on xvdj - and this only ever cleared the first.
  # MEASURED COST, acceptance 2026-09-08 cell 4: the DIAG volume was still attached when the guest
  # was graded, Windows gave it the drive letter the PRIVATE volume normally takes, and
  # user_data_on_private + agent_log_healthy both failed on a guest whose install was perfect -
  # pv_disk_bound was True the whole time. It passed on the next run, because which volume wins
  # the letter is a race. A leftover from priming must never be able to decide a cell's verdict.
  # THE LOG VOLUME IS NOT A LEFTOVER, and sweeping it here BROKE A CELL. I added it to this loop on
  # 2026-10-14 reasoning that prime-run leaves a third `--required` claim; it does, but that volume
  # is the cell's INSTRUMENT - attached before the guest starts, BOUND so QWT's modules write to it,
  # and pulled at cell end. Detaching it mid-cell leaves LogDir pointing at a drive letter that no
  # longer exists, so the agent writes nowhere. Measured minutes later on WIN10-clean:
  # `agent_log_healthy` false with "no agent log is held open by any process: the agent is not
  # logging" and `idd_agent_identified` false for want of the line it reads out of that log - a
  # product FAIL caused entirely by the harness. The stale-claim risk that prompted it is covered
  # where it belongs: claim_sweep_stale runs before every start, so a claim on a released loop
  # cannot make a subject uncreatable.
  local vm=$1 stickloop img
  # `[.]` not `\.`: awk warns "escape sequence \. treated as plain ." on every call, two lines of
  # noise per cell in a log that is read for findings.
  for img in 'answer-usb[.]img$' 'answer-usb-413[.]img$'; do
    stickloop=$(losetup -l 2>/dev/null | awk -v pat="$img" '$6 ~ pat {sub("/dev/","",$1); print $1; exit}')
    if [ -n "$stickloop" ]; then
      local uerr
      if uerr=$(qvm-device block unassign "$vm" "win-idd-mgmt:$stickloop" 2>&1); then
        say "  $vm: prime stick unassigned (win-idd-mgmt:$stickloop)"
      elif printf '%s' "$uerr" | grep -qi 'not assigned'; then
        # ALREADY CLEAR IS NOT A FAILURE. This ran twice on 2026-10-14 and the second pass reported
        # "could not unassign" three times about claims that were gone - a warning that reads as the
        # leftover still being there.
        say "  $vm: no claim on win-idd-mgmt:$stickloop (already clear)"
      else
        say "  [WARN] could not unassign win-idd-mgmt:$stickloop from $vm - its boots depend on this qube's loop layout until cleared: $(printf '%s' "$uerr" | tr -d '\r\n' | tail -c 120)"
      fi
    else
      say "  note: no loop backing ${img%%\\*} for $vm (not assigned this run)"
    fi
  done
  # NOT A BLANKET UNSET. This used to be `qvm-features --unset <vm> qemu-extra-args`, which also
  # deleted the LOG VOLUME's -drive and usb-storage lines and the nec-usb-xhci controller they share
  # with the answer stick. qemu-extra-args applies at DOMAIN CREATION, so the running guest kept its
  # volume and the loss surfaced one boot later - at this cell's park/restore - with LogDir still
  # naming a drive letter that no longer existed. Measured twice (2026-10-14 and the relaunch):
  # `agent_log_healthy` false, "no agent log is held open by any process: the agent is not logging",
  # and the IDD check that reads a line out of that log failing with it. A product FAIL made by the
  # harness. So: keep ours, drop the priming sticks', and unset only when nothing of ours remains.
  local qcur qnew
  qcur=$(qvm-features "$vm" qemu-extra-args 2>/dev/null || true)
  qnew=$(logvol_qemu_args_keep_only_ours "$qcur")
  if [ -n "$qnew" ]; then
    qvm-features "$vm" qemu-extra-args -- "$qnew" >/dev/null 2>&1 \
      && say "  $vm: priming sticks dropped from qemu-extra-args; the log volume's device KEPT" \
      || say "  [WARN] could not rewrite qemu-extra-args on $vm - the priming sticks stay until next prime"
  else
    qvm-features --unset "$vm" qemu-extra-args 2>/dev/null
  fi
  # And the clock convention the install just set, RECORDED not changed (see clock_feature_report).
  clock_feature_report "$vm" "$vm"
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

ensure_churn_target(){ # $1=vm [$2=source golden] - create the disposable churn StandaloneVM if it does not exist.
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
  # timezone: without it the RTC holds TRUE UTC while Windows reads it as LOCAL, so a
  # non-UTC guest computes a UTC behind real UTC by its own offset and CI-minted driver
  # catalogs come out not-yet-valid (0x800B0101, a 25-minute silent drvinst hang,
  # measured 2026-09-25). A create path that copies only the volumes loses the feature, so the
  # subject differed from its golden in exactly that.
  #
  # SET `timezone=localtime` AT CREATE TIME, BEFORE THE GUEST EVER BOOTS. Xen reads this at DOMAIN
  # CREATION and puts dom0's LOCAL time on the emulated clock; absent, it defaults to true UTC. dom0
  # sets it by itself for any Windows qube - but only once the GUEST has reported os+qrexec, which
  # cannot happen before the first install, so a qube created without it spends its whole install on a
  # true-UTC clock and then has the clock change under it one boot later. That transition is the
  # ENTIRE source of clock_boot_correction_s = 10800: one boot reading a UTC clock through dom0's
  # zone (3 h behind), the next reading a dom0-local clock through a convention latched from the
  # first (3 h ahead). Setting it here removes the window instead of converging out of it - the clock
  # holds dom0 local on every boot, Windows reads it as local on every boot (its default; we declare
  # nothing), and the guest's zone is dom0's on every boot. Nothing to settle.
  # This is also what a user's qube ends up with, so it is the configuration to test, not a shortcut.
  qvm-features "$vm" timezone localtime >/dev/null 2>&1 || true
  for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$vm" "${p%%:*}" "${p##*:}"; done
  qvm-prefs "$vm" netvm '' 2>/dev/null
  return 0
}

park_installed(){ # $1=vm $2=label - halt and park the just-installed subject as the campaign's
  # 'installed' snapshot (owner 2026-09-01: "we do snapshots for optimizations"). The release is
  # installed ONCE per OS per campaign; later cells that merely need "a guest carrying the
  # release" unpark this in ~2 s instead of reinstalling.
  # SEPARATE STATEMENTS, not one `local vm=$1 ... ck="ckpt-$vm-installed"`. Bash expands every word
  # of a `local` command BEFORE assigning any of them, so `$vm` there is the CALLER's vm under
  # dynamic scoping - and an unbound-variable abort under `set -u` if the caller has none. It
  # happened to be correct because every caller names its subject `vm`; it was never guaranteed.
  local vm=$1 lbl=$2
  local ck="ckpt-$vm-installed"
  if [ "$(w_state "$vm")" != Halted ]; then
    # DRAIN FIRST, and give the halt a budget that OUTLASTS the restarter. The old form issued a
    # bare qvm-shutdown and waited 420 s while qrexec_timeout sat at 600 - so one queued call could
    # hold or restart the guest for longer than the wait, and the harness then reported the PRODUCT
    # as unable to halt. That is what failed two cells on 2026-09-12, and nothing in the park path
    # drained anything. A restart is now named as an instrument condition, never a product failure.
    w_drain_and_shutdown "$vm" say
    [ "${W_DRAIN_QREXEC_DEAD:-0}" = 1 ] && { no "$lbl: FAIL - qrexec was DEAD on a running guest at park time (QREXECDEAD); the park that followed proves nothing about guest health"; return 1; }
    w_halt_stable "$vm" 660 "$lbl-park-halt" say
    case $? in
      0) ;;
      3) no "$lbl: INVALID-INSTRUMENT - subject halted then was RESTARTED during parking by an OBSERVED queued qrexec call, not a product failure"; return 1 ;;
      4) no "$lbl: subject halted then RESTARTED ITSELF during parking with NO queued call pending - unexplained, graded as PRODUCT until shown otherwise"; return 1 ;;
      *) no "$lbl: subject would not halt for parking"; return 1 ;;
    esac
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
  local ck="ckpt-$vm-installed"   # separate statement - see park_installed for why
  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$vm" \
    || { no "$lbl: subject $vm does not exist - run the clean cell first (it creates, installs and parks)"; return 1; }
  # CHECK THE PARK EXISTS BEFORE TOUCHING THE SUBJECT. Measured 2026-09-17 (release 4.3.29.538,
  # run 35171496552): WIN11-clean hit prime-run's DEADLINE, so cell_clean returned WITHOUT calling
  # park_installed and ckpt-win11-acc-installed was never created - while prime-run's H3.5 policy
  # deliberately left the stalled guest RUNNING, "its state is the evidence". One second later
  # WIN11-reinstall called this function, which in its old form halted the subject FIRST and only
  # asked about the park afterwards. So it spent 660 s waiting for ACPI on a guest whose qrexec had
  # been dead for eighteen minutes, then qvm-killed it - to run an unpark that could not have
  # succeeded, because the snapshot it wanted did not exist. Cost: the preserved specimen of this
  # project's open P1 stall, and a second product-FAIL that carried no information the first did
  # not already carry.
  #
  # The ordering is the whole fix. A cell that cannot possibly pass must not be the thing that
  # destroys another cell's evidence, and the check is free. The subject is LEFT AS IT STANDS -
  # not halted, not killed, not drained - so whatever the clean cell preserved survives this cell.
  if ! qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$ck"; then
    no "$lbl: no 'installed' park $ck exists - the clean cell that creates it did not complete, so this cell cannot run. Subject LEFT AS IT STANDS (state=$(w_state "$vm")): it is not touched, because a failed clean cell may be preserving it as evidence (H3.5)."
    return 1
  fi
  _halt_other_windows "$vm"
  if [ "$(w_state "$vm")" != Halted ]; then
    # Same drain as the park path: a queued call restarts the guest after it halts.
    w_drain_and_shutdown "$vm" say
    [ "${W_DRAIN_QREXEC_DEAD:-0}" = 1 ] && { no "$lbl: FAIL - qrexec was DEAD on a running guest at unpark time (QREXECDEAD); the park that followed proves nothing about guest health"; return 1; }
    w_halt_stable "$vm" 660 "$lbl-unpark-halt" say
    case $? in
      0) ;;
      3) no "$lbl: INVALID-INSTRUMENT - subject halted then was RESTARTED during unpark by an OBSERVED queued qrexec call, not a product failure"; return 1 ;;
      4) no "$lbl: subject halted then RESTARTED ITSELF during unpark with NO queued call pending - unexplained, graded as PRODUCT until shown otherwise"; return 1 ;;
      *)
        # KILL AS THE LAST RESORT, exactly like the park/reclone path above (which says "ignored
        # ACPI shutdown for 420 s - killing as the last resort"). This arm used to give up, and on
        # 2026-09-13 one stuck domain therefore cost WIN10-reinstall its whole cell - while
        # WIN10-upgrade, hitting the IDENTICAL guest minutes later, killed it and then ran clean
        # 10/10. One frozen guest must cost ONE cell, not every cell that touches it afterwards.
        # The failure is still reported: the kill is how the cell proceeds, not how it passes.
        # MEASURE BEFORE DESTROYING. The kill is irreversible and it is the last moment the guest's
        # live state can be read at all, yet this line used to record only the screen verdict. On
        # 2026-09-17 that left the WIN11-reinstall non-halt undecidable from the logs: "NOWINDOW"
        # is equally consistent with the open P1 stall (Running, qrexec dead, empty tar, a vCPU
        # pegged) and with a merely session-less guest, and the one cheap number that separates
        # them - a cpu_time delta taken DURING the refusal - was never taken. w_cpu_state costs 20 s
        # against a 660 s wait that has already elapsed, needs no guest cooperation, and fails open
        # ("UNREADABLE") rather than manufacturing a verdict.
        local _cs; _cs=$(w_cpu_state "$vm")
        say "  $lbl: subject ignored ACPI shutdown for 660 s (screen=$(w_screen "$vm" "stuck-$vm" "$M") cpu=$_cs) - killing as the last resort"
        qvm-kill "$vm" >/dev/null 2>&1
        if w_halt "$vm" 120 "$lbl-unpark-kill" say; then
          say "  NOTE: a killed guest leaves a dirty volume; the unpark below may need the start/stop cycle"
          no "$lbl: subject would not halt for unpark - KILLED so the run can continue (this cell is still a FAIL)"
        else
          no "$lbl: subject would not halt for unpark, and did not halt after qvm-kill either"
        fi
        return 1 ;;
    esac
  fi
  if ./mgmt/harness/checkpoint.sh unpark "$vm" installed >>"$R" 2>&1; then
    say "  $lbl: unparked $vm from ckpt-$vm-installed (snapshot entry - the release is NOT reinstalled per cell)"
  else
    no "$lbl: no restorable 'installed' park for $vm - run the clean cell first (it installs ONCE and parks)"
    return 1
  fi
}

grade_dom0_callers(){ # $1=vm $2=label - the goal's SECOND clause, measured where the guest is up.
  # "qrexec behavior is aligned with dom0 callers: updaters and start menu, from cold qube as well".
  # BOTH checks used to live in the end-of-campaign collection loop, guarded on the cell's guest
  # still answering - and every cell halts, parks or removes its subject as its last act, so only
  # the final cell could ever have a live guest there. MEASURED: run 8's matrix log contains ZERO
  # lines matching VMEXEC, i.e. the check written for this clause had not executed once in eight
  # campaign runs; run 9 reached the loop and measured THREE win11 cells, with every win10 cell
  # reporting "guest not answering" (CALLERCHECKATENDONLY). A gate that measures the channel the
  # goal names for three cells out of eight cannot settle it.
  # So it runs HERE, per cell, next to every other per-cell assertion, while the guest is up.
  local vm=$1 lbl=$2
  if [ "$(w_state "$vm")" != Running ] || ! w_alive "$vm"; then
    no "$lbl: guest not answering - the dom0 caller channel could not be measured for this cell"
    return
  fi
  # THE UPDATER CALLER: dom0 takes stdout as the update agent's log and parses bare floats on
  # stderr for the Update GUI's progress bar. Gating since run 9 showed all four channels arriving.
  if ./mgmt/harness/vmexec-channel-check.sh "$vm" say >>"$M/$lbl-vmexec.out" 2>&1; then
    ok "$lbl: dom0 caller channel aligned (stdout, stderr, exit code, grandchild)"
  else
    no "$lbl: the dom0 caller channel is NOT aligned - see $M/$lbl-vmexec.out"
  fi
  # THE START-MENU CALLER: receive.py ignores what it cannot parse IN SILENCE, so the stream is
  # asserted line by line rather than sampled.
  if ./mgmt/harness/dom0-callers-check.sh "$vm" say >>"$M/$lbl-callers.out" 2>&1; then
    ok "$lbl: start-menu caller aligned (dom0 can parse every line it is sent)"
  else
    no "$lbl: the start-menu caller is NOT aligned - see $M/$lbl-callers.out"
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
  # THE INSTRUMENT COMES FROM THE REPO, NOT THE PACKAGE. This file's own rule, above: "Instruments
  # (reboot-dialog-watch.ps1, health-check.ps1, uninstall/count scripts) may still be pushed: they
  # are the harness, not the product." Taking it from $RELEASE_SETUP version-locked a test
  # instrument to the product, so fixing a CHECK meant rebuilding the release - 45 minutes of CI to
  # change a predicate that never ships to a user. Measured consequence, 20261018-172640: the PnP
  # check failed the battery on a single WMI snapshot and the fix could not be exercised without a
  # new build. The PRODUCT still only ever arrives via the primer stick or the release ISO, and
  # Gate-0 still verifies that payload against the commit it was built from.
  SKIP_PROVISION=1 ALLOW_NA=$allowna HEALTH_CHECK="$PWD/guest/health-check.ps1" ./tools/accept-clean.sh "$vm" no-loop-in-skip-mode "$M/$lbl-accept" \
      >"$M/$lbl-accept.out" 2>&1
  local rc=$?
  say "  $lbl: accept-clean says: $(tail -1 "$M/$lbl-accept.out" | cut -c1-200)"
  if [ $rc -eq 0 ] && grep -qa 'ACCEPT=PASS' "$M/$lbl-accept.out"; then
    ok "$lbl: accept-clean battery PASS (boot path, WU posture, health, pixels, chrome)"
  else
    no "$lbl: accept-clean battery FAILED (see $M/$lbl-accept.out)"
  fi
  # The goal's second clause, per cell, with the guest still up.
  grade_dom0_callers "$vm" "$lbl"
}

# Run the installer and judge the outcome. Sets CELL_RC.
# $3 is the INSTALL SOURCE the guest runs install.cmd from - under the release-only model that is
# the CD drive returned by locate_release_disc (e.g. "E:"), never a pushed directory.
# PRESERVE THE MSI VERBOSE LOG. The installer runs msiexec with /l*v! to C:\qwt-install.log
# precisely so a failing install can be read afterwards - and this harness DELETED it at the start
# of every cell (the CLEARED/MARKED lines in run_install) and never fetched it. Measured 2026-09-14
# while investigating the missing-Q: defect: across 48 campaign directories there is NO verbose log
# for ANY run, passing or failing - only the 40-line tails quick-upgrade happens to keep.
#
# That matters because the deferred custom action which creates Q: (PreparePrivateImg) reports what
# it did HERE AND NOWHERE ELSE. Two clean installs have now finished with no Q: (2026-09-13 20:16Z
# ok:true and silent, 2026-09-14 01:47Z FATAL), both cost a cell, and NEITHER could be diagnosed,
# because the one artifact that would say whether that action ran had been generated on the guest
# and thrown away. Fetching it costs a single qrexec call.
#
# UNCONDITIONAL, not only on failure: the defect is intermittent (2/31 WIN10-clean) and a PASSING
# run's log is the control the failing one must be read against. Base64 over qubes.VMShell because
# the log is not clean ASCII and binary-safe transport is the difference between evidence and
# mojibake. It records; it GRADES NOTHING - a failure here must never change a cell's verdict.
fetch_msi_verbose(){ # $1=vm $2=label
  local vm=$1 lbl=$2 b64
  # ENCODED, NOT QUOTED. This file's own measured rule (see the xenbus version probe below, and
  # tools/lint-harness.py L3): escaped quotes inside -Command fail SILENTLY, returning empty output
  # that reads exactly like "the file was not there". A fetch that cannot tell "no log" from "my
  # quoting broke" is not evidence. Forward slashes for the same reason the probe below uses them.
  # BOUNDARY MARKERS so a truncated transfer is detectable rather than decoded into a short file.
  b64=$(python3 -c "import base64;print(base64.b64encode('''\$ErrorActionPreference='Stop'
if (Test-Path 'C:/qwt-install.log') {
  Write-Host 'MSIB64BEGIN'
  Write-Host ([Convert]::ToBase64String([IO.File]::ReadAllBytes('C:/qwt-install.log')))
  Write-Host 'MSIB64END'
} else { Write-Host 'MSIB64ABSENT' }'''.encode('utf-16-le')).decode())")
  QTEST_VM=$vm timeout -k 5 300 ./tools/qtest run \
      "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" \
      2>/dev/null | tr -d '\r\0' > "$M/$lbl-msi-b64.tmp"
  if grep -qa MSIB64END "$M/$lbl-msi-b64.tmp" 2>/dev/null \
     && sed -n '/MSIB64BEGIN/,/MSIB64END/p' "$M/$lbl-msi-b64.tmp" | grep -av 'MSIB64' | tr -d '\n' \
        | base64 -d > "$M/$lbl-msi-verbose.log" 2>/dev/null \
     && [ -s "$M/$lbl-msi-verbose.log" ]; then
    rm -f "$M/$lbl-msi-b64.tmp"
    say "  $lbl: MSI verbose log preserved ($(wc -c <"$M/$lbl-msi-verbose.log") bytes, $M/$lbl-msi-verbose.log)"
    # Surface the private-image action's own verdict at once - it is the line the Q: hunt needs.
    grep -aiE 'PreparePrivateImg|prepare-private-img' "$M/$lbl-msi-verbose.log" 2>/dev/null \
      | tail -4 | sed "s/^/    $lbl msi: /" || true
  elif grep -qa MSIB64ABSENT "$M/$lbl-msi-b64.tmp" 2>/dev/null; then
    rm -f "$M/$lbl-msi-verbose.log" "$M/$lbl-msi-b64.tmp"
    say "  $lbl: no MSI verbose log on the guest (C:\\qwt-install.log absent) - the guest ANSWERED, this is not a transport failure"
  else
    # Distinguished on purpose: an empty or truncated transfer is MY failure, not the guest's, and
    # must not be recorded as "there was no log". The raw capture is kept so it can be told apart.
    rm -f "$M/$lbl-msi-verbose.log"
    say "  $lbl: [WARN] MSI verbose log NOT retrieved (transfer empty/truncated, raw kept at $M/$lbl-msi-b64.tmp) - a failure in this cell cannot be diagnosed from it"
  fi
  return 0
}

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
  seen=$(_mark_seen "$vm")
  # A SILENT GUEST IS NOT A DEAD ONE - RETRY WHILE IT IS EXECUTING.
  # quick-upgrade.sh carries this retry (2026-09-14: this very read got 'no answer' while the guest
  # measured cpu_time +66935 over 20 s, busy mid-install, and the run was killed as TERMINAL). It
  # was never ported to this file, and on 2026-10-14 the acceptance campaign's WIN10-reinstall cell
  # took 'no answer' three seconds after a SUCCESSFUL guest read ("release disc verified at E:"),
  # refused to run the install, and then graded itself INVALID-INSTRUMENT twice - over an install
  # that had never been attempted. A timeout is a failure only once cpu_time is FLAT.
  if [ "$seen" != PRESENT ]; then
    local _mtry
    for _mtry in 1 2 3 4 5 6; do
      if w_cpu_moving "$vm" 15; then
        say "  $lbl: run marker no answer yet, but the guest IS EXECUTING (cpu_time moving) - retry $_mtry/6"
      else
        say "  $lbl: run marker no answer and cpu_time FLAT - the guest is not executing"
        break
      fi
      QTEST_VM=$vm qrun "cmd /c echo $E2E_MARK >> $GLOG & echo MARKED" >/dev/null 2>&1
      seen=$(_mark_seen "$vm")
      [ "$seen" = PRESENT ] && { say "  $lbl: run marker written on retry $_mtry"; break; }
    done
  fi
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

  # ARM THE MODULE-BASE RECORDER HERE, BEFORE THE INSTALL - not only after it.
  #
  # There is a second arming call in the post-install path (search "module-base recorder armed"),
  # and it is TOO LATE for the cell that actually wedges. WIN11-reinstall has stalled twice
  # (2026-09-12, and 2026-09-14 08:44) INSIDE this function; cell_reinstall does not reach the
  # post-install arming until line ~1120 returns. So the cell most likely to wedge was the one
  # guaranteed to be unarmed when it did, and the 09-14 stall produced the ninth unresolvable RIP
  # despite the wiring being present.
  #
  # Here is the right place: every install-running cell (reinstall/upgrade/seeded/stock) funnels
  # through run_install, and the marker write immediately above has just PROVEN qrexec answers, so
  # arming cannot be defeated by an unreachable guest. The recorder installs an ONSTART task, so
  # arming once also covers every later boot - including the post-install reboot, which is where
  # the stall actually lands.
  #
  # Records evidence, grades nothing: a failure here must never change a cell's verdict.
  if VM="$vm" OUT="$M/modbases-$lbl" ./mgmt/harness/arm-module-bases.sh >>"$M/$lbl-armlog.txt" 2>&1; then
    say "  $lbl: module-base recorder armed BEFORE the install (a stall in here will resolve to driver+offset)"
  else
    say "  $lbl: module-base recorder NOT armed before the install - a stall in here leaves a raw, unresolvable RIP"
  fi

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
  # A DETACHED LAUNCH MUST NOT INHERIT THIS CALL'S HANDLES, AND `start` CANNOT AVOID IT.
  # `start` passes every inheritable handle whatever the redirection - MEASURED 2026-09-27, commit
  # d3fe180: `cmd /c start ... <nul >nul` did NOT prevent it and the call still died at the
  # installer's own service stop on win11de-v3/-v4 (rc=255 after 51-55 s). quick-upgrade.sh:703-710
  # carries that finding and the remedy: Start-Process goes through ShellExecute, which inherits no
  # handles, so the call returns as soon as the launch is done.
  # WHY IT MATTERS HERE: the inherited handles are the qrexec data vchan's pipes, so the launched
  # process holds them for its whole life - 2700 s for this watcher - and the wrapper's output pumps
  # never see EOF. MEASURED win11-reinstall, campaign run 38994277148: wrapper 9140 (this call) and
  # 7080 (the install below) each sat with a live pump until a console control event tore them down
  # 118 s and 63 s in, both reporting at ERROR that output "may not have reached the peer" - the only
  # two undeclared error lines that cell carried. The same shape produced the 120 s TRUNCATED
  # transfer and the lost exit code on the previous campaign.
  # Jev, asked whether to demote that ERROR instead: fix-the-callers 0.79, demotion borderline
  # hiding 0.52. So the caller stops creating the condition.
  QTEST_VM=$vm qrun "powershell -NoProfile -Command \"Start-Process -WindowStyle Minimized -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$INC\\reboot-dialog-watch.ps1','-DurationSeconds','2700'\"" >/dev/null 2>&1
  say "  $lbl: reboot-dialog watcher armed"
  # Same mechanism as the watcher above, and the same form quick-upgrade.sh has proven on this rig.
  # $extra is empty in every current caller (all four pass three arguments) but is threaded rather
  # than silently dropped.
  _extraArgs=""
  [ -n "$extra" ] && _extraArgs=$(printf ",'%s'" $extra)
  QTEST_VM=$vm qrun "powershell -NoProfile -Command \"Start-Process -WindowStyle Minimized -FilePath '$src\\install.cmd' -ArgumentList '/auto','/autologon:qubes'$_extraArgs\"" >/dev/null 2>&1
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
      echo "request written at install+${SEED_DELAY}s ($(date -u +%H:%M:%S))" >> "$M/$lbl-seed.log" ) &
  fi
  # Probe the MONITOR PROCESS directly. tasklist is far cheaper than reading a growing log, so it
  # keeps answering while the guest is busy - which is exactly where every file-read poll lost the
  # race and cost us the six lines that mattered.
  # IT DECLARES ITS OWN LEVEL, AND THE GUEST CANNOT SET IT. This line wears the bash logger's exact
  # shape ("[HH:MM:SS] ..."), so sweep-gate counted all 90 of its polls as undeclared lines of OURS
  # - 71 of the 141 that made the gate refuse to judge the campaign at all (run 38994277148). It is
  # the harness writing, so it declares [INFO]: the poll result is a witness, never a verdict.
  # `tr -d '[]'` is the same guard quick-upgrade.sh:824 already applies - every level alternative in
  # the gate's regex needs a literal ']', and the captured payload really does arrive with brackets
  # in it ("Microsoft Windows [Version 10.0.26300.9457]"), so without this the GUEST chooses the
  # severity of our line. Jev: declare-and-strip 0.69 over excluding the file as a capture 0.31,
  # payload-can-forge 0.65.
  ( for _p in $(seq 1 90); do
      echo "[$(date -u +%H:%M:%S)] [INFO] xenbus-probe: $(QTEST_VM=$vm timeout -k 3 25 ./tools/qtest run \
        'cmd /c tasklist | findstr /i xenbus & sc query xenbus_monitor | findstr /i STATE' \
        2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -d '[]' | cut -c1-150)" >> "$M/$lbl-monitor.log" 2>&1
      sleep 5
    done ) &
  PROBE_PID=$!
  w_install "$vm" 2400 "$lbl" "$M" say "$GLOG"; CELL_RC=$?
  kill ${PROBE_PID:-0} 2>/dev/null

  fetch_msi_verbose "$vm" "$lbl"

  case $CELL_RC in
    0) say "  $lbl: install reported a RESULT" ;;
    1) no "$lbl: guest went to the recovery screen DURING the install" ;;
    2) no "$lbl: install hit the 2400s deadline" ;;
    3) say "  $lbl: guest halted during/after the install (expected for a two-stage install)" ;;
    4) no "$lbl: install STALLED (no progress for ${STALL_SECS}s)" ;;
  esac
  # RE-ASSERT THE LOG BIND, BECAUSE STAGE 2 DELETES THE KEY IT LIVES IN.
  # On reinstall/upgrade/seeded/stock the bind runs right after w_session, BEFORE this install (the
  # comment on logvol_bind_now saying "every caller has just finished an install" is true only of
  # the clean cell). The installer no longer OVERWRITES a deliberate LogDir - it seeds only when the
  # value is absent or is the MSI-chooseable [INSTALL_DIR]log - but when a previous QWT is present
  # its uninstall takes the whole `Qubes Tools` key with it, so the staging value is DELETED and the
  # next seed finds nothing and writes Q:\Qubes Logs. Jev graded that the biggest remaining hole
  # (uninstall_wipes_staging_value 0.50).
  # THIS IS NOT AN ORDERING RACE: it is check-then-act on a KNOWN FINAL STATE - the install has
  # reported, nothing else writes LogDir afterwards, and logvol_bind_now is idempotent (a volume
  # already at its pinned letter with LogDir already correct re-binds with copied=0). It runs only
  # where a bind is actually in force, so a campaign with LOGVOL_BIND=0 is untouched.
  if [ "${LOGVOL_BIND:-1}" = 1 ] && [ -n "${LOGVOL_IMG:-}" ]; then
    say "  $lbl: re-asserting the log bind after the install (stage 2's uninstall deletes the key it lives in)"
    logvol_bind_now "$1" "$lbl-postinstall"
  fi
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
      # ONE PROBE per recovery turn, bounded to the turn: the old form abandoned a request on
      # every 15 s tick of a guest that was already deaf, which is the worst place to add queue.
      w_alive_wait "$vm" 15 5 && { say "  $lbl: qrexec came back on its own at t+$((q*15))s"; break; }
      sleep 15
    done
    # THE REBOOT IS UNCONDITIONAL, because the installer's contract is unconditional: a stage-2
    # install returns reboot_needed:true and its caller owns the reboot. This used to be guarded by
    # `if ! w_alive`, i.e. the contract was honoured only when qrexec had already died - so on the
    # normal path, where the guest is still answering, the harness skipped the reboot entirely and
    # then graded the PRE-REBOOT session.
    #
    # MEASURED 2026-09-09 (4.3.24 campaign, WIN10-upgrade). The install reported ok:true and
    # reboot_needed:true at 23:04:01, and one second later the harness logged
    # "WIN10-upgrade-back: session up at t+0s" and PASSed "guest came back with a session". No guest
    # reboots in one second: that was the old session, still up. The guest then rebooted on its own
    # underneath the harness, so the installer-log fetch returned nothing (scored INVALID-INSTRUMENT
    # at 23:06:03) and the accept battery went on to reboot a guest that was already mid-reboot,
    # ending in "guest did not answer qrexec after reboot" and a subject that answered neither
    # qrexec nor ACPI. Every later cell then failed on "refusing, these are not Halted: win10-acc".
    #
    # This is the same class as the async-shutdown defect fixed in the feature tests today: a reboot
    # must be DRIVEN or PROVEN, never inferred from "something answered".
  fi
  # OUTSIDE the `if ! w_alive` block, deliberately. Putting it inside was the first attempt at this
  # fix and it changed NOTHING: that whole block only runs when qrexec is ALREADY dead, so on the
  # normal path - guest still answering - the reboot was still skipped. The instrument said so at
  # once (back-gap stayed 2 s and "contract requires of its caller" appeared 0 times in the log),
  # which is exactly why the gap is measured rather than assumed.
  say "  $lbl: rebooting the guest, as the installer's contract requires of its caller"
  qvm-shutdown "$vm" >/dev/null 2>&1
  w_halt "$vm" 420 "$lbl-postinstall-halt" say || { qvm-kill "$vm" >/dev/null 2>&1; sleep 10; }
  start_vm "$vm"
  w_session "$vm" 900 "$lbl-back" "$M" say
  case $? in
    1) no "$lbl: BRICKED - $(grep -a "$lbl-back: TERMINAL" "$R" | tail -1 | sed 's/.*TERMINAL - //' | cut -c1-120)"; return 1 ;;
    2) no "$lbl: no session within 900s even after the post-install reboot (last screen: $(w_screen "$vm" "$lbl-final" "$M"))"; return 1 ;;
  esac
  ok "$lbl: guest came back with a session"

  # ARM THE MODULE-BASE RECORDER, the moment this guest can answer.
  #
  # WHY HERE. findings/issues.md P1's first next-action is "harvest a spinner's module bases":
  # every one of the stall specimens is a RAW GUEST RIP that nobody can resolve, because KASLR
  # re-randomises every boot and the bases were never recorded for THAT boot. Arming was wired
  # into every repro harness (clean-install-repeat, enum-storm-repro, flush-durability-ab,
  # ioreq-stall-repro, catch-specimen) and into NONE of the acceptance cells - so when the stall
  # finally happened inside a campaign (win11-acc, WIN11-reinstall, 2026-09-12), it produced the
  # ninth unresolvable address instead of the first resolved one. The guest went deaf about 60 s
  # after this very line, which is exactly the window this arming has to beat.
  #
  # It is cheap, idempotent, takes its own per-VM lock, and a failure here must never affect the
  # cell's verdict: this records evidence, it grades nothing.
  if VM="$vm" OUT="${R%/*}/modbases-$lbl" ./mgmt/harness/arm-module-bases.sh >>"$R" 2>&1; then
    say "  $lbl: module-base recorder armed (a stall's RIP will resolve to driver+offset)"
  else
    say "  $lbl: module-base recorder NOT armed - a stall in this cell will leave a raw, unresolvable RIP"
  fi
  _assert_not_primed "$vm" "$lbl"
  # RETRY, never fail a cell on ONE slow call. `type` on an ~18 KB log takes about two seconds, so
  # a call that burns its whole timeout means the guest was not answering qrexec at all - and
  # re-issuing gets a fresh connection, where simply waiting longer in one call sits on a dead one.
  # MEASURED 2026-09-09 (4.3.24 campaign): WIN10-upgrade's fetch returned 0 bytes after exactly its
  # 120 s timeout, on the guest that had just completed an MSI major upgrade - the busiest
  # post-reboot moment of any cell - and the cell was scored INVALID-INSTRUMENT even though the
  # install had already reported ok:true. The other two cells in the SAME run fetched fine, one of
  # them byte-identical to the previous release's, so the mechanism was never broken: this was a
  # transient, and a transient must be retried with backoff and its error KEPT, not turned into a
  # verdict.
  for _fa in 1 2 3; do
    QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run "cmd /c type \"$GLOG\"" 2>"$M/$lbl-final.err" \
      | tr -d '\r' | grep -av 'system32>' > "$M/$lbl-final.log"
    # EMPTY IS A FAILURE, not a short answer. A killed call can exit non-zero OR simply write
    # nothing, so the exit status alone would let a zero-byte log through as if it had been read -
    # which is exactly how this produced an INVALID cell instead of a retry.
    [ -s "$M/$lbl-final.log" ] && break
    say "  $lbl: installer-log fetch attempt $_fa/3 returned nothing: $(head -c 100 "$M/$lbl-final.err" 2>/dev/null | tr -d '\n') - retrying"
    sleep $((_fa * 15))
  done
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
  # ok AND THE ERROR-CLASS DETAIL FLAGS, through the one shared checker (mgmt/harness/result-flags.py).
  # This battery graded upgrade_mode, the agent hash and autologon and NEVER looked at `ok` - and
  # nothing anywhere read detail.*: the installer records a failed IDD activation, a failed xenvif
  # upgrade, a dead gui-agent or an un-primed PV NIC there (idd_failed, pv_xenvif='failed rc=N',
  # gui_restored='FAILED: ...', pvnic_prime_failed) under ok:true, and the cell graded GREEN (audit
  # 2026-09-16, the systemic finding). EVERY trailer in the slice is judged, not only the last: the
  # last one can be stage-1's (see the hash check below for the same trap), and a stage-1 flag would
  # otherwise be invisible. The flag list lives in result-flags.py only.
  local rf rrc
  rf=$(grep -a '^=== RESULT === {' "$M/$lbl-final.cur" | python3 "$HERE/mgmt/harness/result-flags.py" - 2>&1); rrc=$?
  case $rrc in
    0) ok "$lbl: installer RESULT ok:true and no error-class detail flags ($(echo "$rf" | grep -c '^\[') trailer(s) judged)" ;;
    1) no "$lbl: installer RESULT is NOT green - $(echo "$rf" | tail -1)" ;;
    2) # The trailer exists but its JSON does not parse. Mandated carve-out (2026-09-16): a
       # missing/unparseable RESULT keeps today's grading, which here never judged ok or flags at
       # all - so nothing is graded, and the line says so rather than passing quietly.
       say "  $lbl: result-flags.py could NOT judge the RESULT ($(echo "$rf" | tail -1)) - ok/flags NOT graded (unparseable trailer, today's behaviour)" ;;
    *) no "$lbl: result-flags.py failed (rc=$rrc: $(echo "$rf" | tail -1)) - INVALID-INSTRUMENT, the RESULT was not judged" ;;
  esac
  # JUDGE THE BINARY, NOT THE LAST LOG LINE. This used to demand installed_gui_agent_sha256 in
  # whatever trailer happened to be last. On the two-stage path the last trailer can be
  # stage1-prepare, which does not install the agent and therefore has no such field - so a cell
  # that graded between stage 1 and stage 2 reported "installed agent is NOT the release binary"
  # for a guest whose gui-agent.exe matched the release byte for byte. Measured 2026-09-08
  # (win11-clean, reproload-1015): FAIL at 10:26:03 on a stage1-prepare trailer, accept battery
  # PASS at 10:32:47, and the file on disk hashed 286601ba... == the release reference. It passes
  # or fails on timing, which is why it looked intermittent.
  # Order now: the trailer that actually CARRIES the field, else the file on the guest, and only
  # then a verdict. A guest that cannot be hashed is INVALID-INSTRUMENT, not a product failure.
  local jhash fhash
  jhash=$(grep -a '^=== RESULT === {' "$M/$lbl-final.cur" | grep -a 'installed_gui_agent_sha256' | tail -1)
  if [ -n "$jhash" ] && echo "$jhash" | grep -qa "\"installed_gui_agent_sha256\":\"$ASHA"; then
    ok "$lbl: installed agent == release binary (installer RESULT)"
  else
    fhash=$(QTEST_VM="$vm" timeout -k 8 90 "$HERE/tools/qtest" run \
              'certutil -hashfile "C:\Program Files\Qubes Tools\bin\gui-agent.exe" SHA256' 2>/dev/null \
              | tr -d '\r' | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    if [ -z "$fhash" ]; then
      no "$lbl: could not hash the installed agent on the guest - INVALID-INSTRUMENT, not a product result"
    elif [ "${fhash:0:${#ASHA}}" = "$(echo "$ASHA" | tr 'A-F' 'a-f')" ]; then
      ok "$lbl: installed agent == release binary (hashed on the guest; the RESULT trailer was stage-1)"
    else
      no "$lbl: installed agent is NOT the release binary (on-disk $fhash != $ASHA)"
    fi
  fi
  # NO WINDOW NOBODY ASKED FOR (2026-09-30): a console/Terminal window our agent mapped since this boot is
  # ours or the harness's - the toast bridge shipped one on every Win11 boot for four weeks unseen.
  local cw cwrc
  # THE CELL DECLARES ITS OWN INSTALLER CONSOLE, and only the cells that start one. The
  # over-existing cells install from the release ISO by running <CD>\install.cmd in the guest's
  # session; install.cmd is a batch file, so on Windows 11 25H2 cmd.exe is hosted by Windows
  # Terminal and that window is legitimately mapped. The clean cell enters via prime-run with no
  # session and declares nothing. Measured 2026-10-08: WIN11-upgrade failed here on exactly that
  # window (class=CASCADIA_HOSTING_WINDOW_CLASS) while every Windows 10 cell passed, because
  # conhost hosts it there. Jev: whose_defect = harness 0.94, product 0.00.
  local cwflag=""
  case "$lbl" in
    *-reinstall|*-upgrade|*-seeded|*-stock) cwflag="--allow-installer-console" ;;
  esac
  cw=$("$HERE/mgmt/harness/console-window-check.sh" "$vm" $cwflag 2>&1); cwrc=$?
  case $cwrc in
    0) ok "$lbl: $cw" ;;
    1) no "$lbl: a console/Terminal window was mapped on this boot - $cw" ;;
    *) no "$lbl: console-window check could not judge - INVALID-INSTRUMENT: $cw" ;;
  esac
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
  # THE FOUR XENBUS CONFIRMATIONS BELOW ARE DEMOTED TO say(), NOT DROPPED (owner 2026-10-16).
  # They assert that we keep our hands off xenbus: the monitor is disabled by the shipped INF, it is
  # not running, the package ships none of ours, and the bound version is the MSI's. All four have
  # stood since 2026-08-29 / 2026-09-14 and all four pass on every cell - the owner's words: an
  # obvious result, "like i did not forget to wipe my ass after i shit". A PASS line per cell for
  # something that cannot plausibly be otherwise is noise that crowds out the lines a reader needs.
  # WHAT DID NOT CHANGE: every FAILING branch is still no() and still fails the cell. Silent when
  # true, loud when false - the confirmations stop printing, the regression guard does not move.
  if echo "$start" | grep -qai 'DISABLED'; then
    say "  $lbl: xenbus_monitor is DISABLED by the shipped INF"
  else
    no "$lbl: xenbus_monitor start type is NOT disabled ($start) - the INF patch did not reach this guest"
  fi
  if echo "$state" | grep -qai 'STOPPED'; then
    say "  $lbl: xenbus_monitor is not running"
  else
    no "$lbl: xenbus_monitor is RUNNING ($state) - it can still restart the guest"
  fi

  # WE NO LONGER SHIP A XENBUS. Owner, 2026-09-14: "we do not touch xenbus anymore" / "no xenbus
  # upgrade == no upgrade issues". f68bd22's whole footprint was reverted in f7c16ce, so the guest
  # must be running the MSI's OWN xenbus and this check asserts exactly that - inverted from what
  # it used to assert, which was that OUR rebuilt driver had outranked the MSI's.
  #
  # The package must ALSO not carry one. A pv-drivers/xenbus that came back would be installed by
  # the installer's payload-gated block and nothing else here would notice, which is the silent
  # regression this check now exists to catch.
  if [ -e "$RELEASE_SETUP/pv-drivers/xenbus" ]; then
    no "$lbl: the package carries pv-drivers/xenbus again - we ship stock xenbus (f7c16ce); the build is regressed"
  else
    say "  $lbl: the package ships NO xenbus of ours - the guest keeps the MSI's own"
  fi
  # ENCODED, not quoted: escaped quotes inside -Command fail SILENTLY (tools/lint-harness.py L3).
  # And a MARKER, not a bare version: `qtest run` echoes cmd's banner - "Microsoft Windows
  # [Version 10.0.26100.1742]" - so a bare version regex returns the WINDOWS BUILD. Measured
  # 2026-09-12: the probe reported 10.0.26100.1742 as the bound xenbus version.
  # FORWARD SLASHES ON PURPOSE: with backslashes this literal reaches python as
  # C:\Windows...\xenbus.sys, and \xenbus is a truncated \xXX escape - python raised
  # SyntaxError, b64 came out EMPTY and the probe silently reported <unreadable>.
  # RETRIED, AND THE REASON IS KEPT. One read used to decide this, and its output was thrown away -
  # so a momentary unavailability became a cell failure with nothing to diagnose it from. MEASURED
  # 2026-10-10: WIN11-reinstall failed the whole campaign with "INVALID-INSTRUMENT - could not read
  # the guest's xenbus.sys version", and the identical probe against that same guest afterwards
  # returned XBVER=9.1.0.0 with the file present - so the read was TRANSIENT. The race is in the
  # installer's own words, "The PV drivers bind at the guest's NEXT start": this cell REINSTALLS,
  # so the probe can land across that reboot, when the guest is not answering or the driver file is
  # mid-replacement. A transient must not fail the run and must never be discarded silently
  # (.claude/skills/experimenter rule 11); three reads 10 s apart cost nothing when the first works.
  local b64 got raw i alive
  b64=$(python3 -c "import base64;print(base64.b64encode('Write-Host (\"XBVER=\" + (Get-Item C:/Windows/System32/drivers/xenbus.sys).VersionInfo.FileVersion)'.encode('utf-16-le')).decode())")
  got=""; raw=""
  for i in 1 2 3; do
    raw=$(QTEST_VM=$vm timeout -k 5 90 ./tools/qtest run \
          "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>&1 | tr -d '\r\0')
    got=$(printf '%s' "$raw" | grep -aoE 'XBVER=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d= -f2)
    [ -n "$got" ] && break
    [ "$i" -lt 3 ] && { say "  $lbl xenbus read $i/3 gave nothing - retrying in 10 s"; sleep 10; }
  done
  say "  $lbl xenbus bound version: ${got:-<unreadable>} (expected the MSI's own)"
  if [ -z "$got" ]; then
    # WHICH failure it is decides what a reader does next: a guest that is not answering is a rig
    # state, a guest that answers without the version is a driver state. Both are INVALID, and
    # saying which - with what the guest actually sent - is the difference between a diagnosis and
    # a dead end.
    alive=$(QTEST_VM=$vm timeout 40 ./tools/qtest run 'cmd /c echo ALIVE' 2>/dev/null | grep -ac ALIVE)
    no "$lbl: INVALID-INSTRUMENT - could not read the guest's xenbus.sys version after 3 reads (missing data never reads as a pass; qrexec answers=${alive:-0}; last output: $(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-180))"
  else
    say "  $lbl: xenbus bound is $got, from the MSI - nothing of ours layered on top"
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
  # prime-run REMOVES and recreates its target, so any specimen marker on it dies with the guest.
  specimen_clear "$vm" >/dev/null || true
  ./mgmt/harness/prime-run.sh "$base" "$vm" ours --payload "$RELEASE_SETUP" >"$M/$tag-clean-prime.log" 2>&1
  local prc=$?
  say "  prime-run tail: $(tail -1 "$M/$tag-clean-prime.log" | cut -c1-180)"
  # prime-run attached and bound the log volume for this subject, so the cell-end pull must read
  # THAT image. Without these two lines the clean cell's pull read whatever stale image happened to
  # be at the path, and reported "guest logs incomplete" about a volume from an earlier run
  # (measured 2026-10-14: the archived volume it read had been created five hours before the cell).
  LOGVOL_VM="$vm"; LOGVOL_IMG=$(logvol_image "$vm")
  # A CELL THE RIG PREVENTED FROM RUNNING IS NOT A PRODUCT FAILURE. prime-run refuses outright when
  # another Windows guest is still up ("TERMINAL: refusing, these are not Halted: ..."), which is a
  # rig-state condition - the release was never given a chance to fail. It was nevertheless scored
  # product-FAIL=1 against the release (measured 2026-09-10: WIN11-clean, after the one-guest guard
  # gave up early), and a green release can be marked red by a busy rig.
  #
  # DELIBERATELY NARROW. Only the precondition refusal is reclassified. rc=2 (the guest never came
  # back from its post-install reboot) STAYS a product failure - that is the real stall this project
  # is hunting, and burying it as "ungraded" would be the worse error by far.
  local _ptail; _ptail=$(tail -3 "$M/$tag-clean-prime.log" 2>/dev/null | tr '\n' ' ')
  case $prc in
    0) ok "$tag-clean: prime-run delivered a qrexec-answering installed guest"
       # THE CLEAN CELL IS WHERE THE MISSING-Q: DEFECT ACTUALLY HAPPENS - both events (2026-09-13
       # 20:16Z, 2026-09-14 01:47Z) were WIN10-clean, and upgrade/reinstall cells cannot exercise
       # it at all (Q: already exists there, so the stock action's RAW test is false and it
       # correctly no-ops). The clean path does NOT go through run_install, so the fetch there
       # would have missed this cell entirely - which is the whole point of putting it here too.
       fetch_msi_verbose "$vm" "$tag-clean" ;;
    1) case "$_ptail" in
         *"refusing, these are not Halted"*|*"could not create"*)
           no "$tag-clean: INVALID-RIG - prime-run refused before starting (not a product result): $(printf '%s' "$_ptail" | cut -c1-120)" ;;
         *) no "$tag-clean: prime-run TERMINAL (see $M/$tag-clean-prime.log)" ;;
       esac; return ;;
    2) no "$tag-clean: prime-run hit its deadline (see $M/$tag-clean-prime.log)"; return ;;
    *) no "$tag-clean: prime-run rc=$prc (see $M/$tag-clean-prime.log)"; return ;;
  esac
  clear_prime_leftovers "$vm"
  # BIND NOW, NOT IN prime-run. The volume's drive letter depends on which other removable
  # volumes are attached, and LogDir is written with the letter at bind time. prime-run binds
  # while both priming sticks are present; the sweep above then removes them and the volume
  # shifts letter on the next boot, leaving LogDir pointing at nothing - three campaign runs
  # died that way. logvol-chain-check.sh measured the chain holding across a reboot (15/15)
  # once the device set is stable, which is exactly here.
  logvol_bind_now "$vm" "$tag-clean"
  # Park FIRST, grade the parked state AFTER: the snapshot must be the clean installed state,
  # not one carrying grading residue (notepad, typed markers, an extra boot's mutations).
  park_installed "$vm" "$tag-clean" || say "  $tag-clean: continuing without a park - snapshot cells will refuse loudly"
  start_vm "$vm"
  w_session "$vm" 900 "$tag-clean-boot" "$M" say || { no "$tag-clean: installed guest did not come back for grading"; return; }
  # RE-ASSERT AFTER THE BOOT, BECAUSE THE PINNED LETTER IS NOT EXCLUSIVE. The bind above ran while
  # prime-run's answer stick was still attached beside the DIAG volume; the pin decides where OUR
  # volume goes, it does not reserve the letter, and another removable volume present at boot can
  # own it first. Reproduced on win10-acc by A/B/A 2026-10-20 with no clean install: add one 64 MB
  # stick to qemu-extra-args and `Z:` becomes DUMMYSTK while the DIAG volume moves to D: - LogDir
  # still reads Z:\qwt-logs\<vm>, that directory DOES NOT EXIST, and every module falls back to
  # Q:\Qubes Logs. That is exactly how four cells of run 39225775322 swept 0 QWT lines while their
  # logs sat on the image. The bind resolves the volume by LABEL and is idempotent (copied=0 when
  # nothing is new), so re-asserting it on the boot that grading reads costs nothing and repoints
  # LogDir at the letter the volume actually has.
  if [ "${LOGVOL_BIND:-1}" = 1 ] && [ -n "${LOGVOL_IMG:-}" ]; then
    say "  $tag-clean: re-asserting the log bind after the boot (the pinned letter is not exclusive)"
    logvol_bind_now "$vm" "$tag-clean-postboot"
  fi
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
  logvol_bind_now "$vm" "$tag-reinstall"
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
  ensure_churn_target "$vm" "$prev" || return
  reclone "$prev" "$vm" || { no "$tag-upgrade: could not reclone"; return; }
  boot_with_release_iso "$vm" "$tag-upgrade" || return
  w_session "$vm" 900 "$tag-upgrade-boot" "$M" say || { no "$tag-upgrade: clone did not boot"; return; }
  logvol_bind_now "$vm" "$tag-upgrade"
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
  ensure_churn_target "$2" "$1" || return
  reclone "$1" "$2" || { no "$3-seeded: could not reclone"; return; }
  boot_with_release_iso "$2" "$3-seeded" || return
  w_session "$2" 600 "$3-seeded-boot" "$M" say || { no "$3-seeded: clone did not boot"; return; }
  logvol_bind_now "$2" "$3-seeded"
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
  grep -qa ARMED <<< "$(QTEST_VM=$2 qrun "cmd /c sc config xenbus_monitor start= auto >nul & sc start xenbus_monitor >nul 2>&1 & echo ARMED" 2>/dev/null)" || { no "$3-seeded: could not arm - cell inconclusive"; return; }
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
  ensure_churn_target "$vm" "$entry" || return
  reclone "$entry" "$vm" || { no "$tag-stock: could not reclone"; return; }
  boot_with_release_iso "$vm" "$tag-stock" || return
  w_session "$vm" 900 "$tag-stock-boot" "$M" say || { no "$tag-stock: clone did not boot"; return; }
  logvol_bind_now "$vm" "$tag-stock"
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

# grade_appvm_window - ONE BOOT'S WINDOW VERDICT, as a function so it can be exercised.
#
# WHY IT IS A FUNCTION. This was the tail of cell_appvm's boot loop, and it is what made that
# cell impossible to drive offline: an extracted cell_appvm ran on into these dom0 captures and
# lifecycle-lib helpers, so a suite that stubbed them shifted the cell's own verdicts and a suite
# that did not left unbound state. Three runs of such a suite gave 14/1, 15/0 and 10/5 - a flaky
# check, which is worse than none. The same split was made for grade_cell_logsweep and
# grade_dom0_callers for exactly this reason, and both have suites.
#
# IT GRADES, AND RETURNS WHAT THE CALLER MUST COUNT:
#   0  window(s) mapped, none fullscreen-sized   (caller: mapped_any=1)
#   1  a FULLSCREEN-SIZED window was mapped      (graded here)
#   2  guest has a window, dom0 capture empty    (caller: ii_boots+1; INVALID, not a verdict)
#   3  notepad opened and dom0 got no window     (graded here)
# The messages are unchanged, so a campaign log reads exactly as before.
grade_appvm_window(){ # $1=appvm $2=tag $3=boot-number
  local app=$1 lbl=$2 b=$3
  # Pixels, not logs: open notepad and require a mapped, non-fullscreen window.
  local nppid npstart; read -r _ nppid npstart <<< "$(QTEST_VM=$app T=45 ctl_start notepad)"   # by handle (lifecycle-lib.sh)
  local try W=0 big=0 f w h
  for try in 1 2 3 4 5 6; do
    sleep 7
    rm -f $M/$lbl-appvm-b$b.tar
    QTEST_VM=$app timeout -k 8 120 ./tools/qtest shot $M/$lbl-appvm-b$b.tar >/dev/null 2>&1
    [ -s $M/$lbl-appvm-b$b.tar ] && [ "$(tar tf $M/$lbl-appvm-b$b.tar 2>/dev/null | grep -c '\.png$')" -gt 0 ] && break
  done
  rm -rf $M/$lbl-appvm-b$b-png; mkdir -p $M/$lbl-appvm-b$b-png
  tar xf $M/$lbl-appvm-b$b.tar -C $M/$lbl-appvm-b$b-png 2>/dev/null
  for f in $M/$lbl-appvm-b$b-png/*.png; do
    [ -e "$f" ] || continue
    W=$((W+1)); read -r w h < <(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(33); w,h=struct.unpack('>II',d[16:24]); print(w,h)" "$f" 2>/dev/null)
    [ -z "${w:-}" ] && continue
    say "    $(basename $f) ${w}x${h}"
    [ "$w" -ge $(( 5120 * 99 / 100 )) ] && [ "$h" -ge $(( 1440 * 99 / 100 )) ] && big=1
  done
  # AN EMPTY dom0 CAPTURE IS NOT "NO WINDOW" (memory rule, and measured 2026-09-11: campaign
  # 34594988407 graded WIN11-appvm boot 2 a product FAIL on six empty tars while qrexec answered
  # and the guest took an orderly ACPI shutdown 58 s later - the owner was switching dom0
  # desktops, and the screenshot service returns only windows on the CURRENT one). So before
  # grading, ask the GUEST whether notepad has a top-level window. Guest window present + dom0
  # capture empty = INVALID-INSTRUMENT (ungraded), never a product verdict. Probed BEFORE the
  # taskkill, or there is nothing left to ask about.
  local gw=""
  if [ "$W" -eq 0 ]; then
    gw=$(g_probe "$app" NPWIN 'Write-Host ("NPWIN=" + ((Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count))' 60)
  fi
  say "  notepad: $(QTEST_VM=$app T=45 ctl_stop "${nppid:-0}" "${npstart:-0}")"
  if [ "$big" = 1 ]; then no "$lbl-appvm boot $b: a FULLSCREEN-SIZED window was mapped"; return 1
  elif [ "$W" -gt 0 ]; then ok "$lbl-appvm boot $b: $W window(s) mapped, none fullscreen-sized"; return 0
  elif [ "${gw:-x}" -ge 1 ] 2>/dev/null; then
    say "  $lbl-appvm boot $b: INVALID-INSTRUMENT - the guest shows $gw notepad window(s) but the dom0 capture returned none on six tries (a dom0 desktop switch or capture fault; graded after the cell's other boots)"
    return 2
  else no "$lbl-appvm boot $b: notepad opened but dom0 got NO window (guest-side notepad windows: ${gw:-unreadable})"; return 3; fi
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
  # EXISTENCE FIRST. w_state reports an EMPTY string for a VM that does not exist, and "" != Halted,
  # so an ABSENT template used to enter this branch, get a silent qvm-shutdown, and then be waited on
  # for 420 s before failing as "template would not halt". Both appvm cells of run 9 failed exactly
  # that way - `DEADLINE 420s, still ` with a blank state - while neither win10-tpl nor win11-tpl has
  # ever existed on this rig: `rebuild-rig.sh --only tpl10/tpl11` builds them and had not been run.
  # Four of that campaign's eleven failures were this one message. A missing FIXTURE is an
  # infrastructure fact, knowable in one call, and it must not read as a guest that refused to halt.
  if ! qvm-check "$tpl" >/dev/null 2>&1; then
    no "$3-appvm: template '$tpl' DOES NOT EXIST - build it with mgmt/harness/rebuild-rig.sh --only ${tpl%%-*}... (tpl10/tpl11); this cell derives an AppVM from it and cannot create it"
    return
  fi
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
  qvm-features "$app" timezone localtime >/dev/null 2>&1 || true   # same reason as the create path above
  qvm-prefs "$app" memory 8192 >/dev/null 2>&1; qvm-prefs "$app" maxmem 0 >/dev/null 2>&1
  qvm-prefs "$app" vcpus 4 >/dev/null 2>&1; qvm-prefs "$app" qrexec_timeout 6000 >/dev/null 2>&1
  if [ "$had_app" = 1 ]; then
    qvm-prefs "$app" netvm "${appnetvm:-}" 2>/dev/null \
      || say "  [WARN] could not restore netvm='${appnetvm:-}' on $app - re-apply it before any network use"
  else
    qvm-prefs "$app" netvm '' >/dev/null 2>&1
  fi
  # THE EVIDENCE STICK, WHICH THIS CELL NEVER HAD. Every other cell gets a DIAG log volume on the
  # prime-run path above; this one derives an AppVM from a template instead and never reached that
  # code, so LOGVOL_IMG stayed unset and grade_cell_logsweep reported "no log volume was attached
  # for this cell". MEASURED in run 38787325142: win10-appvm pulled ONE file - a zero-byte
  # sweep.log, 0 QWT lines - and its sweep FAILED for missing data, which it should. One cell in
  # eight had produced no guest evidence in any run.
  # BEFORE THE FIRST BOOT: a --required assignment is satisfied at domain creation, so a volume
  # attached after the start is invisible to the guest.
  LOGVOL_VM="$app"; LOGVOL_IMG=$(logvol_image "$app")
  if logvol_create "$LOGVOL_IMG" "$app" >>"$M/$3-appvm-logvol-setup.out" 2>&1 \
     && logvol_attach "$app" "$LOGVOL_IMG" "$M/logvol-manifest.json" >>"$M/$3-appvm-logvol-setup.out" 2>&1; then
    say "  $3-appvm: log volume attached ($LOGVOL_IMG)"
  else
    # HARD: same reason as the churn path above. An appvm cell with no volume is a cell that
    # cannot be swept, and it was graded blind in two consecutive campaigns.
    say "[ERROR] FATAL: $3-appvm: log volume NOT ATTACHED - $(tail -1 "$M/$3-appvm-logvol-setup.out" 2>/dev/null | cut -c1-140)"
    say "[ERROR] FATAL: this cell's guest logs cannot be swept; the campaign STOPS rather than grade blind."
    say "=== MATRIX: ${PASS:-0} passed, $(( ${FAIL:-0} + 1 )) failed - ABORTED on a log-device failure ==="
    exit 2
  fi
  say "  $app re-created FRESH from $tpl (private auto-seeded from the template's private at creation)"
  local b
  # A dom0 DESKTOP SWITCH MUST NOT FAIL A CELL. Measured 2026-10-10 and CONFIRMED BY THE OWNER, who was
  # switching dom0 desktops at 14:12: boot 1 graded INVALID-INSTRUMENT on six empty tars while the guest
  # showed one notepad window, and boots 2 and 3 of the SAME cell, same guest, same window, minutes
  # later, both returned "1 window(s) mapped". The detection was right and the ACCOUNTING was wrong - it
  # wrote a FAIL line that marks the cell, release-acceptance turned that into a short coverage receipt,
  # and gate-scope refused the cut because someone moved a window on his own screen. So the condition has
  # to REPEAT across the cell's boots before it marks anything: one boot where dom0 saw the window proves
  # the instrument works, and a single empty capture beside it is the switch, not a defect. If NO boot
  # ever mapped a window, that is still a failure and still fails.
  local ii_boots=0 mapped_any=0
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
    # POINT THE APPVM AT ITS OWN VOLUME. The cell creates the volume and attaches it before the
    # first boot, but never bound it - and an AppVM inherits the TEMPLATE's registry, so LogDir
    # still named the TEMPLATE's directory. Measured on run 39225775322: both appvm cells swept
    # `Z:\qwt-logs\win10-acc` while the volume they were given carried `id win10-app`, their
    # collector reported `logdir.exists=0`, and both cells failed INVALID-SWEEP-BLIND with 0 QWT
    # lines - on a guest whose own evidence volume had attached correctly minutes earlier.
    # EVERY BOOT, NOT THE FIRST. An AppVM's ROOT volume is volatile - Qubes discards it at
    # shutdown and re-derives it from the template - and HKLM\Software lives on it. So a LogDir
    # written on boot 1 is GONE on boot 2, and the guest is back to whatever the TEMPLATE's
    # registry says. Measured on run 39225775322, 2026-10-20: the bind set
    # `id=win10-app new=Z:\qwt-logs\win10-app` at 13:27:25 and the collector read
    # `Z:\qwt-logs\win10-acc exists=0` at 13:30:32 - the template's path, after boots 2 and 3 had
    # reset the registry under it. Both appvm cells swept 0 QWT lines in BOTH campaigns for this.
    # Binding on each boot costs one registry write and is what makes the LAST boot - the one
    # grading reads - point at this AppVM's own volume.
    if [ "${LOGVOL_BIND:-1}" = 1 ] && [ -n "${LOGVOL_IMG:-}" ]; then
      logvol_bind_now "$app" "$3-appvm-b$b"
    fi
    # EVERY BOOT IS STILL GRADED. None of the four verdicts ended the cell before this split, and
    # none does now: the loop runs all three boots whatever one of them says, because the
    # instrument verdict below needs to know how many of the three were affected. Mapping the
    # fullscreen and no-window cases to `return` here would have aborted the cell after the first
    # bad boot - a silent behaviour change introduced by the refactor, not by anyone's decision.
    grade_appvm_window "$app" "$3" "$b"
    case $? in
      0) mapped_any=1 ;;                 # window(s) mapped, none fullscreen-sized
      2) ii_boots=$((ii_boots+1)) ;;     # guest had a window, dom0 capture empty: INVALID, counted
      1|3) : ;;                          # graded inside the function; the cell continues
    esac
  done
  # THE CELL'S VERDICT ON THE INSTRUMENT, now that every boot has been seen. (# GUARD:iirepeat)
  if [ "$ii_boots" -gt 0 ] && [ "$mapped_any" = 1 ]; then
    say "  $3-appvm: $ii_boots of 3 boots returned an empty dom0 capture while the guest had a window, and another boot mapped one - a dom0 desktop switch, NOT graded (the owner confirmed one on 2026-10-10)"
  elif [ "$ii_boots" -gt 0 ]; then
    no "$3-appvm: every boot with a guest-side window returned an empty dom0 capture ($ii_boots of 3) - the capture never worked, which is not a desktop switch"
  fi
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
  say "[ERROR] FATAL: RELEASE_SETUP is unset. Point it at the release setup tree, e.g."
  say "  RELEASE_SETUP=\$HOME/deslice-dl-setup RELEASE_ISO=\$HOME/rel/qwt-improved-setup.iso \\"
  say "  RELEASE_COMMIT=<sha> CELLS=\"win10-clean win10-reinstall\" G10=win10-iqi mgmt/harness/matrix.sh"
  exit 1; }
[ -d "$RELEASE_SETUP" ] || { say "[ERROR] FATAL: RELEASE_SETUP=$RELEASE_SETUP is not a directory"; exit 1; }
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
    say "[WARN] RELEASE_COMMIT unset and the MANIFEST names no commit - gating against HEAD, which is WRONG for a campaign"
  fi
fi
RELEASE_REF="${RELEASE_COMMIT:-HEAD}"
# ^{commit} IS NOT DECORATION. `git rev-parse <40 hex>` returns ANY well-formed sha VERBATIM,
# existing or not - it only resolves names - so a mistyped or invented commit sailed through this
# line and Gate-0 then matched it against the MANIFEST on a shared PREFIX. Measured 2026-10-18: a
# campaign was launched with 0040cfd81bff6f6f6f6f6f6f6f6f6f6f6f6f6f6f, a real short sha padded with
# 6f, and Gate-0 reported "PASS: payload verified - built from 0040cfd81bff ... installer matches
# repo" on a commit this repository does not contain. The peg that proves a package is the release
# under test must itself be a commit that exists; ^{commit} is what asks.
# --verify --quiet, NOT a bare rev-parse: on failure `git rev-parse X^{commit}` ECHOES ITS OWN
# ARGUMENT to stdout and exits 128, so the `-n` test below passed and RELEASE_SHA held the literal
# "<sha>^{commit}". Both halves of this line were wrong and the second was found only by driving it.
RELEASE_SHA=$(git rev-parse --verify --quiet "$RELEASE_REF^{commit}")
[ -n "$RELEASE_SHA" ] || { say "[ERROR] FATAL: cannot resolve RELEASE_COMMIT='$RELEASE_REF' in this repo"; exit 1; }
if ./tools/assert-payload.sh "$RELEASE_SETUP" "$RELEASE_REF" >"$M/setup-gate0.out" 2>&1; then
  say "Gate-0 (setup tree): $(tail -1 "$M/setup-gate0.out")"
else
  say "[ERROR] FATAL: Gate-0 FAILED on RELEASE_SETUP=$RELEASE_SETUP:"
  tail -3 "$M/setup-gate0.out" | sed 's/^/  /' | tee -a "$R"
  exit 1
fi
# ASHA is the release binary's hash, and verify_installed greps the guest's RESULT for
# "installed_gui_agent_sha256":"$ASHA. If it were empty that grep would degenerate to matching the
# bare key - i.e. ANY result passes without ever checking which build installed (INVALID-
# WRONGBUILD). The release ships the byte-exact agent at reference/gui-agent.exe and names its
# hash in MANIFEST.json reference_binaries; require BOTH and require them to AGREE. Fail closed.
[ -s "$RELEASE_SETUP/reference/gui-agent.exe" ] || {
  say "[ERROR] FATAL: $RELEASE_SETUP/reference/gui-agent.exe missing - without it the agent-hash check"
  say "       silently matches any build and every cell would report a vacuous PASS."
  exit 1; }
ASHA=$(sha256sum "$RELEASE_SETUP/reference/gui-agent.exe" | cut -c1-12)
MSHA=$(python3 -c "import json;print((json.load(open('$RELEASE_SETUP/MANIFEST.json')).get('reference_binaries') or {}).get('gui-agent.exe',''))" 2>/dev/null | cut -c1-12)
{ [ -n "$ASHA" ] && [ "$ASHA" = "$MSHA" ]; } || {
  say "[ERROR] FATAL: reference/gui-agent.exe hash ('$ASHA') disagrees with MANIFEST reference_binaries ('$MSHA')"
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
B10="${B10:?set B10 to the Win10 base golden - there is no default target}"
B11="${B11:?set B11 to the Win11 base golden - there is no default target}"

# A10/A11 = the DISPOSABLE per-OS churn subjects EVERY install cell targets (TARGET MODEL above).
# Fixed names, deliberately not knobs ("do not complicate the controls"): prime-run recreates
# them freely, ensure_churn_target creates them on demand, and nothing - no AppVM, no derived
# state - may ever bind to them. The templates (win10-tpl/win11-tpl) are NEVER an install-cell
# target; only the appvm cell touches them, by volume restore.
# The instant the campaign started, for the guest-log collector's --since window below. Taken once
# so every cell reports against the same base, and NEVER from a guest clock (the guest's clock flips
# ~3 h about 60 s into every boot, which has broken three freshness checks here).
CAMPAIGN_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# THE CHURN TARGETS. The DEFAULTS are the documented names - docs/ACCEPTANCE-PROTOCOL.md's cell
# table names win10-acc/win11-acc as what every cell reclones into, and the checkpoint names,
# the AppVM derivation and the log-volume image paths are all derived from them. Overridable
# only for a deliberate one-off (e.g. keeping a preserved specimen's name free); an override
# DEVIATES from the committed procedure, so it needs the same justification any heavy path does
# - put to Jev on 2026-10-14 it scored 0.75 as the thing to fix rather than ship.
A10="${A10:-win10-acc}"
A11="${A11:-win11-acc}"

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
      say "[ERROR] FATAL: entry image '$g' is a CHURN TARGET (disposable install subject) - the cells"
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
    say "[ERROR] FATAL: entry image $g has NEITHER an intact seal NOR a fixture record."
    say "       ./mgmt/golden.sh verify $g    # if it is meant to be a sealed golden"
    say "       ./mgmt/golden.sh fixture $g   # if it is meant to be a campaign fixture"
    say "       Cloning from it would inherit whatever it happens to contain."
    exit 1
  fi
  # CUSTODY IS NOT CAPABILITY. The check above proves we know what the image IS; it says nothing
  # about whether it carries QWT, and an over-existing cell needs QWT for two separate reasons: the
  # MSI is a major UPGRADE over an existing install, and every readiness probe in the cell is
  # qrexec, which does not exist without it. MEASURED 2026-10-14: G10 was win10-base, a pristine
  # base. The clone booted perfectly - it mounted the FAT log volume and wrote System Volume
  # Information - and then sat idle (cpu_usage_raw 149-463, an order of magnitude BELOW the idle
  # band) while the cell waited 900 s for a qrexec answer that could never come, and reported
  # "clone did not boot" plus a wedge suspicion. Nothing was wrong with the guest.
  # A fixture record IS the receipt that a QWT build was installed (it carries package_version and
  # gui_agent_sha256); a sealed golden carries QWT only if it is one of the -qwt fixtures, because
  # on this rig "<name>-qwt have QWT; the bases do not".
  if ./mgmt/golden.sh fixture "$g" >/dev/null 2>&1; then :
  elif [ "${g%-qwt}" != "$g" ]; then :
  else
    say "[ERROR] FATAL: entry image $g carries NO QWT, so an over-existing cell cannot run on it."
    say "       The cell installs the release OVER an existing QWT and probes readiness by qrexec;"
    say "       on a pristine base neither exists, so it waits out its whole deadline and reports"
    say "       a boot failure that never happened (measured 2026-10-14, WIN10-upgrade, 900 s)."
    say "       Name a QWT-carrying entry: a -qwt golden, or a fixture built by prime-run:"
    say "         mgmt/harness/prime-run.sh <base> <fixture> ours --payload <previous setup tree>"
    say "       Sealed goldens here: $(ls mgmt/goldens/*.json 2>/dev/null | xargs -r -n1 basename | sed 's/\.json$//' | tr '\n' ' ')"
    exit 1
  fi
done

say "=== MATRIX for $PV (agent $ASHA) ==="
# CELLS used to default to "seeded", which matches NO case arm below: the driver would fall
# straight through and print "0 passed, 0 failed" - a run that looks completed and tested nothing.
# A campaign with no cells is an operator error, not a default.
[ -n "${CELLS:-}" ] || {
  say "[ERROR] FATAL: CELLS is unset. Name the cells explicitly, e.g."
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
      [ -n "${G10:-}" ] || { say "[ERROR] FATAL: cell '$c' needs G10 set (the Win10 entry image: previous-ours or stock fixture)"; exit 1; }
      NEED_ISO=1 ;;
    win11-upgrade|win11-seeded|win11-stock)
      [ -n "${G11:-}" ] || { say "[ERROR] FATAL: cell '$c' needs G11 set (the Win11 entry image: previous-ours or stock fixture)"; exit 1; }
      NEED_ISO=1 ;;
    win10-reinstall|win11-reinstall) NEED_ISO=1 ;;
    win10-clean)
      ./mgmt/golden.sh verify "$B10" >/dev/null 2>&1 \
        || { say "[ERROR] FATAL: base $B10 failed its seal check - a clean cell cannot enter from a drifted base"; exit 1; }
      say "  base $B10: SEALED GOLDEN, intact" ;;
    win11-clean)
      ./mgmt/golden.sh verify "$B11" >/dev/null 2>&1 \
        || { say "[ERROR] FATAL: base $B11 failed its seal check - a clean cell cannot enter from a drifted base"; exit 1; }
      say "  base $B11: SEALED GOLDEN, intact" ;;
  esac
done
[ "$NEED_ISO" = 1 ] && ensure_release_loop
for c in $CELLS; do
  # PER CELL, NOT ONCE. The start-of-campaign check cannot see a pool that fills at cell 11, which is
  # the case that matters: stopping cleanly between cells leaves every completed cell's verdict
  # trustworthy, while filling MID-cell leaves a half-provisioned guest and a result nobody can read.
  # A refusal here is INVALID-POOL for the cell that did not run, and the loop stops - it does not
  # skip ahead, because the cells after it would be no better off.
  if ! pool_gate "cell $c"; then
    say "INVALID-$c  not run: the thin pool is below the floor. Cells completed before this one stand;"
    say "            the campaign is INCOMPLETE and its coverage receipt must not claim this cell."
    FAIL=$((FAIL+1)); INVALID=$((INVALID+1))
    break
  fi
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
      say "[ERROR] FATAL: cell '$c' is RETIRED - it installed from a pushed payload tree (push_payload"
      say "       q4315), which is forbidden: our code enters a guest ONLY from the release"
      say "       package. Clean install = win1X-clean (prime-run from the pristine base; the"
      say "       base's testsigning OFF makes it the true two-stage path)."
      FAIL=$((FAIL+1)) ;;
    # An unknown selector must FAIL the campaign, not be narrated past: a typo would otherwise
    # silently shrink the matrix and the summary would still read as a clean run.
    *) say "[ERROR] FATAL: unknown cell '$c'"; FAIL=$((FAIL+1)) ;;
  esac
  # PULL AFTER EVERY CELL, pass or fail, wedged or clean. Host-side with mtools: nothing is asked of
  # the guest and nothing is detached, so a cell that hung with qrexec dead still yields its logs -
  # the entire reason the volume exists.
  if [ -n "$LOGVOL_IMG" ]; then
    if logvol_pull "$LOGVOL_IMG" "$M/logvol-$c" >>"$M/$c-logvol-pull.out" 2>&1; then
      say "  $c: log volume pulled -> $M/logvol-$c"
    else
      say "  $c: [WARN] could not pull the log volume $LOGVOL_IMG: $(tail -1 "$M/$c-logvol-pull.out" 2>/dev/null | cut -c1-140)"
    fi
    LOGVOL_IMG=""; LOGVOL_VM=""
  fi

  # PRESERVE THE GUEST'S OWN LOGS FOR EVERY CELL, not just the two that bind a volume.
  #
  # The volume is bound on the reinstall and upgrade cells only (logvol_bind_now, two call sites),
  # so the clean and appvm cells contributed NOTHING guest-side: measured on the 2026-10-14 campaign,
  # the clean cell's evidence dir held 48 lines across four files and ZERO in QWT or installer
  # format. The end-of-campaign sweep then reads harness bash lines for half the matrix, and a
  # "clean sweep" over that is clean across half the evidence - the same false comfort as the
  # 96-of-96 campaign that shipped with "log-volume bind failed" in its own log. The owner, asked
  # what the sweep can read from cells we did not preserve: nothing.
  #
  # mgmt/harness/log-sweep.sh is the sanctioned collector and matrix.sh was one of the ~50 harnesses
  # that never called it (findings HARNESSLOGUNSWEPT). It pulls host-side into <out>/logs/, so it
  # needs the guest to answer; where it cannot, that is REPORTED rather than passed over, and the
  # volume still covers the cells that bound one.
  _slv="$(_matrix_sweep_subject "$c" "$A10" "$A11")"
  # One cell's guest-log sweep, graded. grade_cell_logsweep() is a function so it can be exercised
  # without a guest: tools/tests/matrix-logsweep-grade-selftest.sh drives every exit code through it
  # and checks that one condition produces exactly one tally entry and that each message's numbers
  # come off the disk. Grading this inline is how it shipped claiming a cell had "no guest logs"
  # while 37 files sat beside it.
  if [ -n "$_slv" ] && qvm-check "$_slv" >/dev/null 2>&1; then
    grade_cell_logsweep "$c" "$_slv" "$M"
    # THE DOM0 CALLER CHANNEL, which this gate could not see. The release goal is "qrexec behavior
    # is aligned with dom0 callers: updaters and start menu, from cold qube as well", and dom0
    # drives the update agent over qubes.VMExec: stdout is taken as the agent's log, bare floats on
    # stderr drive the Update GUI's progress bar. On 2026-10-14 a 4.3.36 guest ran the command,
    # returned its exit code and delivered NEITHER stream (VMEXECNOSTDOUT) - and grepping this
    # harness, the protocol and its runner for a stdout assertion on that service returned nothing.
    #
    # THE WARM CHECKS HAVE MOVED INTO THE CELL (grade_dom0_callers, called from accept_grade), where
    # the guest is up. They used to run HERE, guarded on the cell's guest still answering - and every
    # cell halts, parks or removes its subject as its last act, so only the final cell could ever
    # have a live guest at this point. Run 8's matrix log contains ZERO lines matching VMEXEC; run 9
    # measured three win11 cells and reported "guest not answering" for every win10 one.
    #
    # WHAT STAYS HERE IS THE COLD CASE, because this is the one place a subject is legitimately
    # Halted: "from cold qube as well" is a clause of the release goal, and dom0 calling a service on
    # a Halted Windows qube is a different path from calling one on a running guest - qrexec has to
    # start the qube and the agent has to be serving before the call is handed over. It is measured
    # ONCE per campaign rather than once per cell: a cold start costs a boot, the path does not vary
    # by cell, and zero measurements is what it was before.
    if [ "$(w_state "$_slv")" = Running ] && w_alive "$_slv"; then
      # ONCE PER OS FAMILY, NOT ONCE PER CAMPAIGN. The budget used to be one campaign-wide latch,
      # so whichever cell ran first consumed it - and the cell order puts win10 first, so run
      # 38994277148 evidenced the goal clause "from cold qube as well" on WIN10 and on no win11
      # cell at all (the three win11 cells carry the warm checks only). Win11 is this project's
      # stated target, and the premise the single latch rested on - "the path does not vary by
      # cell" - is exactly what should not be assumed ACROSS FAMILIES here: the defect this goal
      # exists to close was named as DETACHED_PROCESS plus a grandchild on Win11, and the agent,
      # the wrapper and the boot timing all differ between the two. Jev: once per OS family 0.87
      # (leave as is 0.00), premise should not be assumed across families 0.91.
      # Cost is one extra halt-and-boot per campaign, which is what buys the clause on the target.
      _cf=win_other
      case "$c" in win10*|WIN10*) _cf=win10 ;; win11*|WIN11*) _cf=win11 ;; esac
      eval "_cdone=\${COLD_CALLER_DONE_$_cf:-0}"
      if [ "$_cdone" = 0 ]; then
        eval "COLD_CALLER_DONE_$_cf=1"
        say "  $c: halting $_slv to measure the COLD caller path (the goal's 'from cold qube as well')"
        qwt_shutdown "$_slv" 600 >>"$M/$c-coldcallers.out" 2>&1 || true
        if [ "$(w_state "$_slv")" = Halted ]; then
          if ./mgmt/harness/dom0-callers-check.sh --cold "$_slv" say >>"$M/$c-coldcallers.out" 2>&1; then
            ok "$c: start-menu caller aligned FROM A COLD QUBE (the call started it and dom0 could parse the answer)"
          else
            no "$c: the start-menu caller is NOT aligned from a cold qube - see $M/$c-coldcallers.out"
          fi
          # THE GOAL NAMES TWO CALLERS, AND ONLY ONE OF THEM HAD A COLD CHECK. "updaters and start
          # menu, from cold qube as well" - qubes.VMExec, the service dom0 drives the Windows update
          # agent over, was called warm only (the per-cell call above). ONLY THE FIRST call to a
          # Halted qube is cold, and the start-menu check just used it, so this costs a second halt.
          # Once per OS FAMILY, like the first - see the latch above for why the campaign-wide
          # version left the goal's cold clause evidenced on win10 only.
          say "  $c: halting $_slv again to measure the COLD UPDATER caller (qubes.VMExec)"
          qwt_shutdown "$_slv" 600 >>"$M/$c-coldvmexec.out" 2>&1 || true
          if [ "$(w_state "$_slv")" = Halted ]; then
            if ./mgmt/harness/vmexec-channel-check.sh --cold "$_slv" say >>"$M/$c-coldvmexec.out" 2>&1; then
              ok "$c: updater caller aligned FROM A COLD QUBE (the grandchild's stdout arrived on a qube the call started)"
            else
              no "$c: the updater caller is NOT aligned from a cold qube - see $M/$c-coldvmexec.out"
            fi
          else
            say "  $c: [WARN] $_slv would not halt a second time, so the cold UPDATER path went unmeasured"
          fi
        else
          say "  $c: [WARN] $_slv would not halt, so the cold caller path went unmeasured"
        fi
      fi
    else
      say "  $c: [WARN] guest not answering; the cold caller path went unmeasured for this cell"
    fi
  else
    say "  $c: [WARN] no guest left to collect from; the volume pull left $(find "$M/logvol-$c" -type f 2>/dev/null | wc -l) file(s) for this cell"
  fi
done

# THE COLD CALLER PATH MUST HAVE BEEN MEASURED, AND ZERO MEASUREMENTS IS NOT A PASS.
#
# COLD_CALLER_DONE was SET and never READ. The cold measurement is guarded on the cell's subject
# still answering, and when that guard fails the loop above says "[WARN] ... the cold caller path
# went unmeasured for this cell" - a WARN - and the campaign carries on and can finish green. This
# file's own notes record it happening: "Run 8's matrix log contains ZERO lines matching VMEXEC; run
# 9 measured three win11 cells and reported 'guest not answering' for every win10 one."
#
# "from cold qube as well" is a CLAUSE OF THE RELEASE GOAL. A campaign that never measured it has
# not tested the goal, so it does not get to pass quietly: the absence is graded, exactly like a
# missing log is graded rather than assumed clean. It is INVALID rather than FAIL because an
# unmeasured path is missing instrument data, not a demonstrated product defect - the same rule the
# sweep below follows.
# ...AND THIS GUARD READ A NAME NOTHING WRITES, which is how it failed a campaign that had already
# measured the clause twice. The latch is PER OS FAMILY - the loop above sets COLD_CALLER_DONE_win10
# / COLD_CALLER_DONE_win11 (eval, line ~2493) - while this read asked for the unsuffixed
# COLD_CALLER_DONE, which no line in this file ever assigns. So it was pinned to 0 for ever and
# every campaign reported "never measured". MEASURED 2026-10-18, campaign 20261018-010748: the log
# carries "PASS win11-clean: start-menu caller aligned FROM A COLD QUBE" and "PASS win11-clean:
# updater caller aligned FROM A COLD QUBE", win11-clean-coldcallers.out ends "the start-menu caller
# is aligned on win11-acc (cold, 78 entries, 84s)", and this guard still returned INVALID-COLDCALLER.
# A release could not pass acceptance for a reason that had nothing to do with the release.
#
# IT NOW JUDGES THE ARTIFACT, NOT ITS OWN BOOKKEEPING. Reading a shell latch is what made a wrong
# name invisible, and a latch set inside the grading loop is also hostage to that loop's subshell
# scoping; the evidence file the operator is pointed at cannot be either. For every OS family this
# campaign actually ran cells for, there must be a *-coldcallers.out carrying the aligned sentence.
# An absence is still INVALID rather than FAIL - missing instrument data, not a product defect.
_cold_missing=
_cold_seen=
for _f in $(for c in $CELLS; do case $c in win10*|WIN10*) echo win10 ;; win11*|WIN11*) echo win11 ;; esac; done | sort -u); do
  _cold_hit=0
  for _co in "$M"/*-coldcallers.out; do
    [ -e "$_co" ] || continue
    case "$(basename "$_co")" in "$_f"*) ;; *) continue ;; esac
    grep -aq 'caller is aligned on .*(cold' "$_co" && _cold_hit=1
  done
  if [ "$_cold_hit" = 1 ]; then _cold_seen="$_cold_seen $_f"; else _cold_missing="$_cold_missing $_f"; fi
done
if [ -n "$_cold_missing" ]; then
  no "INVALID-COLDCALLER  the cold dom0-caller path was never measured for:$_cold_missing - 'from cold qube as well' is a release-goal clause, and zero measurements of it is not a pass (see the per-cell *-coldcallers.out, and the guard in the grading loop above)"
else
  ok "the cold dom0-caller path was measured this campaign for every OS family it ran ($_cold_seen )"
fi

# HARDWIRED ERROR SWEEP OVER THE CAMPAIGN'S OWN LOGS, AND IT BLOCKS.
#
# Nothing swept these. A campaign that reported 96 of 96 clean carried "log-volume bind failed" on
# BOTH upgrade cells, and every reader including a model read the run as green (HARNESSLOGUNSWEPT,
# LOGVOLBINDUPGRADE). Reporting was not enough - a line nobody reads is a line nobody reads whether
# or not a tool printed it.
#
# IT RAISES THE *INVALID* CLASS, NEVER PRODUCT FAIL. An unaccounted error in our own harness logs is
# missing or unexplained INSTRUMENT data, not a demonstrated product defect, and verdict-lib's V2
# invariant is that INVALID-* is never folded into FAIL. INVALID blocks the release gate on its own
# (the gate requires zero INVALID), so this stops a cut without inventing a product verdict.
#
# A declared error is accounted for by an entry in mgmt/harness/error-ledger.txt that RECORDS WHY it
# is not a defect. A row with no reason does not account for anything, and nothing is ever hidden:
# accounted messages are printed too, every run.
if [ -x tools/sweep-gate.sh ]; then
  # THE GUEST'S OWN LOGS ARE IN SCOPE, and they are where the product's errors are. logvol_pull
  # drops them under $M/logvol-<cell>/, which a flat "$M"/*.log glob does not see - the first
  # version of this block swept only the harness's bash output and would have reported a campaign
  # clean while the guest's gui-agent log carried a crash loop. No release-grading harness calls
  # log-sweep.sh either (measured: 0 references in matrix.sh, quick-upgrade.sh and wu-e2e.sh), so
  # before this nothing swept the product's logs during a campaign at all.
  #
  # BOUNDED, AND IT SAYS SO WHEN IT IS. A capped sweep that reads as clean is worse than no sweep,
  # so the cap is reported and raises the INVALID class exactly like an unaccounted error would.
  # THE BOUND MUST TRACK THE CAMPAIGN, NOT BE A CONSTANT. Run 39225775322 - a full eight-cell
  # matrix - produced 610 files against a fixed 600 and raised INVALID-SWEEP-CAPPED on campaign
  # SIZE alone. A cap a complete campaign exceeds by construction empties the class exactly when
  # the campaign is most complete: the fuller the matrix, the more certain it is not swept.
  # Measured on that run: 610 files over 8 cells, 77 per cell. Budget 150 per cell - headroom of
  # about 2x - and keep the old 600 as a floor so a one-cell campaign is bounded as before. The
  # cap is still REPORTED when exceeded; that part was right and is unchanged.
  _sw_cells=$(printf '%s' "${CELLS:-}" | wc -w)
  _sw_budget=$(( _sw_cells * 150 ))
  [ "$_sw_budget" -lt 600 ] && _sw_budget=600
  SW_CAP="${MATRIX_SWEEP_FILE_CAP:-$_sw_budget}"
  # NO DEPTH LIMIT - the cap below is the bound, not the depth. This read -maxdepth 3 and the guest
  # logs land at $M/logvol-<cell>/files/qwt-logs/<vm>/*.log, which is depth 5, so the limit excluded
  # exactly the files the previous commit added scope for and claimed were covered. Measured on a
  # real evidence tree: of the logs carrying a declared error, ALL of them were below the limit -
  # depth 3 reached 20 of 83 logs and 0 of the 10 that had errors in them.
  mapfile -t _swl < <(find "$M" -type f \( -name '*.out' -o -name '*.log' -o -name '*.cur' \
                        -o -name '*.tail' \) -size -8M -size +0 \
                        ! -name '*-logsweep.out' ! -path '*-guestlogs/analyze.out' \
                        ! -path '*-guestlogs/sweep.log' 2>/dev/null | sort)
  sw_total=${#_swl[@]}
  swlogs="$R"; n=0
  for o in "${_swl[@]}"; do [ "$n" -ge "$SW_CAP" ] && break; swlogs="$swlogs $o"; n=$((n+1)); done
  if [ "$sw_total" -gt "$SW_CAP" ]; then
    no "INVALID-SWEEP-CAPPED  the campaign produced $sw_total log files and the sweep read $SW_CAP - the rest are UNREAD, so this campaign is not swept (raise MATRIX_SWEEP_FILE_CAP and re-sweep $M)"
  fi
  say "sweep-gate: reading $n of $sw_total log file(s) under $M, plus the campaign log"
  # shellcheck disable=SC2086
  # DECLARED CAUSED BY THIS CAMPAIGN. The guest is right - a request WAS dropped - and the request is
  # OURS: the dropped one's command line is `qrexec-wrapper.exe <dom>|<port>|(null)|6|c:\Windows\
  # System32\cmd.exe`, which is the readiness probe's `cmd /c echo QREADY`, and the caller domain is
  # this management qube. Every burst sits between a halt THIS harness ordered and the next
  # session-up: measured 20261018-123812, clean cell - park-halt 12:50:19, guest QGAVCHANFAIL x3 at
  # 12:51:26, "session up at t+60s" 12:51:37.
  #
  # FOUR ATTEMPTS TO REMOVE THE CAUSE, MEASURED, before declaring it: baseline x9; one probe per wait
  # instead of per turn x8; the other six polling loops plus cancel-before-halt x9; and bracketing
  # the waits with qrexec_timeout 20 made it WORSE at x15, because a shorter hold means more
  # re-probes and every probe issued while the guest is down is queued and delivered the instant its
  # qrexec appears. That attempt is reverted. Jev, shown all four measurements: "stop chasing the
  # probe, declare it" 0.94; the declaration itself no_concealment 0.67.
  #
  # The per-cell sweep has declared this for a while (log-sweep --tolerate-error above, Jev
  # declare-as-caused 0.72), which is why the cells sweep CLEAN while this gate failed on the same
  # lines. A declaration that stops matching FAILS as stale, so it cannot become a silencer.
  # AND THE SHUTDOWN THIS CAMPAIGN ORDERS, which kills whatever was mid-run. Measured
  # 20261018-143438: a dom0 call was in flight and the QubesWindowsUpdateScan task was running when
  # the harness halted the guest, so the task's powershell was terminated with 0xC000013A
  # (STATUS_CONTROL_C_EXIT) and the death reporter recorded it - correctly, naming the cause itself:
  # "its program crashed with a console control (Ctrl-C, or the console closed)". That task ran 29
  # times in the campaign and succeeded every other time.
  #
  # NARROW ON PURPOSE: the regex requires BOTH the task's non-zero result AND the console-control
  # cause, so a QubesWindowsUpdateScan that fails for any other reason still blocks. Jev, shown the
  # sequence and this project's supervision rule that an unexpected death is a major error:
  # declare_caused 0.98 - a task killed by a shutdown WE ordered is not an unexpected death.
  # RARE: the campaign can cause this and usually does not - seen in 1 of 6 campaigns, because it
  # needs the task to be mid-run at the moment a cell halts the guest. Reported when absent, not a
  # failure. Jev: two_kinds 0.89.
  SWGATE_DECL=(--declare-caused-rare 'QubesWindowsUpdateScan ended with a non-zero result.*console control'
    'CAUSED by this campaign: the harness halts the guest between cells, and a scheduled task that is mid-run when that happens is terminated with STATUS_CONTROL_C_EXIT (0xC000013A). The death reporter names the cause itself. The task ran 29 times in this campaign and succeeded every other time; a non-zero result from any OTHER cause is not covered by this regex and still blocks.'
    # RARE TOO, AND THE SUITE PROVED WHY. T9 runs this very block against a CLEAN campaign fixture
    # and expects FAIL=0: with this declared strict, a campaign whose logs happen to carry no
    # QGAVCHANFAIL fails because the declaration is "stale" - i.e. the harness would REQUIRE its own
    # caused condition to occur. That is backwards, and it is the same mistake as the rule it came
    # from. A declaration never demands the condition; the anti-silencer property is that the row is
    # always printed, that it excuses ONLY what its regex names, and that an unmatched one is
    # reported. The strict kind stays in the tool for a caller who genuinely wants must-match
    # (sweep-gate T25c drives it), and nothing here uses it.
    # THE SAME SET THE PER-CELL SWEEP ALREADY HAS, and the reason this stopped being whack-a-mole.
    # log-sweep gets three --tolerate-error declarations above; this gate had two of them, so each
    # campaign failed on whichever of the missing ones happened to occur: 20261018-163605 fell over
    # "wmain: open agent pipe failed with error 0x2" x2, which the per-cell sweep has declared all
    # along with its receipt (Jev on that reason: caused 0.91 conf 0.86). Two instruments grading
    # one campaign must carry the same dispositions; tools/tests/matrix-sweep-tally-selftest.sh now
    # asserts they stay in step.
    --declare-caused-rare 'SetupNetwork: Failed to get qubes-ip|QioWriteBuffer: WriteFile failed with error 0xe8|send_command_to_daemon: write to daemon failed with error 0xe8|wmain: open agent pipe failed with error 0x2'
    'CAUSED by this campaign: every cell subject is given an EMPTY netvm (CLAUDE.md - only a guest that TESTS PV networking gets one), so /qubes-ip legitimately does not exist and the qubesdb client reports a missing pipe or a closed write. Declared for the per-cell sweep since 2026-10-17 with the same receipt; a cell WITH a netvm would not produce these.'
    --declare-caused-rare 'RecreateDuplication: .*BUT THE GEOMETRY CHANGED'
    'CAUSED by this campaign: it drives resolution changes, and a mode change across a duplication recreate is how DXGI signals staleness by design (owner 2026-10-17). Declared for the per-cell sweep with the same receipt, pending the pixel receipt in GEOMETRYERRORUNSETTLEABLE.'
    --declare-caused-rare 'InitVchan: QGAVCHANFAIL .*request dropped'
    'CAUSED by this campaign: the readiness probe (cmd /c echo QREADY) is queued by dom0 while the guest has no qrexec and delivered when it registers, with the caller gone - and the halt/boot cycle that strands it is one the install requires. Four measured attempts to remove it at the probe: x9 -> x8 -> x9 -> x15. Receipt: the dropped request names cmd.exe and this qube as caller; see the correlation in matrix.sh above and findings/issues.md QGAVCHANUNDECLARED.')
  # THE CAMPAIGN'S SIZE, so the gate can compare a vendored-emitter count against a baseline taken
  # from a campaign of a DIFFERENT size. Without it the comparison is absolute and a full 8-cell
  # campaign can never pass a 3-cell baseline - which is what blocked the 4.3.37 cut (see the
  # measurement in tools/sweep-gate.sh).
  SWEEP_GATE_CELLS=$(printf '%s\n' $CELLS | grep -ac .)
  export SWEEP_GATE_CELLS
  say "sweep-gate: $SWEEP_GATE_CELLS cell(s) in this campaign (the denominator for vendored-count rises)"
  # shellcheck disable=SC2086
  if bash tools/sweep-gate.sh "${SWGATE_DECL[@]}" $swlogs > "$M/sweep-gate.out" 2>&1; then
    say "sweep-gate: every declared error in the campaign's own logs is accounted for"
  else
    _sg_rc=$?
    nun=$(grep -ac '^  UNACCOUNTED' "$M/sweep-gate.out" 2>/dev/null || true); nun=${nun:-0}
    nro=$(grep -ac '^  ROSE' "$M/sweep-gate.out" 2>/dev/null || true); nro=${nro:-0}
    # PRINTED, BUT NOT COUNTED TWICE. no() writes every failing check into this same log as
    # "[ERROR] FAIL  <what>" and increments the tally in the same breath, so the gate re-reads our
    # own graded verdicts and each one would add a SECOND entry - classed INVALID, which asserts
    # that nothing graded it. One failure, two entries, the wrong class on the second; on this
    # project a double is a P1, and a cell failure belongs in the cell tally above.
    # They are still printed below: a declared error that stops being shown is how the original
    # incident happened. What changes is only whether they move the counter.
    ngr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$M/sweep-gate.out" 2>/dev/null || true); ngr=${ngr:-0}
    nun_raw=$nun          # before the discount: what the GATE itself counted
    nun=$((nun - ngr)); [ "$nun" -lt 0 ] && nun=0
    [ "$ngr" -gt 0 ] && say "sweep-gate: $ngr line(s) are this campaign's own graded verdicts, already in the tally above - shown, not counted again"
    # A GATE THAT FAILS FOR A REASON THIS BRANCH CANNOT COUNT MUST NOT PASS SILENTLY, and that is
    # not hypothetical: on 20261018-153728 the gate exited 1 over a stale declaration, this branch
    # counted zero UNACCOUNTED and zero ROSE, and the campaign reported rc=0 with 42 passed, 0
    # failed. A guard the harness cannot hear is decoration. So: anything the gate fails on that is
    # not one of the two row kinds is reported with its own structured line quoted.
    # THE RAW COUNT, NOT THE DISCOUNTED ONE - and getting that wrong is what made this guard
    # double-report on 20261018-172640. Two cells failed, the gate listed both as UNACCOUNTED, the
    # discount correctly took them to nun=0 because they are already in the cell tally, and this
    # guard then raised them AGAIN as "a reason this harness does not count". One failure, two
    # entries, the wrong class on the second - the exact defect matrix-sweep-tally-selftest exists
    # to prevent, reintroduced by the guard meant to stop silences.
    #
    # A gate failure is EXPLAINED when it listed any row at all, graded or not. It is unexplained
    # only when it failed with nothing listed - a stale declaration, say - and that is the case this
    # guard is for.
    if [ "${_sg_rc:-0}" -ne 0 ] && [ $((${nun_raw:-0} + nro)) -eq 0 ]; then
      no "INVALID-SWEEP-UNCLASSED  the gate exited ${_sg_rc} with no unaccounted or risen row - it failed for a reason this harness does not count. Its verdict line: $(grep -a 'SWEEP-GATE-RESULT' "$M/sweep-gate.out" 2>/dev/null | tail -1)"
    fi
    if [ $((nun + nro)) -gt 0 ]; then
      no "INVALID-SWEEP  ${nun:-0} unaccounted + ${nro:-0} risen declared error(s) in the campaign's own logs - read $M/sweep-gate.out, then fix the defect or record why it is not one"
    fi
    grep -aE '^  (UNACCOUNTED|ROSE)' "$M/sweep-gate.out" | head -10 | while IFS= read -r l; do say "  $l"; done
  fi
fi

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
# The footer below is an ANCHORED machine contract ('^=== MATRIX: N passed, M failed ===$') and
# stays byte-exact, so the campaign's severity is declared HERE, on the line that carries the same
# two numbers. Without it a campaign could end with failing cells and no line any sweep could judge
# - which is how a 96-of-96 "clean" campaign carried a log-volume bind failure nobody read.
_mx_sev=""; [ "$((FAIL-INVALID))" -gt 0 ] && _mx_sev="[ERROR] " || { [ "$INVALID" -gt 0 ] && _mx_sev="[WARN] "; }
say "${_mx_sev}classes: product-FAIL=$((FAIL-INVALID)) INVALID-*(cell did not run, ungraded)=$INVALID - the footer's 'failed' is both (contract kept; see mgmt/harness/verdict-lib.sh for the three-class rule)"
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
