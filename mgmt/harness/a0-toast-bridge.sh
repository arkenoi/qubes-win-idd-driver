#!/bin/bash
# A0-TOAST-BRIDGE — acceptance for DESIGN-toast-bridge.md phase A0 on a freshly primed guest.
#
#   mgmt/harness/a0-toast-bridge.sh <release-setup-dir> [subject] [base]
#       subject default win10-a0tb, base default win10-base
#
# Experiment plan (the experimenter five lines):
#   HYPOTHESIS: with service.notify-bridge=1 + NotifyBridgeAllow=[PS AUMID], an informational
#     toast from the PS AUMID is bridged (dom0-native bubble, bridge.log delivery ack — fwd_count
#     on FWD_RTT ok=1 / SENT OK, see a0-lib.sh — NO guest o-r
#     banner) and a real-choice toast from a non-allowlisted AUMID stays a guest o-r banner
#     with no dom0 send. Gate off, consent revoked, or connection down => EVERY toast banners
#     in-guest (fail-open). Refuted if an allowlisted toast is ever lost (neither bannered nor
#     bridged) or any split direction inverts.
#   BASELINE: the gate-OFF arm runs FIRST on the same primed guest (P2), before any enable.
#   VARIABLE: one per phase — gate+allowlist (P3/P4), consent revoke/restore (P6a fail-open,
#   P6b reconnect). (The old P6c "kill the relay" phase is retired - see P6b for why.)
#   INSTRUMENT: qtest-geom o-r window diffs (validated in P2: fires on a known-good
#     NotifyClient --send, silent on none), bridge.log tail past a per-phase offset (rule 8),
#     notifhost --dump-aumids for Notification Center records, certutil sha256 of the
#     installed binaries vs the package (rule 1). Each detector is seen to FAIL before its
#     PASS is trusted (P2 baseline + P6a are the fail-proofs).
#   BUDGET: prime <=3600s; session waits per e2e-wait budgets; bridge relaunch waits <=150s
#     (agent supervise 5s poll + 60s throttle). EVERY poll loop is seq-bounded AND wall-clock
#     capped (owner audit 2026-09-06): each guest probe rides qrun (~55s hard cap, e2e-lib _q)
#     or geom (~200s cap), so seq*sleep alone understates a loop's ceiling by N*probe-cost -
#     the exact mechanism that turned P6b's nominal-150s reconnect wait into a measured
#     32-minute stall (20:42->21:14) on a reconnect that could never happen. Loops log which
#     exit they took (success / terminal / deadline); waits whose precondition a prior failed
#     step made impossible SKIP as terminal instead of burning their budget.
#     NOTE the rig's whole-desktop capture (geom /
#     local.WinFullScreen) is ~59s PER CALL here (measured), so window-path detection uses
#     PERSISTENT toasts (fire_info_p) caught in <=2 geom tries, not many polls of a transient
#     toast; total ~60-90 min incl. 3 cold boots. Overall watchdog is the caller's job (>=130 min).
#
# Evidence: scratchpad/a0-toast-bridge-<UTC>/ (gitignored - internal never enters the repo).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

SETUP="${1:?usage: a0-toast-bridge.sh <release-setup-dir> [subject] [base]}"
VM="${2:-win10-a0tb}"
BASE="${3:-win10-base}"

TS=$(date -u +%Y%m%d-%H%M%S)
# A0_OUT: optional evidence-dir override for the protocol wrapper (protocol/steps/p6-toast-bridge.json
# points it under the campaign's ACCEPT_OUT, outside the repo, so the follow-up probes can address
# verdicts.txt deterministically). Default stays the gitignored scratchpad dir; A0_OUT must likewise
# never point inside a tracked path - captures never enter the repo.
OUT="${A0_OUT:-scratchpad/a0-toast-bridge-$TS}"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
verdict(){ log "VERDICT $1: $2"; echo "$1|$2" >> "$OUT/verdicts.txt"; }

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
source .claude/skills/win-guest-e2e/e2e-lib.sh
source mgmt/harness/e2e-wait.sh
source mgmt/harness/a0-lib.sh   # shared toast-bridge instruments (constants + probes) - same code the a0-selftest.sh floor validates

log "=== A0 toast-bridge acceptance: subject=$VM base=$BASE setup=$SETUP out=$OUT ==="

# ---------- P0 preflight -------------------------------------------------------------------
for f in guest/run-as-user.ps1 guest/fire-demo-toast.ps1 tools/qtest tools/qtest-geom \
         mgmt/harness/prime-run.sh; do
  [ -e "$f" ] || { log "FATAL missing $f"; exit 1; }
done
[ -d "$SETUP" ] || { log "FATAL setup dir $SETUP missing"; exit 1; }
[ -f "$SETUP/MANIFEST.json" ] && cp "$SETUP/MANIFEST.json" "$OUT/" && log "manifest: $(head -c 400 "$SETUP/MANIFEST.json")"
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2!="Halted" && $1 ~ /^(win(10|11)|prime-)/ {print $1}')
[ -z "${running// /}" ] || { log "FATAL not all Halted: $running"; exit 1; }

# ---------- P1 prime -----------------------------------------------------------------------
log "P1: prime-run $BASE -> $VM (job ours)"
./mgmt/harness/prime-run.sh "$BASE" "$VM" ours --payload "$SETUP" > "$OUT/prime.log" 2>&1
rc=$?
[ $rc -eq 0 ] || { log "FATAL prime-run rc=$rc (see $OUT/prime.log tail: $(tail -3 "$OUT/prime.log" | tr '\n' ' '))"; exit 1; }
w_usersession "$VM" 900 p1-session "$OUT" log || { log "FATAL no user session after prime"; exit 1; }
verdict P1 "primed and session up"

# build identity (rule 1): installed notifhost/gui-agent sha vs package
for exe in notifhost.exe gui-agent.exe; do
  pk=$(find "$SETUP" -name "$exe" | head -1)
  if [ -n "$pk" ]; then
    want=$(sha256sum "$pk" | awk '{print tolower($1)}')
    have=$(qrun "certutil -hashfile \"$QT\\$exe\" SHA256" | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    if [ "$want" = "$have" ]; then log "P1b: $exe identity OK ($want)"
    else verdict P1b "FAIL $exe installed=$have package=$want - BUILD UNDER TEST IS WRONG"; exit 1; fi
  else log "P1b: $exe not in package (WARN)"; fi
done
verdict P1b "build identity proven"

# INSTRUMENT SELF-TEST (experimenter rule 3: the heartbeat probe must be shown to distinguish
# present vs absent, AND to be able to FAIL, before any verdict relies on it). Point path_state
# at a file that ALWAYS exists (cmd.exe) and one that never does; both directions must be right.
pst_yes=$(path_state 'C:\Windows\System32\cmd.exe')
pst_no=$(path_state 'C:\ProgramData\qubes-toast-bridge\__nope_selftest_marker__')
if [ "$pst_yes" = PRESENT ] && [ "$pst_no" = ABSENT ]; then
  log "P1c: heartbeat instrument self-test OK (present->$pst_yes absent->$pst_no)"
else
  verdict P1c "INSTRUMENT heartbeat self-test present='$pst_yes' absent='$pst_no' - probe unreliable, aborting (instrument-class, not a bridge verdict)"; exit 1
fi
# hb_fresh's FRESHNESS discriminator must ALSO be shown both ways (the P8 hbseen=1 false-fail was a
# STALE heartbeat read as "running"): a just-written file reads PRESENT (fresh); an old-but-existing
# system file (cmd.exe, mtime years old) reads ABSENT (stale) with a tight max-age. Proves hb_state
# can no longer accept a stale heartbeat as a live bridge.
qrun "cmd /c echo x> C:\\ProgramData\\__hbself__" >/dev/null 2>&1
hbf_fresh=$(hb_fresh 'C:\ProgramData\__hbself__' 120)
hbf_stale=$(hb_fresh 'C:\Windows\System32\cmd.exe' 30)
qrun "cmd /c del C:\\ProgramData\\__hbself__" >/dev/null 2>&1
if [ "$hbf_fresh" = PRESENT ] && [ "$hbf_stale" = ABSENT ]; then
  log "P1c: heartbeat FRESHNESS self-test OK (fresh->$hbf_fresh stale->$hbf_stale)"
else
  verdict P1c "INSTRUMENT heartbeat freshness self-test fresh='$hbf_fresh' stale='$hbf_stale' - mtime probe unreliable, aborting (instrument-class, not a bridge verdict)"; exit 1
fi
# fwd_count/fwd_attempts delivery-detector self-test (seen-to-fail, pure text - no VM contact).
# Covers THE 2026-09-05 regression shape: a toast whose SENT line was dropped by BLog's
# share-mode write race (FWD_RTT ok=1 present, SENT absent) must still count as delivered,
# an unacked window must count 0, and anchored patterns must resist title-embedded forgeries.
if fwd_selftest; then
  log "P1c: fwd delivery-detector self-test OK (delivered->5 undelivered->0 clean->0)"
else
  verdict P1c "INSTRUMENT fwd delivery-detector self-test failed (see fwd_selftest MISMATCH line above) - delivery counting unreliable, aborting (instrument-class, not a bridge verdict)"; exit 1
fi

# P1d READINESS GATE for the user-session fire path. The FIRST run-as-user fire after a cold boot
# silently no-ops (no FIRED, no toast) until Task Scheduler + the interactive session fully
# initialize - measured in MINUTES, not the ~32s fire_raw allowed (that defeated P2 three times
# while detection itself was fine, 2026-09-04). So POLL a real fire until it actually shows FIRED,
# up to ~12 min, breaking the instant it works. This is the fire instrument's readiness proof
# (experimenter rule 3) AND the warm-up - once it fires here, mid-run fires are warm.
# P1d gates on the fire path's ACTUAL precondition. run-as-user.ps1 (line 92-95) refuses with
# exit 3 "no_active_interactive_session" - in ~1.5s, NOT the 120s task wait - until `query user`
# reports an Active session. On a FRESH PRIME that is false for ~12+ min while the two-stage
# install settles, even though P1's explorer+pushrun signal passed at t+0 (the signals diverge).
# So poll `query user` DIRECTLY (cheap) for an Active session, up to ~20 min, logging the state
# each time so the transition is on record; THEN confirm one real fire and CAPTURE its output
# (so a residual failure names its reason instead of being grepped away). P3/P8 reboots settle
# fast, so their short mid-run fire retry is unaffected.
log "P1d: waiting for an Active interactive session (query user), up to ~20 min"
# Bounded three ways (owner audit 2026-09-06): seq cap 40; wall cap 1500s (expected event is
# the measured ~12+ min fresh-prime settle, so ~20 min nominal + margin - each qrun turn can
# cost up to ~55s on top of the 30s sleep, which would otherwise stretch this to ~57 min);
# terminal if the guest HALTS mid-wait (no session can ever come from a halted guest).
p1d_active=""; qu=""; p1d_term=""; _w1d=$SECONDS
for i in $(seq 1 40); do
  qu=$(qrun 'query user' 2>&1 | tr -d '\r')
  if printf '%s' "$qu" | grep -qE '[[:space:]]Active([[:space:]]|$)'; then
    p1d_active=1; log "P1d: Active session after ~$((SECONDS-_w1d))s: $(printf '%s' "$qu" | grep -E 'Active' | head -1 | tr -s ' ')"; break
  fi
  [ "$(w_state "$VM")" = Halted ] && { p1d_term=1; break; }
  [ $(( SECONDS - _w1d )) -ge 1500 ] && break
  sleep 30
done
if [ -z "$p1d_active" ]; then
  log "P1d: session wait exit=$([ -n "$p1d_term" ] && echo terminal-guest-halted || echo deadline) t=$((SECONDS-_w1d))s (i=$i/40)"
  printf '%s\n' "$qu" > "$OUT/p1d-lastquser.txt"
  verdict P1d "INSTRUMENT no Active interactive session ($([ -n "$p1d_term" ] && echo "guest HALTED mid-wait" || echo "~25 min wall budget spent; install still settling?")) - fire path never became usable, not a bridge verdict; last query user: $(printf '%s' "$qu" | tr '\n' '|' | head -c 300)"; exit 1
fi
# Confirm the fire path actually works now, and keep the run-as-user output for the record.
fout=$(fire_raw "-Title 'A0T warmup-prime'" "warm$RANDOM"); printf '%s\n' "$fout" > "$OUT/p1d-fire.txt"
if printf '%s' "$fout" | grep -qa FIRED; then
  log "P1d: fire path READY (Active session + confirmed FIRED)"
else
  verdict P1d "INSTRUMENT session Active but fire still not FIRED (fire instrument unusable, not a bridge verdict): $(printf '%s' "$fout" | grep -a 'RUNASUSER\|error' | head -1)"; exit 1
fi
dismiss_toasts

# ---------- P2 instrument validation + gate-OFF baseline -----------------------------------
log "P2: detectors + baseline (gate off - as-installed default)"
hb=$(hb_state)
[ "$hb" = "ABSENT" ] && log "P2: no heartbeat with gate off (expected)" \
  || verdict P2 "FAIL bridge heartbeat present with gate OFF (hb=$hb)"

# dom0-bubble detection is ACK-ONLY. A geom arm here was STRUCTURALLY IMPOSSIBLE (audit
# 2026-09-05): qtest-geom filters every window on _QUBES_VMNAME == the subject VM, so a
# dom0-NATIVE notification bubble (no _QUBES_VMNAME) can NEVER appear in its output - the arm
# could only ever false-activate on a stray GUEST toast between snapshots, after which P4a's
# correctly-suppressed toast read domseen=no and false-FAILED. This rig has no dom0-side window
# instrument; the protocol ack ('OK id=') is the proof the dom0 path delivers.
nc=$(find "$SETUP" -iname 'NotifyClient.exe' | head -1)
NCG="$QT\\NotifyClient.exe"
[ -n "$nc" ] || NCG=""   # no dom0 detector at all if the client is not shipped
DOMDET=none
# presence via path_state, NOT `cmd /c if exist ... echo HAVE`: qrun echoes the command line,
# which literally contains the marker - the banned self-match idiom (and the \" escaping mangles
# cmd's `if exist`), so it reported HAVE even with the file absent.
if [ -n "$NCG" ] && [ "$(path_state "$NCG")" = PRESENT ]; then
  qrun "\"$NCG\" --send \"A0T detector probe\" body --timeout 20" > "$OUT/p2-ncsend.txt" 2>&1
  if grep -qa "OK id=" "$OUT/p2-ncsend.txt"; then DOMDET=ack
  else log "P2 WARN: NotifyClient probe not acked: $(cat "$OUT/p2-ncsend.txt")"; fi
fi
log "P2: dom0-bubble detector mode = $DOMDET (ack=protocol-ack; no dom0-side window instrument on this rig)"

# baseline toast, gate off: MUST banner in-guest (o-r window), MUST NOT bridge. PERSISTENT so the
# ~59s geom can catch the o-r window (2 tries is plenty for a toast that stays up).
snap_or "$TOASTRE" p2-guest-base > "$OUT/p2-guest-base.ids"
# Fire status is a TERMINAL discriminator (audit 2026-09-06): a toast that never FIRED cannot
# banner, so grading the missing banner as a product FAIL would be dishonest - it is an
# instrument miss, and the abort is INSTRUMENT-class either way (both exit 1).
if ! fire_info_p "A0T baseline gate-off" > "$OUT/p2-fire.txt" 2>&1; then
  cap "$OUT" p2-nofire "$R"; dismiss_toasts
  verdict P2 "INSTRUMENT baseline toast never confirmed FIRED (p2-fire.txt) - window-path detector unproven, aborting (instrument-class, not a bridge verdict)"; exit 1
fi
if new_or_window "$OUT/p2-guest-base.ids" "$TOASTRE" 2 p2-guest-toast; then
  dismiss_toasts
  verdict P2 "PASS gate-off toast banners in guest (window path; detector CAN fire)"
else
  cap "$OUT" p2-noshow "$R"; dismiss_toasts; verdict P2 "FAIL gate-off toast produced no guest o-r banner - baseline broken, aborting"; exit 1
fi

# ---------- P3 enable + cold boot ----------------------------------------------------------
log "P3: enable gate + allowlist, cold boot"
qvm-features "$VM" service.notify-bridge 1 || { log "FATAL qvm-features failed"; exit 1; }
qrun "reg add \"HKLM\\SOFTWARE\\Invisible Things Lab\\Qubes Tools\\gui-agent\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$PSAUMID\" /f" >/dev/null
timeout -k 8 60 ./tools/qtest shutdown >/dev/null 2>&1
w_halt "$VM" 300 p3-halt log || { QTEST_VM=$VM timeout -k 8 30 ./tools/qtest kill >/dev/null 2>&1; sleep 5; }
timeout -k 8 60 ./tools/qtest start >/dev/null 2>&1
w_usersession "$VM" 900 p3-session "$OUT" log || { log "FATAL no session after cold boot"; exit 1; }
ok=""; _w3h=$SECONDS
for i in $(seq 1 30); do   # agent launches bridge on shell-up; 5s supervise cadence
  # wall cap 180s (expected: heartbeat within ~30s of session-up; hb_state is a ~55s-capped
  # qrun per turn, so the old seq*sleep=150s nominal could stretch to ~30 min - audit 2026-09-06)
  [ "$(hb_state)" = PRESENT ] && { ok=1; break; }
  [ $(( SECONDS - _w3h )) -ge 180 ] && break
  sleep 5
done
log "P3: heartbeat wait exit=$([ -n "$ok" ] && echo success || echo deadline) t=$((SECONDS-_w3h))s (i=$i/30)"
[ -n "$ok" ] || { cap "$OUT" p3-nobridge "$R"; verdict P3 "FAIL bridge never heartbeat after cold boot"; exit 1; }
conn=""; _w3c=$SECONDS
for i in $(seq 1 15); do
  # wall cap 120s (expected: connect within seconds of the heartbeat; blog_since is a qrun)
  blog_since 0 > "$OUT/p3-blog.txt"
  grep -qa "connected (server version" "$OUT/p3-blog.txt" && { conn=1; break; }
  [ $(( SECONDS - _w3c )) -ge 120 ] && break
  sleep 4
done
log "P3: connected wait exit=$([ -n "$conn" ] && echo success || echo deadline) t=$((SECONDS-_w3c))s (i=$i/15)"
[ -n "$conn" ] && verdict P3 "PASS cold boot: bridge up + connected" \
  || { verdict P3 "FAIL bridge up but never connected: $(tail -5 "$OUT/p3-blog.txt" | tr '\n' ';')"; exit 1; }

# ---------- P4 the split -------------------------------------------------------------------
# NOTE lazy suppression (notifhost fail-open fix): an app's banner is suppressed only AFTER its
# first successful forward, so toast #1 per app double-shows (banner + dom0) and toast #2+ is
# suppressed. So P4a fires a WARM-UP toast to earn suppression (expect a delivery ack), then the
# real check toast (expect a delivery ack + NO new guest banner). This is the fail-open invariant
# made visible: a bridge that never forwards never suppresses.
# Delivery is graded by fwd_count (a0-lib.sh), NOT a bare `SENT id=.*OK` grep: BLog's write race
# drops the SENT line ~1/3 of the time since the 5133293 shadow worker (2026-09-05: ids 15/20/22
# had FWD_RTT ok=1 + a dom0 Dismissed callback but no SENT -> P4a/P6b/P7 false-FAILed).
log "P4: split - allowlisted bridges (lazy suppression), control stays windowed"
# Each forward wait below: seq 15 AND wall cap 90s (expected: the delivery ack lands within a
# few seconds - measured FWD_RTT ms=9..17; blog_since is a ~55s-capped qrun per turn, so the
# old nominal 30s could stretch to ~14 min - audit 2026-09-06). A fire that never confirmed
# FIRED is TERMINAL for its wait (the ack can never come): skip, never burn the budget.
warm=""
if ! Lw=$(blog_len); then
  log "P4: blog_len unreadable before warm-up (probe miss) - warm-up forward unobserved"
elif fire_info "A0T warmup" > /dev/null 2>&1; then   # toast #1: earns suppression (double-shows)
  _w4w=$SECONDS
  for i in $(seq 1 15); do
    blog_since "$Lw" > "$OUT/p4-warm.txt"
    [ "$(fwd_count "$OUT/p4-warm.txt")" -ge 1 ] && { warm=1; break; }
    [ $(( SECONDS - _w4w )) -ge 90 ] && break
    sleep 2
  done
  log "P4: warm-up forward wait exit=$([ -n "$warm" ] && echo success || echo deadline) t=$((SECONDS-_w4w))s"
else
  log "P4: warm-up never confirmed FIRED (terminal - forward wait skipped; INSTRUMENT already logged)"
fi
[ -n "$warm" ] && log "P4: warm-up forwarded (suppression earned)" || log "P4: WARN warm-up not forwarded"
sleep 3
p4inst=""
L0=$(blog_len) || { p4inst="blog_len unreadable"; L0=1000000000; }
snap_or "$TOASTRE" p4-guest-base > "$OUT/p4-guest-base.ids"
fired4=""
fire_info "A0T bridged" > /dev/null 2>&1 && fired4=1   # toast #2: must be suppressed now
[ -n "$fired4" ] || p4inst="${p4inst:+$p4inst + }check toast never confirmed FIRED"
sent=""
if [ -z "$p4inst" ]; then
  _w4s=$SECONDS
  for i in $(seq 1 15); do
    blog_since "$L0" > "$OUT/p4-blog.txt"
    [ "$(fwd_count "$OUT/p4-blog.txt")" -ge 1 ] && { sent=1; break; }
    [ $(( SECONDS - _w4s )) -ge 90 ] && break
    sleep 2
  done
  log "P4a: delivery wait exit=$([ -n "$sent" ] && echo success || echo deadline) t=$((SECONDS-_w4s))s"
else
  log "P4a: delivery wait SKIPPED (terminal: $p4inst)"
fi
# dom0 side: NOT graded by window list (geom cannot see dom0-native bubbles, see the P2
# detector block) - the FWD_RTT ok=1 ack fwd_count keys on IS the dom0-delivery evidence
# (logged only after the dom0 server's ack frame for that seq). Explicit literal so
# the verdict never looks like a vacuously-passed check.
domseen='n/a(no-dom0-instrument)'
guestbanner=no
new_or_window "$OUT/p4-guest-base.ids" "$TOASTRE" 2 p4-guest && guestbanner=yes
sb4=$(showbanner); log "P4a introspection: $sb4 (=0 -> warmup earned suppression, so no-banner is CORRECT and only the forward failed; =absent -> nothing was ever forwarded/suppressed)"
if [ -n "$p4inst" ]; then
  cap "$OUT" p4a "$R"; verdict P4a "INSTRUMENT $p4inst - bridged-path check never exercised, NOT a bridge verdict ($sb4)"
elif [ -n "$sent" ] && [ "$guestbanner" = no ]; then
  verdict P4a "PASS bridged: delivery acked (FWD_RTT ok=1/SENT OK), no guest banner, dom0=$domseen ($sb4)"
else
  cap "$OUT" p4a "$R"; verdict P4a "FAIL sent=${sent:-no} guestbanner=$guestbanner dom0=$domseen $sb4"
fi
p4binst=""
L1=$(blog_len) || { p4binst="blog_len unreadable"; L1=1000000000; }
snap_or "$TOASTRE" p4c-guest-base > "$OUT/p4c-guest-base.ids"
fire_ctl "A0T control" > /dev/null 2>&1 || p4binst="${p4binst:+$p4binst + }control toast never confirmed FIRED"
ctlbanner=no
[ -z "$p4binst" ] && new_or_window "$OUT/p4c-guest-base.ids" "$TOASTRE" 2 p4c-guest && ctlbanner=yes
blog_since "$L1" > "$OUT/p4c-blog.txt"
ctlskip=$(grep -ca "skip id=" "$OUT/p4c-blog.txt" || true)
ctlsent=$(fwd_attempts "$OUT/p4c-blog.txt")   # ANY forward attempt (SENT or FWD_RTT) is a leak here
dismiss_toasts "$CTLAUMID"   # the control toast is a persistent reminder - clear it
if [ -n "$p4binst" ]; then
  cap "$OUT" p4b "$R"; verdict P4b "INSTRUMENT $p4binst - control split never exercised, NOT a bridge verdict"
elif [ "$ctlbanner" = yes ] && [ "$ctlsent" = 0 ]; then
  verdict P4b "PASS control: guest banner, no bridge send (skip=$ctlskip)"
else
  cap "$OUT" p4b "$R"; verdict P4b "FAIL control banner=$ctlbanner sent-lines=$ctlsent"
fi

# ---------- P5 expiry keeps the guest record ----------------------------------------------
log "P5: dom0 expiry must NOT delete the guest Notification Center record"
sleep 20   # let the dom0 bubble expire
# --dump-aumids reads the CURRENT user's Notification Center; run it as the user via a script.
raspush guest/a0-dump-center.ps1 "" a0d$RANDOM > "$OUT/p5-dump.txt" 2>&1
dump=$(cat "$OUT/p5-dump.txt")
if echo "$dump" | grep -qa "A0T bridged"; then
  verdict P5 "PASS record survives dom0 expiry (reason-filter works)"
else
  blog_since 0 | grep -a "Dismissed" > "$OUT/p5-dismissed.txt" || true
  verdict P5 "FAIL bridged toast gone from center after expiry: $(cat "$OUT/p5-dismissed.txt" | tr '\n' ';')"
fi

# ---------- P6 fail-open, seen to fail -----------------------------------------------------
log "P6a: revoke consent -> bridge must fail open (banner returns), THE selftest fail-proof"
# ASSERT the revoke actually landed. a0-consent.ps1 prints CONSENT-NOW=<value>; the old code
# discarded it, so a silent revoke failure (run-as-user no-op) left consent=Allow and P6a
# false-PASSED (relaunched bridge re-suppresses+forwards, lazy suppression double-shows a banner,
# new_or_window hits) - THE fail-proof proving nothing. If it did not land, P6a is INSTRUMENT, not
# a bridge verdict. (audit 2026-09-05)
# consent_ensure (a0-lib.sh): bounded retry-with-verify. The one-shot raspush read back EMPTY
# on the rig 2026-09-06 (the run-as-user task-start race, since fixed at the source, plus the
# genuinely transient no-op class) and the un-landed Deny cascaded into P6b's 32-minute wait
# for a reconnect that could never happen. Only after 3 verified attempts does P6a go
# INSTRUMENT; p6a_deny_landed is P6b's terminal-state guard input.
p6a_deny_landed=""
consent_ensure Deny a0x1 && p6a_deny_landed=1
if [ -z "$p6a_deny_landed" ]; then
  cap "$OUT" p6a-noconsent "$R"; verdict P6a "INSTRUMENT consent revoke did not land after 3 verified attempts (last read '${CONSENT_LAST:-nothing}'; raw in consent-a0x1.txt) - fail-open test invalid, NOT a bridge verdict"
else
  qrun "\"$QT\\notifhost.exe\" --bridge-stop" >/dev/null 2>&1
  Lpre=$(blog_len) || Lpre=0    # offset BEFORE relaunch, to catch its FATAL-consent exit lines
  sleep 12   # bridge exits (2s poll), restores banners, deletes heartbeat
  raspush guest/a0-showbanner.ps1 "" a0x2$RANDOM > "$OUT/p6-showbanner.txt" 2>&1
  sb=$(grep -aoE 'SHOWBANNER-NOW=.*' "$OUT/p6-showbanner.txt" | head -1)
  echo "$sb" | grep -qa 'SHOWBANNER-NOW=0$' && verdict P6a-restore "FAIL ShowBanner still 0 after bridge stop" \
    || log "P6a: ShowBanner restored ($sb)"
  # agent relaunches within ~75s; relaunched bridge must EXIT on the consent selftest (FATAL)
  sleep 90
  snap_or "$TOASTRE" p6-guest-base > "$OUT/p6-guest-base.ids"
  L2=$(blog_len) || L2=1000000000
  if fire_info_p "A0T consent-revoked" > /dev/null 2>&1; then fired6=1; else fired6=; fi
  win6=no; new_or_window "$OUT/p6-guest-base.ids" "$TOASTRE" 2 p6-guest && win6=yes
  sleep 6   # let a (wrongly) forwarded toast reach dom0 before asserting NONE did
  # fwd_attempts, not `SENT id=.*OK`: (a) a dropped SENT line (BLog write race) must not hide a
  # leaked forward, (b) an attempted-but-rejected forward under Deny is just as much a leak.
  blog_since "$L2" > "$OUT/p6a-blog.txt" 2>/dev/null || true
  sent6=$(fwd_attempts "$OUT/p6a-blog.txt")
  blog_since "$Lpre" 2>/dev/null | grep -a "FATAL" > "$OUT/p6-fatal.txt" || true
  fatal6=$(grep -ca 'FATAL' "$OUT/p6-fatal.txt" || true)
  dismiss_toasts
  if [ -z "$fired6" ]; then
    cap "$OUT" p6a "$R"; verdict P6a "INSTRUMENT consent-revoked toast never FIRED - cannot judge fail-open, NOT a bridge verdict"
  elif [ "$win6" = yes ] && [ "${sent6:-0}" = 0 ]; then
    verdict P6a "PASS fail-open: consent=Deny, window path (o-r window), NO dom0 forward (sent=$sent6, relaunch-FATAL=$fatal6)"
  elif [ "$win6" = yes ]; then
    cap "$OUT" p6a "$R"; verdict P6a "FAIL consent=Deny but toast ALSO forwarded to dom0 (sent=$sent6) - fail-open leaked a bridged copy"
  else
    cap "$OUT" p6a "$R"; verdict P6a "FAIL toast lost with consent revoked (no window, sent=$sent6, FATAL=$fatal6) - FAIL-CLOSED DEFECT"
  fi
fi

log "P6b: restore consent -> bridge RECONNECTS and re-forwards (this is the reconnect assertion)"
# P6b now carries the RECONNECT verdict outright. The old P6c ("kill the relay") is DELETED:
# empirically this guest runs exactly ONE notifhost.exe (the --bridge) while connected+forwarding
# - there is NO separate `notifhost --relay` process. The qubes.Notifications vchan is carried by
# a per-connection qrexec-wrapper.exe (session 1); identifying WHICH wrapper is that relay needs
# its command line = WMI, and WMI is BROKEN in this guest (Get-CimInstance/wmic/Get-Process return
# empty; only tasklist works, no command lines), while killing ALL wrappers would also sever
# qtest's own qrexec. So "find and kill the relay" is impossible here. The disconnect->reconnect->
# re-forward capability is instead induced and asserted RIGHT HERE by the consent cycle: P6a's
# Deny forced `FATAL access=2 ... exiting` (bridge exits, connection torn down); the Allow below
# drives a fresh `connected (server version` + a post-restore `SENT id=..OK`. (owner decision
# 2026-09-05; the bridge also supports bare in-process reconnect via ConnUp on g_connDead, but
# there is no guest-side way to drop only the connection without the WMI-unidentifiable wrapper.)
#
# $Lpre (set in P6a, before the relaunch) is the offset that anchors the reconnect evidence: the
# disconnect (P6a's `FATAL access=`, or a `connection down`) AND the NEW `connected (server version`
# must both appear PAST it, so a stale connected line from before the cycle can never satisfy it.
Ldis="${Lpre:-0}"
# TERMINAL-STATE GUARD (rig 2026-09-06: P6b waited 32 real minutes, 20:42->21:14, for a
# reconnect after a Deny that never landed - the bridge never disconnected, so no reconnect
# could ever occur, and the loop's per-turn qrun cost stretched its nominal 150s to 32 min).
# A reconnect needs a disconnect first, so BEFORE any waiting: P6a's Deny must have verified
# AND the tear-down must be ON RECORD past $Lpre ('FATAL access=' consent exit or an explicit
# 'connection down'). Missing precondition => P6b is INSTRUMENT immediately - "no disconnect
# to reconnect from" - never a wait. The disconnect read is re-polled just 3x against a
# transient blog_since miss / a relaunch-FATAL still landing; that is a ~30s guard, not a wait.
# Honesty split: only "setup never landed" skips as INSTRUMENT; "disconnected but never
# reconnected" stays a product FAIL below.
p6b_noprecond=""
if [ -z "${p6a_deny_landed:-}" ]; then
  p6b_noprecond="consent revoke never landed (P6a INSTRUMENT)"
else
  disc=""
  for i in 1 2 3; do
    blog_since "$Ldis" > "$OUT/p6b-blog.txt" 2>/dev/null || true
    grep -qaE "FATAL access=|connection down" "$OUT/p6b-blog.txt" && { disc=1; break; }
    [ "$i" -lt 3 ] && sleep 5
  done
  [ -n "$disc" ] || p6b_noprecond="Deny verified but no disconnect on record past line $Ldis (no 'FATAL access='/'connection down'; P6a relaunch-FATAL count=${fatal6:-?}) - ANOMALOUS with a landed Deny, diagnose p6b-blog.txt"
fi
if [ -n "$p6b_noprecond" ]; then
  # Restore consent even on the skip path, VERIFIED, or P7/P8 inherit consent=Deny and the
  # whole tail of the run cascades - the exact multi-phase cascade this guard exists to stop.
  # Idempotent when the revoke never landed (consent is already Allow).
  consent_ensure Allow a0x3 || log "P6b WARN: Allow restore did not verify on the skip path - P7/P8 may inherit consent=Deny (their own verdicts will surface it)"
  cap "$OUT" p6b-noprecond "$R"
  verdict P6b "INSTRUMENT no disconnect to reconnect from - consent cycle never happened ($p6b_noprecond); reconnect wait SKIPPED (guard exit=terminal, NOT a bridge verdict)"
elif ! consent_ensure Allow a0x3; then
  cap "$OUT" p6b-norestore "$R"
  verdict P6b "INSTRUMENT consent restore (Allow) never verified after 3 attempts (last read '${CONSENT_LAST:-nothing}'; raw in consent-a0x3.txt) - reconnect cannot be induced, NOT a bridge verdict; P7/P8 will likely inherit consent=Deny"
else
  # Reconnect wait - THREE EXITS: success (NEW connected + heartbeat) / terminal (handled by
  # the guard above) / deadline. seq 30 AND wall cap 150s: the budget is the documented
  # relaunch path (supervise 5s + 60s relaunch throttle + connect), and the wall check runs
  # every turn because blog_since+hb_state cost up to ~2x55s qrun timeouts per turn - the
  # 32-minute mechanism. One in-flight probe may overshoot the cap; nothing more can.
  rec=""; _w6b=$SECONDS
  for i in $(seq 1 30); do
    blog_since "$Ldis" > "$OUT/p6b-blog.txt"
    # a NEW connected line past the revoke offset AND a heartbeat now = a real reconnect, not
    # P6b's own stale connected line
    grep -qa "connected (server version" "$OUT/p6b-blog.txt" && \
      [ "$(hb_state)" = PRESENT ] && { rec=1; break; }
    [ $(( SECONDS - _w6b )) -ge 150 ] && break
    sleep 5
  done
  log "P6b: reconnect wait exit=$([ -n "$rec" ] && echo success || echo deadline) t=$((SECONDS-_w6b))s (i=$i/30; disconnect pre-asserted past line $Ldis)"
  if [ -n "$rec" ]; then
    # recovery cleared suppression (reconnect), so re-earn it with a warm-up (lazy suppression)
    warm2=""
    if ! Lw2=$(blog_len); then
      log "P6b: blog_len unreadable before the warm-up (probe miss) - warm-up forward unobserved"
    elif fire_info "A0T recov-warmup" > /dev/null 2>&1; then
      _w6w=$SECONDS
      for i in $(seq 1 15); do
        blog_since "$Lw2" > "$OUT/p6b-warm.txt"
        [ "$(fwd_count "$OUT/p6b-warm.txt")" -ge 1 ] && { warm2=1; break; }
        [ $(( SECONDS - _w6w )) -ge 90 ] && break
        sleep 2
      done
      log "P6b: warm-up forward wait exit=$([ -n "$warm2" ] && echo success || echo deadline) t=$((SECONDS-_w6w))s"
    else
      log "P6b: warm-up never confirmed FIRED (terminal - forward wait skipped; INSTRUMENT already logged)"
    fi
    sleep 3
    l4ok=""; L4=""
    L4=$(blog_len) && l4ok=1
    snap_or "$TOASTRE" p6b-guest-base > "$OUT/p6b-guest-base.ids"
    fired6b=""
    fire_info "A0T recovered" > /dev/null 2>&1 && fired6b=1
    sent=""
    if [ -n "$l4ok" ] && [ -n "$fired6b" ]; then
      _w6c=$SECONDS
      for i in $(seq 1 15); do
        blog_since "$L4" > "$OUT/p6b-check.txt"
        [ "$(fwd_count "$OUT/p6b-check.txt")" -ge 1 ] && { sent=1; break; }
        [ $(( SECONDS - _w6c )) -ge 90 ] && break
        sleep 2
      done
      log "P6b: re-forward wait exit=$([ -n "$sent" ] && echo success || echo deadline) t=$((SECONDS-_w6c))s"
    else
      log "P6b: re-forward wait SKIPPED (terminal: offset-readable=${l4ok:-no} check-fired=${fired6b:-no})"
    fi
    gb=no; new_or_window "$OUT/p6b-guest-base.ids" "$TOASTRE" 2 p6b-guest && gb=yes
    if [ -z "$l4ok" ] || [ -z "$fired6b" ]; then
      cap "$OUT" p6b "$R"; verdict P6b "INSTRUMENT reconnect PROVEN (NEW connected past line $Ldis after a pre-asserted disconnect) but the re-forward check could not be exercised (offset-readable=${l4ok:-no} check-fired=${fired6b:-no}) - re-forward half UNGRADED, NOT a full P6b pass"
    elif [ -n "$sent" ] && [ "$gb" = no ]; then
      verdict P6b "PASS reconnect: disconnect (consent cycle, pre-asserted past line $Ldis) -> NEW 'connected (server version' -> bridged again + re-suppressed"
    else
      cap "$OUT" p6b "$R"; verdict P6b "FAIL recovery sent=${sent:-no} guestbanner=$gb (reconnected but re-forward/suppress wrong)"
    fi
  else
    cap "$OUT" p6b "$R"; verdict P6b "FAIL bridge never reconnected within the 150s budget of a VERIFIED consent restore (disconnect on record past line $Ldis, no NEW 'connected (server version'): $(tail -4 "$OUT/p6b-blog.txt" | tr '\n' ';')"
  fi
fi

# ---------- P7 politeness ------------------------------------------------------------------
log "P7: burst of 5 -> all accounted, one connection"
p7inst=""
L7=$(blog_len) || { p7inst="blog_len unreadable before the burst"; L7=1000000000; }
conncount0=$(blog_since 0 | grep -ca "connected (server version" || true)
# Count CONFIRMED fires: a toast that never FIRED can never be forwarded, so grading tot<5 as
# a product FAIL when k fires no-op'd would be dishonest (audit 2026-09-06). fire_info already
# logs each miss loudly.
f7=0
for i in 1 2 3 4 5; do fire_info "A0T burst $i" > /dev/null 2>&1 && f7=$((f7+1)); done
sleep 25
blog_since "$L7" > "$OUT/p7-blog.txt"
# fwd_count = distinct acked per-toast forwards (FWD_RTT ok=1 / SENT OK, deduped) + acked
# coalesced batch items. Replaces the SENT-only count (dropped-SENT false-FAIL, 2026-09-05:
# id=22 was acked+dom0-dismissed but its SENT line was lost -> tot=4) AND the old
# `paste|bc` coalesced sum, which was silently ALWAYS empty on this rig (bc not installed).
tot=$(fwd_count "$OUT/p7-blog.txt")
conncount1=$(blog_since 0 | grep -ca "connected (server version" || true)
if [ -n "$p7inst" ] || [ "$f7" -lt 5 ]; then
  verdict P7 "INSTRUMENT ${p7inst:-only $f7/5 burst fires confirmed FIRED} - burst accounting ungraded (unfired toasts cannot be forwarded), NOT a bridge verdict (tot=$tot conns $conncount0->$conncount1 recorded)"
elif [ "$tot" -ge 5 ] && [ "$conncount1" = "$conncount0" ]; then
  verdict P7 "PASS burst: $tot accounted (distinct acked ids + acked coalesced items), connection reused"
else
  verdict P7 "FAIL burst tot=$tot conns $conncount0->$conncount1"
fi

# ---------- P8 legacy-toasts opt-out (wins over notify-bridge) ------------------------------
# service.legacy-toasts must force the bridge OFF even with notify-bridge=1: an allowlisted
# toast then renders as an override-redirect guest window (window path) and is NOT forwarded.
# Read at agent init, so this needs a cold boot. Proven-to-fail: without the opt-out the same
# toast bridges (P4a), so a window-path result here is a real discriminator.
log "P8: legacy-toasts opt-out forces the bridge off (cold boot)"
qvm-features "$VM" service.legacy-toasts 1 || log "P8 WARN: qvm-features legacy-toasts failed"
timeout -k 8 60 ./tools/qtest shutdown >/dev/null 2>&1
w_halt "$VM" 300 p8-halt log || { QTEST_VM=$VM timeout -k 8 30 ./tools/qtest kill >/dev/null 2>&1; sleep 5; }
timeout -k 8 60 ./tools/qtest start >/dev/null 2>&1
w_usersession "$VM" 900 p8-session "$OUT" log || { verdict P8 "FAIL no session after legacy-toasts cold boot"; }
# STALE PRE-BOOT HEARTBEAT RACE (confirmed 2026-09-05, P8 false-FAIL hbseen=1). The P6b/P7 bridge
# wrote C:\ProgramData\qubes-toast-bridge\heartbeat every ~2s right up to this cold shutdown; a
# FORCED halt kills it before its clean-exit heartbeat-delete (notifhost.cpp:1031) can run, so the
# file SURVIVES the reboot with an mtime ~= shutdown time. On a fast boot (~25s this run) it is
# still inside hb_state's 45s freshness window at the poll below => false PRESENT. Deleting it
# BEFORE the shutdown does NOT help: the bridge is still running and rewrites the file (CREATE_ALWAYS,
# notifhost.cpp:843) within one ~2s loop before the halt. Delete it HERE, AFTER the gate-off cold
# boot: the gate is forced off so no bridge launches, and ONLY BridgeMain's loop writes the
# heartbeat (--restore-banners does not), so nothing recreates it. A subsequent hb_state=PRESENT
# can then ONLY be a real, wrongly-launched post-boot bridge - the exact regression P8 must catch.
# Run as SYSTEM (qrun) so the ProgramData file is deletable regardless of the user-session owner.
qrun "cmd /c del /q /f \"C:\\ProgramData\\qubes-toast-bridge\\heartbeat\" 2>nul" >/dev/null 2>&1
# bridge must NOT come up (gate forced off); allow a generous window then confirm no heartbeat.
# NEGATIVE watch, two exits: regression-detected (heartbeat seen - the early break IS the
# defect) / window-elapsed-clean. Wall cap 180s (audit 2026-09-06): the watch must outlast the
# ~75s in which a wrongly-gated bridge would launch (supervise 5s + 60s throttle), and the old
# 20x(qrun+5s) shape could stretch a healthy pass to ~20 min of qrun timeouts.
hbseen=""; _w8=$SECONDS
for i in $(seq 1 20); do
  [ "$(hb_state)" = PRESENT ] && { hbseen=1; break; }
  [ $(( SECONDS - _w8 )) -ge 180 ] && break
  sleep 5
done
log "P8: no-bridge watch exit=$([ -n "$hbseen" ] && echo regression-detected || echo window-elapsed-clean) t=$((SECONDS-_w8))s (i=$i/20)"
L8=$(blog_len) || { log "P8 WARN: blog_len unreadable after retries - using a high sentinel so the fresh-forward count reads 0 (never the whole-log residue) and P8 can only fail on a REAL fresh forward, not stale P7 data"; L8=1000000000; }
snap_or "$TOASTRE" p8-guest-base > "$OUT/p8-guest-base.ids"
fired8=""
fire_info_p "A0T legacy" > /dev/null 2>&1 && fired8=1   # persistent: geom must catch the o-r window
lgwin=no
[ -n "$fired8" ] && new_or_window "$OUT/p8-guest-base.ids" "$TOASTRE" 2 p8-guest && lgwin=yes
blog_since "$L8" > "$OUT/p8-blog.txt" 2>/dev/null || true
lgsent=$(fwd_attempts "$OUT/p8-blog.txt")   # ANY forward attempt while the bridge must be off
sb8=$(showbanner); log "P8 introspection: $sb8 (=0 with no bridge -> a LEFTOVER suppression the disabled bridge never restored, a REAL product bug; =absent -> legacy toast took the window path or did not fire)"
dismiss_toasts
# Verdict order (audit 2026-09-06): a heartbeat with the opt-out set is a REAL fail regardless
# of the fire; only with the negative half clean does an unfired toast demote the window-path
# half to INSTRUMENT (an unfired toast can neither banner nor leak - grading it FAIL was
# dishonest cascade, grading it PASS would be vacuous).
if [ -n "$hbseen" ]; then
  cap "$OUT" p8 "$R"; verdict P8 "FAIL legacy-toasts: bridge heartbeat PRESENT with the opt-out set (hbseen=1) - the opt-out did not force the bridge off ($sb8)"
elif [ -z "$fired8" ]; then
  cap "$OUT" p8 "$R"; verdict P8 "INSTRUMENT legacy toast never confirmed FIRED - window-path/no-forward halves ungraded (no-heartbeat half IS valid and clean), NOT a product verdict ($sb8)"
elif [ "$lgwin" = yes ] && [ "${lgsent:-0}" = 0 ]; then
  verdict P8 "PASS legacy-toasts: bridge did NOT run (no heartbeat), toast took the window path, no forward ($sb8)"
else
  cap "$OUT" p8 "$R"; verdict P8 "FAIL legacy-toasts hbseen=no windowpath=$lgwin sent-lines=${lgsent:-?} $sb8"
fi
qvm-features --unset "$VM" service.legacy-toasts 2>/dev/null || true

# ---------- wrap ---------------------------------------------------------------------------
cap "$OUT" final "$R" || true
blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
# Count FAIL *and* INSTRUMENT: an INSTRUMENT verdict means a phase was never actually exercised
# (fire never fired, consent never revoked, blog_len unreadable) - "missing data fails", so the
# overall exit code the caller gates on must NOT read green when a phase was ungraded
# (audit 2026-09-05: the old `grep -c FAIL` let an unexercised phase exit 0).
fails=$(grep -cE 'FAIL|INSTRUMENT' "$OUT/verdicts.txt" || true)
log "=== done: $fails FAIL/INSTRUMENT line(s); evidence in $OUT; subject $VM left running for inspection ==="
[ "${fails:-0}" = 0 ]
