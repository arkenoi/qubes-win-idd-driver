#!/bin/bash
# sweep-gate.sh - NO ERROR-SHAPED LINE IN A HARNESS LOG MAY BE READ BY A MODEL AND WAVED THROUGH.
#
#   tools/sweep-gate.sh <harness-log> [<harness-log> ...]
#
# Exit: 0 every error-shaped line is DECLARED; 1 at least one is not; 2 nothing could be read.
#
# WHY THIS EXISTS (owner, 2026-10-14, twice in one night, the second time in capitals).
# A quick-upgrade log carried four lines reading
#     "no qrexec for 135s (cause UNKNOWN - this sampler cannot see why)"
# and one reading
#     "WARNING: ... records no sealed_version - ordering unchecked"
# and I called the first "expected installer behaviour" and skipped the second, in both cases
# WITHOUT checking. The install happened to be fine. That is luck, not method: the same night, the
# defect that blocked the 4.3.36 release was a transport failure whose evidence sat in guest logs
# that nothing swept, while I read lines by hand and attributed the symptom to the product twice.
#
# `mgmt/harness/log-sweep.sh` already does this properly for the GUEST's logs - and 50 of the
# harnesses that drive a guest never call it, including matrix.sh, quick-upgrade.sh, wu-e2e.sh and
# template-update-test.sh, which is every harness that grades a release. This gate covers the other
# half: the HARNESS'S OWN output, which no instrument looked at at all.
#
# THE RULE: an error-shaped line is either matched by a committed DECLARED pattern - which carries a
# reason, in the file, reviewable - or it fails the run. There is no third option and no judgement
# call at read time. A line nobody has decided about is a finding.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
DECLARED="${SWEEP_GATE_DECLARED:-mgmt/harness/harness-log-declared.txt}"
[ $# -ge 1 ] || { echo "usage: $0 <harness-log> [...]" >&2; exit 2; }
[ -f "$DECLARED" ] || { echo "sweep-gate: REFUSING - no declared list at $DECLARED" >&2; exit 2; }

# The shapes that mean "something went wrong, or something could not be determined". `cause UNKNOWN`
# is in here deliberately: a sampler saying it cannot see why is not a benign line, it is a gap.
SHAPES='ERROR|FAIL|FATAL|WARNING|WARN:|refus|REFUS|cannot|could not|cause UNKNOWN|UNKNOWN -|timed out|timeout|TIMEOUT|abort|ABORT|INVALID|unreadable|no qrexec|not Halted|exception|Exception|Traceback'

# Declared patterns: one extended-regex per line, `#` comments and blanks ignored. Each line in the
# file must carry a trailing `# why: ...` so a declaration can never be a bare silencer.
mapfile -t pats < <(grep -vE '^\s*(#|$)' "$DECLARED" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//' | grep -v '^$')
undeclared=0; scanned=0
for log in "$@"; do
    [ -f "$log" ] || { echo "sweep-gate: $log does not exist" >&2; exit 2; }
    scanned=$((scanned+1))
    while IFS= read -r line; do
        keep=1
        for p in "${pats[@]}"; do
            if printf '%s' "$line" | grep -qE "$p"; then keep=0; break; fi
        done
        if [ "$keep" = 1 ]; then
            [ "$undeclared" = 0 ] && echo "SWEEP-GATE: undeclared error-shaped line(s):"
            undeclared=$((undeclared+1))
            printf '  %s: %s\n' "$(basename "$log")" "$(printf '%s' "$line" | cut -c1-160)"
        fi
    done < <(grep -aE "$SHAPES" "$log" 2>/dev/null)
done

if [ "$undeclared" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT logs=$scanned undeclared=$undeclared"
    echo "  Each line above is either a real finding or a pattern that belongs in $DECLARED WITH a"
    echo "  '# why:' reason. Reading it and moving on is not one of the options."
    exit 1
fi
echo "SWEEP-GATE-RESULT logs=$scanned undeclared=0"
