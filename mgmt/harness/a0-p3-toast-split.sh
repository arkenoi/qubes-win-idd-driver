#!/bin/bash
# A0-P3-TOAST-SPLIT — acceptance SKELETON for the Phase 3 per-toast split (P3d).
#
#   mgmt/harness/a0-p3-toast-split.sh <release-setup-dir> [subject] [base]
#       subject default win10-p3ts, base default win10-base
#
# STATUS: SKELETON, NOT RUNNABLE YET. It grades P3c code (docs/DESIGN-p3-classifier-impl.md)
# that is deliberately NOT written until the P3a rig gate passes (DESIGN-toast-bridge.md:608-609).
# Every assert that needs the unlanded code is tagged "TODO(P3C)"; the guard right below refuses
# to run until an operator flips P3C_READY=1 (and the TODO tags have been reviewed against the
# landed implementation — grep 'TODO(P3C)' must come up empty of surprises first).
# Prerequisites the guard names:
#   - notifhost with NotifyBridgeMixed + CLASSIFY/VREQ lines (design §1,2,4)
#   - gui-agent with the verdict hold + TOASTDROP/TOASTVERDICT lines (design §3,4)
#   - guest/fire-demo-toast.ps1 -Long (design §8; the persistent-INFORMATIONAL fixture —
#     -Persistent classifies WINDOW under Phase 3, exactly as fire-demo-toast.ps1:17-19 predicted)
#
# Experiment plan (the experimenter five lines):
#   HYPOTHESIS: with service.notify-bridge=1 + NotifyBridgeMixed=[PS AUMID] (and the PS AUMID
#     NOT in NotifyBridgeAllow), an INFORMATIONAL toast from that AUMID bridges (bridge.log
#     SENT..OK + CLASSIFY verdict=bridge + agent TOASTDROP, NO new guest o-r window) while a
#     REAL-CHOICE toast from the SAME AUMID stays a guest o-r window (zero SENT, CLASSIFY
#     verdict=window) — the split A0's per-app allowlist cannot express. Every injected fault
#     (DB unreadable, bridge stopped, consent revoked) routes to the WINDOW path, never
#     bannerless-and-unforwarded; ShowBanner is NEVER 0 for a mixed AUMID. Refuted if any
#     mixed toast is lost, any direction inverts, or a fault yields silence on both paths.
#   BASELINE: Q1 runs the A0 behaviour FIRST on the same primed guest with Mixed EMPTY —
#     the no-regression guard AND the proof that Phase 3 is dormant until armed.
#   VARIABLE: one per phase — Q1 mixed-empty / Q2 mixed-armed split / Q3 one fault at a time
#     (each restored before the next) / Q4 ambiguity+burst / Q5 cold-boot + legacy-toasts.
#   INSTRUMENT: a0-lib.sh verbatim (blog_len/blog_since offsets, fire_*, showbanner, geom o-r
#     diffs via snap_or/new_or_window) + NEW HERE: classify_since (CLASSIFY lines past an
#     offset), amark/asince (gui-agent log offset + pattern hits, the rnd-shell-surfaces
#     AGENTMARK idiom). Detectors seen-to-fail: Q1 proves CLASSIFY absent when dormant (so
#     Q2's CLASSIFY hits mean something), Q2's two arms fail each other's detectors (SENT
#     fires where window must not, and vice versa), Q3 faults each flip a Q2-proven PASS.
#   BUDGET: prime <=3600s; 3 cold boots; geom is ~59s/call (a0-toast-bridge.sh BUDGET note),
#     so window-path positives use -RealChoice (persistent) or -Long (~25s, best-effort geom;
#     the deterministic window-path detector is CLASSIFY verdict=window + zero SENT).
#     Total ~90-120 min; overall watchdog is the caller's job (>=150 min).
#
# Evidence: scratchpad/a0-p3-toast-split-<UTC>/ (gitignored - internal never enters the repo).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

# ---------- runnability guard (remove by flipping P3C_READY=1 once P3c has landed) ----------
if [ "${P3C_READY:-0}" != 1 ]; then
  echo "REFUSING TO RUN: this is the P3d SKELETON; the P3c code it grades is not landed." >&2
  echo "Needs: notifhost NotifyBridgeMixed+CLASSIFY/VREQ, agent verdict-hold+TOASTDROP," >&2
  echo "       fire-demo-toast.ps1 -Long. Review every 'TODO(P3C)' below against the landed" >&2
  echo "       code, then rerun with P3C_READY=1." >&2
  exit 3
fi

SETUP="${1:?usage: a0-p3-toast-split.sh <release-setup-dir> [subject] [base]}"
VM="${2:-win10-p3ts}"
BASE="${3:-win10-base}"

TS=$(date -u +%Y%m%d-%H%M%S)
OUT="${P3_OUT:-scratchpad/a0-p3-toast-split-$TS}"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
verdict(){ log "VERDICT $1: $2"; echo "$1|$2" >> "$OUT/verdicts.txt"; }

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
source .claude/skills/win-guest-e2e/e2e-lib.sh
source mgmt/harness/e2e-wait.sh
source mgmt/harness/a0-lib.sh   # PSAUMID CTLAUMID QT BLOG blog_len/blog_since fire_* showbanner geom ors snap_or new_or_window dismiss_toasts

log "=== P3 toast-split acceptance: subject=$VM base=$BASE setup=$SETUP out=$OUT ==="

# ---------- extra instruments (P3-specific; same self-test discipline as a0-lib) ------------
GACFG='HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
# A harmless placeholder so ReadAllowlist's compiled DEFAULT_ALLOW seed (notifhost.cpp:274-280)
# never kicks in while we test the mixed tier (an empty Allow value falls back to the seed).
ALLOW_PLACEHOLDER='QubesP3TS.None.Placeholder'
WPNDB='C:\Users\user\AppData\Local\Microsoft\Windows\Notifications\wpndatabase.db'

# CLASSIFY lines past a bridge.log offset (format contract: DESIGN-p3-classifier-impl.md §4:
#   CLASSIFY id=.. aumid=.. row=N verdict=window|bridge corr=.. src=live reason=..)
classify_since(){ # $1=old blog line count; prints CLASSIFY lines
  blog_since "$1" | grep -a 'CLASSIFY '
}

# gui-agent log offset + since (the rnd-shell-surfaces AGENTMARK idiom: LogDir from the QWT
# registry key, newest gui-agent-*.log, whole-line count / tail past mark). -EncodedCommand so
# the echoed command line can never self-match (a0-lib blog_len lesson).
_ps_enc(){ printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0; }
amark(){ # echoes current agent-log line count (0 if none)
  local ps b64
  ps="\$d=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools' -EA SilentlyContinue).LogDir; \$f=(Get-ChildItem \$d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1); if (\$f) { (@(Get-Content \$f.FullName)).Count } else { 0 }"
  b64=$(_ps_enc "$ps")
  qrun "powershell -NoProfile -EncodedCommand $b64" | tr -d '\r' | grep -aoxE '[0-9]+' | head -1
}
asince(){ # $1=mark $2=pattern; prints matching agent-log lines past the mark
  local ps b64
  ps="\$d=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools' -EA SilentlyContinue).LogDir; \$f=(Get-ChildItem \$d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1); if (\$f) { \$all=@(Get-Content \$f.FullName); if (\$all.Count -gt $1) { \$all[$1..(\$all.Count-1)] | Select-String -Pattern '$2' -SimpleMatch | ForEach-Object { \$_.Line } } }"
  b64=$(_ps_enc "$ps")
  qrun "powershell -NoProfile -EncodedCommand $b64" | tr -d '\r'
}

# TODO(P3C): -Long fixture (design §8). Until fire-demo-toast.ps1 grows it, this fails loudly.
fire_long(){ fire_raw "-Long -Title '$1'" "p3l$RANDOM" || { log "INSTRUMENT: fire_long '$1' never confirmed FIRED - a FAIL below is an instrument miss, NOT bridge behaviour"; return 1; }; }
# Real-choice from the MIXED (PS) AUMID - the same-app control the whole phase exists for.
fire_rc_ps(){ fire_raw "-RealChoice -Aumid $PSAUMID -Title '$1'" "p3r$RANDOM" || { log "INSTRUMENT: fire_rc_ps '$1' never confirmed FIRED - a FAIL below is an instrument miss, NOT bridge behaviour"; return 1; }; }

coldboot(){ # $1=phase tag; shutdown -> start -> user session
  timeout -k 8 60 ./tools/qtest shutdown >/dev/null 2>&1
  w_halt "$VM" 300 "$1-halt" log || { QTEST_VM=$VM timeout -k 8 30 ./tools/qtest kill >/dev/null 2>&1; sleep 5; }
  timeout -k 8 60 ./tools/qtest start >/dev/null 2>&1
  w_usersession "$VM" 900 "$1-session" "$OUT" log
}
bridge_up(){ # wait for heartbeat + connected past blog offset $1; returns 0/1
  local i
  for i in $(seq 1 30); do [ "$(hb_state)" = PRESENT ] && break; sleep 5; done
  [ "$(hb_state)" = PRESENT ] || return 1
  for i in $(seq 1 15); do blog_since "$1" | grep -qa "connected (server version" && return 0; sleep 4; done
  return 1
}

# ---------- Q0 preflight + prime -----------------------------------------------------------
for f in guest/run-as-user.ps1 guest/fire-demo-toast.ps1 guest/a0-consent.ps1 \
         guest/a0-showbanner.ps1 guest/dismiss-toast.ps1 tools/qtest tools/qtest-geom \
         mgmt/harness/prime-run.sh; do
  [ -e "$f" ] || { log "FATAL missing $f"; exit 1; }
done
# TODO(P3C): preflight-grep the shipped fixture for the -Long switch so a stale guest copy
# cannot silently no-op every fire_long:
grep -q '\$Long' guest/fire-demo-toast.ps1 || { log "FATAL fire-demo-toast.ps1 has no -Long (design §8 not landed)"; exit 1; }
[ -d "$SETUP" ] || { log "FATAL setup dir $SETUP missing"; exit 1; }
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2!="Halted" && $1 ~ /^(win(10|11)|prime-)/ {print $1}')
[ -z "${running// /}" ] || { log "FATAL not all Halted: $running"; exit 1; }

log "Q0: prime-run $BASE -> $VM (job ours)"
./mgmt/harness/prime-run.sh "$BASE" "$VM" ours --payload "$SETUP" > "$OUT/prime.log" 2>&1 \
  || { log "FATAL prime-run failed: $(tail -3 "$OUT/prime.log" | tr '\n' ' ')"; exit 1; }
w_usersession "$VM" 900 q0-session "$OUT" log || { log "FATAL no user session after prime"; exit 1; }

# build identity (rule 1) - same block as a0-toast-bridge.sh P1b
for exe in notifhost.exe gui-agent.exe; do
  pk=$(find "$SETUP" -name "$exe" | head -1)
  if [ -n "$pk" ]; then
    want=$(sha256sum "$pk" | awk '{print tolower($1)}')
    have=$(qrun "certutil -hashfile \"$QT\\$exe\" SHA256" | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    [ "$want" = "$have" ] || { verdict Q0 "FAIL $exe installed=$have package=$want - BUILD UNDER TEST IS WRONG"; exit 1; }
  fi
done
verdict Q0 "primed + build identity proven"

# instrument self-tests (a0-lib discipline: every probe seen to distinguish before use)
pst_yes=$(path_state 'C:\Windows\System32\cmd.exe'); pst_no=$(path_state 'C:\ProgramData\qubes-toast-bridge\__nope__')
[ "$pst_yes" = PRESENT ] && [ "$pst_no" = ABSENT ] \
  || { verdict Q0i "INSTRUMENT path_state present='$pst_yes' absent='$pst_no' - aborting"; exit 1; }
am=$(amark)
[ -n "$am" ] || { verdict Q0i "INSTRUMENT amark returned nothing (agent LogDir probe broken) - aborting"; exit 1; }
# asince must be able to MISS (pattern that cannot occur) and to HIT (a line every boot logs).
ahit=$(asince 0 'seamless'); amiss=$(asince 0 '__p3ts_never__')
{ [ -n "$ahit" ] && [ -z "$amiss" ]; } \
  || { verdict Q0i "INSTRUMENT asince hit='${ahit:0:40}' miss='${amiss:0:40}' - aborting"; exit 1; }
log "Q0i: instruments OK (path_state both ways, amark=$am, asince hit/miss)"

# P1d-equivalent readiness gate for the user-session fire path (verbatim rationale:
# a0-toast-bridge.sh:108-142 - the first run-as-user fire after a fresh prime no-ops for
# minutes until `query user` shows Active).
log "Q0r: waiting for an Active interactive session, up to ~20 min"
p3_active=""
for i in $(seq 1 40); do
  qrun 'query user' 2>&1 | tr -d '\r' | grep -qE '[[:space:]]Active([[:space:]]|$)' && { p3_active=1; break; }
  sleep 30
done
[ -n "$p3_active" ] || { verdict Q0r "INSTRUMENT no Active session in ~20 min - fire path unusable, aborting"; exit 1; }
fout=$(fire_raw "-Title 'P3T warmup-prime'" "warm$RANDOM"); printf '%s\n' "$fout" > "$OUT/q0-fire.txt"
printf '%s' "$fout" | grep -qa FIRED || { verdict Q0r "INSTRUMENT session Active but fire not FIRED - aborting"; exit 1; }
dismiss_toasts
verdict Q0r "fire path ready"

# ---------- Q1 baseline: mixed EMPTY => A0 behaviour, Phase 3 provably dormant --------------
log "Q1: gate on, Allow=[PSAUMID], Mixed ABSENT - the A0 regression guard + dormancy proof"
qvm-features "$VM" service.notify-bridge 1 || { log "FATAL qvm-features failed"; exit 1; }
qrun "reg add \"$GACFG\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$PSAUMID\" /f" >/dev/null
qrun "reg delete \"$GACFG\" /v NotifyBridgeMixed /f" >/dev/null 2>&1   # ensure ABSENT
coldboot q1 || { log "FATAL no session after Q1 cold boot"; exit 1; }
bridge_up 0 || { verdict Q1 "FAIL bridge never up+connected after Q1 cold boot"; exit 1; }

# A0 subset: warmup earns lazy suppression, check toast bridges with no guest banner
Lw=$(blog_len) || Lw=0
fire_info "P3T q1-warmup" > /dev/null 2>&1
for i in $(seq 1 15); do blog_since "$Lw" | grep -qa "SENT id=.*OK" && break; sleep 2; done
sleep 3; L0=$(blog_len) || L0=0
snap_or "$TOASTRE" q1-base > "$OUT/q1-base.ids"
fire_info "P3T q1-bridged" > /dev/null 2>&1
q1sent=""; for i in $(seq 1 15); do blog_since "$L0" | grep -qa "SENT id=.*OK" && { q1sent=1; break; }; sleep 2; done
q1gb=no; new_or_window "$OUT/q1-base.ids" "$TOASTRE" 2 q1-guest && q1gb=yes
[ -n "$q1sent" ] && [ "$q1gb" = no ] \
  && verdict Q1a "PASS A0 behaviour intact with mixed absent (SENT OK, no guest banner)" \
  || { cap "$OUT" q1a "$R"; verdict Q1a "FAIL A0 regression: sent=${q1sent:-no} guestbanner=$q1gb"; }

# dormancy: with Mixed absent there must be ZERO CLASSIFY lines in the whole boot's blog, and
# the agent must NOT have armed the verdict hold.
q1cl=$(classify_since 0 | grep -ca 'CLASSIFY' || true)
# TODO(P3C): 'TOASTVERDICT armed' is the design §4 init line; confirm exact text at landing.
q1arm=$(asince 0 'TOASTVERDICT armed')
if [ "${q1cl:-0}" = 0 ] && [ -z "$q1arm" ]; then
  verdict Q1b "PASS Phase 3 dormant (0 CLASSIFY lines, no TOASTVERDICT armed)"
else
  verdict Q1b "FAIL dormancy: classify_lines=$q1cl armed='${q1arm:0:60}' - mixed-empty config changed behaviour"
fi
dismiss_toasts

# ---------- Q2 headline: same-AUMID split --------------------------------------------------
log "Q2: Mixed=[PSAUMID], Allow=placeholder - informational bridges, real-choice windows, SAME app"
qrun "reg add \"$GACFG\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$ALLOW_PLACEHOLDER\" /f" >/dev/null
qrun "reg add \"$GACFG\" /v NotifyBridgeMixed /t REG_MULTI_SZ /d \"$PSAUMID\" /f" >/dev/null
coldboot q2 || { log "FATAL no session after Q2 cold boot"; exit 1; }
bridge_up 0 || { verdict Q2 "FAIL bridge never up+connected after Q2 cold boot"; exit 1; }
# TODO(P3C): assert the agent armed the hold this boot (design §3.1 init line).
q2arm=$(asince 0 'TOASTVERDICT armed')
[ -n "$q2arm" ] && log "Q2: agent verdict hold armed ($q2arm)" \
  || verdict Q2arm "FAIL agent never logged TOASTVERDICT armed with Mixed set - hold not armed"

# Q2a: informational from the mixed AUMID => bridge + drop, no new o-r window
L2=$(blog_len) || L2=0
AM2=$(amark)
snap_or "$TOASTRE" q2a-base > "$OUT/q2a-base.ids"
fire_info "P3T q2-info" > /dev/null 2>&1     # transient informational: detection is log-based
q2sent=""; for i in $(seq 1 15); do blog_since "$L2" | grep -qa "SENT id=.*OK" && { q2sent=1; break; }; sleep 2; done
classify_since "$L2" > "$OUT/q2a-classify.txt"
q2cb=$(grep -ca 'verdict=bridge' "$OUT/q2a-classify.txt" || true)
# TODO(P3C): TOASTDROP is the drop-edge proof (design §3.3/§4) - the window EXISTED and was
# deliberately not mapped; this is the deterministic no-window detector (geom is corroboration).
q2drop=$(asince "$AM2" 'TOASTDROP')
q2win=no; new_or_window "$OUT/q2a-base.ids" "$TOASTRE" 1 q2a-guest && q2win=yes   # 1 try: corroboration only
if [ -n "$q2sent" ] && [ "${q2cb:-0}" -ge 1 ] && [ -n "$q2drop" ] && [ "$q2win" = no ]; then
  verdict Q2a "PASS mixed informational bridged: SENT OK + CLASSIFY verdict=bridge + TOASTDROP + no o-r window"
else
  cap "$OUT" q2a "$R"
  verdict Q2a "FAIL sent=${q2sent:-no} classify_bridge=$q2cb drop='${q2drop:0:60}' orwin=$q2win"
fi

# Q2b: real-choice from the SAME AUMID => o-r window, ZERO sent, CLASSIFY verdict=window.
# (-RealChoice is scenario=reminder + buttons: classifier row 3 fires before row 4 - assert the
# VERDICT, not the row.)
L2b=$(blog_len) || L2b=0
snap_or "$TOASTRE" q2b-base > "$OUT/q2b-base.ids"
fire_rc_ps "P3T q2-choice" > /dev/null 2>&1
q2bwin=no; new_or_window "$OUT/q2b-base.ids" "$TOASTRE" 2 q2b-guest && q2bwin=yes
sleep 6   # let a wrong forward land before asserting none did
q2bsent=$(blog_since "$L2b" | grep -ca "SENT id=.*OK" || true)
classify_since "$L2b" > "$OUT/q2b-classify.txt"
q2bcw=$(grep -ca 'verdict=window' "$OUT/q2b-classify.txt" || true)
dismiss_toasts "$PSAUMID"
if [ "$q2bwin" = yes ] && [ "${q2bsent:-0}" = 0 ] && [ "${q2bcw:-0}" -ge 1 ]; then
  verdict Q2b "PASS same-AUMID real-choice stayed a window: o-r window, 0 SENT, CLASSIFY verdict=window"
else
  cap "$OUT" q2b "$R"; verdict Q2b "FAIL orwin=$q2bwin sent=$q2bsent classify_window=$q2bcw"
fi

# Q2c: ShowBanner spot-check - mixed NEVER suppresses (design constraint 0.3), even after a
# successful forward (the exact opposite of A0's lazy suppression, notifhost.cpp:948-953).
sb2=$(showbanner)
echo "$sb2" | grep -qa 'SHOWBANNER-NOW=0$' \
  && verdict Q2c "FAIL $sb2 - mixed app was banner-suppressed (fail-open hole: a dead bridge would now lose toasts)" \
  || verdict Q2c "PASS $sb2 (mixed app never suppressed)"

# ---------- Q3 fail-open injections, EACH seen to fail --------------------------------------
# Each fault flips a Q2a-proven PASS to the window path; each is restored (and re-proven
# working) before the next, so faults never compound and each detector is seen both ways.

log "Q3a: wpndatabase ACL-denied => DB-unreadable fail-open (design §5 #3)"
# Deny read to the user (notifhost's token) from SYSTEM; per-attempt opens (design §2.1) make
# this bite immediately - no bridge restart needed. VERIFY the deny landed before grading.
qrun "icacls \"$WPNDB\" /deny user:(R)" > "$OUT/q3a-icacls.txt" 2>&1
if ! grep -qa "Successfully processed 1" "$OUT/q3a-icacls.txt"; then
  verdict Q3a "INSTRUMENT icacls deny did not land: $(head -c 200 "$OUT/q3a-icacls.txt") - fault never injected, NOT a bridge verdict"
else
  L3a=$(blog_len) || L3a=0
  snap_or "$TOASTRE" q3a-base > "$OUT/q3a-base.ids"
  fire_long "P3T q3a-dbdenied" > /dev/null 2>&1   # -Long: informational content, ~25s banner
  q3awin=no; new_or_window "$OUT/q3a-base.ids" "$TOASTRE" 1 q3a-guest && q3awin=yes
  sleep 6
  q3asent=$(blog_since "$L3a" | grep -ca "SENT id=.*OK" || true)
  classify_since "$L3a" > "$OUT/q3a-classify.txt"
  q3acw=$(grep -ca 'verdict=window' "$OUT/q3a-classify.txt" || true)
  dismiss_toasts "$PSAUMID"
  # window path proven by CLASSIFY verdict=window (+0 SENT); geom o-r hit is corroboration
  # (25s banner vs ~59s geom call - best effort, never the gating arm).
  if [ "${q3asent:-0}" = 0 ] && [ "${q3acw:-0}" -ge 1 ]; then
    verdict Q3a "PASS DB-unreadable fails open to window (0 SENT, CLASSIFY verdict=window, orwin=$q3awin)"
  elif [ "${q3asent:-0}" = 0 ] && [ "$q3awin" = yes ]; then
    verdict Q3a "PASS DB-unreadable fails open to window (0 SENT, o-r window; CLASSIFY missing=$q3acw - check reason format)"
  else
    cap "$OUT" q3a "$R"; verdict Q3a "FAIL sent=$q3asent classify_window=$q3acw orwin=$q3awin - toast bridged or LOST with DB denied"
  fi
fi
# restore + re-prove the healthy path (fault isolation for Q3b)
qrun "icacls \"$WPNDB\" /remove:d user" >/dev/null 2>&1
L3r=$(blog_len) || L3r=0
fire_info "P3T q3a-restored" > /dev/null 2>&1
q3rok=""; for i in $(seq 1 15); do blog_since "$L3r" | grep -qa "SENT id=.*OK" && { q3rok=1; break; }; sleep 2; done
[ -n "$q3rok" ] && log "Q3a: ACL restored, bridging again (fault was the cause)" \
  || verdict Q3a-restore "FAIL bridging did not resume after ACL restore - Q3a fault not isolated"

log "Q3b: bridge stopped => verdict pipe absent => agent ceiling maps the window (design §5 #10)"
qrun "\"$QT\\notifhost.exe\" --bridge-stop" >/dev/null 2>&1
sleep 8    # bridge exits on its 2s stop poll; supervisor relaunch throttled ~60s (main.c:2406)
AM3=$(amark); L3b=$(blog_len) || L3b=0
snap_or "$TOASTRE" q3b-base > "$OUT/q3b-base.ids"
fire_long "P3T q3b-nobridge" > /dev/null 2>&1
q3bwin=no; new_or_window "$OUT/q3b-base.ids" "$TOASTRE" 1 q3b-guest && q3bwin=yes
q3bsent=$(blog_since "$L3b" 2>/dev/null | grep -ca "SENT id=.*OK" || true)
# TODO(P3C): TOASTVERDICT TIMEOUT is the ceiling-hit proof (design §3.3); exact text at landing.
q3bto=$(asince "$AM3" 'TOASTVERDICT TIMEOUT')
dismiss_toasts "$PSAUMID"
if [ "${q3bsent:-0}" = 0 ] && { [ -n "$q3bto" ] || [ "$q3bwin" = yes ]; }; then
  verdict Q3b "PASS bridge-down fails open: 0 SENT, ceiling-map (timeout='${q3bto:0:50}' orwin=$q3bwin)"
else
  cap "$OUT" q3b "$R"; verdict Q3b "FAIL sent=$q3bsent timeout='${q3bto:0:40}' orwin=$q3bwin - toast bridged or LOST with bridge down"
fi
# supervisor relaunches within ~75s; wait for health before Q3c
L3w=$(blog_len) || L3w=0
sleep 90; bridge_up "$L3w" || verdict Q3b-relaunch "FAIL bridge never relaunched after --bridge-stop"

log "Q3c: consent revoked (the a0 P6a pattern) => bridge FATAL-exits => window path (design §5 #13)"
crev=$(raspush guest/a0-consent.ps1 "-Value Deny" p3x1$RANDOM | tr -d '\r' | grep -aoE 'CONSENT-NOW=[^ ]+' | tail -1)
if [ "$crev" != "CONSENT-NOW=Deny" ]; then
  verdict Q3c "INSTRUMENT consent revoke did not land ($crev) - fault never injected, NOT a bridge verdict"
else
  qrun "\"$QT\\notifhost.exe\" --bridge-stop" >/dev/null 2>&1
  Lpre=$(blog_len) || Lpre=0
  sleep 90   # relaunched bridge must FATAL-exit on the consent selftest (notifhost.cpp:883-885)
  L3c=$(blog_len) || L3c=0
  snap_or "$TOASTRE" q3c-base > "$OUT/q3c-base.ids"
  if fire_long "P3T q3c-consent" > /dev/null 2>&1; then fired3c=1; else fired3c=; fi
  q3cwin=no; new_or_window "$OUT/q3c-base.ids" "$TOASTRE" 1 q3c-guest && q3cwin=yes
  sleep 6
  q3csent=$(blog_since "$L3c" 2>/dev/null | grep -ca "SENT id=.*OK" || true)
  fatal3c=$(blog_since "$Lpre" 2>/dev/null | grep -ca 'FATAL' || true)
  dismiss_toasts "$PSAUMID"
  if [ -z "$fired3c" ]; then
    verdict Q3c "INSTRUMENT consent-revoked toast never FIRED - cannot judge, NOT a bridge verdict"
  elif [ "${q3csent:-0}" = 0 ] && [ "$q3cwin" = yes ]; then
    verdict Q3c "PASS consent-revoked fails open: window path, 0 SENT (FATAL=$fatal3c)"
  else
    cap "$OUT" q3c "$R"; verdict Q3c "FAIL sent=$q3csent orwin=$q3cwin FATAL=$fatal3c - forwarded or LOST with consent revoked"
  fi
  # restore consent + re-prove (mirror of a0 P6b, without re-grading reconnect here)
  raspush guest/a0-consent.ps1 "-Value Allow" p3x2$RANDOM >/dev/null 2>&1
  sleep 90; bridge_up "$Lpre" || verdict Q3c-restore "FAIL bridge never came back after consent restore"
fi

log "Q3d: ShowBanner spot-check after all faults - mixed AUMID must still be absent/1, never 0"
sb3=$(showbanner)
echo "$sb3" | grep -qa 'SHOWBANNER-NOW=0$' \
  && verdict Q3d "FAIL $sb3 - a fault path suppressed a mixed app's banner" \
  || verdict Q3d "PASS $sb3"

# ---------- Q4 ambiguity bias + burst ------------------------------------------------------
log "Q4a: two same-AUMID informational back-to-back => both bridge or both window, NEVER one lost"
L4=$(blog_len) || L4=0
AM4=$(amark)
snap_or "$TOASTRE" q4-base > "$OUT/q4-base.ids"
fire_info "P3T q4-twin-1" > /dev/null 2>&1
fire_info "P3T q4-twin-2" > /dev/null 2>&1     # no settle between: this IS the ambiguity window
sleep 25
blog_since "$L4" > "$OUT/q4-blog.txt"
q4sent=$(grep -ca "SENT id=.*OK" "$OUT/q4-blog.txt" || true)
q4coal=$(grep -aoE 'SENT coalesced x[0-9]+' "$OUT/q4-blog.txt" | grep -aoE '[0-9]+$' | paste -sd+ | bc 2>/dev/null || echo 0)
q4cl=$(grep -ca 'CLASSIFY ' "$OUT/q4-blog.txt" || true)
q4drop=$(asince "$AM4" 'TOASTDROP' | grep -ca 'TOASTDROP' || true)
q4win=no; new_or_window "$OUT/q4-base.ids" "$TOASTRE" 1 q4-guest && q4win=yes
q4bridged=$(( ${q4sent:-0} + ${q4coal:-0} ))
dismiss_toasts
# Accounting: 2 classified; delivery = both bridged (2 SENT/coalesced) or both windowed
# (0 sent + window evidence). Exactly-one-of-two bridged with the other invisible = the lost
# case this phase exists to catch (design §2.4 equal-or-window; §5 #8).
if [ "${q4cl:-0}" -ge 2 ] && { [ "$q4bridged" -ge 2 ] || { [ "$q4bridged" = 0 ] && [ "$q4win" = yes ]; }; }; then
  verdict Q4a "PASS twins consistent: classified=$q4cl bridged=$q4bridged drops=$q4drop orwin=$q4win"
elif [ "$q4bridged" = 1 ]; then
  cap "$OUT" q4a "$R"; verdict Q4a "FAIL exactly ONE of two twins bridged (classified=$q4cl drops=$q4drop orwin=$q4win) - ambiguity bias violated, one may be lost"
else
  cap "$OUT" q4a "$R"; verdict Q4a "FAIL accounting: classified=$q4cl bridged=$q4bridged drops=$q4drop orwin=$q4win"
fi

log "Q4b: burst of 5 informational => all accounted through the coalesce path, one connection"
L4b=$(blog_len) || L4b=0
conn0=$(blog_since 0 | grep -ca "connected (server version" || true)
for i in 1 2 3 4 5; do fire_info "P3T q4-burst $i" > /dev/null 2>&1; done
sleep 25
blog_since "$L4b" > "$OUT/q4b-blog.txt"
b_coal=$(grep -aoE 'SENT coalesced x[0-9]+' "$OUT/q4b-blog.txt" | grep -aoE '[0-9]+$' | paste -sd+ | bc 2>/dev/null || echo 0)
b_ind=$(grep -ca "SENT id=.*OK" "$OUT/q4b-blog.txt" || true)
b_cl=$(grep -ca 'CLASSIFY ' "$OUT/q4b-blog.txt" || true)
b_tot=$(( ${b_coal:-0} + ${b_ind:-0} ))
conn1=$(blog_since 0 | grep -ca "connected (server version" || true)
dismiss_toasts
if [ "$b_tot" -ge 5 ] && [ "${b_cl:-0}" -ge 5 ] && [ "$conn0" = "$conn1" ]; then
  verdict Q4b "PASS burst: $b_tot delivered (coal=$b_coal ind=$b_ind), $b_cl classified, connection reused"
else
  verdict Q4b "FAIL burst tot=$b_tot classified=$b_cl conns $conn0->$conn1"
fi

# ---------- Q5 cold boot: persistence + legacy-toasts still wins ----------------------------
log "Q5a: cold boot - mixed routing survives (registry persists, agent re-arms)"
coldboot q5a || { verdict Q5a "FAIL no session after Q5a cold boot"; exit 1; }
bridge_up 0 || verdict Q5a "FAIL bridge not up after Q5a cold boot"
L5=$(blog_len) || L5=0
fire_info "P3T q5-persist" > /dev/null 2>&1
q5sent=""; for i in $(seq 1 15); do blog_since "$L5" | grep -qa "SENT id=.*OK" && { q5sent=1; break; }; sleep 2; done
q5cb=$(classify_since "$L5" | grep -ca 'verdict=bridge' || true)
[ -n "$q5sent" ] && [ "${q5cb:-0}" -ge 1 ] \
  && verdict Q5a "PASS mixed routing survives cold boot (SENT OK + CLASSIFY verdict=bridge)" \
  || verdict Q5a "FAIL after boot: sent=${q5sent:-no} classify_bridge=$q5cb"
dismiss_toasts

log "Q5b: service.legacy-toasts=1 forces EVERYTHING off - mixed included (a0 P8 mirror)"
qvm-features "$VM" service.legacy-toasts 1 || log "Q5b WARN: qvm-features legacy-toasts failed"
coldboot q5b || verdict Q5b "FAIL no session after Q5b cold boot"
# stale heartbeat race: delete AFTER the gate-off boot (rationale verbatim a0-toast-bridge.sh:383-394)
qrun "cmd /c del /q /f \"C:\\ProgramData\\qubes-toast-bridge\\heartbeat\" 2>nul" >/dev/null 2>&1
hb5=""; for i in $(seq 1 20); do [ "$(hb_state)" = PRESENT ] && { hb5=1; break; }; sleep 5; done
# TODO(P3C): the agent must also NOT arm the hold (legacy clears g_NotifBridge -> disarms mixed,
# design §5 #2) - a held-then-ceiling toast here would add 1.5s latency for nothing.
q5arm=$(asince 0 'TOASTVERDICT armed')
L5b=$(blog_len) || L5b=1000000000
snap_or "$TOASTRE" q5b-base > "$OUT/q5b-base.ids"
fire_long "P3T q5-legacy" > /dev/null 2>&1
q5bwin=no; new_or_window "$OUT/q5b-base.ids" "$TOASTRE" 1 q5b-guest && q5bwin=yes
q5bsent=$(blog_since "$L5b" 2>/dev/null | grep -ca "SENT" || true)
sb5=$(showbanner)
dismiss_toasts "$PSAUMID"
if [ -z "$hb5" ] && [ -z "$q5arm" ] && [ "$q5bwin" = yes ] && [ "${q5bsent:-0}" = 0 ]; then
  verdict Q5b "PASS legacy-toasts kills mixed too: no bridge, no armed hold, window path, 0 SENT ($sb5)"
else
  cap "$OUT" q5b "$R"; verdict Q5b "FAIL hbseen=${hb5:-no} armed='${q5arm:0:40}' orwin=$q5bwin sent=$q5bsent $sb5"
fi
qvm-features --unset "$VM" service.legacy-toasts 2>/dev/null || true

# ---------- wrap ---------------------------------------------------------------------------
cap "$OUT" final "$R" || true
blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
asince 0 'TOAST' > "$OUT/agent-toast-lines.log" 2>/dev/null || true
log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
# FAIL *and* INSTRUMENT both gate: an ungraded phase must never read green (a0 wrap rationale).
fails=$(grep -cE 'FAIL|INSTRUMENT' "$OUT/verdicts.txt" || true)
log "=== done: $fails FAIL/INSTRUMENT line(s); evidence in $OUT; subject $VM left running ==="
[ "${fails:-0}" = 0 ]
