#!/bin/bash
# wu-e2e.sh - drive REPEATED full Windows Update passes on a guest and judge every one.
#
#   mgmt/harness/wu-e2e.sh <vm> [rounds] [outdir]
#
# WHY THIS EXISTS. The register's bar for the GWeck update path is explicit: DONE requires either
# repeated full passes on the German 25H2 template that complete without a stall, or the stall
# found and fixed. Every previous run of that kind was ad-hoc - driven by hand, judged by reading
# logs - which is exactly why "tested end to end" kept not sticking. This is the repeatable form.
#
# HOW A PASS IS DRIVEN: tools/replay-dom0-update.py, which replays dom0's OWN qubes-vm-update
# command sequence over the same qrexec services dom0 uses (qubes.VMExec for commands,
# qubes.VMShell for the agent tarball) - i.e. the Qube Manager path, not a shortcut that calls the
# updater directly. dom0's contract: exit 0 = success, 100 = no updates, anything else = error.
#
# WHAT IS JUDGED, per round, by code and by Jev rather than by eye:
#   * dom0's updates-available BEFORE and AFTER, so a pass that leaves dom0 stale is caught. This
#     is the field failure the whole line exists for: the guest throws, never reports, and dom0
#     keeps the previous number while Qube Manager shows the qube as up to date.
#   * the guest's own updater log - its per-day files in the one log directory since 2026-11-01, plus the
#     cumulative wu\agent.log of an image from before the move - cut to what the round appended (wu_slice),
#     through tools/wu-pass-judge.py --dom0-reported <after>, which
#     FAILS on a SILENT pass (errored and never reported) and on a guest/dom0 disagreement.
#   * update-status.json, kept as evidence for each round.
#
# STALL DETECTION IS PART OF THE TEST, not a nuisance: the open P1 wedge (two vCPUs spinning on a
# held lock while two idle) presents as Running + qrexec dead + no windows, and it can kill a pass.
# A round that ends that way is recorded as STALLED and the run stops - a stalled guest must be
# interrogated, never silently restarted (see findings/issues.md).
#
# PASS LIVENESS IS PART OF THE TEST TOO: a pass that dies (its task no longer Running, its status frozen unfinished) is
# recorded as DEAD by the harness's own probe (mgmt/harness/wu-liveness.sh), never waited out - see the round loop.
#
# Exit 0 every round PASSED, 3 a round FAILED, STALLED or DEAD, 2 instrument error.
declare -F toolstack_accept >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh" 2>/dev/null || true   # toolstack_accept: the one recorded shutdown request
set -u

VM="${1:?[ERROR] usage: $0 <vm> [rounds] [outdir]}"
ROUNDS="${2:-3}"

# SERIAL, ALWAYS. This drives a guest for hours across reboots; a second job on the same guest
# would interleave its probes with these rounds and fabricate a verdict. Taking the lock is not
# optional here - tools/lint-harness.py refuses a harness that touches a guest without it, which
# is how this omission was caught before the first run rather than after a ruined campaign.
source mgmt/harness/vmlock.sh
vm_lock "$VM"
source mgmt/harness/wu-liveness.sh

OUT="${3:-scratchpad/wu-e2e-$VM-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
export QTEST_VM="$VM"
: "${QTEST_INCOMING:=C:\\Users\\gerd-test\\Documents\\QubesIncoming\\win-idd-mgmt}"
export QTEST_INCOMING

# EVERY LINE DECLARES ITS LEVEL, because an emitter that does not makes the sweep gate judge a
# FRACTION of the run and say so. MEASURED on the 4.3.36 campaign: this suite finished its product
# work cleanly - `DONE: rounds=3 fails=0 unjudged_exclusions=0` - and still failed the release, with
#     SWEEP-GATE-COVERAGE lines=32 with_declared_level=0 without=32 third_party=0
#     SWEEP-GATE-RESULT undeclared_ours=32 - this gate judged only part of the run, so its silence
#                                            means nothing
# so wu-e2e exited 5, template-update was classed INSTRUMENT ("could not measure the product" - it
# HAD measured it), and gate-scope then refused the cut over a required suite reported uncovered.
# The gate was right and honest; the 32 undeclared lines were ours. Same shape as quick-upgrade.sh's
# log(), including the leading-whitespace strip: the house style for a sub-step is `log "  [WARN] "`,
# and testing the token at position zero stamps those as INFO *and* WARN, declaring two levels.
log(){ _lv="$*"; _lv="${_lv#"${_lv%%[![:space:]]*}"}"
       case "$_lv" in
         "[ERROR]"*|"[WARN]"*|"[WARNING]"*|"[INFO]"*|"[DEBUG]"*) _m="$*" ;;
         *) _m="[INFO] $*" ;;
       esac
       echo "$(date -u +%H:%M:%S) wu-e2e[$VM]: $_m" | tee -a "$OUT/run.log"; }
# RETRY, and never let a failed CALL look like a STATE. `qvm-ls` can fail transiently (qubesd
# busy, a call racing a domain transition) and then this returned the empty string, which every
# caller reads as "not Halted" or "not Running" - so a shutdown loop, a reboot ledger and a stall
# test all take their verdict from a call that never answered. Jev flagged it no-retry 0.67-0.69
# with load_bearing 0.60-0.66 (tools/probe-review.py, 2026-09-21). Three attempts; if the toolstack
# still will not answer, say UNKNOWN out loud rather than returning something that reads as a state.
# TWO AGREEING READS, not one: re-judged after the first fix, Jev called a single successful
# sample single-sample 0.55 with load_bearing 0.68 - a state read that races a domain
# transition can return a value that was true for an instant and is not the state.
qstate(){ local i a b
  for i in 1 2 3; do
    a=$(timeout 30 qvm-ls --raw-data --fields state "$VM" 2>/dev/null | tr -d ' \r\n')
    b=$(timeout 30 qvm-ls --raw-data --fields state "$VM" 2>/dev/null | tr -d ' \r\n')
    [ -n "$a" ] && [ "$a" = "$b" ] && { printf '%s' "$a"; return 0; }
    sleep 3
  done
  printf 'UNKNOWN'; return 1; }
# THE NUMBER EVERY VERDICT RESTS ON. dom0's updates-available marker is what the whole bar is
# about, and an EMPTY answer here is indistinguishable from the marker legitimately being empty -
# which is the "up to date" verdict. A transient qvm-features failure would therefore manufacture a
# clean result, or a fake oscillation. Jev: no-retry 0.88, load_bearing 0.65, the worst of the ten
# probes reviewed. So: read it three times and require two reads to AGREE before believing either.
dom0_avail(){ local i a b
  for i in 1 2 3; do
    a=$(timeout 30 qvm-features "$VM" updates-available 2>/dev/null | tr -d ' \r\n')
    b=$(timeout 30 qvm-features "$VM" updates-available 2>/dev/null | tr -d ' \r\n')
    [ "$a" = "$b" ] && { printf '%s' "$a"; return 0; }
    sleep 2
  done
  log "[WARN] dom0's updates-available never read the same twice - reporting the last value '$a'"
  printf '%s' "$a"; }

guest_file(){  # $1 = windows path -> stdout, without the cmd banner
  # RETRY ON EMPTY. `type` fails outright when the guest holds the file open, and the updater
  # rewrites its status file constantly while a pass runs. Measured 2026-09-21 on win11de-ctlb: the
  # round-1 capture came back 0 BYTES, which made reboot_needed read 'unknown' and left the
  # oscillation check waiting the full 15 minutes for a scan it could not see - a whole run spent
  # failing on the harness's own inability to collect its evidence. An empty read is MISSING DATA,
  # and missing data gets retried before it is believed.
  local i out
  for i in 1 2 3 4 5 6; do
    out=$(timeout -k 5 180 tools/qtest run "cmd /c type \"$1\"" 2>/dev/null | tr -d '\r' \
      | sed -e '/^Microsoft Windows \[/d' -e '/^(c) Microsoft/d' -e '/^$/d' -e '/^C:\\Windows\\System32>/d')
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    sleep 5
  done
  return 1
}

# THE PASS'S OWN LOGS ARE PER-DAY FILES IN THE ONE LOG DIRECTORY since 2026-11-01 (docs/ADR-logging.md): the updater's
# qubes-windows-update.ps1-<d>.log, the relay's qubes-updates-relay-<d>.log, its handlers' relay-handler-<d>.log and the
# shim's vmupdate-shim.ps1-<d>.log, each named on the day its process starts - so one round can append to yesterday's
# file AND start today's. Before the move each was ONE cumulative file at a fixed path; an image from before the move
# still has them (an upgraded guest keeps them, frozen; an older updater still writes them), so every family is its
# per-day files plus its old path, below.
WU_OLD_LOGS=(
  'C:\ProgramData\Qubes\wu\agent.log'
  'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
  'C:\ProgramData\Qubes\wu\relay-handler.log'
  'C:\ProgramData\Qubes\vmupdate-shim.log'
)
# a guest path -> its family, which is also the round's file for it (nothing = not one of ours)
wu_family(){
  case "${1##*\\}" in
    qubes-windows-update.ps1-*.log|agent.log)               echo agent.log ;;
    qubes-updates-relay-*.log|qubes-updates-relay.log)      echo relay.log ;;
    relay-handler-*.log|relay-handler.log)                  echo relay-handler.log ;;
    vmupdate-shim.ps1-*.log|vmupdate-shim.log)              echo vmupdate-shim.log ;;
  esac; }
# THE ONE LOG DIRECTORY, by log.c's rule: the registry LogDir, else <SystemDrive>\Qubes Logs - read through
# guest_file's own transport. QWTSYSDRIVE proves the guest answered: without it an absent LogDir value and a guest
# that said nothing would read the same, and the default would stand in for an answer.
guest_logdir(){ local i out sd ld
  for i in 1 2 3 4 5 6; do
    out=$(timeout -k 5 180 tools/qtest run 'cmd /c reg query "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools" /v LogDir & echo QWTSYSDRIVE=%SystemDrive%' 2>/dev/null | tr -d '\r')
    sd=$(printf '%s\n' "$out" | sed -n 's/^QWTSYSDRIVE=\([A-Za-z]:\)[[:space:]]*$/\1/p' | tail -1)
    if [ -n "$sd" ]; then
      ld=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*LogDir[[:space:]][[:space:]]*REG_[A-Z_]*SZ[[:space:]][[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' | tail -1)
      printf '%s\n' "${ld:-$sd\\Qubes Logs}"; return 0
    fi
    sleep 5
  done
  return 1; }
# Every file of every family on the guest now, one path per line, the same transport again. A wildcard item yields
# only the files that exist; an old path is checked with `if exist`. QWTLISTEND proves the listing RAN: an empty
# answer is a guest that did not answer, never "no files" - a before-snapshot taken from nothing would hand the judge
# the image's whole history again.
guest_logs(){ local ld="$1" i out set p
  set="\"$ld\\qubes-windows-update.ps1-*.log\" \"$ld\\qubes-updates-relay-*.log\" \"$ld\\relay-handler-*.log\" \"$ld\\vmupdate-shim.ps1-*.log\""
  for p in "${WU_OLD_LOGS[@]}"; do set="$set \"$p\""; done
  for i in 1 2 3 4 5 6; do
    out=$(timeout -k 5 180 tools/qtest run "cmd /c for %g in ($set) do @if exist \"%~g\" echo QWTLOG=%~g& echo QWTLISTEND" 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$out" | grep -qx 'QWTLISTEND'; then printf '%s\n' "$out" | sed -n 's/^QWTLOG=//p'; return 0; fi
    sleep 5
  done
  return 1; }
# The order a family is read in: its old path first - anything there was written before the move - then the per-day
# files by name, which is their date order.
wu_order(){ local p o op
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    o=1; for op in "${WU_OLD_LOGS[@]}"; do [ "$p" = "$op" ] && o=0; done
    printf '%s\t%s\t%s\n' "$o" "${p##*\\}" "$p"
  done | sort -t "$(printf '\t')" -k1,1 -k2,2 | cut -f3-; }
# wu_snapshot <tsv>: BEFORE the pass, the line count of every file of every family ("<count><TAB><path>"), counted
# by guest_file exactly as wu_slice counts it afterwards. Fails if the guest cannot be listed or a listed file read.
wu_snapshot(){ local tsv="$1" ld list p body
  : > "$tsv"
  ld=$(guest_logdir) || return 1
  list=$(guest_logs "$ld") || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    body=$(guest_file "$p") || return 1
    printf '%s\t%s\n' "$(printf '%s\n' "$body" | wc -l)" "$p" >> "$tsv"
  done < <(printf '%s\n' "$list" | wu_order)
  return 0; }
# wu_slice <rd> <tsv>: AFTER the pass, what the round appended to each family, into <rd>/<family file>: each file's
# lines past its snapshot count, and the whole of a file the snapshot does not hold (it is new this round).
# <rd>/guestlogs.tsv records every file's counts, so a slice can be checked against what was on the guest.
# Returns 1 when the guest cannot be listed, 2 when a listed file cannot be read (UNREAD in guestlogs.tsv): a read that
# failed is missing data, never a file that shrank or a new file with no lines.
wu_slice(){ local rd="$1" tsv="$2" ld list p fam pre body n bad=0
  : > "$rd/agent.log"; : > "$rd/relay.log"; : > "$rd/relay-handler.log"; : > "$rd/vmupdate-shim.log"
  printf 'file\tbefore\tafter\tthis_round\tguest_path\n' > "$rd/guestlogs.tsv"
  ld=$(guest_logdir) || return 1
  list=$(guest_logs "$ld") || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    fam=$(wu_family "$p"); [ -n "$fam" ] || continue
    # ENVIRON, not -v: awk processes backslash escapes in a -v value, so a Windows path never equalled its own row.
    pre=$(P="$p" awk -F'\t' '$2 == ENVIRON["P"] { print $1; exit }' "$tsv" 2>/dev/null)
    if ! body=$(guest_file "$p"); then
      log "[ERROR] round $r: INSTRUMENT - $p could not be read after the pass - not sliced"
      printf '%s\t%s\t-\tUNREAD\t%s\n' "$fam" "${pre:--}" "$p" >> "$rd/guestlogs.tsv"
      bad=1; continue
    fi
    n=0; [ -n "$body" ] && n=$(printf '%s\n' "$body" | wc -l)
    if [ -z "$pre" ]; then
      [ -n "$body" ] && printf '%s\n' "$body" >> "$rd/$fam"
      printf '%s\t-\t%s\t%s\t%s\n' "$fam" "$n" "$n" "$p" >> "$rd/guestlogs.tsv"
    elif [ "$n" -lt "$pre" ]; then
      # These files are append-only: one that SHRANK was replaced or truncated under the pass, and its tail would be
      # some other file's lines. Said, and left out of the slice.
      log "[WARN] round $r: $p had $pre line(s) before the pass and $n after - not sliced"
      printf '%s\t%s\t%s\tSHRANK\t%s\n' "$fam" "$pre" "$n" "$p" >> "$rd/guestlogs.tsv"
    else
      [ "$n" -gt "$pre" ] && printf '%s\n' "$body" | tail -n +$((pre + 1)) >> "$rd/$fam"
      printf '%s\t%s\t%s\t%s\t%s\n' "$fam" "$pre" "$n" "$((n - pre))" "$p" >> "$rd/guestlogs.tsv"
    fi
  done < <(printf '%s\n' "$list" | wu_order)
  [ "$bad" = 0 ] || return 2
  return 0; }

# STABLY up, not just up. A single successful probe proves the agent answered ONCE. Measured
# 2026-09-21 on win11de-ctld: 60 s after a reboot that applied a cumulative, one probe succeeded -
# so the reboot counted and the next pass was driven - and that pass then got rc=46 on nearly every
# step, because the agent was still coming and going while Windows finished its boot-time
# servicing. The harness refused to call it a result, correctly, but it should never have driven a
# pass into a booting guest. Three consecutive answers, and any failure resets the count.
wait_qrexec(){ local d=$(( $(date +%s) + ${1:-900} )) ok=0
  while [ "$(date +%s)" -lt "$d" ]; do
    o=$(timeout -k 5 45 tools/qtest run "cmd /c echo UP" 2>/dev/null | tr -d '\r\n')
    case "$o" in
      *UP*) ok=$((ok+1)); [ "$ok" -ge 3 ] && return 0; sleep 15; continue;;
      *)    [ "$ok" -gt 0 ] && log "qrexec answered $ok time(s) then stopped - the guest is not settled yet"; ok=0;;
    esac
    [ "$(qstate)" = Halted ] && return 1
    sleep 15
  done; return 2; }

# A guest that is Running but answers nothing is the P1 stall signature, not a slow guest.
stalled(){ [ "$(qstate)" != Halted ] && ! wait_qrexec 120; }

[ -x tools/wu-pass-judge.py ] || { echo "INSTRUMENT: tools/wu-pass-judge.py missing"; exit 2; }
[ -f tools/replay-dom0-update.py ] || { echo "INSTRUMENT: tools/replay-dom0-update.py missing"; exit 2; }

# PREFLIGHT: the updates proxy. The check and every reason for its shape now live in ONE place,
# primitives.sh's updates_proxy_ok - this file held the only full copy, template-update-test.sh held
# a listen-only one that could pass over a proxy reaching nothing, and the campaign preflight that
# runs before every suite had neither. The primitive starts it when nothing listens, proves egress
# with three attempts because the first request after an idle period regularly returns nothing, and
# leaves it standing. This caller's verdict is unchanged: INSTRUMENT, exit 2.
source mgmt/harness/primitives.sh
updates_proxy_ok || { echo "INSTRUMENT: the updates proxy cannot carry this run (updates_proxy_ok rc=$?) - a run now would blame the guest for a network failure"; exit 2; }
log "updates proxy OK (egress proven, http=$UPDATES_PROXY_HTTP)"

fails=0
# REBOOT ACCOUNTING (owner, 2026-09-20: "there should be no forced reboots in 'hope to settle'.
# amount of reboots performed must match amount of reboots requested").
# A harness that reboots speculatively is unfalsifiable - reboot often enough and something
# settles - and every state that needed an unrequested reboot is a defect it just hid. So every
# power cycle here must trace to a REQUEST: either the guest powered itself off (an /auto stage
# transition, which IS the guest asking), or update-status.json said reboot_needed=true. The two
# counters are compared at the end and a mismatch FAILS the run.
reboots_requested=0
reboots_performed=0
note_request(){ reboots_requested=$((reboots_requested+1)); log "REBOOT REQUESTED (#$reboots_requested): $*"; }
note_performed(){ reboots_performed=$((reboots_performed+1)); log "reboot performed (#$reboots_performed)"; }
# The round directory whose after-pass OFFERS read is still owed - set by a round whose pass scheduled its own restart (see the
# after-pass facts below), taken at the next round's start, or after the loop for the last round.
offers_owed=""

for r in $(seq 1 "$ROUNDS"); do
  RD="$OUT/round$r"; mkdir -p "$RD"
  # Rounds are independent passes, not a burst. Fired back to back they hammer qrexec - measured
  # 2026-09-20, round 3 started 5 s after round 2 and EVERY replay step came back rc=46, i.e. no
  # pass ran at all. This is a settle between independent passes, not a timeout standing in for a
  # fix: nothing in the field runs two update passes five seconds apart.
  if [ "$r" -gt 1 ]; then log "settling ${SETTLE:-60}s before round $r"; sleep "${SETTLE:-60}"; fi
  before=$(dom0_avail); log "round $r: dom0 updates-available BEFORE='${before:-<empty>}'"

  if ! wait_qrexec 900; then
    if stalled; then log "round $r: STALLED (Running, qrexec dead) - stopping, the guest must be interrogated"; fails=1; break; fi
    # The guest powered ITSELF off - that is the guest requesting the cycle, not us forcing one.
    note_request "the guest powered itself off before round $r"
    log "round $r: guest is Halted - starting it"
    timeout 240 qvm-start "$VM" >/dev/null 2>&1
    note_performed
    wait_qrexec 900 || { log "round $r: guest never came up"; fails=1; break; }
  fi

  # INDEPENDENT FACTS FOR THE EXCLUSION AUDIT, at both ends of every pass (Jev 0.88, 2026-10-03). The audit judges an item in the
  # round that EXCLUDED it, so the artefacts that item changes are measured by the harness - not the updater - before and after that
  # very pass. One read after the whole run cannot speak for an earlier round: in rz35 KB2267602 was excluded as already current in
  # round 2 and its signatures moved again in round 3. Evidence only, never a round verdict: an incomplete read is logged here and
  # refused by tools/wu-exclusion-evidence.py when an excluded round needs it (missing data fails).
  mgmt/harness/wu-evidence-facts.sh "$VM" "$RD/facts-before.txt" > "$RD/facts-before.out" 2>&1 \
    || log "round $r: facts before the pass INCOMPLETE - $(tail -1 "$RD/facts-before.out" | cut -c1-160)"
  # THE OFFERS READ THE PREVIOUS ROUND OWES (it scheduled a restart - see the after-pass facts below), taken HERE: after the
  # settle, the qrexec wait and the self-power-off handling above, where build 4.3.41.1272's template-update round 3 then ran
  # undisturbed - not straight after the cycle, where that run's guest powered itself off once more for servicing completion.
  # Appended to THAT round's facts, the round the exclusion audit judges it for.
  if [ -n "$offers_owed" ]; then
    mgmt/harness/wu-evidence-facts.sh "$VM" "$offers_owed/facts-after.txt" offers-only >> "$offers_owed/facts-after.out" 2>&1
    log "round $r: the offers read ${offers_owed##*/} owed: $(tail -1 "$offers_owed/facts-after.out" | cut -c1-160)"
    offers_owed=""
  fi

  # The old agent.log was CUMULATIVE - it carries every pass this image has ever run, including the
  # golden's history - and a per-day file carries every pass of its day. Judging whole files each
  # round re-judges the past and lets an old pass decide this round's verdict. Snapshot every file
  # BEFORE, and judge only what this round appended (wu_slice, after the pass).
  pre_ok=1
  if ! wu_snapshot "$RD/guestlogs-before.tsv"; then
    pre_ok=0
    log "[ERROR] round $r: INSTRUMENT - the guest's update logs could not be listed or read before the pass, so this round's lines cannot be told from earlier passes'"
  fi
  # ...and `satisfied` in update-status.json is cumulative for the SAME reason, deliberately:
  # guest/qubes-windows-update.ps1 GUARD:offeridentity carries the previous pass's list forward
  # ($script:St.satisfied = @($priorSat)) so a scan stops re-raising dom0 for a package it proved
  # installed thirty seconds earlier. It is an accumulator over the image's whole life, golden
  # included. The oscillation verdict below needs "what THIS pass resolved", which is the DELTA -
  # feeding it the accumulator reports every identity the golden ever resolved as an oscillation.
  guest_file 'C:\ProgramData\Qubes\update-status.json' > "$RD/update-status-before.json"

  log "round $r: driving a pass the Qube Manager way (replay-dom0-update.py --with-entrypoint)"
  # A FIRST PASS ON AN UN-UPDATED TEMPLATE IS NOT AN HOUR'S WORK. Measured 2026-09-21 on
  # win11de-ctld: this returned rc=124 - killed, not finished - while the guest was still
  # installing a 4.4 GB cumulative it had already downloaded. The guest-side task survives the
  # kill, so the harness then graded a pass that was still running and ran its oscillation scan
  # against a busy guest, where the updater's mutex makes a scan exit at once. Default raised,
  # and overridable per run.
  #
  # PASS LIVENESS, independent of the product (mgmt/harness/wu-liveness.sh). Measured 2026-09-17: a pass the Task Scheduler
  # ended 90 s in left this wait tailing a corpse for its full bound, because nothing here looked at the pass itself. The
  # product's handler now reports a dead pass on its own, but the harness must not need the product's detector to see the
  # product fail - so while the replay runs, the guest's update task and status file are probed, and a pass that is not Running
  # while its status has stood still, unfinished, for WU_LIVE_HOLD_S ends the round as DEAD. The guest is left exactly as it
  # is, to be interrogated, like a stall.
  timeout -k 20 "${WU_REPLAY_TIMEOUT:-10800}" python3 -u tools/replay-dom0-update.py "$VM" --with-entrypoint \
      > "$RD/replay.out" 2>&1 &
  rpid=$!
  # A probe that gets NO answer is missing data, never a verdict - but three in a row while the replay still runs is how the P1
  # stall looks from here (Running, qrexec dead), and the replay's own step bound would sit it out for an hour. So the stall test
  # runs then, and a stalled guest ends the round at once - a stall is examined WHILE it is live, before anything kills it.
  wu_live_reset; dead=""; noans=0; stall=0
  while kill -0 "$rpid" 2>/dev/null; do
    sleep 30
    kill -0 "$rpid" 2>/dev/null || break
    grep -q '\[entrypoint\] running' "$RD/replay.out" || continue   # not before the pass exists
    pl=$(wu_probe)
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "${pl:-<no answer>}" >> "$RD/liveness.txt"
    if [ -z "$pl" ]; then
      noans=$((noans+1))
      if [ "$noans" -ge 3 ] && stalled; then stall=1; break; fi
      continue
    fi
    noans=0
    if wu_pass_dead "$pl"; then dead=$WU_LIVE_WHY; break; fi
  done
  if [ "$stall" = 1 ]; then
    log "round $r: STALLED during the pass (Running, qrexec dead) - the host replay is stopped; INTERROGATE the guest now (tools/qtest wedge), never restart it"
    wu_killtree "$rpid"; wait "$rpid" 2>/dev/null
    fails=1; break
  fi
  if [ -n "$dead" ]; then
    log "round $r: PASS DEAD (harness liveness, not the product's own report): $dead"
    wu_killtree "$rpid"; wait "$rpid" 2>/dev/null
    log "round $r: the host replay was stopped; the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  wait "$rpid"; rc=$?
  # ...and a pass the PRODUCT reported dead is just as dead. The handler's own verdict (guest/wu-update.ps1 GUARD:deadpass) ends
  # the replay with rc=1 - which the replay counts as an expected protocol outcome ("a KB failed") - long before the probe's hold
  # can elapse, so without this the round went on to judge and scan a guest whose pass had died (Jev review 2026-10-02: a likely
  # miss, 0.68).
  if grep -q 'update pass DIED' "$RD/replay.out"; then
    log "round $r: PASS DEAD (the product's own report): $(grep -m1 'update pass DIED' "$RD/replay.out" | sed 's/^ *err: //')"
    grep -m1 'leftovers:' "$RD/replay.out" | sed 's/^ *err: /    /' | tee -a "$OUT/run.log"
    log "round $r: the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  # A REFUSAL IS THE PRODUCT'S OWN REPORT TOO (2026-10-02, the owner's D3 decision). The updater refused to start - dom0 printed
  # "update refused by the qube: ..." - before it owned anything, typically over a pass cut off in this boot (QWTUPDSTATEUNKNOWN), and
  # requested a restart on that cut-off record. The record stays non-terminal ON PURPOSE, so the post-replay picture below would call
  # the round DEAD - measured on rz34: the round was cut short there, the requested restart never performed, the next round never run.
  # A refused round is not a pass (fails=1); it is judged REFUSED - no pass judge and no oscillation scan, no pass ran - and the
  # restart it requested is honoured below, so the next round tests what comes after it.
  refused=''
  if grep -q 'update refused by the qube:' "$RD/replay.out"; then
    refused=$(grep -m1 'update refused by the qube:' "$RD/replay.out" | sed 's/^ *err: //')
    log "[WARN] round $r: REFUSED by the qube (the product's own report): $(printf '%s' "$refused" | cut -c1-300)"
    fails=1
  fi
  # ...and a pass can also die with NO report: the replay ends (its own step bound, a handler that crashed) while the pass's last
  # picture is unfinished and its task no longer runs (Jev 2026-10-02, the second likeliest miss, 0.27). Nothing waits on the
  # pass once the replay has ended, so the picture is judged now, with no hold. A guest that does not answer is not judged here
  # (a pass that committed its reboot is legitimately going down).
  pl=$(wu_probe); printf '%s %s (after the replay)\n' "$(date -u +%H:%M:%S)" "${pl:-<no answer>}" >> "$RD/liveness.txt"
  if [ -z "$refused" ] && wu_pass_unfinished "$pl"; then
    log "round $r: PASS DEAD (found after the replay ended, with no report from the product): task/status $WU_LIVE_PIC"
    log "round $r: the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  # replay-dom0-update.py reports each STEP's rc in its output but exits 0 regardless, so its
  # exit code is not a verdict. Measured 2026-09-20: every step returned rc=46 and the driver
  # still logged "replay rc=0" and judged a round in which no pass had run at all.
  if grep -q -- '<-- UNEXPECTED' "$RD/replay.out"; then
    log "round $r: INSTRUMENT - the dom0 replay's own steps failed, so NO pass ran; not a result"
    grep -- '<-- UNEXPECTED' "$RD/replay.out" | sed 's/^/    /' | head -6 | tee -a "$OUT/run.log"
    fails=1; break
  fi
  log "round $r: replay rc=$rc (dom0 contract: 0 ok, 100 no updates, else error)"

  # The delta is what this round did. comm needs sorted input, so use the line counts instead:
  # these logs only ever grow, so everything past a file's before-snapshot length is this round's,
  # and so is every line of a file the snapshot did not see.
  # THE RELAY'S OWN LOG is sliced with it. Every byte explaining a relay failure is in there -
  # "parent watchdog armed: pid N", then "listen 127.0.0.1:<port> target=..." just before its
  # listener.Start(). It was never collected, so when the relay failed to serve the port on
  # 2026-10-19 (release 4.3.37, template-update, all three rounds) the evidence that would have said
  # how far it got was left in the guest and the guest was torn down. Collected for every round now,
  # pass or fail - and since the pass names the relay's file per day (--log-file), per file like the rest.
  slice_rc=0; wu_slice "$RD" "$RD/guestlogs-before.tsv" || slice_rc=$?
  case "$slice_rc" in
    0) : ;;
    1) log "[ERROR] round $r: the guest's update logs could not be listed after the pass - nothing of this round was collected" ;;
    *) log "[ERROR] round $r: a guest update log could not be read after the pass (UNREAD in $RD/guestlogs.tsv) - this round's slice is incomplete" ;;
  esac
  log "round $r: agent.log grew by $(wc -l < "$RD/agent.log") line(s) ($(grep -ac '^agent\.log' "$RD/guestlogs.tsv" 2>/dev/null) file(s) read)"
  guest_file 'C:\ProgramData\Qubes\update-status.json'  > "$RD/update-status.json"
  # Read here, from the status just fetched, because the after-pass facts below already depend on it; logged and acted on at the
  # pending-reboot block further down.
  reboot_needed=$(python3 - "$RD/update-status.json" <<'PY' 2>/dev/null
import json,sys
# The guest writes update-status.json with a UTF-8 BOM; plain utf-8 raises and reboot_needed
# then read 'unknown' every round (measured 2026-09-20).
try: print(str(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('reboot_needed', False)).lower())
except Exception: print('unknown')
PY
)
  log "round $r: relay log $(wc -l < "$RD/relay.log" 2>/dev/null || echo 0) line(s), handler log $(wc -l < "$RD/relay-handler.log" 2>/dev/null || echo 0) line(s), shim log $(wc -l < "$RD/vmupdate-shim.log" 2>/dev/null || echo 0) line(s)"
  # `offers` (2026-11-10): after the pass the harness also records what the Windows Update agent itself holds for every pending
  # offer - the independent read of "is this offer's content self-contained" that tools/wu-exclusion-evidence.py holds an
  # unroutable claim against. After the pass only: that is the state the round's claim is about, and before round 1 the
  # agent's store is whatever the golden last saw.
  # ...EXCEPT WHEN THE PASS SCHEDULED ITS OWN RESTART. guest/wu-update.ps1 runs `shutdown /r /t 60` when a reboot is needed, and an
  # offers read in that minute races it. MEASURED on build 4.3.41.1272's template-update round 2: the read returned at the restart,
  # ~60 s after the pass ended, with only "#< CLIXML" - no offer, no count, no error line - so the exclusion evidence for the one item
  # excluded in all three rounds could not be built and the cell ended INSTRUMENT. Round 1, same notice, finished its read in 2 s.
  # Such a round takes its first read now and OWES the offers read to the next round's start (offers_owed, taken there).
  if [ "$reboot_needed" = true ]; then
    mgmt/harness/wu-evidence-facts.sh "$VM" "$RD/facts-after.txt" > "$RD/facts-after.out" 2>&1 \
      || log "round $r: facts after the pass INCOMPLETE - $(tail -1 "$RD/facts-after.out" | cut -c1-160)"
    offers_owed=$RD
  else
    mgmt/harness/wu-evidence-facts.sh "$VM" "$RD/facts-after.txt" offers > "$RD/facts-after.out" 2>&1 \
      || log "round $r: facts after the pass INCOMPLETE - $(tail -1 "$RD/facts-after.out" | cut -c1-160)"
  fi

  after=$(dom0_avail); log "round $r: dom0 updates-available AFTER='${after:-<empty>}'"
  echo "${after:-}" > "$RD/dom0-updates-available.txt"

  jargs=(--agent-log "$RD/agent.log" --json "$RD/verdict.json")
  case "$after" in ''|*[!0-9]*) : ;; *) jargs+=(--dom0-reported "$after") ;; esac
  if [ -n "$refused" ]; then
    log "[WARN] round $r: JUDGE REFUSED (no pass ran - the refusal above is this round's outcome)"
  elif [ "$pre_ok" != 1 ]; then
    # Missing data fails: with no before-snapshot every file was taken whole, and an earlier pass would decide this round.
    log "[ERROR] round $r: JUDGE INSTRUMENT - no before-snapshot of the guest's update logs (above), so nothing was judged"; fails=1
  elif [ "$slice_rc" != 0 ]; then
    # ...and so does a slice with a file missing from it: the judge would grade part of the pass as the whole.
    log "[ERROR] round $r: JUDGE INSTRUMENT - the guest's update logs were not all read after the pass (above), so nothing was judged"; fails=1
  elif python3 tools/wu-pass-judge.py "${jargs[@]}" > "$RD/judge.out" 2>&1; then
    log "round $r: JUDGE PASS"
  else
    log "[ERROR] round $r: JUDGE FAIL"; sed 's/^/    /' "$RD/judge.out" | head -12 | tee -a "$OUT/run.log"; fails=1
  fi

  # THE PENDING REBOOT IS COMPLETED FIRST. This block used to run AFTER the oscillation check,
  # which meant the check polled for 900 s straight through a restart THIS ROUND'S OWN pass had
  # scheduled. MEASURED 2026-10-29 on win11de-tup, acceptance rel-40774674227: the dom0-driven
  # pass installed updates and ran `shutdown /r /t 60` at 05:22:12 (event 1074, comment "Qubes:
  # completing Windows update servicing" - our own string, from wu-update.ps1 shipped as the
  # qubes-rpc-services entry point); the poll started at 05:22:45; the guest went down at
  # 05:28:49 and came back at 05:38:38, and the poll expired at 05:37:49 - 49 seconds short.
  # It then reported "the scan never ran" and failed the cell, and with it the whole acceptance
  # record. Rounds 1 and 3 passed only because their restart fell outside the window: the cell
  # was a race. Nothing is excused by the reorder - the scan still has to run and the stamp
  # still has to move - it is just asked for at a moment the guest is up to answer it.
  # (reboot_needed was read from this round's update-status.json right after it was fetched, above.)
  log "round $r: reboot_needed=$reboot_needed"
  if [ "$reboot_needed" = true ]; then
    note_request "update-status.json says reboot_needed=true after round $r"
    # A REBOOT IS A COMPLETED CYCLE, not an issued command. Counting it at the shutdown was the
    # same accounting dishonesty this rule exists to stop, in my own implementation of the rule:
    # a shutdown that FAILED still incremented the counter, and a guest left powered off had only
    # half a cycle. Measured 2026-09-20: the ledger said "1 performed" while the guest was Running.
    log "round $r: shutting the guest down so the next round starts from the applied state"
    # NEVER `qvm-shutdown --wait`. Its --timeout is "timeout after which domains are KILLED"
    # (default 60 s), so --wait is a hard-kill on a timer - and a guest applying a staged
    # cumulative on shutdown legitimately takes many minutes. That is how this harness came to
    # hold a latent guest-killer aimed at the exact moment a guest is least safe to kill: mid
    # servicing apply. Measured 2026-09-20: it returned at 61 s with the guest still Running and
    # qrexec still answering - not a stall, an impatient harness with a kill attached.
    # Request the shutdown, then WATCH. A guest that will not halt is reported, never killed.
    log "round $r: requested shutdown; waiting for the guest to power off on its own (no kill)"
    toolstack_accept "$VM" >/dev/null 2>&1
    _sd=$(( $(date +%s) + 1800 ))
    while [ "$(date +%s)" -lt "$_sd" ] && [ "$(qstate)" != Halted ]; do sleep 20; done
    if [ "$(qstate)" != Halted ]; then
      if stalled; then log "[ERROR] round $r: STALLED during shutdown"; else log "[ERROR] round $r: FAIL - the guest did not power off, so the requested reboot did NOT happen"; fi
      fails=1; break
    fi
    log "round $r: guest is down; bringing it back to complete the requested cycle"
    timeout 300 qvm-start "$VM" >/dev/null 2>&1
    if wait_qrexec 900; then
      note_performed
    else
      log "[ERROR] round $r: FAIL - the guest did not come back, so the requested reboot is INCOMPLETE"
      fails=1; break
    fi
  elif [ "$reboot_needed" = unknown ]; then
    # Unreadable status is missing data, and missing data fails - it must never be treated as
    # "no reboot needed", because that silently turns a requested cycle into none.
    log "[ERROR] round $r: FAIL - update-status.json unreadable, so reboot_needed is UNKNOWN (missing data fails)"
    fails=1
  fi
  # OSCILLATION CHECK. An install pass settling dom0 is not enough: the very next SCAN must not
  # re-inflate the count. Measured 2026-09-20 - a pass drove dom0 to EMPTY and the following boot
  # scan reported 3 again, so the admin was told there was work when there was none. This is the
  # bar the reporter actually lives at, because a scan runs at every boot and on a timer.
  # ADR-updater section 8 point 5 (owner 2026-11-08): a CHANGE-NOTHING measurement must not be taken
  # while the guest has announced work that has NOT APPLIED YET. The field that decides it is not
  # reboot_needed (consumed above) but the PENDING COUNT the pass announced - `remaining` - which this
  # harness already had on disk and never consulted here. update-status.json is rewritten only BY A PASS,
  # so after the cycle it still carries this round's LAST ANNOUNCEMENT, which is exactly the standing
  # announcement ADR 8.5 makes a completion cycle traceable to; it is re-read rather than reused so the
  # guest's power state is read at the same moment, and so a rewrite by anything else cannot be missed.
  # MEASURED 2026-11-08 on win11de-wufix round 2: the cycle was requested and performed (the ledger
  # stayed honest, 2 = 2), then Windows' servicing completion took its own cycle +83 s into the next boot,
  # INSIDE this check's 900 s poll, and the round failed as "the guest POWERED ITSELF OFF during the
  # scan-only oscillation wait". The product was doing what the ADR sanctions; the instrument was
  # measuring where its measurement is not defined. So the pending count is RE-READ here, fresh.
  osc_remaining=unknown
  if [ "$(qstate)" = Running ]; then
    guest_file 'C:\ProgramData\Qubes\update-status.json' > "$RD/update-status-postcycle.json" 2>/dev/null || true
    osc_remaining=$(python3 - "$RD/update-status-postcycle.json" <<'PY' 2>/dev/null
import json, sys
# utf-8-sig for the same reason as the reboot_needed read above: the guest writes a UTF-8 BOM.
try:
    r = json.load(open(sys.argv[1], encoding='utf-8-sig')).get('remaining')
    print(int(r) if r is not None else 0)
except Exception:
    print('unknown')
PY
)
  fi
  case "$osc_remaining" in (''|*[!0-9]*) osc_remaining=unknown ;; esac
  log "round $r: pending count re-read after the cycle: remaining=$osc_remaining (state $(qstate))"
  if [ -n "$refused" ]; then
    log "round $r: oscillation check skipped - no pass ran, so there is no report for a scan to contradict"
  elif [ "$(qstate)" != Running ]; then
    # DID NOT RUN, and it SAYS so - this is never read as a pass. The guest is down because the servicing
    # completion took the cycle its announcement asked for (ADR-updater 8.5). The next round's top already
    # counts that self-power-off as a request and starts the guest, so the work continues there and the
    # following round measures the oscillation the product was never given a chance to show here.
    log "round $r: oscillation check DID NOT RUN - the guest is $(qstate), so there is nothing for a scan to contradict (ADR-updater 8.5)"
  elif [ "$osc_remaining" = unknown ]; then
    # FAIL CLOSED, like the sibling read above - which fails the round outright on an unreadable status
    # (ADR 8.3, missing data fails). Here the honest outcome is weaker and more precise: without the
    # pending count we cannot establish that this measurement is DEFINED, and a check that could not
    # establish its precondition must never read as a pass. Running it anyway is exactly what
    # manufactured the false red this change exists to stop, so it is recorded as unmeasured instead.
    log "round $r: oscillation check DID NOT RUN - the pending count could not be read, so whether work is still unapplied is UNKNOWN, and a check that cannot establish its precondition is not a pass (ADR-updater 8.5)"
  elif [ "$osc_remaining" -gt 0 ]; then
    log "round $r: oscillation check DID NOT RUN - the guest announces remaining=$osc_remaining, work that has NOT APPLIED yet, so a scan-only 'dom0 must not change' measurement is not defined here (ADR-updater 8.5)"
  else
    log "round $r: oscillation check - running a SCAN-only pass, dom0 must not change"
    # THE BASELINE IS RE-READ HERE, NOT INHERITED FROM BEFORE THE REBOOT. $after was measured
    # before the pending reboot this round now performs above, and applying updates legitimately
    # moves the count - so comparing a post-reboot scan against it would report a difference the
    # REBOOT caused and call it oscillation. When no reboot happened this is the same value read
    # a moment later, so it is always the right one to compare against.
    dom0_before_scan=$(dom0_avail)
    log "round $r: oscillation baseline (after any reboot, before the scan): '${dom0_before_scan:-<empty>}'"
    # THE DURABLE FACT, TAKEN BEFORE. The detector below used to poll for a TRANSIENT state - an
    # `action` containing 'scan' - every 30 s, and declare "the scan never ran" when it did not see
    # one. On run 39225775322 round 2 that timed out over the full 900 s while rounds 1 and 3 saw
    # theirs in 55 s and 48 s, and NOTHING could decide whether the scan had not run or a sampler
    # had missed it (Jev: sampler_missed 0.15, never_ran 0.36, evidence_can_decide 0.22 - but
    # detector_is_the_defect 0.88: sampling a transient is the wrong shape).
    # update-status.json's `ts` is durable: the updater rewrites it when it runs and it is STILL
    # THERE afterwards, so a ts that has ADVANCED past the one taken here proves the updater ran,
    # whether or not any poll happened to catch it mid-scan.
    _ts_before=$(guest_file 'C:\ProgramData\Qubes\update-status.json' | tr -d '\r' \
                 | command grep -ao '"ts"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
    log "round $r: status stamp before the scan: ${_ts_before:-<unreadable>}"
    # Run the scan WITHOUT -Scheduled. The scheduled-scan debounce legitimately skips any -Scheduled
    # scan whose previous completed pass is younger than 30 minutes, and it exits BEFORE logging - so
    # firing the task here tests the debounce, not the scan, and leaves no trace either way.
    # Measured 2026-09-20: the check waited 15 minutes for a scan that had correctly declined to run.
    # THE SCAN IS LAUNCHED DETACHED, because holding a 900 s qrexec channel open over it made the
    # channel the scan's lifeline. MEASURED on acceptance run 40037710497, rounds 1 and 2: the scan
    # STARTED (its own output shows "relay started: pid 7212", "proxy up: 127.0.0.1:8082",
    # "Sync-Revocation: 3/3 CTLs refreshed") and then the client logged
    #     qrexec_process_io: vchan connection closed early (fds: -1 -1 -1, status: -1)
    # ~16 s in, exiting 58 and then 255. When the qrexec client goes away the guest-side process
    # goes with it, so the scan died, the durable stamp never advanced, and the oscillation check
    # correctly reported "the scan never ran (missing data fails)" - failing template-update and
    # with it the whole acceptance record. Round 3 survived, which is what makes it a transport
    # flake rather than a scan that refuses.
    # Start-Process detaches the scan from this channel, so the launch returns at once and the
    # EXISTING poll below - which watches update-status.json's `ts` ADVANCE, a durable marker that
    # outlives any channel - is what decides whether it ran. Nothing is excused: a scan that truly
    # does not run still fails on the stamp not moving.
    # -EncodedCommand, NOT escaped quotes inside -Command: lint-harness L3 refuses the latter
    # because it FAILS SILENTLY, and this command must carry two paths containing spaces. The
    # base64 below is UTF-16LE of exactly this, which is what the guest runs:
    #   Start-Process -FilePath powershell -WindowStyle Hidden -ArgumentList
    #     '-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\...\qubes-windows-update.ps1"
    #      -Action scan -RelayExe "C:\Program Files\...\qubes-updates-relay.exe"'; 'LAUNCHED'
    # ONE argument STRING with the paths double-quoted: -ArgumentList @(...) joins its elements
    # with spaces and does not quote one that contains them, so the child would otherwise see
    # `-File C:\Program` plus a stray argument.
    timeout -k 10 120 tools/qtest run 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand UwB0AGEAcgB0AC0AUAByAG8AYwBlAHMAcwAgAC0ARgBpAGwAZQBQAGEAdABoACAAcABvAHcAZQByAHMAaABlAGwAbAAgAC0AVwBpAG4AZABvAHcAUwB0AHkAbABlACAASABpAGQAZABlAG4AIAAtAEEAcgBnAHUAbQBlAG4AdABMAGkAcwB0ACAAJwAtAE4AbwBQAHIAbwBmAGkAbABlACAALQBFAHgAZQBjAHUAdABpAG8AbgBQAG8AbABpAGMAeQAgAEIAeQBwAGEAcwBzACAALQBGAGkAbABlACAAIgBDADoAXABQAHIAbwBnAHIAYQBtACAARgBpAGwAZQBzAFwAUQB1AGIAZQBzACAAVABvAG8AbABzAFwAYgBpAG4AXABxAHUAYgBlAHMALQB3AGkAbgBkAG8AdwBzAC0AdQBwAGQAYQB0AGUALgBwAHMAMQAiACAALQBBAGMAdABpAG8AbgAgAHMAYwBhAG4AIAAtAFIAZQBsAGEAeQBFAHgAZQAgACIAQwA6AFwAUAByAG8AZwByAGEAbQAgAEYAaQBsAGUAcwBcAFEAdQBiAGUAcwAgAFQAbwBvAGwAcwBcAGIAaQBuAFwAcQB1AGIAZQBzAC0AdQBwAGQAYQB0AGUAcwAtAHIAZQBsAGEAeQAuAGUAeABlACIAJwA7ACAAJwBMAEEAVQBOAEMASABFAEQAJwA=' > "$OUT/round$r/oscillation-scan-launch.out" 2>&1; _osc_rc=$?
    # KEEP THE LAUNCH'S OUTCOME. This ended >/dev/null 2>&1 - stdout, stderr AND the exit code
    # thrown away - so when round 2 of run 3 reported "the scan never ran" on 2026-10-20 there was
    # nothing to say WHY, and neither I nor Jev could decide between "it never started" and "it
    # ran and was not seen" (evidence_can_decide 0.22). The 15 minute poll was measuring the
    # consequence of a command whose outcome had been discarded by design. Same defect as
    # arm-module-bases.sh's schtasks capture, found the same day.
    [ "$_osc_rc" = 0 ] || log "[WARN] round $r: the scan launch exited $_osc_rc - see $OUT/round$r/oscillation-scan-launch.out"
    # RECORD WHAT WAS SAMPLED. On 2026-10-20 round 2 of run 3 timed out here after 15m11s -
    # "the scan never ran" - while rounds 1 and 3 saw their scan, and NOTHING in the evidence
    # covered the window: each round's captured update-status.json is the PASS's own status
    # (action=full phase=done), stamped before the oscillation scan even started. So the one
    # question that matters - did the scan not run, or did a 30 s sampler miss a fast one - could
    # not be answered from the artefacts, and template-update has now failed three campaigns for
    # three different reasons. Every poll is written here with its time, so the next timeout is
    # read rather than guessed.
    _osc_log="$OUT/round$r/oscillation-poll.log"
    mkdir -p "$OUT/round$r" 2>/dev/null
    printf 'oscillation poll for round %s, started %s (budget 900s, 30s interval)\n' \
      "$r" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_osc_log"
    _sc=$(( $(date +%s) + 900 )); scan_seen=0; _osc_empty_run=0; _osc_empty_tot=0; _osc_gone=""
    while [ "$(date +%s)" -lt "$_sc" ]; do
      sleep 30
      st_now=$(guest_file 'C:\ProgramData\Qubes\update-status.json' | tr -d '\r')
      printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$(printf '%s' "${st_now:-<empty read>}" | tr '\n' ' ' | cut -c1-240)" >> "$_osc_log"
      # AN UNREADABLE GUEST IS A DIFFERENT STATE FROM A SCAN THAT DID NOT RUN, and until
      # 2026-10-29 both ended at the same message. Counted here so the verdict can name which.
      if [ -z "${st_now:-}" ]; then
        _osc_empty_run=$((_osc_empty_run+1)); _osc_empty_tot=$((_osc_empty_tot+1))
        # THE THIRD EXIT, AND THE 2026-10-29 FIX WAS ONLY THE MESSAGE. That round's note (below, at
        # the scan_seen=0 verdict) already recorded "nine consecutive empty ones AS THE GUEST
        # REBOOTED" - so a subject powering off inside this wait was MEASURED then, and all that
        # changed was the wording of the failure. The loop still had two success exits and a
        # deadline, no terminal state, so it could only INFER a departed guest from empty reads
        # after spending the whole budget. MEASURED AGAIN 2026-11-07, campaign 42400226595 round 2:
        # the guest powered itself off at ~22:48, this loop read empty fifteen times over 920 s and
        # declared the question undecidable, and the power-off was only named at 23:04:23 by the NEXT
        # round ("the guest powered itself off before round 3"). A wait that cannot detect "this will
        # never happen" burns its whole budget on a subject that died in the first minute.
        # qstate is the primitive stalled() already uses; Halted is terminal for a guest nothing here
        # will start, so the wait ends AT the event and the verdict attributes it instead of guessing.
        # (# GUARD:oscillationterminalexit)
        _osc_gone=$(qstate)
        if [ "$_osc_gone" = Halted ]; then
          printf '%s  TERMINAL: guest power_state=%s - it will never answer this read; ending the wait\n' \
            "$(date -u +%H:%M:%SZ)" "$_osc_gone" >> "$_osc_log"
          break
        fi
        _osc_gone=""
      else _osc_empty_run=0; fi
      # EITHER SIGNAL ENDS THE WAIT, and the durable one is the reliable half:
      #   * the TRANSIENT one - action contains 'scan' - is what this used to rely on alone, and it
      #     can be missed because it need not persist between two 30 s samples;
      #   * the DURABLE one - the status stamp has MOVED from the value taken before the launch -
      #     is still true afterwards, so it cannot be missed by sampling.
      # A stamp that moved proves the updater ran and wrote, which is the question being asked.
      _ts_now=$(printf '%s' "$st_now" | command grep -ao '"ts"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
      if [ -n "$_ts_now" ] && [ -n "$_ts_before" ] && [ "$_ts_now" != "$_ts_before" ]; then
        scan_seen=1
        log "round $r: the status stamp moved ($_ts_before -> $_ts_now) - the scan ran"
        break
      fi
      case "$st_now" in *'"action"'*'scan'*) scan_seen=1; break;; esac
    done
    printf 'result: scan_seen=%s after %ss (empty reads: %s total, %s trailing)\n' "$scan_seen" "$(( 900 - (_sc - $(date +%s)) ))" "$_osc_empty_tot" "$_osc_empty_run" >> "$_osc_log"
    dom0_after_scan=$(dom0_avail)
    # ---- THE IDENTITY VERDICT, AND IT DECIDES -----------------------------------------------
    # tools/wu-oscillation-verdict.py was added by 763d8dc3 with NO CALLER: written, selftested and
    # registered in offline-suites.txt, wired to nothing, so it had never decided a single campaign
    # cell (findings/issues.md WUOSCILLATIONVERDICTNEVERRUNS, P1). This is that call.
    #
    # IT RUNS BEFORE AND INDEPENDENTLY OF THE FLAG COMPARISON BELOW, which is the point: an offer we
    # reported RESOLVED coming back while a different one stops being offered leaves dom0's count
    # EXACTLY where it was, so a check gated on the flag moving is blind to it by construction. The
    # tool's own words: "Both move the number from N to N+1." Only identity separates the real
    # oscillation from Microsoft republishing a definition mid-campaign, which is why KB2267602 made
    # the count-based leg fail intermittently for ever on any guest that receives definitions.
    #
    # THE DATA IS ALREADY THERE AND IS NOT DERIVED FROM A TITLE. guest/qubes-windows-update.ps1:993
    # writes every offer with uid and rev taken straight off the COM object's Identity.UpdateID and
    # Identity.RevisionNumber - "no title parsing, no locale dependence" (ADR section 6). BEFORE is
    # the PASS's own status, AFTER is the scan's, RESOLVED is what THIS PASS said it satisfied.
    # Offers = available + not_actionable: both are still being OFFERED, and an offer we cannot
    # action is still one that must not come back after we reported it done.
    #
    # RESOLVED IS A DELTA, NOT THE LIST. `satisfied` is an accumulator (see the pre-pass capture
    # above), and the tool's rule is "we said we resolved it, and here it is again" - so feeding it
    # the accumulator reports every identity the GOLDEN ever resolved and still sees offered.
    # MEASURED on the recorded campaign rel-40037710497 round 3: the guest's own status carries
    # satisfied=["177debf7-03e2-4280-a97a-53ade44e2cce:200"] AND available=[{uid 177debf7-..., rev
    # 200, KB2267602}] in the SAME file, count=1 - because the script deliberately does not subtract
    # satisfied from available ("dom0 must always hear the true number of available updates"; a
    # previous attempt to subtract it is what produced GWeck's forum #175 report). The count leg
    # passed that round. The accumulator would have failed the updater cell on it.
    # So: resolved = satisfied(after this pass) MINUS satisfied(before it). On a round that resolves
    # nothing the set is empty and the OSCILLATION branch cannot fire - correctly: nothing was
    # claimed, so nothing can come back.
    if [ "$scan_seen" = 1 ]; then
      printf '%s' "$st_now" > "$RD/update-status-after-scan.json"
      python3 - "$RD/update-status.json" "$RD/update-status-after-scan.json" \
               "$RD/osc-before.json" "$RD/osc-after.json" "$RD/osc-resolved.txt" \
               "$RD/update-status-before.json" <<'PY'
import json, sys
def offers(d):
    out = []
    for k in ("available", "not_actionable"):
        for u in (d.get(k) or []):
            # not_actionable is a DURABLE list of STRINGS - kb and title, built from the previous
            # status's info rows (guest/qubes-windows-update.ps1:3162-3177) and carried forward on
            # purpose. Walking it as objects raised AttributeError here on 2026-11-08 and took the
            # whole oscillation verdict with it. It crashed exactly when an info-severity offer
            # exists, which is the only case this check is for, so the instrument was blind in
            # precisely its own subject. The PRODUCT is correct; this projection was not.
            if not isinstance(u, dict):
                continue
            if u.get("uid"):
                out.append({"uid": u["uid"], "rev": u.get("rev"), "kb": u.get("kb") or ""})
    return out
def rd(p):
    with open(p, encoding="utf-8-sig") as fh:
        return json.load(fh)
bp, ap, bo, ao, ro, pp = sys.argv[1:7]
b, a = rd(bp), rd(ap)
json.dump({"offers": offers(b)}, open(bo, "w"))
json.dump({"offers": offers(a)}, open(ao, "w"))
# satisfied is a list of IDENTITY STRINGS, "<uid>[:<rev>]" - NOT objects. Measured on
# rel-40037710497 round 3: satisfied[0] == "177debf7-03e2-4280-a97a-53ade44e2cce:200", and the
# same spelling the script's own -Only switch documents at qubes-windows-update.ps1:37. Treating
# it as an object made this projection raise, which would have FAILED the updater cell on a
# healthy guest. Objects are accepted too, so a future shape change does not silently yield none.
def sat(d):
    out = []
    for u in (d.get("satisfied") or []):
        uid = (u.get("uid") or u.get("id") or "") if isinstance(u, dict) else str(u)
        uid = uid.split(":", 1)[0].strip().lower()
        if uid:
            out.append(uid)
    return out
# The pre-pass file is the ONLY thing that makes this a delta. A missing or unreadable one is not
# "the golden resolved nothing" - that reading turns the accumulator back into the resolved set and
# fails the cell on the golden's history. It is missing data, so it raises and the caller fails.
prior = set(sat(rd(pp)))
# the PASS's own status is where its resolved set lands; the scan that follows only reads.
res = [u for u in sat(b) if u not in prior]
open(ro, "w").write(",".join(res))
PY
      if [ $? != 0 ]; then
        log "[ERROR] round $r: FAIL - the per-offer identities could not be projected from the guest's own status, so the oscillation verdict cannot run (missing data fails, as everywhere here)"
        fails=1
      else
        _osc_res=$(cat "$RD/osc-resolved.txt" 2>/dev/null)
        python3 tools/wu-oscillation-verdict.py --before "$RD/osc-before.json" \
                --after "$RD/osc-after.json" --resolved "$_osc_res" > "$RD/osc-verdict.out" 2>&1
        _osc_vrc=$?
        log "round $r: $(head -1 "$RD/osc-verdict.out")"
        if [ "$_osc_vrc" = 1 ]; then
          log "[ERROR] round $r: FAIL - OSCILLATION BY IDENTITY: an offer this pass reported RESOLVED is being offered again after the scan. dom0 went '${dom0_before_scan:-<empty>}' -> '${dom0_after_scan:-<empty>}', which a count cannot tell apart from a new publication"
          fails=1
        elif [ "$_osc_vrc" != 0 ]; then
          log "[ERROR] round $r: FAIL - the oscillation verdict could not read its input (rc=$_osc_vrc): $(head -2 "$RD/osc-verdict.out" | tail -1)"
          fails=1
        fi
      fi
    fi
    if [ "$scan_seen" = 0 ]; then
      # MEASURED 2026-10-29: this said "the scan never ran" while the poll log showed eleven good
      # reads and then nine consecutive empty ones as the guest rebooted - so the message sent the
      # reader hunting a scan defect that did not exist. Both still fail; only the cause differs.
      # TWO CLAIMS, AND ONLY ONE OF THEM IS UNDECIDABLE. "Did the scan run?" cannot be answered once
      # the subject is gone. "Did the guest stay up across a pass defined to change nothing?" IS
      # answered - measured, by power state, at the moment it happened - and the answer is no. So
      # this is a product FAIL on what was measured, never an instrument excuse for what was not:
      # a scan-only oscillation pass that ends with the subject powered off is the finding itself.
      if [ -n "$_osc_gone" ]; then
        log "[ERROR] round $r: FAIL - the guest POWERED ITSELF OFF (power_state=$_osc_gone) DURING the scan-only oscillation wait, after $_osc_empty_tot empty read(s) - MEASURED by power state, not inferred. This pass is defined to change nothing, so the power-off is the finding; whether the scan ran is separately undecidable - see $_osc_log"
      elif [ "$_osc_empty_run" -ge 3 ]; then
        log "[ERROR] round $r: FAIL - the GUEST STOPPED ANSWERING during the oscillation wait ($_osc_empty_tot empty read(s), the last $_osc_empty_run consecutive) while power_state was NOT Halted, so whether the scan ran cannot be decided (missing data fails) - see $_osc_log"
      else
        log "[ERROR] round $r: FAIL - the scan never ran, so the oscillation check did not happen (missing data fails)"
      fi
      fails=1
    elif [ "${dom0_before_scan:-}" != "${dom0_after_scan:-}" ]; then
      # THE GUEST'S OWN POST-SCAN VIEW IS THE DISCRIMINATOR, IT WAS ALREADY IN HAND, AND IT WAS
      # THROWN AWAY. dom0 changing across a scan is the SYMPTOM; whether dom0 was told wrong or the
      # scan genuinely found newly-applicable work is answered by the counts the guest wrote during
      # that same scan, and $st_now already holds them (the wait loop above breaks on them).
      # MEASURED 2026-10-16 on win11de-tup: a REAL oscillation failure ('<empty>' -> '1') reported
      # the symptom with no cause, and by the time anyone read it the guest was Halted - and booting
      # it to look runs the per-boot task, which rewrites the very state that would answer the
      # question. So the answer has to be captured AT the failure or it does not exist.
      printf '%s' "$st_now" > "$RD/update-status-after-scan.json"
      _osc=$(python3 - "$RD/update-status-after-scan.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8-sig'))
except Exception:
    print('unreadable'); raise SystemExit
print('count=%s offered=%s actionable=%s remaining=%s available=%d not_actionable=%d satisfied=%d' % (
    d.get('count'), d.get('offered'), d.get('actionable'), d.get('remaining'),
    len(d.get('available') or []), len(d.get('not_actionable') or []), len(d.get('satisfied') or [])))
PY
      )
      # IT JUDGES ON AGREEMENT, NOT ON THE FLAG MOVING. A flag that changed is not the defect: dom0
      # reporting work the guest also has is dom0 being right, and an update published between the
      # pass and the scan moves it.
      # THE GUEST'S SIDE IS THE OFFERS dom0 IS TOLD ABOUT, derived from the rows the scan wrote and
      # not from the `count` it published, which is the number under test. ADR-updater section 2
      # leaves three kinds of offer out of that number, and so does this: a Defender definition
      # (point 6, the row's is_definition), an offer this scan verified has no route (point 5,
      # `unroutable`, keyed by the KB or by the exact title of an offer without one), and an
      # identity already proved installed (point 3, `satisfied`, uid:rev).
      # Offers left and dom0 says available -> they AGREE. None left and dom0 says available -> the
      # admin was told of work the guest does not have; a flag raised by a definition alone ends
      # here. Offers left and dom0 empty -> work the user cannot see. Unreadable -> missing data fails.
      _told=$(python3 - "$RD/update-status-after-scan.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8-sig'))
    rows = d['available']
    if not isinstance(rows, list):
        raise ValueError
    noroute = [str(k).lower() for k in d.get('unroutable') or []]
    sat = [str(k).lower() for k in d.get('satisfied') or []]
    left = []
    for u in rows:
        kb = str(u.get('kb') or '')
        route = kb if kb[:2].upper() == 'KB' and kb[2:].isdigit() else str(u.get('title') or '').strip()
        if (u.get('is_definition') is not True and route.lower() not in noroute
                and ('%s:%s' % (u.get('uid'), u.get('rev'))).lower() not in sat):
            left.append(route or str(u.get('uid') or '?'))
except Exception:
    print('unreadable'); raise SystemExit
print('%d\t%s' % (len(left), '; '.join(left) or '(none)'))
PY
      )
      _cnt=${_told%%$'\t'*}; _items=${_told#*$'\t'}
      if [ "${_cnt:-unreadable}" = unreadable ]; then
        log "[ERROR] round $r: FAIL - dom0 went '${dom0_before_scan:-<empty>}' -> '${dom0_after_scan:-<empty>}' across the scan and the guest's own status is UNREADABLE, so agreement cannot be judged (missing data fails)"
        fails=1
      elif [ -n "$dom0_after_scan" ] && [ "${_cnt:-0}" -gt 0 ]; then
        log "round $r: oscillation OK - dom0 went '${dom0_before_scan:-<empty>}' -> '${dom0_after_scan:-<empty>}' and the guest AGREES: its own scan lists ${_cnt} offer(s) dom0 is told about [${_items:-?}]. dom0 was told what the guest found, which is not the defect this leg looks for"
      elif [ -z "$dom0_after_scan" ] && [ "${_cnt:-0}" -gt 0 ]; then
        log "[ERROR] round $r: FAIL - the guest's scan lists ${_cnt} offer(s) dom0 is told about [${_items:-?}] and dom0's updates-available is EMPTY: work the user cannot see"
        log "  the guest's OWN status from that scan: ${_osc:-unreadable}  (kept at $RD/update-status-after-scan.json)"
        fails=1
      else
        log "[ERROR] round $r: FAIL - dom0's updates-available is '${dom0_after_scan:-<empty>}' while the guest's own scan lists no offer dom0 is told about (Defender definitions, verified no-route offers and installed identities are left out): the admin was told there was work when there was none"
        log "  the guest's OWN status from that scan: ${_osc:-unreadable}  (kept at $RD/update-status-after-scan.json)"
        fails=1
      fi
    else
      log "round $r: oscillation OK - dom0 stayed '${dom0_after_scan:-<empty>}' across the pass and the scan"
    fi
  fi

done

# A LAST ROUND THAT SCHEDULED A RESTART OWES ITS OFFERS READ TOO, with no next round to take it at, so this is that round's top:
# the settle, the qrexec wait, a self-power-off counted as the guest's own request, then the read. Only after a run that went
# through every round - every break out of the loop above sets fails=1 - because a stopped run's guest is left as it is, to be
# interrogated. A read that is not taken is logged as the gap it is, and the evidence builder refuses on it (missing data fails).
if [ -n "$offers_owed" ] && [ "$fails" = 0 ]; then
  log "settling ${SETTLE:-60}s before the offers read ${offers_owed##*/} owes"; sleep "${SETTLE:-60}"
  owed_up=1
  if ! wait_qrexec 900; then
    owed_up=0
    if stalled; then log "after round $ROUNDS: STALLED (Running, qrexec dead) - stopping, the guest must be interrogated"; fails=1
    else
      note_request "the guest powered itself off after round $ROUNDS"
      timeout 240 qvm-start "$VM" >/dev/null 2>&1
      note_performed
      if wait_qrexec 900; then owed_up=1; else log "after round $ROUNDS: guest never came up"; fails=1; fi
    fi
  fi
  if [ "$owed_up" = 1 ]; then
    mgmt/harness/wu-evidence-facts.sh "$VM" "$offers_owed/facts-after.txt" offers-only >> "$offers_owed/facts-after.out" 2>&1
    log "after round $ROUNDS: the offers read ${offers_owed##*/} owed: $(tail -1 "$offers_owed/facts-after.out" | cut -c1-160)"
  else
    log "after round $ROUNDS: the offers read ${offers_owed##*/} owed was NOT taken - the guest did not answer"
  fi
elif [ -n "$offers_owed" ]; then
  log "the offers read ${offers_owed##*/} owed was NOT taken - the run stopped early and its guest is left as it is"
fi

if [ "$reboots_performed" != "$reboots_requested" ]; then
  log "[ERROR] FAIL REBOOT ACCOUNTING: $reboots_performed performed vs $reboots_requested requested - a power cycle happened that nobody asked for (or a requested one was skipped)"
  fails=1
else
  log "reboot accounting OK: $reboots_performed performed = $reboots_requested requested"
fi
# THE AGGREGATE FLAG IS NOT THE WHOLE ANSWER. Every round above judges what dom0 was TOLD. It
# cannot see WHICH items the guest stopped counting, or why - so an item excluded for the wrong
# reason still produces a correct-looking dom0 flag and a green run. Jev graded this design's
# ability to tell a correct exclusion from a concealed failure at 0.24 for exactly that reason
# (2026-09-20, confidence 0.93), and the very first run carrying the grade had such an item in it
# (KB5007651, findings/issues.md). So: COUNT them here in code, and refuse to call the run green
# while they are unjudged. The judging itself is tools/wu-exclusion-audit.py - deliberately NOT
# called from here, because a harness must not need an external API to finish.
excl=$(python3 - "$OUT" <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, "tools")
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("a", "tools/wu-exclusion-audit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen = {}
for rnd, r in m.rows(Path(sys.argv[1])):
    if m.excluded(r):
        seen.setdefault(m.key(r), []).append(rnd)
for k, v in seen.items():
    print(f"{k}\t{','.join(v)}")
PYEOF
)
unjudged=0
if [ -n "$excl" ]; then
  log "EXCLUDED ITEMS dom0 was never told about ($(printf '%s\n' "$excl" | wc -l)):"
  printf '%s\n' "$excl" | sed 's/^/    /' | tee -a "$OUT/run.log"
  printf '%s\n' "$excl" > "$OUT/excluded-items.tsv"
  # Until 2026-09-21 this printed "NOT GREEN YET" and then exited 0 anyway, so a run WITH unjudged
  # exclusions was indistinguishable from a clean one to every caller - the precise hole
  # docs/ADR-updater.md listed as open. The harness still does not call Jev (it must be able to
  # finish without an external API), but it no longer PRETENDS the question was settled:
  #   * WU_EXCLUSION_VERDICT=<answers.json>, produced by `tools/wu-exclusion-audit.py --out`, is
  #     replayed here through that tool's OWN gate function - pure local code, no API - and must
  #     cover EVERY item in excluded-items.tsv. Green only if the gate passes on all of them.
  #   * no verdict file => exit 4 UNJUDGED. Not a pass, not a defect: an open question.
  if [ -n "${WU_EXCLUSION_VERDICT:-}" ] && [ -f "$WU_EXCLUSION_VERDICT" ]; then
    gate_out=$(python3 - "$OUT/excluded-items.tsv" "$WU_EXCLUSION_VERDICT" <<'PYEOF'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("a", "tools/wu-exclusion-audit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
items = [l.split("\t")[0] for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
try:
    v = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception as e:
    print("VERDICT FILE UNREADABLE: %s" % e); sys.exit(2)
missing = [k for k in items if k not in v]
if missing:
    # A verdict that does not cover an item says nothing about it. Never let coverage be implied.
    print("VERDICT DOES NOT COVER: " + ", ".join(missing)); sys.exit(2)
stale = [k for k in v if k not in items]
if stale:
    print("note: verdict also covers items not in this run: " + ", ".join(stale))
sys.exit(m.gate({k: v[k] for k in items}))
PYEOF
    ); grc=$?
    printf '%s\n' "$gate_out" | sed 's/^/    /' | tee -a "$OUT/run.log"
    if [ "$grc" = 0 ]; then
      log "exclusion audit REPLAYED from $WU_EXCLUSION_VERDICT: every excluded item positively judged"
    else
      log "[ERROR] FAIL EXCLUSION AUDIT (rc=$grc): an excluded item is a concealed failure, unproven, or uncovered"
      fails=1
    fi
  else
    unjudged=1
    log "UNJUDGED EXCLUSIONS: run  tools/wu-exclusion-audit.py $OUT --out <answers.json>  and judge each"
    log "               one, then re-run with WU_EXCLUSION_VERDICT=<answers.json> to grade this run."
    log "               An exclusion not judged against evidence OUTSIDE the updater is an open"
    log "               question, not a pass - see docs/ADR-updater.md section 2."
  fi
else
  log "no excluded items in any round - dom0 was told about everything the guest saw"
fi

# HARDWIRED ERROR SWEEP over this suite's own log, and it BLOCKS. This is the suite that drives the
# updater, i.e. the one whose log carried the lines nobody read (HARNESSLOGUNSWEPT). A declared
# error is accounted for by an entry in mgmt/harness/error-ledger.txt that records WHY it is not a
# defect; a row with no reason accounts for nothing, and accounted messages are still printed.
# It can only ever RAISE the exit code - it never rescues a failing round.
sweep_rc=0
if [ -x tools/sweep-gate.sh ] && [ -s "$OUT/run.log" ]; then
  if bash tools/sweep-gate.sh "$OUT/run.log" > "$OUT/sweep-gate.out" 2>&1; then
    log "sweep-gate: every declared error in this suite's own log is accounted for"
  else
    log "[ERROR] SWEEP-GATE: $(grep -ac '^  UNACCOUNTED' "$OUT/sweep-gate.out" || true) unaccounted declared error(s) in $OUT/run.log - read $OUT/sweep-gate.out"
    grep -aE '^  (UNACCOUNTED|ROSE)' "$OUT/sweep-gate.out" | head -8 | while IFS= read -r l; do log "  $l"; done
    sweep_rc=5
  fi
fi

log "DONE: rounds=$ROUNDS fails=$fails unjudged_exclusions=$unjudged sweep=$sweep_rc out=$OUT"
[ "$fails" = 0 ] || exit 3
[ "$unjudged" = 0 ] || exit 4   # passed every round, but exclusions are unjudged: NOT green
[ "$sweep_rc" = 0 ] || exit 5   # rounds passed, but this suite's own log carries an unread error
exit 0
