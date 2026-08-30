#!/bin/bash
# CAMPAIGN COMPLETION GATE — computes the verdict from the ledger instead of leaving it to whoever
# is writing the summary.
#
# WHY THIS EXISTS. On 2026-08-30 I reported "acceptance protocol complete" for a campaign that
# contained a product FAIL, two INVALID-PRECONDITION cells, one INVALID-VACUOUS, one INCONCLUSIVE,
# two blocked cells, and 183 of 229 passes with no fail-proof on record. Every one of those was
# written down honestly in the ledger; the SUMMARY still said complete, because the summary was
# prose and prose lets you average. This makes the verdict arithmetic.
#
#   tools/campaign-verdict.sh <verdicts.tsv> [instrument-proofs.md]
#
# Exit 0 = COMPLETE. Exit 1 = EXECUTED WITH GAPS (and it names them). Exit 2 = unusable input.
#
# THE RULE, and it is not negotiable: a campaign is COMPLETE only when the ledger contains ZERO
# FAIL, ZERO INVALID-*, ZERO INCONCLUSIVE, ZERO BLOCKED, and every PASS has a registry entry.
# Anything else is "EXECUTED WITH GAPS", and the gaps go in the summary's FIRST paragraph, not an
# appendix. A campaign that found a real defect is a SUCCESSFUL campaign - but it is not a complete
# one, and the report must not open with a number that hides it.
set -uo pipefail
LEDGER="${1:?usage: $0 <verdicts.tsv> [instrument-proofs.md]}"
[ -f "$LEDGER" ] || { echo "UNUSABLE: no ledger at $LEDGER"; exit 2; }

python3 - "$LEDGER" <<'PY'
import sys, collections
p = sys.argv[1]
rows = []
for i, line in enumerate(open(p).read().splitlines()):
    if i == 0 or not line.strip():
        continue
    f = line.split('\t')
    if len(f) >= 3:
        rows.append({'cell': f[0], 'check': f[1], 'verdict': f[2],
                     'detail': f[3] if len(f) > 3 else '', 'ev': f[4] if len(f) > 4 else ''})

counts = collections.Counter(r['verdict'] for r in rows)
print(f"ledger: {len(rows)} checks")
for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
    print(f"  {k:<22} {v}")

blockers = collections.OrderedDict()
def collect(name, pred):
    hits = [r for r in rows if pred(r)]
    if hits:
        blockers[name] = hits

# SUPERSEDED-BY:<evidence> means "this run was invalid, but a VALID re-run of the same check
# exists". That is only true if the re-run is actually on the ledger, so verify it rather than
# trusting the label - otherwise 'superseded' becomes the way gaps get hidden, which is precisely
# the failure this file was written to stop.
valid = {}
for r in rows:
    if not (r['verdict'].startswith(('INVALID', 'FAIL', 'SUPERSEDED', 'INCONCLUSIVE', 'BLOCKED', 'RETRACTED'))):
        valid.setdefault(r['cell'], []).append(r)

def superseded_unbacked(r):
    if not r['verdict'].startswith('SUPERSEDED-BY:'):
        return False
    ev = r['verdict'].split(':', 1)[1].strip()
    for c in valid.get(r['cell'], []):
        if c['ev'] == ev and c['check'] == r['check']:
            return False   # a valid row for the SAME cell AND SAME check from that run exists
    return True            # the label points at nothing that re-tested this check - still a gap

def retracted_unreplaced(r):
    # A RETRACTED verdict says "this result was wrong". If nothing valid replaced it, the check has
    # NO result at all - which is a gap, not a resolution. Without this, retracting a row is a way to
    # make a gap disappear, exactly as an unbacked SUPERSEDED would be. (U1's scan-phase,
    # available-populated and updates-available-to-dom0 were all retracted on 2026-08-30 when the
    # root cause was falsified, and nothing has re-tested them since.)
    if not r['verdict'].startswith('RETRACTED'):
        return False
    for c in valid.get(r['cell'], []):
        if c['check'] == r['check']:
            return False
    return True

collect('RETRACTED with nothing valid replacing it', retracted_unreplaced)
collect('SUPERSEDED but NOT backed by a valid re-run', superseded_unbacked)
collect('FAIL (product defect)',        lambda r: r['verdict'] == 'FAIL')
collect('FAIL-MINE (instrumentation)',  lambda r: r['verdict'] == 'FAIL-MINE')
collect('INVALID (cell did not run)',   lambda r: r['verdict'].startswith('INVALID'))
collect('INCONCLUSIVE',                 lambda r: r['verdict'] == 'INCONCLUSIVE')
collect('BLOCKED / SKIPPED',            lambda r: r['verdict'].startswith(('BLOCKED', 'SKIPPED')))

unproven = counts.get('PASS-UNPROVEN', 0)

print()
if not blockers and unproven == 0:
    print("VERDICT: COMPLETE")
    print("  zero FAIL, zero INVALID, zero INCONCLUSIVE, and every PASS has a fail-proof on record.")
    sys.exit(0)

print("VERDICT: EXECUTED WITH GAPS  -- this campaign is NOT complete")
print()
print("These belong in the FIRST paragraph of the summary, not an appendix:")
for name, hits in blockers.items():
    print(f"  {name}: {len(hits)}")
    for h in hits[:6]:
        print(f"      {h['cell']} / {h['check']}  -- {h['detail'][:90]}")
    if len(hits) > 6:
        print(f"      ... and {len(hits)-6} more")
if unproven:
    print(f"  PASS-UNPROVEN: {unproven}")
    print("      succeeded but never seen to fail. H5: a check absent from the fail-proof")
    print("      registry can NEVER emit plain PASS. Report these separately, always.")
print()
print("A campaign that found a real defect is a SUCCESSFUL campaign. It is still not a COMPLETE one.")
sys.exit(1)
PY
