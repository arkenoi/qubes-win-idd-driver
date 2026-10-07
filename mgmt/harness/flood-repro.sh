#!/usr/bin/env bash
# flood-repro.sh - GWeck, forum #175: "When starting the VM after the installation of QWT, a lot of
# notifications pop up." Reproduce it ON HIS ENVIRONMENT and NAME each notification.
#
# WHY THIS SHAPE. The flood is the one item he leads with and the one the owner calls important, and it is
# invisible on our own long-lived guest: 471 lines of bridge log across four bridge starts and two installs
# today carry exactly ONE `SENT id=`. The difference is that his is a FRESHLY PROVISIONED profile - a German
# 25H2 TemplateVM, QWT just installed, started for the first time - where Windows' own first-run notifications
# are still pending. So the measurement has to be a first start after an install, on his environment, with
# every forwarded notification named rather than counted.
#
# WHAT IT MEASURES, all guest-side and all exact:
#   * every `SENT id=` the bridge forwarded on that first boot, with its title and sender
#   * the same for the two boots after it, so "only the first start" is a measurement and not an impression
#   * WHEN the quiet-desktop nag policies were asserted relative to those notifications (the hypothesis is
#     that QubesQuietDesktopGuard runs at boot+1min while the storm fires at logon - if so, every nag the
#     policy set covers gets one free run on the boot that matters most)
#   * what our OWN routes sent (notify-errors tokens, the death reporter's DEATH lines), so his flood is
#     attributed to Windows' nags or to us, by evidence
#
# The reporter gate is not optional: env-assert.sh must pass before anything is measured, because a
# reproduction on the wrong image has already cost this project a day (mgmt/harness/env-assert.sh header).
#
#   flood-repro.sh --iso <iso> [--subject <vm>] [--golden win11de-qwt] [--boots 3] [--deliver]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2

ISO=""; SUBJ="win11de-flood"; GOLDEN="win11de-qwt"; BOOTS=3; DELIVER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --subject) SUBJ="${2:-}"; shift 2 ;;
    --golden) GOLDEN="${2:-}"; shift 2 ;;
    --boots) BOOTS="${2:-}"; shift 2 ;;
    # THE BOOTS THAT MEASURE THE FLOOD PUT IT ON THE OWNER'S SCREEN, and there is no way round that:
    # the notifications are forwarded to dom0's notification service by the product itself, and the
    # queue they come from lives in a SQLite store only the C++ bridge reads. So this is an explicit
    # opt-in, not a default - on 2026-10-07 this run was started without warning him and he watched
    # the flood arrive ("so, here is the flood, right on screen"). Standing rule: warn before taking
    # over the owner's screen.
    --deliver) DELIVER=1; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "FAIL  --iso <file> is required and must exist (got '$ISO')" >&2; exit 2; }

OUT="${FLOOD_OUT:-/home/user/qwt-flood/$(date -u +%m%d-%H%M)}"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "$(date -u +%T)Z flood[$SUBJ]: $*" | tee -a "$R"; }
source mgmt/harness/shutdown-lib.sh
source mgmt/harness/vmlock.sh; vm_lock "$SUBJ" || { echo "FAIL  the rig lock for $SUBJ is held by a live job" >&2; exit 2; }
# THE SUBJECT COMES DOWN WHEN THIS STOPS, however it stops. A guest running this measurement keeps
# forwarding notifications to the OWNER'S dom0 screen: on 2026-10-07 the harness was interrupted and
# left the subject up, and he watched the flood continue with nothing driving it. SIGTERM/SIGINT and a
# normal exit all land here.
_teardown(){ local rc=$?; trap - EXIT INT TERM
  if [ "$(qvm-ls --raw-data --fields STATE "$SUBJ" 2>/dev/null | tr -d '\n')" != Halted ]; then
    echo "$(date -u +%T)Z flood[$SUBJ]: stopping the subject - it must not keep sending notifications to dom0" | tee -a "$R"
    qwt_shutdown "$SUBJ" 420 >/dev/null 2>&1
  fi
  exit $rc; }
trap _teardown EXIT INT TERM
RUN_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # the sweep's <since>: everything this run produced
log "start iso=$(sha256sum "$ISO" | cut -c1-12) golden=$GOLDEN boots=$BOOTS out=$OUT"

q(){ QTEST_VM="$SUBJ" timeout "${QT_T:-180}" ./tools/qtest "$@"; }
state(){ qvm-ls --raw-data --fields STATE "$SUBJ" 2>/dev/null | tr -d '\n'; }
# THREE EXITS, and it says which: a session appeared / the guest is Halted (terminal) / the deadline.
wait_session(){ local d=$((SECONDS+${1:-420}));
  while [ $SECONDS -lt $d ]; do
    [ "$(state)" = Halted ] && { echo "halted"; return 1; }
    q run 'cmd /c echo UP' 2>/dev/null | grep -q UP && { echo "up"; return 0; }
    sleep 10
  done; echo "deadline"; return 1; }

# ---- the subject: a clone of HIS golden, and the gate that proves it is his environment ---------------
if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ"; then
  log "removing the previous subject"
  qwt_shutdown "$SUBJ" 420 >/dev/null 2>&1; qvm-remove -f "$SUBJ" >/dev/null 2>&1
fi
bash mgmt/clone-guest.sh "$GOLDEN" "$SUBJ" > "$OUT/clone.out" 2>&1 || { log "FAIL clone: $(tail -2 "$OUT/clone.out" | tr '\n' ' ' | cut -c1-200)"; exit 1; }
log "cloned $GOLDEN -> $SUBJ"
qvm-start "$SUBJ" >/dev/null 2>&1
w=$(wait_session 420); [ "$w" = up ] || { log "FAIL the clone reached no session ($w) - nothing can be measured"; exit 1; }
if ! bash mgmt/harness/env-assert.sh "$SUBJ" gweck > "$OUT/env-assert.out" 2>&1; then
  log "FAIL env-assert gweck: $(grep -aE 'NOT MATCHED|FAIL' "$OUT/env-assert.out" | head -3 | tr '\n' ';' | cut -c1-240)"
  log "      a reproduction on the wrong image is worse than none - stopping"
  exit 1
fi
log "env-assert gweck PASSED - this is his environment"

# ---- install QWT, exactly as he did, then watch the FIRST start -----------------------------------------
log "installing the package under test (his sequence: install QWT, then start the VM)"
if ! mgmt/harness/quick-upgrade.sh "$ISO" "$SUBJ" win11de > "$OUT/install.out" 2>&1; then
  log "NOTE quick-upgrade reported failure: $(grep -aE '^FAIL' "$OUT/install.out" | head -2 | tr '\n' ';' | cut -c1-220)"
  log "     continuing - the flood is measured on the boot AFTER the install, whatever the installer graded"
fi

cat > "$OUT/probe.ps1" <<'PS'
# Every notification this boot forwarded, NAMED, plus when the nag policies were asserted relative to them.
$ErrorActionPreference = 'Continue'
function L($k,$v){ "FL|$k|$v" }
$boot = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).LastBootUpTime
L 'boot' $(if ($boot) { $boot.ToString('HH:mm:ss') } else { 'unreadable' })
$b = 'C:\ProgramData\qubes-toast-bridge\bridge.log'
$lines = @(Get-Content -LiteralPath $b -EA SilentlyContinue)
L 'bridge_lines' $lines.Count
# THE COUNT THAT MATTERS: what we actually handed to dom0. Case-SENSITIVE - 'absent (' and 'consent'
# both contain 'sent ', and matching case-insensitively is how an earlier read of this log reported
# three forwards that never happened.
$sent = @($lines | Where-Object { $_ -cmatch 'SENT id=' })
L 'sent_total' $sent.Count
foreach ($s in $sent) { L 'sent' (($s -replace "`r",'') -replace '\s+',' ') }
$plan = @($lines | Where-Object { $_ -cmatch 'PLAN ' })
L 'plan_total' $plan.Count
foreach ($p in ($plan | Select-Object -First 40)) { L 'plan' (($p -replace "`r",'') -replace '\s+',' ') }
# the nag policies: WHEN did the guard last run, and did it report failures?
$qd = (& schtasks /query /tn QubesQuietDesktopGuard /v /fo LIST 2>&1 | Out-String)
L 'guard_last' ([regex]::Match($qd, '(?m)^\s*Last Run Time:\s*(.+)$').Groups[1].Value.Trim())
L 'guard_rc'   ([regex]::Match($qd, '(?m)^\s*Last Result:\s*(.+)$').Groups[1].Value.Trim())
# a few of the per-user values the guard sets, read from the LIVE user's hive - if they are not there,
# the storm had nothing stopping it
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-310093Enabled') {
  L "cdm_$n" (((Get-ItemProperty -Path $cdm -Name $n -EA SilentlyContinue).$n) -as [string])
}
L 'explorer_sync' (((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' -EA SilentlyContinue).ShowSyncProviderNotifications) -as [string])
# and OUR own routes, so his flood is attributed by evidence rather than by assumption
$st = Join-Path $env:ProgramData 'Qubes\notify-errors'
L 'notifyerr_tokens' (@(Get-ChildItem -LiteralPath $st -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer }).Count)
foreach ($f in @(Get-ChildItem -LiteralPath $st -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer })) { L 'notifyerr' "$($f.Name) $($f.LastWriteTime.ToString('HH:mm:ss'))" }
$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$deaths = 0
if ($logdir) { foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-report-death*.log' -EA SilentlyContinue) {
  $deaths += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -cmatch 'DEATH #' }).Count } }
L 'death_notifications' $deaths
L 'END' 'ok'
PS

tally(){ # $1 label -> the per-boot reading
  q pushrun "$OUT/probe.ps1" > "$OUT/probe-$1.out" 2>&1
  g(){ grep -a "^FL|$1|" "$OUT/probe-$2.out" | tail -1 | cut -d'|' -f3-; }
  local s p
  s=$(grep -a '^FL|sent_total|' "$OUT/probe-$1.out" | tail -1 | cut -d'|' -f3)
  p=$(grep -a '^FL|plan_total|' "$OUT/probe-$1.out" | tail -1 | cut -d'|' -f3)
  log "  boot $1: forwarded=${s:-<unreadable>} planned=${p:-<unreadable>} guard_last=$(grep -a '^FL|guard_last|' "$OUT/probe-$1.out" | tail -1 | cut -d'|' -f3-) cdm=$(grep -a '^FL|cdm_SubscribedContent-338388Enabled|' "$OUT/probe-$1.out" | tail -1 | cut -d'|' -f3-)"
  grep -a '^FL|sent|' "$OUT/probe-$1.out" | sed 's/^FL|sent|/    > /' | cut -c1-190
  [ -n "$s" ] || { log "  boot $1: MISSING DATA - the probe produced no count, which fails rather than reads as zero"; return 1; }
  echo "$s" > "$OUT/sent-$1.txt"
}

if [ "$DELIVER" != 1 ]; then
  log "STOPPING BEFORE THE MEASUREMENT BOOTS - they would deliver the flood to dom0's screen."
  log "  The clone, env-assert gweck and the install are done; the subject is $SUBJ."
  log "  Re-run with --deliver when you are ready to see notifications arrive on the desktop."
  exit 3
fi
log "boot 1 - the first start after the install, which is the one he reports"
log "  --deliver was given: notifications WILL appear on dom0's screen from here on"
if [ "$(state)" != Running ]; then qvm-start "$SUBJ" >/dev/null 2>&1; fi
w=$(wait_session 420); [ "$w" = up ] || { log "FAIL no session on boot 1 ($w)"; exit 1; }
sleep 120   # the first-run storm and the guard's PT1M trigger both land inside this; see the header
tally 1 || true

n=2
while [ "$n" -le "$BOOTS" ]; do
  log "boot $n - a later start, to show whether the flood is the FIRST boot only"
  qwt_shutdown "$SUBJ" 600 > "$OUT/shutdown-$n.out" 2>&1
  [ "$(state)" = Halted ] || { log "FAIL the guest would not halt for boot $n: $(tail -1 "$OUT/shutdown-$n.out" | cut -c1-140)"; break; }
  qvm-start "$SUBJ" >/dev/null 2>&1
  w=$(wait_session 420); [ "$w" = up ] || { log "FAIL no session on boot $n ($w)"; break; }
  sleep 120
  tally "$n" || true
  n=$((n+1))
done

# ---- THE ERROR LOG, WHICH THIS HARNESS USED TO IGNORE ENTIRELY -----------------------------------
# It counted forwarded notifications and looked at nothing else. When the count probe broke it
# printed MISSING DATA and carried on - past four [ERROR] lines it had printed in its own output,
# past 766 error/warning lines in the guest's log, and past the one the owner could see on his
# screen ("The Windows Update scan task failed"), which he then had to point at. A clean error log
# is the gate condition (owner, 2026-10-07: "Make clean error log the gate condition. Any error is
# fuckup!" and "every rig run calls for log sweep and action"), and Jev scored exactly this remedy
# at 1.00 after scoring "did this agent read, detect and act on all the errors" at 0.03.
# Enforced for every harness by lint rule L19, so this cannot be left out again.
log "sweeping the guest's error log for the whole run"
sweep_rc=0
mgmt/harness/log-sweep.sh "$SUBJ" "$RUN_STARTED" "$OUT/sweep" > "$OUT/sweep.out" 2>&1 || sweep_rc=$?
sweep_line=$(grep -aE '^(SWEEP|FAIL|OK)' "$OUT/sweep.out" | tail -1)
log "  sweep rc=$sweep_rc ${sweep_line:-<no verdict line>}"

echo
echo "=== flood-repro: $SUBJ (GWeck forum #175, item 1) ==="
for i in $(seq 1 "$BOOTS"); do
  [ -f "$OUT/sent-$i.txt" ] && printf '  boot %s: %s notification(s) forwarded to dom0\n' "$i" "$(cat "$OUT/sent-$i.txt")"
done
printf '  error log: sweep rc=%s - %s\n' "$sweep_rc" "${sweep_line:-no verdict}"
if [ "$sweep_rc" != 0 ]; then
  echo "  THE RUN IS NOT CLEAN: the sweep found error lines it was not told to expect. They are the"
  echo "  result of this run as much as the notification count is - read $OUT/sweep/summary.txt."
fi
log "done. evidence in $OUT"
exit "$sweep_rc"
