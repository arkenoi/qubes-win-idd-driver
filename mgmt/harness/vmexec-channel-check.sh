#!/bin/bash
# vmexec-channel-check.sh - does a call over qubes.VMExec actually DELIVER stdout and stderr?
#
#   mgmt/harness/vmexec-channel-check.sh <vm> [logfn]
#
# WHY THIS EXISTS. The release goal is: "qrexec behavior is aligned with dom0 callers: updaters and
# start menu, from cold qube as well". dom0 drives the Windows update agent over `qubes.VMExec`,
# takes stdout as the agent's log, parses bare floats on STDERR for the Qubes Update GUI's progress
# bar, and cats the agent log as its final step. On 2026-10-14 a 4.3.36 guest ran the command,
# returned its exit code, and delivered NO stdout and NO stderr: `cmd /c echo X > file & echo Y`
# came back rc=0 with empty stdout while the FILE held X (VMEXECNOSTDOUT). Cause: DETACHED_PROCESS
# gave the child's grandchild a fresh console, which overrides inherited std handles; reverted to
# CREATE_NO_WINDOW in core-agent.
#
# AND NOTHING IN THE ACCEPTANCE GATE COULD SEE IT. Grepping the matrix, the protocol and its runner
# for a stdout assertion on this service returns nothing: the gate graded installs while the channel
# the goal names went unmeasured. `qtest run` cannot stand in for it - that is `qubes.VMShell` on the
# SYSTEM path, which kept working throughout and is exactly why the defect survived so long.
#
# THE SERVICE ARGUMENT IS ENCODED, per the shipped guest-side decoder
# (rpc/qubes-rpc-services/VMExec-Decode.ps1): each argv element escapes every character outside
# [a-zA-Z0-9._] as -HH (uppercase hex), a literal '-' as '--', and the elements are joined with '+'.
# tools/tests/vmexec-channel-selftest.sh round-trips this encoder through that very PowerShell
# decoder, so the wire format is proven against the code that reads it rather than against my
# reading of it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

COLD=0
[ "${1:-}" = "--cold" ] && { COLD=1; shift; }
VM="${1:?usage: $0 [--cold] <vm> [logfn]}"
LG="${2:-echo}"
# A FUNCTION NAME IS NOT A COMMAND IN A CHILD PROCESS, and this cost two evidence files their
# contents. matrix.sh calls these checks with its own `say` as the log function - `say` is a shell
# FUNCTION, not exported, so in a child `bash script.sh` every log call died with
# "say: command not found". In vmexec-channel-check.sh that was SILENT: its verdict comes from
# $rc_all, computed independently, so it reported PASS while its evidence file contained nothing but
# those errors - in every campaign run since it was written. In dom0-callers-check.sh it was worse:
# the cell FAILED and the reason was unreadable. So the log target is validated here rather than
# trusted, and a caller that passes something unrunnable gets stdout instead of silence.
if ! command -v "$LG" >/dev/null 2>&1; then
  echo "  (log target '$LG' is not a command here - a shell function does not cross into a child process; using echo)"
  LG=echo
fi

# One argv element -> the escaped form the guest decoder expects.
vmexec_encode_arg(){ python3 -c '
import sys
out = []
for ch in sys.argv[1]:
    if ch.isascii() and (ch.isalnum() or ch in "._"):
        out.append(ch)
    elif ch == "-":
        out.append("--")
    else:
        out.append("-%02X" % ord(ch))
print("".join(out))' "$1"; }

# argv -> the full service name.
vmexec_service(){ local part acc=""; for part in "$@"; do acc="$acc+$(vmexec_encode_arg "$part")"; done; printf 'qubes.VMExec%s' "$acc"; }

# Run one argv over qubes.VMExec, capturing the two streams SEPARATELY - the whole point is which
# of them arrives.
vmexec_run(){ # <outfile> <errfile> <argv...>
  local out="$1" err="$2"; shift 2
  local svc; svc=$(vmexec_service "$@")
  timeout -k 5 120 qrexec-client-vm "$VM" "$svc" </dev/null >"$out" 2>"$err"
}

MARK="VMEXECMARK$$"
T=$(mktemp -d "${TMPDIR:-/tmp}/vmexec-chan.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
rc_all=0

# ---- THE COLD CLAUSE FOR THE UPDATER CALLER ---------------------------------------------------
# The goal is "updaters and start menu, from COLD qube as well". dom0-callers-check.sh covers the
# start menu cold (matrix.sh:2411); this service - the one dom0 drives the Windows update agent
# over - was only ever called warm (matrix.sh:960), so the updater half of that clause had no
# instrument at all.
#
# THE COLD CALL IS THE GRANDCHILD SHAPE, NOT THE SIMPLE ONE. Only the FIRST call to a Halted qube
# is cold - after it the qube is Running and everything else is warm, whatever it is labelled. So
# the one cold call has to be the shape that matters, and that is `cmd /c cmd /c echo` : the updater
# is powershell under cmd, two processes deep, and a fresh console given to the GRANDCHILD is the
# measured cause of VMEXECNOSTDOUT. Checks 1-4 below then run warm against the qube this call
# started, and the log says so rather than implying four cold calls.
#
# The precondition is a REFUSAL, not a warning: a cold check against an already-Running guest
# measures the warm path under a cold label, which has its own entry in this project's history.
if [ "$COLD" -eq 1 ]; then
  state=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
  [ "$state" = Halted ] || { $LG "  VMEXEC: [ERROR] --cold needs $VM Halted and it is '$state' - refusing to label a warm call cold"; exit 2; }
  # The bound comes from the qube, not from a number I liked: a cold call pays for the whole boot
  # before the service is reached, and dom0's own caller gives up at qrexec_timeout.
  qt_pref=$(qvm-prefs "$VM" qrexec_timeout 2>/dev/null)
  case "$qt_pref" in (*[!0-9]*|'') qt_pref=0 ;; esac
  bound=$(( qt_pref + 60 )); [ "$bound" -lt 180 ] && bound=180
  svc=$(vmexec_service cmd.exe /c "cmd /c echo $MARK")
  t0=$(date +%s)
  timeout -k 5 "$bound" qrexec-client-vm "$VM" "$svc" </dev/null >"$T/c0" 2>"$T/c0e"
  crc=$?
  elapsed=$(( $(date +%s) - t0 ))
  if command grep -qa "$MARK" "$T/c0"; then
    $LG "  VMEXEC: COLD grandchild stdout delivered ($(wc -c <"$T/c0") bytes in ${elapsed}s, rc=$crc)"
  elif [ "$crc" -ge 124 ]; then
    $LG "  VMEXEC: [ERROR] the COLD call did not finish inside ${bound}s (rc=$crc) - a HANG, not an empty stream; dom0's caller (qrexec_timeout=${qt_pref}s) had already given up"
    rc_all=1
  elif [ -s "$T/c0e" ]; then
    $LG "  VMEXEC: [ERROR] the COLD call returned no stdout and stderr says: $(tr -d '\r' <"$T/c0e" | head -2 | tr '\n' ' ') - a refusal or transport failure, not an empty stream"
    rc_all=1
  else
    $LG "  VMEXEC: [ERROR] the COLD call returned 0 bytes of stdout with a SILENT stderr (rc=$crc, ${elapsed}s) - dom0 would read the update agent's log as empty"
    rc_all=1
  fi
  # The call itself had to bring the qube up; if it is still Halted, something else answered.
  now=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
  if [ "$now" = Running ]; then
    $LG "  VMEXEC: the cold call started the qube (Halted -> $now)"
  else
    $LG "  VMEXEC: [ERROR] after a cold call $VM is '$now' - this stream did not come from a qube this call started"
    rc_all=1
  fi
  if [ "$qt_pref" -gt 0 ] && [ "$elapsed" -gt "$qt_pref" ]; then
    $LG "  VMEXEC: [ERROR] the cold call took ${elapsed}s against qrexec_timeout=${qt_pref}s - dom0's caller gives up first"
    rc_all=1
  elif [ "$qt_pref" -gt 0 ]; then
    $LG "  VMEXEC: cold answer in ${elapsed}s, inside qrexec_timeout=${qt_pref}s"
  fi
  $LG "  VMEXEC: checks 1-4 below run WARM, against the qube that cold call started"
fi

# 1. STDOUT. The marker is echoed by the child; if the channel is broken the call still succeeds
# and the file is empty, which is exactly how this defect hid.
vmexec_run "$T/o1" "$T/e1" cmd.exe /c "echo $MARK"; rc=$?
if command grep -qa "$MARK" "$T/o1"; then
  $LG "  VMEXEC: stdout delivered ($(wc -c <"$T/o1") bytes, rc=$rc)"
else
  $LG "  VMEXEC: [ERROR] stdout EMPTY with rc=$rc - dom0 takes this stream as the update agent's log (VMEXECNOSTDOUT)"
  rc_all=1
fi

# 2. STDERR, which dom0 parses for the progress bar. Separate call, so one broken stream cannot
# mask the other.
vmexec_run "$T/o2" "$T/e2" cmd.exe /c "echo $MARK 1>&2"; rc=$?
if command grep -qa "$MARK" "$T/e2"; then
  $LG "  VMEXEC: stderr delivered ($(wc -c <"$T/e2") bytes, rc=$rc)"
else
  $LG "  VMEXEC: [ERROR] stderr EMPTY with rc=$rc - the Qubes Update GUI reads bare floats on this stream, so a Windows qube shows no progress"
  rc_all=1
fi

# 3. THE EXIT CODE still has to be right, because that is the one channel that DID work and a fix
# must not trade one for another.
vmexec_run "$T/o3" "$T/e3" cmd.exe /c "exit 7"; rc=$?
if [ "$rc" -eq 7 ]; then
  $LG "  VMEXEC: exit code passed through (7)"
else
  $LG "  VMEXEC: [ERROR] exit code 7 came back as $rc"
  rc_all=1
fi

# 4. A GRANDCHILD, which is the shape that actually broke: the wrapper's child is always
# `cmd.exe /c <something>`, so the thing producing output is two processes deep. A fix that only
# works for a direct child would pass checks 1-3 and still lose the updater's output.
vmexec_run "$T/o4" "$T/e4" cmd.exe /c "cmd /c echo $MARK"; rc=$?
if command grep -qa "$MARK" "$T/o4"; then
  $LG "  VMEXEC: stdout delivered from a GRANDCHILD (the updater's shape), rc=$rc"
else
  $LG "  VMEXEC: [ERROR] a grandchild's stdout is LOST (rc=$rc) - this is the measured shape: the updater runs powershell under cmd"
  rc_all=1
fi

if [ "$rc_all" -eq 0 ]; then
  [ "$COLD" -eq 1 ] \
    && $LG "  VMEXEC: the updater caller is aligned on $VM - one COLD call in the updater's grandchild shape, then all four channels warm" \
    || $LG "  VMEXEC: all four channel checks passed on $VM"
  exit 0
fi
# IT HAS NOW BEEN SEEN TO WORK ON A GUEST, so it gates. Campaign run 9 (2026-10-15) reported
# `dom0 caller channel aligned (stdout, stderr, exit code, grandchild)` on win11-clean,
# win11-reinstall and win11-upgrade - three independent cells, all four channels arriving. That was
# the condition this check was written to wait for: until then a refusal by dom0's tag-based policy
# would have looked exactly like the defect it hunts (an empty stream), and an instrument that has
# never been seen to WORK must not decide a release.
# Before that run it had never executed AT ALL, because it was only called from the end-of-campaign
# collection loop and every cell halts its subject as its last act (CALLERCHECKATENDONLY). It is now
# called per cell, while the guest is up.
$LG "  VMEXEC: [ERROR] the dom0 caller channel is NOT aligned on $VM"
exit "$rc_all"
