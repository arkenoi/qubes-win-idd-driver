#!/bin/bash
# A0-TOAST-BRIDGE — acceptance for DESIGN-toast-bridge.md phase A0 on a freshly primed guest.
#
#   mgmt/harness/a0-toast-bridge.sh <release-setup-dir> [subject] [base]
#       subject default win10-a0tb, base default win10-base
#
# Experiment plan (the experimenter five lines):
#   HYPOTHESIS: with service.notify-bridge=1 + NotifyBridgeAllow=[PS AUMID], an informational
#     toast from the PS AUMID is bridged (dom0-native bubble, bridge.log SENT OK, NO guest o-r
#     banner) and a real-choice toast from a non-allowlisted AUMID stays a guest o-r banner
#     with no dom0 send. Gate off, consent revoked, or connection down => EVERY toast banners
#     in-guest (fail-open). Refuted if an allowlisted toast is ever lost (neither bannered nor
#     bridged) or any split direction inverts.
#   BASELINE: the gate-OFF arm runs FIRST on the same primed guest (P2), before any enable.
#   VARIABLE: one per phase — gate+allowlist (P3/P4), consent (P6a/b), relay liveness (P6c).
#   INSTRUMENT: qtest-geom o-r window diffs (validated in P2: fires on a known-good
#     NotifyClient --send, silent on none), bridge.log tail past a per-phase offset (rule 8),
#     notifhost --dump-aumids for Notification Center records, certutil sha256 of the
#     installed binaries vs the package (rule 1). Each detector is seen to FAIL before its
#     PASS is trusted (P2 baseline + P6a are the fail-proofs).
#   BUDGET: prime <=3600s; session waits per e2e-wait budgets; bridge relaunch waits <=150s
#     (agent supervise 5s poll + 60s throttle). NOTE the rig's whole-desktop capture (geom /
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
OUT="scratchpad/a0-toast-bridge-$TS"; mkdir -p "$OUT"
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
  verdict P1c "FAIL heartbeat instrument self-test present='$pst_yes' absent='$pst_no' - probe unreliable, aborting"; exit 1
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
  verdict P1c "FAIL heartbeat freshness self-test fresh='$hbf_fresh' stale='$hbf_stale' - mtime probe unreliable, aborting"; exit 1
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
p1d_active=""; qu=""
for i in $(seq 1 40); do
  qu=$(qrun 'query user' 2>&1 | tr -d '\r')
  if printf '%s' "$qu" | grep -qE '[[:space:]]Active([[:space:]]|$)'; then
    p1d_active=1; log "P1d: Active session after ~$((i*30))s: $(printf '%s' "$qu" | grep -E 'Active' | head -1 | tr -s ' ')"; break
  fi
  sleep 30
done
if [ -z "$p1d_active" ]; then
  printf '%s\n' "$qu" > "$OUT/p1d-lastquser.txt"
  verdict P1d "FAIL no Active interactive session in ~20 min (install still settling?); last query user: $(printf '%s' "$qu" | tr '\n' '|' | head -c 300)"; exit 1
fi
# Confirm the fire path actually works now, and keep the run-as-user output for the record.
fout=$(fire_raw "-Title 'A0T warmup-prime'" "warm$RANDOM"); printf '%s\n' "$fout" > "$OUT/p1d-fire.txt"
if printf '%s' "$fout" | grep -qa FIRED; then
  log "P1d: fire path READY (Active session + confirmed FIRED)"
else
  verdict P1d "FAIL session Active but fire still not FIRED: $(printf '%s' "$fout" | grep -a 'RUNASUSER\|error' | head -1)"; exit 1
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
fire_info_p "A0T baseline gate-off" > "$OUT/p2-fire.txt" 2>&1
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
ok=""
for i in $(seq 1 30); do   # agent launches bridge on shell-up; 5s supervise cadence
  [ "$(hb_state)" = PRESENT ] && { ok=1; break; }; sleep 5
done
[ -n "$ok" ] || { cap "$OUT" p3-nobridge "$R"; verdict P3 "FAIL bridge never heartbeat after cold boot"; exit 1; }
conn=""
for i in $(seq 1 15); do
  blog_since 0 > "$OUT/p3-blog.txt"
  grep -qa "connected (server version" "$OUT/p3-blog.txt" && { conn=1; break; }; sleep 4
done
[ -n "$conn" ] && verdict P3 "PASS cold boot: bridge up + connected" \
  || { verdict P3 "FAIL bridge up but never connected: $(tail -5 "$OUT/p3-blog.txt" | tr '\n' ';')"; exit 1; }

# ---------- P4 the split -------------------------------------------------------------------
# NOTE lazy suppression (notifhost fail-open fix): an app's banner is suppressed only AFTER its
# first successful forward, so toast #1 per app double-shows (banner + dom0) and toast #2+ is
# suppressed. So P4a fires a WARM-UP toast to earn suppression (expect SENT OK), then the real
# check toast (expect SENT OK + NO new guest banner). This is the fail-open invariant made
# visible: a bridge that never forwards never suppresses.
log "P4: split - allowlisted bridges (lazy suppression), control stays windowed"
Lw=$(blog_len)
fire_info "A0T warmup" > /dev/null 2>&1        # toast #1: earns suppression (double-shows)
warm=""
for i in $(seq 1 15); do blog_since "$Lw" | grep -qa "SENT id=.*OK" && { warm=1; break; }; sleep 2; done
[ -n "$warm" ] && log "P4: warm-up forwarded (suppression earned)" || log "P4: WARN warm-up not forwarded"
sleep 3
L0=$(blog_len)
snap_or "$TOASTRE" p4-guest-base > "$OUT/p4-guest-base.ids"
fire_info "A0T bridged" > /dev/null 2>&1        # toast #2: must be suppressed now
sent=""
for i in $(seq 1 15); do
  blog_since "$L0" > "$OUT/p4-blog.txt"
  grep -qa "SENT id=.*OK" "$OUT/p4-blog.txt" && { sent=1; break; }; sleep 2
done
# dom0 side: NOT graded by window list (geom cannot see dom0-native bubbles, see the P2
# detector block) - the SENT..OK ack above IS the dom0-delivery evidence. Explicit literal so
# the verdict never looks like a vacuously-passed check.
domseen='n/a(no-dom0-instrument)'
guestbanner=no
new_or_window "$OUT/p4-guest-base.ids" "$TOASTRE" 2 p4-guest && guestbanner=yes
sb4=$(showbanner); log "P4a introspection: $sb4 (=0 -> warmup earned suppression, so no-banner is CORRECT and only the forward failed; =absent -> nothing was ever forwarded/suppressed)"
if [ -n "$sent" ] && [ "$guestbanner" = no ]; then
  verdict P4a "PASS bridged: SENT OK, no guest banner, dom0=$domseen ($sb4)"
else
  cap "$OUT" p4a "$R"; verdict P4a "FAIL sent=${sent:-no} guestbanner=$guestbanner dom0=$domseen $sb4"
fi
L1=$(blog_len)
snap_or "$TOASTRE" p4c-guest-base > "$OUT/p4c-guest-base.ids"
fire_ctl "A0T control" > /dev/null 2>&1
ctlbanner=no
new_or_window "$OUT/p4c-guest-base.ids" "$TOASTRE" 2 p4c-guest && ctlbanner=yes
blog_since "$L1" > "$OUT/p4c-blog.txt"
ctlskip=$(grep -ca "skip id=" "$OUT/p4c-blog.txt" || true)
ctlsent=$(grep -ca "SENT" "$OUT/p4c-blog.txt" || true)
dismiss_toasts "$CTLAUMID"   # the control toast is a persistent reminder - clear it
if [ "$ctlbanner" = yes ] && [ "$ctlsent" = 0 ]; then
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
crev=$(raspush guest/a0-consent.ps1 "-Value Deny" a0x1$RANDOM | tr -d '\r' | grep -aoE 'CONSENT-NOW=[^ ]+' | tail -1)
if [ "$crev" != "CONSENT-NOW=Deny" ]; then
  cap "$OUT" p6a-noconsent "$R"; verdict P6a "INSTRUMENT consent revoke did not land ($crev) - fail-open test invalid, NOT a bridge verdict"
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
  sent6=$(blog_since "$L2" 2>/dev/null | grep -ca "SENT id=.*OK" || true)
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

log "P6b: restore consent -> bridge recovers"
raspush guest/a0-consent.ps1 "-Value Allow" a0x3$RANDOM >/dev/null 2>&1
rec=""
for i in $(seq 1 30); do   # <=150s: supervise 5s + 60s throttle + connect
  L3=$(blog_len); blog_since 0 > "$OUT/p6b-blog.txt"
  tail -20 "$OUT/p6b-blog.txt" | grep -qa "connected (server version" && \
    [ "$(hb_state)" = PRESENT ] && { rec=1; break; }
  sleep 5
done
if [ -n "$rec" ]; then
  # recovery cleared suppression (reconnect), so re-earn it with a warm-up (lazy suppression)
  Lw2=$(blog_len); fire_info "A0T recov-warmup" > /dev/null 2>&1
  for i in $(seq 1 15); do blog_since "$Lw2" | grep -qa "SENT id=.*OK" && break; sleep 2; done
  sleep 3
  L4=$(blog_len)
  snap_or "$TOASTRE" p6b-guest-base > "$OUT/p6b-guest-base.ids"
  fire_info "A0T recovered" > /dev/null 2>&1
  sent=""
  for i in $(seq 1 15); do blog_since "$L4" | grep -qa "SENT id=.*OK" && { sent=1; break; }; sleep 2; done
  gb=no; new_or_window "$OUT/p6b-guest-base.ids" "$TOASTRE" 2 p6b-guest && gb=yes
  [ -n "$sent" ] && [ "$gb" = no ] && verdict P6b "PASS recovery: bridged again + re-suppressed after consent restore" \
    || verdict P6b "FAIL recovery sent=${sent:-no} guestbanner=$gb"
else
  verdict P6b "FAIL bridge never recovered after consent restore"
fi

log "P6c: kill the relay -> banners restored, then auto-reconnect"
# Offset BEFORE the kill: the old detector (`blog_since 0 | tail -8 | grep connected`) matched
# a STALE connected line from P6b and declared reconnect without one happening (audit
# 2026-09-05). Only lines PAST L5 count, and the bridge must log BOTH its disconnect notice
# ("connection down - banners restored", notifhost.cpp BridgeMain) and a NEW
# "connected (server version" to prove the kill->EOF->restore->reconnect path actually ran.
if ! L5=$(blog_len); then
  verdict P6c "INSTRUMENT blog_len unreadable before relay kill - no offset to anchor reconnect evidence, NOT graded"
else
  raspush guest/a0-kill-relay.ps1 "" a0k$RANDOM > "$OUT/p6c-kill.txt" 2>&1
  killed=$(grep -aoE 'KILLED-RELAY=[0-9]+' "$OUT/p6c-kill.txt" | head -1 | grep -aoE '[0-9]+$')
  log "P6c: KILLED-RELAY=${killed:-absent} $(grep -aoE 'RELAY-KILL-[A-Z]+=[^[:space:]]*' "$OUT/p6c-kill.txt" | tr '\n' ' ')"
  if [ "${killed:-0}" -lt 1 ]; then
    # nothing confirmed dead => the path under test never ran; grading it would be vacuous
    cap "$OUT" p6c-nokill "$R"
    verdict P6c "INSTRUMENT relay kill confirmed 0 kills (KILLED-RELAY=${killed:-absent}) - reconnect path never exercised, NOT a bridge verdict"
  else
    sleep 8    # reader notices EOF, banners restore; backoff first retry 5s
    recon=""
    for i in $(seq 1 10); do
      blog_since "$L5" > "$OUT/p6c-blog.txt"
      grep -qa "connection down" "$OUT/p6c-blog.txt" && \
        grep -qa "connected (server version" "$OUT/p6c-blog.txt" && { recon=1; break; }
      sleep 3
    done
    if [ -n "$recon" ]; then
      L6=$(blog_len)
      snap_or "$TOASTRE" p6c-guest-base > "$OUT/p6c-guest-base.ids"
      fire_info "A0T post-reconnect" > /dev/null 2>&1
      sent=""
      for i in $(seq 1 15); do blog_since "$L6" | grep -qa "SENT id=.*OK" && { sent=1; break; }; sleep 2; done
      [ -n "$sent" ] && verdict P6c "PASS relay killed ($killed) -> disconnect noticed -> reconnected -> bridged again" \
        || verdict P6c "FAIL no bridged send after reconnect"
    else
      verdict P6c "FAIL no NEW disconnect+reconnect after relay kill (since line $L5): $(tail -4 "$OUT/p6c-blog.txt" | tr '\n' ';')"
    fi
  fi
fi

# ---------- P7 politeness ------------------------------------------------------------------
log "P7: burst of 5 -> all accounted, one connection"
L7=$(blog_len)
conncount0=$(blog_since 0 | grep -ca "connected (server version" || true)
for i in 1 2 3 4 5; do fire_info "A0T burst $i" > /dev/null 2>&1; done
sleep 25
blog_since "$L7" > "$OUT/p7-blog.txt"
tot=0
coal=$(grep -aoE 'SENT coalesced x[0-9]+' "$OUT/p7-blog.txt" | grep -aoE '[0-9]+$' | paste -sd+ | bc 2>/dev/null || echo 0)
ind=$(grep -ca "SENT id=" "$OUT/p7-blog.txt" || true)
tot=$(( ${coal:-0} + ${ind:-0} ))
conncount1=$(blog_since 0 | grep -ca "connected (server version" || true)
if [ "$tot" -ge 5 ] && [ "$conncount1" = "$conncount0" ]; then
  verdict P7 "PASS burst: $tot accounted (coalesced=$coal individual=$ind), connection reused"
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
# bridge must NOT come up (gate forced off); allow a generous window then confirm no heartbeat
hbseen=""
for i in $(seq 1 20); do
  [ "$(hb_state)" = PRESENT ] && { hbseen=1; break; }; sleep 5
done
L8=$(blog_len) || { log "P8 WARN: blog_len unreadable after retries - using a high sentinel so the fresh-forward count reads 0 (never the whole-log residue) and P8 can only fail on a REAL fresh forward, not stale P7 data"; L8=1000000000; }
snap_or "$TOASTRE" p8-guest-base > "$OUT/p8-guest-base.ids"
fire_info_p "A0T legacy" > /dev/null 2>&1   # persistent: geom must catch the o-r window
lgwin=no; new_or_window "$OUT/p8-guest-base.ids" "$TOASTRE" 2 p8-guest && lgwin=yes
lgsent=$(blog_since "$L8" 2>/dev/null | grep -ca "SENT" || true)
sb8=$(showbanner); log "P8 introspection: $sb8 (=0 with no bridge -> a LEFTOVER suppression the disabled bridge never restored, a REAL product bug; =absent -> legacy toast took the window path or did not fire)"
dismiss_toasts
if [ -z "$hbseen" ] && [ "$lgwin" = yes ] && [ "${lgsent:-0}" = 0 ]; then
  verdict P8 "PASS legacy-toasts: bridge did NOT run (no heartbeat), toast took the window path, no forward ($sb8)"
else
  cap "$OUT" p8 "$R"; verdict P8 "FAIL legacy-toasts hbseen=${hbseen:-no} windowpath=$lgwin sent-lines=${lgsent:-?} $sb8"
fi
qvm-features --unset "$VM" service.legacy-toasts 2>/dev/null || true

# ---------- wrap ---------------------------------------------------------------------------
cap "$OUT" final "$R" || true
blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
# Count FAIL *and* INSTRUMENT: an INSTRUMENT verdict means a phase was never actually exercised
# (fire never fired, consent never revoked, blog_len unreadable, 0 relay kills) - "missing data
# fails", so the overall exit code the caller gates on must NOT read green when a phase was ungraded
# (audit 2026-09-05: the old `grep -c FAIL` let an unexercised P6c exit 0).
fails=$(grep -cE 'FAIL|INSTRUMENT' "$OUT/verdicts.txt" || true)
log "=== done: $fails FAIL/INSTRUMENT line(s); evidence in $OUT; subject $VM left running for inspection ==="
[ "${fails:-0}" = 0 ]
