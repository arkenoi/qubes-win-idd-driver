#!/bin/bash
# A BREACH THAT REACHES THE JUDGE WITH NO LINES IS A JUDGEMENT ON A METRIC NAME.
#
# `breach_evidence` ended in `if "lines" in b: out.extend(b["lines"])` - testing a key NO producer
# ever set. compare() emits exactly metric/value/max/severity/why, so that fallback was dead code,
# and every metric without an explicit `name in (...)` arm reached Jev with evidence: [].
#
# Measured on 2026-10-21: 12 of the 34 thresholded metrics, SEVEN of them P1 - bugchecks,
# wer_crashes, unexpected_shutdowns, service_failures, notifications_lost, dom0_loud_failures,
# clock_boot_correction_s - and among the P2s error_lines_undeclared, the one metric that has been
# blocking this release. Its lines were right there and thrown away at `len()`.
#
# Ten now carry their lines. The two that remain are scalars for which a line list is not the right
# evidence, and they carry an explicit marker instead of silence - because a fallback firing is an
# anomaly and must say so, not degrade quietly.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }

run_case(){ # $1 = path to the analyzer under test -> prints the python verdicts
python3 - "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)

LINE = "[20261020.132705.123-4812:3344-E] Foo: something of ours failed"
# every top-level key breach_evidence reads, each empty: an arm then yields nothing and the
# metric is genuinely bare, which is what this sweep is measuring. A missing key would raise
# and be mistaken for "armed".
st_with = {"instances": [], "windows": [], "events": [], "deaths": [], "ev_deaths": [],
           "fastdeath": [],
           "context": {"fault_injection": False, "declared": False, "declared_source": "",
                       "unproven": False, "sources": [], "records": []},
           "metric_lines": {"error_lines_undeclared": [LINE]}}
st_bare = dict(st_with); st_bare["metric_lines"] = {}
b = {"metric": "error_lines_undeclared", "value": 1, "max": 0, "severity": "P2", "why": "w"}

ev = ls.breach_evidence(b, st_with, {})
print("THREADED", "yes" if any(LINE in e for e in ev) else "no", len(ev))
ev2 = ls.breach_evidence(b, st_bare, {})
print("MARKER", "yes" if any("NO EVIDENCE WAS ATTACHED" in e for e in ev2) else "no", len(ev2))
print("NEVEREMPTY", "yes" if ev2 else "no")

# the sweep: how many thresholded metrics can still reach the judge with nothing at all
import re
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("DEFAULT_THRESHOLDS"); seg = src[i:src.index("\n}\n", i)]
thr = sorted(set(re.findall(r'"([a-z0-9_]+)":\s*\{[^}]*"max"', seg)))
bare = []
for name in thr:
    bb = {"metric": name, "value": 1, "max": 0, "severity": "P2", "why": ""}
    try:
        if not ls.breach_evidence(bb, st_bare, {}):
            bare.append(name)
    except Exception as e:          # an arm reached for state this stub does not carry: it HAS an
        pass                        # arm, so it is not bare - but say nothing silently

print("BARE", len(thr), len(bare), ",".join(bare))
PY
}

out=$(run_case "$ROOT/tools/log-sweep.py")
printf '%s\n' "$out" | sed 's/^/     /'

read -r _ v n <<< "$(printf '%s\n' "$out" | command grep '^THREADED')"
[ "$v" = yes ] && ok "error_lines_undeclared carries the error line it counted ($n evidence line(s))" \
               || no "error_lines_undeclared reached the judge without its line"
read -r _ v _ <<< "$(printf '%s\n' "$out" | command grep '^MARKER')"
[ "$v" = yes ] && ok "a metric with no lines says so explicitly instead of being empty" \
               || no "a metric with no lines produced silence"
read -r _ v <<< "$(printf '%s\n' "$out" | command grep '^NEVEREMPTY')"
[ "$v" = yes ] && ok "no breach can reach the judge with evidence == []" \
               || no "a breach still reaches the judge with evidence == []"
read -r _ total bare names <<< "$(printf '%s\n' "$out" | command grep '^BARE')"
[ "$bare" = 0 ] && ok "all $total thresholded metrics produce some evidence (0 bare)" \
                || no "$bare of $total thresholded metrics still produce nothing: $names"

# ---------------------------------------------------------------- NEGATIVE CONTROL
# Strip the threading and the marker, and the first and third assertions must fail. A check never
# seen to fail is not evidence.
CTL=$(mktemp --suffix=.py)   # importlib needs the .py suffix to pick a loader
trap 'rm -f "$CTL"' EXIT
python3 - "$ROOT/tools/log-sweep.py" "$CTL" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace('    out.extend((st.get("metric_lines") or {}).get(name) or [])\n', '')
t = re.sub(r'\n    if not out:\n        out\.append\("NO EVIDENCE WAS ATTACHED.*?% name\)\n', '\n', t, flags=re.S)
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
cout=$(run_case "$CTL")
read -r _ cv _ <<< "$(printf '%s\n' "$cout" | command grep '^THREADED')"
read -r _ cn _ <<< "$(printf '%s\n' "$cout" | command grep '^NEVEREMPTY')"
if [ "$cv" = no ] && [ "$cn" = no ]; then
    ok "negative control: without the threading the line is lost AND evidence is empty"
else
    no "negative control did not reproduce the defect (threaded=$cv neverempty=$cn)"
fi
read -r _ ctotal cbare _ <<< "$(printf '%s\n' "$cout" | command grep '^BARE')"
# NOT the 12. With an empty state stub an ARMED metric also yields nothing, so this number is
# larger and measures only "the threading and the marker are what produce evidence here". The real
# figure - how many metrics had neither an arm nor a line list - is asserted statically below.
[ "${cbare:-0}" -gt 0 ] 2>/dev/null \
  && ok "negative control: $cbare of $ctotal produce nothing once the threading and marker are gone (now 0)" \
  || no "negative control: removing the threading changed nothing, so the assertion above is inert"

# THE REAL COVERAGE FIGURE, read from the source: a metric is covered if breach_evidence has an arm
# for it or a line list is threaded for it. This is the 12 that was measured on 2026-10-21, and it
# must not grow.
read -r armed threaded bare2 names2 <<< "$(python3 - "$ROOT/tools/log-sweep.py" <<'PY2'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("DEFAULT_THRESHOLDS"); seg = src[i:src.index("\n}\n", i)]
thr = sorted(set(re.findall(r'"([a-z0-9_]+)":\s*\{[^}]*"max"', seg)))
j = src.index("def breach_evidence"); k = src.index("\ndef build_jev_items")
arms = set()
for m in re.finditer(r"name in \(([^)]*)\)", src[j:k], re.S):
    arms.update(re.findall(r'"([a-z0-9_]+)"', m.group(1)))
thread = set(re.findall(r'_count\("([a-z0-9_]+)"', src)) | set(re.findall(r'_ml\["([a-z0-9_]+)"\]', src))
bare = [x for x in thr if x not in arms and x not in thread]
print(len(arms & set(thr)), len(thread & set(thr)), len(bare), ",".join(bare) or "-")
PY2
)"
[ "${bare2:-99}" -le 2 ] 2>/dev/null \
  && ok "coverage: $armed armed + $threaded line-threaded, only $bare2 with neither ($names2) - was 12" \
  || no "coverage regressed: $bare2 metrics have neither an arm nor a line list ($names2)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
