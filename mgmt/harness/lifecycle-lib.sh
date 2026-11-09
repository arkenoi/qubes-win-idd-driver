# mgmt/harness/lifecycle-lib.sh - process LIFETIME for VM harnesses: the GUI agent is restarted
# through the service that owns it, and a control process the harness started is stopped by the
# identity the harness recorded when it started it. Nothing here finds a process by NAME and
# nothing here kills a relauncher's child.
#
# CALLER CONTRACT - source this from the REPO ROOT, with the subject named in VM (or QTEST_VM) and
# the per-VM lock already held (source mgmt/harness/vmlock.sh; vm_lock "$VM"). A sourced library
# never takes the lock itself. Every function runs ONE guest round trip through tools/qtest and
# returns its facts on stdout; nothing here sleeps on a timer.
#
# WHY (owner, 2026-10-07: "if you terminate something that relaunches you need to make sure it
# STOPS relaunching beforehand ... thats why we do not kill processes by name"). Every harness
# that needed a fresh agent did `Stop-Service QubesGuiWatchdog; Get-Process gui-agent |
# Stop-Process -Force; Start-Service` and then polled Get-Process for a pid not seen before. The
# kill raced the service's own relaunch (the watchdog respawns the agent it owns the instant it
# exits), so the toggle sometimes measured the survivor - which failproof-gates.sh and
# gate-preflight.sh then papered over with an INVALID-INSTRUMENT branch for "the old one survived
# Stop-Process". The 2026-10-03 sweep fixed the SHIPPED scripts only; this library is the fix for
# the harnesses, and tools/lint-harness.py L17/L18 refuse the old shape in every file.
#
#   agent_restart_push            push guest/restart-gui-agent.ps1 to the guest and PROVE the copy
#                                 (sha256 of the guest file == the repo file). rc 1 = not proven:
#                                 the caller refuses to proceed (a 0-byte push is a known flake).
#   agent_restart_ps [pre] [post] -> the PowerShell text that runs the pushed helper, with the
#                                 caller's preamble before it (e.g. the registry writes the agent
#                                 reads at Init) and epilogue after it (e.g. a readback echo). Feed
#                                 it to the harness's own psrun so the toggle stays ONE round trip.
#   agent_restart_grade <out>     rc 0 when the helper proved the turnover (RESTART ok ...);
#                                 rc 1 when it reported RESTART INVALID-INSTRUMENT; rc 2 when no
#                                 RESTART line came back at all (missing data). Prints the reason.
#   agent_restart_run [pre] [post] convenience: push once (cached), run, print the helper's lines.
#   ctl_start <exe> [args]        start a control process (notepad, chromerepro) and print
#                                 "CTL <pid> <start-filetime>" - the identity this harness owns.
#                                 rc 1 and "CTL EXITED"/"CTL NONE" when nothing of ours is alive.
#   ctl_stop <pid> <start>        stop EXACTLY that process: Stop-Process -Id, only if its start
#                                 time still matches (a reused pid is not ours). Prints
#                                 "CTLSTOP stopped|gone|not-ours|unknown". Never by name.
#   agent_lines_ps                -> PowerShell PRELUDE text: fills $agentlines with the RUNNING
#                                 agent's own lines and $agentpid with its pid. The log is one file
#                                 per DAY since 4.3.33 and every agent started that day appends to
#                                 it, so a count or a "last matching line" over the file reads the
#                                 earlier lifetimes too. Prepend it to any log query.
#   agent_screen                  -> "AGENTSCREEN <W>x<H> src=<line> pid=<n>": the screen size the
#                                 running agent BELIEVES (g_ScreenWidth), read from the last line
#                                 that wrote it - RESDRIFT, RESEXACT, RESAPPLIED(-MISMATCH),
#                                 NEVEREXIT, or A6CONFIGURE where a whole-desktop grant exists.
#                                 "AGENTSCREEN none pid=<n>" when its lines carry no such write.
#                                 NOT the A6CONFIGURE announce alone: a seamless agent never sends
#                                 it (ADR-windows s5), and two readers that did FAILED for two days.
#
# The helper's marker lines (guest/restart-gui-agent.ps1 header) are what callers grep:
#   SVCSTOP ... / OLDLOG ... / WDSTART <status> <err> / AGENTPID <pid> after <n>s / OLDALIVE <0|1>
#   NEWLOG ... / RESTART ok new=<pid> log=<name> | RESTART INVALID-INSTRUMENT <reason>

LC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_HELPER_PS1="${LC_HELPER_PS1:-guest/restart-gui-agent.ps1}"
# WHERE tools/qtest push LANDS FILES - ASKED, NOT GUESSED. This was
#   LC_INCOMING="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
# which hardcodes the profile `user` and this qube's hostname, and was computed at SOURCE time
# before the caller had even named a subject. On any guest whose account is not `user` - the German
# golden's is gerd-test - the file lands in the real profile while every command here looks in a
# path that does not exist, which reads exactly like "the push did not work". mgmt/CLAUDE.md records
# the same value being planted in a dotfile for months for the same reason. `qtest incoming` prints
# the path for THAT guest, so ask it, once per guest, and cache it.
LC_INCOMING=""          # resolved lazily by _lc_incoming; do not read directly
_lc_incoming(){
  local vm; vm="$(_lc_vm)"
  if [ -n "${QTEST_INCOMING:-}" ]; then printf '%s' "$QTEST_INCOMING"; return 0; fi
  if [ -z "${LC_INCOMING:-}" ]; then
    LC_INCOMING=$(QTEST_VM="$vm" timeout 90 "${QTEST_BIN:-./tools/qtest}" incoming 2>/dev/null \
                    | tr -d '\r' | command grep -aE '^[A-Za-z]:\\' | tail -1)
  fi
  # No fallback guess. A wrong path here is the failure this comment is about, and an empty answer
  # makes the sha read below come back 'none', which the caller already reports as a refusal.
  printf '%s' "${LC_INCOMING:-}"
}
_lc_helper_guest(){ printf '%s\\%s' "$(_lc_incoming)" "$(basename "$LC_HELPER_PS1")"; }
LC_PUSHED=""

_lc_vm(){ printf '%s' "${QTEST_VM:-${VM:-}}"; }
_lc_require_vm(){
  [ -n "$(_lc_vm)" ] || { echo "FATAL lifecycle-lib.sh: neither QTEST_VM nor VM names the subject" >&2; return 2; }
}
# ONE guest round trip. The timeout is the caller's T (the harness convention), default 120 s.
_lc_qtest(){ _lc_require_vm || return 2
  QTEST_VM="$(_lc_vm)" timeout -k 8 "${T:-120}" "${QTEST_BIN:-./tools/qtest}" "$@" 2>/dev/null | tr -d '\r'; }
# PowerShell through -EncodedCommand (rule 16: nested quotes are re-split at every hop and fail silently).
_lc_ps(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  _lc_qtest run "cmd /c powershell -NoProfile -EncodedCommand $b"; }

agent_restart_push(){
  [ -f "$LC_HELPER_PS1" ] || { echo "FATAL lifecycle-lib.sh: $LC_HELPER_PS1 is not in the repo" >&2; return 1; }
  local want have
  want=$(sha256sum "$LC_HELPER_PS1" | cut -d' ' -f1)
  # RETRY, AND KEEP THE REASON. Measured 2026-10-09 in the gate's own run: gate-preflight started
  # 0 s after the rig harness confirmed "win11-acc answers qrexec" and this FATALed 14 s later with
  # guest sha 'none'. A hand push of the same file to the same guest a moment later landed with an
  # exact sha match - so the file copy was not broken, it was EARLY. qrexec answers as SYSTEM within
  # a minute of boot; a file copy needs the receiver in a LOGGED-ON session, which is later. A
  # single attempt turns that gap into an INVALID-INSTRUMENT verdict for the whole suite.
  # The push's own output was also discarded, which is why the reason never appeared.
  local tries="${LC_PUSH_TRIES:-6}" out i
  for i in $(seq 1 "$tries"); do
    out=$(_lc_qtest push "$LC_HELPER_PS1" 2>&1)
    have=$(_lc_ps "Write-Output ('HELPERSHA ' + (Get-FileHash -LiteralPath '$(_lc_helper_guest)' -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash)" \
           | grep -aoE 'HELPERSHA [0-9A-Fa-f]{64}' | awk '{print tolower($2)}' | head -1)
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
      [ "$i" -gt 1 ] && echo "lifecycle-lib.sh: the restart helper landed on attempt $i/$tries (the file receiver needs a logged-on session, which qrexec does not prove)" >&2
      LC_PUSHED=yes; return 0
    fi
    [ "$i" -lt "$tries" ] && sleep 10
  done
  [ -n "${out:-}" ] && echo "lifecycle-lib.sh: the last push said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" >&2
  echo "lifecycle-lib.sh: the restart helper on the guest is NOT the repo copy after $tries attempt(s) (guest sha256 '${have:-none}', repo $want) - refusing to restart the agent through an unproven helper" >&2
  LC_PUSHED=""; return 1
}

agent_restart_ps(){  # [preamble] [epilogue] -> PowerShell text
  printf '%s\n' "${1:-}"
  # THE EXECUTION POLICY BLOCKS A .ps1 FILE, AND THIS IS THE ONLY SITE IN THE REPO THAT FORGOT IT.
  # This line was `& '<path>' -TimeoutSec N`. Measured on win11-acc 2026-10-09, with the helper
  # pushed and its sha PROVEN equal to the repo copy:
  #   & : File ...\restart-gui-agent.ps1 cannot be loaded because running scripts is disabled
  #       on this system. ... PSSecurityException / UnauthorizedAccess
  # The guest's effective policy is Restricted with every scope Undefined - the Windows default, not
  # a misconfigured guest - and an -EncodedCommand payload is exempt while invoking a FILE is not.
  # So the preamble and the epilogue both ran, the helper did not, and the harness saw a round-tripped
  # GATEOFF with no SVCSTOP/WDSTART/AGENTPID/NEWLOG/RESTART at all. gate-preflight read that missing
  # WDSTART as "QubesGuiWatchdog not Running after Start-Service" and graded the guest
  # INVALID-INSTRUMENT - a blocked file invocation reported as a broken service.
  # Every other .ps1-file invocation in this repo already passes -ExecutionPolicy Bypass (20+ call
  # sites, e.g. guest/install-updater-agent.ps1:436, guest/pvnic-selfprime.ps1:1194); a child process
  # is also what keeps the helper's own `exit` from truncating the epilogue.
  # AGENT_RESTART_WAIT_SERVING (seconds, default 0 = today's behaviour) asks the helper to wait for
  # the restarted agent to reach serving=connected, not merely alive. Only a caller that goes on to
  # grade WINDOWS needs it - failproof-gates aborted a whole 89-minute run in 63 seconds because its
  # baseline suite ran against an agent still 'awaiting' a vchan client and produced no verdicts.
  printf 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %s -TimeoutSec %s -WaitServing %s\n' \
    "'$(_lc_helper_guest)'" "${AGENT_RESTART_TIMEOUT:-45}" "${AGENT_RESTART_WAIT_SERVING:-0}"
  printf '%s\n' "${2:-}"
}

agent_restart_grade(){  # <helper output> -> rc 0 ok / 1 invalid / 2 missing; prints the reason
  local line
  line=$(printf '%s\n' "$1" | grep -a '^RESTART ' | tail -1)
  case "$line" in
    "RESTART ok"*)   printf '%s\n' "${line#RESTART }"; return 0 ;;
    "RESTART INVALID-INSTRUMENT"*) printf '%s\n' "${line#RESTART INVALID-INSTRUMENT }"; return 1 ;;
    *) printf '%s\n' "no RESTART line from the guest (the helper did not run to its verdict: pushed? qrexec alive?)"; return 2 ;;
  esac
}

agent_restart_run(){  # [preamble] [epilogue]
  if [ -z "$LC_PUSHED" ]; then agent_restart_push || return 2; fi
  _lc_ps "$(agent_restart_ps "${1:-}" "${2:-}")"
}

# ---- control processes the harness itself starts (notepad, chromerepro). The identity is the
# pid AND the start time, read from the handle Start-Process -PassThru returned - the same shape
# the shipped updater uses for its relay (guest/qubes-windows-update.ps1 Start-Relay/Stop-OwnRelay).
ctl_start(){  # <exe> [args...] -> "CTL <pid> <start>" ; rc 1 when nothing of ours stayed alive
  local exe="$1"; shift
  local args="" a
  for a in "$@"; do args="$args,'$a'"; done
  local al=""; [ -n "$args" ] && al=" -ArgumentList @(${args#,})"
  local out
  out=$(_lc_ps "\$p = Start-Process -FilePath '$exe'$al -PassThru -ErrorAction SilentlyContinue
if (-not \$p) { Write-Output 'CTL NONE'; exit 1 }
Start-Sleep -Milliseconds 700
if (\$p.HasExited) { Write-Output 'CTL EXITED' ; exit 1 }
Write-Output ('CTL ' + \$p.Id + ' ' + \$p.StartTime.ToFileTimeUtc())" | grep -a '^CTL ' | head -1)
  printf '%s\n' "${out:-CTL NONE}"
  case "$out" in "CTL "[0-9]*) return 0 ;; *) return 1 ;; esac
}

ctl_stop(){  # <pid> <start-filetime> -> "CTLSTOP stopped|gone|not-ours|unknown"
  local pid="${1:-0}" start="${2:-0}"
  case "$pid" in ''|*[!0-9]*|0) printf 'CTLSTOP unknown no-pid\n'; return 1 ;; esac
  local out
  out=$(_lc_ps "\$p = Get-Process -Id $pid -ErrorAction SilentlyContinue
if (-not \$p) { Write-Output 'CTLSTOP gone'; exit 0 }
\$st = 0; try { \$st = \$p.StartTime.ToFileTimeUtc() } catch { }
if ('$start' -ne '0' -and \"\$st\" -ne '$start') { Write-Output ('CTLSTOP not-ours pid $pid start ' + \$st); exit 0 }
Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
[void]\$p.WaitForExit(5000)
Write-Output ('CTLSTOP ' + \$(if (\$p.HasExited) { 'stopped' } else { 'STILL-RUNNING' }))" | grep -a '^CTLSTOP ' | head -1)
  out="${out:-CTLSTOP unknown no-answer}"
  printf '%s\n' "$out"
  # EACH OUTCOME GETS ITS OWN EXIT CODE, because the line alone was the whole result and every
  # caller just logged it. Found by the descending audit, 2026-10-21: the function's last command
  # was the printf, so "not-ours" and "STILL-RUNNING" returned 0 - the same code as a confirmed
  # stop - and matrix.sh's call site (`say "  notepad: $(... ctl_stop ...)"`) only printed the
  # string. A control window that failed to close therefore stayed on the guest desktop to be
  # counted by a later window-map grading step in the SAME cell, falsifying that cell's verdict.
  # WHAT ENFORCES THIS NOW (2026-10-28). ctl-stop-rc-selftest.sh asserted the mapping AND that
  # matrix.sh branched on it; it was deleted when the window check moved into window-grade-lib.sh,
  # because it was anchored on the literal `_ctl_rc=$?` and went red on a caller that still
  # branches - and it only ever inspected matrix.sh, one of thirteen ctl_stop call sites. For the
  # window check the property is now structural: grade_mapped_window ALWAYS sets WG_CTLSTOP_RC and
  # its three callers (matrix.sh, quick-upgrade.sh, stability-e2e.sh) each branch on it. The other
  # call sites below are NOT covered by anything - p5-run.sh, rnd-shell-surfaces.sh, sg6-failproof.sh,
  # promoted-checks.sh, rnd8-resolution.sh and sg1-u2-coldboot.sh still only PRINT this result.
  case "$out" in
    *'CTLSTOP stopped'*)       return 0 ;;   # it exited
    *'CTLSTOP gone'*)          return 0 ;;   # already gone, which is what a stop wanted
    *'CTLSTOP not-ours'*)      return 3 ;;   # that pid is a DIFFERENT process now - ours may live
    *'CTLSTOP STILL-RUNNING'*) return 4 ;;   # stop sent, still alive after 5 s
    *)                         return 2 ;;   # no answer / no pid: instrument failure, not a stop
  esac
  # CTL-STOP-RC-B
}

# ---- the running agent's own log lines, and the screen size it believes -----------------------------
# WHY A PRELUDE AND NOT A GREP. The agent log became one file per day in 4.3.33 and every agent
# started that day appends to it (2026-11-01 on win11-acc: pids 8176, 4388 and 7416 in one file). A
# query over the whole file therefore counts the lifetimes before this one - RND-8's DIED counter
# scored the orderly shutdown lines of two EARLIER agents ("capture thread still in its acquire at
# exit; the exit ends it", "window event thread exiting on request - the agent is leaving") as four
# thread deaths of the running one - and a "last matching line" may be theirs. The running agent is
# the one that wrote the file's last line; its lines are selected by pid, and when its process
# started before today the earlier daily files back to its start date are read as well, so a
# lifetime that crosses midnight is not cut in half. findings/misc.md: a pattern match in a module
# log must be bounded to the run it judges. Nothing here finds a process by name: the pid comes from
# the log and Get-Process -Id only dates it.
agent_lines_ps(){ cat <<'PS'
$ErrorActionPreference='Continue'
$agentlines=@(); $agentpid=''
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$fs=@(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($fs.Count -gt 0){
  # -ReadCount 0 hands back ONE object, the whole string[]; wrapped in @() it nests as a single element
  # (measured 2026-11-01 on a 79 KB log: lines=1, no pid found). A typed variable keeps it a string[].
  [string[]]$new = Get-Content $fs[0].FullName -ReadCount 0 -EA SilentlyContinue
  for($i=$new.Count-1; $i -ge 0; $i--){ if($new[$i] -match '^\[\d{8}\.\d{6}\.\d{3}-(\d+):'){ $agentpid=$Matches[1]; break } }
  $since=$null; if($agentpid){ try{ $since=(Get-Process -Id ([int]$agentpid) -EA Stop).StartTime.Date }catch{} }
  $pick=@($fs[0])
  if($since -and $fs.Count -gt 1){
    foreach($f in $fs[1..($fs.Count-1)]){
      if($f.Name -match '^gui-agent-(\d{8})\.log$'){ try{ if([datetime]::ParseExact($Matches[1],'yyyyMMdd',$null) -ge $since){ $pick += $f } }catch{} }
    }
  }
  $re='^\[\d{8}\.\d{6}\.\d{3}-' + $agentpid + ':'
  foreach($f in ($pick | Sort-Object LastWriteTime)){
    [string[]]$c = if($f.FullName -eq $fs[0].FullName){ $new } else { Get-Content $f.FullName -ReadCount 0 -EA SilentlyContinue }
    $agentlines += @($c | Where-Object { $_ -match $re })
  }
}
PS
}

# The last line that WROTE g_ScreenWidth, scanned backwards so the scan stops at the first hit. The
# writers and what each logs (agent/gui-agent/resolution.c, vchan-handlers.c, main.c), every one of
# them the ADOPTED size - after a mismatch, width/height already hold the applied mode when RESEXACT
# and the legacy path log and assign:
#   RESDRIFT believed=AxB actual=WxH - adopting the actual mode              -> WxH   resolution.c:1513
#   RESAPPLIED-MISMATCH applied=WxH expected=AxB - adopting the applied size -> WxH   :1892, :2066
#   RESEXACT WxH replug=N                                                             :1913
#   RESAPPLIED WxH                     (the readback the legacy path adopts)           :2063
#   NEVEREXIT adopted WxH as the current screen size                                  vchan-handlers.c:258
#   A6CONFIGURE window 0 -> WxH        (the announce; only under a whole-desktop grant) main.c:15828
_lc_agent_screen_ps(){ cat <<'PS'
$pats=@(
  @{t='RESDRIFT';            r='RESDRIFT believed=\d+x\d+ actual=(\d+x\d+)'},
  @{t='RESAPPLIED-MISMATCH'; r='RESAPPLIED-MISMATCH applied=(\d+x\d+)'},
  @{t='RESEXACT';            r='RESEXACT (\d+x\d+) replug='},
  @{t='RESAPPLIED';          r='RESAPPLIED (\d+x\d+)'},
  @{t='NEVEREXIT';           r='NEVEREXIT adopted (\d+x\d+) as the current screen size'},
  @{t='A6CONFIGURE';         r='A6CONFIGURE window 0 -> (\d+x\d+)'})
$hit=$null
for($i=$agentlines.Count-1; $i -ge 0 -and -not $hit; $i--){
  foreach($p in $pats){ if($agentlines[$i] -match $p.r){ $hit=@{t=$p.t; v=$Matches[1]}; break } }
}
if($hit){ Write-Output ('AGENTSCREEN ' + $hit.v + ' src=' + $hit.t + ' pid=' + $agentpid) }
else { Write-Output ('AGENTSCREEN none pid=' + $agentpid) }
PS
}
agent_screen(){
  _lc_ps "$(agent_lines_ps)
$(_lc_agent_screen_ps)" | grep -ao 'AGENTSCREEN .*' | head -1
}

# ---- the DEBUG precondition: the feature that writes the agent's debug lines, and the proof -------
# WHY THIS IS A SHARED PAIR AND NOT A COMMENT IN EACH SUITE. Several harnesses grade on lines the
# agent writes ONLY at DEBUG, and each one established that precondition its own way or not at all:
# failproof-faultinject.sh set service.gui-agent-debug and restored it (for QGAPERF seq lines),
# crop-before-map.sh and vchan-collapse-debug-cell.sh write the registry LogLevel and reboot, and
# failproof-gates.sh did NEITHER - its SG4/SG2 discriminators are the agent's two fullscreen deny
# lines (main.c:9611 "boot/shutdown/logon-phase fullscreen" and :9636 "borderless fullscreen ...
# hidden (set service.gui-fullscreen to allow)", both LogDebug), so against a guest at the shipped
# LogLevel 3 the baseline agent wrote ZERO D lines, both cells graded INVALID-VACUOUS, and SG3 -
# whose product fix HAD landed - was never reached, because failproof-gates.sh aborts when any of
# the four is not green at baseline (measured 2026-11-01 on win11-acc, agent pid 3716).
# tools/tests/log-policy-selftest.sh:317 polices this class by grepping for the COMMENT "NEEDS
# LogLevel", so a suite that declares nothing is not failed by it - merely absent from its list. An
# absence must be ENFORCED, not declared, which is what these two functions are for.
# perf.c:341 reads /qubes-service/gui-agent-debug at Init and raises the level for the whole
# process, so the value takes AT THE NEXT AGENT START: hold it BEFORE the restart that precedes the
# graded run, never after. qvm-features on a win-idd-testbed qube is pre-authorised (CLAUDE.md, Rig).
# CALL agent_debug_hold AT TOP LEVEL - never inside $( ), a pipeline, or any other subshell. It
# installs an EXIT trap and remembers the subject's previous value in shell state, and a subshell
# throws BOTH away while the qvm-features write still lands on dom0: the guest would be left with
# service.gui-agent-debug=1 and nothing to put it back. Read its one printf line from stdout, or the
# globals it sets, rather than capturing it.
agent_debug_hold(){  # <vm> - hold service.gui-agent-debug=1 for this script; the old value goes back at EXIT
  _LC_DEBUG_VM="${1:-$(_lc_vm)}"
  [ -n "$_LC_DEBUG_VM" ] || { echo "ERROR agent_debug_hold: no VM (pass one, or set QTEST_VM/VM)" >&2; return 2; }
  _LC_DEBUG_WAS=$(qvm-features "$_LC_DEBUG_VM" service.gui-agent-debug 2>/dev/null || true)
  # CHAINED, NEVER REPLACED, AND INSTALLED AS ONE STATEMENT. Bash keeps a single EXIT trap, so a
  # bare `trap agent_debug_restore EXIT` here would silently drop whatever the caller installed -
  # p5-run.sh's _p5_exit removes its tempdir AND re-enables the update scan it disarmed - which is
  # the defect tools/lint-harness.py L21 was written for. ${x:+...} keeps this ONE armed trap
  # instead of an if/else pair; L21 counts armed `trap ... EXIT` statements, and a second one here
  # would be a real finding rather than a formatting accident.
  _LC_DEBUG_PREV_TRAP=$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")
  trap "${_LC_DEBUG_PREV_TRAP:+$_LC_DEBUG_PREV_TRAP; }agent_debug_restore" EXIT
  [ "$_LC_DEBUG_WAS" = 1 ] || qvm-features "$_LC_DEBUG_VM" service.gui-agent-debug 1 || return 1
  printf 'AGENTDEBUGFEATURE was=%s now=%s\n' "${_LC_DEBUG_WAS:-unset}" \
    "$(qvm-features "$_LC_DEBUG_VM" service.gui-agent-debug 2>/dev/null || true)"
}

agent_debug_restore(){  # back to EXACTLY what it was, including ABSENT - a left-behind 1 is a changed subject
  [ -n "${_LC_DEBUG_VM:-}" ] || return 0
  if [ -n "${_LC_DEBUG_WAS:-}" ]
  then qvm-features "$_LC_DEBUG_VM" service.gui-agent-debug "$_LC_DEBUG_WAS" >/dev/null 2>&1
  else qvm-features --unset "$_LC_DEBUG_VM" service.gui-agent-debug >/dev/null 2>&1
  fi
}

# THE PROOF THAT THE HOLD TOOK, read from the agent that is about to be GRADED - never from the
# feature value, which says only what dom0 asked for. tools/log-sweep.py:257 is the authority on the
# line shape: [YYYYMMDD.HHMMSS.mmm-<pid>[:<tid>]-<LEVEL>] with LEVEL in [IWEDV]. agent_lines_ps has
# already bounded $agentlines to the RUNNING pid, so a PREVIOUS agent's debug lines - these suites
# restart the agent on every toggle, and 4.3.33 made the log one file per day - cannot satisfy the
# current one's precondition.
_lc_agent_debug_ps(){ cat <<'PS'
$dbg=0
foreach($l in $agentlines){ if($l -match '^\[\d{8}\.\d{6}\.\d{3}-\d+(:\d+)?-D\]'){ $dbg++ } }
Write-Output ('AGENTDEBUG ' + $dbg + ' of ' + $agentlines.Count + ' pid=' + $agentpid)
PS
}
agent_debug_lines(){
  _lc_ps "$(agent_lines_ps)
$(_lc_agent_debug_ps)" | grep -ao 'AGENTDEBUG .*' | head -1
}
