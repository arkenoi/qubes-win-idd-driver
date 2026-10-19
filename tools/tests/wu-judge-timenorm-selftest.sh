#!/usr/bin/env bash
# wu-judge-timenorm-selftest.sh - tools/wu-log-judge.py must select its window as an ABSOLUTE
# INTERVAL, build episodes forward in real time, and refuse loudly when a bound has no date.
#
# WHY. Until 2026-10-19 the window and the log's stamps were both bare `timedelta`s:
#     def hms(s): h, m, sec = s.split(":"); return timedelta(hours=int(h), ...)
#     if t < t0 or t > t1: continue
# so the window took rows at that o'clock on EVERY date the log carries - and one decode carries
# several. Every real decoded WU log on this qube spans two or more days:
#     scratchpad/gweck25h2/slowscan/wulog-diag.txt   2026.09.16 + 2026.09.17
#     ../qwt-accept/gweck-failboot/wulog.txt         2026.09.16 + 2026.10.02  (sixteen days apart)
#     scratchpad/fbprobe/run-*/wulog-post/wulog.txt  2026.09.16 + 2026.09.21
# Measured pre-fix on a window where two of those dates overlap:
#     facts: rows=3 resets=0 transient=0 http_errors=0 last_row=21:05:12.332000 searches=1 ended=True episodes=1
#     verdict: PASS
# The pass under test had NO search at all; the `ended=True` that cleared it was the PREVIOUS day's
# completed search. `ended` is the make-or-break FAIL in this judge, so that is a blind gate.
# The mirror image was the midnight window: `hms("23:59:00") > hms("00:01:30")`, so nothing matched
# `t0 <= t <= t1` and the judge printed `INSTRUMENT: no WU log rows in window 23:59:00-00:01:30`
# over five rows that were in it - the P1 transient line among them. Campaigns here cross midnight
# routinely (the 4.3.37 acceptance ran 20:21 -> 02:24).
# And episodes: `(r2["t"] - r["t"]).total_seconds() * 1000 > span_ms` is never true of a NEGATIVE
# delta, so a line 2 h 10 min after the head was glued onto its episode and sent to Jev as
# "consecutive lines on one thread" - measured pre-fix, `lines in episode 0 = 2`.
#
# EVERY CASE CARRIES ITS OWN PRE-FIX CONTROL (the frozen `old_*` python below, transcribed from
# wu-log-judge.py:46-57 and :67 as of 7238cd09), so a fixture that stops discriminating fails this
# suite rather than passing it quietly.
#
# Offline: no rig, no guest, no network (--no-judge everywhere, so no Jev call and no key).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
J="${WU_JUDGE:-$HERE/tools/wu-log-judge.py}"
[ -f "$J" ] || { echo "FAIL  $J missing - nothing ran (missing data fails)"; exit 2; }
D=$(mktemp -d "${TMPDIR:-/tmp}/wu-timenorm-XXXXXX"); trap 'rm -rf -- "$D"' EXIT
REAL="$HERE/scratchpad/gweck25h2/slowscan/wulog-diag.txt"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- fixture bodies, copied from the real decode ------------------------------------------------
# All four are verbatim message shapes from scratchpad/gweck25h2/slowscan/wulog-diag.txt; only the
# stamps are moved. The 8024402C SendRequest line is the one that is an episode head WITHOUT being
# a reset or an HTTP error, so a day can carry a failure and still clear every code fact - which is
# what makes the borrowed `ended` the whole verdict.
START='ComApi          Federated Search: Starting search against 2 service(s) (cV = FzEm/U2eF0GgRY0M.1.0)'
END='ComApi          * END *   All federated searches have completed. Jobs = 2, Succeeded = 1, ClientId = <<PROCESS>>: powershell.exe (cV = FzEm/U2eF0GgRY0M.1.2)'
SENDFAIL='Misc            *FAILED* [8024402C] WinHttp: SendRequestWithAuthRetry using proxy failed for <HTTPS://tas02.sls.update.microsoft.com/SLS/{9482F4B4-E343-43B6-B170-9A65BC822C77}/x64/10.0.26200.8037/0?CH=67&L=de-DE&P=&PT=0x30&WUA=1507.2601.30012.0&MK=Xen&MD=HVM+domU>'
RESETHEAD='Misc            *FAILED* [80072EFE] WinHttp: SendRequestWithAuthRetry using proxy failed for <http://download.windowsupdate.com/c/msdownload/update/others/2021/01/33356784_31f6eaf6d5437d3e7700835aa29b58168ae2a3b6.cab>'
RETRY='Misc            *FAILED* [80072EFE] Library download error. Will retry. Retry Counter: 0'
TRANS='Misc            A transient error was identified and the network is not connected. Reducing the total number of retries from 3 to 2'

# PIN THE FIXTURE TO THE EMITTER AND TO THE JUDGE'S OWN PATTERNS. A suite whose fixture no longer
# matches what the judge looks for would keep "passing" while measuring nothing.
python3 - "$J" "$REAL" "$START" "$END" "$SENDFAIL" "$RESETHEAD" "$TRANS" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("j", sys.argv[1])
j = importlib.util.module_from_spec(spec); spec.loader.exec_module(j)
real, start, end, sendfail, resethead, trans = sys.argv[2:8]
bad = []
if j.STARTED not in start: bad.append("the frozen start line no longer carries STARTED")
if j.ENDED not in end: bad.append("the frozen end line no longer carries ENDED")
if j.TRANSIENT not in trans: bad.append("the frozen transient line no longer carries TRANSIENT")
if not j.FAILHEAD.search(sendfail): bad.append("the frozen 8024402C line is no longer an episode head")
if j.RESET.search(sendfail) or j.HTTPERR.search(sendfail):
    bad.append("the frozen 8024402C line now counts as a reset/http error - it must clear both")
if not j.RESET.search(resethead): bad.append("the frozen 80072EFE head is no longer a reset")
if os.path.exists(real):
    # Counted with the judge's OWN row regex, which both generations have, so this anchor keeps
    # working when the suite is pointed at a pre-fix copy to prove it fires.
    dates = []
    with open(real, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = j.WU.match(line.rstrip("\n"))
            if m:
                d = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
                if d not in dates: dates.append(d)
    if len(dates) < 2:
        bad.append("%s no longer spans two dates (%d) - the ambiguity case has no real witness"
                   % (real, len(dates)))
    else:
        print("anchor: real decode present and spans %d dates (%s)"
              % (len(dates), ", ".join("%04d-%02d-%02d" % d for d in dates)))
else:
    print("anchor: real decode gone from this qube; frozen shapes used")
for b in bad: print("ANCHOR-FAIL " + b)
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || { echo "FAIL  fixture anchors: the frozen shapes no longer match the emitter/judge"; exit 1; }

row(){ printf '%s %s %s  %s  %s\n' "$1" "$2" "$3" "$4" "$5"; }

# A: THE BLIND GATE. 2026-09-16 21:05 ran a search and ended it; 2026-09-17 21:05 is the pass under
# test and has no search at all, only a SendRequest failure.
{ row 2026.09.16 21:05:10.8175683 5980 6472 "$START"
  row 2026.09.16 21:05:49.9100857 5980 6472 "$END"
  row 2026.09.17 21:05:12.3327783 2784 2640 "$SENDFAIL"; } > "$D/a.log"
# B: a window across midnight. The real stalled-run sequence (19:02:25 -> 19:02:28), on midnight.
{ row 2026.10.18 23:59:40.8175683 5980 6472 "$START"
  row 2026.10.18 23:59:59.8000000 2676 7064 "$RESETHEAD"
  row 2026.10.19 00:00:00.9000000 2676 7064 "$RETRY"
  row 2026.10.19 00:00:01.1000000 2676 7064 "$TRANS"; } > "$D/b.log"
# C: an episode head at 23:59:50 and a line 2 h 10 min later on the same thread.
{ row 2026.10.18 23:59:50.8000000 2676 7064 "$RESETHEAD"
  row 2026.10.19 02:00:00.0000000 2676 7064 "$RETRY"; } > "$D/c.log"
# E: one date only, and the clock steps BACK 5 s inside the window. A guest clock here really does
# jump (a health.json on this rig carries `"boot_skew_s": -10720, "boot_stamp_usable": false`).
{ row 2026.09.17 19:02:25.3141907 2676 7064 "$RESETHEAD"
  row 2026.09.17 19:02:20.0000000 2676 7064 "$RETRY"; } > "$D/e.log"

run(){ python3 "$J" --no-judge "$@" 2>&1; }
rc(){ python3 "$J" --no-judge "$@" >/dev/null 2>&1; echo $?; }

# ---- the frozen PRE-FIX window + episode builder -----------------------------------------------
old(){ python3 - "$1" "$2" "$3" <<'PY'
import re, sys
from datetime import timedelta
WU = re.compile(r"^(\d{4})\.(\d\d)\.(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")
RESET = re.compile(r"\*FAILED\* \[80072EFE\]", re.I)
HTTPERR = re.compile(r"\*FAILED\* \[8019[0-9A-F]{4}\]", re.I)
FAILHEAD = re.compile(r"\*FAILED\* \[[0-9A-F]{8}\] .*(SendRequest|HTTP status)", re.I)
TRANSIENT = "A transient error was identified and the network is not connected"
ENDED = "All federated searches have completed"
STARTED = "Federated Search: Starting search"
def hms(s):
    h, m, sec = s.split(":"); return timedelta(hours=int(h), minutes=int(m), seconds=int(sec))
t0, t1 = hms(sys.argv[2]), hms(sys.argv[3])
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = WU.match(line.rstrip("\n"))
    if not m: continue
    t = timedelta(hours=int(m.group(4)), minutes=int(m.group(5)), seconds=int(m.group(6)), milliseconds=int(m.group(7)[:3]))
    if t < t0 or t > t1: continue
    rows.append({"t": t, "tid": m.group(9), "msg": m.group(11)})
starts = [i for i, r in enumerate(rows) if STARTED in r["msg"]]
ended = bool(starts) and any(ENDED in r["msg"] for r in rows[starts[-1]:])
nep = 0
for i, r in enumerate(rows):
    if not FAILHEAD.search(r["msg"]): continue
    if not (RESET.search(r["msg"]) or HTTPERR.search(r["msg"]) or "SendRequest" in r["msg"]): continue
    seq = [r["msg"]]
    for r2 in rows[i + 1:]:
        if r2["tid"] != r["tid"]: continue
        if (r2["t"] - r["t"]).total_seconds() * 1000 > 3000 or len(seq) > 6: break
        if FAILHEAD.search(r2["msg"]): break
        seq.append(r2["msg"])
    nep = max(nep, len(seq))
fails = bool([x for x in (
    sum(1 for r in rows if RESET.search(r["msg"]) and ("SendRequest" in r["msg"] or "DownloadSession" in r["msg"])),
    sum(1 for r in rows if TRANSIENT in r["msg"]), 0 if ended else 1) if x])
print("rows=%d transient=%d ended=%s maxepisodelines=%d verdict=%s" % (
    len(rows), sum(1 for r in rows if TRANSIENT in r["msg"]), ended, nep,
    "FAIL" if fails else "PASS"))
PY
}

# ================= the SILENT one: `ended` borrowed from another day =============================
o=$(old "$D/a.log" 21:00:00 21:59:59)
if printf '%s' "$o" | grep -q 'ended=True' && printf '%s' "$o" | grep -q 'verdict=PASS'; then
    ok "borrowed ended, pre-fix control: $o - a day with no search graded PASS"
else bad "borrowed ended: the pre-fix control did NOT pass ($o) - the fixture no longer discriminates"; fi
r=$(run --wu-log "$D/a.log" --from '2026-09-17 21:00:00' --to '2026-09-17 21:59:59')
if [ "$(rc --wu-log "$D/a.log" --from '2026-09-17 21:00:00' --to '2026-09-17 21:59:59')" = 3 ] \
   && printf '%s' "$r" | grep -q 'searches=0 ended=False' \
   && printf '%s' "$r" | grep -q 'NOT ENDED: the last of 0 search(es)'; then
    ok "borrowed ended: dated to the pass under test, the missing search is a FAIL"
else bad "borrowed ended: $(printf '%s' "$r" | head -2 | tr '\n' ' ')"; fi
r=$(run --wu-log "$D/a.log" --from 21:00:00 --to 21:59:59)
if [ "$(rc --wu-log "$D/a.log" --from 21:00:00 --to 21:59:59)" = 2 ] \
   && printf '%s' "$r" | grep -q 'rows between them on 2 dates'; then
    ok "borrowed ended: a bare window over two dates is refused and both dates are named"
else bad "a bare window over two dates still produced a verdict - $(printf '%s' "$r" | head -1)"; fi
# The same day on both sides must still grade exactly as before: this is a correctness fix.
r=$(run --wu-log "$D/a.log" --from '2026-09-16 21:00:00' --to '2026-09-16 21:59:59')
if [ "$(rc --wu-log "$D/a.log" --from '2026-09-16 21:00:00' --to '2026-09-16 21:59:59')" = 0 ] \
   && printf '%s' "$r" | grep -q 'searches=1 ended=True'; then
    ok "one day, one phase: the day that really did end its search still grades PASS"
else bad "a provably single-day window changed verdict - $(printf '%s' "$r" | head -1)"; fi

# ================= (a) ACROSS MIDNIGHT: the rows and the episode must be found ====================
o=$(old "$D/b.log" 23:59:00 00:01:30)
if printf '%s' "$o" | grep -q '^rows=0'; then
    ok "midnight, pre-fix control: $o - four rows in the interval and the judge saw none"
else bad "midnight: the pre-fix control found rows ($o)"; fi
r=$(run --wu-log "$D/b.log" --from '2026-10-18 23:59:00' --to '2026-10-19 00:01:30')
if [ "$(rc --wu-log "$D/b.log" --from '2026-10-18 23:59:00' --to '2026-10-19 00:01:30')" = 3 ] \
   && printf '%s' "$r" | grep -q 'rows=4' && printf '%s' "$r" | grep -q 'transient=1' \
   && printf '%s' "$r" | grep -q 'FAIL TRANSIENT'; then
    ok "midnight: the interval spans the day boundary and the transient line is FOUND"
else bad "midnight: $(printf '%s' "$r" | head -2 | tr '\n' ' ')"; fi
r=$(run --wu-log "$D/b.log" --from 23:59:00 --to 00:01:30)
if [ "$(rc --wu-log "$D/b.log" --from 23:59:00 --to 00:01:30)" = 2 ] \
   && printf '%s' "$r" | grep -q 'cannot express a window that crosses midnight'; then
    ok "midnight: a bare straddling window is an INSTRUMENT refusal that names the remedy"
else bad "a bare straddling window did not refuse loudly - $(printf '%s' "$r" | head -1)"; fi
# The operator who dates only --from must still get the right interval, and be told it rolled.
r=$(run --wu-log "$D/b.log" --from '2026-10-18 23:59:00' --to 00:01:30)
if printf '%s' "$r" | grep -q 'window=2026-10-18T23:59:00/2026-10-19T00:01:30' \
   && printf '%s' "$r" | grep -q 'window_dates=given/rolled+1d'; then
    ok "midnight: a dated --from with a bare --to rolls to the next day and says so"
else bad "mixed bounds did not roll - $(printf '%s' "$r" | head -1)"; fi

# ================= an episode must not swallow a line 2 h away ===================================
o=$(old "$D/c.log" 00:00:00 23:59:59)
if printf '%s' "$o" | grep -q 'maxepisodelines=2'; then
    ok "episode span, pre-fix control: $o - a line 2 h 10 min later was glued to the head"
else bad "episode span: the pre-fix control did not glue ($o)"; fi
run --wu-log "$D/c.log" --from '2026-10-18 00:00:00' --to '2026-10-19 23:59:59' --json "$D/c.json" >/dev/null 2>&1
n=$(python3 -c "import json;d=json.load(open('$D/c.json'));print(len(d['episodes'][0]['lines']))" 2>/dev/null)
if [ "$n" = 1 ]; then
    ok "episode span: the head stands alone - a line 2 h 10 min later is no longer its tail"
else bad "episode span: episode 0 still holds $n line(s)"; fi

# ================= a backward clock step is cut AND reported ======================================
r=$(run --wu-log "$D/e.log" --from '2026-09-17 19:02:00' --to '2026-09-17 19:03:00')
if printf '%s' "$r" | grep -q 'clock_backward_steps=1' && printf '%s' "$r" | grep -q 'FLAG CLOCK'; then
    ok "clock step: a 5 s backward step inside the window is cut and FLAGGED, not swallowed"
else bad "clock step: a backward step was absorbed silently - $(printf '%s' "$r" | head -1)"; fi

# ================= the OLD CLI on a single-date log, unchanged ===================================
r=$(run --wu-log "$D/e.log" --from 19:02:00 --to 19:03:00)
if [ "$(rc --wu-log "$D/e.log" --from 19:02:00 --to 19:03:00)" = 3 ] \
   && printf '%s' "$r" | grep -q 'window_dates=resolved:2026-09-17' \
   && printf '%s' "$r" | grep -q '^facts: rows=2 resets=1 transient=0 http_errors=0'; then
    ok "backward compat: a bare window on a single-date log still resolves, same leading facts"
else bad "backward compat: the old call shape changed - $(printf '%s' "$r" | head -1)"; fi

# ================= THE REAL LOG, THE DOCUMENTED INVOCATION, SAME VERDICT =========================
# The docstring's receipt is `--from 20:46:00 --to 20:49:00` on the stalled run's decode, a log that
# carries BOTH 2026.09.16 and 2026.09.17. Only 09-17 has rows in that interval, so the bare window
# still resolves and must read the same rows and return the same facts as the pre-fix code.
if [ -f "$REAL" ]; then
    o=$(old "$REAL" 20:46:00 20:49:00)
    r=$(run --wu-log "$REAL" --from 20:46:00 --to 20:49:00)
    if printf '%s' "$o" | grep -q '^rows=505 transient=30 ended=False' \
       && printf '%s' "$r" | grep -q 'rows=505 resets=60 transient=30' \
       && printf '%s' "$r" | grep -q 'window_dates=resolved:2026-09-17' \
       && [ "$(rc --wu-log "$REAL" --from 20:46:00 --to 20:49:00)" = 3 ]; then
        ok "real decode: the documented window still reads 505 rows and still FAILS (pre-fix: $o)"
    else bad "real decode: the documented invocation moved - pre=[$o] post=[$(printf '%s' "$r" | head -1)]"; fi
else echo "SKIP  the stalled run's decode is not on this qube (fixtures covered every case above)"; fi

echo "wu-judge-timenorm: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -ge 12 ] || { echo "FAIL  only $pass assertion(s) ran - the suite has been gutted"; exit 1; }
