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
  printf 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %s -TimeoutSec %s\n' \
    "'$(_lc_helper_guest)'" "${AGENT_RESTART_TIMEOUT:-45}"
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
  printf '%s\n' "${out:-CTLSTOP unknown no-answer}"
}
