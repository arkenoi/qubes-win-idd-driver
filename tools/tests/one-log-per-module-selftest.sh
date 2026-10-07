#!/usr/bin/env bash
# one-log-per-module-selftest.sh - patches/windows-utils-one-log-per-module.patch and the two
# consumers it forces to change, checked OFFLINE. No guest, no CI.
#
# WHAT IT GUARDS. windows-utils named every log file after the PROCESS that opened it, so one qrexec
# call made one log file: 386 files on a measured guest, 368 of them qrexec-wrapper-*.log, which
# starved the sweep's 60-file budget so it skipped qwt-deaths.log - the record the gate reads.
#
# THE FIX IS THREE THINGS THAT ONLY WORK TOGETHER:
#   1. one file per module per day - the date stays because PurgeOldLogs deletes by ftCreationTime,
#      so a dateless name would eventually have the retention sweep delete the LIVE log;
#   2. an append-only handle shared for writing - FILE_APPEND_DATA without FILE_WRITE_DATA is what
#      makes a write atomic against the other writers;
#   3. ONE WriteFile per line - three calls would let two processes interleave inside a line, which
#      is why an earlier append patch scored append_is_safe 0.37: it kept the three calls.
# Jev: sink 0.79 (conf 0.72), append_atomic_single_write 0.84, earlier_answer_superseded 0.72. The
# number that did NOT favour it is in docs/ADR-logging.md (meets_owner_constraints chose the event
# log, 0.61 at conf 0.48, because a bespoke logger survives this).
#
# Three defects were found in review and are guarded here: a BOM race, the pid being lost with the
# file name, and safe flush becoming a silent no-op on an append-only handle. Checks 9-11 cover the
# knock-ons: a shared file means no new file on restart and a previous instance's lines in it, so
# anything trusting a log's NAME or any matching line is now wrong.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-one-log-per-module.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${ONELOG_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/one-log-XXXXXX")}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$PATCHFILE" ] || { echo "FAIL  $PATCHFILE is missing - nothing ran (missing data fails)"; exit 2; }
[ -d "$MIRROR" ]    || { echo "FAIL  $MIRROR is missing"; exit 2; }

# ---- 1. the patch is written against the ref CI actually clones ---------------------------------
ref=$(command grep -oE 'WINDOWS_UTILS_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
mirror_ver=$(tr -d ' \r\n' < "$MIRROR/version" 2>/dev/null)
if [ -n "$ref" ] && [ -n "$mirror_ver" ] && [ "${ref#v}" = "${mirror_ver#v}" ]; then
  ok "ref_matches_mirror: written against $mirror_ver, which is WINDOWS_UTILS_REF ($ref)"
else
  bad "ref_matches_mirror: WINDOWS_UTILS_REF='$ref' but the mirror says '$mirror_ver'"
fi

# ---- 2. it applies cleanly, AND co-exists with every other windows-utils patch -----------------
# CI applies four patches to one clone. A patch that applies alone and conflicts with its
# neighbours fails in CI only, after a build. Apply them in the order build.yml does.
rm -rf "$OUT/clean"; mkdir -p "$OUT/clean"
cp -r "$MIRROR"/. "$OUT/clean/"
( cd "$OUT/clean" && git init -q . 2>/dev/null; git apply --check "$PATCHFILE" ) 2>"$OUT/apply.err"
if [ $? -eq 0 ]; then ok "applies: git apply --check succeeds against a pristine mirror"
else bad "applies: $(head -2 "$OUT/apply.err" | tr '\n' ' ')"; fi

order=$(command grep -oE 'patches\\windows-utils-[a-z-]+\.patch' "$ROOT/.github/workflows/build.yml" \
        | sed 's/.*\\//' | awk '!seen[$0]++')
rm -rf "$OUT/all"; mkdir -p "$OUT/all"
cp -r "$MIRROR"/. "$OUT/all/"
( cd "$OUT/all" && git init -q . ) 2>/dev/null
allok=1; applied=0
for p in $order; do
  if ( cd "$OUT/all" && git apply "$ROOT/patches/$p" ) 2>>"$OUT/all.err"; then
    applied=$((applied+1))
  else
    allok=0; echo "      ... $p failed to apply in sequence"
  fi
done
if [ "$allok" = 1 ] && [ "$applied" -ge 4 ] && echo "$order" | command grep -q 'one-log-per-module'; then
  ok "stacks_with_siblings: all $applied windows-utils patches apply in build.yml's order, ours among them"
else
  bad "stacks_with_siblings: applied=$applied of $(echo "$order" | wc -w) in CI order ($(echo $order | tr '\n' ' '))"
fi
SRC="$OUT/clean/src/log.c"
( cd "$OUT/clean" && git apply "$PATCHFILE" ) 2>/dev/null

# ---- 3. every marker the build step asserts is present after patching --------------------------
miss=""
for m in 'FILE_APPEND_DATA | FILE_READ_ATTRIBUTES' \
         'WriteFile(g_LogfileHandle, g_LineBufUtf8' \
         '%s-%04d%02d%02d.log' \
         'g_LineBufUtf8[CONVERT_MAX_BUFFER_LENGTH + 1024]'; do
  command grep -qF "$m" "$SRC" || miss="$miss [$m]"
done
[ -z "$miss" ] && ok "markers: every string the build step asserts is present after patching" \
               || bad "markers: missing$miss"

# ---- 4. the defect is GONE, not merely shadowed ------------------------------------------------
if command grep -qF '%02d%02d%02d-%d.log' "$SRC" || command grep -qE 'GetCurrentProcessId\(\)\s*\)\)\)' "$SRC"; then
  bad "defect_removed: the log name still carries the time and the pid"
else
  ok "defect_removed: the per-process log name (time + pid) is gone"
fi

# ---- 5. the write is ONE call on the normal path -----------------------------------------------
# The composed write must exist exactly once, and the three-call form must survive ONLY as the
# over-long-line fallback - i.e. inside an else branch, never on the normal path.
n_line=$(command grep -cF 'WriteFile(g_LogfileHandle, g_LineBufUtf8' "$SRC")
n_piece=$(command grep -cF 'WriteFile(g_LogfileHandle, g_PrefixBufferUtf8' "$SRC")
if [ "$n_line" = 1 ] && [ "$n_piece" = 1 ] && command grep -qF 'exceeds the one-write buffer' "$SRC"; then
  ok "one_write: one composed write, and the piecewise form survives only as the announced over-long fallback"
else
  bad "one_write: composed=$n_line (want 1) piecewise=$n_piece (want 1, in the fallback)"
fi

# ---- 6. the open is append-only and no longer exclusive ----------------------------------------
if command grep -qF 'FILE_SHARE_READ | FILE_SHARE_WRITE' "$SRC" \
   && ! command grep -A2 'g_LogfileHandle = CreateFile' "$SRC" | command grep -qF 'GENERIC_WRITE'; then
  ok "append_open: the log is opened append-only and shared for writing; GENERIC_WRITE is gone"
else
  bad "append_open: the log file open is still GENERIC_WRITE and/or not shared for writing"
fi

# ---- 6b. the BOM belongs to the CREATOR, not to whoever reads a zero length ---------------------
# OPEN_ALWAYS plus a length check is a race: two processes of one module starting together both read
# zero and both write a BOM, leaving a doubled BOM and one unparseable first line. Exactly one
# CREATE_NEW can win, so creation is what decides it.
if command grep -qF 'CREATE_NEW' "$SRC" && command grep -qF 'weCreatedTheLog' "$SRC" \
   && command grep -qF 'OPEN_EXISTING' "$SRC" && ! command grep -qF 'GetFileSizeEx' "$SRC"; then
  ok "bom_by_creator: CREATE_NEW decides who writes the BOM; the racy length check is gone"
else
  bad "bom_by_creator: the BOM is still written on a length check, which two starters can both pass"
fi

# ---- 7. the shipped retention sweep still works ------------------------------------------------
# PurgeOldLogs deletes by ftCreationTime against "<module>*.*". The date must stay in the name, or
# the live log ages out and gets deleted under the running process.
if command grep -qF '%s-%04d%02d%02d.log' "$SRC" && command grep -qF 'PurgeOldLogs(logDir)' "$SRC"; then
  ok "purge_still_sound: the name still carries the date the age-based purge needs"
else
  bad "purge_still_sound: a dateless name would have PurgeOldLogs delete the live log"
fi

# ---- 8. the undefined read on an empty message is fixed ----------------------------------------
command grep -qF 'if (bufferSize == 0)' "$SRC" \
  && ok "empty_message: an empty message no longer reads g_BufferUtf8[-1]" \
  || bad "empty_message: the [bufferSize - 1] read is still unguarded"

# ---- 8a. SAFE FLUSH MUST NOT HAVE BECOME A NO-OP -----------------------------------------------
# g_SafeFlush exists so a line is on disk before a crash, and it was serviced by FlushFileBuffers -
# which documents a GENERIC_WRITE requirement an append-only handle does not meet. Left alone, this
# fix would have turned safe flush into a silent no-op. The OS does it at the open instead.
# The property is not "a flag is mentioned": it is that LogFlush still FLUSHES when the append-only
# handle refuses. Its two real callers are agent/gui-agent/lifecycle.c:148 and :156, immediately
# before ExitProcess at a session end - the lines that explain a shutdown. An earlier version of
# this check passed on two greps while durability was gated on a registry value the MSI ships as 0,
# which left exactly that hole open.
flushblk=$(sed -n '/^void LogFlush/,/^}/p' "$SRC")
if printf '%s' "$flushblk" | command grep -qF 'GENERIC_WRITE' \
   && printf '%s' "$flushblk" | command grep -qF 'OPEN_EXISTING' \
   && printf '%s' "$flushblk" | command grep -qF 'may be lost' \
   && command grep -qF 'g_LogFilePath = _wcsdup' "$SRC"; then
  ok "flush_still_flushes: LogFlush reopens the file with write access when the append handle refuses, and says so if both routes fail"
else
  bad "flush_still_flushes: LogFlush cannot flush an append-only handle and has no second route - the lines before ExitProcess can be lost silently"
fi
# and the write-through path for a configured safe flush is still there
command grep -qF 'FILE_FLAG_WRITE_THROUGH' "$SRC" \
  && ok "safe_flush_honoured: a log configured for safe flush is still opened write-through" \
  || bad "safe_flush_honoured: the configured safe-flush path is gone"

# ---- 8b. EVERY LINE NAMES ITS PROCESS ----------------------------------------------------------
# The pid used to live in the FILE NAME and nowhere else. With one file per module a line that does
# not name its process cannot be attributed to one, which would trade a pile of files for one
# unreadable file. The prefix is pid:tid now.
if command grep -qF '%03d-%d:%d-%c' "$SRC" && command grep -qF 'GetCurrentProcessId(), GetCurrentThreadId()' "$SRC"; then
  ok "line_names_its_process: the prefix carries pid:tid, so an interleaved file is still attributable"
else
  bad "line_names_its_process: the line prefix still carries only the thread id"
fi

# ---- 9. THE ANALYZER MUST STILL RECOGNISE THE NEW NAMES ----------------------------------------
# If the sweep stops classifying our logs, the release gate goes blind and says nothing at all.
python3 - "$ROOT" <<'PY' > "$OUT/family.txt" 2>&1
import importlib.util, sys, pathlib
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ls", root / "tools" / "log-sweep.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
want = {
    "qrexec-wrapper-20261007.log": "qrexec",
    "qrexec-agent-20261007.log": "qrexec",
    "gui-agent-20261007.log": "agent",
    "gui-watchdog-20261007.log": "watchdog",
    "qubesdb-daemon-20261007.log": "qubesdb",
    "network-setup-20261007.log": "winutils",
    "set-gui-mode-20261007.log": "winutils",
}
bad = []
for name, fam in want.items():
    got = next((f for rx, f in m.FAMILY_BY_NAME if rx.match(name)), None)
    if got != fam:
        bad.append("%s -> %s (want %s)" % (name, got, fam))
# Both prefix shapes must parse: guests still hold logs written with the single-number (tid) prefix,
# and dropping it would blind the gate to every log taken before today.
for line, want_pid, want_tid in (
    ("[20261007.123456.789-1234-E] Func: old shape", "", "1234"),
    ("[20261007.123456.789-5678:1234-E] Func: new shape", "5678", "1234"),
):
    g = m.WINUTILS_RE.match(line)
    if not g:
        bad.append("prefix not parsed: %s" % line)
        continue
    n1, n2 = g.group(4), g.group(5)
    pid, tid = (n1, n2) if n2 else ("", n1)
    if (pid, tid) != (want_pid, want_tid):
        bad.append("prefix %s -> pid=%r tid=%r (want %r/%r)" % (line, pid, tid, want_pid, want_tid))
print("OK" if not bad else "BAD " + "; ".join(bad))
PY
if command grep -q '^OK' "$OUT/family.txt"; then
  ok "analyzer_still_classifies: every new-style name lands in its family, and BOTH prefix shapes parse with the right pid/tid"
else
  bad "analyzer_still_classifies: $(head -2 "$OUT/family.txt" | tr '\n' ' ')"
fi

# ---- 10. the PowerShell logger changed the same way --------------------------------------------
PSLOG="$ROOT/core-agent/src/qubes-rpc-services/log.ps1"
if command grep -qF 'yyyyMMdd").log' "$PSLOG" && ! command grep -qF -- '-$PID.log' "$PSLOG" \
   && command grep -qF 'LogAppendLine' "$PSLOG" && command grep -qF 'line LOST' "$PSLOG"; then
  ok "ps_logger: one file per script per day, and a contended append retries then SAYS it lost the line"
else
  bad "ps_logger: log.ps1 still names per pid, or appends without a bounded retry and a loud loss"
fi

# ---- 11. the restart verifier no longer trusts a file name -------------------------------------
# A shared file means: no new file on restart, and the previous instance's lines are in it.
RGA="$ROOT/guest/restart-gui-agent.ps1"
rga_bad=""
command grep -qF 'Get-GuiAgentLastInit' "$RGA" || rga_bad="$rga_bad [no last-init reader]"
command grep -qF 'Get-GuiAgentLogPid' "$RGA" && rga_bad="$rga_bad [still parses a pid out of the name]"
command grep -qF 'AfterLine' "$RGA" || rga_bad="$rga_bad [serving marker not bounded to lines after the init]"
command grep -qF 'no-new-init' "$RGA" || rga_bad="$rga_bad [turnover still waits for a new FILE]"
command grep -qF -- '-InitAt' "$RGA" || rga_bad="$rga_bad [pid age still checked against the file's creation time]"
[ -z "$rga_bad" ] && ok "restart_verifier: identity is the LAST init record, and later markers must follow it" \
                  || bad "restart_verifier:$rga_bad"

# ---- 12. THE CHECKS MUST FAIL ON UNPATCHED SOURCE ----------------------------------------------
# A check never seen to fail is decoration. Run the marker checks against the pristine mirror.
UN="$MIRROR/src/log.c"
un_markers=0
for m in 'FILE_APPEND_DATA | FILE_READ_ATTRIBUTES' 'g_LineBufUtf8' '%s-%04d%02d%02d.log'; do
  command grep -qF "$m" "$UN" && un_markers=$((un_markers+1))
done
if [ "$un_markers" = 0 ] && command grep -qF '%02d%02d%02d-%d.log' "$UN" && command grep -qF 'GENERIC_WRITE' "$UN"; then
  ok "seen_to_fail: against UNPATCHED source every marker is absent and both defects are present"
else
  bad "seen_to_fail: unpatched source has $un_markers/3 markers - the checks above prove nothing"
fi

# ---- 13. the build wires it in BOTH workflows, with the no-op guard ----------------------------
for wf in build qwt-full; do
  f="$ROOT/.github/workflows/$wf.yml"
  if command grep -q 'windows-utils-one-log-per-module.patch' "$f" \
     && command grep -q 'append-only open marker missing after patch' "$f" \
     && command grep -q 'the per-process log name is still present after patching' "$f"; then
    ok "wired_$wf: applied unconditionally, with assertions for both the new marker and the old defect"
  else
    bad "wired_$wf: not applied, or applied without a marker assertion"
  fi
done

echo
echo "one-log-per-module-selftest: $pass passed, $fail failed   (work dir: $OUT)"
[ "$fail" = 0 ] || exit 1
