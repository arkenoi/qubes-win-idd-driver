#!/usr/bin/env bash
# Classify what a guest's STAGE TRANSITION actually did to the Xen domain: destroyed it (the defined
# path) or warm-reset it in place (the leak).
#
# WHY THIS EXISTS - two instruments were wrong before it:
#
#  1. prime-run's `restarts` counter is a 20 s poll, and a domain destroy can be shorter than that.
#     MEASURED 2026-09-09: runs 3 and 4 of the determinism campaign recorded restarts=0 - the warm
#     reset signature - while a 2 s watcher caught Dying -> Halted -> Running with a NEW xid. The
#     counter is not wrong about what it saw; it is blind between polls. Every historical figure we
#     have (the "8 destroy / 6 warm" control over 14 runs) was measured with ONLY this instrument,
#     so an unknown number of those six "warm resets" were short halts it missed. Those runs cannot
#     be re-checked: no xid was ever recorded for them (prime-run has never logged one).
#
#  2. The first xid classifier asked "did the domain halt at all, and did the xid change at all?"
#     over the WHOLE run. That is satisfied trivially, because a run legitimately contains THREE
#     domain generations: the leftover being removed and the clone created, then the stage-1
#     transition, then the stage-2 transition. It could not return WARM for any real run - a check
#     that cannot fail, in the instrument built to judge whether a fix works.
#
# WHAT THIS MEASURES INSTEAD. Anchor on the RECREATE - the last `none` in the trace, i.e. the moment
# the qube did not exist because prime-run had removed it - and look only after that point. From
# there the install runs, and each stage transition ends one domain generation and starts the next:
#
#     …none… -> Running X          the clone starts; the install begins
#     X -> (Dying|Halted|…) -> Y   a transition that DESTROYED the domain: new xid
#     X -> …still X…               a transition the domain SURVIVED: warm reset, same xid
#
# So: count DISTINCT Running xids after the recreate.
#     >= 2  the domain went down and came back at least once  -> DESTROY (the defined path)
#     == 1  the install ran to completion without the domain ever being replaced -> WARM (the leak)
#     == 0  no domain observed after the recreate -> UNKNOWN (the run did not happen; do not grade)
#
# Usage:  classify-transition.sh <xidtrace.log> [...]
#         classify-transition.sh --selftest
#
# Trace format (one line per observed change), as written by the campaign watcher:
#     HH:MM:SS <vm>:<state>:xid=<n|->
set -uo pipefail

classify_one() {
    # stdin: a trace. Echoes "<verdict> xids=[...] n=<count>".
    awk '
        # Anchor: remember the position of the LAST "none" (qube removed => recreate follows).
        { line[NR] = $0; if ($0 ~ /:none:/) anchor = NR }
        END {
            if (NR == 0) { print "UNKNOWN xids=[] n=0 reason=empty-trace"; exit }
            # No "none" means the trace never saw the recreate, so we cannot tell an install
            # generation from a leftover one. Fail closed rather than guess.
            if (anchor == 0) { print "UNKNOWN xids=[] n=0 reason=no-recreate-anchor"; exit }
            n = 0; out = ""
            for (i = anchor; i <= NR; i++) {
                if (match(line[i], /xid=[0-9]+/)) {
                    x = substr(line[i], RSTART + 4, RLENGTH - 4)
                    if (x != last) { seen[++n] = x; last = x; out = out x " " }
                }
            }
            v = (n >= 2) ? "DESTROY" : ((n == 1) ? "WARM" : "UNKNOWN")
            r = (n == 0) ? " reason=no-domain-after-recreate" : ""
            printf "%s xids=[%s] n=%d%s\n", v, out, n, r
        }'
}

if [ "${1:-}" = "--selftest" ]; then
    # THE CLASSIFIER MUST BE ABLE TO RETURN EVERY VERDICT. The one it was previously incapable of
    # returning is WARM - the whole point of the measurement - so that fixture comes first.
    fail=0
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

    # A real DESTROY run (shape of campaign run 4: recreate, then two transitions).
    cat >"$t/destroy" <<'EOF'
17:15:58 win11-acc:Running:xid=6277
17:16:03 win11-acc:Halted:xid=-
17:16:08 win11-acc:none:xid=-
17:16:19 win11-acc:Running:xid=6279
17:20:34 win11-acc:Halted:xid=-
17:20:39 win11-acc:Running:xid=6281
17:25:58 win11-acc:Running:xid=6283
EOF
    # A WARM run: recreated, started ONCE, and the domain is never replaced again - the guest
    # reboots inside the same domain, so the xid never moves.
    cat >"$t/warm" <<'EOF'
17:15:58 win11-acc:Running:xid=6277
17:16:03 win11-acc:Halted:xid=-
17:16:08 win11-acc:none:xid=-
17:16:19 win11-acc:Running:xid=6279
17:59:00 win11-acc:Running:xid=6279
EOF
    # Leftover generations BEFORE the recreate must not count - this is the contamination that made
    # the previous classifier unable to fail.
    cat >"$t/leftover-only" <<'EOF'
17:04:36 win11-acc:Running:xid=6271
17:04:40 win11-acc:Halted:xid=-
17:04:45 win11-acc:none:xid=-
17:05:05 win11-acc:Running:xid=6273
EOF
    cat >"$t/no-anchor" <<'EOF'
17:04:36 win11-acc:Running:xid=6271
17:04:40 win11-acc:Halted:xid=-
17:05:05 win11-acc:Running:xid=6273
EOF
    : >"$t/empty"

    check() { # <fixture> <expected-verdict>
        got=$(classify_one <"$t/$1"); v=${got%% *}
        if [ "$v" = "$2" ]; then echo "PASS  $1 -> $got"
        else echo "FAIL  $1 -> $got (want $2)"; fail=$((fail+1)); fi
    }
    check destroy       DESTROY
    check warm          WARM
    check leftover-only WARM      # only ONE generation after the recreate, however much came before
    check no-anchor     UNKNOWN
    check empty         UNKNOWN
    echo "--- $( [ $fail -eq 0 ] && echo 'ALL PASS' || echo "$fail FAILED" )"
    exit $fail
fi

[ $# -gt 0 ] || { echo "usage: $0 <xidtrace.log> [...] | --selftest" >&2; exit 2; }
rc=0
for f in "$@"; do
    [ -f "$f" ] || { echo "MISSING  $f"; rc=1; continue; }
    printf '%-28s %s\n' "$(basename "$f")" "$(classify_one <"$f")"
done
exit $rc
