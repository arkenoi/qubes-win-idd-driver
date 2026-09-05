#!/bin/bash
# P3A-ETW-GATE — the Phase-3 ETW/provisioning DECISION GATE, mechanized.
# Grades docs/DESIGN-p3-classifier-impl.md §10.16 "Rig-run spec v2 — the proxy gate" AS
# PIVOTED by §10.20 (HYBRID: ETW carries a payload-FREE SIGNAL {AUMID, notificationId, tag,
# group} in a 'QTS1' frame; the bridge answers each signal with ONE TARGETED wpndatabase
# read for the payload) (+ the §10.14 provisioning asserts) against a freshly primed guest,
# and emits ONE of the §10.16.4 verdicts: PICK-ETW / FALL-TO-DB / KILL.
#
#   mgmt/harness/p3a-etw-gate.sh <release-setup-dir> [subject] [base]
#       subject default win10-p3etw, base default win10-base
#
# AUTHORED RIG-FREE (Fable, 2026-09-05) per the three-model division: this file mechanizes the
# gate; OPUS EXECUTES IT LIVE. Every guest log-line spelling below was read from the shipped
# sources (tools/notifhost/notifhost.cpp, agent/gui-agent/etwproxy.c,
# guest/provision-etwproxy-account.ps1); the ones that could NOT be verified without a run are
# tagged TODO(RIG) — Opus reconciles each against real output BEFORE trusting its verdict.
#
# HARD WATCHDOG IS THE CALLER'S JOB (this script has bounded waits but no self-timeout):
#   timeout -k 60 10800 mgmt/harness/p3a-etw-gate.sh <setup-dir>        # 180 min ceiling
#
# NOTE: the slice-map-hold A/B comparison is a SEPARATE experiment arm (main.c's uncommitted
# CropReadyForMap edit) and is deliberately OUT OF SCOPE here — one variable per run. Do not
# bolt it onto this harness; it gets its own.
#
# Experiment plan (the experimenter five lines):
#   HYPOTHESIS: the capability-grant split works end to end UNDER THE §10.20 HYBRID — a
#     zero-priv, never-PLU qubes-etwproxy token, holding ONLY the agent's per-session
#     EventAccessControl grant (TRACELOG_ACCESS_REALTIME on QubesToastBridgeEtw), can
#     OpenTrace+ProcessTrace and deliver payload-FREE SIGNAL frames {AUMID, notificationId,
#     tag, group} (QTS1) to the bridge, whose ONE TARGETED wpndb read then produces the
#     payload and classifies (corr=id-ok via the notificationId<->row-id join, corr=sig-unique
#     via the fallback), with src=etw-sig latency beating the DB rung's WAL-paced latency, for
#     unpackaged senders across all three registration methods, without perturbing A0 routing
#     (shadow is measure-only). Refuted by: proxy exit 5 (grant insufficient => FALL-TO-DB),
#     the proxy dying 0xC0000142 again (§10.20.3 L1 regression), zero signal frames on the
#     canonical method, the targeted read failing the canonical row (corr not id-ok /
#     sig-unique), src=etw-sig not beating src=db, or any A0 routing delta.
#   BASELINE: a0-toast-bridge.sh green on the SAME package (run it first — this gate assumes a
#     working A0 bridge and re-checks only a slice in T7). Within this run, T5's drift-parked
#     boot is the src=db control arm for T6's src=etw-sig measurement — same fires, tier down.
#   VARIABLE: one per phase — T2 the L1 launch + grant + signal flow (tier up), T3 the targeted
#     read + id join, T4 the launch token (SYSTEM vs user), T5 ONE injected drift (PLU
#     membership, switchable: added, proven seen, removed, tier re-proven), T6 tier up vs T5's
#     tier down, T7 nothing (invariance re-check), T8 the §10.20.5#5 fail-open drills
#     (fire+purge, twins, pipe squatter — one variable each, run last, recovery re-proven).
#   INSTRUMENT: a0-lib.sh verbatim (blog_len/blog_since offsets, path_state/hb_fresh, fire_*,
#     showbanner, dismiss_toasts) + NEW: gflen/gfsince (path-generic guest-file offsets, for
#     etw-proxy.log + the install log), amark/asince (the a0-p3-toast-split agent-log idiom),
#     enc_run (-EncodedCommand marker probes — the self-match-safe idiom), tf/tf_fire
#     (toastfire, FIRED-confirmed like fire_raw), a heartbeat mtime sampler. Each probe is
#     self-tested both directions in T0i before any verdict leans on it; each negative assert
#     names where its detector was seen to fire (T5 fires the PLU-absent detector, T4 fires the
#     proxy's own refuse machinery, T0i fires the rest).
#   BUDGET: prime <=3600s; 2 cold boots (T0 gate-on, T5 restore — the §10.16.2 boot-path
#     element); ~30 confirmed fires at ~30-60s each incl. bounded 3s-cadence log polls (<=45s
#     per fire); drift relaunch window 120s (backoff floor 5s; TODO(RIG) #7 below); T8c's
#     squatter window ~2 min hold + up to ~6 min bounded recovery wait. Total ~100-170 min.
#     Terminal states: prime TERMINAL/DEADLINE, no-user-session, T2 no-go (STOP
#     with FALL-TO-DB/KILL). Stall = any bounded poll exhausting its seq loop, always logged.
#     EVERY poll loop is seq-bounded AND wall-clock capped (owner audit 2026-09-06, after the
#     a0 P6b 32-minute stall): each guest probe rides a ~55s-hard-capped qrun/enc_run, so
#     seq*sleep alone understates a loop's ceiling by N*probe-cost. Budgets are sized to the
#     event's EXPECTED timeline, loops log which exit they took, and waits whose precondition
#     a prior failed step made impossible (a fire that never confirmed FIRED, an unreadable
#     offset) SKIP as terminal instead of burning their budget.
#
# Evidence: scratchpad/p3a-etw-gate-<UTC>/ (gitignored — internal NEVER enters the repo; the
# P3A_OUT override must likewise never point inside a tracked path).
#
# ---------------------------------------------------------------------------------------------
# TODO(RIG) REGISTER — Opus: reconcile each against live output, then delete the tag or fix:
#  #1 etw-proxy.log default dir when LogDir is unset (code: %SystemDrive%\Qubes Logs — verify).
#  #2 tasklist /fo csv "User Name" rendering for the session-0 proxy (expected <HOST>\qubes-etwproxy).
#  #3 icacls rendering of the state-dir DENY ACE (grep is deliberately loose: name + 'deny').
#  #4 T4b (plain-user arm): if the interactive token is genuinely elevated (EnableLUA=0 images),
#     the never-SYSTEM guard trips LEGITIMATELY => rc=9 there is INSTRUMENT (arm precondition
#     unmet), not FAIL — the code already grades it that way; confirm which way this image falls.
#  #5 push-vs-floor split at 15s (T3): reconcile against the observed NotificationChanged wake
#     vs the 30s floor; the raw dt is recorded either way.
#  #6 --dump-etw no-go discriminator (T2x): hybrid semantics — the tier needs a SIGNAL, not a
#     payload; the grep keys on 'aumid=1' ETWEVT lines / 'aumid_events=<n>' / the ETWDUMP
#     verdict line. Tighten from real output if the discriminator is ever exercised.
#  #7 drift-arm relaunch window (T5): 120s assumes the 5s backoff floor; if prior exits doubled
#     the backoff, widen — the wait logs the agent lines it saw either way. (T8c's recovery
#     wait inherits the same caveat, already widened to ~6 min for the squatted exits.)
#  #8 provision trailer fallback: if C:\qwt-improved-install.log is absent/rotated, re-run the
#     provisioning script from the staged setup tree (path on guest unverified) to re-print it.
#  #9 heartbeat gap bound 4s (T6) assumes the shipped 2s wake cadence; reconcile.
#  #10 SUPERSEDED by the 2026-09-05 CONSOLE SPLIT: the proxy is etwproxy.exe now, a binary
#     with NO user32/gdi32 imports and NO window station involvement anywhere. There is no
#     winsta census to grow; T2l1 instead asserts the winsta-era lines are ABSENT (the agent
#     must no longer create QubesEtwProxyWS) alongside the unchanged no-0xC0000142 assert.
#  #11 SUPERSEDED likewise: the "proxy token cannot open WinSta0" negative probe is moot -
#     the proxy links no user32, receives no winsta rights, and the agent grants none.
#  #12 T8a fire+purge race: the purge-delay ladder (200/500/1000ms) vs the WAL-paced targeted
#     read (3 attempts, ~1.5s worst) is a guess — reconcile against the observed race and tune.
#  #13 T8b twins: corr=sig-ambiguous is reachable only when the signal joins by NEITHER id nor
#     a tag-filtered fallback; both are build properties measured in T3/T8b, not assumptions.
#     If unreachable on this build, ambiguity handling stays proven by review only — Opus
#     decides whether a non-toastfire twin source can reach it.
# ---------------------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

SETUP="${1:?usage: p3a-etw-gate.sh <release-setup-dir> [subject] [base]}"
VM="${2:-win10-p3etw}"
BASE="${3:-win10-base}"

TS=$(date -u +%Y%m%d-%H%M%S)
OUT="${P3A_OUT:-scratchpad/p3a-etw-gate-$TS}"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
verdict(){ log "VERDICT $1: $2"; echo "$1|$2" >> "$OUT/verdicts.txt"; }

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
source .claude/skills/win-guest-e2e/e2e-lib.sh
source mgmt/harness/e2e-wait.sh
source mgmt/harness/a0-lib.sh   # PSAUMID CTLAUMID QT BLOG HBF INCOMING raspush blog_* path_state hb_* fire_* showbanner dismiss_toasts

log "=== P3a ETW proxy gate: subject=$VM base=$BASE setup=$SETUP out=$OUT ==="

# ---------- constants (spellings read from the shipped sources — see file header) ------------
ACCT='qubes-etwproxy'
FWRULE='QubesEtwProxy-BlockOutbound'                       # provision-etwproxy-account.ps1:86
ETWPIPE='qubes-toast-etw'                                  # qtb_shared.h kEtwProxyPipe (fixed name, §10.18 delta)
ETWSESS='QubesToastBridgeEtw'                              # qtb_shared.h kEtwBridgeSession / etwproxy.c ETWPROXY_SESSION_NAME
STATEDIR='C:\ProgramData\qubes-toast-bridge'
ILOG='C:\qwt-improved-install.log'
# toastfire default AUMIDs per registration method (tools/toastfire/README.md)
declare -A TFAUMID=( [start-shortcut]='QubesToastfire.StartShortcut'
                     [com-activator]='QubesToastfire.ComActivator'
                     [bare]='QubesToastfire.Bare' )
PLOG=""   # resolved in T1 (LogDir + \etw-proxy.log)

# ---------- extra instruments (same self-test discipline as a0-lib) --------------------------
_ps_enc(){ printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0; }
# -EncodedCommand runner: the command line the console echoes is an opaque blob, so output
# markers can never self-match (the a0-lib path_state/blog_len lesson).
enc_run(){ qrun "powershell -NoProfile -EncodedCommand $(_ps_enc "$1")"; }

# Path-generic guest-file line count / tail-past-offset (blog_len/blog_since with the path as a
# parameter — same retry, same whole-line-integer anchor, same NONZERO-on-hard-failure contract:
# callers MUST NOT default the count to 0 on failure).
gflen(){ # $1=guest path
  local i n ps
  ps="if (Test-Path -LiteralPath '$1') { (@(Get-Content -LiteralPath '$1')).Count } else { 0 }"
  for i in 1 2 3; do
    n=$(enc_run "$ps" | tr -d '\r' | grep -aoxE '[0-9]+' | head -1)
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
    sleep 2
  done
  return 1
}
gfsince(){ # $1=guest path $2=old line count. -EncodedCommand, NOT the blog_since -Command idiom:
  # PLOG may live under 'C:\Qubes Logs' (space), and a space inside a hop-requoted -Command
  # string is exactly the mangling class the a0-lib audit documented. Encoded survives every hop.
  enc_run "if (Test-Path -LiteralPath '$1') { Get-Content -LiteralPath '$1' | Select-Object -Skip $2 }"
}
plog_len(){ gflen "$PLOG"; }
plog_since(){ gfsince "$PLOG" "$1"; }

# gui-agent log offset + since (verbatim the a0-p3-toast-split.sh amark/asince idiom).
amark(){
  local ps
  ps="\$d=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools' -EA SilentlyContinue).LogDir; \$f=(Get-ChildItem \$d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1); if (\$f) { (@(Get-Content \$f.FullName)).Count } else { 0 }"
  enc_run "$ps" | tr -d '\r' | grep -aoxE '[0-9]+' | head -1
}
asince(){ # $1=mark $2=pattern (simple match)
  local ps
  ps="\$d=(Get-ItemProperty 'HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools' -EA SilentlyContinue).LogDir; \$f=(Get-ChildItem \$d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1); if (\$f) { \$all=@(Get-Content \$f.FullName); if (\$all.Count -gt $1) { \$all[$1..(\$all.Count-1)] | Select-String -Pattern '$2' -SimpleMatch | ForEach-Object { \$_.Line } } }"
  enc_run "$ps" | tr -d '\r'
}
# asince's stdout unavoidably rides the qtest-run CMD banner ("Microsoft Windows [Version..."
# + the base64 -EncodedCommand echo), so any verdict TRAILER that embeds `asince | tail` picks
# up banner tails (cosmetic FAIL-trailer pollution, rig 2026-09-05). asince_hits re-filters
# locally to the pattern's own hits — use it wherever asince output lands in a verdict string
# or an evidence file named after the pattern. Patterns must be regex-safe literals (all ours
# are: plain words, digits, '='; the guest side already matched them with -SimpleMatch).
asince_hits(){ asince "$1" "$2" | grep -a -- "$2"; }

# toastfire, run IN THE INTERACTIVE USER SESSION via run-as-user (toasts need one; per-user
# registration only). The exe is NOT in the installed package (make-setup stages only
# wgcbroker/notifhost/etwproxy into bin\) — T0 pushes it from $SETUP to QubesIncoming and this wrapper
# runs it from there. Args are space-free slugs BY CONTRACT: they ride run-as-user's ArgsB64 and
# are then re-split by `powershell -File wrapper.ps1 <tokens>`, where single quotes do NOT
# protect spaces — so no argument this harness passes may contain one.
tf(){ # $1=toastfire args string (space-free tokens), $2=tag; echoes wrapper output
  raspush "$OUT/p3a-toastfire.ps1" "$1" "$2"
}
tf_fire(){ # FIRED-confirmed (the fire_raw discipline); logs INSTRUMENT loudly on silence
  local out i
  for i in 1 2 3; do
    out=$(tf "$1" "tf$RANDOM")
    printf '%s\n' "$out"
    # RIG-RECONCILED 2026-09-05: key on the real result line 'FIRED method=' (toastfire.cpp:565),
    # NOT bare 'FIRED' - toastfire's Usage() text prints "FIRED prints payload_sha256" so a
    # usage-error run false-matched bare 'FIRED'. Proven both directions live.
    printf '%s' "$out" | grep -qa 'FIRED method=' && return 0
    sleep 8
  done
  log "INSTRUMENT: toastfire '$1' never confirmed FIRED after retries - dependent asserts are instrument misses, NOT product verdicts"
  return 1
}

coldboot(){ # $1=phase tag (verbatim the a0-p3-toast-split idiom)
  timeout -k 8 60 ./tools/qtest shutdown >/dev/null 2>&1
  w_halt "$VM" 300 "$1-halt" log || { QTEST_VM=$VM timeout -k 8 30 ./tools/qtest kill >/dev/null 2>&1; sleep 5; }
  timeout -k 8 60 ./tools/qtest start >/dev/null 2>&1
  w_usersession "$VM" 900 "$1-session" "$OUT" log
}
bridge_up(){ # heartbeat + connected past blog offset $1; return 0 = up (caller logs success),
  # nonzero = deadline (logged here). Wall caps 180s/120s: expected heartbeat ~30s after
  # session-up, connect seconds later; each probe is a ~55s-capped qrun, so the old
  # seq*sleep-only bounds (150s/60s nominal) could stretch to ~30/15 min (audit 2026-09-06).
  local i ok="" t0=$SECONDS
  for i in $(seq 1 30); do
    [ "$(hb_state)" = PRESENT ] && { ok=1; break; }
    [ $(( SECONDS - t0 )) -ge 180 ] && break
    sleep 5
  done
  [ -n "$ok" ] || { log "bridge_up: heartbeat wait exit=deadline t=$((SECONDS-t0))s (i=$i/30)"; return 1; }
  local t1=$SECONDS
  for i in $(seq 1 15); do
    blog_since "$1" | grep -qa "connected (server version" && return 0
    [ $(( SECONDS - t1 )) -ge 120 ] && break
    sleep 4
  done
  log "bridge_up: connected wait exit=deadline t=$((SECONDS-t1))s (i=$i/15; heartbeat was present)"
  return 1
}
# ETW tier up: proxy LIVE in etw-proxy.log past $1 + bridge 'ETW IPC connected' past blog $2.
# Wall cap 150s per call (expected: relaunch backoff floor 5s + connect, well under 120s
# nominal; two ~55s-capped guest reads per turn could otherwise stretch seq 24 to ~48 min).
# T8r's recovery deliberately calls this 3x for its ~6-8 min post-squat window (TODO(RIG)#7).
etw_tier_up(){ # $1=plog offset $2=blog offset; 0 = up, nonzero = deadline (logged)
  local i t0=$SECONDS
  for i in $(seq 1 24); do
    plog_since "$1" > "$OUT/.tierup-plog.txt" 2>/dev/null
    blog_since "$2" > "$OUT/.tierup-blog.txt" 2>/dev/null
    grep -qa 'ETWPROXY LIVE' "$OUT/.tierup-plog.txt" && \
      grep -qa 'ETW IPC connected server_pid=' "$OUT/.tierup-blog.txt" && return 0
    [ $(( SECONDS - t0 )) -ge 150 ] && break
    sleep 5
  done
  log "etw_tier_up: exit=deadline t=$((SECONDS-t0))s (i=$i/24)"
  return 1
}
med(){ sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit} if(NR%2)print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'; }

# ---------- T0 preflight + prime + gate on + instrument floor --------------------------------
for f in guest/run-as-user.ps1 guest/fire-demo-toast.ps1 guest/a0-showbanner.ps1 \
         guest/dismiss-toast.ps1 tools/qtest tools/qtest-geom mgmt/harness/prime-run.sh; do
  [ -e "$f" ] || { log "FATAL missing $f"; exit 1; }
done
[ -d "$SETUP" ] || { log "FATAL setup dir $SETUP missing"; exit 1; }
[ -f "$SETUP/MANIFEST.json" ] && cp "$SETUP/MANIFEST.json" "$OUT/" && log "manifest: $(head -c 400 "$SETUP/MANIFEST.json")"
# toastfire: required by the decisive phases; from the package, or TOASTFIRE= override.
TFEXE="${TOASTFIRE:-$(find "$SETUP" -iname 'toastfire.exe' | head -1)}"
[ -n "$TFEXE" ] && [ -f "$TFEXE" ] || { log "FATAL toastfire.exe not in $SETUP (and no TOASTFIRE= override) - the per-method phases cannot run"; exit 1; }
sha256sum "$TFEXE" | tee -a "$R" >/dev/null
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2!="Halted" && $1 ~ /^(win(10|11)|prime-)/ {print $1}')
[ -z "${running// /}" ] || { log "FATAL not all Halted: $running"; exit 1; }

# guest-side wrappers, generated into the gitignored evidence dir and pushed via raspush
cat > "$OUT/p3a-toastfire.ps1" <<PSEOF
\$exe = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\toastfire.exe'
if (-not (Test-Path -LiteralPath \$exe)) { Write-Output "TFWRAP error=toastfire_not_found path=\$exe"; exit 4 }
& \$exe @args 2>&1 | ForEach-Object { "\$_" }
Write-Output ("TFWRAP_EXIT " + \$LASTEXITCODE)
PSEOF
cat > "$OUT/p3a-dumpwpndb.ps1" <<'PSEOF'
& 'C:\Program Files\Qubes Tools\bin\notifhost.exe' --dump-wpndb 30 2>&1 | ForEach-Object { "$_" }
Write-Output ("DWEXIT " + $LASTEXITCODE)
PSEOF
cat > "$OUT/p3a-userproxy.ps1" <<'PSEOF'
# T4b: run etwproxy.exe (the console-split proxy binary) AS THE PLAIN INTERACTIVE USER,
# bounded. rc lands in P3ARC=; stdout (the guard/denied printf lines) is captured too — the
# proxy log ACL denies this token, so stdout is the only record of WHY it exited.
$of = 'C:\ProgramData\Qubes\p3a-userproxy-out.txt'
Remove-Item $of -Force -EA SilentlyContinue
$p = Start-Process -FilePath 'C:\Program Files\Qubes Tools\bin\etwproxy.exe' `
       -NoNewWindow -PassThru -RedirectStandardOutput $of
if ($p.WaitForExit(20000)) { Write-Output ('P3ARC=' + $p.ExitCode) } else { $p.Kill(); Write-Output 'P3ARC=RUNAWAY' }
Start-Sleep -Milliseconds 300
if (Test-Path $of) { Get-Content $of | ForEach-Object { "$_" } }
PSEOF
cat > "$OUT/p3a-firepurge.ps1" <<'PSEOF'
# T8a fire+purge drill (design 10.20.5#5): fire via toastfire, then purge the platform
# notification (History.Clear deletes its wpndatabase row) after a caller-set delay - all IN
# ONE user-session process, because a second qrexec hop (~1-2s) always loses the race against
# the bridge's WAL-paced targeted read. args: <aumid> <purge-delay-ms> <toastfire args...>
$exe = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\toastfire.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Output "FPWRAP error=toastfire_not_found path=$exe"; exit 4 }
$aumid = $args[0]
$delay = [int]$args[1]
$rest = @($args | Select-Object -Skip 2)
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
& $exe @rest 2>&1 | ForEach-Object { "$_" }
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds $delay
try {
  [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($aumid)
  Write-Output "FPWRAP purged=1 delay_ms=$delay"
} catch { Write-Output ("FPWRAP purged=0 err=" + $_.Exception.Message) }
Write-Output ("FPWRAP_EXIT " + $rc)
PSEOF

log "T0: prime-run $BASE -> $VM (job ours; clean install from the RELEASE PACKAGE, no swaps)"
./mgmt/harness/prime-run.sh "$BASE" "$VM" ours --payload "$SETUP" > "$OUT/prime.log" 2>&1
rc=$?
[ $rc -eq 0 ] || { log "FATAL prime-run rc=$rc (tail: $(tail -3 "$OUT/prime.log" | tr '\n' ' '))"; exit 1; }
w_usersession "$VM" 900 t0-session "$OUT" log || { log "FATAL no user session after prime"; exit 1; }

# build identity (rule 1): the artefact under test is what is actually installed.
# etwproxy.exe ADDED 2026-09-05 with the console split: the proxy code this gate grades no
# longer lives inside notifhost.exe, so without its own hash check a bin-overlay miss or a
# stale proxy binary would be graded as product behaviour (the helpers-must-be-explicitly-
# packaged trap; make-setup.ps1 hard-requires it in helper-bins, so any valid package has it).
for exe in notifhost.exe gui-agent.exe etwproxy.exe; do
  pk=$(find "$SETUP" -name "$exe" | head -1)
  if [ -n "$pk" ]; then
    want=$(sha256sum "$pk" | awk '{print tolower($1)}')
    have=$(qrun "certutil -hashfile \"$QT\\$exe\" SHA256" | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    if [ "$want" = "$have" ]; then log "T0: $exe identity OK ($want)"
    else verdict T0 "FAIL $exe installed=$have package=$want - BUILD UNDER TEST IS WRONG"; exit 1; fi
  else verdict T0 "FAIL $exe not found in package $SETUP"; exit 1; fi
done

# gate ON in dom0, read back, then COLD BOOT: EtwProxyInit runs after the agent's gate read at
# Init, so the proxy chain only arms on a boot that starts with the feature set.
qvm-features "$VM" service.notify-bridge 1 || { log "FATAL qvm-features set failed"; exit 1; }
gval=$(qvm-features "$VM" service.notify-bridge 2>/dev/null)
[ "$gval" = "1" ] || { verdict T0 "FAIL service.notify-bridge readback='$gval' (wanted 1)"; exit 1; }
# allowlist the PS AUMID for T7's A0 regression slice (same config a0-toast-bridge.sh P3 proves)
qrun "reg add \"HKLM\\SOFTWARE\\Invisible Things Lab\\Qubes Tools\\gui-agent\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$PSAUMID\" /f" >/dev/null
coldboot t0 || { log "FATAL no session after gate-on cold boot"; exit 1; }
verdict T0 "primed, build identity proven, gate on, cold-booted"

# ---- T0i instrument floor (every probe seen to distinguish BOTH WAYS before any verdict) ----
pst_yes=$(path_state 'C:\Windows\System32\cmd.exe'); pst_no=$(path_state 'C:\ProgramData\__p3a_nope__')
[ "$pst_yes" = PRESENT ] && [ "$pst_no" = ABSENT ] \
  || { verdict T0i "INSTRUMENT path_state present='$pst_yes' absent='$pst_no' - aborting"; exit 1; }
am=$(amark); [ -n "$am" ] || { verdict T0i "INSTRUMENT amark empty (agent LogDir probe broken) - aborting"; exit 1; }
ahit=$(asince 0 'seamless'); amiss=$(asince 0 '__p3a_never__')
# RIG-RECONCILED 2026-09-05: asince's stdout carries the qtest-run CMD banner ("Microsoft
# Windows [Version ...]" + the base64 -EncodedCommand echo), so an emptiness test on the miss
# direction is NEVER empty and aborted every run. asince is USED everywhere with a positive grep
# for a specific pattern, so validate it that way: the hit pattern MUST appear (real 'seamless'
# agent lines) and the (base64-hidden) miss pattern MUST NOT. Proven both directions live.
if ! printf '%s' "$ahit" | grep -qa 'seamless' || printf '%s' "$amiss" | grep -qa '__p3a_never__'; then
  verdict T0i "INSTRUMENT asince hit-has-seamless=$(printf '%s' "$ahit" | grep -qa 'seamless' && echo y || echo n) miss-has-never=$(printf '%s' "$amiss" | grep -qa '__p3a_never__' && echo y || echo n) - aborting"; exit 1
fi
# gflen both ways: an existing file counts, a missing one reads 0 (and hard failure is nonzero)
gy=$(gflen 'C:\Windows\win.ini') || gy=ERR; gn=$(gflen 'C:\ProgramData\__p3a_nofile__') || gn=ERR
{ [ "$gy" != ERR ] && [ "${gy:-0}" -gt 0 ] && [ "$gn" = 0 ]; } \
  || { verdict T0i "INSTRUMENT gflen exists='$gy' missing='$gn' - aborting"; exit 1; }
# fwd detectors (T7's forward asserts lean on them): a0-lib's pure-text self-test, no VM
# contact - fwd_count must count the dropped-SENT delivered shape and read 0 on undelivered/
# forgery-laden windows; fwd_attempts must fire on any attempt and stay 0 on a forward-free
# window. This is the NAMED seen-to-fail proof for T7a/T7c's must-be-zero asserts and T7b's
# delivered counts (same call a0-toast-bridge.sh P1c makes - reused, not reinvented).
fwd_selftest \
  || { verdict T0i "INSTRUMENT fwd_count/fwd_attempts self-test failed (see the MISMATCH line above) - T7's forward asserts would grade blind, aborting"; exit 1; }
log "T0i: probes OK (path_state both ways, amark=$am, asince hit/miss, gflen $gy/$gn, fwd_selftest clean)"
# guest scratch dir for redirected outputs (secedit export, sampler, T4 redirects) - created
# HERE so no later phase depends on run-as-user having incidentally created its parent first
qrun 'cmd /c mkdir C:\ProgramData\Qubes 2>nul & echo P3AMKDIR' >/dev/null 2>&1

# fire-path readiness (the a0 P1d gate, verbatim rationale: the first run-as-user fire after a
# fresh prime silently no-ops for MINUTES until `query user` shows Active)
log "T0r: waiting for an Active interactive session, up to ~20 min"
# Three exits (audit 2026-09-06): Active / terminal guest-halted / 1500s wall deadline (the
# expected event is the measured ~12+ min fresh-prime settle; per-turn qrun cost would
# otherwise stretch seq 40 x 30s to ~57 min).
t0_active=""; t0_term=""; _wt0r=$SECONDS
for i in $(seq 1 40); do
  qrun 'query user' 2>&1 | tr -d '\r' | grep -qE '[[:space:]]Active([[:space:]]|$)' && { t0_active=1; break; }
  [ "$(w_state "$VM")" = Halted ] && { t0_term=1; break; }
  [ $(( SECONDS - _wt0r )) -ge 1500 ] && break
  sleep 30
done
[ -n "$t0_active" ] || { log "T0r: session wait exit=$([ -n "$t0_term" ] && echo terminal-guest-halted || echo deadline) t=$((SECONDS-_wt0r))s (i=$i/40)"; verdict T0r "INSTRUMENT no Active session ($([ -n "$t0_term" ] && echo "guest HALTED mid-wait" || echo "~25 min wall budget spent")) - fire path unusable, aborting"; exit 1; }
# push toastfire ONCE (per-file push; needs the user session for Filecopy), then prove the tool:
# --print-xml offline (executes + prints payload_sha256 => the FIRED detector's data source
# exists) and a bogus flag (usage error, NO FIRED => the detector can fail).
QTEST_VM=$VM timeout -k 8 120 ./tools/qtest push "$TFEXE" >/dev/null 2>&1
tfx=$(tf '--print-xml --class informational --title P3A-selftest' t0px); printf '%s\n' "$tfx" > "$OUT/t0-printxml.txt"
printf '%s' "$tfx" | grep -qa 'payload_sha256=' \
  || { verdict T0r "INSTRUMENT toastfire --print-xml produced no payload_sha256 (tool not runnable in-session): $(printf '%s' "$tfx" | tail -2 | tr '\n' ';')"; exit 1; }
tfb=$(tf '--fire --bogus-flag-p3a' t0bg)
# the negative control: a usage error prints Usage() (which CONTAINS the word FIRED); the
# detector keys on the result line 'FIRED method=' so it correctly does NOT match here.
printf '%s' "$tfb" | grep -qa 'FIRED method=' \
  && { verdict T0r "INSTRUMENT the FIRED detector matched a usage-error run - detector cannot fail, aborting"; exit 1; }
# register the two registerable methods (idempotent; bare registers nothing by design)
tf '--register --method start-shortcut' t0r1 > "$OUT/t0-reg-ss.txt" 2>&1
tf '--register --method com-activator'  t0r2 > "$OUT/t0-reg-ca.txt" 2>&1
# one confirmed real fire = warm-up + readiness proof
tf_fire '--fire --method start-shortcut --class informational --title P3A-warmup --tag t0warm' > "$OUT/t0-warm.txt" 2>&1 \
  || { verdict T0r "INSTRUMENT warm-up fire never FIRED - aborting"; exit 1; }
dismiss_toasts "${TFAUMID[start-shortcut]}"
verdict T0r "fire path ready (Active session, toastfire proven both ways, methods registered)"

# ---------- T1 provisioning asserts (§10.14 as shipped by provision-etwproxy-account.ps1) ----
log "T1: provisioning asserts (installer trailer, census, account, rights, firewall, ACLs, owner)"

# T1a installer trailer: the provision script's '=== RESULT === provisioned=1 ... reason=ok'
# rides Install-QwtImproved's log. sid= from the same line feeds the secedit asserts below.
qrun "cmd /c type $ILOG" | tr -d '\r' > "$OUT/t1-install.log" 2>/dev/null
trailer=$(grep -a 'provisioned=' "$OUT/t1-install.log" | tail -1)
if [ -z "$trailer" ]; then
  verdict T1a "INSTRUMENT no provisioned= trailer found in $ILOG - TODO(RIG)#8 re-run the staged provisioning script to re-print it; provisioning UNGRADED"
else
  log "T1a trailer: $(printf '%s' "$trailer" | head -c 300)"
  printf '%s' "$trailer" | grep -qa 'provisioned=1' \
    && verdict T1a "PASS trailer provisioned=1 ($(printf '%s' "$trailer" | grep -aoE 'reason=[^ ]+'))" \
    || verdict T1a "FAIL trailer says $(printf '%s' "$trailer" | grep -aoE 'provisioned=[0-9]+ .*reason=[^ ]*' | head -c 200)"
fi
ACCTSID=$(printf '%s' "$trailer" | grep -aoE 'sid=S-1-5-21-[0-9-]+' | cut -d= -f2)
[ -n "$ACCTSID" ] && log "T1: account SID from trailer: $ACCTSID" \
  || log "T1 WARN: no sid= in trailer - secedit asserts will be graded INSTRUMENT"

# T1b agent census: etwproxy.c logs the invariant verbatim on every launch.
cen=$(asince 0 'ETWPROXYSUP consumer token census')
printf '%s\n' "$cen" > "$OUT/t1-census.txt"
# RIG-RECONCILED 2026-09-05: asince carries the CMD banner so [ -z "$cen" ] is never true;
# detect an absent census line by the pattern itself, not by emptiness.
if ! printf '%s' "$cen" | grep -qa 'ETWPROXYSUP consumer token census'; then
  verdict T1b "FAIL no 'ETWPROXYSUP consumer token census' line this boot - the agent never attempted the launch (gate/arming broken; check 'ETWPROXYSUP armed' + 'ETWPROXYSUP parked' lines: $(asince_hits 0 'ETWPROXYSUP' | tail -2 | tr '\n' ';'))"
elif printf '%s' "$cen" | grep -qa 'plu=0 admin=0 se_system_profile=0'; then
  verdict T1b "PASS census invariant holds: $(printf '%s' "$cen" | tail -1 | grep -aoE 'groups=[0-9]+ privs=[0-9]+ plu=0 admin=0 se_system_profile=0')"
else
  verdict T1b "FAIL census present but invariant violated: $(printf '%s' "$cen" | tail -1 | head -c 200)"
fi

# T1c account exists (+ the detector's fail direction on a name that cannot exist)
acct=$(enc_run '& net user qubes-etwproxy *> $null; if ($LASTEXITCODE -eq 0) {"ACCT-PRESENT"} else {"ACCT-ABSENT"}' | grep -aoE 'ACCT-(PRESENT|ABSENT)' | tail -1)
noacct=$(enc_run '& net user __p3a_nouser__ *> $null; if ($LASTEXITCODE -eq 0) {"ACCT-PRESENT"} else {"ACCT-ABSENT"}' | grep -aoE 'ACCT-(PRESENT|ABSENT)' | tail -1)
[ "$noacct" = ACCT-ABSENT ] || { verdict T1c "INSTRUMENT account probe cannot fail (bogus name read '$noacct') - ungraded"; }
[ "$acct" = ACCT-PRESENT ] && [ "$noacct" = ACCT-ABSENT ] \
  && verdict T1c "PASS account $ACCT exists (probe proven both ways)" \
  || { [ "$noacct" = ACCT-ABSENT ] && verdict T1c "FAIL account $ACCT absent"; }

# T1d NOT in Performance Log Users (the never-PLU core of the split). The PRESENT direction of
# this detector is fired deliberately in T5 (drift injection) — cross-phase fail-proof.
plu=$(enc_run '(net localgroup "Performance Log Users") -join "|"' | tr -d '\r')
printf '%s\n' "$plu" > "$OUT/t1-plu.txt"
printf '%s' "$plu" | grep -qai "$ACCT" \
  && verdict T1d "FAIL $ACCT IS in Performance Log Users - the split's core invariant is broken on install" \
  || verdict T1d "PASS $ACCT not in Performance Log Users (PRESENT direction fired in T5)"

# T1e logon rights via secedit export: batch GRANTED, interactive/remote/network DENIED.
# RIG-RECONCILED 2026-09-05 (FALSE NEGATIVE): secedit renders a NEW LOCAL account by NAME
# ("qubes-etwproxy"), not as *S-1-5-21-... - a SID-only grep read a correctly-provisioned
# guest as FAIL. Match name-OR-SID (renderings differ by account age/rebuild state), and
# grade by name alone when the trailer carried no sid= instead of going INSTRUMENT.
enc_run 'secedit /export /areas USER_RIGHTS /cfg C:\ProgramData\Qubes\p3a-ur.inf *> $null; Get-Content C:\ProgramData\Qubes\p3a-ur.inf' \
  | tr -d '\r' > "$OUT/t1-userrights.inf"
if ! grep -qa '^Se' "$OUT/t1-userrights.inf"; then
  verdict T1e "INSTRUMENT secedit export empty/unreadable (no Se* lines) - rights ungraded"
else
  urpat="$ACCT"; [ -n "$ACCTSID" ] && urpat="$ACCTSID|$ACCT"
  urfail=""
  grep -a '^SeBatchLogonRight' "$OUT/t1-userrights.inf" | grep -qaE "$urpat" || urfail="$urfail batch-missing"
  for right in SeDenyInteractiveLogonRight SeDenyRemoteInteractiveLogonRight SeDenyNetworkLogonRight; do
    grep -a "^$right" "$OUT/t1-userrights.inf" | grep -qaE "$urpat" || urfail="$urfail $right-missing"
  done
  [ -z "$urfail" ] && verdict T1e "PASS rights: +SeBatchLogonRight, deny interactive/remote/network (matched by name-or-SID in secedit export)" \
    || verdict T1e "FAIL rights:$urfail (export in t1-userrights.inf; pattern '$urpat')"
fi

# T1f no LSA secret L$QubesEtwProxyCred (retired by the split). Access fire-proof first: SYSTEM
# must be able to enumerate the Secrets key at all, or ABSENT is vacuous.
secroot=$(enc_run '& reg query "HKLM\SECURITY\Policy\Secrets" *> $null; if ($LASTEXITCODE -eq 0) {"SEC-OK"} else {"SEC-DENIED"}' | grep -aoE 'SEC-(OK|DENIED)' | tail -1)
if [ "$secroot" != SEC-OK ]; then
  verdict T1f "INSTRUMENT cannot enumerate LSA Secrets as SYSTEM ($secroot) - absence unprovable, ungraded"
else
  # the key path MUST sit in PS SINGLE quotes: inside PS double quotes, $QubesEtwProxyCred is a
  # (nonexistent, empty) PS variable and the probe would query ...\Secrets\L - vacuous forever
  lsec=$(enc_run "& reg query 'HKLM\\SECURITY\\Policy\\Secrets\\L\$QubesEtwProxyCred' *> \$null; if (\$LASTEXITCODE -eq 0) {'LS-PRESENT'} else {'LS-ABSENT'}" | grep -aoE 'LS-(PRESENT|ABSENT)' | tail -1)
  [ "$lsec" = LS-ABSENT ] && verdict T1f "PASS no L\$QubesEtwProxyCred LSA secret (access proven via Secrets root)" \
    || verdict T1f "FAIL retired LSA secret still present ($lsec)"
fi

# T1g no QubesEtwProxyGuard task (retired). Fail direction: create+query+delete a marker task.
# RIG-RECONCILED 2026-09-05 (self-test hiccup): schtasks /create can RETURN before the task
# store answers a /query for the fresh task - one rig run read TQ-ABSENT on its own marker and
# self-INSTRUMENTed. Poll the marker query up to 3x (2s apart) before concluding the probe is
# broken; the fail-safe stays INSTRUMENT (a probe that cannot see its own marker grades nothing).
mkrc=$(enc_run '& schtasks /create /tn P3ASELFTESTTASK /tr "cmd /c exit 0" /sc once /st 00:00 /f *> $null; if ($LASTEXITCODE -eq 0) {"MK-OK"} else {"MK-FAIL"}' | grep -aoE 'MK-(OK|FAIL)' | tail -1)
tsy=""
for i in 1 2 3; do
  tsy=$(enc_run '& schtasks /query /tn P3ASELFTESTTASK *> $null; if ($LASTEXITCODE -eq 0) {"TQ-PRESENT"} else {"TQ-ABSENT"}' | grep -aoE 'TQ-(PRESENT|ABSENT)' | tail -1)
  [ "$tsy" = TQ-PRESENT ] && break
  sleep 2
done
enc_run '& schtasks /delete /tn P3ASELFTESTTASK /f *> $null; "TDEL"' >/dev/null
tguard=$(enc_run '& schtasks /query /tn QubesEtwProxyGuard *> $null; if ($LASTEXITCODE -eq 0) {"TQ-PRESENT"} else {"TQ-ABSENT"}' | grep -aoE 'TQ-(PRESENT|ABSENT)' | tail -1)
if [ "$tsy" != TQ-PRESENT ]; then
  verdict T1g "INSTRUMENT task probe cannot see a task it just created (create=${mkrc:-?} query=$tsy after 3 polls) - ungraded"
else
  [ "$tguard" = TQ-ABSENT ] && verdict T1g "PASS no QubesEtwProxyGuard task (probe proven both ways)" \
    || verdict T1g "FAIL retired guard task still registered"
fi

# T1h firewall: the per-SID outbound Block rule (with its can-fail direction)
fw=$(enc_run "\$r=Get-NetFirewallRule -Name '$FWRULE' -EA SilentlyContinue; if (\$r) {'FWRULE-PRESENT action='+\$r.Action+' dir='+\$r.Direction+' enabled='+\$r.Enabled} else {'FWRULE-ABSENT'}" | grep -aoE 'FWRULE-[^|]*' | tail -1)
nofw=$(enc_run "\$r=Get-NetFirewallRule -Name '__p3a_nofw__' -EA SilentlyContinue; if (\$r) {'FWRULE-PRESENT'} else {'FWRULE-ABSENT'}" | grep -aoE 'FWRULE-(PRESENT|ABSENT)' | tail -1)
[ "$nofw" = FWRULE-ABSENT ] || verdict T1h "INSTRUMENT firewall probe cannot fail ('$nofw') - ungraded"
if [ "$nofw" = FWRULE-ABSENT ]; then
  printf '%s' "$fw" | grep -qa 'FWRULE-PRESENT action=Block dir=Outbound' \
    && verdict T1h "PASS outbound-block rule present ($fw)" \
    || verdict T1h "FAIL firewall rule wrong/absent: $fw"
fi

# T1i scoped ACLs: proxy account on ITS OWN log only; DENY on the bridge state dir. PLOG first.
plogdir=$(enc_run '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -EA SilentlyContinue).LogDir; if (-not $d) { $d = "$env:SystemDrive\Qubes Logs" }; "PLOGDIR=$d"' | grep -aoE 'PLOGDIR=[^ ].*' | tail -1)
plogdir="${plogdir#PLOGDIR=}"
# Every decisive phase reads this log; an unresolved path would misattribute their failures.
[ -n "$plogdir" ] && printf '%s' "$plogdir" | grep -qa ':' \
  || { verdict T1i "INSTRUMENT proxy log dir resolution returned '$plogdir' - T2/T3 cannot be graded, aborting"; exit 1; }
PLOG="$plogdir\\etw-proxy.log"
log "T1: proxy log resolved to $PLOG (TODO(RIG)#1 if LogDir was unset)"
enc_run "icacls '$PLOG'" | tr -d '\r' > "$OUT/t1-acl-plog.txt" 2>/dev/null
enc_run "icacls '$STATEDIR'" | tr -d '\r' > "$OUT/t1-acl-statedir.txt" 2>/dev/null
aclfail=""
grep -qai "$ACCT" "$OUT/t1-acl-plog.txt" || aclfail="$aclfail no-$ACCT-ACE-on-own-log"
grep -ai "$ACCT" "$OUT/t1-acl-statedir.txt" | grep -qai 'deny' || aclfail="$aclfail no-deny-on-state-dir(TODO(RIG)#3)"
[ -z "$aclfail" ] && verdict T1i "PASS ACLs: $ACCT ACE on its own log, deny on $STATEDIR" \
  || verdict T1i "FAIL ACLs:$aclfail (see t1-acl-*.txt)"

# T1j the RUNNING proxy's owner: session-0 etwproxy.exe owned by the proxy account, never
# SYSTEM. RIG-RECONCILED 2026-09-05: the console split renamed the proxy BINARY to
# etwproxy.exe (agent line 'ETWPROXYSUP launched etwproxy.exe pid=' confirms); a notifhost.exe
# filter here false-FAILed the last run while the proxy ran fine (notifhost.exe is the
# USER-SESSION bridge and never the session-0 proxy).
# tasklist, not WMI/Get-Process (both broken on this guest — only tasklist works).
enc_run 'tasklist /v /fo csv /fi "imagename eq etwproxy.exe"' | tr -d '\r' > "$OUT/t1-tasklist.csv"
prow=$(awk -F'","' '$4 == "0" {print}' "$OUT/t1-tasklist.csv" | head -1)
if [ -z "$prow" ]; then
  verdict T1j "FAIL no session-0 etwproxy.exe running (proxy not launched; agent lines: $(asince_hits 0 'ETWPROXYSUP' | tail -2 | tr '\n' ';'))"
elif printf '%s' "$prow" | grep -qai "$ACCT"; then
  verdict T1j "PASS proxy runs as $ACCT in session 0 ($(printf '%s' "$prow" | head -c 160))"
else
  verdict T1j "FAIL session-0 etwproxy.exe owner is NOT $ACCT (TODO(RIG)#2 check CSV rendering): $(printf '%s' "$prow" | head -c 160)"
fi

# ---------- T2 DECISIVE: the proxy ARMS (L1) and SIGNAL frames arrive ------------------------
# The go/no-go of the whole gate (§10.16.3b as redefined by the split, PIVOTED by §10.20):
# a zero-priv, never-PLU token holding only the per-session EventAccessControl grant must
# OpenTrace+ProcessTrace and deliver payload-FREE SIGNAL frames (QTS1: {AUMID, notificationId,
# tag, group} - §10.20.1). The PAYLOAD is deliberately ABSENT from the wire (Win10 providers
# never emit it; the proxy must not materialize it); T3 grades the targeted wpndb read that
# answers each signal. Everything after this phase refines HOW WELL; this decides WHETHER.
log "T2: DECISIVE - proxy arms (L1 launch fix) + grant carries OpenTrace+ProcessTrace + signal frames flow"

# agent-side control-call RCs, verbatim (§10.16.3b datum lines)
prc=$(asince 0 'PROXY RC ')
printf '%s\n' "$prc" > "$OUT/t2-proxyrc.txt"
t2rcfail=""
printf '%s' "$prc" | grep -qa 'api=StartTrace provider=- rc=0' || t2rcfail="$t2rcfail StartTrace!=0"
printf '%s' "$prc" | grep -qa 'api=EnableTraceEx2 provider=.* rc=0' || t2rcfail="$t2rcfail no-provider-enabled"
printf '%s' "$prc" | grep -qa 'api=EventAccessControl op=AddDACL principal=consumer rights=TRACELOG_ACCESS_REALTIME rc=0' || t2rcfail="$t2rcfail grant-AddDACL!=0"
[ -z "$t2rcfail" ] && log "T2: agent control RCs clean (StartTrace/EnableTraceEx2/EventAccessControl all 0)" \
  || verdict T2rc "FAIL agent control calls:$t2rcfail - record verbatim, the cures are owner decisions (§10.16.3b), not rig improvisation"

# T2l1 - the L1 launch fix under the 2026-09-05 CONSOLE SPLIT (etwproxy.exe links no
# user32/gdi32, so no winsta exists in the story at all), graded BEFORE tier-up:
#   (a) the proxy never dies STATUS_DLL_INIT_FAILED - 0xC0000142 renders as DECIMAL
#       3221225794 in the agent's 'ETWPROXYSUP proxy exited rc=%lu' line - the split's
#       whole claim is that this exit is now structurally impossible;
#   (b) the winsta-era machinery is GONE: the agent must log NO 'dedicated winsta ready'
#       line and the proxy log must never name QubesEtwProxyWS (their presence means an
#       old agent/binary pairing is running - a deploy mix, not this build);
#   (c) etw-proxy.log EXISTS with content - the 0xC0000142 signature was this log NEVER
#       appearing (user32 init died before the proxy's first line).
pexits=$(asince_hits 0 'proxy exited rc=')
printf '%s\n' "$pexits" > "$OUT/t2-proxy-exits.txt"
ndll=$(printf '%s' "$pexits" | grep -ca 'rc=3221225794' || true)
wsready=$(asince_hits 0 'dedicated winsta ready' | tail -1)
pl2=""; _wpl=$SECONDS
for i in $(seq 1 12); do
  # wall cap 90s (expected: the proxy's first log line lands within seconds of its launch,
  # backoff floor 5s; plog_len's internal 3-try retry could stretch a turn to ~3 min)
  pl2=$(plog_len) && [ "${pl2:-0}" -gt 0 ] && break
  [ $(( SECONDS - _wpl )) -ge 90 ] && break
  sleep 5
done
log "T2l1: proxy-log wait exit=$([ "${pl2:-0}" -gt 0 ] 2>/dev/null && echo success || echo deadline) t=$((SECONDS-_wpl))s (i=$i/12)"
plog_since 0 | grep -a 'QubesEtwProxyWS' > "$OUT/t2-plog-winsta.txt" 2>/dev/null || true
t2l1fail=""
[ "${ndll:-0}" = 0 ] || t2l1fail="$t2l1fail 0xC0000142-exits=$ndll(CONSOLE-SPLIT-REGRESSED)"
[ -z "$wsready" ] || t2l1fail="$t2l1fail winsta-era-agent-line-present(old-agent-running?)"
[ ! -s "$OUT/t2-plog-winsta.txt" ] || t2l1fail="$t2l1fail proxy-log-names-QubesEtwProxyWS(old-binary-running?)"
[ "${pl2:-0}" -gt 0 ] || t2l1fail="$t2l1fail etw-proxy.log-absent/empty"
if [ -z "$t2l1fail" ]; then
  verdict T2l1 "PASS console split holds: no 0xC0000142 exits, no winsta lines anywhere, etw-proxy.log live ($pl2 lines)"
else
  verdict T2l1 "FAIL L1:$t2l1fail (proxy exit lines in t2-proxy-exits.txt)"
fi

# proxy alive + tier connected, then the ORDERING assert: token census + privileges shed must
# precede the FIRST forwarded signal — the untrusted decode never ran privileged.
if ! etw_tier_up 0 0; then
  plog_since 0 | tail -8 > "$OUT/t2-plog-tail.txt" 2>/dev/null
  verdict T2 "FAIL ETW tier never came up (no ETWPROXY LIVE + ETW IPC connected): plog tail=$(tr '\n' ';' < "$OUT/t2-plog-tail.txt" | head -c 300) agent=$(asince_hits 0 'ETWPROXYSUP parked' | tail -1 | head -c 200)"
  T2GO=no
else
  log "T2: tier up (ETWPROXY LIVE + ETW IPC connected)"
  T2GO=""
  # one informational fire per registration method; ANY method's SIGNAL frame proves the
  # grant. Offsets captured PER METHOD, and both greps pinned to the method's AUMID -
  # otherwise a later method could satisfy its detector with an EARLIER method's SIG line.
  # Spellings (source-RE-read 2026-09-05 post console split): proxy 'ETWPROXY SIG #n
  # aumid=... idnum=...' (etwproxy.cpp EtwProxyEventCb), bridge 'ETW SIG #n aumid=...
  # idnum=...' (notifhost.cpp EtwIpcReadRecord). The old 'ETWPROXY TOAST'/'ETW REC #'
  # payload-frame lines are GONE.
  t2frames=0; t2imiss=0
  for m in start-shortcut com-activator bare; do
    tt="P3A-t2-$m"
    if ! P2=$(plog_len) || ! L2=$(blog_len); then
      t2imiss=$((t2imiss+1)); log "T2 INSTRUMENT: plog_len/blog_len unreadable before method=$m - method ungraded"; continue
    fi
    tf_fire "--fire --method $m --class informational --title $tt --tag t2$m" > "$OUT/t2-fire-$m.txt" 2>&1 \
      || { t2imiss=$((t2imiss+1)); continue; }
    got=""; _wt2=$SECONDS
    for i in $(seq 1 15); do
      # wall cap 90s (expected: the signal frame lands within seconds of the fire; two
      # ~55s-capped guest reads per turn could stretch the nominal 45s to ~30 min per method)
      plog_since "$P2" > "$OUT/t2-plog-$m.txt" 2>/dev/null
      blog_since "$L2" > "$OUT/t2-blog-$m.txt" 2>/dev/null
      if grep -qa "ETWPROXY SIG #.*aumid=${TFAUMID[$m]}" "$OUT/t2-plog-$m.txt" \
         && grep -qa "ETW SIG #.*aumid=${TFAUMID[$m]}" "$OUT/t2-blog-$m.txt"; then got=1; break; fi
      [ $(( SECONDS - _wt2 )) -ge 90 ] && break
      sleep 3
    done
    if [ -n "$got" ]; then
      t2frames=$((t2frames+1))
      log "T2: method=$m signal delivered ($(grep -a "ETWPROXY SIG #.*${TFAUMID[$m]}" "$OUT/t2-plog-$m.txt" | tail -1 | head -c 160))"
    else
      log "T2: method=$m NO signal frame (wait exit=deadline t=$((SECONDS-_wt2))s; data for T3's table, not yet a gate fail)"
    fi
    dismiss_toasts "${TFAUMID[$m]}"
  done
  plog_since 0 > "$OUT/t2-plog-full.txt" 2>/dev/null
  # §10.20.1: the proxy must NOT materialize payload bytes at all (PxLooksLikeToastXml is
  # inverted into a markup REJECT). Any payload field or toast markup in the proxy log means
  # the signal frame carries cargo the hybrid forbids on the wire.
  if grep -qaE 'payload_bytes=|<toast' "$OUT/t2-plog-full.txt"; then
    verdict T2pl "FAIL proxy log carries payload material ($(grep -aE 'payload_bytes=|<toast' "$OUT/t2-plog-full.txt" | head -1 | head -c 160)) - the §10.20.1 markup-reject rule is broken"
  else
    log "T2: signal frames are payload-free (no payload_bytes=/<toast anywhere in the proxy log)"
  fi
  # ordering: census + shed before the first SIG, in the proxy's own log (whole-log line nums)
  nshed=$(grep -an 'ETWPROXY privileges shed' "$OUT/t2-plog-full.txt" | head -1 | cut -d: -f1)
  ncen=$(grep -an 'ETWPROXY token enabled-groups=' "$OUT/t2-plog-full.txt" | head -1 | cut -d: -f1)
  nsig=$(grep -an 'ETWPROXY SIG #' "$OUT/t2-plog-full.txt" | head -1 | cut -d: -f1)
  if [ "$t2frames" -ge 1 ]; then
    if [ -n "$nshed" ] && [ -n "$ncen" ] && [ -n "$nsig" ] && [ "$nshed" -lt "$nsig" ] && [ "$ncen" -lt "$nsig" ]; then
      # the census the proxy printed must ALSO be clean (perf-log-users=0 se-system-profile=0)
      grep -a 'ETWPROXY token enabled-groups=' "$OUT/t2-plog-full.txt" | head -1 | grep -qa 'perf-log-users=0 se-system-profile=0' \
        && verdict T2 "PASS DECISIVE: grant suffices - $t2frames/3 methods delivered payload-free SIGNAL frames (proxy SIG + bridge SIG) under a shed, census-clean token (shed@$nshed census@$ncen < first SIG@$nsig)" \
        || verdict T2 "FAIL signal frames arrived but the proxy's own census is not clean: $(grep -a 'ETWPROXY token enabled-groups=' "$OUT/t2-plog-full.txt" | head -1 | head -c 160)"
    else
      verdict T2 "FAIL signal frames arrived but ordering unproven (shed@${nshed:-none} census@${ncen:-none} sig@${nsig:-none}) - the decode may have run before privileges were shed"
    fi
  elif [ "$t2imiss" -ge 3 ]; then
    T2GO=no
    verdict T2 "INSTRUMENT all 3 method fires were instrument misses (never FIRED / logs unreadable) - the grant is UNGRADED, not disproven; fix the fire path before re-running"
  else
    T2GO=no
    verdict T2 "FAIL DECISIVE: ZERO ETW signal frames from 3 methods ($t2imiss instrument miss(es)) - the grant does not carry ProcessTrace ($(grep -a 'FAIL OpenTrace' "$OUT/t2-plog-full.txt" | tail -1 | head -c 160); agent: $(asince_hits 0 'proxy exit 5' | tail -1 | head -c 160))"
  fi
fi

# no-go path: discriminate FALL-TO-DB vs KILL (§10.16.4), then STOP. The SYSTEM --dump-etw is
# the permitted step-0 controlled-rig shortcut ONLY — never left scheduled.
if [ "$T2GO" = no ]; then
  log "T2x: no-go discriminator - SYSTEM --dump-etw (does ANY provider carry the SIGNAL at all?) + --dump-wpndb rc"
  enc_run 'Remove-Item C:\ProgramData\Qubes\p3a-dumpetw.txt -Force -EA SilentlyContinue; Start-Process -FilePath "C:\Program Files\Qubes Tools\bin\notifhost.exe" -ArgumentList "--dump-etw","20" -NoNewWindow -RedirectStandardOutput "C:\ProgramData\Qubes\p3a-dumpetw.txt"; "DUMPSTARTED"' >/dev/null
  tf_fire '--fire --method start-shortcut --class informational --title P3A-t2x-dump --tag t2x' >/dev/null 2>&1
  sleep 25
  enc_run 'if (Test-Path C:\ProgramData\Qubes\p3a-dumpetw.txt) { Get-Content C:\ProgramData\Qubes\p3a-dumpetw.txt }' | tr -d '\r' > "$OUT/t2x-dumpetw.txt"
  dismiss_toasts "${TFAUMID[start-shortcut]}"
  raspush "$OUT/p3a-dumpwpndb.ps1" "" t2xdw > "$OUT/t2x-dumpwpndb.txt" 2>&1
  dwrc=$(grep -aoE 'DWEXIT [0-9]+' "$OUT/t2x-dumpwpndb.txt" | tail -1 | awk '{print $2}')
  # HYBRID discriminator (§10.20 + TODO(RIG)#6): the tier needs a SIGNAL, not a payload -
  # Win10 providers NEVER emit the payload XML (the rig-proven §10.20 datum), so "no payload
  # in --dump-etw" can no longer send anything toward KILL. Signal availability = an ETWEVT
  # line with aumid=1, the 'aumid_events=<n>' summary with n>=1, or the 'signal tier viable'
  # ETWDUMP verdict; a payload sighting ('payload XML observed'/'<toast') EXCEEDS the Win10
  # finding and also proves viability. KILL only when NO signal appears even under the SYSTEM
  # diagnostic AND --dump-wpndb exits 4 (schema mismatch): neither the tier NOR the fallback
  # can classify on this build.
  log "T2x: $(grep -a 'ETWDUMP processtrace rc=' "$OUT/t2x-dumpetw.txt" | tail -1) (§10.20.4 hardening datum)"
  DUMPETW_SIGNAL='aumid=1|aumid_events=[1-9]|signal tier viable|payload XML observed|<toast'
  if ! grep -qaiE "$DUMPETW_SIGNAL" "$OUT/t2x-dumpetw.txt" && [ "${dwrc:-0}" = 4 ]; then
    verdict GATE "KILL - no provider yields even the SIGNAL under the SYSTEM diagnostic AND --dump-wpndb exits 4 (schema mismatch): per-toast classification unbuildable on this build"
  else
    verdict GATE "FALL-TO-DB - the grant mechanism failed but the DB rung stands (dump-etw signal seen=$(grep -qaiE "$DUMPETW_SIGNAL" "$OUT/t2x-dumpetw.txt" && echo yes || echo no), dump-wpndb rc=${dwrc:-?}): proxy ships dormant, tier D primary, nothing regresses"
  fi
  log "T2x: STOPPING per the gate contract - phases T3-T7 unmeasured (voided window = UNCHECKED, not wrong)"
  blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
  plog_since 0 > "$OUT/etw-proxy-full.log" 2>/dev/null || true
  log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
  exit 1
fi

# ---------- T3 DECISIVE: the targeted wpndb read answers each signal (method x class) --------
# Hybrid semantics (§10.20.2 + §10.20.5 item 1): the signal carries NO payload - the bridge's
# ONE targeted read must produce it and classify. Per row this records:
#   sig     the proxy emitted a SIGNAL frame for the fired AUMID ('ETWPROXY SIG #')
#   idnum   the signal's numeric notificationId (idnum= on the SIG line; 0 = no id join)
#   row_id  the wpndatabase row for THIS toast (the 'ROW id=' whose PAYLOAD line carries the
#           unique title), via --dump-wpndb
#   join    THE notificationId<->wpndb-Id JOIN VERIFICATION (§10.20.5#1): idnum == row_id?
#           yes / no-id (signal carried none) / no-row / MISMATCH (idnum != row_id: the id
#           join is dead or wrong and the fallback must carry the tier)
#   corr    the targeted read's outcome - id-ok (id path) or sig-unique (fallback) are the
#           only clean acquisitions
#   verdict must match the fixture class: informational -> bridge, realchoice -> window
# Gate criterion: the CANONICAL row (start-shortcut x informational — the PS-fixture
# equivalent every prior phase used) must classify src=etw-sig, corr in {id-ok, sig-unique},
# verdict=bridge; other rows are findings, recorded not gated (a method Windows itself
# refuses is a coverage datum, not a harness fail).
#
# TODO(P3C) (routing phase - do NOT implement while measure-only): a SINGLE-ROW
# signal-fallback earns corr=sig-unique WITHOUT the first-<text>-vs-title cross-check
# (WpnTargetedRead's one-row path returns immediately; only the >1-row path disambiguates by
# title). Acceptable while the classifier is measure-only; BEFORE any corr value is allowed
# to influence REAL ROUTING, the single-row path must add the advisory title check too, or a
# stale/foreign lone row inside the +/-60s window classifies a toast it does not describe.
# This gate therefore records sig-unique as trusted-for-measurement only.
log "T3: per-method signal -> targeted-read matrix (6 rows) + the notificationId<->wpndb-Id join"
TBL="$OUT/t3-table.txt"
printf '%-15s %-14s %-6s %-4s %-12s %-12s %-9s %-8s %-9s %-18s %-8s %-6s %s\n' \
  method class fired sig idnum row_id join src etw corr verdict push dt_s > "$TBL"
t3canon=""; t3canonmiss=""
declare -A T3JOIN T3CORR T3SIG    # informational-row data: feeds T3j and the T8b twin drill
for m in start-shortcut com-activator bare; do
  for c in informational realchoice; do
    tt="P3A-t3-$m-$c"
    if ! P3=$(plog_len) || ! L3=$(blog_len); then
      # a 0 default would let an EARLIER row's lines satisfy this row's detectors
      log "T3 INSTRUMENT: log offsets unreadable before $m/$c - row ungraded"
      printf '%-15s %-14s %-6s %-4s %-12s %-12s %-9s %-8s %-9s %-18s %-8s %-6s %s\n' \
        "$m" "$c" probe-fail - - - - - - - - - - >> "$TBL"
      [ "$m" = start-shortcut ] && [ "$c" = informational ] && t3canonmiss=1
      continue
    fi
    fired=no; sig=no; idnum=0; rowid=-; join=-; csrc=-; cetw=-; ccorr=-; cver=-; push=none; dt=-
    if [ "$m" = bare ]; then
      # bare (never-registered AUMID) may be REFUSED by Windows — that outcome is the datum,
      # so no retry-instrument semantics here: one attempt, record what happened.
      o=$(tf "--fire --method $m --class $c --title $tt --tag t3$m$c" "t3$m$c"); printf '%s\n' "$o" > "$OUT/t3-fire-$m-$c.txt"
      printf '%s' "$o" | grep -qa 'FIRED method=' && fired=yes
    else
      tf_fire "--fire --method $m --class $c --title $tt --tag t3$m$c" > "$OUT/t3-fire-$m-$c.txt" 2>&1 && fired=yes
    fi
    if [ "$fired" = yes ]; then
      tfire=$(date +%s)
      for i in $(seq 1 15); do
        # wall cap 90s (expected: CLASSIFY within the 30s listing floor + WAL retries, <45s;
        # a ~55s-capped qrun per turn could stretch the nominal 45s to ~15 min per row)
        blog_since "$L3" > "$OUT/t3-blog-$m-$c.txt" 2>/dev/null
        grep -qa 'CLASSIFY id=' "$OUT/t3-blog-$m-$c.txt" && { dt=$(( $(date +%s) - tfire )); break; }
        [ $(( $(date +%s) - tfire )) -ge 90 ] && break
        sleep 3
      done
      plog_since "$P3" > "$OUT/t3-plog-$m-$c.txt" 2>/dev/null
      sl=$(grep -a "ETWPROXY SIG #.*aumid=${TFAUMID[$m]}" "$OUT/t3-plog-$m-$c.txt" | tail -1)
      if [ -n "$sl" ]; then
        sig=yes
        idnum=$(printf '%s' "$sl" | grep -aoE 'idnum=[0-9]+' | head -1 | cut -d= -f2)
      fi
      # CLASSIFY vocabulary (§10.20.2, source-read): line order is
      #   'CLASSIFY id=N src=S etw=E verdict=V row_latency=Lms signals=G corr=C'
      # with src in {etw-sig,db,none}, etw in {sig-hit,sig-none,down,off,probe-threw},
      # corr in {id-ok,id-aumid-mismatch,id-norow,sig-unique,sig-ambiguous,sig-norow,
      # db-fail, the DB rung's classes, none}. corr= is NOT adjacent to verdict=, and
      # 'etw-sig' needs the hyphen class - extract each field separately, never with the old
      # contiguous 'src=[a-z]+ etw=... verdict=...' grep (it can never match etw-sig).
      cl=$(grep -a 'CLASSIFY id=' "$OUT/t3-blog-$m-$c.txt" | tail -1)
      if [ -n "$cl" ]; then
        csrc=$(printf '%s' "$cl" | grep -aoE 'src=[a-z-]+' | head -1 | cut -d= -f2)
        cetw=$(printf '%s' "$cl" | grep -aoE 'etw=[a-z-]+' | head -1 | cut -d= -f2)
        ccorr=$(printf '%s' "$cl" | grep -aoE 'corr=[a-z-]+' | head -1 | cut -d= -f2)
        cver=$(printf '%s' "$cl" | grep -aoE 'verdict=[a-z]+' | head -1 | cut -d= -f2)
      fi
      # push vs 30s floor: wall-clock fire->CLASSIFY. <15s = NotificationChanged woke the
      # listing; 15-40s = the floor did. TODO(RIG)#5. dt=- means never detected (also a datum).
      if [ "$dt" != - ]; then
        [ "$dt" -lt 15 ] && push=push || push=floor
      fi
      # the wpndb row for THIS toast + the id join (§10.20.5 item 1): --dump-wpndb prints
      # 'ROW id=N ... aumid=...' followed by its 'PAYLOAD <xml>' line - pin the row whose
      # payload carries this row's unique title, then compare its id to the signal's idnum.
      raspush "$OUT/p3a-dumpwpndb.ps1" "" "t3d$RANDOM" > "$OUT/t3-wpndb-$m-$c.txt" 2>&1
      rowid=$(awk -v t="$tt" '/^ROW id=/{split($2,a,"="); rid=a[2]} /^PAYLOAD /{if (rid != "" && index($0,t)) {print rid; exit}}' "$OUT/t3-wpndb-$m-$c.txt")
      [ -n "$rowid" ] || rowid=-
      if [ "${idnum:-0}" = 0 ]; then join=no-id
      elif [ "$rowid" = - ]; then join=no-row
      elif [ "$idnum" = "$rowid" ]; then join=yes
      else join=MISMATCH; fi
    fi
    printf '%-15s %-14s %-6s %-4s %-12s %-12s %-9s %-8s %-9s %-18s %-8s %-6s %s\n' \
      "$m" "$c" "$fired" "$sig" "${idnum:-0}" "$rowid" "$join" "$csrc" "$cetw" "$ccorr" "$cver" "$push" "$dt" >> "$TBL"
    if [ "$c" = informational ]; then T3JOIN[$m]=$join; T3CORR[$m]=$ccorr; T3SIG[$m]=$sig; fi
    if [ "$m" = start-shortcut ] && [ "$c" = informational ]; then
      [ "$sig" = yes ] && [ "$csrc" = etw-sig ] && [ "$cver" = bridge ] \
        && { [ "$ccorr" = id-ok ] || [ "$ccorr" = sig-unique ]; } && t3canon=1
      [ "$fired" = no ] && t3canonmiss=1   # tf_fire already logged the INSTRUMENT loudly
    fi
    dismiss_toasts "${TFAUMID[$m]}"
  done
done
log "T3 table:"; cat "$TBL" | tee -a "$R"
if [ -n "$t3canon" ]; then
  verdict T3 "PASS canonical row (start-shortcut x informational) classifies src=etw-sig, corr in {id-ok,sig-unique}, verdict=bridge - signal + targeted read carry the tier; full 6-row table in t3-table.txt"
elif [ -n "$t3canonmiss" ]; then
  verdict T3 "INSTRUMENT canonical row never exercised (fire/offset probe failed) - targeted-read coverage UNGRADED, not disproven"
else
  verdict T3 "FAIL canonical row: signal or targeted read failed (see its src/etw/corr/verdict in t3-table.txt) - a FALL-TO-DB datum even though T2's frames flow (tier D stays primary, §10.16.4)"
fi
# T3j - the id-join verdict (§10.20.5 item 1), from the informational rows. Rules:
#   (1) join=yes + corr=id-ok is the clean primary path; join=yes + corr=sig-unique is a
#       DATUM, not a fail (the advisory first-<text>-vs-title check legitimately falls
#       through to the fallback on a title-render difference - notifhost never lets a
#       text-mismatched row earn id-ok);
#   (2) a NON-JOINING signalled method (no-id/no-row/MISMATCH) must be SEEN taking
#       corr=sig-unique - the fallback carrying it is the §10.20.5#1 requirement;
#   (3) corr=id-ok alongside a non-joining record is INCOHERENT (the read pinned a row the
#       measured join contradicts - the aumid cross-check should have refused it): FAIL.
t3jbad=""; t3joins=0; t3nonj=0
for m in start-shortcut com-activator bare; do
  j="${T3JOIN[$m]:--}"; k="${T3CORR[$m]:--}"; s="${T3SIG[$m]:--}"
  log "T3j: method=$m join=$j corr=$k sig=$s"
  [ "$j" = yes ] && t3joins=$((t3joins+1))
  [ "$s" = yes ] || continue     # no signal for the row: T2/T3 grade that, the join cannot
  case "$j" in
    yes)
      case "$k" in
        id-ok) : ;;
        sig-unique) log "T3j DATUM: $m joins by id but classified corr=sig-unique - the advisory title check fell through (title rendering, record for the rig)" ;;
        *) t3jbad="$t3jbad $m:joined-but-corr=$k" ;;
      esac ;;
    no-id|no-row|MISMATCH)
      t3nonj=$((t3nonj+1))
      if [ "$k" = id-ok ]; then t3jbad="$t3jbad $m:corr=id-ok-despite-join=$j(INCOHERENT)"
      elif [ "$k" != sig-unique ]; then t3jbad="$t3jbad $m:non-joining($j)-not-carried-by-fallback(corr=$k)"
      fi ;;
  esac
done
if [ -z "$t3jbad" ]; then
  if [ "$t3joins" -ge 1 ]; then
    verdict T3j "PASS id join VERIFIED live: notificationId == wpndb ROW id on $t3joins/3 methods; $t3nonj non-joining signalled method(s), each carried by corr=sig-unique"
  else
    verdict T3j "PASS-DATUM id join DEAD on this build (0/3 methods join) - every signalled method fell back cleanly to corr=sig-unique, the fallback carries the tier (a §10.20.2 design datum, not a defect; the id path stays first-try+retries by design)"
  fi
else
  verdict T3j "FAIL id-join incoherences:$t3jbad (see t3-table.txt; join=MISMATCH means the ETW notificationId does NOT equal the wpndb ROW id for the same toast)"
fi

# ---------- T4 the never-SYSTEM guard (exit 9), both directions ------------------------------
# This ALSO fires the PROXY-SIDE refuse machinery (its own census/guard path), which T5 cannot
# reach — the agent-side census refuses drift BEFORE launching, so exit-9-on-drift is only
# observable via a hand launch. T4a is that hand launch's SYSTEM flavor.
log "T4: never-SYSTEM guard - SYSTEM launch must exit 9, plain-user launch must NOT"
t4sys=$(enc_run 'Remove-Item C:\ProgramData\Qubes\p3a-sysproxy-out.txt -Force -EA SilentlyContinue; $p = Start-Process -FilePath "C:\Program Files\Qubes Tools\bin\etwproxy.exe" -NoNewWindow -PassThru -RedirectStandardOutput "C:\ProgramData\Qubes\p3a-sysproxy-out.txt"; if ($p.WaitForExit(20000)) { "P3ARC=" + $p.ExitCode } else { $p.Kill(); "P3ARC=RUNAWAY" }')
printf '%s\n' "$t4sys" > "$OUT/t4-sys.txt"
enc_run 'if (Test-Path C:\ProgramData\Qubes\p3a-sysproxy-out.txt) { Get-Content C:\ProgramData\Qubes\p3a-sysproxy-out.txt }' | tr -d '\r' >> "$OUT/t4-sys.txt" 2>/dev/null
t4rc=$(grep -aoE 'P3ARC=[A-Z0-9-]+' "$OUT/t4-sys.txt" | tail -1 | cut -d= -f2)
# stdout spelling: the guard's printf says "refusing to run the untrusted ETW/TDH parse under
# a privileged ..."; 'never-SYSTEM guard' is its BLog twin (which a refused token cannot write)
if [ "$t4rc" = 9 ] && grep -qaE 'never-SYSTEM guard|refusing to run the untrusted' "$OUT/t4-sys.txt"; then
  verdict T4a "PASS SYSTEM launch refused: exit 9 + never-SYSTEM guard line"
elif [ "$t4rc" = 9 ]; then
  verdict T4a "PASS SYSTEM launch exit 9 (guard line not captured - check t4-sys.txt redirect)"
else
  verdict T4a "FAIL SYSTEM launch rc='$t4rc' (wanted 9) - the guard did NOT refuse a privileged token"
fi
t4usr=$(raspush "$OUT/p3a-userproxy.ps1" "" t4u); printf '%s\n' "$t4usr" > "$OUT/t4-user.txt"
t4urc=$(grep -aoE 'P3ARC=[A-Z0-9-]+' "$OUT/t4-user.txt" | tail -1 | cut -d= -f2)
if [ "$t4urc" = 9 ]; then
  # TODO(RIG)#4: an elevated interactive token (EnableLUA=0) trips the guard LEGITIMATELY.
  if grep -qaE 'never-SYSTEM guard|refusing to run the untrusted|token DRIFT' "$OUT/t4-user.txt"; then
    verdict T4b "INSTRUMENT plain-user arm got 9 but the output shows the interactive token is itself privileged - arm precondition unmet on this image, not a product verdict: $(grep -aE 'never-SYSTEM|DRIFT' "$OUT/t4-user.txt" | head -1 | head -c 200)"
  else
    verdict T4b "FAIL plain-user launch exit 9 with no guard/drift line - guard misfiring on an unprivileged token"
  fi
elif [ -n "$t4urc" ]; then
  verdict T4b "PASS plain-user launch rc=$t4urc != 9 (expected 5: no grant for that token; guard reserved for privileged tokens)"
else
  verdict T4b "INSTRUMENT plain-user arm returned no P3ARC ($(tail -2 "$OUT/t4-user.txt" | tr '\n' ';' | head -c 200)) - ungraded"
fi

# ---------- T5 DRIFT fail-proof (seen-to-fail) + the src=db control arm ----------------------
# Inject the exact drift the census exists to catch (PLU membership), force a relaunch, and the
# detector MUST fire + park. This is experimenter rule 3b for T1b/T1d AND rule 5's switchable
# defect: injected, proven seen by the same probe T1d used, then removed and the healthy tier
# re-proven (T6). While parked, the same burst T6 will fire feeds the src=db latency control.
log "T5: drift fail-proof - PLU added by hand => census must REFUSE + park (then restore)"
enc_run '& net localgroup "Performance Log Users" qubes-etwproxy /add *> $null; (net localgroup "Performance Log Users") -join "|"' | tr -d '\r' > "$OUT/t5-plu-after-add.txt"
if ! grep -qai "$ACCT" "$OUT/t5-plu-after-add.txt"; then
  verdict T5 "INSTRUMENT PLU membership add did not land - drift never injected, detector ungraded (NOT a product verdict)"
else
  log "T5: drift injected AND seen by the T1d probe (its fail direction is now proven)"
  AM5=$(amark); [ -n "$AM5" ] || AM5=0   # amark's pipeline exits 0 even when empty - test output
  # kill the running proxy (session-0 etwproxy.exe, BY PID - never the user-session notifhost
  # bridge); the agent's exit-wait relaunches it, and THAT launch's census meets the drifted
  # token. (Filter RIG-RECONCILED 2026-09-05: the console split renamed the proxy binary.)
  enc_run 'tasklist /nh /fo csv /fi "imagename eq etwproxy.exe"' | tr -d '\r' > "$OUT/t5-tasklist.csv"
  ppid=$(awk -F'","' '$4 == "0" {gsub(/"/,"",$2); print $2}' "$OUT/t5-tasklist.csv" | head -1)
  if [ -z "$ppid" ]; then
    verdict T5 "INSTRUMENT no session-0 proxy to kill (tier already down?) - drift relaunch cannot be forced, ungraded"
  else
    qrun "taskkill /f /pid $ppid" >/dev/null 2>&1
    t5seen=""; _wt5=$SECONDS
    for i in $(seq 1 24); do   # nominal 120s: 5s backoff floor + census; TODO(RIG)#7
      # wall cap 150s (the documented 120s window + margin; asince is a ~55s-capped enc_run
      # per turn, so seq*sleep alone could stretch this to ~25 min - audit 2026-09-06)
      a5=$(asince "$AM5" 'ETWPROXYSUP')
      printf '%s' "$a5" | grep -qa 'PROVISIONING DRIFT' && printf '%s' "$a5" | grep -qa 'parked for this boot' && { t5seen=1; break; }
      [ $(( SECONDS - _wt5 )) -ge 150 ] && break
      sleep 5
    done
    log "T5: drift-park wait exit=$([ -n "$t5seen" ] && echo success || echo deadline) t=$((SECONDS-_wt5))s (i=$i/24)"
    printf '%s\n' "$a5" > "$OUT/t5-agentlines.txt"
    if [ -n "$t5seen" ]; then
      verdict T5 "PASS drift detector FIRED: agent census refused (PROVISIONING DRIFT) and the tier parked ($(printf '%s' "$a5" | grep -a 'parked for this boot' | tail -1 | head -c 160)). Proxy-side refuse machinery proven separately in T4a."
    else
      verdict T5 "FAIL drift injected + proxy killed but no DRIFT/park within the 150s wall budget - the detector did NOT fire (agent lines: $(printf '%s' "$a5" | grep -a 'ETWPROXYSUP' | tail -2 | tr '\n' ';' | head -c 240))"
    fi
    # src=db CONTROL ARM: tier parked => the shadow ladder must serve from the DB rung. Any
    # src=etw-sig line here means the park LEAKED - a product assert, not just instrumentation.
    # A 0-default offset would scan T2/T3's legitimate src=etw-sig lines and false-FAIL the
    # park, so an unreadable offset makes the arm UNGRADED, never guessed.
    if ! L5=$(blog_len); then
      verdict T5db "INSTRUMENT blog_len unreadable before the parked burst - control arm ungraded"
    else
      t5fired=""
      tf_fire '--fire --method start-shortcut --class informational --title P3A-t5-db --tag t5db --count 5 --interval-ms 3000' > "$OUT/t5-fire.txt" 2>&1 && t5fired=1
      sleep 40
      blog_since "$L5" | grep -a 'CLASSIFY id=' > "$OUT/t5-classify.txt" || true
      dismiss_toasts "${TFAUMID[start-shortcut]}"
      t5etw=$(grep -ca 'src=etw-sig' "$OUT/t5-classify.txt" || true)
      t5db=$(grep -ca 'src=db' "$OUT/t5-classify.txt" || true)
      grep -a 'src=db' "$OUT/t5-classify.txt" | grep -aoE 'row_latency=[0-9]+' | cut -d= -f2 > "$OUT/t5-db-lat.txt"
      # leak check FIRST (valid regardless of fire confirmation: ANY etw-sig line while parked
      # is a leak); an unconfirmed fire then demotes the thin-arm outcome to INSTRUMENT rather
      # than misgrading a no-op burst (audit 2026-09-06)
      if [ "${t5etw:-0}" != 0 ]; then
        verdict T5db "FAIL $t5etw src=etw-sig CLASSIFY lines while PARKED - the park leaked live ETW signal frames"
      elif [ -z "$t5fired" ]; then
        verdict T5db "INSTRUMENT parked burst never confirmed FIRED (tf_fire logged the miss) - control arm ungraded, NOT a product verdict"
      elif [ "${t5db:-0}" -ge 3 ]; then
        verdict T5db "PASS parked burst served by the DB rung ($t5db src=db rows; latencies banked for T6: $(paste -sd, "$OUT/t5-db-lat.txt"))"
      else
        verdict T5db "INSTRUMENT only ${t5db:-0} src=db rows from a 5-burst while parked - control arm too thin, T6's comparison will be ungradeable"
      fi
    fi
  fi
fi
# RESTORE (the switch's off position), then a COLD BOOT - parking is per-boot by design, so the
# boot is the documented un-park path (and doubles as the §10.16.2 boot-path element).
enc_run '& net localgroup "Performance Log Users" qubes-etwproxy /delete *> $null; (net localgroup "Performance Log Users") -join "|"' | tr -d '\r' > "$OUT/t5-plu-after-del.txt"
grep -qai "$ACCT" "$OUT/t5-plu-after-del.txt" \
  && { verdict T5r "FAIL PLU membership removal did not land - guest left drifted, aborting before T6 measures garbage"; exit 1; }
log "T5r: PLU removed; cold boot to un-park"
coldboot t5r || { verdict T5r "FAIL no session after restore cold boot"; exit 1; }
bridge_up 0 || { verdict T5r "FAIL bridge never up after restore boot"; exit 1; }
if etw_tier_up 0 0; then
  cen5=$(asince_hits 0 'ETWPROXYSUP consumer token census' | tail -1)
  printf '%s' "$cen5" | grep -qa 'plu=0 admin=0 se_system_profile=0' \
    && verdict T5r "PASS restored: census clean again, tier up (defect switchable both ways)" \
    || verdict T5r "FAIL tier up but census not clean after restore: $(printf '%s' "$cen5" | head -c 160)"
else
  verdict T5r "FAIL ETW tier did not return after drift removal + cold boot ($(asince_hits 0 'ETWPROXYSUP parked' | tail -1 | head -c 200))"
fi

# ---------- T6 LATENCY: src=etw-sig vs the T5 src=db control + heartbeat cadence -------------
log "T6: latency - same burst as T5, tier up; CLASSIFY row_latency etw-sig-vs-db + heartbeat gap"
# background heartbeat mtime sampler (SYSTEM, survives the qrexec call; read back afterwards)
hbps='$o="C:\ProgramData\Qubes\p3a-hbsample.txt"; Remove-Item $o -Force -EA SilentlyContinue; $hb="C:\ProgramData\qubes-toast-bridge\heartbeat"; 1..40 | ForEach-Object { $t=0; $it=Get-Item -LiteralPath $hb -EA SilentlyContinue; if ($it) { $t=$it.LastWriteTimeUtc.Ticks }; Add-Content -LiteralPath $o -Value "$t"; Start-Sleep -Milliseconds 900 }'
qrun "cmd /c start /b powershell -NoProfile -EncodedCommand $(_ps_enc "$hbps")" >/dev/null 2>&1
sleep 2
if ! L6=$(blog_len); then
  # A 0-default would pull T5's src=db rows and T2/T3's src=etw-sig rows into this window and
  # fabricate a latency comparison - ungraded, never guessed.
  verdict T6 "INSTRUMENT blog_len unreadable before the tier-up burst - latency arm ungraded"
else
  conn6a=$(blog_since 0 | grep -ca "connected (server version" || true)
  t6fired=""
  tf_fire '--fire --method start-shortcut --class informational --title P3A-t6-etw --tag t6etw --count 5 --interval-ms 3000' > "$OUT/t6-fire.txt" 2>&1 && t6fired=1
  sleep 40
  blog_since "$L6" > "$OUT/t6-blog.txt" 2>/dev/null
  grep -a 'CLASSIFY id=' "$OUT/t6-blog.txt" > "$OUT/t6-classify.txt" || true
  conn6b=$(blog_since 0 | grep -ca "connected (server version" || true)
  dismiss_toasts "${TFAUMID[start-shortcut]}"
  grep -a 'src=etw-sig' "$OUT/t6-classify.txt" | grep -aoE 'row_latency=[0-9]+' | cut -d= -f2 > "$OUT/t6-etw-lat.txt"
  n6=$(wc -l < "$OUT/t6-etw-lat.txt")
  m6=$(med < "$OUT/t6-etw-lat.txt")
  m5=$(med < "$OUT/t5-db-lat.txt" 2>/dev/null)
  log "T6: src=etw-sig rows=$n6 median=${m6}ms vs T5 src=db median=${m5}ms (raw: etw-sig=$(paste -sd, "$OUT/t6-etw-lat.txt") db=$(paste -sd, "$OUT/t5-db-lat.txt" 2>/dev/null))"
  if [ -z "$t6fired" ]; then
    # an unconfirmed burst cannot produce rows - grading the empty window as "tier not
    # serving" would be a dishonest cascade (audit 2026-09-06; tf_fire logged the miss)
    verdict T6 "INSTRUMENT tier-up burst never confirmed FIRED - latency arm ungraded, NOT a product verdict"
  elif [ "${n6:-0}" -lt 3 ] || [ "$m6" = NA ]; then
    verdict T6 "FAIL only ${n6:-0} src=etw-sig rows from a 5-burst with the tier up - signal+targeted-read tier not serving ($(grep -a 'etw=' "$OUT/t6-classify.txt" | tail -2 | tr '\n' ';' | head -c 240))"
  elif [ "$m5" = NA ] || [ -z "$m5" ]; then
    verdict T6 "INSTRUMENT no src=db control distribution from T5 - etw-sig median=${m6}ms recorded, comparison ungraded"
  elif awk -v a="$m6" -v b="$m5" 'BEGIN{exit !(a<b)}'; then
    verdict T6 "PASS src=etw-sig (median ${m6}ms) beats src=db (median ${m5}ms) - the WAL-retry ceiling is removed (§10.1.2 datum; §10.20.5#4 wants it well under the DB rung's 47ms baseline - record the raw medians either way)"
  else
    verdict T6 "FAIL src=etw-sig median ${m6}ms does NOT beat src=db ${m5}ms - the tier buys nothing on this build"
  fi
  [ "$conn6a" = "$conn6b" ] && log "T6: no supervisor relaunch during the burst (connected-count stable at $conn6a)" \
    || verdict T6sup "FAIL supervisor relaunched the bridge during the burst (connected-count $conn6a -> $conn6b)"
fi
# heartbeat cadence during the burst: max gap between successive DISTINCT mtimes
enc_run 'if (Test-Path C:\ProgramData\Qubes\p3a-hbsample.txt) { Get-Content C:\ProgramData\Qubes\p3a-hbsample.txt }' | tr -d '\r' | grep -aoxE '[0-9]+' > "$OUT/t6-hbsample.txt"
hbgap=$(awk '$1>0 { if (prev>0 && $1!=prev) { d=($1-prev)/10000000; if (d>max) max=d } prev=$1 } END{printf "%.1f", max+0}' "$OUT/t6-hbsample.txt")
if [ -z "$hbgap" ] || [ "$hbgap" = "0.0" ]; then
  verdict T6hb "INSTRUMENT heartbeat sampler saw no mtime change in ~36s (sampler broken or file absent; $(wc -l < "$OUT/t6-hbsample.txt") samples) - cadence ungraded"
elif awk -v g="$hbgap" 'BEGIN{exit !(g<=4.0)}'; then
  verdict T6hb "PASS heartbeat max gap ${hbgap}s <= 4s during the burst (TODO(RIG)#9)"
else
  verdict T6hb "FAIL heartbeat max gap ${hbgap}s > 4s during the burst - a pass is blocking the loop"
fi

# ---------- T7 A0 regression: the shadow probe is MEASURE-ONLY -------------------------------
# Routing must be exactly A0's per-app split: allowlisted PS AUMID forwards (delivered per
# fwd_count) and earns lazy suppression; non-allowlisted control stays windowed with
# 'skip id='; the toastfire bursts above produced ZERO forward attempts (their AUMIDs are not
# allowlisted - the classifier WATCHED them, it must not have ROUTED them); and no supervisor
# relaunch happened. Forward detectors are a0-lib's fwd_count/fwd_attempts (audit 2026-09-05):
# NEGATIVE must-be-zero asserts use fwd_attempts (ANY anchored SENT line, any outcome, or ANY
# FWD_RTT line) because BLog's share-mode collision can DROP a SENT line while the forward
# happened and FWD_RTT ok=1 still records it - a SENT-only grep can HIDE a real forward, the
# exact leak-safety hole the a0 fix closed. POSITIVE delivered asserts use fwd_count (distinct
# ids across the FWD_RTT ok=1 / SENT..OK union + acked coalesced batches), which survives the
# same dropped-SENT shape without false-FAILing. Both proven both directions by fwd_selftest
# in T0i - that is the named seen-to-fail proof for every T7 assert below.
log "T7: A0 regression slice - forward/skip/SHOWBANNER unchanged, shadow measure-only"
if [ -s "$OUT/t6-blog.txt" ]; then
  t6fwd=$(fwd_attempts "$OUT/t6-blog.txt")
  [ "${t6fwd:-0}" = 0 ] \
    && verdict T7a "PASS measure-only: 0 forward-attempt lines (SENT/FWD_RTT, fwd_attempts) for the (non-allowlisted) toastfire burst - shadow classification did not route" \
    || verdict T7a "FAIL $t6fwd forward-attempt line(s) (SENT/FWD_RTT) during the toastfire burst - the shadow probe ROUTED (or attempted to route) a toast it may only measure"
else
  verdict T7a "INSTRUMENT no T6 burst window on record (T6 was ungraded) - measure-only assert has nothing to judge, NOT a vacuous pass"
fi
if ! Lw=$(blog_len); then
  verdict T7b "INSTRUMENT blog_len unreadable - allowlisted-forward arm ungraded"
else
  # Forward waits: seq 15 AND wall cap 90s each (expected ack within seconds; blog_since is a
  # ~55s-capped qrun per turn). A fire that never confirmed FIRED is TERMINAL for its wait -
  # skip and grade INSTRUMENT, never burn the budget then misgrade (audit 2026-09-06).
  t7binst=""
  w7=""
  if fire_info "A0T p3a-warmup" > /dev/null 2>&1; then   # toast #1 earns lazy suppression
    # POSITIVE delivered assert -> fwd_count: a collision-dropped SENT line must not false-FAIL
    # a toast that WAS delivered (FWD_RTT ok=1 records it) - the a0-lib dropped-SENT fix.
    _w7a=$SECONDS
    for i in $(seq 1 15); do
      blog_since "$Lw" > "$OUT/t7b-warm-blog.txt" 2>/dev/null
      [ "$(fwd_count "$OUT/t7b-warm-blog.txt")" -ge 1 ] && { w7=1; break; }
      [ $(( SECONDS - _w7a )) -ge 90 ] && break
      sleep 2
    done
  else
    t7binst="warmup-never-FIRED"
    log "T7b: warm-up never confirmed FIRED (terminal - forward wait skipped)"
  fi
  sleep 3
  if L7=$(blog_len); then
    s7base=0
  else
    # fall back to the warmup offset: same boot, only over-scans OUR window - but then the
    # warmup's OWN forward sits inside the check window, so the check must EXCEED the count
    # banked at fallback time (the old SENT grep was vacuously satisfied by the warmup's
    # already-present line here - the fallback could never fail)
    L7=$Lw
    blog_since "$Lw" > "$OUT/t7b-warm-blog.txt" 2>/dev/null
    s7base=$(fwd_count "$OUT/t7b-warm-blog.txt")
  fi
  s7=""
  if fire_info "A0T p3a-bridged" > /dev/null 2>&1; then   # toast #2 must forward while suppressed
    _w7b=$SECONDS
    for i in $(seq 1 15); do
      blog_since "$L7" > "$OUT/t7b-check-blog.txt" 2>/dev/null
      [ "$(fwd_count "$OUT/t7b-check-blog.txt")" -gt "${s7base:-0}" ] && { s7=1; break; }
      [ $(( SECONDS - _w7b )) -ge 90 ] && break
      sleep 2
    done
  else
    t7binst="${t7binst:+$t7binst + }check-never-FIRED"
    log "T7b: check toast never confirmed FIRED (terminal - delivery wait skipped)"
  fi
  sb7=$(showbanner)
  if [ -n "$t7binst" ]; then
    verdict T7b "INSTRUMENT fire path failed ($t7binst) - allowlisted-forward arm ungraded, NOT a product verdict ($sb7)"
  elif [ -n "$w7" ] && [ -n "$s7" ]; then
    verdict T7b "PASS allowlisted path forwards (warmup + check both delivered per fwd_count; $sb7)"
  else
    verdict T7b "FAIL allowlisted forward broken: warmup=${w7:-no} check=${s7:-no} $sb7"
  fi
fi
if ! L7c=$(blog_len); then
  verdict T7c "INSTRUMENT blog_len unreadable - control arm ungraded"
else
  c7fired=""
  fire_ctl "A0T p3a-control" > /dev/null 2>&1 && c7fired=1
  sleep 10
  blog_since "$L7c" > "$OUT/t7-ctl-blog.txt"
  c7skip=$(grep -ca 'skip id=' "$OUT/t7-ctl-blog.txt" || true)
  # NEGATIVE must-not-forward assert -> fwd_attempts (any SENT or FWD_RTT line): a dropped
  # SENT must not hide a real forward of the control toast (see the T7 header rationale)
  c7fwd=$(fwd_attempts "$OUT/t7-ctl-blog.txt")
  dismiss_toasts "$CTLAUMID"; dismiss_toasts
  # forward-leak half is valid regardless of fire confirmation; the skip half needs the fire
  if [ "${c7fwd:-0}" != 0 ]; then
    verdict T7c "FAIL control routing: forward attempted (skip=$c7skip fwd_attempts=$c7fwd)"
  elif [ -z "$c7fired" ]; then
    verdict T7c "INSTRUMENT control toast never confirmed FIRED - skip-line half ungraded (no forward attempts seen, which IS valid), NOT a product verdict"
  elif [ "${c7skip:-0}" -ge 1 ]; then
    verdict T7c "PASS control AUMID skipped, not forwarded (skip=$c7skip fwd_attempts=$c7fwd)"
  else
    verdict T7c "FAIL control routing: skip=$c7skip fwd_attempts=$c7fwd"
  fi
fi

# ---------- T8 §10.20.5#5 fail-open drills (each failure class DEMONSTRATED) -----------------
# The proxy-kill-mid-run => src=db drill is already proven by T5's parked control arm; the
# three below are the hybrid-specific ones. One variable per drill; T8c perturbs the tier and
# re-proves recovery so the subject is left sane. Runs LAST so a drill mishap cannot pollute
# the measurement phases.
log "T8: hybrid fail-open drills (fire+purge, twins, pipe squatter)"

# T8a fire+purge: purge the wpndb row before the targeted read completes => the signal-keyed
# read must fail OPEN to the window floor - corr=id-norow on an id-joining signal, sig-norow
# on an id-less one - and src must stay 'none', NEVER 'db': the DB rung is the ETW-DOWN
# fallback, not a second guess at a row the precise signal-keyed read already failed to pin
# (ShadowClassifyWork's sig-hit branch owns the outcome; this drill is its seen-to-fail).
# The purge races BOTH the WAL-paced read (3 attempts, ~1.5s worst - purge too late = id-ok)
# AND the bridge listener (purge before the toast is listed = no CLASSIFY at all), so the
# delay is laddered and a lost race is an instrument miss, not a product verdict (TODO(RIG)#12).
t8a=""
for d in 200 500 1000; do
  if ! L8=$(blog_len); then log "T8a INSTRUMENT: blog_len unreadable - delay=${d}ms attempt skipped"; continue; fi
  o=$(raspush "$OUT/p3a-firepurge.ps1" "${TFAUMID[start-shortcut]} $d --fire --method start-shortcut --class informational --title P3A-t8a-$d --tag t8a$d" "t8a$d")
  printf '%s\n' "$o" > "$OUT/t8a-fire-$d.txt"
  printf '%s' "$o" | grep -qa 'FIRED method=' || { log "T8a: delay=${d}ms never FIRED - instrument miss, next rung"; continue; }
  printf '%s' "$o" | grep -qa 'FPWRAP purged=1' || { log "T8a: delay=${d}ms purge did not land ($(printf '%s' "$o" | grep -a 'FPWRAP purged' | head -c 120)) - instrument miss, next rung"; continue; }
  cl=""; _w8a=$SECONDS
  for i in $(seq 1 15); do
    # wall cap 90s (expected: CLASSIFY <45s; ~55s-capped qrun per turn - audit 2026-09-06)
    cl=$(blog_since "$L8" | grep -a 'CLASSIFY id=' | tail -1)
    [ -n "$cl" ] && break
    [ $(( SECONDS - _w8a )) -ge 90 ] && break
    sleep 3
  done
  printf '%s\n' "$cl" > "$OUT/t8a-classify-$d.txt"
  if [ -z "$cl" ]; then log "T8a: delay=${d}ms produced no CLASSIFY (purge likely beat the listener) - next rung is slower"; continue; fi
  a_src=$(printf '%s' "$cl" | grep -aoE 'src=[a-z-]+' | head -1 | cut -d= -f2)
  a_etw=$(printf '%s' "$cl" | grep -aoE 'etw=[a-z-]+' | head -1 | cut -d= -f2)
  a_corr=$(printf '%s' "$cl" | grep -aoE 'corr=[a-z-]+' | head -1 | cut -d= -f2)
  a_ver=$(printf '%s' "$cl" | grep -aoE 'verdict=[a-z]+' | head -1 | cut -d= -f2)
  log "T8a: delay=${d}ms => src=$a_src etw=$a_etw corr=$a_corr verdict=$a_ver"
  if [ "$a_corr" = id-norow ] || [ "$a_corr" = sig-norow ]; then
    if [ "$a_ver" = window ] && [ "$a_src" != db ]; then
      verdict T8a "PASS fire+purge fails open: etw=$a_etw corr=$a_corr verdict=window src=$a_src (delay=${d}ms) - the targeted read landed on the window floor and never second-guessed via the DB rung"
    else
      verdict T8a "FAIL fire+purge reached corr=$a_corr but verdict=$a_ver src=$a_src - a purged row must land on the WINDOW floor, never db/bridge"
    fi
    t8a=1; break
  fi
  log "T8a: delay=${d}ms lost the race (corr=$a_corr) - next rung"
done
[ -n "$t8a" ] || verdict T8a "INSTRUMENT fire+purge never won its race across the 200/500/1000ms ladder (see t8a-*.txt) - drill unproven, not disproven; TODO(RIG)#12 tune the delay on the rig"
dismiss_toasts "${TFAUMID[start-shortcut]}"

# T8b twins => corr=sig-ambiguous => verdict=window (never guess). Reachable ONLY through the
# signal-FALLBACK: an id-joining signal pins its row and can never be ambiguous, so the
# subject method comes from T3's MEASURED join data - and even then the fallback narrows by
# n.Tag when the signal carries one (toastfire twins need DISTINCT tags, or Windows REPLACES
# the first toast instead of stacking a twin). Both preconditions are build properties this
# drill measures rather than assumes (TODO(RIG)#13).
t8m=""
for m in start-shortcut com-activator bare; do
  [ "${T3SIG[$m]:-}" = yes ] || continue
  case "${T3JOIN[$m]:--}" in no-id|no-row|MISMATCH) t8m=$m; break;; esac
done
if [ -z "$t8m" ]; then
  verdict T8b "SKIPPED-PRECONDITION every signalled method joined by id in T3 - corr=sig-ambiguous is unreachable via toastfire on this build (the id path pins its row); a measured datum, not a vacuous pass: ambiguity handling stays covered by review only (TODO(RIG)#13)"
elif ! L8b=$(blog_len); then
  verdict T8b "INSTRUMENT blog_len unreadable before the twin burst - drill ungraded"
else
  log "T8b: twin drill on non-joining method=$t8m (T3 join=${T3JOIN[$t8m]})"
  f8b=0
  tf_fire "--fire --method $t8m --class informational --title P3A-t8b-twin --tag t8btw1" > "$OUT/t8b-fire1.txt" 2>&1 && f8b=$((f8b+1))
  tf_fire "--fire --method $t8m --class informational --title P3A-t8b-twin --tag t8btw2" > "$OUT/t8b-fire2.txt" 2>&1 && f8b=$((f8b+1))
  ncl=0
  if [ "$f8b" = 2 ]; then
    _w8b=$SECONDS
    for i in $(seq 1 15); do
      # wall cap 90s (expected: both CLASSIFY lines <45s; ~55s-capped qrun per turn)
      blog_since "$L8b" | grep -a 'CLASSIFY id=' > "$OUT/t8b-classify.txt" || true
      ncl=$(grep -ca 'CLASSIFY id=' "$OUT/t8b-classify.txt" || true)
      [ "${ncl:-0}" -ge 2 ] && break
      [ $(( SECONDS - _w8b )) -ge 90 ] && break
      sleep 3
    done
  else
    : > "$OUT/t8b-classify.txt"
    log "T8b: only $f8b/2 twin fires confirmed FIRED (terminal - CLASSIFY wait skipped)"
  fi
  dismiss_toasts "${TFAUMID[$t8m]}"
  if [ "$f8b" -lt 2 ]; then
    verdict T8b "INSTRUMENT only $f8b/2 twin fires confirmed FIRED - drill ungraded (fires that never happened cannot twin)"
  elif [ "${ncl:-0}" -lt 2 ]; then
    verdict T8b "INSTRUMENT only ${ncl:-0}/2 twin CLASSIFY lines - drill ungraded (t8b-classify.txt)"
  elif grep -qa 'corr=sig-ambiguous' "$OUT/t8b-classify.txt"; then
    amb=$(grep -a 'corr=sig-ambiguous' "$OUT/t8b-classify.txt" | tail -1)
    printf '%s' "$amb" | grep -qa 'verdict=window' \
      && verdict T8b "PASS twins forced corr=sig-ambiguous and the verdict stayed WINDOW (never guess): $(printf '%s' "$amb" | head -c 160)" \
      || verdict T8b "FAIL corr=sig-ambiguous with verdict!=window - the never-guess rule is broken: $(printf '%s' "$amb" | head -c 200)"
  elif [ "$(grep -ca 'corr=sig-unique' "$OUT/t8b-classify.txt" || true)" -ge 2 ]; then
    verdict T8b "SKIPPED-PRECISE twins both classified corr=sig-unique - the signal's tag/group keeps the fallback query precise on this build; ambiguity unreachable via toastfire (measured datum, TODO(RIG)#13)"
  else
    verdict T8b "INSTRUMENT twins produced neither sig-ambiguous nor 2x sig-unique ($(grep -a 'corr=' "$OUT/t8b-classify.txt" | tail -2 | tr '\n' ';' | head -c 240)) - reconcile on the rig"
  fi
fi

# T8c pipe squatter => proxy exit 8, tier down, DB serves, then RECOVERY. Sequencing: the
# live proxy HOLDS the single-instance pipe name, so the squatter starts FIRST in retry mode
# (it grabs the name the moment the killed proxy releases it), then the proxy is killed; the
# agent's relaunch meets the squatted name => 'ETWPROXY FAIL CreateNamedPipe ... (squatter
# holding the name?)' => exit 8 => backoff. The squatter self-bounds (45s grab window, 120s
# hold) so nothing is left running whatever happens.
sq='$p=$null; $deadline=(Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  try { $p = New-Object System.IO.Pipes.NamedPipeServerStream("qubes-toast-etw",[System.IO.Pipes.PipeDirection]::Out,1); break } catch { Start-Sleep -Milliseconds 200 }
}
if ($p) { Set-Content C:\ProgramData\Qubes\p3a-squat.txt "SQUAT-HELD"; Start-Sleep -Seconds 120; $p.Dispose(); Add-Content C:\ProgramData\Qubes\p3a-squat.txt "SQUAT-RELEASED" }
else { Set-Content C:\ProgramData\Qubes\p3a-squat.txt "SQUAT-NEVER" }'
enc_run 'Remove-Item C:\ProgramData\Qubes\p3a-squat.txt -Force -EA SilentlyContinue; "SQCLEAN"' >/dev/null
qrun "cmd /c start /b powershell -NoProfile -EncodedCommand $(_ps_enc "$sq")" >/dev/null 2>&1
AM8=$(amark); [ -n "$AM8" ] || AM8=0
L8c=$(blog_len) || L8c=""
# kill the session-0 proxy (etwproxy.exe) BY PID (never the user-session bridge) - the T5 idiom
enc_run 'tasklist /nh /fo csv /fi "imagename eq etwproxy.exe"' | tr -d '\r' > "$OUT/t8c-tasklist.csv"
spid=$(awk -F'","' '$4 == "0" {gsub(/"/,"",$2); print $2}' "$OUT/t8c-tasklist.csv" | head -1)
if [ -z "$spid" ]; then
  verdict T8c "INSTRUMENT no session-0 proxy to kill (tier already down?) - squatter drill ungraded"
else
  qrun "taskkill /f /pid $spid" >/dev/null 2>&1
  t8cexit=""; _w8x=$SECONDS
  for i in $(seq 1 24); do   # exit 8 lands within the first relaunch backoffs (floor 5s)
    # wall cap 150s (the documented 120s window + margin; asince is a ~55s-capped enc_run
    # per turn - audit 2026-09-06)
    asince_hits "$AM8" 'proxy exited rc=8 after' | grep -qa 'rc=8 after' && { t8cexit=1; break; }
    [ $(( SECONDS - _w8x )) -ge 150 ] && break
    sleep 5
  done
  log "T8c: exit-8 wait exit=$([ -n "$t8cexit" ] && echo success || echo deadline) t=$((SECONDS-_w8x))s (i=$i/24)"
  sqstate=$(enc_run 'if (Test-Path C:\ProgramData\Qubes\p3a-squat.txt) { Get-Content C:\ProgramData\Qubes\p3a-squat.txt }' | grep -aoE 'SQUAT-[A-Z]+' | head -1)
  if [ -z "$t8cexit" ]; then
    if [ "$sqstate" != SQUAT-HELD ] && [ "$sqstate" != SQUAT-RELEASED ]; then
      verdict T8c "INSTRUMENT squatter never grabbed the pipe (state=${sqstate:-none}) - drill ungraded ($(asince_hits "$AM8" 'proxy exited' | tail -1 | head -c 160))"
    else
      verdict T8c "FAIL squatter held the name but no 'proxy exited rc=8' within the 150s wall budget ($(asince_hits "$AM8" 'ETWPROXYSUP' | tail -2 | tr '\n' ';' | head -c 240))"
    fi
  else
    log "T8c: proxy exited rc=8 against the squatted pipe (squatter state=${sqstate:-?})"
    # DATUM, recorded not auto-graded: the bridge reconnect loop opens the pipe BY NAME, so a
    # 'connected server_pid=' line during the squat window means it connected to the SQUATTER
    # - a real finding for the rig to chase (the tier still cannot serve: the ring gets no
    # frames, so classification falls to sig-none/down -> DB either way).
    if [ -n "$L8c" ]; then
      blog_since "$L8c" | grep -a 'ETW IPC ' > "$OUT/t8c-ipc.txt" 2>/dev/null || true
      grep -qa 'ETW IPC connected server_pid=' "$OUT/t8c-ipc.txt" \
        && log "T8c DATUM: bridge logged an IPC connect DURING the squat - check server_pid against the squatter: $(grep -a 'ETW IPC connected' "$OUT/t8c-ipc.txt" | tail -1 | head -c 160)"
    fi
    if ! L8d=$(blog_len); then
      verdict T8c "INSTRUMENT blog_len unreadable for the tier-down fire - DB-serves arm ungraded (the exit-8 half DID pass)"
    else
      cl8=""
      if tf_fire '--fire --method start-shortcut --class informational --title P3A-t8c-db --tag t8cdb' > "$OUT/t8c-fire.txt" 2>&1; then
        _w8d=$SECONDS
        for i in $(seq 1 15); do
          # wall cap 90s (expected: CLASSIFY <45s; ~55s-capped qrun per turn)
          cl8=$(blog_since "$L8d" | grep -a 'CLASSIFY id=' | tail -1)
          [ -n "$cl8" ] && break
          [ $(( SECONDS - _w8d )) -ge 90 ] && break
          sleep 3
        done
      else
        log "T8c: tier-down fire never confirmed FIRED (terminal - CLASSIFY wait skipped; the empty-cl8 INSTRUMENT branch grades it)"
      fi
      dismiss_toasts "${TFAUMID[start-shortcut]}"
      printf '%s\n' "$cl8" > "$OUT/t8c-classify.txt"
      c_src=$(printf '%s' "$cl8" | grep -aoE 'src=[a-z-]+' | head -1 | cut -d= -f2)
      c_etw=$(printf '%s' "$cl8" | grep -aoE 'etw=[a-z-]+' | head -1 | cut -d= -f2)
      if [ "$c_src" = db ]; then
        verdict T8c "PASS squatter => proxy exit 8, tier not serving (etw=$c_etw), DB rung carries the outage (src=db) - fail-open holds"
      elif [ -z "$cl8" ]; then
        verdict T8c "INSTRUMENT no CLASSIFY for the tier-down fire - DB-serves arm ungraded (the exit-8 half DID pass)"
      else
        verdict T8c "FAIL tier-down fire classified src=$c_src etw=$c_etw (wanted src=db) - the DB rung did not carry the squatted outage"
      fi
    fi
    # RECOVERY: the squatter releases at ~120s; backoff doubled across the squatted exits, so
    # allow ~6 min (3 bounded etw_tier_up rounds; TODO(RIG)#7's backoff caveat applies).
    if ! P8r=$(plog_len) || ! L8r=$(blog_len); then
      verdict T8r "INSTRUMENT log offsets unreadable before the recovery wait - recovery ungraded (a 0 offset would false-pass on the OLD LIVE lines)"
    else
      rec=""
      for t in 1 2 3; do etw_tier_up "$P8r" "$L8r" && { rec=1; break; }; done
      if [ -n "$rec" ]; then
        verdict T8r "PASS tier recovered after the squatter released (fresh ETWPROXY LIVE + ETW IPC connected) - subject left sane"
      else
        verdict T8r "FAIL tier did not recover within ~6 min of the squat - subject left tier-down; check the backoff ($(asince_hits "$AM8" 'relaunch in' | tail -1 | head -c 160))"
      fi
    fi
  fi
fi

# ---------- wrap + the gate verdict ----------------------------------------------------------
cap "$OUT" final "$R" || true
blog_since 0 > "$OUT/bridge-full.log" 2>/dev/null || true
plog_since 0 > "$OUT/etw-proxy-full.log" 2>/dev/null || true
asince_hits 0 'ETWPROXYSUP' > "$OUT/agent-etwproxysup.log" 2>/dev/null || true
asince_hits 0 'PROXY RC' > "$OUT/agent-proxyrc.log" 2>/dev/null || true
tf '--unregister --method start-shortcut' wrapu1 >/dev/null 2>&1
tf '--unregister --method com-activator'  wrapu2 >/dev/null 2>&1

log "=== verdicts ==="; cat "$OUT/verdicts.txt" | tee -a "$R"
# FAIL *and* INSTRUMENT both gate the exit code: an ungraded phase must never read green
# (missing data fails - the a0 wrap rationale, audit 2026-09-05).
fails=$(grep -cE 'FAIL|INSTRUMENT' "$OUT/verdicts.txt" || true)
# §10.16.4 verdict under the hybrid: T2 (L1 + grant + signal flow) and T3 (targeted read)
# carry the mechanism; everything else must be clean for PICK-ETW.
if grep -qa '^T2|PASS' "$OUT/verdicts.txt" && grep -qa '^T3|PASS' "$OUT/verdicts.txt"; then
  if [ "${fails:-0}" = 0 ]; then
    verdict GATE "PICK-ETW - grant + signal flow proven (T2), canonical signal->targeted-read row proven (T3, id join recorded in T3j), L1/guard/drift/latency/regression/drills all clean: tier E primary through the proxy, tier D confirmed fallback"
  else
    verdict GATE "PICK-ETW-BLOCKED - the mechanism is proven (T2+T3 PASS) but $fails phase(s) are FAIL/INSTRUMENT: fix and re-run before shipping the tier as primary"
  fi
elif grep -qa '^T3|FAIL' "$OUT/verdicts.txt"; then
  verdict GATE "FALL-TO-DB - signal frames flow but the canonical targeted-read row failed (T3): proxy ships dormant, tier D stays primary, nothing regresses"
else
  verdict GATE "UNDECIDED - T2/T3 ungraded; read the phase verdicts (this line should be unreachable: the T2 no-go path exits early)"
fi
log "=== done: $fails FAIL/INSTRUMENT line(s); evidence in $OUT; subject $VM left running for inspection ==="
[ "${fails:-0}" = 0 ]
