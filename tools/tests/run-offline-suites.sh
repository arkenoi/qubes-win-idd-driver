#!/bin/bash
# run-offline-suites.sh - run every suite in offline-suites.txt, serially, and fail on any red.
#
#   tools/tests/run-offline-suites.sh
#
# This is the producer SELFTESTSUNRUNINCI was missing: 117 offline suites existed and CI named them
# only in comments, so a green `test` said nothing about any of them and every receipt in
# findings/issues.md held only as long as someone kept running them by hand.
#
# SERIAL BY DESIGN. Two suites that both bind and delete loop devices produced a false red when run
# in one command (BLOCKCLAIMSELFTESTRACES): loop numbers are global, so each can observe the other's
# device. Parallelism here would buy a minute and cost a believable red.
#
# THE FLOOR IS THE POINT. A runner that iterates a list cannot tell "all 37 passed" from "the list
# was emptied" - and a gate suite losing its producer is this project's most repeated failure
# (count-the-producers, the selftest whose RESULT line was deduped away, the gate that required 18
# suites where 12 had a producer). So the count is asserted against a floor that only moves in a
# commit, and a suite that reports zero assertions is a failure even at exit 0.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

# OFFLINE_SUITES_LIST/_DIR point this at a fixture list, for tools/tests/offline-runner-selftest.sh.
# A runner whose own floor and EMPTY rule have never been seen to FIRE is the thing it exists to
# stop, so they are proven against planted suites rather than asserted in this comment.
LIST=${OFFLINE_SUITES_LIST:-tools/tests/offline-suites.txt}
SUITEDIR=${OFFLINE_SUITES_DIR:-tools/tests}
# 36 since 2026-10-15: clock-convention-selftest.sh was DELETED with the decision block it tested.
# 56 since 2026-10-17: notifbridge-pid-selftest.sh ADDED, after the agent reported a
# predecessor's bridge exiting as its own bridge crashing.
# 55 since 2026-10-17: desktop-stuck-lock-selftest.sh ADDED, after an ACTION notification told
# the user to sign in to a guest that signed itself in 8 s later.
# 54 since 2026-10-17: wrapper-one-line-selftest.sh ADDED, holding one truncated transfer to
# ONE error line after a single event reported three times on a campaign cell.
# 53 since 2026-10-17: window-measure-selftest.sh ADDED, holding GetRealWindowRect to the
# discriminator between a vanished window and a monitor-topology fault.
# 52 since 2026-10-17: wait-bound-selftest.sh ADDED, after a probe bounded below the boot it waited
# for abandoned a request on every boot and the guest logged a dropped request for each one.
# 56 -> 57 on 2026-10-17: cold-caller-family-selftest.sh, which pins the release goal's cold-qube
# clause to EVERY OS family rather than to whichever cell ran first (it was evidenced on win10 only
# in run 38994277148, with win11 - the target - unmeasured).
# 57 -> 59 on 2026-10-19: relay-judge-timenorm-selftest.sh and wu-judge-timenorm-selftest.sh ADDED,
# after both update judges were found correlating two log sources by TIME OF DAY - no date, no zone.
# Measured: a relay line and a WU failure 24 h apart gave `gaps=0 violations=0` exit 0, and a WU
# window over a two-date decode graded `ended=True verdict: PASS` on a day whose pass never ran a
# search. Each suite carries the pre-fix comparison frozen beside the fixed one, so every case is
# seen to fail.
# The floor only ever moves in a commit, and this is that commit - a suite that loses its subject is
# removed deliberately, not left to rot green.
# 59 -> 60 on 2026-10-19: toasthold-grade-clock-selftest.sh ADDED, the same defect class in the
# toast-hold grader: bridge.log carries a time of day and NO date, and the date was put on it by
# comparing it against THIS qube's clock, three hours out of phase with the guest's on the very
# evidence it grades. Measured: a record stamped 61 s BEFORE its own toast read PASS OK-BRIDGED.
# 60 -> 61 on 2026-10-19: harness-clock-selftest.sh ADDED, the host-side half of the same class: one
# campaign matrix.log carried three clocks (its own `date` local, accept-clean's `date -u` quoted on
# the same line, arm-module-bases' UTC), and a guest-local stick file 42 s OLDER than its bind was
# read as three hours newer. Every host stamp is now `date -u` and each campaign log declares its
# zone first; the suite's negatives are frozen fixtures, so they cannot rot when the fix is committed.
# 74 -> 75 on 2026-10-21: gate-remainder-dry-selftest.sh ADDED. `gate-remainder.sh --dry` put
# EVERY reachable suite in PASSED and exited 0 - run_it's dry branch returns 0 and `note $?` read
# that as a result - and acceptance-plan.py:202 makes that dry call the remainder cell's first
# probe, so the probe could not fail. The suite runs the shipped script dry and requires an empty
# passed line, and its T10 drives the pre-fix definition through the same assertion and requires
# it to go red.
# 75 -> 76 on 2026-10-21: sweep-life-selftest.sh ADDED. tools/sweep-gate.sh returned a CLEAN
# verdict over an empty log file AND over a capture that failed to decode - it had no predicate
# asserting it had been handed anything gradeable. The suite drives all three refusals and a
# seen-to-fail leg that deletes the predicate and requires the empty capture to read CLEAN again.
# 97 -> 98 on 2026-10-23: deathevent-selftest.sh ADDED, and being unlisted is exactly why it rotted.
# It was in NEITHER list. Run by hand today it reported `clean: rc=1 ok=56 fail=4`: four text legs in
# agent/gui-agent/deathevent_test.c still asserted the wording from BEFORE agent fc94490 ("Say it in
# plain English, once"), which reworded the composer - deathevent.h prints "- after %s" where the legs
# expected "- after running %s", plus two reworded phrases and the teardown sentence. So the ONLY
# check of the death notification's TEXT - which ADR-supervision 3 requires to carry what died, its
# code and how long it ran - was red and unread. The legs are now aimed at the shipped wording, the
# suite is 60/0, and all four defect knobs (WARNING, SHAREDID, NOCODE, HANGASEXIT) still fail as
# required. THE COMPILER-POLICY EXCLUSION DOES NOT APPLY TO IT: the offline job is ubuntu-latest, so
# gcc is present; it checks out with `submodules: true`, so agent/ is there; and it materialises the
# pinned upstream/ro/qubes-windows-utils that this suite's -fsyntax-only checks read.
# 107 -> 108 on 2026-10-25: accept-logvol-smoke-selftest.sh ADDED - the campaign now smoke-tests the
#   LOG VOLUME BIND before its eight cells, and this drives that wiring. Campaign 40134888669
#   aborted 11 minutes into its first cell on a volume the guest could not see, having spent 10 of
#   them installing, and every preparation gate written afterwards checks around that bind rather
#   than the bind. The suite executes the code between release-acceptance's RASMOKE markers against
#   a stubbed smoke test and asserts the refutation arm runs FIRST, that EITHER arm failing stops
#   the campaign before the matrix, that rc 2 is reported as the RIG and not the bind, and that the
#   artefacts stay out of record-acceptance's *.out glob. 10 checks.
# 101 -> 102 on 2026-10-23: decode-dedup-selftest.sh ADDED - one logical file pulled TWICE is not two
#   files. The union collector (Get-LswLogDirCandidates) pulls a file present in two candidate
#   LogDirs twice, and decode kept both, so every line counted twice: measured on the first
#   supervision-gate guest run, 21 of 88 files duplicated, agent_instances 6 for 5 real instances
#   and agent_instances_per_boot 2 against max 1 - a P2 breach and cell L2 FAIL on a healthy guest.
#   13 checks, two mutations seen to fail.
# 100 -> 101 on 2026-10-23: build-attribution-selftest.sh ADDED - the BIRTH CUTOFF. It proves that
#   the entry fixture's lines are excluded even when its module declares one version, that our own
#   installer's ERRORs (0.0.0.0, pre-anchor) are NOT excluded, that a stock component's version
#   does not make its lines unattributable, and that a capture holding nothing the candidate wrote
#   FAILS. Four mutations, each seen to fail. Measured cause: 396 ERROR lines across the 195
#   captures on this rig were hidden as prior-build, 12 of them our installer's per upgrade cell.
# 76 -> 77 on 2026-10-21: assert-payload-floor-selftest.sh ADDED. The harness audit measured
# tools/assert-payload.sh printing `PASS: payload verified - 0 files` over an empty SHA256SUMS.txt:
# the integrity loop ran zero iterations and all three consumers branch only on the exit code, so
# a campaign would install and grade a payload nothing had hashed.
# 77 -> 78 on 2026-10-21: accept-clean-wu-selftest.sh ADDED. accept-clean.sh disabled Windows
# Update with `|| true` and never read the result, while matrix.sh never sets ACCEPT_MODE - so
# EVERY cell took that branch and a failed disable left the cell graded as a clean "our package
# only" measurement with WU live. The posture is now read back and a failed disable calls fail().
# 78 -> 79 on 2026-10-21: dom0-callers-count-selftest.sh ADDED. The Start-menu check tested
# `entries >= 10` against a clean Windows that reports ~37, so a menu amputated to a third read
# as aligned. The count now has to AGREE across cells of one OS family, which are clones of the
# same sealed golden - a predicate with no invented number in it.
# 79 -> 80 on 2026-10-21: ctl-stop-rc-selftest.sh ADDED. ctl_stop's last command was its printf,
# so "not-ours" and "STILL-RUNNING" exited 0 - the same as a confirmed stop - and matrix.sh only
# printed the string. A control window that failed to close stayed on the desktop to be counted
# by the window-map grading later in the same cell.
# 80 -> 81 on 2026-10-21: accept-cancel-selftest.sh ADDED. ACCEPTCANCELORPHAN root-caused:
# release-acceptance.sh never sourced run-lib.sh and never called job_init, so a SIGTERM to the
# leader exited the driver and left matrix.sh holding the rig - three cancels did exactly that.
# 81 -> 82 on 2026-10-21: seal-halted-selftest.sh ADDED. seal-qwt-golden.sh was the only consumer
# of qwt_shutdown that trusted its exit code without re-reading the state, so a guest still
# Running after a successful-looking shutdown would have been SEALED - freezing whatever it was
# doing into every clone taken from that golden.
# 82 -> 83 on 2026-10-21: answer-labconfig-selftest.sh ADDED. build-answer-stick.sh guarded a
# Windows 11 stick with `grep -q LabConfig`, so an answer file that only MENTIONS the word
# passed and Setup failed 0x800700FF - 0x40030 four minutes in. The four bypass keys a Xen HVM
# needs are asserted by name instead.
# 83 -> 84 on 2026-10-21: firstboot-effects-selftest.sh ADDED. guest/firstboot-setup.ps1 printed
# "OK - REBOOT REQUIRED" unconditionally with ErrorActionPreference=Continue and no checks, so a
# failed `bcdedit /set testsigning on` left a setup log identical to a good one - and nothing
# else in the tracked harness asserts testsigning, while the IDD driver is test-signed.
# 84 -> 85 on 2026-10-21: offline-rigshim-selftest.sh ADDED. Two suites in this very list were
# firing ~50 DENIED admin calls per estate run at qubes that do not exist - specimen-mark-reachable
# at `somevm` through `timeout 20 qrexec-client-vm`, dom0-callers at `fixture-vm` through
# `qvm-ls --raw-data --fields STATE` - and every one was written to the owner's dom0 journal. Both
# suites were green on every assertion they make, and nothing here could see it, because the calls
# are not a suite's output. The runner now shims 23 rig commands onto PATH ahead of each suite and
# reports any suite that reaches one as RED; this suite drives that guard, including the case a
# shell function cannot stub.
# 96 -> 97 on 2026-10-22: wedge-gates-selftest.sh ADDED. A guest wedged on the post-install second
# boot of a campaign cell; matrix.sh FATALed and aborted itself, release-acceptance.sh ran the
# feature tests anyway, the subject was killed at 600s with NOTHING captured, and no record was
# produced - although collect-failure.sh, wedge-lib.sh, fetch-wedge-core.sh, wedge-hunt.sh and
# verdict-jev.py all existed and none was invoked. The same day a guest that merely LOOKED wedged
# answered qrexec rc=0 and halted cleanly. mgmt/harness/wedge-gates-lib.sh is one classifier for
# both - owner's definition: present, no pixels at all, and ACPI ignored, as distinct from "has a
# qrexec queue and restarts rapidly". This suite drives all 15 classes offline, the two REAL
# specimens among them, proves stage 1 is a pure function, refuses a kill until the record is
# complete, and ASSERTS THE WIRING - because unwired machinery is the defect, not the fix.
# 95 -> 96 on 2026-10-22: campaign-full-selftest.sh ADDED. acceptance-plan.py plans THREE cells and
# campaign-run.sh mechanised only the middle one, so the other two were run BY HAND - and both hand
# steps went wrong in a way that read as success: two release-package runs at the same commit have
# IDENTICAL display titles, so the roles were taken from dispatch order (and a grep for QGAFAULT in
# the shipped binary returned 0 on both, which reads as "the flag did nothing"); and the required
# workflows that run on push-to-main only had to be dispatched by hand, twice. mgmt/harness/
# campaign-full.sh now owns the whole chain, and this suite drives the only two things it decides
# for itself, with an order-trusting resolver as the seen-to-fail control and the REAL ci-state
# refusal text as the fixture.
# 94 -> 95 on 2026-10-22: qrexec-gap-witness-selftest.sh ADDED. quick-upgrade.sh told a run that
# "the log volume could not be read either (no volume attached, or mtools found nothing)" while the
# same pull had just recovered 120 files and returned 0 - because the predicate read only the SINGLE
# newest *.log and that file was one the MSI had just created and not yet written to. The false
# [ERROR] then failed the run's own sweep gate, rc=3 over an install that passed 11 of 11 checks.
# The fix walks newest-first until a line is found; this suite runs the SHIPPED predicate over the
# tree that defeated the old one, keeps the [ERROR] branch reachable for a volume that really yields
# nothing, and its control is the old one-file form, which must come back empty on that same tree.
# 93 -> 94 on 2026-10-22: updater-component-selftest.sh ADDED. The relay defect was found by a HAND
# sequence (owner: "it is mostly what you do now by hand but systemic, verified and repeatable"), and
# the release gate that should have caught it - template-update-test.sh - contains NO relay assertion
# at all: it grades the update ROUND outcome, so a relay that was never built surfaced as an update
# symptom and was attributed elsewhere four times. mgmt/harness/updater-component-test.sh is the
# per-component split over GWeck's German golden; this suite drives its seven gates offline against
# the REAL captures of that day - the pre-fix pair must FAIL and each gate must fail alone.
# 92 -> 93 on 2026-10-22: discarded-scriptblock-selftest.sh ADDED. The relay defect above was a bare
# `{ ... }` statement - a ScriptBlock LITERAL, built and discarded, never executed - so the deploy
# logged success while the exe on disk stayed the one built 2026-09-16. The source text was CORRECT,
# which is exactly why every offline leg and every Jev score passed it. This is an AST check over the
# shipped PowerShell (303 files) whose control is the real shipped shape: an earlier draft reported
# every file clean while unable to detect it at all.
# 91 -> 92 on 2026-10-22: relay-vouch-selftest.sh ADDED. The updater deploy reported success over a
# relay built from a STALE staged source: three template-update rounds bound the pass's own pid as the
# listen port and nothing served 8082, so every pass went silent - and 87e3a746 had been reported as
# the fix on offline legs alone. The deploy now vouches the SOURCE it compiles, vouches the PLACED exe
# by its UTF-16 marker, and ends stale relays BY IMAGE PATH rather than by the port they hold.
# 90 -> 91 on 2026-10-22: upd-task-prestop-selftest.sh ADDED. The MSI's Restart Manager reaped our
# own running update scan and the death reporter told the USER the scan had failed (P1,
# dom0_loud_failures=2). The installer now ENDS those tasks before msiexec, so the result is
# 267014/0x41306 which the reporter already ignores - a declaration instead of an inference, and no
# reporter change. The suite runs the shipped region with schtasks as a recorder.
# 89 -> 90 on 2026-10-22: stick-scope-restore-selftest.sh ADDED, for the owner's two rulings - the
# evidence stick is for INSTALL testing, so appvm cells bind nothing, and the registry is handed
# back after an install so no park, clone or derived AppVM inherits a path to a removable volume.
# It extracts the class decision, the restore and four cells from the shipped matrix.sh and RUNS
# them with the stick primitives as recorders; the controls mutate the real file and were seen to
# turn it red.
# 88 -> 89 on 2026-10-22: accept-attempt-boundary-selftest.sh ADDED - the OTHER half of the same
# defect, which the 88 fix did not cover and which I had called done. release-acceptance.sh appends
# the matrix's stdout to $CAMP/full.out, one level above the dir matrix.sh stamps, so that file held
# two attempts' footers - and it is the file `matrix rc=` points a reader at. It is ROTATED rather
# than stamped because record-acceptance.sh requires ONE footer per *.out and a separator inside
# the file would not restore that; the kept copy is renamed out of the glob.
# 87 -> 88 on 2026-10-22: matrix-attempt-boundary-selftest.sh ADDED. matrix.sh derives its work
# dir from the release-package run id and opens per-cell artefacts with `>>`, so two attempts
# against one package wrote into the same files with no separator - and the mtime belongs to the
# newest line. WIN10-clean-logvol-bind.out held an aborted attempt's `fail` and a later
# attempt's `ok` together; read three times that night, it produced a live campaign reported as
# aborted and then an invented retry to reconcile the lines. Each attempt now stamps the
# artefacts it inherits, nothing is deleted, and the suite asserts ATTRIBUTABILITY by attributing
# lines the way a reader does, with the stamp removed as its control.
# 87 since 2026-10-22: the two qrexec-wrapper exit suites joined the list. wrapper-exit-emit is new -
# it compiles and runs the exit chain, which is what the brace defect needed - and
# wrapper-exit-reason was already written but excluded for needing submodule git history, which is
# how its red went unread for days.
# 98 -> 99 on 2026-10-23: ttfw-ab-selftest.sh ADDED with the harness it checks. ttfw-ab.sh produces
# the headline number for a user-visible latency (time to first window), so it is an instrument, and
# the shapes whose absence would make its number MEANINGLESS rather than slightly wrong are the ones
# asserted: the running binary's hash verified before any timing, the tag asserted in preflight and
# the capture service's exit status read on every poll (an empty per-window tar has three causes, two
# of which look exactly like "no window yet"), interleaving with an alternating start side, a smoke
# sweep over a single-build window gating the exit code, and IMPROVED claimed only on disjoint ranges.
# 99 -> 100 on 2026-10-23: init-record-consumers-selftest.sh ADDED. The LogInit banner's demotion to
# LogDebug removed `process ID: N` from every shipped log, and SIX readers key on it to answer "which
# lines are THIS instance's" - the sanctioned agent restart (which then cannot prove a turnover, so
# the kill-by-name it exists to prevent is all that is left), two harnesses that SCOPE a count with it
# and therefore counted the whole file instead, and an acceptance gate that emits INITLINE 0 and
# exits. One severity edit, six readers, every failure silent or inverted. The suite asserts each
# consumer accepts the shipped QWTBIRTH form, skipping comments (all six now explain the demotion in
# prose a whole-file check would pass on), and drives the restart parser against a line a 4.3.37
# guest actually wrote, with the branch removed to prove it reads 0 without it.
FLOOR=${OFFLINE_SUITES_FLOOR:-108}
# Each suite's own temp files: /tmp is a 1 GB tmpfs on the dev qube and 40 suites' fixtures do not
# belong in RAM. On a CI runner TMPDIR is already real disk, so this only ever makes it safer.
export TMPDIR="${TMPDIR_OVERRIDE:-${RUNNER_TEMP:-/home/user/tmp}}"
mkdir -p "$TMPDIR" 2>/dev/null

# DEPTH GUARD. offline-runner-selftest.sh is itself in the list and it RUNS this script against a
# fixture list, so the nesting is one deep by construction - but a self-test that re-entered its own
# producer once fork-bombed this qube, and the fix then was a depth guard. One level, no exceptions.
if [ "${OFFLINE_SUITES_DEPTH:-0}" -ge 1 ]; then
  echo "ERROR: run-offline-suites.sh re-entered itself (depth ${OFFLINE_SUITES_DEPTH}) - a suite must not run the whole suite"
  exit 2
fi
export OFFLINE_SUITES_DEPTH=$(( ${OFFLINE_SUITES_DEPTH:-0} + 1 ))

[ -r "$LIST" ] || { echo "ERROR: $LIST is missing - the curated list IS the gate"; exit 2; }
mapfile -t suites < <(sed 's/#.*//' "$LIST" | awk 'NF')
n=${#suites[@]}
if [ "$n" -lt "$FLOOR" ]; then
  echo "ERROR: $LIST names $n suite(s), floor is $FLOOR - the list shrank; move the floor in a commit or restore the suites"
  exit 2
fi
echo "--- $n offline suite(s), serially (floor $FLOOR, TMPDIR $TMPDIR)"

# OFFLINE MEANS IT DOES NOT TOUCH THE RIG, AND UNTIL NOW THAT WAS ONLY THE WORD IN THE FILENAME.
# specimen-mark-reachable-selftest.sh drove w_session against a guest it called `somevm`; w_session
# samples cpu with `timeout 20 qrexec-client-vm "$vm" admin.vm.Stats`, so every single run fired 24
# admin calls at a qube that does not exist. Each one is DENIED, and a denied Admin API call is
# written to the OWNER'S dom0 journal - he asked what they were, 2026-10-21. The suite was green
# throughout: nothing it asserted could see the calls, because the calls are not its output.
# So the property gets a predicate. Every suite runs with a shim dir FIRST on PATH; any rig command
# it reaches is recorded and exits 1 - which is what a denial already gave it - and a suite that
# reached one is RED whatever its exit code was. A suite that genuinely needs the rig is not an
# offline suite and does not belong in this list.
# It must be a stub on PATH and not a shell function: `timeout`, `env`, `xargs`, `nohup` and
# `find -exec` all EXEC their argument, so a function is never in the path to be found. That was
# my first fix and the call count did not move.
# OFFLINE-RIGSHIM-A  (to the B marker: driven by tools/tests/offline-rigshim-selftest.sh;
# neither marker names the other)
RIGSHIM="$TMPDIR/.offline-rig-shim.$$"
RIGCALLS="$TMPDIR/.offline-rig-calls.$$"
mkdir -p "$RIGSHIM" || { echo "ERROR: cannot create the rig shim dir - refusing to run unguarded"; exit 2; }
for _c in qrexec-client-vm qrexec-client \
          qvm-ls qvm-tags qvm-run qvm-start qvm-shutdown qvm-kill qvm-pause qvm-unpause \
          qvm-prefs qvm-features qvm-volume qvm-device qvm-remove qvm-clone qvm-create \
          qvm-check qvm-copy-to-vm qvm-move-to-vm qvm-console-dispvm qvm-firewall qubes-prefs; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "${OFFLINE_RIG_CALLS:-/dev/null}"\nexit 1\n' \
    "$_c" > "$RIGSHIM/$_c" || { echo "ERROR: cannot write the rig shim - refusing to run unguarded"; exit 2; }
  chmod +x "$RIGSHIM/$_c"
done
trap 'rm -rf "$RIGSHIM" "$RIGCALLS"' EXIT
# OFFLINE-RIGSHIM-B

red=0; green=0; empty=0; total_assertions=0; touched=0
for s in "${suites[@]}"; do
  f="$SUITEDIR/$s"
  if [ ! -x "$f" ] && [ ! -r "$f" ]; then
    printf 'MISSING  %-52s named in the list, not in the tree\n' "$s"; red=$((red+1)); continue
  fi
  : > "$RIGCALLS"
  out=$(OFFLINE_RIG_CALLS="$RIGCALLS" PATH="$RIGSHIM:$PATH" timeout 300 bash "$f" 2>&1); rc=$?
  # A run that reports NO assertion at all has been gutted, whatever its exit code - that is exactly
  # how a deduped RESULT line turned a suite into a no-op. Two spellings count, because both are in
  # use here: a tally ("N passed", "N check(s)") and a bare verdict line. The defect-knob suites
  # print their planted failures as FAIL lines and end with one PASS, so counting only tallies
  # called four green suites empty.
  passed=$(printf '%s' "$out" | command grep -oaE '[0-9]+ (passed|check\(s\))' | command grep -oaE '^[0-9]+' | tail -1)
  : "${passed:=0}"
  if [ "$passed" -eq 0 ]; then
    passed=$(printf '%s' "$out" | command grep -caE '^[[:space:]]*(PASS|ok)[[:space:]]|^RESULT: PASS')
    : "${passed:=0}"
  fi
  total_assertions=$((total_assertions + passed))
  if [ -s "$RIGCALLS" ]; then
    # RED WHATEVER THE EXIT CODE WAS: the suite passed its own assertions and still reached the rig.
    printf 'TOUCHED-RIG %-49s %s call(s) to the rig from an OFFLINE suite\n' "$s" "$(wc -l < "$RIGCALLS")"
    sort -u "$RIGCALLS" | sed 's/^/           /' | head -4
    red=$((red+1)); touched=$((touched+1))
  elif [ "$rc" -ne 0 ]; then
    printf 'FAIL     %-52s rc=%s  %s\n' "$s" "$rc" "$(printf '%s' "$out" | tail -1 | cut -c1-80)"
    printf '%s\n' "$out" | command grep -aiE '^\s*(FAIL|BROKE|ERROR)' | sed 's/^/           /' | head -6
    red=$((red+1))
  elif [ "$passed" -eq 0 ]; then
    printf 'EMPTY    %-52s exited 0 and reported no assertions\n' "$s"
    empty=$((empty+1))
  else
    printf 'ok       %-52s %s assertion(s)\n' "$s" "$passed"
    green=$((green+1))
  fi
done

echo "--- $green green, $red red, $empty reporting nothing; $total_assertions assertions over $n suite(s)"
if [ "$red" -gt 0 ] || [ "$empty" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
