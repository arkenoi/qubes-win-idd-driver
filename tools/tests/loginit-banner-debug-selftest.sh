#!/usr/bin/env bash
# loginit-banner-debug-selftest.sh - patches/windows-utils-loginit-banner-debug.patch, OFFLINE.
# No guest, no CI.
#
# WHAT IT GUARDS. qrexec-wrapper is a SHORT-LIVED process spawned once per qrexec call, and
# windows-utils' LogInit emits six LogInfo lines every time one starts - Log started / System
# uptime / Running as user / Module version / Session / Command line. Measured on acceptance run
# 39225775322, one brief WIN10-clean cell: 155 invocations, ~1085 of that module's 1250 lines were
# that banner - 87% of the file a process announcing its own birth - and the whole guest session
# read 2535 INFO against 52 WARN and 2 ERROR. Owner 2026-10-20: "it is NOT normal to have
# thousands of lines of log during the brief normal run ... ok for debug purposes but not on a
# product session."
#
# The fix demotes them to LogDebug: gone at the default level, all back at LOG_LEVEL_DEBUG, which
# is where a startup banner belongs. The lines are NOT deleted - losing them would cost the one
# thing they are good for, telling support which build wrote a log.
#
# ORDER MATTERS: one-log-per-module.patch is the only other patch touching log.c, and this one is
# generated against the file AFTER it. The test applies both in the CI order, so a future patch
# that collides is caught here rather than in a build.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
pass=0; fail=0
ok(){  pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }

UP=upstream/ro/qubes-windows-utils/src/log.c
# upstream/ro is gitignored (.gitignore), so a checkout without it cannot run this. That is
# INCONCLUSIVE, not a pass: a suite that quietly skips is a suite that reports success.
[ -f "$UP" ] || { echo "INCONCLUSIVE: $UP absent (upstream/ro is gitignored) - nothing checked"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src"; cp "$UP" "$T/src/log.c"
( cd "$T" && git init -q . && git add src/log.c && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1

# the banner is at INFO before anything is applied - the control for everything below
if command grep -qE 'LogInfo\("Log started' "$T/src/log.c"; then
  ok "control: upstream emits the startup banner at INFO"
else
  bad "control: upstream does not emit LogInfo(\"Log started\")" "the patch's premise is gone; re-read upstream before trusting this suite"
fi

a=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-one-log-per-module.patch" 2>&1); arc=$?
[ "$arc" = 0 ] && ok "one-log-per-module applies (it is applied first in CI)" \
                || bad "one-log-per-module did not apply" "$(printf '%s' "$a" | tail -1)"
b=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-loginit-banner-debug.patch" 2>&1); brc=$?
[ "$brc" = 0 ] && ok "loginit-banner-debug applies AFTER it, in the CI order" \
                || bad "loginit-banner-debug did not apply after one-log-per-module" "$(printf '%s' "$b" | tail -1)"

src=$T/src/log.c
# every banner line demoted...
for m in 'Log started, module name' 'System uptime: %.3f seconds' 'Running as user: %s' 'Module version: %d' 'Session: %lu' 'Command line: %s'; do
  if command grep -q "LogDebug(\"$(printf '%s' "$m" | cut -c1-20)" "$src" 2>/dev/null \
     || command grep -qF "LogDebug(\"$m" "$src"; then
    ok "demoted to LogDebug: $m"
  else
    bad "still not at LogDebug: $m" "$(command grep -nF "$m" "$src" | head -1 | cut -c1-110)"
  fi
done
# ...and NOT deleted: the banner must survive, just quieter
kept=$(command grep -c 'LogDebug("Log started\|LogDebug("System uptime\|LogDebug("Running as user\|LogDebug("Module version\|LogDebug("Session:\|LogDebug("Command line' "$src")
[ "$kept" -ge 6 ] && ok "the banner is KEPT at debug ($kept line(s)), not deleted" \
                  || bad "banner lines were lost, not demoted ($kept found)" "support loses which build wrote a log"
# ...and none left at INFO
left=$(command grep -c 'LogInfo("Log started\|LogInfo("System uptime\|LogInfo("Running as user\|LogInfo("Module version\|LogInfo("Session:\|LogInfo("Command line' "$src")
[ "$left" = 0 ] && ok "no banner line is left at INFO" \
                || bad "$left banner line(s) still at INFO" "a product session keeps flooding"

# ---- THE BIRTH LINE: what the demotion took away, given back ONCE -------------------------------
#
# Demoting the banner also removed the only thing that bills a log line to a BUILD, and
# tools/log-sweep.py reads three facts out of it: the module name, the boot (System uptime) and the
# version. MEASURED, acceptance run 39868919766: every graded cell read boots=0 agent_instances=0
# over 3781-7653 lines, FOUR cells returned status=CLEAN having attributed nothing at all, and
# win10-upgrade failed on five ERROR lines belonging to its 4.3.35.795 entry fixture - the only
# banner-bearing log in that capture, because the image predates the demotion. The marker that
# replaces it was already named at tools/sweep-gate.sh:747 and grepped for at :778, and already had
# fixtures in sweep-life-selftest - with no producer, which is why that gate's own count of birth
# lines per capture went "2484, then 327, then ZERO". These legs hold the producer and the consumer
# to the SAME spelling, which is the join that was missing.
#
# EVERY SOURCE ASSERTION BELOW STRIPS // COMMENT LINES FIRST. The comment explaining this line names
# every token the legs forbid or require, so an unfiltered grep would find its own explanation.
c=$(cd "$T" && git apply --verbose "$OLDPWD/patches/windows-utils-single-birth-line.patch" 2>&1); crc=$?
[ "$crc" = 0 ] && ok "single-birth-line applies AFTER both, in the CI order" \
                || bad "single-birth-line did not apply third" "$(printf '%s' "$c" | tail -1)"

code=$(command grep -v '^[[:space:]]*//' "$src")

if printf '%s' "$code" | command grep -qF 'LogInfo("QWTBIRTH module='; then
  ok "the birth line is emitted at INFO, so a product session carries it"
else
  bad "no LogInfo(\"QWTBIRTH module=\" in the patched source" "the sweep has no build to bill a line to"
fi

# every fact the parser needs, in ONE line
for k in 'module=%s' 'ver=%d.%d.%d.%d' 'pid=%lu' 'session=%lu' 'uptime=%.3f'; do
  if printf '%s' "$code" | command grep -qF "$k"; then
    ok "the birth line states $k"
  else
    bad "the birth line omits $k" "log-sweep.py cannot rebuild the init record without it"
  fi
done

# ONE line, not six: the owner's objection was volume, and this must not reinstate it
n=$(printf '%s' "$code" | command grep -c 'LogInfo("QWTBIRTH')
[ "$n" = 1 ] && ok "exactly one INFO line is added per process start (not six)" \
             || bad "$n QWTBIRTH INFO lines in LogInit" "one process start must cost one line"
# and the demoted banner stays demoted - the legs above assert this, so here only that the new line
# did not drag any of it back up
left2=$(printf '%s' "$code" | command grep -c 'LogInfo("Log started\|LogInfo("System uptime\|LogInfo("Running as user\|LogInfo("Module version\|LogInfo("Session:\|LogInfo("Command line')
[ "$left2" = 0 ] && ok "the birth line did not restore any banner line to INFO" \
                 || bad "$left2 banner line(s) back at INFO" "the demotion was undone"

# THE PRODUCER'S TEXT MUST SATISFY THE CONSUMERS' PATTERNS. Both are quoted from the consumers, not
# invented here: tools/sweep-gate.sh:778 greps 'QWTBIRTH module=' and tools/log-sweep.py tests
# msg.startswith("QWTBIRTH "). A format string that drifts from either is the whole failure mode.
emitted='[20261023.021749.400-3820:3824-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=3820 session=1 uptime=31.500'
printf '%s' "$emitted" | command grep -qE 'QWTBIRTH module=' \
  && ok "an emitted birth line matches sweep-gate.sh's grep" \
  || bad "an emitted birth line does not match sweep-gate.sh's pattern" "the life gate stays blind"
if command grep -q 'msg.startswith("QWTBIRTH ")' tools/log-sweep.py; then
  ok "log-sweep.py reads the marker the patch writes"
else
  bad "log-sweep.py has no QWTBIRTH handler" "the producer landed with no consumer - the exact shape of the defect this fixes"
fi

# THE CONSUMER, ON A REAL PARSE. A source-text match is not the property: the property is that one
# birth line yields one attributable instance with a version. SEEN TO FAIL - with the line removed
# this reads inits=0 version=None, which is precisely what every cell of run 39868919766 recorded.
LF=$T/cap; mkdir -p "$LF"
printf '%s\n' "$emitted" > "$LF/gui-agent-20261023.log"
printf '[20261023.021750.000-3820:3824-I] TrackWindows: up\n' >> "$LF/gui-agent-20261023.log"
got=$(python3 - "$LF" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("gui-agent")][0]
print("%d|%s|%s|%s" % (len(lf.inits or []), lf.version, lf.module,
                       m.line_version(lf, lf.lines[-1])))
EOF
) || got="parse-failed"
case "$got" in
  "1|4.3.37.1100|gui-agent|4.3.37.1100")
      ok "one birth line yields one init, a module and a version a LINE can be billed to" ;;
  *)  bad "the parse did not recover the init record (got '$got')" \
          "expected 1|4.3.37.1100|gui-agent|4.3.37.1100 - without this every cell reads agent_instances=0" ;;
esac

# ONE PROCESS IS ONE INSTANCE EVEN AT DEBUG LEVEL. At LOG_LEVEL_DEBUG the demoted banner comes back,
# so a support capture carries the legacy six-line block AND the birth line for the SAME process.
# Counting both would double agent_instances and breach agent_instances_per_boot (max 1) on a guest
# that did nothing wrong. SEEN TO FAIL: appending unconditionally reads inits=2.
D=$T/dbg; mkdir -p "$D"
{
  printf '[20261023.021749.300-3820:3824-D] LogInit: Log started, module name: gui-agent\n'
  printf '[20261023.021749.300-3820:3824-D] LogInit: System uptime: 31.500 seconds\n'
  printf '[20261023.021749.300-3820:3824-D] LogInit: Running as user: SYSTEM, process ID: 3820\n'
  printf '[20261023.021749.300-3820:3824-D] LogInit: Module version: 4.3.37.1100\n'
  printf '[20261023.021749.400-3820:3824-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=3820 session=1 uptime=31.500\n'
  printf '[20261023.021750.000-3820:3824-I] TrackWindows: up\n'
} > "$D/gui-agent-20261023.log"
got=$(python3 - "$D" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("gui-agent")][0]
print("%d|%s" % (len(lf.inits or []), lf.version))
EOF
) || got="parse-failed"
[ "$got" = "1|4.3.37.1100" ]   && ok "a debug-level capture holding BOTH spellings counts one instance, not two"   || bad "both spellings for one process start were counted separately (got '$got')"          "expected 1|4.3.37.1100 - agent_instances_per_boot would breach on a healthy guest"

# 0.0.0.0 IS NOT A VERSION. The producer prints it when GetCurrentModuleVersion failed, and our own
# qwtng-netsetup has no version resource at all. Believing it gives that module a versions list that
# cannot match the build under test, and unattributable() then bills its every versioned line to
# nobody - a P2 breach no build can own. SEEN TO FAIL: accepting `ver` as-is reads version=0.0.0.0
# and line_version=0.0.0.0.
Z=$T/zero; mkdir -p "$Z"
printf '[20261023.021749.400-900:901-I] LogInit: QWTBIRTH module=qwtng-netsetup ver=0.0.0.0 pid=900 session=0 uptime=12.000\n[20261023.021750.000-900:901-E] Apply: failed\n' > "$Z/qwtng-netsetup-20261023.log"
got=$(python3 - "$Z" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("qwtng-netsetup")][0]
print("%d|%s|%s" % (len(lf.inits or []), lf.version, m.line_version(lf, lf.lines[-1])))
EOF
) || got="parse-failed"
[ "$got" = "1|None|None" ]   && ok "ver=0.0.0.0 opens the instance but declares no version to bill lines to"   || bad "0.0.0.0 was taken as a version (got '$got')"          "expected 1|None|None - an unversioned module's ERROR line becomes an unownable breach"

# AND THE LEGACY BANNER MUST OBEY THE SAME 0.0.0.0 RULE. The QWTBIRTH leg above has guarded this
# since the birth line landed; the legacy `Module version:` path did not, and an entry fixture that
# predates the birth line writes exactly that banner. MEASURED on win11-upgrade of 2026-10-23, the
# first upgrade cell ever graded on the candidate's own logs: qwtng-netsetup came back
# versions=['0.0.0.0'], which matches no build under test, so unattributable() billed every
# versioned line of that module to nobody - error_lines_unattributable = 12 (max 0) on twelve lines
# the cell itself declares as tolerated, with error_lines_undeclared reading 0. Both paths now share
# _declared_version() so they cannot drift apart again.
# SEEN TO FAIL: against the pre-fix parser this reads 1|0.0.0.0|0.0.0.0.
Z2=$T/zero-legacy; mkdir -p "$Z2"
printf '[20261023.092232.000-3724:3728-I] LogInit: Log started, module name: qwtng-netsetup\n[20261023.092232.100-3724:3728-I] LogInit: Module version: 0.0.0.0\n[20261023.092233.006-3724:3728-E] send_command_to_daemon: write to daemon failed with error 0xe8: The pipe is being closed.\n' \
  > "$Z2/qwtng-netsetup-20261023-092232-3724.log"
got=$(python3 - "$Z2" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("qwtng-netsetup")][0]
print("%d|%s|%s" % (len(lf.inits or []), lf.version, m.line_version(lf, lf.lines[-1])))
EOF
) || got="parse-failed"
[ "$got" = "1|None|None" ]   && ok "the LEGACY banner's 0.0.0.0 declares no version either - one rule, both paths"   || bad "the legacy path took 0.0.0.0 as a version (got '$got')"          "expected 1|None|None - this is what failed win11-upgrade on 12 declared lines"

# AND THE CONSEQUENCE, not just the parse: with no fabricated version, such a module's ERROR line is
# no longer billed to nobody. This is the property; the parse above is the mechanism.
got=$(python3 - "$Z2" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
sc = m.build_scope(files, "4.3.37+agent.7f26b15b15d6")
prior, unattrib = sc.prior, sc.unattributable   # BY NAME: build_scope returns a BuildScope, and sc[-1] silently became a different field when inst_prior was appended
lf = [f for f in files if f.name.startswith("qwtng-netsetup")][0]
errs = [l for l in lf.lines if l.level == "E"]
print(sum(1 for l in errs if unattrib(lf, l) and not prior(lf, l)))
EOF
) || got="parse-failed"
[ "$got" = "0" ]   && ok "an unversioned module's ERROR line is no longer unattributable (0 of them)"   || bad "an unversioned module's ERROR line is still billed to nobody (got '$got')"          "that is the P2 breach no build can own"

# A RECORD MUST NOT INHERIT THE PREVIOUS INSTANCE'S BUILD. Two instances in one per-day file, the
# second's birth line truncated so it carries no readable ver (an unclean shutdown leaving NULs
# mid-file is a measured shape here). SEEN TO FAIL: reading the record's version from the
# file-scoped lf.version bills instance 2 to 4.3.36.915, the build it is NOT.
I=$T/inherit; mkdir -p "$I"
{
  printf '[20261023.030000.000-100:101-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.36.915 pid=100 session=1 uptime=10.000\n'
  printf '[20261023.030001.000-100:101-I] TrackWindows: first instance\n'
  printf '[20261023.040000.000-200:201-I] LogInit: QWTBIRTH module=gui-agent pid=200 session=1 uptime=20.000\n'
  printf '[20261023.040001.000-200:201-E] TrackWindows: second instance failed\n'
} > "$I/gui-agent-20261023.log"
got=$(python3 - "$I" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("gui-agent")][0]
print("%d|%s|%s" % (len(lf.inits or []), [i.get("version") for i in lf.inits],
                    m.line_version(lf, lf.lines[-1])))
EOF
) || got="parse-failed"
[ "$got" = "2|['4.3.36.915', None]|None" ]   && ok "an instance whose birth line states no version inherits none"   || bad "a record inherited a version its own birth line did not state (got '$got')"          "expected 2|['4.3.36.915', None]|None - the second instance would be billed to 4.3.36.915"

# THE PID JOIN IS BOUNDED IN TIME, because Windows reuses pids and a per-day file spans a day. Two
# instances hours apart sharing pid 3820, each INFO-only. SEEN TO FAIL: joining on pid alone merges
# them and reports one instance where there were two.
R=$T/reuse; mkdir -p "$R"
{
  printf '[20261023.030000.000-3820:1-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=3820 session=1 uptime=10.000\n'
  printf '[20261023.030001.000-3820:1-I] TrackWindows: up\n'
  printf '[20261023.090000.000-3820:1-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=3820 session=1 uptime=30.000\n'
  printf '[20261023.090001.000-3820:1-I] TrackWindows: up again\n'
} > "$R/gui-agent-20261023.log"
got=$(python3 - "$R" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.name.startswith("gui-agent")][0]
print(len(lf.inits or []))
EOF
) || got="parse-failed"
[ "$got" = "2" ]   && ok "two instances six hours apart sharing a reused pid stay two instances"   || bad "a reused pid merged two instances (got '$got' records)"          "expected 2 - agent_instances would under-count by one per reuse"

echo
echo "loginit-banner-debug-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
