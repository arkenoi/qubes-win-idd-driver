#!/usr/bin/env bash
# relay-log-judge correlates both logs on ABSOLUTE INSTANTS and refuses loudly when it cannot.
# run: tools/tests/relay-judge-timenorm-selftest.sh
# pass: exit 0
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
J="${RELAY_JUDGE:-$HERE/tools/relay-log-judge.py}"
[ -f "$J" ] || { echo "FAIL  $J missing - nothing ran (missing data fails)"; exit 2; }
D=$(mktemp -d "${TMPDIR:-/tmp}/relay-timenorm-XXXXXX"); trap 'rm -rf -- "$D"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- fixture bodies, taken from real captures on this qube -------------------------------------
# The relay serve line is the shape of
#   qwt-accept/rel-39175573529/template-update.d/wu-e2e/round1/relay.log:3041
# and the WU failure is the token-less DownloadSession line from
#   scratchpad/gweck25h2/slowscan/wulog-diag.txt
# (`*FAILED* [80072EFE] wuauengcore.dll, ...DownloadSession.cpp @842`). The token-less one is the
# case that reaches the TIMESTAMP arm of the gap check - the one with a URL token is matched by
# causation and was never affected.
REAL_RELAY="$HERE/../qwt-accept/rel-39175573529/template-update.d/wu-e2e/round1/relay.log"
REAL_WU="$HERE/scratchpad/gweck25h2/slowscan/wulog-diag.txt"
SERVE='PLAIN tries=1 bytes=7612 body=7331/7331 complete=True streamed=False chunked=False ms=272 req=[GET http://download.windowsupdate.com/d/msdownload/update/others/2018/06/26753995_f328ff0bc8e46265aba7f7809fbd5964b7d9e1]'
WUFAIL='*FAILED* [80072EFE] wuauengcore.dll, C:\__w\1\s\src\Client\lib\DownloadFile\DownloadSession.cpp @842'
LISTEN='listen 127.0.0.1:8082 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'

# PIN THE FIXTURE TO THE EMITTER. If the real captures are still here, the frozen bodies above must
# still be the shape the judge's own regexes pick out of them; otherwise this suite could keep
# "passing" on lines no relay writes any more, which is how a grader goes blind.
python3 - "$J" "$REAL_RELAY" "$REAL_WU" "$SERVE" "$WUFAIL" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("j", sys.argv[1])
j = importlib.util.module_from_spec(spec); spec.loader.exec_module(j)
real_relay, real_wu, serve, wufail = sys.argv[2:6]
bad = []
if not j.ACCOUNTS.match(serve):
    bad.append("the frozen serve line is no longer an ACCOUNTS line for the judge")
if j.URLTOK.search(wufail):
    bad.append("the frozen WU failure now carries a URL token - it would not reach the timestamp arm")
if not (j.WU_FAIL.search(wufail) and "DownloadSession" in wufail):
    bad.append("the frozen WU failure is no longer selected by parse_wu_failures")
if os.path.exists(real_relay):
    with open(real_relay, encoding="utf-8", errors="replace") as f:
        if not any(j.ACCOUNTS.match(m.group(5)) for m in
                   (j.RELAY_TS.match(l.rstrip("\n")) for l in f) if m):
            bad.append("%s has no ACCOUNTS line - the fixture shape has drifted" % real_relay)
    print("anchor: real relay capture present (%s)" % os.path.basename(real_relay))
else:
    print("anchor: real relay capture gone from this qube; frozen shape used")
if os.path.exists(real_wu):
    with open(real_wu, encoding="utf-8", errors="replace") as f:
        if not any("DownloadSession.cpp" in l and "80072EFE" in l for l in f):
            bad.append("%s has no token-less DownloadSession failure any more" % real_wu)
    print("anchor: real WU capture present (%s)" % os.path.basename(real_wu))
else:
    print("anchor: real WU capture gone from this qube; frozen shape used")
for b in bad: print("ANCHOR-FAIL " + b)
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || { echo "FAIL  fixture anchors: the frozen shapes no longer match the emitter"; exit 1; }

mk_relay(){ printf '%s %s\n%s %s\n' "$1" "$LISTEN" "$2" "$SERVE" > "$3"; }
mk_wu(){ printf '%s %s 2676  7064  Agent           %s\n' "$1" "$2" "$WUFAIL" > "$3"; }

# A: the serve is 1.914 s before the failure, across midnight.
mk_relay 23:59:58.000 23:59:59.400 "$D/a-relay.log"
mk_wu 2026.10.19 00:00:01.3142204 "$D/a-wu.log"
# B: THE BLIND GATE. The relay log is 2026-10-18; the failure is 2026-10-19, 24 h away.
mk_relay 05:13:44.900 05:13:45.100 "$D/b-relay.log"
mk_wu 2026.10.19 05:13:46.1234567 "$D/b-wu.log"
# C: one instant, two clocks 3 h apart - the guest's relay log is local (+03:00), this WU decode is
# UTC. Measured on this qube: wu-e2e/run.log says `02:15:05 ... relay log 3048 line(s)` for the very
# round whose relay.log ends at `05:14:06.195`, and the installer logs `2026-10-19 05:01:31` for the
# run whose precondition record says `"t":"2026-10-19T02:01:31.6807220Z"`.
mk_relay 05:01:30.900 05:01:31.500 "$D/c-relay.log"
mk_wu 2026.10.19 02:01:33.0000000 "$D/c-wu.log"

# ---- the frozen PRE-FIX comparison, so every case is seen to FAIL without the fix ---------------
# relay-log-judge.py:58 (pre-fix): t = timedelta(hours=int(h), minutes=int(mi), seconds=int(s), milliseconds=int(ms))
# relay-log-judge.py:99 (pre-fix): near = [x for (tt, x) in outcomes if abs((tt - t).total_seconds()) <= window]
old_delta(){ python3 - "$1" "$2" <<'PY'
import re, sys
from datetime import timedelta
RELAY_TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3})\s+(.*)$")
WU_TS = re.compile(r"^(\d{4})\.(\d\d)\.(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")
out = []
for l in open(sys.argv[1]):
    m = RELAY_TS.match(l.rstrip("\n"))
    if m and m.group(5).startswith(("PLAIN tries=", "PLAIN REFUSED", "CLOSE reason=", "CONN ")):
        out.append(timedelta(hours=int(m.group(1)), minutes=int(m.group(2)), seconds=int(m.group(3)), milliseconds=int(m.group(4))))
for l in open(sys.argv[2]):
    m = WU_TS.match(l.rstrip("\n"))
    if not m: continue
    t = timedelta(hours=int(m.group(4)), minutes=int(m.group(5)), seconds=int(m.group(6)), milliseconds=int(m.group(7)[:3]))
    print("%.3f %s" % (min(abs((x - t).total_seconds()) for x in out) if out else -1,
                       "accounted" if any(abs((x - t).total_seconds()) <= 2 for x in out) else "GAP"))
PY
}

run(){ python3 "$J" --no-judge "$@" 2>&1; }
rc(){ python3 "$J" --no-judge "$@" >/dev/null 2>&1; echo $?; }

# ================= (a) 2 s apart ACROSS MIDNIGHT must correlate ==================================
old=$(old_delta "$D/a-relay.log" "$D/a-wu.log")
if [ "${old#* }" = "GAP" ]; then
    ok "midnight, pre-fix control: the old time-of-day delta is ${old%% *} s and reports a GAP"
else bad "midnight: the pre-fix control did NOT fail ($old) - the fixture no longer discriminates"; fi
r=$(run --relay-log "$D/a-relay.log" --wu-log "$D/a-wu.log" --relay-date 2026-10-18)
if [ "$(rc --relay-log "$D/a-relay.log" --wu-log "$D/a-wu.log" --relay-date 2026-10-18)" = 0 ] \
   && printf '%s' "$r" | grep -q 'gaps=0 violations=0'; then
    ok "midnight: 23:59:59.400 accounts for a 00:00:01.314 failure 1.9 s later"
else bad "midnight: $(printf '%s' "$r" | head -1)"; fi

# ================= the SILENT direction: a line 24 h away must NOT account ========================
old=$(old_delta "$D/b-relay.log" "$D/b-wu.log")
if [ "${old#* }" = "accounted" ]; then
    ok "24 h, pre-fix control: the old delta is ${old%% *} s, so another day's line accounted for it"
else bad "24 h: the pre-fix control did NOT pass ($old) - the fixture no longer discriminates"; fi
r=$(run --relay-log "$D/b-relay.log" --wu-log "$D/b-wu.log" --relay-date 2026-10-18)
if [ "$(rc --relay-log "$D/b-relay.log" --wu-log "$D/b-wu.log" --relay-date 2026-10-18)" = 3 ] \
   && printf '%s' "$r" | grep -q 'gaps=1' && printf '%s' "$r" | grep -q 'VIOLATION GAP'; then
    ok "24 h: a relay line a day away no longer accounts for the failure (the blind gate is shut)"
else bad "24 h: a 24 h gap still read as accounted - $(printf '%s' "$r" | head -1)"; fi

# ================= (b) two sources 3 h apart in PHASE ============================================
old=$(old_delta "$D/c-relay.log" "$D/c-wu.log")
if [ "${old#* }" = "GAP" ]; then
    ok "3 h phase, pre-fix control: the old delta is ${old%% *} s and reports a GAP, silently"
else bad "3 h phase: the pre-fix control did NOT fail ($old)"; fi
r=$(run --relay-log "$D/c-relay.log" --wu-log "$D/c-wu.log" --relay-date 2026-10-19 --relay-tz +03:00 --wu-tz Z)
if [ "$(rc --relay-log "$D/c-relay.log" --wu-log "$D/c-wu.log" --relay-date 2026-10-19 --relay-tz +03:00 --wu-tz Z)" = 0 ] \
   && printf '%s' "$r" | grep -q 'gaps=0 violations=0' && printf '%s' "$r" | grep -q 'timebase=relay=+03:00 wu=Z'; then
    ok "3 h phase: once both zones are declared the two logs correlate on one instant"
else bad "3 h phase: $(printf '%s' "$r" | head -1)"; fi
r=$(run --relay-log "$D/c-relay.log" --wu-log "$D/c-wu.log" --relay-date 2026-10-19 --relay-tz +03:00)
if [ "$(rc --relay-log "$D/c-relay.log" --wu-log "$D/c-wu.log" --relay-date 2026-10-19 --relay-tz +03:00)" = 2 ] \
   && printf '%s' "$r" | grep -q 'come as a pair'; then
    ok "3 h phase: one zone declared and one unknown is an INSTRUMENT refusal, not a verdict"
else bad "half-declared zones graded a verdict - $(printf '%s' "$r" | head -1)"; fi

# ================= an undatable stamp must be LOUD, never a fallback =============================
r=$(run --relay-log "$D/b-relay.log" --wu-log "$D/b-wu.log")
if [ "$(rc --relay-log "$D/b-relay.log" --wu-log "$D/b-wu.log")" = 2 ] \
   && printf '%s' "$r" | grep -q 'INSTRUMENT' && printf '%s' "$r" | grep -q 'carries NO date'; then
    ok "no --relay-date: refuses to correlate at all rather than fall back to a time of day"
else bad "no --relay-date still produced a verdict - $(printf '%s' "$r" | head -1)"; fi
# The relay log's date is NEVER taken from the WU log: fixture B is the proof that the inference
# would hand back a clean PASS on a file whose real date is the day before.
if printf '%s' "$r" | grep -q 'not derivable'; then
    ok "no --relay-date: the message says the WU log's date does not establish the relay log's"
else bad "the refusal did not state that the WU date is not a substitute"; fi

# A REAL relay log steps backward across its appended days; that is not datable, and the judge must
# say which line rather than invent a date for the rest of the file.
if [ -f "$REAL_RELAY" ]; then
    r=$(run --relay-log "$REAL_RELAY" --wu-log "$D/b-wu.log" --relay-date 2026-10-17)
    if [ "$(rc --relay-log "$REAL_RELAY" --wu-log "$D/b-wu.log" --relay-date 2026-10-17)" = 2 ] \
       && printf '%s' "$r" | grep -q 'steps BACK'; then
        ok "real capture: the 19:41:56 -> 19:03:14 step is refused by line number, not dated by guess"
    else bad "real capture: an undatable backward step was dated anyway - $(printf '%s' "$r" | head -1)"; fi
else echo "SKIP  real relay capture not on this qube (frozen shapes covered every case above)"; fi

# THE DOCUMENTED RECEIPT MUST NOT MOVE. findings/issues.md records this judge as "seen to FAIL on
# this log, 31/31 gapped" for the 2026-09-17 stalled pass. That pair is still here, and its own
# relay log is NOT monotonic - its last line is a truncated DUPLICATE of line 30, so the stamps step
# back 43 s. The operator knows the file is one day (its name says 20260917 and it spans 20:46-20:48)
# and says so; the step is still counted and printed. Same gaps, same 31 distinct downloads as the
# pre-fix code: this is a correctness fix, not a behaviour change.
PAIR_R="$HERE/scratchpad/gweck25h2/slowscan/relay-full-20260917.log"
PAIR_W="$HERE/scratchpad/gweck25h2/slowscan/wu-fails-2046pass.log"
if [ -f "$PAIR_R" ] && [ -f "$PAIR_W" ]; then
    args=(--relay-log "$PAIR_R" --wu-log "$PAIR_W" --relay-date 2026-09-17 --relay-single-day)
    r=$(run "${args[@]}")
    if [ "$(rc "${args[@]}")" = 3 ] && printf '%s' "$r" | grep -q 'gaps=46' \
       && printf '%s' "$r" | grep -q 'relay_backward_steps=1' \
       && printf '%s' "$r" | grep -q 'NOTE 1 backward stamp step'; then
        ok "real pair: the 2026-09-17 receipt still gaps 46 failures and the dup tail is announced"
    else bad "real pair: the documented receipt moved - $(printf '%s' "$r" | head -1)"; fi
    python3 "$J" --no-judge "${args[@]}" --json "$D/pair.json" >/dev/null 2>&1
    n=$(python3 -c "import json;print(json.load(open('$D/pair.json'))['distinct_failed_downloads'])" 2>/dev/null)
    if [ "$n" = 31 ]; then
        ok "real pair: 31 distinct failed downloads, exactly as findings/issues.md records"
    else bad "real pair: distinct_failed_downloads=$n, issues.md records 31"; fi
    # Without the declaration the same file must REFUSE: the knob is what authorises it, not the tool.
    if [ "$(rc --relay-log "$PAIR_R" --wu-log "$PAIR_W" --relay-date 2026-09-17)" = 2 ]; then
        ok "real pair: without --relay-single-day the non-monotonic capture is refused"
    else bad "real pair: the dup tail was dated without the operator declaring anything"; fi
else echo "SKIP  the 2026-09-17 evidence pair is not on this qube"; fi

# ================= the OLD CLI, unchanged ========================================================
# Without --wu-log nothing is correlated, so no date is load-bearing and the pre-fix call shape must
# still work and still print its counts in the same order and wording.
r=$(run --relay-log "$D/b-relay.log")
if [ "$(rc --relay-log "$D/b-relay.log")" = 0 ] \
   && printf '%s' "$r" | grep -q '^relay lines=2 judged=0 wu_failures=- gaps=0 violations=0'; then
    ok "backward compat: --relay-log alone still runs and the summary's leading fields are unmoved"
else bad "backward compat: the old call shape changed - $(printf '%s' "$r" | head -1)"; fi

echo "relay-judge-timenorm: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -ge 10 ] || { echo "FAIL  only $pass assertion(s) ran - the suite has been gutted"; exit 1; }
