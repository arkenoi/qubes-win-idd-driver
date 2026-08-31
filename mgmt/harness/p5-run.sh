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

require_scripts guest/disarm-update-scan.ps1 guest/fsgate-probe.ps1 guest/set-resolution.ps1 guest/open-start.ps1
VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/P5-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-120}" ./tools/qtest "$@" 2>/dev/null; }
log(){ echo "$(date -u +%H:%M:%S) p5[$VM]: $*" | tee -a "$OUT/p5.log"; }
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
q push guest/fsgate-probe.ps1 >/dev/null 2>&1
cat > "$TMP/p5-mark.ps1" <<'PS'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if($f){ Write-Output ('AGENTMARK ' + @(Get-Content $f.FullName).Count) } else { Write-Output 'AGENTMARK 0' }
PS
# $args[0] = mark line, $args[1] = pattern
cat > "$TMP/p5-since.ps1" <<'PS'
param([int]$Mark, [string]$Pattern)
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if(-not $f){Write-Output 'SINCE_HITS 0';exit}
$all = Get-Content $f.FullName
$new = if ($all.Count -gt $Mark) { $all[$Mark..($all.Count-1)] } else { @() }
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
wait_probe_ready(){  # $1 = guest file path
  for _ in $(seq 1 20); do
    T=90 q run "cmd /c type $1" 2>/dev/null | tr -d '\r' | grep -qa '"visible":true' && return 0
    sleep 6
  done
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
  local mark; mark=$(T=200 q pushrun "$TMP/p5-mark.ps1" | tr -d '\r' | grep -ao 'AGENTMARK [0-9]*' | awk '{print $2}')
  local gf="C:\\ProgramData\\Qubes\\fsgate-$id.txt"
  q run "cmd /c del /q $gf 2>nul & exit 0" >/dev/null 2>&1
  # -WindowStyle Hidden and NO shell redirection: the previous form wrapped the probe in
  # `cmd /c "... > file"`, whose CONSOLE WINDOW (979x512) is itself mapped by the agent. The harness
  # counted it and reported SG2/SG4 as FAIL - "a screen-sized window reached dom0" - when the only
  # extra window was the launcher's own console and the probe had been denied correctly.
  q run "cmd /c start \"\" powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File $GUEST\\fsgate-probe.ps1 -Mode $mode -HoldSeconds 220 -HostWidth $HOSTW -HostHeight $HOSTH -OutFile $gf" >/dev/null 2>&1

  if ! wait_probe_ready "$gf"; then
    log "  -> INVALID-INSTRUMENT: the probe never reported a created window; this cell grades nothing"
    printf '%s\tprobe-ready\tINVALID-INSTRUMENT\tno window within deadline\t\n' "$id" >> "$OUT/verdicts.tsv"
    rc=1; return
  fi
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
  local hits nh
  hits=$(T=300 q pushrun "$TMP/p5-since.ps1" -Mark "${mark:-0}" -Pattern "$disc" | tr -d '\r')
  nh=$(echo "$hits" | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
  { echo "$probe"; echo "$hits"; } > "$OUT/$id.probe.txt"
  q run 'cmd /c taskkill /f /im powershell.exe 2>nul & exit 0' >/dev/null 2>&1
  sleep 8

  local existed=no
  echo "$probe" | grep -qa '"visible":true' && existed=yes
  log "  probe: ${probe:-NONE}"
  log "  probe ${pw}x${ph} mapped=$probe_mapped  control_seen=$saw_control  dom0 dims:${alldims:- none}  '${disc}' hits=${nh:-0}"

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
mark=$(T=200 q pushrun "$TMP/p5-mark.ps1" | tr -d '\r' | grep -ao 'AGENTMARK [0-9]*' | awk '{print $2}')
T=400 q pushrun guest/open-start.ps1 >/dev/null 2>&1
sleep 10
d9=$(mapped_list SG9); n9=${d9%%|*}
h9=$(T=300 q pushrun "$TMP/p5-since.ps1" -Mark "${mark:-0}" -Pattern 'Start surface not presented in seamless mode' | tr -d '\r')
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
