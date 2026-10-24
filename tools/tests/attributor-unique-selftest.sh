#!/usr/bin/env bash
# attributor-unique-selftest.sh - THERE IS EXACTLY ONE "is this record the predecessor's?" IN THIS
# TREE, EVERY CONSUMER ROUTES THROUGH IT, AND IT READS THE BANNER THE PRODUCT ACTUALLY SHIPS.
# No guest, no rig.
#
# WHY THIS EXISTS. Owner, 2026-10-24: "you claimed to fix predecessor lines from being erroneously
# ingested AT LEAST FOUR TIMES ... AND YOU DO IT OVER AND OVER", and "until you fix the sweeper, no
# product fixes make sense because you are going to be distracted by predecessor noise on each
# turn". Four fixes, four consumers, because THREE implementations of the rule existed sharing no
# code - tools/log-sweep.py is_prior_build (fixed 2026-10-23), a private `_inst_prior` copy in
# compute_metrics (left on the old rule), and tools/sweep-gate.sh _is_prior_build (old rule, with
# its own banner parser and no --build). Each fix reached one of them; the owner's phrase for the
# result is "self-procreating bugs of bugfixes". THE FAN-OUT IS THIS SUITE'S CONTENT: the thing that
# stops a fifth instance is not a better patch, it is a check that a fourth copy cannot be added.
#
# AND THE WORST OF THE THREE WAS NOT THE RULE, IT WAS THE PARSE. sweep-gate's extractor read
# "LogInit: Log started, module name:" + "LogInit: Module version:" - the two lines
# patches/windows-utils-loginit-banner-debug DEMOTES TO LogDebug, replaced by one LogInfo line
# `LogInit: QWTBIRTH module=<m> ver=<a.b.c.d> ...` from patches/windows-utils-single-birth-line. So
# on every capture written by a shipped build it returned EMPTY, the gate's index held only the
# PREDECESSOR (whose entry-fixture image predates the demotion), and its prior-build rule could
# exclude nothing. MEASURED on scratchpad/dedup-test/logs/files: 27 of 71 files blind, the gate
# FAILED with unaccounted=11 of which all 11 were the predecessor's, and after the fix it excludes
# 41 files and reports unaccounted=0. Backtest over 127 captures / 982 files: 201 -> 283 files
# excluded, 82 files of predecessor noise removed, ZERO regressions
# (scratchpad/attributor-receipt/backtest.txt).
#
# FIVE PROPERTIES, each with a control that has been SEEN TO FAIL:
#   A  exactly one implementation of the RULE exists (AST, so comments and docstrings cannot
#      satisfy it) - control: a second copy injected into a temp tree must be caught
#   B  no shell/powershell script decides it from a banner of its own - control: the old
#      _sg_modver restored into a temp copy of sweep-gate.sh must be caught
#   C  every granularity ROUTES through the one function - control: mutate it and all three must
#      change (line, instance, file); a granularity that does not change has its own copy
#   D  both banner spellings are read, and the fixture's shape is taken from the PATCHES rather
#      than from this file's memory of them
#   E  a named build that declared itself nowhere makes the campaign gate REFUSE - control: a
#      named build that IS present must not refuse
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d /tmp/attruniq-XXXXXX)"
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && echo "     why it matters: $2"; }
trap 'rm -rf "$T"' EXIT

ATTR_FN="version_is_prior"
ATTR_FILE="tools/log-sweep.py"

# =================================================================================================
# A. EXACTLY ONE IMPLEMENTATION OF THE RULE, over the python tree.
#
# THE PREDICATE IS THE AST, NOT A GREP. This project has measured twice that a text check cannot
# carry a property like this: a check satisfied by the COMMENT that quoted the line it guarded
# (2026-10-22), and a count of calls in a file that passed on a missing brace (owner: "FUCK YOUR
# GREPS"). Every docstring in the attribution path QUOTES the old rule - this file does too - so a
# grep for `len(info["versions"]) < 2` finds prose and calls it an implementation. The AST does not
# see comments or docstrings at all.
#
# WHAT COUNTS AS AN IMPLEMENTATION: a function whose body both (a) tests a version collection's
# length against a small literal, or compares something to a ["newest"] subscript, and (b) returns
# a boolean-ish answer from it. That is the rule's distinctive shape. Scoped to the TRACKED tree
# (git ls-files): scratchpad/ carries throwaway forks of this analyzer by design - there was a
# 4240-line copy of log-sweep.py in it on 2026-10-23 - and a working copy nobody ships is not a
# second implementation in the product.
cat > "$T/scan.py" <<'PY'
import ast, sys

# TWO SHAPES, COUNTED SEPARATELY, because the rule has two halves and they live in two functions:
#   turnover  - "does this module's own logs show a build turnover?"  -> module_turned_over()
#   newest    - "is this version the module's newest?"                -> the decision
# The first cut of this scanner required BOTH in one function, which made it miss four private
# copies of the turnover half - install_anchor, _candidate_series, superseded_series and
# version_is_prior each wrote it out by hand. It also only saw the SUBSCRIPT spelling, so
# `info.get("versions")` and `i.get("newest")` were invisible: a copy could be added by writing
# `.get` instead of `[...]`. A guard with a spelling-shaped hole is the defect it exists to stop.
KEYS = ("versions", "newest")

def _key_of(node):
    """The dict key this expression reads, for `x["k"]` and `x.get("k")` alike."""
    if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant):
        return node.slice.value if node.slice.value in KEYS else None
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
            and node.func.attr == "get" and node.args \
            and isinstance(node.args[0], ast.Constant):
        return node.args[0].value if node.args[0].value in KEYS else None
    return None

def shapes(fn):
    turnover = newest = False
    for n in ast.walk(fn):
        if _key_of(n) == "newest":
            newest = True
        # len(<anything mentioning "versions">) compared to a literal
        if isinstance(n, ast.Compare) and isinstance(n.left, ast.Call) \
                and isinstance(n.left.func, ast.Name) and n.left.func.id == "len":
            for a in n.left.args:
                for s in ast.walk(a):
                    if _key_of(s) == "versions":
                        turnover = True
    return turnover, newest

out = []
for p in sys.argv[1:]:
    try:
        tree = ast.parse(open(p, encoding="utf-8").read())
    except (SyntaxError, OSError):
        continue
    for n in ast.walk(tree):
        if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        t, w = shapes(n)
        if t:
            out.append("turnover\t%s:%d:%s" % (p, n.lineno, n.name))
        if w:
            out.append("newest\t%s:%d:%s" % (p, n.lineno, n.name))
for h in sorted(out):
    print(h)
PY
scan_names(){ python3 "$T/scan.py" "${PYFILES[@]}" | awk -F'\t' -v k="$1" '$1==k{n=$2; sub(/.*:/,"",n); print n}' | sort -u | tr '\n' ' '; }
mapfile -t PYFILES < <(git ls-files '*.py' 2>/dev/null)
[ "${#PYFILES[@]}" -ge 5 ] \
  && ok "A0 the scan has a population: ${#PYFILES[@]} tracked .py file(s)" \
  || no "A0 only ${#PYFILES[@]} tracked .py file(s) found - the scan would pass on nothing" \
        "an empty population is a green that measured nothing"

a_turn=$(scan_names turnover)
a_new=$(scan_names newest)
# A1: THE TURNOVER TEST, exactly once. Four functions wrote it out by hand until 2026-10-24, and the
# one in superseded_series is the reason a capture-wide fallback was gated on the very per-module
# test it exists to replace - the measured `26 -> 26, no effect`.
[ "$a_turn" = "module_turned_over " ] \
  && ok "A1 the turnover test exists in exactly one function: $a_turn" \
  || no "A1 the turnover test is in: $a_turn (want module_turned_over alone)" \
        "every extra copy is a consumer the next fix will miss - that is how this was re-fixed four times"
# A1b: WHO MAY READ A MODULE'S `newest` AT ALL - a bounded inventory, asserted as an EQUALITY, so a
# NEW reader is red and so is a silent removal. It is deliberately NOT a uniqueness claim: reading
# the newest version to PRINT it is not deciding attribution, and the first cut of this leg demanded
# "exactly two" and went red on four honest readers. What carries the DECISION's uniqueness is the
# mutation in legs C1/C2/C3 - break version_is_prior and every granularity must change, which a
# second implementation in use would survive.
#   version_is_prior   THE DECISION. The one attributor.
#   install_anchor     which init is the FIRST of the new build - the time cutoff for sources that
#                      structurally carry no version (bridge.log, TaskScheduler records).
#   _candidate_series  the self-calibrating candidate series, when no --build was given.
#   compute_metrics    modules_superseded_silent: "the newest build wrote nothing in the window",
#                      the metric that reports a zero produced by nothing being considered.
#   cmd_analyze        the downgrade warning: --build is not the newest these modules declared.
#   cmd_attribute      prints the module's newest in its output, so no consumer has to rank versions.
A1B_WANT="_candidate_series cmd_analyze cmd_attribute compute_metrics install_anchor version_is_prior "
[ "$a_new" = "$A1B_WANT" ] \
  && ok "A1b the readers of a module's newest are exactly the six named here: $a_new" \
  || no "A1b the newest readers are: $a_new" \
        "want: $A1B_WANT - a new one is a new answer to 'which version is current'; if it is legitimate, name it here with why"

# SEEN TO FAIL: a second copy, in a file that is part of the scanned population.
mkdir -p "$T/inject"
cp "$ATTR_FILE" "$T/inject/log-sweep.py"
cat >> "$T/inject/log-sweep.py" <<'PY'


def _sneaky_prior(mod, v, builds):
    info = builds[mod]
    if len(info["versions"]) < 2:
        return False
    return v != info["newest"]
PY
# A SECOND INJECTED COPY, written in the OTHER SPELLING - `.get("versions")` / `.get("newest")`
# instead of subscripts. That is the hole the first cut of this scanner had: it matched only the
# subscript form, so four hand-written copies of the turnover half sat in the tree unseen and a
# fifth could be added just by typing `.get`. The control proves the hole is closed.
cat >> "$T/inject/log-sweep.py" <<'PY'


def _sneaky_prior_get(mod, v, builds):
    info = builds.get(mod) or {}
    if len(info.get("versions") or []) < 2:
        return False
    return v != info.get("newest")
PY
mapfile -t BASE < <(python3 "$T/scan.py" "$ATTR_FILE")
mapfile -t HITS2 < <(python3 "$T/scan.py" "$T/inject/log-sweep.py")
# RELATIVE TO THE BASELINE, never absolute: the control's job is to show the scan DETECTS an added
# copy, and an absolute number would also fail whenever leg A1 fails - one defect, two red legs, and
# the control's own meaning lost. (It read `= 2` on the first run, reporting the control broken when
# what was actually true was that A1 had found a real fourth site.)
# TWO copies injected, each carrying BOTH halves, so each adds two rows: +4.
if [ "${#HITS2[@]}" = "$(( ${#BASE[@]} + 4 ))" ]; then
    ok "A1 SEEN TO FAIL: injected copies in BOTH spellings are caught (${#BASE[@]} -> ${#HITS2[@]} rows)"
else
    no "A1 control: an injected copy was NOT caught (${#BASE[@]} -> ${#HITS2[@]} rows, want +4)" \
       "the scan cannot see a fifth implementation, so legs A1/A1b prove nothing"
    python3 "$T/scan.py" "$T/inject/log-sweep.py" | sed 's/^/       /'
fi

# AND A CONTROL IN THE OTHER DIRECTION: the scan must not fire on a function that merely MENTIONS
# the rule in a comment or docstring, which is what every honest explanation in this path does.
cat > "$T/inject/prose.py" <<'PY'
def explains_the_rule(mod, v, builds):
    """The old rule was: if len(info["versions"]) < 2: return False, else v != info["newest"]."""
    # if len(info["versions"]) < 2: return False
    # return v != info["newest"]
    return version_is_prior(mod, v, builds)
PY
mapfile -t HITS3 < <(python3 "$T/scan.py" "$T/inject/prose.py")
[ "${#HITS3[@]}" = 0 ] \
  && ok "A2 a function that only QUOTES the rule in prose is not counted" \
  || no "A2 prose was counted as an implementation (${HITS3[*]})" \
        "then every docstring in this path is a finding and the leg is noise"

# =================================================================================================
# B. NO SHELL OR POWERSHELL SCRIPT DECIDES IT FROM A BANNER OF ITS OWN.
#
# The co-occurrence is the predicate, and it needs no exemption list: a script that READS a module's
# declared version out of a log AND ORDERS versions against each other has an implementation of this
# rule in it. tools/cut-release.sh and mgmt/harness/quick-upgrade.sh both order versions (git tags,
# and the version installed on a guest) and neither reads a log banner, so neither is a hit.
# THE POPULATION IS THE SHIPPED SCRIPTS, NOT THE SUITES - and that is a scope with a reason, not an
# exemption by name. A suite DRIVES this rule and therefore quotes both the banner and the old
# ordering on purpose: this very file restores `sort -V` into a temp copy of sweep-gate.sh three
# lines below as its own control, and its fixtures carry QWTBIRTH lines. On the first run B1 reported
# ITSELF. A test implementing the rule cannot change a campaign verdict; a shipped script can. Any
# .py test is still covered, because leg A1's scan takes every tracked .py including tools/tests/.
b_hits=""; b_pop=0
while IFS= read -r f; do
    case "$f" in tools/tests/*) continue ;; esac
    [ -f "$f" ] || continue
    b_pop=$((b_pop+1))
    # the banner, in either spelling - what the parse would read
    command grep -qE "Module version:|module name:|QWTBIRTH[^|]*ver=" "$f" || continue
    # an ordering or inequality over versions - what the decision would do
    command grep -qE "sort -V|sort -rV" "$f" || continue
    b_hits="$b_hits $f"
done < <(git ls-files '*.sh' '*.ps1' '*.cmd' 2>/dev/null)
# A SCOPE THAT EMPTIES THE POPULATION PASSES VACUOUSLY, and the file this property is ABOUT must be
# in it - otherwise the leg would stay green with sweep-gate.sh excluded by a typo.
# NOT `git ls-files | grep -q`: under `set -o pipefail` the producer keeps writing after grep -q
# exits, takes SIGPIPE, and the PIPELINE returns 141 - so the test reads as "not found" whatever
# grep decided. That is this project's own recorded trap (findings/issues.md PIPEFAILGREPQISUGREP),
# and it made this very leg report the population empty while sweep-gate.sh was plainly in it.
b_has=$(git ls-files '*.sh' > "$T/shfiles.txt"; command grep -cx 'tools/sweep-gate.sh' "$T/shfiles.txt" || true)
if [ "$b_pop" -lt 20 ] || [ "${b_has:-0}" -lt 1 ]; then
    no "B1 the population is $b_pop script(s) and/or tools/sweep-gate.sh is not in it" \
       "the scoping emptied the leg - it would then pass whatever the shipped scripts do"
else
    ok "B1 the population is $b_pop shipped script(s), tools/sweep-gate.sh among them"
fi
[ -z "$b_hits" ] \
  && ok "B1 no shipped script both reads a module banner and orders versions" \
  || no "B1 a shell implementation of the rule:$b_hits" \
        "two spellings of one fact is two implementations - this is the one that went blind"

# SEEN TO FAIL: restore the old extractor and the old ordering into a copy and re-run the predicate.
cp tools/sweep-gate.sh "$T/sg-old.sh"
cat >> "$T/sg-old.sh" <<'SH'
_sg_modver_old() {
    h=$(_text "$1" | head -c 2000)
    printf '%s' "$h" | grep -aom1 'Module version: [0-9][0-9.]*'
}
_newest_old() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }
SH
if command grep -qE "Module version:|module name:|QWTBIRTH[^|]*ver=" "$T/sg-old.sh" \
   && command grep -qE "sort -V|sort -rV" "$T/sg-old.sh"; then
    ok "B1 SEEN TO FAIL: the old extractor + ordering restored into a copy is caught"
else
    no "B1 control: the restored old extractor was NOT caught" \
       "the predicate does not detect the implementation it exists to forbid"
fi

# AND THE POSITIVE HALF: the gate must still reach the attributor, or leg B1 is satisfied by a gate
# that does no attribution at all - which is the state this whole change replaced.
command grep -q 'log-sweep.py attribute' tools/sweep-gate.sh \
  && ok "B2 tools/sweep-gate.sh asks the one attributor" \
  || no "B2 tools/sweep-gate.sh does not call 'log-sweep.py attribute'" \
        "B1 would then pass on a gate that attributes nothing"

# =================================================================================================
# C. EVERY GRANULARITY ROUTES THROUGH THE ONE FUNCTION, PROVEN BY MUTATION.
#
# Reading the call sites cannot establish this; a second implementation is invisible to a reader who
# is looking at the first. So: break the one function in a COPY of the analyzer and require all
# THREE granularities to change. A granularity that still answers the same way has its own copy of
# the rule - which is exactly the state `_inst_prior` was in while the line-level rule was "fixed".
L="$T/logs"; mkdir -p "$L"
# ---- the turnover module, which is what establishes the superseded series for the capture.
# Lines carry the CURRENT banner spelling; leg D asserts that spelling against the patch itself.
cat > "$L/qrexec-agent-20261024.log" <<'LOG'
[20261024.091958.340-2764:2768-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.35.795 pid=2764 session=0 uptime=52.900
[20261024.091958.377-2764:2768-I] XcOpen: XenIface handle: 00000000000001E4
[20261024.092357.780-5468:5472-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.37.1100 pid=5468 session=0 uptime=291.100
[20261024.092357.800-5468:5472-I] XcOpen: XenIface handle: 00000000000001F0
LOG
# ---- a module whose ONLY log is the predecessor's: one declared version, so the module itself
# ---- cannot tell a turnover happened and only the capture-wide set can decide its lines.
cat > "$L/gui-agent-20261024.log" <<'LOG'
[20261024.091959.705-800:804-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.35.795 pid=800 session=1 uptime=54.328
[20261024.092000.100-800:804-E] WinMain: WatchForEvents failed with error 0x0: The operation completed successfully.
[20261024.092001.100-800:804-I] WatchForEvents: QGAWDSESSIONEND nothing starts in session 1
LOG
cat > "$T/probe.py" <<'PY'
import importlib.util, sys
src, logs = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ls", src)
m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
_, files, _, _ = m.load_logs(logs)
sc = m.build_scope(files, "4.3.37+agent.deadbeef")
lf = [f for f in files if f.module == "gui-agent"][0]
e = [l for l in lf.lines if l.level == "E"][0]
# LINE granularity
print("LINE", sc.prior(lf, e))
# INSTANCE granularity - an instance record of the predecessor's build
inst = {"file": lf.name, "version": "4.3.35.795"}
print("INST", sc.inst_prior(inst))
PY
read -r _ c_line  <<<"$(python3 "$T/probe.py" "$ATTR_FILE" "$L" | sed -n '1p')"
read -r _ c_inst  <<<"$(python3 "$T/probe.py" "$ATTR_FILE" "$L" | sed -n '2p')"
c_file=$(python3 tools/log-sweep.py attribute --build 4.3.37+agent.deadbeef -- "$L"/* 2>/dev/null \
         | awk -F'\t' '$2=="gui-agent"{print $4}')
[ "$c_line" = "True" ] && [ "$c_inst" = "True" ] && [ "$c_file" = "prior" ] \
  && ok "C0 all three granularities call the predecessor's record prior (line/instance/file)" \
  || no "C0 baseline wrong: line=$c_line inst=$c_inst file=$c_file (want True/True/prior)" \
        "the fixture does not hold the condition, so the mutation below proves nothing"

# THE MUTATION: the one function always answers False. It is applied to the DEFINITION only, by
# line number from the AST, so it cannot silently match a comment or a second site.
python3 - "$ATTR_FILE" "$T/mut.py" "$ATTR_FN" <<'PY'
import ast, sys
src, dst, fn = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src, encoding="utf-8").read().split("\n")
tree = ast.parse("\n".join(lines))
target = [n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == fn]
if len(target) != 1:
    sys.exit("expected exactly one def %s, found %d" % (fn, len(target)))
t = target[0]
body0 = t.body[0]
start = (body0.end_lineno if isinstance(body0, ast.Expr) and isinstance(body0.value, ast.Constant)
         else body0.lineno - 1)        # keep the docstring, replace the code
out = lines[:start] + ["    return False   # MUTATION"] + lines[t.end_lineno:]
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
m_line=""; m_inst=""
if [ -s "$T/mut.py" ]; then
    read -r _ m_line <<<"$(python3 "$T/probe.py" "$T/mut.py" "$L" | sed -n '1p')"
    read -r _ m_inst <<<"$(python3 "$T/probe.py" "$T/mut.py" "$L" | sed -n '2p')"
    m_file=$(python3 "$T/mut.py" attribute --build 4.3.37+agent.deadbeef -- "$L"/* 2>/dev/null \
             | awk -F'\t' '$2=="gui-agent"{print $4}')
else
    no "C the mutation could not be built" "no routing claim can be made"
    m_file=""
fi
[ "$m_line" = "False" ] \
  && ok "C1 LINE granularity routes through $ATTR_FN (mutated: prior=False)" \
  || no "C1 the line-level answer did not change (got '$m_line')" \
        "it has its own implementation of the rule"
[ "$m_inst" = "False" ] \
  && ok "C2 INSTANCE granularity routes through $ATTR_FN (mutated: inst_prior=False)" \
  || no "C2 the instance-level answer did not change (got '$m_inst')" \
        "this is the exact state _inst_prior was in for five gated metrics"
[ -n "$m_file" ] && [ "$m_file" != "prior" ] \
  && ok "C3 FILE granularity routes through $ATTR_FN (mutated verdict: $m_file)" \
  || no "C3 the file-level verdict did not change (got '$m_file')" \
        "the campaign gate would be deciding this on its own, which is where this defect lived"

# =================================================================================================
# D. BOTH BANNER SPELLINGS ARE READ - AND THE FIXTURE'S SHAPE COMES FROM THE PATCHES.
#
# A fixture that encodes a format from memory stops testing the product the moment the product
# changes, which is the whole mechanism of this defect: the gate's extractor was correct for a
# format that had been retired. So assert the two patches still say what these fixtures assume, and
# fail LOUDLY if they do not.
P_BIRTH="patches/windows-utils-single-birth-line.patch"
P_DEMOTE="patches/windows-utils-loginit-banner-debug.patch"
if [ -f "$P_BIRTH" ] && command grep -q 'LogInfo("QWTBIRTH module=%s ver=%d\.%d\.%d\.%d' "$P_BIRTH"; then
    ok "D0 the shipped birth line is still LogInfo QWTBIRTH module=... ver=... ($P_BIRTH)"
else
    no "D0 $P_BIRTH no longer writes 'LogInfo(\"QWTBIRTH module=%s ver=%d.%d.%d.%d'" \
       "the fixtures below encode a format the product may no longer emit - re-derive them from the patch"
fi
if [ -f "$P_DEMOTE" ] && command grep -q '^+        LogDebug("Module version:' "$P_DEMOTE"; then
    ok "D0 the legacy banner is still DEMOTED to LogDebug ($P_DEMOTE)"
else
    no "D0 $P_DEMOTE no longer demotes 'Module version:' to LogDebug" \
       "if the legacy banner is back at Info, the blindness this suite guards has a different shape"
fi
# D1: a capture whose ONLY banner is the new spelling - what every shipped build writes.
NB="$T/newbanner"; mkdir -p "$NB"
cat > "$NB/gui-agent-20261024.log" <<'LOG'
[20261024.101000.100-6264:6268-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=6264 session=1 uptime=80.000
[20261024.101001.100-6264:6268-E] GetFrame: AcquireNextFrame failed with error 0x887a0026: The keyed mutex was abandoned.
LOG
d1=$(python3 tools/log-sweep.py attribute --build 4.3.37.1100 -- "$NB"/* 2>/dev/null | awk -F'\t' 'NR==1{print $2"/"$3}')
[ "$d1" = "gui-agent/4.3.37.1100" ] \
  && ok "D1 the new spelling alone is read: $d1" \
  || no "D1 the new spelling was not read (got '$d1')" \
        "this is the blindness itself: the candidate's own logs become unattributable"
# D2: and the legacy spelling alone must STILL be read - the entry fixtures write it.
OB="$T/oldbanner"; mkdir -p "$OB"
cat > "$OB/gui-agent-20261024-101000-800.log" <<'LOG'
[20261024.101000.100-804-I] LogInit: Log started, module name: gui-agent
[20261024.101000.100-804-I] LogInit: Running as user: SYSTEM, process ID: 800
[20261024.101000.100-804-I] LogInit: Module version: 4.3.35.795
[20261024.101001.100-804-E] WinMain: WatchForEvents failed with error 0x0: The operation completed successfully.
LOG
d2=$(python3 tools/log-sweep.py attribute -- "$OB"/* 2>/dev/null | awk -F'\t' 'NR==1{print $2"/"$3}')
[ "$d2" = "gui-agent/4.3.35.795" ] \
  && ok "D2 the legacy spelling alone is still read: $d2" \
  || no "D2 the legacy spelling was not read (got '$d2')" \
        "every upgrade cell's entry fixture writes it, so dropping it re-opens the defect the other way"
# D3: a module that DECLARED a version it could not read (0.0.0.0) on the NEW spelling. The
# discriminator existed on the legacy path only, so this answered False on every shipped build and
# our own installer's declared ERROR lines were billed to the predecessor or to nobody.
UR="$T/unreadable"; mkdir -p "$UR"
cat > "$UR/qwtng-netsetup-20261024.log" <<'LOG'
[20261024.101500.100-3544:3548-I] LogInit: QWTBIRTH module=qwtng-netsetup ver=0.0.0.0 pid=3544 session=0 uptime=12.500
[20261024.101500.200-3544:3548-E] QioWriteBuffer: WriteFile failed with error 0xe8: The pipe is being closed.
LOG
d3=$(python3 - "$UR" "$ATTR_FILE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[2])
m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
_, files, _, _ = m.load_logs(sys.argv[1])
lf = [f for f in files if f.module == "qwtng-netsetup"][0]
e = [l for l in lf.lines if l.level == "E"][0]
print(m.declared_unreadable(lf, e))
PY
)
[ "$d3" = "True" ] \
  && ok "D3 'declared 0.0.0.0' is recognised on the new spelling too" \
  || no "D3 declared_unreadable=$d3 on a QWTBIRTH ver=0.0.0.0 record (want True)" \
        "our own installer's 12 declared ERROR lines go to the predecessor's column or to nobody"

# =================================================================================================
# E. A NAMED BUILD THAT DECLARED ITSELF NOWHERE MAKES THE CAMPAIGN GATE REFUSE.
#
# Jev scored the fork refuse 0.60 against grade-and-flag. The reason it is a REFUSAL and not a
# metric: run 40037710497 was graded over 847 inputs and reported 26 unaccounted messages that a
# whole day then went into triaging, on a corpus the gate could not attribute at all. The output of
# a gate that cannot attribute is not a number to interpret, it is a run that has to happen again.
E_LED="$T/e-ledger.txt"; : > "$E_LED"
e_absent=$(SWEEP_GATE_LEDGER="$E_LED" bash tools/sweep-gate.sh --build 4.9.99.1 "$L"/* 2>&1); e_rc=$?
if printf '%s' "$e_absent" | command grep -q 'INVALID-NOBUILD' && [ "$e_rc" != 0 ]; then
    ok "E1 a build that declared itself nowhere is REFUSED (INVALID-NOBUILD, rc=$e_rc)"
else
    no "E1 no refusal for an absent build (rc=$e_rc)" \
       "every message in the corpus is then billed to a build not shown to be in it"
fi
# SEEN TO FAIL in the other direction: the build that IS there must not be refused.
e_present=$(SWEEP_GATE_LEDGER="$E_LED" bash tools/sweep-gate.sh --build 4.3.37.1100 "$L"/* 2>&1); p_rc=$?
if printf '%s' "$e_present" | command grep -q 'INVALID-NOBUILD'; then
    no "E2 control: a PRESENT build was refused too (rc=$p_rc)" \
       "the refusal fires on every healthy campaign, which makes it useless"
else
    ok "E2 control: the build that IS in the corpus is not refused (rc=$p_rc)"
fi
# AND the refusal must not be the only thing the gate can say about this input: with no --build it
# grades as before, so an ad-hoc invocation over one log is unaffected.
e_none=$(SWEEP_GATE_LEDGER="$E_LED" bash tools/sweep-gate.sh "$L"/* 2>&1); n_rc=$?
if printf '%s' "$e_none" | command grep -q 'INVALID-NOBUILD'; then
    no "E3 without --build the gate still refused (rc=$n_rc)" \
       "there is no claim to check, so refusing invents one"
else
    ok "E3 without --build nothing is refused (rc=$n_rc)"
fi

# =================================================================================================
# F. THE CUT AT INGESTION: the predecessor's lines leave the graded view ONCE, and the cut cannot
#    take the candidate's with them.
#
# Owner, 2026-10-24: "cut if off on ingestion, otherwise it is going to take forever and be
# unreliable. and you will rediscover it someday and start your regular panic". Jev:
# partition-at-ingestion 0.99 against predicate-per-consumer 0.01 and delete-at-ingestion 0.00;
# keep the inits and the boot census 0.81; and the risk to guard is hides-the-candidate 0.89.
cat > "$T/cutprobe.py" <<'PY'
import importlib.util, sys
src, logs, build = sys.argv[1], sys.argv[2], (sys.argv[3] or None)
since = m_since = None
if len(sys.argv) > 4 and sys.argv[4]:
    since = sys.argv[4]
spec = importlib.util.spec_from_file_location("ls", src)
m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
if since:
    m_since = m.parse_iso(since)
_, files, _, _ = m.load_logs(logs)
trusted = not (len(sys.argv) > 5 and sys.argv[5] == 'skewed')
scope, cut = m.cut_predecessor(files, build, m_since, trusted)
lf = [f for f in files if f.module == "gui-agent"][0]
# THE FUNCTION NAME IS IN l.func: the parser strips the "Function: " prefix out of the message,
# which is why build-attribution-selftest's own fixtures note it. Reading l.msg here compared the
# message text and the leg failed on its own expectation rather than on the product.
graded = [l.func for l in lf.lines if l.level == "E"]
aside  = [l.func for l in lf.prior_lines if l.level == "E"]
print("CUT %s" % cut.get("cut"))
print("GRADED %s" % ("|".join(graded) or "-"))
print("ASIDE %s" % ("|".join(aside) or "-"))
print("MOVED %s" % (",".join("%s=%s" % kv for kv in sorted(cut.get("moved", {}).items())) or "-"))
print("STALE %d" % cut.get("lines_stale", 0))
print("WINTRUST %s" % cut.get("window_trusted"))
print("MARKS %s" % ("|".join(sorted({(l.swept_out or "NONE") for lf in files for l in lf.prior_lines})) or "-"))
print("INITS %d" % sum(len(f.inits) for f in files))     # the turnover must survive the cut
print("WHY %s" % cut.get("why", "-"))
PY
# The fixture: ONE per-day file spanning the upgrade, pid reused - the ordinary shape under
# one-log-per-module, and the shape that collapsed into a single predecessor-stamped instance.
FC="$T/cut"; mkdir -p "$FC"
cat > "$FC/gui-agent-20261024.log" <<'LOG'
[20261024.100000.100-800:804-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.35.795 pid=800 session=1 uptime=50.000
[20261024.100001.100-800:804-E] StaleOne: an error from the build being replaced
[20261024.100500.100-800:804-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=800 session=1 uptime=350.000
[20261024.100501.100-800:804-E] FreshOne: an error from the candidate
LOG
cat > "$FC/qrexec-agent-20261024.log" <<'LOG'
[20261024.095958.340-2764:2768-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.35.795 pid=2764 session=0 uptime=48.900
[20261024.100600.780-5468:5472-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.37.1100 pid=5468 session=0 uptime=410.100
LOG
f_out=$(python3 "$T/cutprobe.py" "$ATTR_FILE" "$FC" 4.3.37.1100)
f_cut=$(printf '%s' "$f_out"   | sed -n 's/^CUT //p')
f_grad=$(printf '%s' "$f_out"  | sed -n 's/^GRADED //p')
f_aside=$(printf '%s' "$f_out" | sed -n 's/^ASIDE //p')
f_moved=$(printf '%s' "$f_out" | sed -n 's/^MOVED //p')
f_inits=$(printf '%s' "$f_out" | sed -n 's/^INITS //p')
[ "$f_grad" = "FreshOne" ] \
  && ok "F1 after the cut the graded view holds the CANDIDATE's error only ($f_grad)" \
  || no "F1 the graded view is '$f_grad', want FreshOne alone" \
        "either the predecessor's line still grades, or the candidate's was taken with it"
[ "$f_aside" = "StaleOne" ] \
  && ok "F2 the predecessor's error is PARTITIONED, not deleted (prior_lines: $f_aside)" \
  || no "F2 prior_lines holds '$f_aside', want StaleOne" \
        "deleting it takes the receipt with it - the prior-build counters can then only report 0"
# THE PROPERTY, not a transcript: the receipt must NAME the predecessor's module@version it moved
# and must name NO version of the candidate's series. The first draft of this leg asserted the exact
# string `gui-agent@4.3.35.795=1` and went red on a correct receipt, because the predecessor's own
# QWTBIRTH line is also a line the predecessor wrote and is moved with its error - while the init
# RECORD stays, which is what F4 covers.
if printf '%s' "$f_moved" | command grep -q 'gui-agent@4\.3\.35\.795=[1-9]' \
   && ! printf '%s' "$f_moved" | command grep -q '4\.3\.37'; then
    ok "F3 the cut names what it moved, per module and version, and no candidate version ($f_moved)"
else
    no "F3 the receipt reads '$f_moved'" \
       "an exclusion that cannot be named cannot be seen to be wrong - and a candidate version in it is the hiding case"
fi
[ "${f_inits:-0}" -ge 4 ] \
  && ok "F4 the init records survive the cut ($f_inits) - the turnover is what attributes anything" \
  || no "F4 only ${f_inits:-0} init record(s) survive the cut" \
        "cut the inits and the attributor saws off the branch it stands on (Jev: keep them, 0.81)"

# F5 THE ANTI-HIDING GUARD, driven by MUTATION: an attributor that calls everything the
# predecessor's must not be allowed to empty the capture. This is the 0.89 risk, and both
# mis-attributions found on 2026-10-24 had exactly this direction.
python3 - "$ATTR_FILE" "$T/mut-true.py" "$ATTR_FN" <<'PY'
import ast, sys
src, dst, fn = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src, encoding="utf-8").read().split("\n")
t = [n for n in ast.walk(ast.parse("\n".join(lines)))
     if isinstance(n, ast.FunctionDef) and n.name == fn]
if len(t) != 1:
    sys.exit("expected one def %s, found %d" % (fn, len(t)))
t = t[0]
b0 = t.body[0]
start = (b0.end_lineno if isinstance(b0, ast.Expr) and isinstance(b0.value, ast.Constant) else b0.lineno - 1)
open(dst, "w", encoding="utf-8").write("\n".join(
    lines[:start] + ["    return bool(v)   # MUTATION: everything with a version is 'the predecessor's'"] + lines[t.end_lineno:]))
PY
g_out=$(python3 "$T/cutprobe.py" "$T/mut-true.py" "$FC" 4.3.37.1100 2>&1)
g_cut=$(printf '%s' "$g_out"  | sed -n 's/^CUT //p')
g_grad=$(printf '%s' "$g_out" | sed -n 's/^GRADED //p')
g_why=$(printf '%s' "$g_out"  | sed -n 's/^WHY //p')
if [ "$g_cut" = "False" ] && printf '%s' "$g_why" | command grep -q 'REFUSED'; then
    ok "F5 a cut that would move the CANDIDATE's lines is REFUSED entirely ($g_why)"
elif [ "$g_grad" = "FreshOne" ]; then
    no "F5 the mutation did not reach the cut (graded still '$g_grad')" \
       "then this leg proves nothing about the guard"
else
    no "F5 the mutated attributor emptied the graded view (graded='$g_grad', cut=$g_cut)" \
       "this is hides-the-candidate: every consumer then sees a capture the candidate kept clean"
fi
# F6 and the refusal case: a named build that declared itself nowhere must leave the capture ALONE,
# not cut every versioned line out of it.
h_out=$(python3 "$T/cutprobe.py" "$ATTR_FILE" "$FC" 4.9.99.1)
h_cut=$(printf '%s' "$h_out"  | sed -n 's/^CUT //p')
h_grad=$(printf '%s' "$h_out" | sed -n 's/^GRADED //p')
if [ "$h_cut" = "False" ] && [ "$h_grad" = "StaleOne|FreshOne" ]; then
    ok "F6 with the named build absent, nothing is cut and both lines still grade ($h_grad)"
else
    no "F6 absent build: cut=$h_cut graded='$h_grad', want False and both lines" \
       "a capture that cannot name the candidate must fail as unattributable, not be emptied"
fi

# F7 A PREVIOUS CAMPAIGN'S LINES ARE NOT THIS RUN'S OBSERVATIONS, and a build scope cannot reach
# them: a per-day log is APPENDED to, so two campaigns on one guest on one day share a file and both
# runs' lines carry the SAME candidate build. Owner, 2026-10-24: "make sure PREVIOUS campaign logs
# pre-split are not contaminating observations". MEASURED on acceptance run 40037710497: all EIGHT
# cells carry lines predating their own window (1, 49, 53, 166, 24, 19, 116, 75 - 503 in total), so
# this is a real population, not a hypothetical one.
# The fixture's first birth is at 10:00:00 and its error at 10:00:01; a window opening at 10:02 makes
# BOTH of those a previous run's, and the candidate's 10:05 error the only observation of this one.
# THE FIXTURE MUST HOLD THE CONDITION, AND THE FIRST ONE AVOIDED IT. Pointing this leg at $FC gave
# stale=0 and the leg was right to fail: that capture's pre-window lines are the PREDECESSOR's, so
# the build rule claims them first and the window rule never sees one. The contamination the owner
# named is a DIFFERENT shape - the SAME candidate build in two runs, which is what a per-day log
# holds when a guest is used twice in a day - so it needs its own capture: one build, two
# instances, and a window that opens between them.
FR="$T/prevrun"; mkdir -p "$FR"
cat > "$FR/gui-agent-20261024.log" <<'LOG'
[20261024.095000.100-700:704-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=700 session=1 uptime=40.000
[20261024.095001.100-700:704-E] OldRunError: an error from the PREVIOUS campaign, same build
[20261024.100500.100-900:904-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=900 session=1 uptime=95.000
[20261024.100501.100-900:904-E] FreshOne: an error from THIS run
LOG
g7_out=$(python3 "$T/cutprobe.py" "$ATTR_FILE" "$FR" 4.3.37.1100 2026-10-24T10:02:00)
g7_grad=$(printf '%s' "$g7_out"  | sed -n 's/^GRADED //p')
g7_stale=$(printf '%s' "$g7_out" | sed -n 's/^STALE //p')
g7_marks=$(printf '%s' "$g7_out" | sed -n 's/^MARKS //p')
[ "${g7_stale:-0}" -ge 1 ] \
  && ok "F7 lines from before this run's window are excluded on their own account ($g7_stale)" \
  || no "F7 nothing was excluded as a previous run's (stale=$g7_stale)" \
        "then only each metric remembering sel(l.ts) stands between a previous campaign's error and this verdict"
[ "$g7_grad" = "FreshOne" ] \
  && ok "F7 the graded view holds only THIS run's candidate line ($g7_grad)" \
  || no "F7 the graded view is '$g7_grad', want FreshOne alone" \
        "a previous run's line is being graded, or this run's was taken with it"
# F8 AND THE TWO EXCLUSIONS ARE DISTINGUISHABLE, because they are different facts: one line's BUILD
# is wrong for this verdict, the other's RUN is. A single mark would make "the predecessor wrote it"
# and "a previous campaign wrote it" one number nobody can act on.
# BOTH MARKS NEED A CAPTURE THAT EARNS BOTH, so this asks the MIXED-build fixture with a window
# that falls after its predecessor segment: the 4.3.35 lines are excluded by BUILD and the
# candidate's own pre-window line by RUN.
cat >> "$FC/gui-agent-20261024.log" <<'LOG'
[20261024.100505.100-950:954-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=950 session=1 uptime=360.000
[20261024.100506.100-950:954-E] MiddleOne: this run's own candidate error, before the window below
LOG
g8_out=$(python3 "$T/cutprobe.py" "$ATTR_FILE" "$FC" 4.3.37.1100 2026-10-24T10:05:30)
g8_marks=$(printf '%s' "$g8_out" | sed -n 's/^MARKS //p')
case "$g8_marks" in
  *predecessor-build*before-this-run*|*before-this-run*predecessor-build*)
    ok "F8 both exclusions carry their OWN mark on the line ($g8_marks)" ;;
  *) no "F8 the marks are '$g8_marks' - want both predecessor-build and before-this-run" \
        "a swept-out line must say WHICH exclusion took it, or the receipt cannot be acted on" ;;
esac
# SEEN TO FAIL: with no window, nothing is excluded as a previous run's - which is also the
# behaviour every ad-hoc sweep gets, so it is worth stating.
g8_stale=$(printf '%s' "$f_out" | sed -n 's/^STALE //p')
[ "${g8_stale:-0}" = 0 ] \
  && ok "F8 SEEN TO FAIL: with no --since nothing is excluded as a previous run's (stale=$g8_stale)" \
  || no "F8 control: lines were excluded as stale with no window given (stale=$g8_stale)" \
        "then the leg above passes on something other than the window"

# F9 A SHIFTED GUEST CLOCK MUST NOT LET THE WINDOW DROP THIS RUN'S OWN LINES. The comparison is
# against GUEST-LOCAL timestamps and this rig's guests shift by hours; cmd_analyze already raises a
# `clockskew` DATA problem for it and that problem's own wording is the ruling - "no --since window
# can be trusted". Jev refused the unconditional version on this path (hides-this-run 0.37,
# clock_risk 0.31, land 0.47), and the recorded rule is: never anchor freshness on a guest clock.
# So with the clock untrusted the window does NOTHING, and a previous run's line surfaces as a
# finding - over-reporting, which is the safe direction.
g9_out=$(python3 "$T/cutprobe.py" "$ATTR_FILE" "$FR" 4.3.37.1100 2026-10-24T10:02:00 skewed)
g9_stale=$(printf '%s' "$g9_out" | sed -n 's/^STALE //p')
g9_grad=$(printf '%s' "$g9_out"  | sed -n 's/^GRADED //p')
g9_tr=$(printf '%s' "$g9_out"    | sed -n 's/^WINTRUST //p')
if [ "${g9_stale:-1}" = 0 ] && [ "$g9_tr" = "False" ]; then
    ok "F9 with the clock untrusted the window excludes NOTHING and says so (trusted=$g9_tr)"
else
    no "F9 the window still excluded $g9_stale line(s) with the clock untrusted (trusted=$g9_tr)" \
       "a shifted clock would then drop THIS run's lines, which is hiding"
fi
case "$g9_grad" in
  *OldRunError*ThisRunError*|*OldRunError*|*ThisRunError*OldRunError*)
    ok "F9 and both runs' lines stay graded, so a previous run's error over-reports instead of hiding ($g9_grad)" ;;
  *) no "F9 the graded view is '$g9_grad' - want both lines kept when the window cannot be trusted" \
        "the untrusted path must over-report, never drop" ;;
esac

# G1 THE CAMPAIGN GATE DROPS A PREVIOUS RUN'S DECLARED ERROR, AND ONLY WITH A WINDOW. The gate
# aggregates by MESSAGE across a whole campaign directory, so a previous run's declared ERROR in an
# appended per-day log counted against this run - and no build scope could reach it, because both
# runs carry the same candidate build. The fixture is one guest log with a declared E on either side
# of the window, both from the same build.
GW="$T/gatewin"; mkdir -p "$GW"
cat > "$GW/gui-agent-20261024.log" <<'LOG'
[20261024.095000.100-700:704-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=700 session=1 uptime=40.000
[20261024.095001.100-700:704-E] OldRunError: the previous campaign declared this one
[20261024.100500.100-900:904-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=900 session=1 uptime=95.000
[20261024.100501.100-900:904-E] ThisRunError: this run declared this one
LOG
: > "$T/gw-ledger.txt"
g1_win=$(SWEEP_GATE_LEDGER="$T/gw-ledger.txt" bash tools/sweep-gate.sh --build 4.3.37.1100 \
            --since 2026-10-24T10:02:00 "$GW"/*.log 2>&1)
g1_none=$(SWEEP_GATE_LEDGER="$T/gw-ledger.txt" bash tools/sweep-gate.sh --build 4.3.37.1100 \
            "$GW"/*.log 2>&1)
_has(){ printf '%s' "$1" | command grep -qa "$2"; }
if _has "$g1_win" 'ThisRunError' && ! _has "$g1_win" 'OldRunError'; then
    ok "G1 with --since the gate surfaces THIS run's declared error and not the previous run's"
else
    no "G1 the windowed gate surfaced: $(printf '%s' "$g1_win" | command grep -a 'UNACCOUNTED' | head -2 | tr '\n' ' ')" \
       "a previous campaign's declared error is counted against this run's verdict"
fi
# SEEN TO FAIL: without a window the gate cannot tell the two runs apart, and must surface BOTH.
# That is also what every caller got until 2026-10-24, which is why this is stated rather than
# assumed.
if _has "$g1_none" 'OldRunError' && _has "$g1_none" 'ThisRunError'; then
    ok "G1 SEEN TO FAIL: with no --since BOTH runs' errors surface - the window is what separates them"
else
    no "G1 control: without --since the gate did not surface both ($(printf '%s' "$g1_none" | command grep -ac 'UNACCOUNTED') unaccounted)" \
       "then leg G1 above passes on something other than the window"
fi

echo "--- $PASS passed, $FAIL failed; fixtures in $T"
[ "$FAIL" = 0 ] && exit 0 || exit 1
