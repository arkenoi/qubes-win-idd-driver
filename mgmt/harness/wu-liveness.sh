#!/bin/bash
# wu-liveness.sh - PASS LIVENESS for a harness that drives a Windows update pass. Source it; it uses tools/qtest, so QTEST_VM
# must name the guest.
#
# WHY. findings/issues.md P1 "A KILLED UPDATE PASS COSTS dom0 TWO SILENT HOURS": on 2026-09-17 a pass on the German 25H2
# template was ended 90 s in (task result 0x41306), and the harness watching it checked qrexec liveness and a 2 h stage bound -
# so a dead pass looked exactly like a slow one for two hours. The product's handler now reports a dead pass itself
# (guest/wu-update.ps1, GUARD:deadpass), but a harness must not depend on the product's own detector to notice that the product
# failed (Jev 2026-10-02, 0.70). So this reads the guest directly - the update task's state and update-status.json - and never
# the handler's output.
#
# NO PROCESS LIST. The probe reads the task through the Schedule.Service COM object (RPC to the scheduler; numeric state, no
# localized text) and the status file, and asks the TCP stack whether anything listens on 127.0.0.1:8082. It never enumerates
# processes: a process list is NtQuerySystemInformation -> ExpGetProcessInformation -> KeFlushProcessWriteBuffers, the IPI
# broadcast the 2026-10-02 SPIN specimen was found waiting in (findings/wedge.md), and a harness probe must not add one per poll.
#
#   wu_probe             one 'WUPROBE|task=..|last=..|status=..|action=..|phase=..|ts=..|relay=..|gt=..' line on stdout, or
#                        nothing when three attempts got no answer (missing data - never a state)
#   wu_pass_unfinished <line>  the picture NOW, no hold: 0 = not running and not finished, 1 = running/finished, 2 = unread.
#                        For a check made after nothing is waiting on the pass any more (its replay has ended).
#   wu_pass_dead <line>  exit 0, the reason in WU_LIVE_WHY, once a dead pass has HELD for WU_LIVE_HOLD_S seconds (default 90)
#                        under one unchanged signature; exit 1 otherwise. It keeps state in globals, so call it directly - never
#                        inside $(...), where every update would be lost with the subshell. Feed it every probe in order;
#                        wu_live_reset between passes.
#
# DEAD means: the task is readable and neither Running nor Queued, AND update-status.json is absent, or belongs to a pass
# (action is not 'scan') whose phase is not one the writer ends a pass with (done, error, scan-failed, skipped-*) - and that
# exact picture has not changed for the hold. A scan's status written over an unfinished pass does not hide it: the pass's own
# last picture is judged. A probe that could not read the task or the status says nothing either way: it neither advances nor
# resets the hold.
# Offline self-test: tools/tests/wu-liveness-selftest.sh (WU_LIVE_DEFECT=1 makes the verdict unreachable; the test must FAIL).

WU_LIVE_HOLD_S="${WU_LIVE_HOLD_S:-90}"

# The probe, as the guest runs it. -EncodedCommand (UTF-16LE base64) so no quoting survives cmd.exe's parser to bite us.
read -r -d '' WU_PROBE_PS <<'PS' || true   # read returns 1 at the heredoc's end (no NUL): not an error
$ErrorActionPreference = 'SilentlyContinue'
$st = 'UNREADABLE'; $lr = ''
try {
  $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
  $tk = $svc.GetFolder('\').GetTask('QubesWindowsUpdateRun')
  $st = @('Unknown', 'Disabled', 'Queued', 'Ready', 'Running')[[int]$tk.State]
  $lr = '0x{0:X}' -f ([int64]$tk.LastTaskResult -band 0xFFFFFFFF)
} catch { $st = 'UNREADABLE' }
$f = 'C:\ProgramData\Qubes\update-status.json'
$kind = 'absent'; $s = $null
if (Test-Path -LiteralPath $f) {
  $raw = $null
  # shared for write AND delete: the writer replaces the file by temp + Move-Item (guest/qubes-windows-update.ps1 Save), and a
  # reader holding it without FILE_SHARE_DELETE makes that replace fail - a probe must never cost the pass a status write
  try { $fs = [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try { $raw = (New-Object IO.StreamReader($fs, $true)).ReadToEnd() } finally { $fs.Dispose() } } catch { $raw = $null }
  if ($null -eq $raw) { $kind = 'unreadable' } else { try { $s = $raw | ConvertFrom-Json; $kind = 'ok' } catch { $kind = 'unparseable' } }
}
$ts = ''
if ($s -and $s.ts) { if ($s.ts -is [datetime]) { $ts = $s.ts.ToString('s') } else { $ts = "$($s.ts)" } }
$rl = 'none'
try {
  foreach ($e in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
    if ($e.Port -eq 8082 -and "$($e.Address)" -eq '127.0.0.1') { $rl = 'listening' }
  }
} catch { $rl = 'unknown' }
'WUPROBE|task=' + $st + '|last=' + $lr + '|status=' + $kind + '|action=' + $s.action + '|phase=' + $s.phase + '|ts=' + $ts + '|relay=' + $rl + '|gt=' + (Get-Date).ToString('s')
PS
WU_PROBE_B64=$(printf '%s' "$WU_PROBE_PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

wu_probe(){ local i out
  for i in 1 2 3; do
    out=$(timeout -k 5 60 tools/qtest run "powershell -NoProfile -NonInteractive -EncodedCommand $WU_PROBE_B64" 2>/dev/null \
          | tr -d '\r' | grep -a '^WUPROBE|' | tail -1)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    [ "$i" -lt 3 ] && sleep 3
  done
  return 1; }

wu_field(){ printf '%s\n' "$1" | tr '|' '\n' | sed -n "s/^$2=//p" | head -1; }

# Stop a host-side job and everything under it (python, and the qrexec-client-vm it spawned - which would otherwise sit out the
# guest handler's own bound holding a qrexec connection). Children first, so none is re-parented and missed.
wu_killtree(){ local c; for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do wu_killtree "$c"; done; kill -TERM "$1" 2>/dev/null; }

wu_live_hold_reset(){ WU_LIVE_SIG=''; WU_LIVE_SINCE=0; }
wu_live_reset(){ wu_live_hold_reset; WU_LIVE_PASS=''; WU_LIVE_WHY=''; }
wu_live_reset

wu_terminal(){ case "$1" in done|error|scan-failed|skipped-*) return 0 ;; esac; return 1; }

# wu_pass_unfinished <line>: the picture NOW, no hold. 0 = a pass that is not running and did not finish (WU_LIVE_PIC holds
# task|kind|action|phase|ts); 1 = running, queued or finished; 2 = no verdict (the task or the status could not be read).
wu_pass_unfinished(){ local l="$1" task kind act ph ts
  WU_LIVE_PIC=''
  [ "${WU_LIVE_DEFECT:-}" = 1 ] && return 1   # GUARD:wu-liveness - the self-test's seen-to-fail switch ("never unfinished")
  [ -n "$l" ] || return 2
  task=$(wu_field "$l" task); kind=$(wu_field "$l" status)
  act=$(wu_field "$l" action); ph=$(wu_field "$l" phase); ts=$(wu_field "$l" ts)
  # the newest picture of the PASS itself - a scan's status is not the pass's
  if [ "$kind" = ok ] && [ "$act" != scan ]; then WU_LIVE_PASS="$act|$ph|$ts"; fi
  case "$task" in
    Running|Queued) return 1 ;;
    Ready|Disabled) : ;;
    *) return 2 ;;                                  # UNREADABLE / Unknown / empty
  esac
  case "$kind" in
    ok)
      if [ "$act" = scan ]; then
        # A SCAN'S STATUS OVER A PASS THAT STOPPED WRITING (Jev 2026-10-02, the likeliest miss, 0.47): the scheduled scan can run
        # as soon as a dead pass has released the updater's mutex, and its status replaces the pass's. If the last picture of
        # this pass was unfinished, it is still the dead one: judge ITS picture, never the scan's.
        [ -n "$WU_LIVE_PASS" ] || return 1
        act=${WU_LIVE_PASS%%|*}; ph=${WU_LIVE_PASS#*|}; ts=${ph#*|}; ph=${ph%%|*}
      fi
      wu_terminal "$ph" && return 1 ;;
    absent) : ;;
    *) return 2 ;;                                  # unreadable / unparseable / empty
  esac
  WU_LIVE_PIC="$task|$kind|$act|$ph|$ts"
  return 0; }

wu_pass_dead(){ local l="$1" rc now task ph ts kind
  [ "${WU_LIVE_DEFECT:-}" = 1 ] && return 1   # GUARD:wu-liveness - the self-test's seen-to-fail switch
  wu_pass_unfinished "$l"; rc=$?
  [ "$rc" = 1 ] && { wu_live_hold_reset; return 1; }
  [ "$rc" = 2 ] && return 1                       # missing data neither advances nor resets the hold
  now=${WU_LIVE_NOW:-$(date +%s)}                 # WU_LIVE_NOW: the self-test's clock
  if [ "$WU_LIVE_PIC" != "$WU_LIVE_SIG" ]; then WU_LIVE_SIG=$WU_LIVE_PIC; WU_LIVE_SINCE=$now; return 1; fi
  [ $((now - WU_LIVE_SINCE)) -ge "$WU_LIVE_HOLD_S" ] || return 1
  task=${WU_LIVE_PIC%%|*}; kind=$(printf '%s' "$WU_LIVE_PIC" | cut -d'|' -f2)
  ph=$(printf '%s' "$WU_LIVE_PIC" | cut -d'|' -f4); ts=$(printf '%s' "$WU_LIVE_PIC" | cut -d'|' -f5)
  if [ "$kind" = absent ]; then
    WU_LIVE_WHY="the update task is $task (last result $(wu_field "$l" last)) and no update-status.json has existed for $((now - WU_LIVE_SINCE)) s - a pass that never wrote"
  else
    WU_LIVE_WHY="the update task is $task (last result $(wu_field "$l" last)) while the pass's status has stood at phase '$ph' (ts $ts) for $((now - WU_LIVE_SINCE)) s - a pass that stopped writing$( [ "$(wu_field "$l" action)" = scan ] && echo ' (a scan has since written over it)')"
  fi
  return 0; }
