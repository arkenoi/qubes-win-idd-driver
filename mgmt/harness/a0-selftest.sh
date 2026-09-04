#!/bin/bash
# A0-SELFTEST — the toast-bridge INSTRUMENT-VALIDATION FLOOR, run BEFORE a0-toast-bridge.sh.
#
#   mgmt/harness/a0-selftest.sh <release-setup-dir> [subject] [base]
#       subject default win10-a0tb-floor, base default win10-base
#
# WHY THIS EXISTS: the 2026-09-04/05 acceptance run burned ~1 h with THREE broken instruments
# (blog_len returned a constant 10 off the cmd banner; heartbeat probes self-matched their own
# echoed command line; unconfirmed fires were graded as bridge behaviour) and nobody noticed
# until the post-mortem audit. This floor exercises EVERY instrument in mgmt/harness/a0-lib.sh
# ONCE - the SAME sourced code the full harness runs, not a copy - against the same primed-subject
# shape, each check emitting one `SELFTEST <name> PASS|FAIL <evidence>` line and each ABLE to
# fail. An instrument bug now costs this run, not the marathon. It validates INSTRUMENTS ONLY:
# it renders no bridge verdicts (a0-toast-bridge.sh's job) and runs none of the P4-P8 phases.
#
# Experiment plan (the experimenter five lines):
#   HYPOTHESIS: every probe in a0-lib.sh, pointed at a live primed subject with the bridge
#     enabled exactly as P3 enables it, returns the signal it claims to measure; refuted per
#     check by a wrong/empty/constant reading (blog_len_is_real alone would have caught the
#     constant-10 bug: a constant count cannot grow across a confirmed forwarded fire).
#   BASELINE: each discriminator runs against ground truth in BOTH directions - cmd.exe as the
#     always-present file with an ancient mtime, a never-existing path, a just-written
#     ProgramData file as the fresh-mtime subject, a confirmed-FIRED toast as the log-growth
#     stimulus - so every PASS was seen next to the reading that would FAIL it.
#   VARIABLE: none across checks - ONE subject, ONE enablement (gate feature + allowlist + one
#     cold boot); each check reads a different instrument on that fixed state.
#   INSTRUMENT: the SELFTEST lines themselves plus raw captures in $OUT (fire transcripts,
#     kill-relay output, bridge.log slices, geom dumps). The instruments ARE the subject here,
#     so their raw output is kept, never piped to /dev/null.
#   BUDGET: prime <=3600s (typical 5-10 min) + Active-session settle <=1200s (measured 12+ min
#     on a fresh prime - the swing item) + ONE cold boot <=900s + checks ~8-12 min. Typical
#     15-30 min, hard ceiling ~60 min (caller watchdog). Terminal states: prime rc!=0, no user
#     session, recovery screen (e2e-wait detects). Every poll below is bounded; transients are
#     retried once with the error text logged, never discarded.
#
# Evidence: scratchpad/a0-selftest-<UTC>/ (gitignored - internal never enters the repo).
# Exit nonzero if ANY check fails. The subject is LEFT RUNNING for the full run to reuse or
# replace (the full harness's P0 all-Halted gate is the coordinator's to satisfy).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

SETUP="${1:?usage: a0-selftest.sh <release-setup-dir> [subject] [base]}"
VM="${2:-win10-a0tb-floor}"
BASE="${3:-win10-base}"

TS=$(date -u +%Y%m%d-%H%M%S)
OUT="scratchpad/a0-selftest-$TS"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest
source .claude/skills/win-guest-e2e/e2e-lib.sh
source mgmt/harness/e2e-wait.sh
source mgmt/harness/a0-lib.sh                  # the instruments under test - the REAL ones

FAILS=0
st(){ # $1=check-name $2=PASS|FAIL $3...=one-line evidence
  local name=$1 v=$2; shift 2
  local line="SELFTEST $name $v $*"
  printf '%s\n' "$line" >> "$OUT/selftest.txt"
  printf '%s\n' "$line" | tee -a "$R"
  [ "$v" = PASS ] || FAILS=$((FAILS+1))
}
fatal(){ log "FATAL $*"; log "=== ABORT before the checks: instruments are UNVALIDATED, do NOT start the full run ==="; exit 2; }
# Transient self-heal (experimenter rule 11): retry ONCE after 10 s if a probe returned empty,
# and KEEP the error text. log inside a $(...) capture would contaminate the caller's variable,
# so its output is pushed to stderr here.
retry_empty(){ # $1=label, rest=command; echoes stdout, one retry on empty
  local lbl=$1; shift
  local out; out=$("$@")
  if [ -z "$out" ]; then
    log "TRANSIENT: $lbl returned empty (QRC=${QRC:-?} err=$(head -c 200 "$QERR" 2>/dev/null | tr '\n' ' ')); retrying once in 10s" >&2
    sleep 10; out=$("$@")
  fi
  printf '%s' "$out"
}

log "=== A0 selftest floor: subject=$VM base=$BASE setup=$SETUP out=$OUT ==="

# ---------- S0 preflight (mirror of the full harness's P0) ---------------------------------
for f in guest/run-as-user.ps1 guest/fire-demo-toast.ps1 guest/dismiss-toast.ps1 \
         guest/a0-consent.ps1 guest/a0-showbanner.ps1 guest/a0-kill-relay.ps1 \
         tools/qtest tools/qtest-geom mgmt/harness/prime-run.sh; do
  [ -e "$f" ] || fatal "missing $f"
done
[ -d "$SETUP" ] || fatal "setup dir $SETUP missing"
[ -f "$SETUP/MANIFEST.json" ] && cp "$SETUP/MANIFEST.json" "$OUT/" && log "manifest: $(head -c 400 "$SETUP/MANIFEST.json")"
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2!="Halted" && $1 ~ /^(win(10|11)|prime-)/ {print $1}')
[ -z "${running// /}" ] || fatal "not all Halted: $running (VM-mutating jobs run serially)"

# ---------- S1 prime ONE guest --------------------------------------------------------------
log "S1: prime-run $BASE -> $VM (job ours, payload $SETUP)"
./mgmt/harness/prime-run.sh "$BASE" "$VM" ours --payload "$SETUP" > "$OUT/prime.log" 2>&1
rc=$?
[ $rc -eq 0 ] || fatal "prime-run rc=$rc (tail: $(tail -3 "$OUT/prime.log" | tr '\n' ' '))"
w_usersession "$VM" 900 s1-session "$OUT" log || fatal "no user session after prime"
log "S1: primed and session up"

# ---------- S2 file/heartbeat discriminators, both directions -------------------------------
# These need only the SYSTEM qrexec channel, so they run before the Active-session settle.
log "S2: path_state + hb_fresh against ground-truth subjects"
p_yes=$(retry_empty path_state-present path_state 'C:\Windows\System32\cmd.exe')
p_no=$(retry_empty path_state-absent path_state 'C:\ProgramData\qubes-toast-bridge\__nope_floor_marker__')
if [ "$p_yes" = PRESENT ] && [ "$p_no" = ABSENT ]; then
  st path_state_both PASS "cmd.exe->$p_yes nonexistent->$p_no"
else
  st path_state_both FAIL "cmd.exe->'$p_yes' nonexistent->'$p_no' - probe cannot tell a file from no file (self-match/echo/marshalling regression)"
fi

qrun "cmd /c echo x> C:\\ProgramData\\__a0floor_hb__" >/dev/null 2>&1
h_fresh=$(retry_empty hb_fresh-fresh hb_fresh 'C:\ProgramData\__a0floor_hb__' 120)
h_stale=$(retry_empty hb_fresh-stale hb_fresh 'C:\Windows\System32\cmd.exe' 30)
qrun "cmd /c del C:\\ProgramData\\__a0floor_hb__" >/dev/null 2>&1
if [ "$h_fresh" = PRESENT ] && [ "$h_stale" = ABSENT ]; then
  st hb_fresh_both PASS "just-written->$h_fresh ancient-mtime(max30s)->$h_stale"
else
  st hb_fresh_both FAIL "just-written->'$h_fresh' ancient-mtime->'$h_stale' - freshness probe would accept a stale heartbeat as a live bridge (the P8 false-fail class)"
fi

# ---------- S3 fire-path readiness (P1d shape: Active session, then one confirmed fire) -----
# run-as-user.ps1 refuses (exit 3) until `query user` shows an Active session - on a fresh prime
# that is 12+ min after qrexec answers. Poll the ACTUAL precondition, cheaply, then prove one
# real fire. Without this gate every later FAIL would be a session artifact, not an instrument
# reading.
log "S3: waiting for an Active interactive session (query user), up to ~20 min"
s3_active=""; qu=""
for i in $(seq 1 40); do
  qu=$(qrun 'query user' 2>&1 | tr -d '\r')
  if printf '%s' "$qu" | grep -qE '[[:space:]]Active([[:space:]]|$)'; then
    s3_active=1; log "S3: Active session after ~$((i*30))s"; break
  fi
  sleep 30
done
[ -n "$s3_active" ] || { printf '%s\n' "$qu" > "$OUT/s3-lastquser.txt"; fatal "no Active session in ~20 min; last query user: $(printf '%s' "$qu" | tr '\n' '|' | head -c 200)"; }
fout=$(fire_raw "-Title 'A0F warmup'" "aw$RANDOM"); printf '%s\n' "$fout" > "$OUT/s3-warmup-fire.txt"
printf '%s' "$fout" | grep -a 'FIRED' | grep -qav 'never confirmed FIRED' \
  || fatal "session Active but warmup fire never FIRED (see $OUT/s3-warmup-fire.txt)"
log "S3: fire path READY (confirmed FIRED, gate still off)"
dismiss_toasts

# ---------- S4 enable the bridge exactly like P3, ONE cold boot -----------------------------
log "S4: enable gate + allowlist, cold boot (P3 shape)"
qvm-features "$VM" service.notify-bridge 1 || fatal "qvm-features notify-bridge failed"
qrun "reg add \"HKLM\\SOFTWARE\\Invisible Things Lab\\Qubes Tools\\gui-agent\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$PSAUMID\" /f" >/dev/null
timeout -k 8 60 ./tools/qtest shutdown >/dev/null 2>&1
w_halt "$VM" 300 s4-halt log || { QTEST_VM=$VM timeout -k 8 30 ./tools/qtest kill >/dev/null 2>&1; sleep 5; }
timeout -k 8 60 ./tools/qtest start >/dev/null 2>&1
w_usersession "$VM" 900 s4-session "$OUT" log || fatal "no user session after cold boot"

# ---------- S5 hb_state_up: heartbeat PRESENT while the bridge runs -------------------------
# Agent launches the bridge on shell-up (5s supervise cadence); 150s is P3's own budget. FAILs
# if the bridge never runs OR the freshness probe (validated both ways in S2) misreads it.
hb=""; hbt=""
for i in $(seq 1 30); do hb=$(hb_state); [ "$hb" = PRESENT ] && { hbt=$((i*5)); break; }; sleep 5; done
if [ "$hb" = PRESENT ]; then
  st hb_state_up PASS "heartbeat fresh ~${hbt}s after cold-boot session-up"
else
  st hb_state_up FAIL "heartbeat never PRESENT within 150s (last='$hb') - bridge not running with gate on, or probe blind; bridge-dependent checks below will fail dependently"
fi

# ---------- S6 connected (gating wait, logged; graded via fire_confirms/killrelay) ----------
conn=""
for i in $(seq 1 15); do
  blog_since 0 > "$OUT/s6-blog.txt"
  grep -qa "connected (server version" "$OUT/s6-blog.txt" && { conn=1; break; }; sleep 4
done
[ -n "$conn" ] && log "S6: bridge connected" \
  || log "S6: WARN no 'connected (server version' in $((15*4))s (tail: $(tail -3 "$OUT/s6-blog.txt" 2>/dev/null | tr '\n' ';' | head -c 200)) - fire_confirms/killrelay below will surface it"

# ---------- S7 the marquee: ONE persistent first fire serves three checks -------------------
# Lazy suppression makes toast #1 per app the ONLY toast that both BANNERS and FORWARDS (toast
# #2+ is suppressed after the first successful forward). So blog_len_is_real, fire_confirms and
# window_caught MUST share this single first fire: sequential separate fires would false-FAIL
# window_caught on a correctly-suppressed second banner. fire_info_p (persistent) is the same
# fire_raw path as fire_info, persistent so the ~59s/call geom can catch the window.
log "S7: first allowlisted fire - blog_len_is_real + fire_confirms + window_caught"
Lpre=""
if ! Lpre=$(blog_len); then
  st blog_len_is_real FAIL "blog_len unreadable (nonzero rc) BEFORE the fire - no offset possible; callers defaulting this to 0 was exactly the corruption mode"
else
  log "S7: blog_len pre-fire = $Lpre"
fi
snap_or "$TOASTRE" s7-win-base > "$OUT/s7-win-base.ids"
fout=$(fire_info_p 'A0F selftest'); frc=$?
printf '%s\n' "$fout" > "$OUT/s7-fire.txt"
# fire_info_p's own failure warning contains the word FIRED ("never confirmed FIRED"), so a raw
# grep would self-match it - accept only genuine `FIRED ...` transcript lines.
fired=no
printf '%s' "$fout" | grep -a 'FIRED' | grep -qav 'never confirmed FIRED' && fired=yes

# fire_confirms: rc==0, FIRED captured, and the forward proven end to end by a SENT..OK line
# VISIBLE PAST the pre-fire offset (this also proves blog_since's Skip semantics against the
# same offset blog_len produced - the pairing the constant-10 bug silently broke).
sent=no
if [ -n "$Lpre" ]; then
  for i in $(seq 1 15); do
    blog_since "$Lpre" > "$OUT/s7-blog.txt"
    grep -qa "SENT id=.*OK" "$OUT/s7-blog.txt" && { sent=yes; break; }; sleep 2
  done
fi
if [ "$frc" -eq 0 ] && [ "$fired" = yes ] && [ "$sent" = yes ]; then
  st fire_confirms PASS "fire rc=0, FIRED line captured ($OUT/s7-fire.txt), SENT id..OK visible past offset ${Lpre}"
else
  st fire_confirms FAIL "rc=$frc fired=$fired sent=$sent offset=${Lpre:-unreadable} (fire transcript: $(printf '%s' "$fout" | tr '\n' ';' | head -c 160))"
fi

# window_caught: the same first toast must appear as a NEW o-r window vs the pre-fire baseline
# (mapped-tolerant ors) - the P2/P6/P8 window detector.
win=no
new_or_window "$OUT/s7-win-base.ids" "$TOASTRE" 2 s7-win && win=yes
if [ "$win" = yes ]; then
  st window_caught PASS "NEW o-r toast window vs baseline (geom dumps s7-win-base.txt/s7-win.txt)"
else
  st window_caught FAIL "no NEW o-r window after the first fire (fired=$fired) - detector blind, TOASTRE drifted, or the toast never bannered; see s7-win-base.txt/s7-win.txt"
fi

# blog_len_is_real: the count must have GROWN by a plausible small amount across the confirmed
# fire, and the just-counted SENT line must sit BEHIND the new offset. A constant reading (the
# old banner-matched 10) cannot grow; an overcount hides the SENT line from blog_since (caught
# above); an undercount re-shows it past the post offset (caught here). Both directions bite.
if [ -n "$Lpre" ]; then
  if Lpost=$(blog_len); then
    delta=$((Lpost - Lpre))
    blog_since "$Lpost" > "$OUT/s7-blogpost.txt"
    resent=$(grep -ca "SENT id=" "$OUT/s7-blogpost.txt" || true)
    if [ "$delta" -ge 1 ] && [ "$delta" -le 40 ] && [ "${resent:-0}" = 0 ]; then
      st blog_len_is_real PASS "pre=$Lpre post=$Lpost delta=$delta, counted SENT line hidden behind post offset - a constant/banner-matched count cannot produce this"
    else
      st blog_len_is_real FAIL "pre=$Lpre post=$Lpost delta=$delta resent-past-offset=${resent:-?} (delta=0 => constant reading a la the 10-bug; delta>40 => miscount; resent>0 => undercount; NOTE if fire_confirms also failed, the bridge may have written nothing - fix that first)"
    fi
  else
    st blog_len_is_real FAIL "blog_len unreadable (nonzero rc) AFTER the fire"
  fi
fi
dismiss_toasts   # the persistent test toast must not outlive the floor

# ---------- S8 showbanner_reads -------------------------------------------------------------
sb=$(retry_empty showbanner showbanner)
if printf '%s' "$sb" | grep -qaxE 'SHOWBANNER-NOW=(absent|0|1)'; then
  st showbanner_reads PASS "$sb (after a forwarded first toast, 0 = suppression earned)"
else
  st showbanner_reads FAIL "unparseable/empty reading '$sb' - run-as-user no-op or the SHOWBANNER-NOW token drifted"
fi

# ---------- S9 killrelay_truthful -----------------------------------------------------------
# The rewritten role-based kill must CONFIRM >=1 kill, and the bridge must log its disconnect
# ("connection down") plus a FRESH "connected (server version" PAST a pre-kill offset - the
# vacuous KILLED-RELAY=0 pass and the stale-connected-line pass are both unreachable here.
if ! Lk=$(blog_len); then
  st killrelay_truthful FAIL "blog_len unreadable before the kill - no offset to anchor reconnect evidence"
else
  raspush guest/a0-kill-relay.ps1 "" "ak$RANDOM" > "$OUT/s9-kill.txt" 2>&1
  killed=$(grep -aoE 'KILLED-RELAY=[0-9]+' "$OUT/s9-kill.txt" | head -1 | grep -aoE '[0-9]+$')
  if [ -z "$killed" ]; then
    log "TRANSIENT: kill-relay returned no KILLED-RELAY line (raw: $(head -c 200 "$OUT/s9-kill.txt" | tr '\n' ';')); retrying once in 10s"
    sleep 10
    raspush guest/a0-kill-relay.ps1 "" "ak$RANDOM" > "$OUT/s9-kill2.txt" 2>&1
    killed=$(grep -aoE 'KILLED-RELAY=[0-9]+' "$OUT/s9-kill2.txt" | head -1 | grep -aoE '[0-9]+$')
  fi
  recon=no
  if [ "${killed:-0}" -ge 1 ] 2>/dev/null; then
    sleep 8   # reader notices EOF, banners restore; backoff first retry 5s
    for i in $(seq 1 12); do
      blog_since "$Lk" > "$OUT/s9-blog.txt"
      grep -qa "connection down" "$OUT/s9-blog.txt" && \
        grep -qa "connected (server version" "$OUT/s9-blog.txt" && { recon=yes; break; }
      sleep 3
    done
  fi
  if [ "${killed:-0}" -ge 1 ] 2>/dev/null && [ "$recon" = yes ]; then
    st killrelay_truthful PASS "KILLED-RELAY=$killed + NEW 'connection down' + fresh 'connected (server version' past offset $Lk"
  else
    st killrelay_truthful FAIL "killed='${killed:-absent}' recon=$recon (0/absent = role-based kill found no relay, vacuous; no down+reconnect past $Lk = kill did not sever the live connection) markers: $(grep -haoE 'RELAY-KILL-[A-Z]+=[^[:space:]]*' "$OUT"/s9-kill*.txt 2>/dev/null | tr '\n' ' ' | head -c 200)"
  fi
fi

# ---------- S10 consent_roundtrip -----------------------------------------------------------
# Both directions must READ BACK (the P6a corruption was a silently-failed revoke). Deny->Allow
# completes in seconds; the running bridge polls consent every 60s (notifhost.cpp nextConsent)
# so it usually never notices - if it does, it exits FATAL and the agent relaunches within ~75s
# (S11 covers that). The Allow restore is attempted UNCONDITIONALLY, even after a failed Deny.
consent_set(){ # $1=Allow|Deny -> echoes CONSENT-NOW=... (or nothing); raw kept in consent.raw
  raspush guest/a0-consent.ps1 "-Value $1" "ac$RANDOM" 2>>"$OUT/consent.raw" \
    | tee -a "$OUT/consent.raw" | tr -d '\r' | grep -aoE 'CONSENT-NOW=[^ ]+' | tail -1
}
cdeny=$(consent_set Deny)
[ -n "$cdeny" ] || { log "TRANSIENT: consent Deny read back nothing (raw in consent.raw); retrying once in 10s"; sleep 10; cdeny=$(consent_set Deny); }
callow=$(consent_set Allow)
[ -n "$callow" ] || { log "TRANSIENT: consent Allow read back nothing (raw in consent.raw); retrying once in 10s"; sleep 10; callow=$(consent_set Allow); }
if [ "$cdeny" = "CONSENT-NOW=Deny" ] && [ "$callow" = "CONSENT-NOW=Allow" ]; then
  st consent_roundtrip PASS "Deny read back, then Allow restored"
else
  st consent_roundtrip FAIL "deny->'$cdeny' allow->'$callow' (silent run-as-user no-op or hive write failed; verify consent is Allow before any full run)"
fi

# ---------- S11 leave the subject usable (log-only courtesy, not a check) -------------------
log "S11: if the 60s consent poll caught the Deny sample the bridge exited FATAL; waiting <=150s for a live heartbeat so the subject is handed off healthy"
hbend=""
for i in $(seq 1 30); do [ "$(hb_state)" = PRESENT ] && { hbend=1; break; }; sleep 5; done
[ -n "$hbend" ] && log "S11: bridge heartbeat live" \
  || log "S11: WARN heartbeat not back within 150s - the full run's P3 cold-boots anyway; noting, not failing"

# ---------- wrap ---------------------------------------------------------------------------
log "=== SELFTEST lines ==="
cat "$OUT/selftest.txt" | tee -a "$R"
log "=== done: $FAILS FAIL line(s); evidence in $OUT; subject $VM LEFT RUNNING for the full run ==="
[ "$FAILS" -eq 0 ]
