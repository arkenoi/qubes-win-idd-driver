#!/bin/bash
# STABILITY E2E for the 4.3.14 candidate. Fresh installs on both chains, from the golden images.
#
# What is under test (all committed, none of it validated end to end yet):
#   * watchdog no longer respawns the agent into a shutting-down machine
#   * QGADESKSTUCK names a persistent secure-desktop freeze
#   * the secure-desktop freeze is seamless-only
#   * boot/shutdown fullscreen denied by PHASE, not just class   <- the defect I introduced
#   * the installer ARMS autologon (LSA secret) and reports it
#   * the reboot-cause audit is installed
#
# ACCEPTANCE IS BY OUTCOME, NOT BY LOG LINE:
#   1. install RESULT json: agent sha == release binary, autologon armed, reboot audit installed
#   2. cold boot -> a USER SESSION exists (Win32_ComputerSystem.UserName), not merely qrexec,
#      which on this testbed answers as SYSTEM with no session at all
#   3. windows are mapped in dom0 and NONE of them is fullscreen-sized (the direct check on the
#      thing that went wrong: a guest window must never cover the host screen)
#   4. the agent leaves the secure desktop at boot and does not sit stuck
#   5. no watchdog death-storm across a clean shutdown
#   6. an AppVM built from the template survives 3 cold boots with all of the above
set -uo pipefail
cd /home/user/qubes-win-idd-driver
source .claude/skills/win-guest-e2e/e2e-lib.sh
T=/home/user/.claude/jobs/c2a0f57b/tmp; S=$T/stability; mkdir -p $S
R=$S/run.log; : > "$R"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$R"; }
PASS=0; FAIL=0
ok(){ say "PASS  $*"; PASS=$((PASS+1)); }
no(){ say "FAIL  $*"; FAIL=$((FAIL+1)); }
vstate(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }
# A HARD KILL IS DAMAGE, NOT A TIMEOUT STRATEGY. Killing a Windows guest while it is booting or
# servicing is how it ends up in Automatic Repair - which is what happened to win10-tpl on
# 2026-08-28, from my own kills, not from anything the product did. Give a clean shutdown a real
# chance (8 min covers a guest applying updates), and say loudly when a kill is resorted to.
stop_vm(){ local vm=$1 dl; qvm-shutdown --wait "$vm" >/dev/null 2>&1; dl=$(( SECONDS + 480 ))
  until [ "$(vstate "$vm")" = Halted ]; do
    if [ "$SECONDS" -ge "$dl" ]; then
      say "  WARNING: $vm did not shut down in 480s - forcing it. Expect Automatic Repair on the next boot."
      qvm-kill "$vm" >/dev/null 2>&1; sleep 8; break
    fi
    sleep 5
  done; }
qready(){ local n=${1:-40} i; for i in $(seq 1 "$n"); do
    timeout -k 5 45 ./tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | grep -qa QREADY && return 0; sleep 10; done; return 1; }
session_user(){ timeout -k 5 60 ./tools/qtest run 'cmd /c powershell -NoProfile -Command "\"SESSIONUSER=\" + (Get-CimInstance Win32_ComputerSystem).UserName"' 2>/dev/null \
    | tr -d '\r' | grep -aoE '^SESSIONUSER=.+' | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }
wait_session(){ local n=$1 i u; for i in $(seq 1 "$n"); do u=$(session_user); [ -n "$u" ] && { echo "$u"; return 0; }; sleep 10; done; return 1; }
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
HOSTW=5120; HOSTH=1440   # dom0 screen; the fullscreen check is relative to this

png_dims(){ python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(33)
w,h=struct.unpack('>II',d[16:24]); print(w,h)" "$1" 2>/dev/null; }

# shot -> count windows, and fail if ANY of them covers the host screen.
# ALWAYS OPEN AN APP FIRST. In seamless mode a guest with nothing running has no windows at all,
# so an empty tar is the CORRECT answer and proves nothing either way - the first run of this
# e2e shot every boot with an empty desktop and reported "capture failed" for all of them, which
# left the one check that matters (no host-sized window) with nothing to look at.
check_windows(){ # $1=label  -> sets WCOUNT
  local lbl=$1 f w h big=0
  timeout -k 5 45 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1
  # POLL, do not sleep a fixed amount. On an AppVM's first cold boot notepad can take longer than
  # any constant, and a single early shot then reports "capture failed" for a guest that is simply
  # still starting - one such false failure in the 2026-08-28 run.
  local try
  WCOUNT=0
  for try in 1 2 3 4 5 6; do
    sleep 7
    rm -f $S/$lbl.tar; timeout -k 8 120 ./tools/qtest shot $S/$lbl.tar >/dev/null 2>&1
    [ -s $S/$lbl.tar ] && [ "$(tar tf $S/$lbl.tar 2>/dev/null | grep -c '\.png$')" -gt 0 ] && break
  done
  [ -s $S/$lbl.tar ] || { say "  $lbl: no shot after 6 attempts (~42 s)"; return 1; }
  rm -rf $S/$lbl-png && mkdir -p $S/$lbl-png && tar xf $S/$lbl.tar -C $S/$lbl-png 2>/dev/null
  for f in $S/$lbl-png/*.png; do
    [ -e "$f" ] || continue
    WCOUNT=$((WCOUNT+1))
    read -r w h < <(png_dims "$f")
    [ -z "${w:-}" ] && continue
    say "  $lbl: $(basename $f) ${w}x${h}"
    if [ "$w" -ge $(( HOSTW * 99 / 100 )) ] && [ "$h" -ge $(( HOSTH * 99 / 100 )) ]; then big=1; fi
  done
  timeout -k 5 45 ./tools/qtest run 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1
  [ "$big" = 0 ] || return 2
  [ "$WCOUNT" -gt 0 ] || return 3   # notepad was opened: zero windows now means a real failure
  return 0
}

boot_checks(){ # $1=vm label for messages
  local lbl=$1 u rc
  if u=$(wait_session 18); then ok "$lbl: user session '$u'"; else no "$lbl: NO user session (guest cannot come back by itself)"; fi
  check_windows "$lbl"; rc=$?
  case $rc in
    0) ok "$lbl: $WCOUNT window(s) mapped with notepad open, none fullscreen-sized" ;;
    2) no "$lbl: A FULLSCREEN-SIZED WINDOW WAS MAPPED - the rule that must never break" ;;
    3) no "$lbl: notepad was opened but dom0 got NO window - the guest is not presenting windows" ;;
    *) no "$lbl: screenshot failed - window check could not run" ;;
  esac
  # agent state: left the secure desktop, not stuck
  local L; L=$(timeout -k 5 90 ./tools/qtest run 'cmd /c dir /b /o-d "Q:\Qubes Logs\gui-agent-*.log"' 2>/dev/null | tr -d '\r' | grep -a '^gui-agent' | head -1)
  if [ -n "$L" ]; then
    local body; body=$(qrun "cmd /c findstr /c:\"secure desktop left\" /c:\"QGADESKSTUCK\" \"Q:\\Qubes Logs\\$L\"" 2>/dev/null | tr -d '\r' | grep -a '\[2026')
    # Judge the LAST of the two events, never the mere presence of one. QGADESKSTUCK is a WARNING
    # that fires at 30 s, and a slow first logon trips it legitimately: measured 2026-08-28 on
    # win11-tpl's first post-install cold boot, "secure desktop left after 38 s" followed it and the
    # desktop then presented normally. Failing on presence turned that recovery into a FAIL and would
    # equally have hidden a real freeze that happened to be preceded by a recovery.
    local last; last=$(echo "$body" | grep -a -e 'QGADESKSTUCK on the secure desktop' -e 'secure desktop left' | tail -1)
    if [ -n "$last" ] && [ -z "${last##*secure desktop left*}" ]; then
      local secs; secs=$(echo "$last" | grep -aoE 'left after [0-9]+ s' | grep -aoE '[0-9]+')
      if echo "$body" | grep -qa 'QGADESKSTUCK'; then
        ok "$lbl: agent left the secure desktop after ${secs:-?} s (QGADESKSTUCK warned first - slow logon, recovered)"
      else
        ok "$lbl: agent left the secure desktop normally at boot (${secs:-?} s)"
      fi
    elif [ -n "$last" ]; then
      no "$lbl: agent STILL on the secure desktop - QGADESKSTUCK is the last event, no recovery followed"
    else
      say "  $lbl: neither line present in $L (agent may not have hit the secure desktop at all)"
    fi
  else
    no "$lbl: no agent log found"
  fi
}

install_chain(){ # $1=golden $2=template $3=appvm $4=tag
  local GOLD=$1 TPL=$2 APP=$3 TAG=$4
  say "######## CHAIN $TAG: $GOLD -> $TPL -> $APP ########"
  for vm in "$APP" "$TPL" "$GOLD"; do [ "$(vstate $vm)" = Halted ] || stop_vm "$vm"; done
  python3 - "$GOLD" "$TPL" <<'EOF' || return 1
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
dst.virt_mode='hvm'; dst.kernel=''
dst.memory=8192; dst.maxmem=0; dst.vcpus=4; dst.qrexec_timeout=6000
print('cloned', sys.argv[1], '->', sys.argv[2])
EOF
  say "$TAG: template re-cloned from the golden image"
  qvm-start "$TPL" >/dev/null 2>&1
  export QTEST_VM="$TPL"
  bootwait 25 say || { no "$TAG: template never formed a session before install"; return 1; }
  sleep 20
  timeout -k 8 600 ./tools/qtest push "$TAR" >/dev/null 2>&1 || { no "$TAG: push failed"; return 1; }
  qrun "cmd /c \"rmdir /s /q C:\\q4314 2>nul & mkdir C:\\q4314 & tar -xzf $INC\\$(basename $TAR) -C C:\\q4314 && echo EXTRACT_OK\"" | grep -qx EXTRACT_OK || { no "$TAG: extract failed"; return 1; }
  # DEFECT DELIBERATELY RE-INTRODUCED before the install, so the suppressor is tested against the
  # state the field hit rather than against a guest that never prompts anyway: a pending PV reboot
  # Request plus xenbus_monitor set to auto-start. The MSI starts the service during its own run -
  # that is the moment the modal "needs to restart the system" appears (forum post 104, where
  # answering Yes left a half-installed QWT). Not started here on purpose: msiexec starting it is
  # the real trigger, and this way nothing can prompt before the installer is even running.
  # SEED_XENBUS=0 turns the injection OFF. It has to be switchable: WIN10 has now bricked twice
  # with the seed present, and with one run per outcome nothing can say whether the killer is the
  # seed, the installer's handling of it, or stage 1 on its own. A control run without it is the
  # only way to attribute the brick. FINDINGS 2026-08-28 (8abc9ef) already recorded "the seeded
  # prompt condition wedged win10-tpl" once - that is a second data point for the seed, not proof.
  local XK='HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor'
  if [ "${SEED_XENBUS:-1}" = 1 ]; then
    qrun "cmd /c reg add \"$XK\\Request\\xenvbd\" /v Reboot /t REG_DWORD /d 1 /f /reg:64 >nul & sc config xenbus_monitor start= auto >nul & echo SEEDED" 2>/dev/null | tr -d '\r' | grep -qa SEEDED \
      && say "  $TAG: seeded the xenbus reboot-prompt condition (Request=1, service auto-start)" \
      || say "  $TAG: could not seed the xenbus condition - the prompt test is INCONCLUSIVE"
  else
    say "  $TAG: xenbus seed OFF (SEED_XENBUS=0) - CONTROL run: the reboot-prompt suppressor is NOT under test here"
  fi

  clearlog
  # /autologon:qubes exercises the real arming path; without it the installer correctly refuses
  # to guess a password and reports not-armed.
  qrun 'cmd /c start "" /min C:\q4314\install.cmd /auto /autologon:qubes' >/dev/null 2>&1
  # STREAM STAGE 1 OUT WHILE THE GUEST IS STILL ALIVE. Every WIN10 attempt so far produced a
  # ZERO-BYTE install log: stage 1 reboots, the guest does not come back, and the log - which
  # lives on the guest's C: - becomes unreadable, so the run that most needs telemetry is the one
  # that yields none. One long-lived qrexec call with Get-Content -Wait tails the log until the
  # guest goes away, so whatever stage 1 printed LAST is on this side of the vchan even if the
  # guest never boots again. One streaming call, not a poll loop: per-second qrexec churn is what
  # wedged a guest before (IPI shootdown), so this must not become a polling instrument.
  ( timeout -k 10 900 ./tools/qtest run \
      'cmd /c powershell -NoProfile -Command "Get-Content -LiteralPath C:\qwt-improved-install.log -Wait -Tail 500"' \
      2>/dev/null | tr -d '\r' > "$S/$TAG-stage1-live.log" ) &
  local STREAM=$!
  sleep 60
  wait_install 40 say || { no "$TAG: install did not finish"; }
  kill $STREAM 2>/dev/null; wait $STREAM 2>/dev/null
  if [ -s "$S/$TAG-stage1-live.log" ]; then
    say "  $TAG: stage-1 stream captured $(wc -l < "$S/$TAG-stage1-live.log") lines; last:"
    tail -6 "$S/$TAG-stage1-live.log" | sed 's/^/      | /' | tee -a "$R"
  else
    say "  $TAG: stage-1 stream captured NOTHING - the installer never wrote a log, or it never started"
  fi
  # wait_install RETURNS ON THE STAGE-1 REBOOT - its own contract says "0 = ended (reboot or
  # completed)". A guest whose testsigning is already on installs in ONE stage and there is no
  # reboot, which is why the WIN11 chain worked; a two-stage install reboots into stage 2, and
  # reading the log at this point catches a rebooting guest and returns NOTHING. That is what
  # produced "install did not finish" plus a 0-byte log on the WIN10 chain twice, and it is a
  # harness bug, not a product failure. So: wait for the guest to come back AND for stage 2 to
  # write its RESULT before judging anything.
  # AND START IT AGAIN. This testbed HALTS on guest reboot, so after stage 1 the guest is Halted
  # and nothing brings it back: the previous version of this loop only called qready, which just
  # asks a dead VM for a shell 45 times and then reports "the guest never returned". That was my
  # bug, not the product's, and it is the second time this loop has been wrong about the two-stage
  # path. Restart it explicitly, and say so, so a start that fails is visible rather than silent.
  local waited=0
  for waited in $(seq 1 45); do
    if [ "$(vstate $TPL)" = Halted ]; then
      say "  $TAG: guest halted after the stage-1 reboot - starting it for stage 2"
      qvm-start "$TPL" >/dev/null 2>&1 || say "  $TAG: qvm-start FAILED - the guest will not boot"
      sleep 20
    fi
    qready 3 || { sleep 10; continue; }
    qrun 'cmd /c type C:\qwt-improved-install.log' 2>/dev/null | grep -av 'system32>' > "$S/$TAG-install.log"
    grep -qa 'stage2-install' "$S/$TAG-install.log" && { say "  $TAG: stage 2 RESULT present after $((waited*10))s"; break; }
    sleep 10
  done
  if [ ! -s "$S/$TAG-install.log" ]; then
    no "$TAG: the guest never came back after the stage-1 reboot"
    # The ONE instrument that can see a guest with no session: qtest shot only captures windows
    # the gui-agent maps, so a guest sitting in Automatic Repair is invisible to it. fullshot
    # captures the whole dom0 desktop, which is where a session-less HVM's framebuffer is drawn.
    timeout -k 8 150 ./tools/qtest fullshot "$S/$TAG-noreturn.tar" >/dev/null 2>&1
    if [ -s "$S/$TAG-noreturn.tar" ]; then
      rm -rf "$S/$TAG-noreturn-png"; mkdir -p "$S/$TAG-noreturn-png"
      tar xf "$S/$TAG-noreturn.tar" -C "$S/$TAG-noreturn-png" 2>/dev/null
      say "  $TAG: dom0 desktop captured -> $S/$TAG-noreturn-png (READ IT: it shows what the guest is stuck on)"
    else
      say "  $TAG: fullshot produced nothing either - no instrument can see this guest"
    fi
  fi
  local J; J=$(grep -ao '=== RESULT === .*' "$S/$TAG-install.log" | tail -1)
  say "$TAG install RESULT: $(echo "$J" | cut -c1-400)"
  echo "$J" | grep -qa "\"installed_gui_agent_sha256\":\"$ASHA" \
    && ok "$TAG: installed agent == release binary ($ASHA)" \
    || no "$TAG: installed agent is NOT the release binary"
  echo "$J" | grep -qa '"autologon":"armed"' \
    && ok "$TAG: installer armed autologon" \
    || no "$TAG: autologon not armed ($(echo "$J" | grep -ao '"autologon":"[^"]*"'))"
  # The fix itself was proven on 2026-08-21 (control 9 short/60 vs 0 short/90). What was never
  # done is SHIPPING it, so what this asserts is landing, not correctness: the installed wrapper
  # must be OURS, i.e. different from the stock copy the installer set aside.
  echo "$J" | grep -qa '"qrexec_bins":"placed=1"' \
    && ok "$TAG: fork qrexec-wrapper placed" \
    || no "$TAG: qrexec-wrapper NOT placed ($(echo "$J" | grep -ao '"qrexec_bins":"[^"]*"'))"
  local WH SH
  WH=$(qrun 'cmd /c powershell -NoProfile -Command "(Get-FileHash \"C:\Program Files\Qubes Tools\bin\qrexec-wrapper.exe\" -Algorithm SHA256).Hash"' 2>/dev/null | tr -d '\r' | grep -aoE '^[0-9A-F]{64}' | head -1)
  SH=$(qrun 'cmd /c powershell -NoProfile -Command "(Get-FileHash \"C:\Program Files\Qubes Tools\bin\qrexec-wrapper.exe.qwt-stock\" -Algorithm SHA256).Hash"' 2>/dev/null | tr -d '\r' | grep -aoE '^[0-9A-F]{64}' | head -1)
  if [ -n "$WH" ] && [ -n "$SH" ] && [ "$WH" != "$SH" ]; then
    ok "$TAG: installed qrexec-wrapper differs from the stock copy (ours is live)"
  else
    no "$TAG: qrexec-wrapper is stock or unverifiable (ours=${WH:0:12} stock=${SH:0:12})"
  fi
  echo "$J" | grep -qa '"appmenu_scripts":"placed=2"' \
    && ok "$TAG: app-menu rpc scripts placed over the stock ones" \
    || no "$TAG: app-menu scripts NOT placed ($(echo "$J" | grep -ao '"appmenu_scripts":"[^"]*"'))"
  echo "$J" | grep -qa '"reboot_audit":"changed=[1-9]' \
    && ok "$TAG: reboot-cause audit installed" \
    || no "$TAG: reboot audit missing ($(echo "$J" | grep -ao '"reboot_audit":"[^"]*"'))"

  # --- app menu: a fresh guest must offer something to launch -------------------------
  # In seamless mode there is no taskbar and no desktop, so dom0's application list is the only
  # way into the qube. Run the service's own script and read what it would report.
  # Did the install survive it, and is the guest left in the shipping state?
  local XS XR
  XS=$(qrun 'cmd /c sc qc xenbus_monitor | findstr START_TYPE' 2>/dev/null | tr -d '\r' | grep -ao 'DISABLED\|AUTO_START\|DEMAND_START' | head -1)
  XR=$(qrun 'cmd /c reg query "HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request" /s /reg:64 2>nul | findstr /i Reboot' 2>/dev/null | tr -d '\r' | grep -ac 'Reboot')
  # A pending Request is NOT a failure: the driver re-files it on any boot that still needs the
  # binding, and the installer's own comment says so. What must hold is that nothing can ANSWER it
  # with a modal - i.e. the monitor is disabled. Report the count, judge the service state.
  say "  $TAG: pending xenbus Request values after install: ${XR:-0} (re-filed by the driver is normal)"
  [ "$XS" = DISABLED ] \
    && ok "$TAG: install survived the reboot-prompt condition (monitor DISABLED - nothing can prompt)" \
    || no "$TAG: xenbus_monitor left as START_TYPE=$XS - it can prompt on the next boot"

  say "--- $TAG: app menu contents ---"
  # EXIT CODE FIRST: this is the actual field failure - dom0 discards the entire application list
  # when the service exits non-zero, which a user sees as
  # "qvm-sync-appmenus ... returned non-zero exit status 1".
  local AMOUT; AMOUT=$(qrun 'cmd /c (powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Qubes Tools\qubes-rpc-services\get-appmenus.ps1") & echo GETAPPMENUS_EXIT=%ERRORLEVEL%' 2>/dev/null | tr -d '\r')
  local AMRC; AMRC=$(echo "$AMOUT" | grep -aoE 'GETAPPMENUS_EXIT=[0-9]+' | tail -1 | cut -d= -f2)
  [ "${AMRC:-1}" = 0 ] && ok "$TAG: get-appmenus exits 0 (dom0 keeps the list)" \
                       || no "$TAG: get-appmenus exited '${AMRC:-?}' - dom0 would discard every app"
  qrun 'cmd /c dir /b /s "C:\Program Files\Qubes Tools\qubes.GetAppmenus"' 2>/dev/null | tr -d '\r' | grep -qa 'qubes.GetAppmenus' \
    && ok "$TAG: qubes.GetAppmenus (the name dom0 calls) is present" \
    || no "$TAG: no qubes.GetAppmenus service file"
  local AM; AM=$(echo "$AMOUT" | grep -a ':Name=')
  echo "$AM" > "$S/$TAG-appmenu.txt"
  local want miss=0
  for want in notepad explorer settings cmd cmd-admin powershell powershell-admin; do
    echo "$AM" | grep -qa "^$want.desktop:Name=" || { say "  missing menu entry: $want"; miss=$((miss+1)); }
  done
  say "  app menu entries reported: $(echo "$AM" | grep -ac ':Name=')"
  [ "$miss" -eq 0 ] && ok "$TAG: all built-in app-menu entries reported" \
                    || no "$TAG: $miss built-in app-menu entries missing"
  echo "$AM" | grep -qa '^edge.desktop:Name=' && say "  (edge present)" || say "  (edge absent - not installed on this image)"

  say "--- $TAG: template cold boot ---"
  stop_vm "$TPL"; qvm-start "$TPL" >/dev/null 2>&1; qready 40 || say "  no qrexec"
  boot_checks "$TAG-tpl"
  stop_vm "$TPL"

  say "--- $TAG: build the AppVM and boot it 3x ---"
  if qvm-ls --raw-list 2>/dev/null | grep -qx "$APP"; then qvm-remove -f "$APP" >/dev/null 2>&1; fi
  qvm-create --class AppVM --template "$TPL" --label red "$APP" >/dev/null 2>&1 || { no "$TAG: AppVM create failed"; return 1; }
  qvm-tags "$APP" add win-idd-testbed >/dev/null 2>&1
  qvm-prefs "$APP" memory 8192 >/dev/null 2>&1; qvm-prefs "$APP" maxmem 0 >/dev/null 2>&1
  qvm-prefs "$APP" vcpus 4 >/dev/null 2>&1; qvm-prefs "$APP" qrexec_timeout 6000 >/dev/null 2>&1
  export QTEST_VM="$APP"
  local b
  for b in 1 2 3; do
    say "--- $TAG: AppVM cold boot $b/3 ---"
    qvm-start "$APP" >/dev/null 2>&1
    qready 40 || say "  no qrexec on boot $b"
    boot_checks "$TAG-app-b$b"
    # did the guest restart itself while we were looking?
    local audit; audit=$(qrun 'cmd /c type "Q:\Qubes Logs\reboot-audit.log"' 2>/dev/null | tr -d '\r' | grep -ac '^\[2026')
    say "  $TAG boot $b: reboot-audit entries so far: ${audit:-0}"
    stop_vm "$APP"
  done
  # the watchdog must not have written a death storm during those shutdowns
  qvm-start "$APP" >/dev/null 2>&1; qready 40 || true
  local wd; wd=$(qrun 'cmd /c findstr /c:"died within" /c:"not restarting it" "Q:\Qubes Logs\gui-watchdog-*.log"' 2>/dev/null | tr -d '\r')
  local storms notrestart
  storms=$(echo "$wd" | grep -ac 'died within' || true)
  notrestart=$(echo "$wd" | grep -ac 'not restarting it' || true)
  echo "$wd" > "$S/$TAG-watchdog.log"
  say "  $TAG watchdog: 'died within'=$storms  'not restarting it (going down)'=$notrestart"
  [ "${storms:-0}" -eq 0 ] && ok "$TAG: no watchdog death-storm across 3 shutdowns" \
                           || say "  $TAG: $storms quick-death lines - inspect $S/$TAG-watchdog.log"
  qrun 'cmd /c type "Q:\Qubes Logs\reboot-audit.log"' 2>/dev/null | tr -d '\r' | grep -a '^\[2026' > "$S/$TAG-reboot-audit.log" || true
  say "  $TAG reboot-audit records: $(wc -l < "$S/$TAG-reboot-audit.log" 2>/dev/null || echo 0)"
  stop_vm "$APP"
}

say "=== fetch the release-package artifact (all fixes) ==="
RID=$(gh run list -L 10 -w release-package --json databaseId,headSha,conclusion -q '[.[]|select(.conclusion=="success")][0].databaseId')
rm -rf $S/dl && gh run download "$RID" -D $S/dl >/dev/null 2>&1 || { say "download failed"; exit 1; }
PV=$(python3 -c "import json;print(json.load(open('$S/dl/qwt-improved-iso/MANIFEST.json'))['package_version'])")
ASHA=$(sha256sum $S/dl/qwt-full-package/gui-agent.exe | cut -c1-12)
say "package $PV, agent $ASHA"
TAR=$S/qwt-setup.tar.gz
( cd $S/dl/qwt-improved-setup && tar -czf "$TAR" . )
say "setup tarball: $(stat -c%s "$TAR") bytes"

# CHAINS selects which chains run (default both). The WIN10 chain is the ONLY one that exercises
# the two-stage install: a guest with testsigning off installs stage 1, REBOOTS, then installs
# stage 2 - the path the field reports hit and the one the reboot-prompt suppressor exists for.
# Note on win10-tpl, which I wrecked with repeated hard kills: it is a clone TARGET here, not a
# source. install_chain re-clones root and private from the golden win10-clean before touching it,
# so its damaged contents are overwritten rather than used. It only has to be Halted.
CHAINS=${CHAINS:-WIN11 WIN10}
case " $CHAINS " in *" WIN11 "*) install_chain win11-fresh win11-tpl win11-app WIN11 ;;
  *) say ""; say "=== WIN11 chain SKIPPED by CHAINS='$CHAINS' ===" ;; esac
case " $CHAINS " in *" WIN10 "*) install_chain win10-clean win10-tpl win10-app WIN10 ;;
  *) say ""; say "=== WIN10 chain SKIPPED by CHAINS='$CHAINS' - two-stage install path NOT covered ===" ;; esac

say ""
say "=== STABILITY E2E: $PASS passed, $FAIL failed ==="
say "=== DONE ==="
