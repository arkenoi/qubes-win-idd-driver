#!/bin/bash
# P5 RUNNER — the unattended safeguard cells, with containment ESTABLISHED AND PROVEN first.
#
# WHY THIS EXISTS. P5's rules were written down and then not executed. On 2026-08-30 the SG cells
# ran against a guest that was silently still at host size: probes built for 1600x900 were 31% of a
# 5120x1440 screen, so the >=99%-of-screen gate was never reached, every "nothing mapped" was
# vacuous, and one arm opened a 5088x1368 window that took the owner's keyboard focus mid-session.
# The rule existed (SG0.2); an executable step did not. This is the step.
#
#   mgmt/harness/p5-run.sh <vm> [outdir]
#
# Exit 0 = every cell graded. 1 = a cell failed. 2 = precondition not established (nothing is run:
# an unmeasured cell beats a vacuous pass).
#
# NEVER sets service.gui-fullscreen. Feature-ON arms are owner-attended and are listed
# ATTENDED-PENDING, never silently dropped (SG0).
set -uo pipefail
cd /home/user/qubes-win-idd-driver

# PREFLIGHT: every guest-side script this harness needs must exist IN THE REPO.
# Until 2026-08-31 three of them (startproof/enumwin/sg6-state) lived only in a per-job scratch
# directory. The harness still ran without them - it just printed `?` for the deny counts, i.e. it
# silently dropped the vacuity proofs that are the load-bearing half of every "nothing mapped"
# verdict. Missing data must FAIL, never degrade quietly (H5.4).
require_scripts(){
  local missing=""
  for s in "$@"; do [ -f "$s" ] || missing="$missing $s"; done
  if [ -n "$missing" ]; then
    echo "FATAL: required guest script(s) not found in the repo:$missing" >&2
    echo "       Refusing to run - a cell without its vacuity proof grades nothing." >&2
    exit 2
  fi
}

require_scripts guest/disarm-update-scan.ps1 guest/fsgate-probe.ps1 guest/set-resolution.ps1 guest/open-start.ps1 guest/run-as-user.ps1
VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/P5-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-120}" ./tools/qtest "$@" 2>/dev/null; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  q run "cmd /c powershell -NoProfile -EncodedCommand $b" | tr -d '\r'; }
log(){ echo "$(date -u +%H:%M:%S) p5[$VM]: $*" | tee -a "$OUT/p5.log"; }

# Did the AGENT announce this window to dom0? Counts `msg=MAP,hwnd=<h>` in the agent's own log.
#
# WHY THIS EXISTS - the screenshot cannot see an override-redirect window.
# Measured 2026-08-31 with FaultGateOff=0x3 (both fullscreen clauses bypassed): the agent logged
#   SendWindowCreateInternal: 0x3601e6, (0,0) 1920x1080, override=1
#   SendWindowMap: QGAPROTO,msg=MAP,hwnd=0x3601e6,ovr=1,...,w=1920,h=1080
# i.e. it offered dom0 a full-screen override-redirect window - the precise leak SG4 asserts
# against - and `qtest shot` still returned ONLY the control window. Override-redirect windows are
# undecorated and do not appear in that enumeration, so a cell graded on the screenshot alone is
# BLIND to this defect and would pass a leaking build. (Compare the memory note: an empty shot tar
# is not evidence of no windows.)
#
# Guest-side log evidence is weaker than pixels and does not replace them - it is ADDITIVE. A
# "nothing mapped" verdict now requires BOTH: no matching window in dom0, AND no MAP from the
# agent for that hwnd. Either one alone can miss the leak.
agent_mapped(){  # <hwnd like 0x3601e6> -> count of MAP messages for it
  local h; h=$(echo "${1#0x}" | tr 'A-Z' 'a-z')
  psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1
Write-Output ("AGENTMAP " + @(Get-Content $f.FullName | Select-String -SimpleMatch "msg=MAP,hwnd=0x'"$h"'").Count)' \
    | grep -aoE 'AGENTMAP [0-9]+' | awk '{print $2}' | head -1
}
rc=0

# ---------------------------------------------------------------- P5-2: disarm the scan
log "=== P5-2: disarm QubesWindowsUpdateScan (same gate as P4-1) ==="
dis=$(T=300 q pushrun guest/disarm-update-scan.ps1 | tr -d '\r')
echo "$dis" | grep -aE '^(SCAN_|RELAY_|DISARMED)' | sed 's/^/  /' | tee "$OUT/disarm.txt"
echo "$dis" | grep -qa 'DISARMED True' || { log "FATAL: scan not disarmed - refusing to run"; exit 2; }
restore(){ log "=== re-enabling QubesWindowsUpdateScan ==="
           q run 'cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable & echo REENABLED' | tr -d '\r' | grep -a REENABLED | sed 's/^/  /'; }
trap restore EXIT

# ---------------------------------------------------------------- P5-3: containment
HOSTW=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[1]}')
HOSTH=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[2]}')
HOSTW=${HOSTW:-5120}; HOSTH=${HOSTH:-1440}
log "=== P5-3: containment (host ${HOSTW}x${HOSTH}) ==="
con=$(T=300 q pushrun guest/set-resolution.ps1 -Contain | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -ao '{.*}' | head -1)
echo "  $con" | tee "$OUT/containment.txt"
echo "$con" | grep -qa '"ok":true' || {
    # A guest already at the contained size reports ok:false ("no offered mode strictly smaller"),
    # which is fine. Anything else is not.
    now=$(T=200 q pushrun guest/set-resolution.ps1 -List | tr -d '\r' | grep -ao '"current":"[0-9x]*"' | head -1)
    log "  set-resolution did not apply; current=$now"
}
GW=$(T=200 q pushrun guest/set-resolution.ps1 -List | tr -d '\r' | grep -ao '"current":"[0-9]*x[0-9]*"' | head -1 | grep -ao '[0-9]*x[0-9]*')
GWW=${GW%x*}; GWH=${GW#*x}
log "  guest screen now: ${GW:-unknown}"
if [ -z "${GWW:-}" ] || [ "$GWW" -ge "$HOSTW" ] || [ "$GWH" -ge "$HOSTH" ]; then
    log "FATAL: guest screen ${GW:-unknown} is not strictly inside host ${HOSTW}x${HOSTH}."
    log "       Refusing to open screen-sized windows on the owner's display (SG0.2)."
    exit 2
fi

# The GUEST agreeing is not enough - the agent must have followed, or every gate compares against a
# screen size the agent does not believe in. This is the check that was missing on 2026-08-30.
cat > "$TMP/p5-agentscreen.ps1" <<'PS'
$ErrorActionPreference='Continue'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if(-not $f){Write-Output 'AGENTSCREEN none';exit 1}
$c = Get-Content $f.FullName -Tail 3000
$m = $c | Select-String -Pattern 'A6CONFIGURE window 0 -> (\d+)x(\d+)' | Select-Object -Last 1
if($m){ Write-Output ('AGENTSCREEN ' + $m.Matches[0].Groups[1].Value + 'x' + $m.Matches[0].Groups[2].Value) }
else  { Write-Output 'AGENTSCREEN no-configure-line' }
PS
as=$(T=300 q pushrun "$TMP/p5-agentscreen.ps1" | tr -d '\r' | grep -ao 'AGENTSCREEN .*' | head -1)
log "  agent believes: ${as:-?}"
echo "$as" | grep -qa "AGENTSCREEN ${GW}" || {
    log "FATAL: agent's believed screen (${as:-?}) != guest screen (${GW}). A gate sized to one and"
    log "       enforced against the other grades nothing. INVALID-PRECONDITION, not a pass."
    exit 2
}
log "  containment PROVEN: guest ${GW}, agent ${GW}, host ${HOSTW}x${HOSTH}"

# ---------------------------------------------------------------- helpers
# The probe SCRIPT must be ON the guest before any cell launches it. The previous blind
# `q push ... >/dev/null 2>&1` was the discarded-transient trap (experimenter rule 11) verbatim:
# qvm-copy-to-vm fails transiently on a freshly-settled session (file-agent/no session yet), the
# error was thrown away, and every SG cell then burned its full deadline launching a script that
# was never there. Measured 2026-09-04 on win10-acc (fresh standalone): SG2/SG3/SG4 ALL graded
# INVALID-INSTRUMENT "never reported a created window" (~120 s each) while the control Notepad -
# which needs no pushed file - came up fine ("capture path proven alive, control=1426x752"), and
# the SAME cells passed on the warm win10-p4. Verify on the SAME signal the launcher consults
# (rule 5b): the file's existence at the exact path the launch names.
# The probe LAUNCH STAGE, run through guest/run-as-user.ps1 (see run_cell for why). run-as-user's
# schtasks child owns a VISIBLE conhost for as long as it runs, and the probe holds its window for
# 220 s - launched directly, that console would sit in every mapped_list sample (the very
# launcher-console FAIL documented in run_cell). This stage Start-Process-es the probe with a
# HIDDEN console and exits immediately: the visible wrap console lives ~1-2 s, gone before the
# first sample (sampling starts only after the probe reports), and the probe's own console is
# never shown at all. No shell redirection anywhere - the probe writes its own -OutFile.
cat > "$TMP/p5-fsgate-launch.ps1" <<'PS'
param([string]$Mode,[int]$HoldSeconds=220,[int]$HostWidth=0,[int]$HostHeight=0,[string]$OutFile='')
$probe = Join-Path $PSScriptRoot 'fsgate-probe.ps1'
if (-not (Test-Path $probe)) { Write-Output "FSGATE-LAUNCH error=probe_not_found $probe"; exit 2 }
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File',$probe,
  '-Mode',$Mode,'-HoldSeconds',$HoldSeconds,'-HostWidth',$HostWidth,'-HostHeight',$HostHeight,
  '-OutFile',$OutFile)
Write-Output "FSGATE-LAUNCH ok mode=$Mode out=$OutFile"
PS
ensure_probe_pushed(){
  local i f ok
  for i in 1 2 3; do
    T=200 q push guest/fsgate-probe.ps1 "$TMP/p5-fsgate-launch.ps1" >/dev/null 2>&1
    ok=yes
    for f in fsgate-probe.ps1 p5-fsgate-launch.ps1; do
      T=90 q run "cmd /c if exist $GUEST\\$f (echo PROBEFILE-OK) else (echo PROBEFILE-MISSING)" \
          | tr -d '\r' | grep -qa 'PROBEFILE-OK' || ok=no
    done
    [ "$ok" = yes ] && return 0
    log "  probe scripts not on the guest after push attempt $i/3 - retrying"
    sleep 10
  done
  return 1
}
if ! ensure_probe_pushed; then
  log "FATAL: guest/fsgate-probe.ps1 + p5-fsgate-launch.ps1 could not be pushed-and-verified after"
  log "       3 attempts. Every SG cell would launch a script that is not there and grade"
  log "       INVALID-INSTRUMENT."
  exit 2
fi
cat > "$TMP/p5-mark.ps1" <<'PS'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
# Emit the FILE as well as the offset. An offset alone is meaningless if the agent restarts
# before the count is taken - see p5-since.ps1.
if($f){ Write-Output ('AGENTMARK ' + @(Get-Content $f.FullName).Count + ' ' + $f.Name) } else { Write-Output 'AGENTMARK 0 none' }
PS
# $args[0] = mark line, $args[1] = pattern
cat > "$TMP/p5-since.ps1" <<'PS'
param([int]$Mark, [string]$Pattern, [string]$MarkFile = '')
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if(-not $f){Write-Output 'SINCE_HITS 0';exit}
$all = Get-Content $f.FullName
# THE OFFSET IS ONLY VALID IN THE FILE IT WAS TAKEN FROM. The agent rotates to a new log on every
# restart, and several cells restart it. Applying a stale offset to a different file counts lines
# from an arbitrary point in the middle of it - measured 2026-08-31: an SG9 cell reported 3 deny
# hits for a clause that a clean direct measurement showed fired 0 times. If the file changed,
# EVERY line in the current one postdates the mark, so the whole file is the correct window.
if ($MarkFile -and $MarkFile -ne $f.Name) {
  Write-Output ("SINCE_NOTE log rotated ($MarkFile -> " + $f.Name + "); counting the whole new file")
  $new = $all
} else {
  $new = if ($all.Count -gt $Mark) { $all[$Mark..($all.Count-1)] } else { @() }
}
$hits = @($new | Select-String -Pattern $Pattern -SimpleMatch)
Write-Output ("SINCE_HITS " + $hits.Count)
@($hits | Select-Object -First 3) | ForEach-Object { Write-Output ("  S " + $_.Line) }
PS

mapped_list(){  # $1 = tag -> "<count>|<WxH>,<WxH>,..." of what dom0 maps right now
  local t="$OUT/$1.tar"; rm -f "$t"
  q shot "$t" >/dev/null 2>&1
  local n; n=$(tar tf "$t" 2>/dev/null | grep -c '\.png$'); n=${n:-0}
  local dims=""
  if [ "$n" -gt 0 ]; then
    rm -rf "$OUT/.x"; mkdir -p "$OUT/.x"; tar xf "$t" -C "$OUT/.x" 2>/dev/null
    dims=$(for f in "$OUT/.x"/*.png; do [ -e "$f" ] && python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',d[16:24]); print(f'{w}x{h}')" "$f"; done | paste -sd,)
  fi
  echo "$n|$dims"
}

# THE CONTROL WINDOW - the fix for the defect this harness shipped with.
# Every "nothing mapped" verdict is meaningless unless the capture path was PROVEN alive in the SAME
# measurement. Measured 2026-08-30: an 18 s settle was shorter than PowerShell's runtime C# compile,
# so the probe window did not exist yet, `qtest shot` returned an empty tar, and the harness read
# that as "the gate denied it". SG3 was scored FAIL against a window the agent's own log showed it
# had MAPped (`SendWindowMap ... ovr=0`), and SG2/SG4/SG9's "0 mapped" halves were equally blind.
# A small Notepad now stays mapped throughout; a cell whose shot cannot see IT is INVALID-INSTRUMENT,
# never a pass.
CONTROL_DIM=""; CONTROL_N=0
start_control(){
  q run 'cmd /c start "" notepad.exe' >/dev/null 2>&1
  local d n
  for _ in $(seq 1 12); do
    sleep 8
    d=$(mapped_list control); n=${d%%|*}
    if [ "${n:-0}" -ge 1 ]; then CONTROL_DIM=$(echo "${d#*|}" | cut -d, -f1); CONTROL_N=$n; return 0; fi
  done
  return 1
}
control_alive(){ echo "$1" | grep -q "$CONTROL_DIM"; }

# Wait until the PROBE ITSELF says it created the window. Never a fixed sleep: the probe's own JSON
# is the readiness signal, and dom0 lags it by a further ~5-20 s.
# THREE exits (experimenter rule 6), and the caller must branch on which was taken:
#   0 = the probe reported "visible":true - ready, grade it;
#   2 = the probe REPORTED but the window is not visible ("visible":false is written once and
#       never changes; containment_absent means the probe refused and exited) - a REAL result,
#       terminal: grade it, NEVER relaunch;
#   1 = no probe report at all by the deadline - the LAUNCH never took (instrument gap; the only
#       exit a relaunch may answer).
wait_probe_ready(){  # $1 = guest file path
  local body=""
  for _ in $(seq 1 25); do
    body=$(T=90 q run "cmd /c type $1" 2>/dev/null | tr -d '\r')
    echo "$body" | grep -qa '"visible":true' && return 0
    echo "$body" | grep -qa '"visible":false\|containment_absent' && return 2
    sleep 6
  done
  echo "$body" | grep -qa '===\|{' && return 2
  return 1
}

q run 'cmd /c taskkill /f /im notepad.exe & taskkill /f /im chromerepro.exe & exit 0' >/dev/null 2>&1
sleep 4
if ! start_control; then
    log "FATAL: the control window never became visible to local.WinScreenshot. The capture path is"
    log "       blind, so no 'nothing mapped' verdict from this rig could mean anything."
    exit 2
fi
log "=== control UP: dom0 sees $CONTROL_N window(s), control=$CONTROL_DIM - capture path proven alive ==="

# run_cell <id> <probe-mode> <expect: map|nomap> <discriminator>
run_cell(){
  local id="$1" mode="$2" expect="$3" disc="$4"
  log "=== $id: -Mode $mode  (expect: $expect) ==="
  local markraw mark markfile
  markraw=$(T=200 q pushrun "$TMP/p5-mark.ps1" | tr -d '\r' | grep -aoE 'AGENTMARK [0-9]+ [^ ]+' | head -1)
  mark=$(echo "$markraw" | awk '{print $2}'); markfile=$(echo "$markraw" | awk '{print $3}')
  local gf="C:\\ProgramData\\Qubes\\fsgate-$id.txt"
  q run "cmd /c del /q $gf 2>nul & exit 0" >/dev/null 2>&1
  # LAUNCH VERB: guest/run-as-user.ps1 (schtasks /ru user /it), NOT a detached
  # `cmd /c start "" powershell -WindowStyle Hidden`. Measured 2026-09-04 on win10-acc (fresh
  # 4.3.18 standalone, contained 1920x1080 < host): EVERY SG2/SG3/SG4 launch via the detached
  # hidden-powershell produced "no report file" - the child never ran the probe - while the
  # IDENTICAL probe invocation in the foreground worked ("visible":true, correct refusal when
  # uncontained). The task scheduler gives the probe a supervised user-token process instead of a
  # fire-and-forget `start` child, and it is the launcher the rig already trusts for backgrounded
  # user-session scripts (rnd-shell-surfaces.sh). Args ride -ArgsB64: -ScriptArgs re-splits on
  # whitespace at every hop (run-as-user.ps1 header, measured 2026-08-31).
  #
  # NO shell redirection and NO visible launcher console, still: an earlier form wrapped the probe
  # in `cmd /c "... > file"`, whose CONSOLE WINDOW (979x512) is itself mapped by the agent. The
  # harness counted it and reported SG2/SG4 as FAIL - "a screen-sized window reached dom0" - when
  # the only extra window was the launcher's own console and the probe had been denied correctly.
  # run-as-user's own schtasks child DOES get a visible conhost, which is why it runs the
  # p5-fsgate-launch.ps1 stage (exits in ~1-2 s, probe hidden via Start-Process) and never the
  # probe directly - see the stage's header above ensure_probe_pushed.
  #
  # BOUNDED RELAUNCH, covering ONLY the "launch never took" instrument gap (wait exit 1: no probe
  # report at all). Measured 2026-09-04 on win10-acc (fresh standalone): SG2/SG3/SG4 each burned the
  # full deadline with "never reported a created window" while the same suite's control Notepad was
  # up and the SAME cells passed on warm win10-p4 - launch flakiness, not the product. A probe that
  # DID report (exits 0/2) is a REAL result and is graded exactly as before, never relaunched:
  # retrying a reported window could let a once-only wrong mapping vanish into a clean second
  # attempt. The gate under test is deterministic on styles, so a relaunched window exercises the
  # identical ShouldAcceptWindow decision - a real leak cannot hide behind the retry.
  local attempt=1 ready ab64 lout
  while :; do
    ab64=$(printf '%s' "-Mode $mode -HoldSeconds 220 -HostWidth $HOSTW -HostHeight $HOSTH -OutFile $gf" \
      | python3 -c "import base64,sys;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(),end='')")
    lout=$(T=120 q pushrun guest/run-as-user.ps1 -Tag "fsg$id" -Script "$GUEST\\p5-fsgate-launch.ps1" -ArgsB64 "$ab64" -NoWait \
      | tr -d '\r' | grep -ao 'RUNASUSER.*' | head -1)
    log "  launch(as-user): ${lout:-NO-RESPONSE (qrexec/push failed?)}"   # keep the error text - a discarded transient took a whole cell once
    wait_probe_ready "$gf"; ready=$?
    [ "$ready" -ne 1 ] && break          # 0 = visible; 2 = reported-not-visible: real, grade it
    [ "$attempt" -ge 3 ] && break        # bounded: a silent launch gets exactly two relaunches
    log "  probe launch $attempt/3 produced no report file - killing strays, re-verifying the script, relaunching"
    # a half-started probe must not double the window under the relaunch; same hammer as post-cell
    q run 'cmd /c taskkill /f /im powershell.exe 2>nul & exit 0' >/dev/null 2>&1
    sleep 5
    ensure_probe_pushed || log "  WARNING: probe scripts still not verifiable on the guest"
    q run "cmd /c del /q $gf 2>nul & exit 0" >/dev/null 2>&1
    attempt=$((attempt+1))
  done

  if [ "$ready" -eq 1 ]; then
    log "  -> INVALID-INSTRUMENT: the probe never reported a created window in $attempt launches; this cell grades nothing"
    printf '%s\tprobe-ready\tINVALID-INSTRUMENT\tno probe report after %s launches\t\n' "$id" "$attempt" >> "$OUT/verdicts.tsv"
    rc=1; return
  fi
  [ "$ready" -eq 2 ] && log "  probe REPORTED but never visible:true - grading the real report (no relaunch)"
  local probe; probe=$(T=200 q run "cmd /c type $gf" | tr -d '\r' | grep -a '^{' | head -1)

  # Identify the probe BY SIZE, not by a window count. A count is fooled by anything else that
  # happens to be on the desktop - a stray Notepad left by an aborted run, an installer, a toast -
  # in BOTH directions: a leftover window fakes "the gate leaked", and a probe that maps while
  # something else closes fakes "nothing mapped". The probe reports its own rect, and on a
  # contained screen the gap is wide (probe 1024x768 vs a Notepad at 744x501 = 73% of width).
  local pw ph
  pw=$(echo "$probe" | grep -ao '"rect":"[0-9]*,[0-9]* [0-9]*x[0-9]*"' | grep -ao '[0-9]*x[0-9]*' | cut -dx -f1)
  ph=$(echo "$probe" | grep -ao '"rect":"[0-9]*,[0-9]* [0-9]*x[0-9]*"' | grep -ao '[0-9]*x[0-9]*' | cut -dx -f2)
  local probe_mapped=no saw_control=no alldims="" n dims d
  for _ in $(seq 1 6); do
    d=$(mapped_list "$id"); n=${d%%|*}; dims="${d#*|}"
    control_alive "$dims" && saw_control=yes
    alldims="$alldims $dims"
    # tolerance: the agent trims the invisible resize border on captioned windows
    # (measured 1600x900 -> 1586x893), so match at >=93% width and >=88% height.
    for wh in $(echo "$dims" | tr ',' ' '); do
      local mw=${wh%x*} mh=${wh#*x}
      [ -z "$mw" ] && continue
      if [ "$mw" -ge $(( pw * 93 / 100 )) ] && [ "$mh" -ge $(( ph * 88 / 100 )) ]; then probe_mapped=yes; fi
    done
    sleep 10
  done
  # SECOND, INDEPENDENT WITNESS: ask the agent whether it announced this window to dom0 at all.
  # The screenshot cannot see an override-redirect window (see agent_mapped above), so a cell
  # graded on dom0 dims alone is blind to exactly the leak SG4 asserts against.
  local phwnd nmap
  phwnd=$(echo "$probe" | grep -ao '"hwnd":"0x[0-9A-Fa-f]*"' | grep -ao '0x[0-9A-Fa-f]*' | head -1)
  if [ -n "$phwnd" ]; then
    nmap=$(agent_mapped "$phwnd")
    if [ -n "$nmap" ] && [ "$nmap" -gt 0 ]; then
      log "  AGENT MAPPED the probe: $nmap MAP message(s) for $phwnd - dom0 was offered this window"
      probe_mapped=yes
    fi
  fi

  local hits nh
  hits=$(T=300 q pushrun "$TMP/p5-since.ps1" -Mark "${mark:-0}" -Pattern "$disc" -MarkFile "${markfile:-}" | tr -d '\r')
  nh=$(echo "$hits" | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
  { echo "$probe"; echo "$hits"; echo "AGENTMAP $phwnd -> ${nmap:-?}"; } > "$OUT/$id.probe.txt"
  q run 'cmd /c taskkill /f /im powershell.exe 2>nul & exit 0' >/dev/null 2>&1
  sleep 8

  local existed=no
  echo "$probe" | grep -qa '"visible":true' && existed=yes
  log "  probe: ${probe:-NONE}"
  log "  probe ${pw}x${ph} mapped=$probe_mapped  control_seen=$saw_control  agent_map=${nmap:-?}  dom0 dims:${alldims:- none}  '${disc}' hits=${nh:-0}"

  if [ "$existed" != yes ]; then
    log "  -> INVALID-VACUOUS: probe window never existed"
    printf '%s\tvacuity\tINVALID-VACUOUS\tno visible probe window\t\n' "$id" >> "$OUT/verdicts.tsv"; rc=1; return
  fi
  if [ "$saw_control" != yes ]; then
    log "  -> INVALID-INSTRUMENT: the control window was not visible to the capture path in this cell,"
    log "     so 'nothing mapped' proves nothing about the guest. Re-run; do not grade."
    printf '%s\tinstrument-alive\tINVALID-INSTRUMENT\tcontrol absent from every sample\t\n' "$id" >> "$OUT/verdicts.tsv"; rc=1; return
  fi

  if [ "$expect" = nomap ]; then
    if [ "$probe_mapped" = no ] && [ "${nh:-0}" -gt 0 ]; then
      log "  -> PASS-UNPROVEN: no ${pw}x${ph} window in dom0, AND the agent logged the deny"
      printf '%s\tnot-mapped\tPASS-UNPROVEN\tno %sx%s in dom0 (control seen), %s x%s\t\n' "$id" "$pw" "$ph" "$disc" "${nh}" >> "$OUT/verdicts.tsv"
    elif [ "$probe_mapped" = yes ]; then
      log "  -> FAIL: a ${pw}x${ph} window reached dom0 - the gate leaked"
      printf '%s\tnot-mapped\tFAIL\t%sx%s present in dom0 dims:%s\t\n' "$id" "$pw" "$ph" "$alldims" >> "$OUT/verdicts.tsv"; rc=1
    else
      log "  -> INVALID-VACUOUS: nothing extra mapped but the agent never logged the deny"
      printf '%s\tnot-mapped\tINVALID-VACUOUS\t0 discriminator hits\t\n' "$id" >> "$OUT/verdicts.tsv"; rc=1
    fi
  else
    if [ "$probe_mapped" = yes ]; then
      log "  -> PASS-UNPROVEN: the captioned screen-sized window mapped, as the README requires"
      printf '%s\tmapped\tPASS-UNPROVEN\t%sx%s present in dom0 dims:%s\t\n' "$id" "$pw" "$ph" "$alldims" >> "$OUT/verdicts.tsv"
    else
      log "  -> FAIL: a captioned windowed-fullscreen window did NOT map - the gate over-fired"
      printf '%s\tmapped\tFAIL\tno %sx%s in dom0 dims:%s\t\n' "$id" "$pw" "$ph" "$alldims" >> "$OUT/verdicts.tsv"; rc=1
    fi
  fi
}

# ---------------------------------------------------------------- P5-4: must NOT map
run_cell SG4 overrideredirect nomap 'unconditionally denied, feature or not'
run_cell SG2 borderless       nomap 'hidden (set service.gui-fullscreen to allow)'

# ---------------------------------------------------------------- P5-5: must map
run_cell SG3 captioned        map   'not-used'

# ---------------------------------------------------------------- SG9: Start, per the shipped spec
log "=== SG9: Start is NOT presented in seamless (acceptance is the OPPOSITE of 'Start maps') ==="
markraw=$(T=200 q pushrun "$TMP/p5-mark.ps1" | tr -d '\r' | grep -aoE 'AGENTMARK [0-9]+ [^ ]+' | head -1)
mark=$(echo "$markraw" | awk '{print $2}'); markfile=$(echo "$markraw" | awk '{print $3}')
T=400 q pushrun guest/open-start.ps1 >/dev/null 2>&1
sleep 10
d9=$(mapped_list SG9); n9=${d9%%|*}
h9=$(T=300 q pushrun "$TMP/p5-since.ps1" -Mark "${mark:-0}" -Pattern 'Start surface not presented in seamless mode' -MarkFile "${markfile:-}" | tr -d '\r')
nh9=$(echo "$h9" | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
log "  dom0 windows=$n9 (control $CONTROL_N) [${d9#*|}]  deny hits=${nh9:-0}"
if [ "$n9" -le "$CONTROL_N" ] && [ "${nh9:-0}" -gt 0 ]; then
  log "  -> PASS-UNPROVEN: no Start window in dom0, and the agent logged the deny"
  echo -e "SG9\tstart-not-presented\tPASS-UNPROVEN\tdom0=$n9 (control $CONTROL_N), deny x${nh9}\t" >> "$OUT/verdicts.tsv"
elif [ "$n9" -gt "$CONTROL_N" ]; then
  log "  -> FAIL: $n9 mapped vs control $CONTROL_N"
  echo -e "SG9\tstart-not-presented\tFAIL\tdom0=$n9 vs control $CONTROL_N\t" >> "$OUT/verdicts.tsv"; rc=1
else
  log "  -> INVALID-VACUOUS: nothing mapped and no deny line - Start may never have opened"
  echo -e "SG9\tstart-not-presented\tINVALID-VACUOUS\t0 deny hits\t" >> "$OUT/verdicts.tsv"; rc=1
fi

log "=== P5 finished rc=$rc ==="
log "ATTENDED-PENDING (never run unattended - they need service.gui-fullscreen, which is banned):"
log "  SG1 fail-proof (diag build, phase test removed), SG2 feature-ON arm, SG4 feature-ON arm,"
log "  SG7 fail-proof (naive cloak filter diag build), SG10 both-bits arm"
exit $rc
