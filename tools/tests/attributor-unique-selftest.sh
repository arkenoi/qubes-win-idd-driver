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
import ast, subprocess, sys

def rule_shape(fn):
    """Does this function body carry the prior-build RULE's own shape?"""
    newest = False      # compares against a ["newest"] subscript
    vcount = False      # tests len(<something>["versions"]) against a literal
    for n in ast.walk(fn):
        if isinstance(n, ast.Subscript) and isinstance(n.slice, ast.Constant) and n.slice.value == "newest":
            newest = True
        if isinstance(n, ast.Compare) and isinstance(n.left, ast.Call) \
                and isinstance(n.left.func, ast.Name) and n.left.func.id == "len":
            for a in n.left.args:
                for s in ast.walk(a):
                    if isinstance(s, ast.Subscript) and isinstance(s.slice, ast.Constant) \
                            and s.slice.value == "versions":
                        vcount = True
    return newest and vcount

files = sys.argv[1:]
hits = []
for p in files:
    try:
        tree = ast.parse(open(p, encoding="utf-8").read())
    except (SyntaxError, OSError):
        continue
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and rule_shape(n):
            hits.append("%s:%d:%s" % (p, n.lineno, n.name))
for h in sorted(hits):
    print(h)
PY
mapfile -t PYFILES < <(git ls-files '*.py' 2>/dev/null)
[ "${#PYFILES[@]}" -ge 5 ] \
  && ok "A0 the scan has a population: ${#PYFILES[@]} tracked .py file(s)" \
  || no "A0 only ${#PYFILES[@]} tracked .py file(s) found - the scan would pass on nothing" \
        "an empty population is a green that measured nothing"

mapfile -t HITS < <(python3 "$T/scan.py" "${PYFILES[@]}")
if [ "${#HITS[@]}" = 1 ] && [[ "${HITS[0]}" == *":$ATTR_FN" ]]; then
    ok "A1 exactly one implementation of the rule: ${HITS[0]}"
else
    no "A1 ${#HITS[@]} implementation(s) of the prior-build rule: ${HITS[*]}" \
       "each extra copy is a consumer the next fix will miss - that is how this was re-fixed four times"
fi

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
mapfile -t BASE < <(python3 "$T/scan.py" "$ATTR_FILE")
mapfile -t HITS2 < <(python3 "$T/scan.py" "$T/inject/log-sweep.py")
# RELATIVE TO THE BASELINE, not to 1: the control's job is to show the scan DETECTS an added copy,
# and an absolute number here would also fail whenever leg A1 fails - one defect, two red legs, and
# the control's own meaning lost. (It read `= 2` on the first run, which reported the control broken
# when what was actually true was that A1 had found a real fourth site.)
if [ "${#HITS2[@]}" = "$(( ${#BASE[@]} + 1 ))" ]; then
    ok "A1 SEEN TO FAIL: an injected second copy is caught (${#BASE[@]} -> ${#HITS2[@]} hits)"
else
    no "A1 control: the injected copy was NOT caught (${#BASE[@]} -> ${#HITS2[@]} hits)" \
       "the scan cannot see a fourth implementation, so leg A1 proves nothing"
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
b_hits=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    # the banner, in either spelling - what the parse would read
    command grep -qE "Module version:|module name:|QWTBIRTH[^|]*ver=" "$f" || continue
    # an ordering or inequality over versions - what the decision would do
    command grep -qE "sort -V|sort -rV" "$f" || continue
    b_hits="$b_hits $f"
done < <(git ls-files '*.sh' '*.ps1' '*.cmd' 2>/dev/null)
[ -z "$b_hits" ] \
  && ok "B1 no shell/powershell script both reads a module banner and orders versions" \
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

echo "--- $PASS passed, $FAIL failed; fixtures in $T"
[ "$FAIL" = 0 ] && exit 0 || exit 1
