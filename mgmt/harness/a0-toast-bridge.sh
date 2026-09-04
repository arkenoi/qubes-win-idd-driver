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
#   BUDGET: prime <=3600s; session waits per e2e-wait budgets; toast checks <=30s @2s; bridge
#     relaunch waits <=150s (agent supervise 5s poll + 60s throttle); overall watchdog is the
#     caller's job (launch with run_in_background + a pkill watchdog).
#
# Evidence: scratchpad/a0-toast-bridge-<UTC>/ (gitignored - internal never enters the repo).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

SETUP="${1:?usage: a0-toast-bridge.sh <release-setup-dir> [subject] [base]}"
VM="${2:-win10-a0tb}"
BASE="${3:-win10-base}"
PSAUMID='{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
CTLAUMID='Microsoft.Windows.Explorer'
QT='C:\Program Files\Qubes Tools\bin'
BLOG='C:\ProgramData\qubes-toast-bridge\bridge.log'
HBF='C:\ProgramData\qubes-toast-bridge\heartbeat'

TS=$(date -u +%Y%m%d-%H%M%S)
OUT="scratchpad/a0-toast-bridge-$TS"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
verdict(){ log "VERDICT $1: $2"; echo "$1|$2" >> "$OUT/verdicts.txt"; }

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
source .claude/skills/win-guest-e2e/e2e-lib.sh
source mgmt/harness/e2e-wait.sh

# Run a pushed script IN THE INTERACTIVE USER SESSION (listener + HKCU are session-bound).
# NEVER pass -Command with nested quotes through qtest - each hop re-splits and strips them
# (measured during the win10-app residue cleanup); -Script + -ArgsB64 survives every hop.
INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
raspush(){ # $1=repo script path, $2=args string (may be empty), $3=tag
  QTEST_VM=$VM timeout -k 8 60 ./tools/qtest push "$1" >/dev/null 2>&1
  local base b64
  base=$(basename "$1")
  b64=$(printf '%s' "$2" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  qrun "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INCOMING\\run-as-user.ps1\" -Tag $3 -Script \"$INCOMING\\$base\" ${b64:+-ArgsB64 $b64}"
}

geom(){ QTEST_VM=$VM timeout -k 8 200 ./tools/qtest-geom 2>/dev/null; }
# mapped override-redirect window lines (id x y w h or mapped name)
ors(){ awk '$6==1 && $7==1' ; }

blog_len(){ qrun "cmd /c \"type \\\"$BLOG\\\" 2>nul | find /c /v \\\"\\\"\"" | grep -aoE '[0-9]+' | head -1; }
blog_since(){ # $1 = old line count
  qrun "powershell -NoProfile -Command \"if (Test-Path '$BLOG') { Get-Content '$BLOG' | Select-Object -Skip $1 }\""
}

fire_info(){ raspush guest/fire-demo-toast.ps1 "-Title '$1'" "a0i$RANDOM"; }
fire_ctl(){ raspush guest/fire-demo-toast.ps1 "-RealChoice -Aumid $CTLAUMID -Title '$1'" "a0c$RANDOM"; }

# poll for a NEW mapped o-r window vs a baseline id set, name matching $2; returns 0 found
new_or_window(){ # $1=baseline-file $2=name-regex $3=tries(2s each) $4=save-as
  local i cur
  for i in $(seq 1 "$3"); do
    geom > "$OUT/$4.txt"
    cur=$(ors < "$OUT/$4.txt" | grep -iaE "$2" | awk '{print $1}' | sort)
    if [ -n "$cur" ] && ! diff <(echo "$cur") <(sort "$1" | comm -12 - <(echo "$cur")) >/dev/null 2>&1; then
      comm -23 <(echo "$cur") <(sort "$1") | grep -q . && return 0
    fi
    sleep 2
  done
  return 1
}
snap_or(){ # $1=name-regex $2=save-as ; prints matching ids to stdout
  geom > "$OUT/$2.txt"; ors < "$OUT/$2.txt" | grep -iaE "$1" | awk '{print $1}' | sort
}

TOASTRE='notification|demo toast|ToastHost|ShellExperienceHost|CoreWindow|A0T'
DOMRE='notifyd|notification'

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

# ---------- P2 instrument validation + gate-OFF baseline -----------------------------------
log "P2: detectors + baseline (gate off - as-installed default)"
hb=$(qrun "cmd /c \"if exist \\\"$HBF\\\" (echo YESHB) else (echo NOHB)\"" | grep -aoE 'YESHB|NOHB')
[ "$hb" = "NOHB" ] && log "P2: no heartbeat with gate off (expected)" \
  || verdict P2 "FAIL bridge heartbeat present with gate OFF"

snap_or "$DOMRE" p2-dom0-base > "$OUT/p2-dom0-base.ids"
# known-good dom0 bubble: the proven NotifyClient direct send
nc=$(find "$SETUP" -iname 'NotifyClient.exe' | head -1)
NCG="$QT\\NotifyClient.exe"
[ -n "$nc" ] || NCG=""   # fall back to ack-only detector mode if the client is not shipped
DOMDET=none
if [ -n "$NCG" ] && qrun "cmd /c \"if exist \\\"$NCG\\\" echo HAVE\"" | grep -qa HAVE; then
  qrun "\"$NCG\" --send \"A0T detector probe\" body --timeout 20" > "$OUT/p2-ncsend.txt" 2>&1 &
  ncpid=$!
  if new_or_window "$OUT/p2-dom0-base.ids" "$DOMRE" 12 p2-dom0-probe; then DOMDET=geom
  else DOMDET=ack; fi
  wait $ncpid || true
  grep -qa "OK id=" "$OUT/p2-ncsend.txt" || log "P2 WARN: NotifyClient probe not acked: $(cat "$OUT/p2-ncsend.txt")"
fi
log "P2: dom0-bubble detector mode = $DOMDET (geom=window-list visible, ack=protocol-ack only)"

# baseline toast, gate off: MUST banner in-guest, MUST NOT bridge
snap_or "$TOASTRE" p2-guest-base > "$OUT/p2-guest-base.ids"
fire_info "A0T baseline gate-off" > "$OUT/p2-fire.txt" 2>&1
if new_or_window "$OUT/p2-guest-base.ids" "$TOASTRE" 15 p2-guest-toast; then
  verdict P2 "PASS gate-off toast banners in guest (window path; detector CAN fire)"
else
  cap "$VM" p2-noshow "$OUT"; verdict P2 "FAIL gate-off toast produced no guest o-r banner - baseline broken, aborting"; exit 1
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
  hb=$(qrun "cmd /c \"if exist \\\"$HBF\\\" (echo YESHB) else (echo NOHB)\"" | grep -aoE 'YESHB|NOHB')
  [ "$hb" = "YESHB" ] && { ok=1; break; }; sleep 5
done
[ -n "$ok" ] || { cap "$VM" p3-nobridge "$OUT"; verdict P3 "FAIL bridge never heartbeat after cold boot"; exit 1; }
conn=""
for i in $(seq 1 15); do
  blog_since 0 > "$OUT/p3-blog.txt"
  grep -qa "connected (server version" "$OUT/p3-blog.txt" && { conn=1; break; }; sleep 4
done
[ -n "$conn" ] && verdict P3 "PASS cold boot: bridge up + connected" \
  || { verdict P3 "FAIL bridge up but never connected: $(tail -5 "$OUT/p3-blog.txt" | tr '\n' ';')"; exit 1; }

# ---------- P4 the split -------------------------------------------------------------------
log "P4: split - allowlisted bridges, control stays windowed"
L0=$(blog_len)
snap_or "$TOASTRE" p4-guest-base > "$OUT/p4-guest-base.ids"
snap_or "$DOMRE" p4-dom0-base > "$OUT/p4-dom0-base.ids"
fire_info "A0T bridged" > /dev/null 2>&1
sent=""
for i in $(seq 1 15); do
  blog_since "$L0" > "$OUT/p4-blog.txt"
  grep -qa "SENT id=.*OK" "$OUT/p4-blog.txt" && { sent=1; break; }; sleep 2
done
domseen="n/a"
if [ "$DOMDET" = geom ]; then
  new_or_window "$OUT/p4-dom0-base.ids" "$DOMRE" 5 p4-dom0 && domseen=yes || domseen=no
fi
guestbanner=no
new_or_window "$OUT/p4-guest-base.ids" "$TOASTRE" 3 p4-guest && guestbanner=yes
if [ -n "$sent" ] && [ "$guestbanner" = no ] && [ "$domseen" != no ]; then
  verdict P4a "PASS bridged: SENT OK, no guest banner, dom0=$domseen"
else
  cap "$VM" p4a "$OUT"; verdict P4a "FAIL sent=${sent:-no} guestbanner=$guestbanner dom0=$domseen"
fi
L1=$(blog_len)
snap_or "$TOASTRE" p4c-guest-base > "$OUT/p4c-guest-base.ids"
fire_ctl "A0T control" > /dev/null 2>&1
ctlbanner=no
new_or_window "$OUT/p4c-guest-base.ids" "$TOASTRE" 15 p4c-guest && ctlbanner=yes
blog_since "$L1" > "$OUT/p4c-blog.txt"
ctlskip=$(grep -ca "skip id=" "$OUT/p4c-blog.txt" || true)
ctlsent=$(grep -ca "SENT" "$OUT/p4c-blog.txt" || true)
if [ "$ctlbanner" = yes ] && [ "$ctlsent" = 0 ]; then
  verdict P4b "PASS control: guest banner, no bridge send (skip=$ctlskip)"
else
  cap "$VM" p4b "$OUT"; verdict P4b "FAIL control banner=$ctlbanner sent-lines=$ctlsent"
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
raspush guest/a0-consent.ps1 "-Value Deny" a0x1$RANDOM >/dev/null 2>&1
qrun "\"$QT\\notifhost.exe\" --bridge-stop" >/dev/null 2>&1
sleep 12   # bridge exits (2s poll), restores banners, deletes heartbeat
raspush guest/a0-showbanner.ps1 "" a0x2$RANDOM > "$OUT/p6-showbanner.txt" 2>&1
sb=$(grep -aoE 'SHOWBANNER-NOW=.*' "$OUT/p6-showbanner.txt" | head -1)
echo "$sb" | grep -qa 'SHOWBANNER-NOW=0$' && verdict P6a-restore "FAIL ShowBanner still 0 after bridge stop" \
  || log "P6a: ShowBanner restored ($sb)"
# agent relaunches within ~75s; relaunched bridge must EXIT on the consent selftest
sleep 90
snap_or "$TOASTRE" p6-guest-base > "$OUT/p6-guest-base.ids"
L2=$(blog_len)
fire_info "A0T consent-revoked" > /dev/null 2>&1
if new_or_window "$OUT/p6-guest-base.ids" "$TOASTRE" 15 p6-guest; then
  verdict P6a "PASS consent revoked => window path (fail-open proven by failure)"
else
  cap "$VM" p6a "$OUT"; verdict P6a "FAIL toast lost with consent revoked - FAIL-CLOSED DEFECT"
fi
blog_since "$L2" | grep -a "FATAL" > "$OUT/p6-fatal.txt" || true

log "P6b: restore consent -> bridge recovers"
raspush guest/a0-consent.ps1 "-Value Allow" a0x3$RANDOM >/dev/null 2>&1
rec=""
for i in $(seq 1 30); do   # <=150s: supervise 5s + 60s throttle + connect
  L3=$(blog_len); blog_since 0 > "$OUT/p6b-blog.txt"
  tail -20 "$OUT/p6b-blog.txt" | grep -qa "connected (server version" && \
    qrun "cmd /c \"if exist \\\"$HBF\\\" echo YESHB\"" | grep -qa YESHB && { rec=1; break; }
  sleep 5
done
if [ -n "$rec" ]; then
  L4=$(blog_len)
  snap_or "$TOASTRE" p6b-guest-base > "$OUT/p6b-guest-base.ids"
  fire_info "A0T recovered" > /dev/null 2>&1
  sent=""
  for i in $(seq 1 15); do blog_since "$L4" | grep -qa "SENT id=.*OK" && { sent=1; break; }; sleep 2; done
  gb=no; new_or_window "$OUT/p6b-guest-base.ids" "$TOASTRE" 3 p6b-guest && gb=yes
  [ -n "$sent" ] && [ "$gb" = no ] && verdict P6b "PASS recovery: bridged again after consent restore" \
    || verdict P6b "FAIL recovery sent=${sent:-no} guestbanner=$gb"
else
  verdict P6b "FAIL bridge never recovered after consent restore"
fi

log "P6c: kill the relay -> banners restored, then auto-reconnect"
qrun "powershell -NoProfile -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='notifhost.exe'\\\" | Where-Object { \\\$_.CommandLine -match '--relay' } | ForEach-Object { Stop-Process -Id \\\$_.ProcessId -Force }\"" >/dev/null 2>&1
sleep 8    # reader notices EOF, banners restore; backoff first retry 5s
L5=$(blog_len)
recon=""
for i in $(seq 1 10); do blog_since 0 | tail -8 | grep -qa "connected (server version" && { recon=1; break; }; sleep 3; done
if [ -n "$recon" ]; then
  L6=$(blog_len)
  snap_or "$TOASTRE" p6c-guest-base > "$OUT/p6c-guest-base.ids"
  fire_info "A0T post-reconnect" > /dev/null 2>&1
  sent=""
  for i in $(seq 1 15); do blog_since "$L6" | grep -qa "SENT id=.*OK" && { sent=1; break; }; sleep 2; done
  [ -n "$sent" ] && verdict P6c "PASS relay killed -> reconnected -> bridged again" \
    || verdict P6c "FAIL no bridged send after reconnect"
else
  verdict P6c "FAIL no reconnect after relay kill: $(blog_since "$L5" | tail -4 | tr '\n' ';')"
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

# ---------- wrap ---------------------------------------------------------------------------
cap "$VM" final "$OUT" || true
blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
fails=$(grep -c "FAIL" "$OUT/verdicts.txt" || true)
log "=== done: $fails FAIL line(s); evidence in $OUT; subject $VM left running for inspection ==="
[ "${fails:-0}" = 0 ]
