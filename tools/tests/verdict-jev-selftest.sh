#!/usr/bin/env bash
# verdict-jev-selftest.sh - offline proof matrix for tools/verdict-jev.py (PLAN-acceptance-optimization section 5:
# every error is evaluated; Claude only when Jev returns novel or insufficient-evidence on at least one item).
#
# No network: a stub judge stands in for tools/jev.py and answers by name - every item 'known-class' at a chosen
# confidence, or 'novel', or it exits 2 (the instrument did not run). The inputs are a log-sweep report in the real
# analyzer's shape and an activity snapshot in the collector's shape. Every check is also seen to FAIL on a copy of
# the tool with ONE `# GUARD:<knob>` line replaced by the defect beside it.
#
#   complete   the rubric carries EVERY item: the breach, both NEW signatures, the known-defect E signature the
#              baseline already catalogues, both harness error lines, plus the one overall question (knob: prefilter)
#   state      the state text carries the snapshot's last qrexec pair, harness command and module tails, and the catalogue
#   known      all known-class at 0.9 and overall noul 0.1 -> rc 0
#   novel      one novel item -> rc 1 and verdict.json names it
#   floor      known-class at 0.3 is below the floor -> rc 1 (knob: conffloor)
#   overall    all known-class but the judge's overall noul 0.9 -> rc 1 (knob: overallor)
#   exit2      the judge exits 2 -> rc 2, never a pass (knob: jev2)
#   declared   a declaration that matches an item keeps it out of the rubric and records it; one that matches
#              nothing -> rc 3 (knob: declunmatched)
#   data       a sweep report with status DATA -> rc 2 (knob: dataispass)
#   inputs     an unreadable snapshot -> rc 2; no inputs at all -> rc 2
#
#   VERDICT_SELFTEST_OUT=<dir>  keep fixtures and outputs (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tools/verdict-jev.py"
T="${VERDICT_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/verdict-selftest-XXXXXX")}"
[ -n "${VERDICT_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran"; exit 2; }

# ---- fixtures: a sweep report in the analyzer's shape, a snapshot in the collector's shape ------------------------
python3 - "$T" <<'PY'
import json, sys
T = sys.argv[1]
sig = lambda key, fam, lvl, n, base=None, jev=None: {"key": key, "family": fam, "level": lvl, "count": n, "max_per_boot": n, "per_boot": {"1": n},
    "files": ["Q:\\Qubes Logs\\x.log"], "first": "2026-10-13 10:00:00.000", "last": "2026-10-13 10:00:05.000", "baseline": base, "match": "exact" if base else None,
    "examples": ["[20261013.100000.000-1:2-%s] F: %s" % (lvl, key.split("|", 2)[-1])], "context": [], "jev": jev}
known_base = {"status": "known-defect", "issue": "shutdown-death-relaunch", "reason": "the agent dies 0x40010004 at session end and is relaunched", "max_per_boot": 3}
rep = {"version": 9, "status": "FINDINGS", "rc": 1, "header": {"label": "fx"},
       "breaches": [{"metric": "errors_during_requested_stop", "value": 2, "max": 0, "severity": "P2", "why": "no ERROR line between asked and gone",
                     "jev": {"choice": "defect", "confidence": 1.0}}],
       "new": [sig("agent|E|BrokerRegister: QGABROKERREGFAIL hwnd 0xH", "agent", "E", 1, None, {"choice": "defect", "confidence": 0.7}),
               sig("events|I|Task Scheduler completed task QwtClockSync", "events", "I", 1, None, {"choice": "expected", "confidence": 0.5})],
       "rose": [], "out_of_context": [], "judged_defects": ["b01_errors_during_requested_stop"], "known_defects_present": [],
       "signatures": {"watchdog|E|WatchdogThread: Process 'gui-agent.exe' (PID N) exited with code 0xH without this service asking it to":
                      sig("watchdog|E|WatchdogThread: Process 'gui-agent.exe' (PID N) exited with code 0xH without this service asking it to", "watchdog", "E", 3, known_base, {"choice": "defect", "confidence": 0.9}),
                      "bridge|W|PUSH NotificationChanged unavailable": sig("bridge|W|PUSH NotificationChanged unavailable", "bridge", "W", 1, {"status": "expected", "reason": "Jev: expected 0.96"}, {"choice": "expected", "confidence": 0.96}),
                      "agent|I|PerfInit: QGAPROTO off": sig("agent|I|PerfInit: QGAPROTO off", "agent", "I", 1, {"status": "expected", "reason": "noise"}, None),
                      "agent|E|BrokerRegister: QGABROKERREGFAIL hwnd 0xH": sig("agent|E|BrokerRegister: QGABROKERREGFAIL hwnd 0xH", "agent", "E", 1, None, None)},
       "metrics": {"error_lines_undeclared": 1}, "jev": {"calls": [], "rc": 0}}
json.dump(rep, open(T + "/report.json", "w"), indent=1)
d = dict(rep); d["status"] = "DATA"; d["rc"] = 3; d["data_problems"] = [["missing", "gui-agent-x.log", "listed but absent"]]
json.dump(d, open(T + "/report-data.json", "w"), indent=1)
snap = {"version": 1, "vm": "win11-cell", "reason": "selftest", "power_state_at_collection": "Running",
        "harness_cmd": {"cmd": "mgmt/harness/quick-upgrade.sh pkg win11-cell win11r", "source": "argument"},
        "last_qrexec_pair": {"request_ts": "2026-10-13 10:00:30.000", "request": "qrexec-wrapper.exe 10858|515|user|6|cmd /c echo QREADY", "outcome": {"line": "[20261013.100030.900-5804:5456-I] WrapperCtrlHandler: child exited with code 0x0"}},
        "last_window": {"line": "[20261013.100020.000-3228:3364-I] SendWindowUnmap: Unmapping window 0x301c4", "hwnd": "0x301c4"},
        "clock_skew": {"skew_s": 3, "guest_utc": "2026-10-13T10:00:00Z"},
        "power_timeline": [{"utc": "2026-10-13T09:59:30", "state": "eventlog-started (boot)", "source": "guest-event"}],
        "module_logs": {"gui-agent-20261013.log": {"family": "agent", "lines": 11, "last_ts": "2026-10-13 10:00:21.000", "tail": ["[20261013.100021.000-3228:3364-I] AddAllWindows: QGALEDGERSUM TAILMARKER"]}},
        "missing": [], "complete": True}
json.dump(snap, open(T + "/snapshot.json", "w"), indent=1)
open(T + "/errors.txt", "w").write("FAIL  WIN11-clean: accept-clean battery FAILED (see x)\n\n[12:00:00] ERROR: push failed rc=46\n")
json.dump([{"tag": "SHUTDOWNDEATHTOAST", "scope": "P1, FIXED", "title": "the agent dies at session end"}], open(T + "/hints.json", "w"))
PY
# the stub judges: every item answered with $STUB_CHOICE at $STUB_CONF, the overall noul $STUB_NOUL; or exit 2
cat > "$T/jev-stub.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
if os.environ.get("STUB_RC") == "2":
    print("INSTRUMENT: stub - the judge did not run"); sys.exit(2)
rub = json.load(open(sys.argv[1])); q = rub.get("questions", rub)
out = sys.argv[sys.argv.index("--out") + 1]
choice = os.environ.get("STUB_CHOICE", "known-class"); conf = float(os.environ.get("STUB_CONF", "0.9")); noul = float(os.environ.get("STUB_NOUL", "0.1"))
novel_id = os.environ.get("STUB_NOVEL_ID", "")
ans = {}
for k, v in q.items():
    if v.get("type") == "noul":
        ans[k] = {"type": "noul", "noul": noul}
    else:
        c = "novel" if k == novel_id else choice
        ans[k] = {"type": "choice", "choice": c, "confidence": conf, "probabilities": {c: conf, "insufficient-evidence": round(1 - conf, 2)}}
json.dump({"model": "stub", "answers": ans, "usage": {"input_tokens": 1}}, open(out, "w"))
for k in ans: print(k, ans[k])
PY
chmod +x "$T/jev-stub.py"

knob(){ local n="$1" out="$T/verdict-$1.py" hits
  hits=$(grep -c "# GUARD:$n DEFECT: " "$SRC")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $SRC (want exactly 1)" >&2; return 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$SRC" > "$out"
  [ "$(diff "$SRC" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$SRC" "$out" | grep -c '^>') lines" >&2; return 2; }
  python3 -m py_compile "$out" || { echo "FATAL: knob $n does not compile" >&2; return 2; }
  printf '%s' "$out"; }
# vj <tool> <label> [args...] -> rc; output in $T/<label>.out, verdict in $T/<label>.json
vj(){ local tool="$1" l="$2"; shift 2
  python3 "$tool" --sweep "$T/report.json" --snapshot "$T/snapshot.json" --errors "$T/errors.txt" --hints "$T/hints.json" \
      --out "$T/$l.json" --workdir "$T/$l-work" --label "$l" --jev-cmd "$T/jev-stub.py" "$@" > "$T/$l.out" 2>&1; echo $?; }
vf(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$T/$1.json" "$2" 2>/dev/null; }

# ---- complete: every item reaches the judge ----------------------------------------------------------------------
rc=$(vj "$SRC" known)
[ "$rc" = 0 ] && ok "known: all known-class at 0.9, overall 0.1 -> rc 0" || bad "known: rc=$rc $(tail -2 "$T/known.out")"
n=$(vf known "len(r['items'])"); nq=$(python3 -c "import json;print(len(json.load(open('$T/known-work/jev-rubric-1.json'))['questions']))")
# 1 breach + 2 new + 1 known-defect E signature + 1 expected W signature + 2 harness lines = 7 items (the I-level ones are not errors), +1 overall question
[ "$n" = 7 ] && [ "$nq" = 8 ] && ok "complete: 7 items (breach, 2 NEW, the catalogued E signature, the expected W signature, 2 harness lines) + 1 overall = 8 questions" || bad "complete: items=$n questions=$nq: $(vf known "[(i['kind'],i['key'][:40]) for i in r['items']]")"
vf known "[i['kind'] for i in r['items'] if (i.get('hint') or {}).get('baseline_status')=='known-defect']" | grep -q signature && ok "complete: the signature the baseline already catalogues as known-defect is STILL an item (hint, not filter)" || bad "complete: the catalogued signature was pre-filtered"
K=$(knob prefilter) || exit 2; rc=$(vj "$K" k-prefilter); n=$(vf k-prefilter "len(r['items'])")
[ "$n" -lt 7 ] && ok "knob 'prefilter': catalogued signatures are dropped (items=$n) - the check is SEEN TO FAIL" || bad "knob prefilter did not drop anything (items=$n)"
grep -q 'cmd /c echo QREADY' "$T/known-work/jev-state-1.txt" && grep -q 'quick-upgrade.sh pkg win11-cell win11r' "$T/known-work/jev-state-1.txt" && grep -q 'TAILMARKER' "$T/known-work/jev-state-1.txt" \
  && grep -q 'SHUTDOWNDEATHTOAST' "$T/known-work/jev-state-1.txt" && grep -q 'KNOWN-CLASS CATALOGUE' "$T/known-work/jev-state-1.txt" \
  && ok "state: carries the snapshot's last qrexec pair, harness command, module tail and the catalogue" || bad "state: missing pieces in $T/known-work/jev-state-1.txt"
grep -q '"insufficient-evidence"' "$T/known-work/jev-rubric-1.json" && ok "rubric: every choice offers insufficient-evidence" || bad "rubric: no insufficient-evidence option"
grep -q 'VERDICT label=known rc=0 items=7 known=7 novel=0 insufficient=0 declared=0 needs_analysis=0' "$T/known.out" && ok "known: the VERDICT line carries the counts" || bad "known: verdict line: $(tail -1 "$T/known.out")"

# ---- novel / floor / overall -----------------------------------------------------------------------------------------
rc=$(STUB_NOVEL_ID=i002 vj "$SRC" novel)
[ "$rc" = 1 ] && [ "$(vf novel "r['overall']['items_needing_analysis']")" = "['i002']" ] && ok "novel: one novel item -> rc 1, verdict.json names i002" || bad "novel: rc=$rc $(vf novel "r['overall']")"
rc=$(STUB_CONF=0.3 vj "$SRC" floor)
[ "$rc" = 1 ] && vf floor "r['items'][0]['needs_analysis_why']" | grep -q 'below the confidence floor' && ok "floor: known-class at 0.3 is below the floor -> rc 1, the reason is recorded" || bad "floor: rc=$rc"
K=$(knob conffloor) || exit 2; rc=$(STUB_CONF=0.3 vj "$K" k-floor)
[ "$rc" = 0 ] && ok "knob 'conffloor': a 0.3 known-class passes - the check is SEEN TO FAIL" || bad "knob conffloor: rc=$rc"
rc=$(STUB_NOUL=0.9 vj "$SRC" overall)
[ "$rc" = 1 ] && [ "$(vf overall "r['overall']['jev_noul']")" = 0.9 ] && ok "overall: all known-class but the judge's overall noul 0.9 -> rc 1 (the judge can add a reason, never remove one)" || bad "overall: rc=$rc"
K=$(knob overallor) || exit 2; rc=$(STUB_NOUL=0.9 vj "$K" k-overall)
[ "$rc" = 0 ] && ok "knob 'overallor': the judge's overall is ignored - the check is SEEN TO FAIL" || bad "knob overallor: rc=$rc"

# ---- the judge did not run --------------------------------------------------------------------------------------------
rc=$(STUB_RC=2 vj "$SRC" exit2)
[ "$rc" = 2 ] && grep -q 'the judge did not run' "$T/exit2.out" && ok "exit2: jev.py exit 2 -> rc 2, never a pass" || bad "exit2: rc=$rc"
K=$(knob jev2) || exit 2; rc=$(STUB_RC=2 vj "$K" k-exit2)
[ "$rc" != 2 ] && ok "knob 'jev2': exit 2 reads as a verdict (rc=$rc) - the check is SEEN TO FAIL" || bad "knob jev2 did not change rc"

# ---- declarations ------------------------------------------------------------------------------------------------------
rc=$(vj "$SRC" decl --declare-error 'push failed rc=46' 'the cell pushes before the receiver session is up, on purpose')
n=$(vf decl "len(r['items'])"); d=$(vf decl "r['counts']['declared']"); nq=$(python3 -c "import json;print(len(json.load(open('$T/decl-work/jev-rubric-1.json'))['questions']))")
[ "$rc" = 0 ] && [ "$d" = 1 ] && [ "$nq" = 7 ] && [ "$(vf decl "[i['declared'] for i in r['items'] if i.get('declared')]")" = "['the cell pushes before the receiver session is up, on purpose']" ] \
  && ok "declared: the matching item is kept in verdict.json with the stimulus and left OUT of the rubric (7 questions)" || bad "declared: rc=$rc declared=$d questions=$nq"
rc=$(vj "$SRC" declnone --declare-error 'this matches nothing at all' 'a stimulus that did not happen')
[ "$rc" = 3 ] && grep -q 'declaration matched nothing' "$T/declnone.out" && ok "declared: a declaration matching nothing -> rc 3 (the run fails)" || bad "declnone: rc=$rc"
K=$(knob declunmatched) || exit 2; rc=$(vj "$K" k-declnone --declare-error 'this matches nothing at all' 'x')
[ "$rc" = 0 ] && ok "knob 'declunmatched': an unmatched declaration is tolerated - the check is SEEN TO FAIL" || bad "knob declunmatched: rc=$rc"

# ---- data problems and inputs ---------------------------------------------------------------------------------------------
python3 "$SRC" --sweep "$T/report-data.json" --snapshot "$T/snapshot.json" --out "$T/data.json" --workdir "$T/data-work" --jev-cmd "$T/jev-stub.py" > "$T/data.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'sweep status DATA' "$T/data.out" && ok "data: a sweep report with status DATA -> rc 2 (instrument)" || bad "data: rc=$rc $(tail -1 "$T/data.out")"
K=$(knob dataispass) || exit 2
python3 "$K" --sweep "$T/report-data.json" --snapshot "$T/snapshot.json" --out "$T/k-data.json" --workdir "$T/k-data-work" --jev-cmd "$T/jev-stub.py" > "$T/k-data.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "knob 'dataispass': a DATA sweep is judged as if complete - the check is SEEN TO FAIL" || bad "knob dataispass: rc=$rc"
python3 "$SRC" --sweep "$T/report.json" --snapshot "$T/nope.json" --out "$T/nosnap.json" --jev-cmd "$T/jev-stub.py" > "$T/nosnap.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "inputs: an unreadable snapshot -> rc 2" || bad "inputs: missing snapshot rc=$rc"
python3 "$SRC" --snapshot "$T/snapshot.json" --out "$T/none.json" --jev-cmd "$T/jev-stub.py" > "$T/none.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "inputs: no sweep and no errors -> rc 2" || bad "inputs: nothing given rc=$rc"
python3 "$SRC" --sweep "$T/report.json" --snapshot "$T/snapshot.json" --out "$T/hintreal.json" --workdir "$T/hintreal-work" --jev-cmd "$T/jev-stub.py" > "$T/hintreal.out" 2>&1; rc=$?
nh=$(python3 -c "import json;print(json.load(open('$T/hintreal.json'))['inputs']['hints'])")
[ "$rc" = 0 ] && [ "$nh" -gt 10 ] && ok "hints: without --hints the catalogue comes from findings/issues.md + the baseline ($nh entries)" || bad "hints: rc=$rc entries=$nh"

echo
echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
