#!/bin/bash
# committed-procedure-gate.sh — PreToolUse hook (Bash|Workflow|Agent)
# Blocks heavy rig mutations unless a recent Jev call explicitly quotes the committed procedure.
# Exception: recreate-goldens sequence when no golden exists (docs/PROCEDURE-recreate-goldens.md).
set -u
WINDOW_MIN="${COMMITTED_PROC_WINDOW_MIN:-15}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"
# EVERY ENTRY POINT, NOT JUST THE INNERMOST ONE. This listed matrix.sh but none of the wrappers
# that CALL it, and the gate reads the command IT is asked to allow - not the processes that
# command later spawns. MEASURED 2026-10-16: a full 8-cell acceptance campaign - the heaviest path
# on this rig, four hours of exclusive time and the operator's screen - was launched through
# release-acceptance.sh inside a wrapper script, and this gate never fired, so the heaviest action
# available went without the committed-procedure Jev call that its own inner step requires. One
# level of indirection defeated it. Driven by tools/tests/committed-procedure-gate-selftest.sh.
HEAVY='prime-run\.sh|reprovision-usb\.sh|matrix\.sh|seal-qwt-golden|build-media\.sh|clone-to-template'
HEAVY="$HEAVY|release-acceptance\.sh|campaign-run\.sh|gate-remainder\.sh"
# repro-run.sh added 2026-10-28 WITH the wrapper, not after it. It loops prime-run.sh, so it is
# exactly the one-level indirection the comment above measured on 2026-10-16: the gate reads the
# command it is asked to allow, and an unlisted wrapper makes a heavy path invisible to it.
HEAVY="$HEAVY|repro-run\.sh"
# campaign-full.sh IS THE HEAVIEST PATH ON THIS RIG AND WAS NOT LISTED. Every script it calls was
# - release-acceptance.sh, gate-remainder.sh, matrix.sh via them - but the gate reads the command it
# is asked to allow, so naming the parts and not the whole is precisely the one-level-of-indirection
# hole measured on 2026-10-16, rebuilt by a wrapper written after that fix. It runs the eight cells,
# the feature tests AND the six remainder suites against two packages: hours of exclusive rig time
# and the operator's screen, on the single command most likely to be typed from memory at the end of
# a long session. Found 2026-10-29 while reading the chain before running it.
HEAVY="$HEAVY|campaign-full\.sh"
# The ETW gate suite added 2026-10-30. Found while preparing to re-run it: its T0 step primes
# the subject from a base golden with a clean install from the release package - the same heavy
# path listed first in this regex - and the suite itself was never listed. That is exactly the
# one-level-of-indirection hole measured on 2026-10-16 and rebuilt on 2026-10-29, a third time:
# the gate reads the command it is asked to allow, so naming the inner script does nothing for a
# wrapper that calls it. Any suite that primes its own subject belongs here.
HEAVY="$HEAVY|p3a-etw-gate\.sh"

# THE BLUNTNESS IS LOAD-BEARING, AND A READ-ONLY EXEMPTION IS NOT AS EASY AS IT LOOKS.
# This regex matches the command TEXT, so a command that merely NAMES a heavy script - a grep for
# the filename, a patch script with it in a string literal - is refused too. That was invisible
# while permits never expired. The obvious narrowing is to exempt commands whose every segment is
# a read-only inspector, and it was designed and then DROPPED on 2026-10-29: there is no small
# safe subset of these tools. sed executes with the `e` flag, awk with system() and `print | cmd`,
# find with -exec, and even sort with --compress-program=CMD - all without a single $( . A
# whitelist containing any of them exempts arbitrary execution; one that excludes them is too
# narrow to remove the friction it exists for. Banning command substitution does not help, because
# none of those four needs it. If you try this again, that is the problem to solve first.
# The friction is small in practice: both false refusals measured that day came from working on
# this hook itself. Prefer paying it to weakening the gate.
input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c '
import json,sys
try: o=json.loads(sys.stdin.read() or "{}")
except Exception: print(""); sys.exit(0)
tool=o.get("tool_name","")
ti=o.get("tool_input") or {}
if tool=="Bash": print(ti.get("command",""))
elif tool in ("Workflow","Agent"): print(str(ti.get("prompt") or ti.get("description") or ""))
else: print("")
')

if ! echo "$cmd" | grep -qE "$HEAVY"; then exit 0; fi

frag=$(echo "$cmd" | head -c 80 | tr -d "\"'\\n" | sed 's/  */ /g')

if [ ! -s "$WIRE" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no Jev wire log.
Heavy path: $frag
Ask Jev with state containing "committed_procedure", the exact command, and the rejected short-cycle alternative.
If no golden exists, use the recreate-goldens sequence (docs/PROCEDURE-recreate-goldens.md) and include the marker recreate_goldens.
EOM
  exit 2
fi

# Normal case: command fragment + committed-procedure marker (or quick-upgrade mention)
# THE PERMIT MUST NAME THIS COMMAND. It used to accept a line that named the command OR merely
# mentioned "quick-upgrade" - and since a well-formed permit is REQUIRED to state the rejected
# short-cycle alternative, which is quick-upgrade, that clause was satisfied by EVERY valid permit.
# So the command binding was inert: a permit obtained for prime-run authorised a full 8-cell
# campaign, measured 2026-10-16 by tools/tests/committed-procedure-gate-selftest.sh. The mention of
# the alternative is evidence it was considered; it is not a substitute for naming the command.
#
# AND THE PERMIT MUST BE RECENT. WINDOW_MIN was declared on line 6 and then never read again: the
# lookup below returned a LINE NUMBER, and nothing ever compared a clock, so every permit ever
# written stayed valid forever. MEASURED 2026-10-29: a campaign was launched on the permit at line
# 9814, written 2026-10-28T03:16 - a day and a different package earlier - while that run's own
# fresh permit sat unread at line 10079. The word "recent" was in the block message the whole time.
# A line whose ts is missing or unparseable is NOT fresh: jev.py stamps every line it writes, so an
# unstamped line is not a Jev permit, and failing open on one would restore exactly this hole.
verdict=$(WINDOW_MIN="$WINDOW_MIN" FRAG="$frag" python3 - "$WIRE" <<'WIREPY'
import json, os, sys, datetime

wire = sys.argv[1]
frag = os.environ["FRAG"][:20]
win  = float(os.environ["WINDOW_MIN"])
now  = datetime.datetime.now(datetime.timezone.utc)

fresh = None          # (kind, age_min) a permit inside the window
stale = None          # (kind, age_min) the NEWEST one outside it, named in the block message

for line in open(wire, errors="replace"):
    if ("committed_procedure" in line or "use_committed" in line or "procedure_delta" in line) \
       and frag in line:
        kind = "permit"
    elif "recreate_goldens" in line or "PROCEDURE-recreate-goldens" in line:
        kind = "recreate-goldens permit"
    else:
        continue
    try:
        t = datetime.datetime.fromisoformat(json.loads(line).get("ts"))
        if t.tzinfo is None:
            t = t.astimezone()
    except Exception:
        continue
    age = (now - t).total_seconds() / 60.0
    if age <= win:
        fresh = (kind, age)
    elif stale is None or age < stale[1]:
        stale = (kind, age)

if fresh:   print("OK|%s|%.0f" % fresh)
elif stale: print("STALE|%s|%.0f" % stale)
else:       print("NONE|none|0")
WIREPY
)
state="${verdict%%|*}"; rest="${verdict#*|}"; kind="${rest%%|*}"; age="${rest##*|}"

if [ "$state" = "STALE" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: the newest Jev $kind naming this command is ${age} min old (window ${WINDOW_MIN} min).
Heavy path: $frag
A permit authorises the run it was asked about, not a later one. Ask Jev again, NOW, with state
containing "committed_procedure", the exact command, and the rejected short-cycle alternative.
EOM
  exit 2
fi

if [ "$state" != "OK" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no recent Jev call quoting both the command and the committed alternative.
Heavy path: $frag
If no golden exists, ask Jev with state containing recreate_goldens and the commands from docs/PROCEDURE-recreate-goldens.md.
EOM
  exit 2
fi
exit 0
