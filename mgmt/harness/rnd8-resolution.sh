#!/bin/bash
# RND-8 — dynamic resolution changes, judged FROM PIXELS.
#
# WHY PIXELS AND NOT A RETURN CODE. The known failure at exactly this path is
# `AcquireNextFrame` returning 0x887a0026 ("the keyed mutex was abandoned") on a resolution change,
# after which the capture thread dies. Everything guest-side still reports success: the mode is set,
# the agent re-announces the screen, `EnumDisplaySettings` reads back the new size. What stops is
# the FRAMES. So the acceptance is: after each resize, make a visible change in a mapped window and
# require the dom0 capture of that window to CHANGE. A resize that reports success while the picture
# is frozen is the defect, and only a pixel comparison sees it.
#
# SCOPE, STATED HONESTLY. RND-8 has two drivers and this runner exercises ONE:
#   * `guest/set-resolution.ps1` — guest-initiated. Exercised here.
#   * `tools/qtest resize <WxH>`  — dom0-initiated, the product path a user actually drives.
#     BLOCKED: the installed dom0 service reports `no_window` even when windows exist (its geom()
#     shells out to xwininfo); `dom0/10-install-resize-service.sh` v5 distinguishes the causes but
#     DOM0 MUST REINSTALL IT before that half can run. Recorded as BLOCKED, never folded into a pass.
#
# CONTAINMENT: only modes strictly smaller than the host are used. The adapter also offers the host
# size, and selecting it would put a host-sized guest desktop on the owner's display.
#
#   mgmt/harness/rnd8-resolution.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: required guest script(s) missing:$m" >&2; exit 2; }; }
require_scripts guest/set-resolution.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
source mgmt/harness/lifecycle-lib.sh   # ctl_start/ctl_stop: the notepad this run starts is stopped by its recorded identity, never by name
source mgmt/harness/window-grade-lib.sh # wg_png_dims/wg_png_wxh/wg_png_id: the ONE reader of a capture's dimensions
AGL=$(agent_lines_ps)   # the PowerShell prelude every log query below starts with: $agentlines = the RUNNING agent's lines only
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/RND8-$VM}"
# A contaminated subject is refused BEFORE any work: this script's default output dir carries no
# run-id, so a second attempt would otherwise append to the first attempt's artefacts and be read
# back as one run. Pass a fresh outdir to run again.
declare -F attempt_dir >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh"
attempt_dir "$OUT" || exit 1

mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
# Any PowerShell with quotes or backslashes goes through -EncodedCommand: bash -> qtest ->
# cmd.exe -> powershell re-splits a nested-quote one-liner at every hop, and the failure mode
# is SILENCE, not an error (protocol 0.8b rule 2).
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) rnd8[$VM]: $*" | tee -a "$OUT/rnd8.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0

HOSTW=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[1]}'); HOSTW=${HOSTW:-5120}
HOSTH=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[2]}'); HOSTH=${HOSTH:-1440}

log "=== disarm the update scan ==="
cat > "$TMP/d.ps1" <<'PS'
$t=Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if($t){ & schtasks /change /tn QubesWindowsUpdateScan /disable *>$null }
Write-Output 'DISARMED done'
PS
T=300 q pushrun "$TMP/d.ps1" >/dev/null 2>&1
trap 'q run "cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- the mode list
LST=$(T=300 q pushrun guest/set-resolution.ps1 -List | tr -d '\r' | grep -a '^{')
echo "  $LST" | tee "$OUT/modes.json"
MODES=$(echo "$LST" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip())
hw,hh=$HOSTW,$HOSTH
out=[m for m in d.get('modes',[]) if int(m.split('x')[0])<hw and int(m.split('x')[1])<hh]
print(' '.join(out))")
log "  sub-host modes to exercise: ${MODES:-none}"
[ -n "$MODES" ] || { log "FATAL: no sub-host mode offered"; exit 2; }

# ---------------------------------------------------------------- pixel helper
# hash of the LARGEST mapped window's PNG - the same window across a pair of captures.
shot_hash(){
  local t="$TMP/s.tar"; rm -f "$t"; rm -rf "$TMP/sx"; mkdir -p "$TMP/sx"
  q shot "$t" >/dev/null 2>&1
  [ -s "$t" ] || { echo "NOCAP"; return; }
  tar xf "$t" -C "$TMP/sx" 2>/dev/null
  local big=""; big=$(ls -S "$TMP/sx"/*.png 2>/dev/null | head -1)
  [ -n "$big" ] || { echo "NOWIN"; return; }
  wg_png_id "$big"
}

# type into Notepad so the pixels genuinely change. THE TYPIST RUNS AS SYSTEM, THROUGH pushrun, and
# activates the notepad by its OWNING PID - the one ctl_start recorded - never by caption.
# Measured 2026-11-01 on win11-acc against a ctl_start notepad: AppActivate from the user session
# (guest/run-as-user.ps1, the previous shape) -> False, so every pixel row and the keyed-mutex row
# of this suite came back INVALID-INSTRUMENT "typing stimulus did not land" on each run that reached
# them, and the suite is in none of the 46 receipts; AppActivate(<pid>) as SYSTEM -> 'TYPED ok' and
# the window's hash moved 164c758c5c295bf1 -> e7bbca2aa600bf89 (1418x736). The notepad ctl_start
# opens is a qrexec (SYSTEM) process, so the typist on the same desktop is the one that reaches it;
# tools/accept-clean.sh types the same way. By pid, not by title: the caption is "Editor" on a
# German guest and a title match there reads as a dead stimulus (owner 2026-10-01: never identify a
# window by its caption, not even in a harness).
# NO KEYSTROKES SINCE 2026-11-11. On the 23b19e36 chain AppActivate+SendKeys printed 'TYPED ok' in
# all six unarmed passes of failproof-faultinject while the keystrokes never reached the window: the
# agent's log shows the typed notepad (0x1c0274) receiving caret-blink damage only, and the witness
# read the same empty-notepad hash in every control (5088e1d307bbff6c, also seen on earlier days).
# 'TYPED ok' meant "AppActivate found a window", not "text arrived" - activation is subject to the
# foreground lock and SendWait types into whatever holds focus. The text now goes straight into the
# pid's edit control with WM_SETTEXT, which needs neither the foreground nor the input queue, and
# 'TYPED ok' is printed only when WM_GETTEXT reads the marker back out of the control.
cat > "$TMP/type.ps1" <<'PS'
param([int]$ProcId)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Rnd8Edit {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    // The edit control inside a VISIBLE top-level window the pid owns: "Edit" (classic Notepad) or
    // a "RichEdit..." class (RichEditD2DPT in the newer Notepad).
    public static IntPtr Find(uint want) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((top, l) => {
            uint pid; GetWindowThreadProcessId(top, out pid);
            if (pid == want && IsWindowVisible(top))
                EnumChildWindows(top, (h, l2) => {
                    var c = new StringBuilder(64); GetClassNameW(h, c, 64);
                    string s = c.ToString();
                    if (s == "Edit" || s.StartsWith("RichEdit")) { found = h; return false; }
                    return true;
                }, IntPtr.Zero);
            return found == IntPtr.Zero;
        }, IntPtr.Zero);
        return found;
    }
    // WM_SETTEXT, then WM_GETTEXTLENGTH + WM_GETTEXT: returns what the control HOLDS afterwards.
    public static string Put(IntPtr edit, string text) {
        SendMessageW(edit, 0x000C, IntPtr.Zero, text);
        int n = (int)SendMessageW(edit, 0x000E, IntPtr.Zero, IntPtr.Zero);
        var b = new StringBuilder(n + 1);
        SendMessageW(edit, 0x000D, (IntPtr)(n + 1), b);
        return b.ToString();
    }
}
'@
$e = [Rnd8Edit]::Find([uint32]$ProcId)
if ($e -eq [IntPtr]::Zero) { Write-Output ('TYPED no-edit pid=' + $ProcId); exit 0 }
$mark = 'RND8 ' + (Get-Random)
$back = [Rnd8Edit]::Put($e, $mark + "`r`n" + ('#' * 60) + "`r`n")
if ($back.Contains($mark)) { Write-Output ('TYPED ok pid=' + $ProcId + ' edit=0x' + $e.ToInt64().ToString('x')) }
else { Write-Output ('TYPED no-readback pid=' + $ProcId + ' held=' + $back.Length) }
PS

# A notepad left by an earlier run is NOT ours to stop (owner 2026-10-07: nothing is killed by
# name): reported, not touched. Ours is started by handle and stopped by that identity at the end.
left=$(r 'cmd /c tasklist /nh /fo csv /fi "imagename eq notepad.exe"' | grep -aci '^"notepad\.exe"'); left=${left:-0}
[ "$left" -gt 0 ] && log "  WARNING: $left notepad.exe process(es) from an earlier run are on the guest - not started by this run, not stopped"
read -r _ NP_PID NP_START <<< "$(ctl_start notepad)"; sleep 14

# ---------------------------------------------------------------- per-mode
for M in $MODES; do
  W=${M%x*}; H=${M#*x}
  log "=== mode $M ==="
  t0=$(date +%s%3N)
  res=$(T=300 q pushrun guest/set-resolution.ps1 -Width "$W" -Height "$H" | tr -d '\r' | grep -a '^{' | tail -1)
  t1=$(date +%s%3N)
  log "  set: $res"
  echo "$res" | grep -qa '"ok":true' || {
    log "  -> FAIL: the guest did not adopt $M"
    printf 'RND-8\tmode-followed-%s\tFAIL\t%s\t%s\n' "$M" "$res" "$EV" >> "$V"; rc=1; continue; }

  # the AGENT must agree, or dom0 is being told a different screen than the guest has.
  # THE BELIEF, NOT THE ANNOUNCEMENT (2026-11-01). This read the agent's last `A6CONFIGURE window 0
  # -> WxH`, the whole-desktop configure a seamless agent never sends (ADR-windows s5: a seamless
  # guest never holds a whole-desktop grant; SeamlessNoScreenGrant on by default since 2026-09-13).
  # Every mode-followed row therefore FAILED "the agent last told dom0 none" while the agent's own
  # log carried `RESDRIFT believed=5120x1440 actual=1920x1080 - adopting the actual mode` - the
  # belief had followed; the reader was looking for a line the product deliberately stopped
  # writing. agent_screen (lifecycle-lib.sh) reads the last line that WROTE the belief, bounded to
  # the running agent's own lines. One bounded re-read when the query itself answers nothing.
  ag=$(T=300 agent_screen)
  [ -n "$ag" ] || { sleep 5; ag=$(T=300 agent_screen); }
  log "  agent: ${ag:-?}"

  # GRADE THE AGENT'S AGREEMENT, which is what this check has always CLAIMED to do.
  #
  # Until 2026-08-31 `ag` was logged here and then never compared: `mode-followed-<M>` was
  # emitted from inside the PIXEL branch below, with the detail string "guest+agent both report
  # <M>" - a statement about a comparison that no line of code performed. Measured with
  # FI_NOSCREENCONFIG armed (the agent deliberately never tells dom0 the resolution changed):
  # AGENTSCREEN came back `none` for all three modes and the cell still recorded
  # "guest+agent both report 1920x1080". The check could not fail against the exact defect it
  # names, and would have passed a build where dom0 is left on stale geometry forever.
  #
  # Graded on its own now, not as a side effect of the pixel test - a check that can be SKIPPED
  # by an unrelated branch is nearly as bad as one that cannot fail (the other two modes emitted
  # no mode-followed verdict at all in that run, because the pixel judge went INVALID first).
  # SINCE 2026-11-01 THE PROPERTY IS THE BELIEF. In seamless mode dom0 consumes no window-0 geometry
  # at all (xside.c composes only screen-dump windows from it), so "told dom0" is vacuous there and
  # what a stale belief breaks is the agent's own input normalisation and window clamps. The
  # FI_NOSCREENCONFIG measurement above dates from the grant era and is kept as history.
  agv=$(echo "$ag" | awk '{print $2}')
  if [ -z "$agv" ]; then
    log "  -> INVALID-INSTRUMENT: the agent-screen query returned nothing; not grading mode-followed"
    printf 'RND-8\tmode-followed-%s\tINVALID-INSTRUMENT\tagent-screen query returned no data\t%s\n' "$M" "$EV" >> "$V"; rc=1
  elif [ "$agv" = "$M" ]; then
    log "  -> PASS: the guest adopted $M AND the agent's believed screen agrees ($ag)"
    printf 'RND-8\tmode-followed-%s\tPASS-UNPROVEN\tguest adopted %s and the agent believes %s - they agree\t%s\n' "$M" "$M" "$agv" "$EV" >> "$V"
  else
    log "  -> FAIL: the guest adopted $M but the agent still believes '$agv' ($ag) - dom0 is being told stale geometry"
    printf 'RND-8\tmode-followed-%s\tFAIL\tguest adopted %s but the agent believes %s\t%s\n' "$M" "$M" "$agv" "$EV" >> "$V"; rc=1
  fi

  sleep 6
  h1=$(shot_hash)
  # CAPTURE the stimulus result - a discarded stimulus was the bug. type.ps1 reports 'TYPED ok' vs
  # 'TYPED no-activate'; if that is not checked and the stimulus silently fails to land (no window
  # of that pid to activate, SendKeys no-op), the pixels never change, h1==h2, and a MISSING
  # STIMULUS gets recorded as the product capture-death defect (V3: missing data must be
  # INVALID-INSTRUMENT, never FAIL).
  typed=$(T=200 q pushrun "$TMP/type.ps1" "$NP_PID" 2>/dev/null | tr -d '\r')
  sleep 8
  h2=$(shot_hash)
  t2=$(date +%s%3N)
  log "  pixels before=$h1  after=$h2   (set $((t1-t0))ms, first-pixel ~$((t2-t1))ms)"

  if ! echo "$typed" | grep -qa 'TYPED ok'; then
    log "  -> INVALID-INSTRUMENT: the visible-change typing stimulus did not land at $M (no 'TYPED ok');"
    log "     without a guaranteed pixel change, identical h1==h2 says nothing about frozen capture - not grading"
    printf 'RND-8\tpixels-change-after-resize-%s\tINVALID-INSTRUMENT\ttyping stimulus did not land (type.ps1 gave no TYPED ok) - not a product frozen-capture\t%s\n' "$M" "$EV" >> "$V"; rc=1
  elif [ "$h1" = NOCAP ] || [ "$h2" = NOCAP ] || [ "$h1" = NOWIN ] || [ "$h2" = NOWIN ]; then
    log "  -> INVALID-INSTRUMENT: no capture at $M, so the pixel judge could not run"
    printf 'RND-8\tpixels-change-after-resize-%s\tINVALID-INSTRUMENT\tcapture returned %s / %s\t%s\n' "$M" "$h1" "$h2" "$EV" >> "$V"; rc=1
  elif [ "$h1" != "$h2" ]; then
    log "  -> PASS: capture is alive after the resize (window ${h2%%:*}, pixels changed)"
    printf 'RND-8\tpixels-change-after-resize-%s\tPASS-UNPROVEN\t%s -> %s after a visible guest change\t%s\n' "$M" "$h1" "$h2" "$EV" >> "$V"
  else
    log "  -> FAIL: identical pixels after a visible guest change - capture is FROZEN at $M"
    log "     (this is the 0x887a0026 keyed-mutex signature: everything reports success, frames stop)"
    printf 'RND-8\tpixels-change-after-resize-%s\tFAIL\tidentical capture hash %s before and after a visible change\t%s\n' "$M" "$h1" "$EV" >> "$V"; rc=1
  fi
done

# ---------------------------------------------------------------- the keyed-mutex check
# THE CRITERION IS RECOVERY, NOT ABSENCE.
# CLAUDE.md records a "PREREQUISITE BUG": on a resolution change AcquireNextFrame fails with
# 0x887a0026 ("the keyed mutex was abandoned") AND THE CAPTURE THREAD DIES. Measured 2026-08-31
# across three mode changes: the error occurred 12 times and the thread never died once. Each
# occurrence is followed immediately by `RecreateDuplication: STAGING dormant-park-path (screen
# grant kept across duplication recreate)` and a fresh `GetDuplication` at the NEW size, e.g.
#   GetFrame: ... 0x887a0026 -> RecreateDuplication -> Got output duplication ... 1024x768
# 0x887a0026 is simply how DXGI signals that the duplication is stale after a mode change; demanding
# ZERO occurrences would fail a correctly-behaving build. What must hold is that every occurrence is
# recovered and FRAMES RESUME - and the per-mode pixel comparison above is the independent proof of
# the second half (CLAUDE.md: "RecreateDuplication: recovered - windows kept" was once logged while
# every dom0 window was frozen, so the log line alone is not enough).
# THROUGH -EncodedCommand, NOT nested quotes. The previous form was a `cmd /c powershell
# -Command "... \"...\" ..."` one-liner, and on 2026-08-31 it was measured returning NOTHING at
# all: cmd echoed the command and produced no output, no error. km/rec/died came back EMPTY,
# `[ "" -eq 0 ]` failed, and the else-branch wrote `keyed-mutex-recovered FAIL` with a detail
# line reading " abandonments,  recreates,  thread deaths". A fabricated product defect from a
# silently broken query - protocol 0.8b rule 2, the same hazard that made a health-check plant
# silently do nothing. The identical query through -EncodedCommand returns `KM=10 RC=23 DIED=0`.
# BOUNDED TO THE RUNNING AGENT'S LINES ($AGL, lifecycle-lib agent_lines_ps). The daily log holds every
# lifetime of the day, and on 2026-11-01 the whole-file count scored DIED=4 from the orderly shutdown
# lines of two EARLIER agents ("capture thread still in its acquire at exit", "window event thread
# exiting on request") against KM=3, one per lifetime - a thread-death verdict on an agent that had
# lost no thread.
KM=$(psrun "$AGL"$'\n''$a=$agentlines
Write-Output ("KM=" + @($a | Select-String -SimpleMatch 887a0026).Count + " RC=" + @($a | Select-String -SimpleMatch RecreateDuplication).Count + " DIED=" + @($a | Select-String -Pattern "capture thread|thread exiting|giving up").Count + " PID=" + $agentpid)' \
  | grep -aoE 'KM=[0-9]+ RC=[0-9]+ DIED=[0-9]+ PID=[0-9]*' | head -1)
km=$(echo "$KM" | grep -ao 'KM=[0-9]*' | cut -d= -f2); rec=$(echo "$KM" | grep -ao 'RC=[0-9]*' | cut -d= -f2); died=$(echo "$KM" | grep -ao 'DIED=[0-9]*' | cut -d= -f2)
log "=== keyed mutex: ${km:-?} abandonment(s), ${rec:-?} RecreateDuplication, ${died:-?} thread death(s) - agent pid $(echo "$KM" | grep -ao 'PID=[0-9]*' | cut -d= -f2) ==="

# ---------------------------------------------------------------- FRAME LIVENESS, from OUTPUT
# The `DIED` counter above is a LOG GREP, and on 2026-08-31 it was measured to be worthless for
# the defect it names: with FI_CAPTURE_EXIT armed - the capture thread returning without
# signalling its error event - the ONLY line in the whole agent log matching
# /capture thread|thread exiting|giving up/ was the FAULT INJECTOR'S OWN MESSAGE. The check
# scored a "thread death" it had detected from the injector announcing itself, and a silently
# dead capture thread produces no such line at all.
#
# So ask the capture engine whether it is still PRODUCING. QGAPERF emits one line per frame with
# a monotonic `seq=`; if seq advances across a visible guest change, frames are genuinely being
# captured. That cannot be satisfied by any log message, which is the whole point
# (CLAUDE.md: "Judge output, not logs").
perf_seq(){ psrun "$AGL"$'\n''$m=@($agentlines | Select-String -Pattern "QGAPERF,v=\d+,seq=(\d+)")
if ($m.Count -eq 0) { Write-Output "PERFSEQ none" }
else { Write-Output ("PERFSEQ " + $m[-1].Matches[0].Groups[1].Value) }' | grep -aoE 'PERFSEQ [0-9]+|PERFSEQ none' | awk '{print $2}' | head -1; }

s0=$(perf_seq)
# CAPTURE the liveness stimulus too: a flat QGAPERF seq after a stimulus that never landed is a
# missing stimulus, not a dead capture thread. Grading it as capture-death would fabricate a product
# defect (V3), the same class as the per-mode pixel judge above.
typed2=$(T=200 q pushrun "$TMP/type.ps1" "$NP_PID" 2>/dev/null | tr -d '\r')
sleep 8
s1=$(perf_seq)
log "  frame liveness: QGAPERF seq $s0 -> $s1"
if echo "$typed2" | grep -qa 'TYPED ok'; then live_stim=yes; else live_stim=no; fi
alive=unknown
if [ "$s0" = none ] || [ "$s1" = none ] || [ -z "$s0" ] || [ -z "$s1" ]; then
  alive=unknown
elif [ "$s1" -gt "$s0" ] 2>/dev/null; then alive=yes
else alive=no
fi
# MISSING DATA IS AN INSTRUMENT FAULT, NOT A PRODUCT VERDICT. CLAUDE.md says missing data must
# fail - it must never be approximated or skipped - but failing it as FAIL would put a defect
# on the PRODUCT's record that the product never committed. Distinguish the two explicitly.
if [ -z "$km" ] || [ -z "$rec" ] || [ -z "$died" ]; then
  log "  -> INVALID-INSTRUMENT: the log counter returned no data (raw='${KM}'). Nothing is graded"
  log "     here; this says nothing about the guest, only that the query did not run."
  printf 'RND-8\tkeyed-mutex-recovered\tINVALID-INSTRUMENT\tcounter query returned no data (raw=%s)\t%s\n' "${KM:-EMPTY}" "$EV" >> "$V"; rc=1
elif [ "$live_stim" = no ]; then
  log "  -> INVALID-INSTRUMENT: the liveness typing stimulus did not land (no 'TYPED ok'), so a flat"
  log "     QGAPERF seq here would be a MISSING STIMULUS, not a capture death. Frame liveness unmeasurable."
  printf 'RND-8\tkeyed-mutex-recovered\tINVALID-INSTRUMENT\tliveness typing stimulus did not land (no TYPED ok) - frame liveness unmeasurable, not a capture death\t%s\n' "$EV" >> "$V"; rc=1
elif [ "$alive" = unknown ]; then
  log "  -> INVALID-INSTRUMENT: QGAPERF produced no seq (is service.gui-agent-debug on?), so frame"
  log "     liveness could not be measured. The log counters alone are NOT sufficient evidence -"
  log "     see the comment above; they were measured detecting the injector rather than a death."
  printf 'RND-8\tkeyed-mutex-recovered\tINVALID-INSTRUMENT\tno QGAPERF seq available; frame liveness unmeasurable\t%s\n' "$EV" >> "$V"; rc=1
elif [ "$alive" = no ]; then
  log "  -> FAIL: frames are NOT advancing (QGAPERF seq $s0 -> $s1) after a visible guest change."
  log "     Capture has stopped producing, whatever the log counters say."
  printf 'RND-8\tkeyed-mutex-recovered\tFAIL\tQGAPERF seq did not advance (%s -> %s) after a visible change: capture is not producing\t%s\n' "$s0" "$s1" "$EV" >> "$V"
  printf 'RND-8\tcapture-thread-survives-resize\tFAIL\tframes stopped: QGAPERF seq %s -> %s\t%s\n' "$s0" "$s1" "$EV" >> "$V"; rc=1
elif [ "$died" -eq 0 ] && [ "$rec" -ge "$km" ]; then
  log "  -> PASS: every abandonment was recovered and the capture thread never died; frames"
  log "     provably resumed (the pixel comparisons above)."
  printf 'RND-8\tkeyed-mutex-recovered\tPASS-UNPROVEN\t%s abandonment(s), %s RecreateDuplication, 0 thread deaths, AND frames provably still advancing (QGAPERF seq %s -> %s after a visible change)\t%s\n' "$km" "$rec" "$s0" "$s1" "$EV" >> "$V"
  printf 'RND-8\tcapture-thread-survives-resize\tPASS-UNPROVEN\tthe prerequisite bug (thread dies on 0x887a0026) did NOT reproduce across %s mode changes, and capture is still PRODUCING (QGAPERF seq %s -> %s)\t%s\n' "$(echo $MODES | wc -w)" "$s0" "$s1" "$EV" >> "$V"
else
  log "  -> FAIL: abandonment(s) not recovered (thread deaths=${died:-?}, recreates=${rec:-?} vs ${km:-?})"
  printf 'RND-8\tkeyed-mutex-recovered\tFAIL\t%s abandonments, %s recreates, %s thread deaths\t%s\n' "$km" "$rec" "$died" "$EV" >> "$V"; rc=1
fi

printf 'RND-8\tdom0-driven-resize\tBLOCKED\tlocal.WinResize returns no_window even with windows present; dom0 must reinstall 10-install-resize-service.sh v5 before this half can run\t%s\n' "$EV" >> "$V"
log "  notepad: $(ctl_stop "${NP_PID:-0}" "${NP_START:-0}")"
log "=== finished rc=$rc ==="
exit $rc
