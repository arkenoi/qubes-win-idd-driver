#!/usr/bin/env python3
"""wu-log-judge.py - did a Windows Update pass through our relay ever enter the transient/NLA-wait path?

    tools/wu-log-judge.py --wu-log DECODED.txt --from T0 --to T1 [--tz +03:00] [--limit N] [--json out]
    T0/T1 are `YYYY-MM-DD HH:MM:SS[.frac]` (or `...THH:MM:SS`, optionally `Z`/`+03:00`), or a bare
    `HH:MM:SS[.frac]` whose date is resolved from the log and REFUSED when it is ambiguous.

Input: the decoded Windows Update log (Get-WindowsUpdateLog; works offline on the guest in ~21 s) and
the wall-clock window of ONE update pass. Verdict (exit 0 PASS, 3 FAIL, 2 instrument):

THE WINDOW IS AN ABSOLUTE INTERVAL, NEVER A TIME OF DAY. Until 2026-10-19 both the log's stamps and
the window bounds were parsed into bare `timedelta`s, so the window selected rows at that o'clock on
EVERY date the log carries - and ONE decode carries many: every real one on this qube spans two or
more days (scratchpad/gweck25h2/slowscan/wulog-diag.txt 2026.09.16 + 2026.09.17;
qwt-accept/gweck-failboot/wulog.txt 2026.09.16 + 2026.10.02, sixteen days apart). Measured pre-fix,
on a window where two dates overlap: `rows=3 ... searches=1 ended=True ... verdict: PASS`, where the
pass under test had no search at all and the `ended` that cleared it belonged to the PREVIOUS day.
That is the blind gate - the make-or-break FAIL satisfied by another day's row. A window that
crosses midnight was the mirror image: `hms("23:59:00") > hms("00:01:30")`, so every row failed
`t0 <= t <= t1` and the judge said `INSTRUMENT: no WU log rows in window` over five rows that were
right there, the P1 transient line among them. Campaigns here cross midnight routinely (the 4.3.37
acceptance ran 20:21 -> 02:24).
Episodes had the same root: `(r2["t"] - r["t"]).total_seconds() * 1000 > span_ms` is never true for
a negative delta, so a line 2 h 10 min after the failure head was glued onto its episode and sent to
Jev as "consecutive lines on one thread" - a composite that never happened.
So every stamp becomes ONE ABSOLUTE INSTANT at parse time, from the date the log itself carries, and
an episode's tail must be 0..span_ms AFTER its head. A bound whose instant cannot be established
exits 2 and says why; it never degrades to a time-of-day match.

CODE (load-bearing, fixed strings the WU engine emits):
  resets      count of `*FAILED* [80072EFE]` on SendRequest/DownloadSession - WinHTTP 12030, a reset
              from the proxy side. The relay must never produce one: any reset is a FAIL.
  transient   count of "A transient error was identified and the network is not connected" - the
              NLA consult that on a NIC-less guest can park a synchronous search. Any is a FAIL.
  ended       the pass's search reached "All federated searches have completed" inside the window.
              Absent is a FAIL (the 2026-09-17 stall: the search never ended, the task's 2 h limit did).
  http_errors count of `*FAILED* [8019xxxx]` (an HTTP status the client recorded, e.g. a 403 from the
              relay) - the premise under test: a 403 must show up HERE and NOT as a transient.

JEV (semantic; owner 2026-09-18 "delegate to jev everything when feasible"): the lines the engine
writes after a download failure are not a fixed vocabulary once the relay answers 403 instead of
resetting, so each failure EPISODE (the failure line plus the next lines on the same thread) is
rubric-graded: what did the client do next - record a final error and proceed, retry then get the
file, or classify it transient and wait for the network? Any episode graded transient-network-wait
(p >= 0.5), and any grade with confidence < 0.7, is reported; the first is a FAIL, the second a flag
("no uncertainty anywhere" - a low-confidence grade names what still has to be read by hand).

Seen to FAIL on the stalled run's log (scratchpad/gweck25h2/slowscan/wulog-diag.txt, window
20:46:00-20:49:00): resets>0, transient>0, and the 20:47 search never ended.
"""
import argparse, json, os, re, sys
from datetime import datetime, timedelta, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jev import load_key, ask  # noqa: E402

WU = re.compile(r"^(\d{4})\.(\d\d)\.(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")
RESET = re.compile(r"\*FAILED\* \[80072EFE\]", re.I)
HTTPERR = re.compile(r"\*FAILED\* \[8019[0-9A-F]{4}\]", re.I)
TRANSIENT = "A transient error was identified and the network is not connected"
ENDED = "All federated searches have completed"
# One episode per download: the WinHttp SendRequest line (or an HTTP-status line) heads it; the
# DownloadSession/Library-download lines that follow on the same thread are its tail, not new heads.
FAILHEAD = re.compile(r"\*FAILED\* \[[0-9A-F]{8}\] .*(SendRequest|HTTP status)", re.I)
STARTED = "Federated Search: Starting search"

TOD = re.compile(r"^(\d\d):(\d\d):(\d\d)(?:\.(\d+))?$")
ABS = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(?:\.(\d+))?"
                 r"(Z|[+-]\d\d:?\d\d)?$")
TZ_SPEC = re.compile(r"^(?:(Z)|([+-])(\d\d):?(\d\d))$")


class Undatable(Exception):
    """A bound whose absolute instant cannot be established. The caller turns this into an
    INSTRUMENT exit (2), never into a verdict."""


def parse_tz(spec, what):
    """`Z` / `+03:00` / `-0500` -> a fixed-offset tzinfo. An unparsable zone raises; nothing is
    assumed about a stamp's zone."""
    if spec is None: return None
    m = TZ_SPEC.match(spec.strip())
    if not m: raise Undatable("%s=%r is not a zone offset (use Z, +03:00 or -0500)" % (what, spec))
    if m.group(1): return timezone.utc
    sign = -1 if m.group(2) == "-" else 1
    return timezone(sign * timedelta(hours=int(m.group(3)), minutes=int(m.group(4))))


def log_dates(path):
    """The dates the log carries, in file order, first occurrence only. One decode spans days."""
    seen = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU.match(line.rstrip("\n"))
        if m:
            d = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
            if d not in seen: seen.append(d)
    return seen


def _frac_us(frac):
    """The WU stamp's fraction is 7 digits (`.3142667`). Truncated to ms exactly as before, so a
    verdict on a single-day log does not move."""
    return int(((frac or "") + "000")[:3]) * 1000


def _abs_bound(spec, tz, what):
    """`YYYY-MM-DD HH:MM:SS[.frac][Z|+HH:MM]` -> an instant. None if the spec is not that shape."""
    m = ABS.match(spec.strip())
    if not m:
        return None
    if m.group(8) and tz is None:
        raise Undatable("%s=%r carries a zone but --tz is not set, so the log's own stamps have no "
                        "zone and the two cannot be compared. Pass --tz, or drop the zone."
                        % (what, spec))
    z = parse_tz(m.group(8), what) if m.group(8) else tz
    return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
                    int(m.group(5)), int(m.group(6)), _frac_us(m.group(7)), tzinfo=z)


def _tod(spec, what):
    m = TOD.match(spec.strip())
    if not m:
        raise Undatable("%s=%r is neither YYYY-MM-DD HH:MM:SS[.frac] nor HH:MM:SS[.frac]"
                        % (what, spec))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), _frac_us(m.group(4)))


def _at(d, tod, tz):
    return datetime(d[0], d[1], d[2], tod[0], tod[1], tod[2], tod[3], tzinfo=tz)


def window(spec0, spec1, path, dates, tz):
    """The two bounds -> ONE ABSOLUTE INTERVAL, resolved as a PAIR.

    A bare `HH:MM:SS` pair is the old call shape and keeps working, because its date is resolved
    from the interval: the date is the single one in the log that has a row between the two times of
    day. That is why the documented invocation (`--from 20:46:00 --to 20:49:00` on
    scratchpad/gweck25h2/slowscan/wulog-diag.txt, a log carrying 2026.09.16 AND 2026.09.17) still
    reads the same 505 rows and returns the same verdict - the fix is correctness, not a behaviour
    change. Where TWO dates have rows in the interval the old code quietly took them all, and that
    is the blind gate, so it refuses and names them."""
    a0, a1 = _abs_bound(spec0, tz, "--from"), _abs_bound(spec1, tz, "--to")
    if a0 and a1:
        return a0, a1, "given/given"
    if a0 or a1:
        # One bound dated, the other bare: the bare one takes the dated one's date. A --to that then
        # lands before --from can only be the next day, and the report says it was rolled.
        if a0:
            t1 = _at((a0.year, a0.month, a0.day), _tod(spec1, "--to"), a0.tzinfo)
            if t1 < a0: return a0, t1 + timedelta(days=1), "given/rolled+1d"
            return a0, t1, "given/from--from"
        t0 = _at((a1.year, a1.month, a1.day), _tod(spec0, "--from"), a1.tzinfo)
        if a1 < t0: return t0 - timedelta(days=1), a1, "rolled-1d/given"
        return t0, a1, "from--to/given"
    tod0, tod1 = _tod(spec0, "--from"), _tod(spec1, "--to")
    if tod1 < tod0:
        raise Undatable("--from=%s is later in the day than --to=%s: a bare HH:MM:SS pair cannot "
                        "express a window that crosses midnight, and %s really does carry %d date(s) "
                        "(%s). Give both bounds as YYYY-MM-DD HH:MM:SS."
                        % (spec0, spec1, path, len(dates),
                           ", ".join("%04d-%02d-%02d" % d for d in dates) or "none"))
    hit = []
    for line in open(path, encoding="utf-8", errors="replace"):
        q = WU.match(line.rstrip("\n"))
        if not q: continue
        rt = (int(q.group(4)), int(q.group(5)), int(q.group(6)), _frac_us(q.group(7)))
        if not (tod0 <= rt <= tod1): continue
        d = (int(q.group(1)), int(q.group(2)), int(q.group(3)))
        if d not in hit: hit.append(d)
    if len(hit) > 1:
        raise Undatable("--from/--to are bare times of day and %s has rows between them on %d dates "
                        "(%s), so the window would take them all - a row from one day would settle "
                        "the verdict on another. Give both bounds as YYYY-MM-DD HH:MM:SS."
                        % (path, len(hit), ", ".join("%04d-%02d-%02d" % d for d in hit)))
    if not hit:
        raise Undatable("--from/--to are bare times of day and %s has NO row between them on any of "
                        "its %d date(s) (%s), so the window has no date. Give both bounds as "
                        "YYYY-MM-DD HH:MM:SS."
                        % (path, len(dates), ", ".join("%04d-%02d-%02d" % d for d in dates) or "none"))
    d = hit[0]
    return _at(d, tod0, tz), _at(d, tod1, tz), "resolved:%04d-%02d-%02d" % d


def parse(path, t0, t1, tz=None):
    """Rows as ABSOLUTE INSTANTS, selected by an absolute interval. The date is the log's own
    (`2026.09.17 19:02:25.3141907`), which this used to parse and then discard."""
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU.match(line.rstrip("\n"))
        if not m: continue
        t = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
                     int(m.group(5)), int(m.group(6)), _frac_us(m.group(7)), tzinfo=tz)
        if t < t0 or t > t1: continue
        rows.append({"t": t, "pid": m.group(8), "tid": m.group(9), "comp": m.group(10), "msg": m.group(11)})
    return rows

def episodes(rows, follow=6, span_ms=3000):
    """An episode's tail must fall 0..span_ms AFTER its head.

    The old bound was `delta > span_ms`, which is never true for a NEGATIVE delta, so every row at
    an earlier time of day joined the episode however far away it really was - measured: a line
    2 h 10 min later glued onto a head at 23:59:50 because it read as -79200 s. A backward step is
    now a break AND a counted fact, because on this rig the guest clock really does jump (a
    health.json here carries `"boot_skew_s": -10720`) and a silent reorder would grade a composite
    nobody saw."""
    eps, backward = [], 0
    for i, r in enumerate(rows):
        if not FAILHEAD.search(r["msg"]): continue
        if not (RESET.search(r["msg"]) or HTTPERR.search(r["msg"]) or "SendRequest" in r["msg"]): continue
        seq = [r["msg"]]
        for r2 in rows[i + 1:]:
            if r2["tid"] != r["tid"]: continue
            delta_ms = (r2["t"] - r["t"]).total_seconds() * 1000
            if delta_ms < 0: backward += 1; break
            if delta_ms > span_ms or len(seq) > follow: break
            if FAILHEAD.search(r2["msg"]): break   # the NEXT download's failure starts a new episode; never mix two
            seq.append(r2["msg"])
        eps.append({"t": r["t"].isoformat(sep=" "), "tid": r["tid"], "lines": seq})
    return eps, backward

QUESTIONS = {
    "next": {
        "type": "choice",
        "instructions": {"judge": "These are consecutive Windows Update engine log lines on one thread, starting at a download failure through the local proxy at 127.0.0.1:8082. What did the client DO after the failure, according to these lines?",
                         "context": "The guest has no network adapter, so the Network List Manager always reports 'not connected'. If the engine classifies a failure as a transient NETWORK error it consults NLA and waits for a network event that never comes; the synchronous search then never returns. An HTTP status the engine records (e.g. 403) is a final answer for that file."},
        "criteria": {
            "final-error-recorded": "the engine recorded an HTTP-level or definitive error for the file and moved on (no transient classification, no NLA wait)",
            "retried-then-served": "the engine retried and a later line shows the download or the operation succeeding",
            "transient-network-wait": "the engine classified the failure as a transient network error, reduced or scheduled retries, consulted network state, and there is no sign it moved on",
            "not-a-download-outcome": "the lines do not describe what happened after a download failure",
        },
    },
    "parked": {
        "type": "noul",
        "instructions": "Do these lines show the Windows Update engine treating the failure as a transient network problem to wait out (rather than a final result to record)?",
        "criteria": {"true": "yes - transient classification, retry scheduling tied to network state, no final result",
                     "false": "no - a final result was recorded, or a retry succeeded"},
    },
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wu-log", required=True); ap.add_argument("--from", dest="t0", required=True); ap.add_argument("--to", dest="t1", required=True)
    ap.add_argument("--limit", type=int, default=40, help="max episodes sent to Jev (cost bound; the code facts always cover the whole window)")
    ap.add_argument("--no-judge", action="store_true"); ap.add_argument("--json")
    ap.add_argument("--tz", help="zone of the log's stamps (Z, +03:00, -0500). Needed only to "
                                 "compare against a ZONED --from/--to, e.g. a UTC bound read off a "
                                 "harness run.log against a guest-local decode.")
    a = ap.parse_args()
    # ---- THE WINDOW BECOMES ONE ABSOLUTE INTERVAL BEFORE ANY ROW IS SELECTED ------------------
    # Every refusal here is exit 2 (INSTRUMENT). A window whose date cannot be established has not
    # measured a clean pass; it has measured nothing, and saying PASS is the defect.
    try:
        tz = parse_tz(a.tz, "--tz")
        dates = log_dates(a.wu_log)
        t0, t1, how = window(a.t0, a.t1, a.wu_log, dates, tz)
        if t1 < t0:
            raise Undatable("--from=%s resolves to %s, after --to=%s (%s) - an empty interval"
                            % (a.t0, t0.isoformat(sep=" "), a.t1, t1.isoformat(sep=" ")))
    except (Undatable, ValueError) as e:
        print("INSTRUMENT: %s" % e); sys.exit(2)
    rows = parse(a.wu_log, t0, t1, tz)
    if not rows:
        print("INSTRUMENT: no WU log rows in window %s-%s (resolved to %s .. %s)"
              % (a.t0, a.t1, t0.isoformat(sep=" "), t1.isoformat(sep=" "))); sys.exit(2)
    facts = {
        "rows": len(rows),
        "resets": sum(1 for r in rows if RESET.search(r["msg"]) and ("SendRequest" in r["msg"] or "DownloadSession" in r["msg"])),
        "transient": sum(1 for r in rows if TRANSIENT in r["msg"]),
        "http_errors": sum(1 for r in rows if HTTPERR.search(r["msg"])),
        "last_row": rows[-1]["t"].isoformat(sep=" ").replace(" ", "T"),
    }
    # "ended" means the LAST search started in the window reached its END - not merely that some
    # search did. The stalled run had two searches in one pass: the first ended, the second never did.
    starts = [i for i, r in enumerate(rows) if STARTED in r["msg"]]
    facts["searches"] = len(starts)
    facts["ended"] = bool(starts) and any(ENDED in r["msg"] for r in rows[starts[-1]:])
    eps, backward = episodes(rows)
    facts["episodes"] = len(eps)
    # APPENDED, never inserted: a field added in front of this line blinds every reader anchored on
    # a position in it. New facts go at the end, in this order, forever.
    facts["window"] = "%s/%s" % (t0.isoformat().replace(" ", "T"), t1.isoformat().replace(" ", "T"))
    facts["window_dates"] = how
    facts["log_dates"] = len(dates)
    facts["clock_backward_steps"] = backward
    fails, flags, graded = [], [], []
    if facts["resets"]: fails.append("RESETS: %d download failures were 80072EFE (reset by the relay side)" % facts["resets"])
    if facts["transient"]: fails.append("TRANSIENT: %d '%s' lines" % (facts["transient"], TRANSIENT[:40]))
    if not facts["ended"]: fails.append("NOT ENDED: the last of %d search(es) in the window never reached '%s'" % (facts["searches"], ENDED))
    # A clock that stepped back inside the window is not an episode boundary to swallow quietly: the
    # rows after the step are not where they look, so whatever was graded around it is suspect.
    if backward: flags.append("CLOCK: %d backward step(s) inside the window - an episode was cut "
                              "there rather than grading lines the guest never saw in that order" % backward)
    if not a.no_judge and eps:
        key = load_key()
        if not key: print("INSTRUMENT: no API key"); sys.exit(2)
        if len(eps) > a.limit: flags.append("COVERAGE: %d of %d episodes sent to Jev (--limit)" % (a.limit, len(eps)))
        for e in eps[:a.limit]:
            r = ask(key, {"episode_lines": e["lines"]}, QUESTIONS)["answers"]
            g = {"t": e["t"], "next": r["next"]["choice"], "conf": r["next"]["confidence"], "parked": r["parked"]["noul"], "head": e["lines"][0][:110]}
            graded.append(g)
            if g["next"] == "transient-network-wait" and g["parked"] >= 0.5: fails.append("JEV transient-wait %s p=%.2f: %s" % (g["t"], g["parked"], g["head"]))
            elif g["conf"] < 0.7: flags.append("JEV low-confidence %s (%s conf=%.2f): %s" % (g["t"], g["next"], g["conf"], g["head"]))
    # The episodes themselves, so the --no-judge run can be checked offline: before the fix the only
    # visible trace of a composite episode was a count.
    report = {"facts": facts, "graded": graded, "fails": fails, "flags": flags, "episodes": eps}
    if a.json: json.dump(report, open(a.json, "w"), indent=1)
    print("facts: " + " ".join("%s=%s" % kv for kv in facts.items()))
    for f in fails: print("  FAIL", f)
    for f in flags: print("  FLAG", f)
    print("verdict: %s" % ("FAIL" if fails else "PASS"))
    sys.exit(3 if fails else 0)

if __name__ == "__main__":
    main()
