#!/usr/bin/env python3
"""relay-log-judge.py - verify the update relay's log against the owner's rule with TypeSafe judgments.

THE RULE (owner, 2026-09-17): "a sanctioned path should work, a non-sanctioned path should be properly
blocked. no uncertainty anywhere." And: "it should be pointed to something that hard fails
immediately, not waits, not retries."

WHAT THIS CHECKS, given the relay log (C:\\ProgramData\\Qubes\\wu\\qubes-updates-relay.log pulled from
the guest) and optionally the decoded Windows Update log (Get-WindowsUpdateLog output):
  1. CODE, not judgment - the GAP check: every Windows Update download failure (WinHTTP 12030/12029/
     12002, "*FAILED* [80072EFE]" etc.) must have a relay line within +-2 s that accounts for it
     (a served response, a DENY, or a CLOSE with a reason). A failure the relay never logged is the
     2026-09-17 defect: 21 resets, zero lines, a search parked for two hours.
  2. JUDGMENT (TypeSafe System One, model jev-latest) - each relay event line is classified into the
     rule's categories:
        sanctioned-served          the request was served (200/response relayed)
        non-sanctioned-blocked     denied immediately and finally (403 / policy RST)
        sanctioned-not-served      a request that should have been served was closed, reset, 5xx'd,
                                   or otherwise handed a failure the client would treat as transient
        not-a-request              pool/stat/housekeeping line
     plus a Noul: "would a Windows Update client treat this outcome as a transient network failure
     and retry or wait?" Any sanctioned-not-served, any transient=yes on a non-housekeeping line, and
     any GAP is a VIOLATION. Exit 0 = no violation, 3 = violations, 2 = instrument error.

WHY A JUDGMENT: the relay's lines are free text that has changed shape across commits (PLAIN/CONN/
DENY/POOL/CLOSE ...). A regex per shape is a check that silently stops matching when the shape moves;
a rubric-driven judgment keeps classifying, and its probabilities flag what it is unsure about, which
the rule forbids ("no uncertainty anywhere") - low-confidence classifications are reported as such.

TIME IS ABSOLUTE HERE, NEVER A TIME OF DAY. Until 2026-10-19 both logs were parsed into a bare
`timedelta` - a time of day with no date and no zone - and the GAP check correlated the two sources
by `abs(tt - t)`. Two consequences, both measured on this repo's own evidence:
  * ACROSS MIDNIGHT a served download 2 s before a failure reads as 86398 s away, so the window
    finds nothing and the judge reports the absence as a finding ("NO relay line for this
    download") instead of saying it could not correlate. Campaigns here routinely cross midnight
    (the 4.3.37 acceptance ran 20:21 -> 02:24).
  * THE OTHER DIRECTION IS WORSE AND SILENT: the relay log is append-only across days
    (guest/qubes-updates-relay.cs Log(): `File.AppendAllText(path, DateTime.Now.ToString(
    "HH:mm:ss.fff") + ...)` - no date, no zone, no rotation), so a line from LAST WEEK at the same
    time of day lands inside +-2 s and accounts for today's failure. Measured pre-fix: a relay line
    at 05:13:45 and a WU failure 24 h later at 05:13:46 gave `gaps=0 violations=0`, exit 0 - a
    clean PASS over a correlation of nothing. A real capture shows how wide the file is:
    qwt-accept/rel-39175573529/template-update.d/wu-e2e/round1/relay.log is 3048 lines whose
    stamps run 19:41 -> 19:03 -> 05:02 -> 05:14, several days in one file.
So every stamp becomes ONE ABSOLUTE INSTANT at parse time. The WU log already carries its date
(`2026.09.17 19:02:25.3141907`); the relay log carries none, so its date must be SUPPLIED
(--relay-date) and is never guessed. When the two sources are on different clocks, declare both
zones (--relay-tz/--wu-tz). If an instant cannot be established the judge exits 2 and says why; it
never falls back to a time-of-day comparison, because that fallback yields a pass.

The API key is read from ~/.config/qwt-secrets/typesafe.key (owner-only file, outside the repo) or
from TYPESAFE_API_KEY. It is never printed. Usage:
  tools/relay-log-judge.py --relay-log <file> [--wu-log <file>] [--no-judge] [--json out.json]
                           [--relay-date YYYY-MM-DD] [--relay-tz +03:00] [--wu-tz Z]
  --no-judge runs only the code-level GAP check (no network, no key).
  --relay-date is REQUIRED with --wu-log: it dates the relay log's FIRST stamp, and the date rolls
  forward at each midnight crossing. It is NOT inferred from the WU log - "the relay log is on the
  WU log's date" cannot be falsified from the data, and when it is wrong the inference returns a
  clean PASS, which is the defect this guards.
  --relay-tz/--wu-tz declare the two sources' zones; give both or neither. Neither means one shared
  clock, which is today's rig (both logs are written by the guest), and the report says so.
"""
import argparse, json, os, re, sys, time, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jev import load_key, ask, KEYFILE  # one wire-logged call path for every Jev request

# ---- parsing ----------------------------------------------------------------------------------
RELAY_TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3})\s+(.*)$")
WU_TS = re.compile(r"^(\d{4})\.(\d\d)\.(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")
WU_FAIL = re.compile(r"\*FAILED\* \[(80072EFE|80072EE7|80072EFD|80072EE2|80072F78|80072EF3)\]", re.I)
# The download's own identity: msdownload URLs end in <8+ digits>_<hex>. It is carried identically by
# the WU failure line and by the relay line that served or refused it, so it matches a failure to its
# relay outcome by CAUSATION - which request - not by timestamp proximity. Proximity credited an
# unrelated DENY a second away; the URL token cannot be fooled that way.
URLTOK = re.compile(r"/(?:others|[a-z])/[^ \]\"<]*?/(\d{6,}_[0-9a-f]{6,})", re.I)

ISO_DATE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)$")
TZ_SPEC = re.compile(r"^(?:(Z)|([+-])(\d\d):?(\d\d))$")
# A stamp that goes BACKWARD by no more than this is thread jitter around one append lock, not a
# new day; anything larger is a midnight crossing or an undatable clock jump.
JITTER_S = 1.0


class Undatable(Exception):
    """A stamp whose absolute instant cannot be established. Loud by construction: the caller turns
    this into an INSTRUMENT exit, never into a verdict."""


def parse_tz(spec, what):
    """`Z` / `+03:00` / `-0500` -> a fixed-offset tzinfo. No guessing: an unparsable zone raises."""
    if spec is None:
        return None
    m = TZ_SPEC.match(spec.strip())
    if not m:
        raise Undatable("%s=%r is not a zone offset (use Z, +03:00 or -0500)" % (what, spec))
    if m.group(1):
        return timezone.utc
    sign = -1 if m.group(2) == "-" else 1
    return timezone(sign * timedelta(hours=int(m.group(3)), minutes=int(m.group(4))))


def parse_relay(path, anchor_date, tz=None, single_day=False):
    """Parse the relay log into (absolute datetime, text), dating every stamp. Returns (events,
    backward_steps).

    The relay writes a bare local time of day (guest/qubes-updates-relay.cs Log()), append-only,
    never rotated, so the date comes from anchor_date - the date of the FIRST stamp in the file -
    and rolls forward at each midnight crossing (previous stamp >= 23:00, next < 01:00). ANY other
    backward step is a clock jump, a multi-day append gap or a damaged capture; none of those is
    datable from the file, so it raises instead of being guessed. That case is real, not
    hypothetical, and both kinds are on this qube:
      * qwt-accept/rel-39175573529/template-update.d/wu-e2e/round1/relay.log steps
        `19:41:56.550` -> `19:03:14.305` - days appended into one file.
      * scratchpad/gweck25h2/slowscan/relay-full-20260917.log ends on a TRUNCATED DUPLICATE of its
        own line 30, so line 33 steps back 43 s.
    single_day is the operator declaring a fact the file cannot show - "every stamp here is on
    anchor_date" - for exactly that second case. It suppresses the refusal, never the evidence: the
    steps are counted, returned, and printed."""
    ev, prev, day, backward = [], None, anchor_date, 0
    for lineno, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        m = RELAY_TS.match(line.rstrip("\n"))
        if not m:
            continue
        h, mi, s, ms, text = m.groups()
        tod = timedelta(hours=int(h), minutes=int(mi), seconds=int(s), milliseconds=int(ms))
        if prev is not None and tod < prev:
            back = (prev - tod).total_seconds()
            if back <= JITTER_S:
                pass                                  # same day, threads racing the append lock
            elif single_day:
                backward += 1                         # declared one day: keep the date, count it
            elif prev >= timedelta(hours=23) and tod < timedelta(hours=1):
                day = day + timedelta(days=1)         # midnight crossing, the only datable decrease
            else:
                raise Undatable(
                    "relay log %s line %d steps BACK %.0f s (%s -> %s) - that is a clock jump, a "
                    "multi-day append gap or a damaged capture, and no date can be read from the "
                    "file. Split the log at that line, pass the segment you mean, or - if you know "
                    "the whole file is one day - say so with --relay-single-day."
                    % (path, lineno, back, _tod(prev), _tod(tod)))
        prev = tod
        ev.append((datetime.combine(day, datetime.min.time(), tzinfo=tz) + tod, text))
    return ev, backward


def _tod(td):
    total = td.total_seconds()
    return "%02d:%02d:%06.3f" % (int(total // 3600), int(total % 3600 // 60), total % 60)


def parse_wu_failures(path, tz=None):
    """The decoded WU log carries its own date (`2026.09.17 19:02:25.3141907`), which this used to
    parse and then throw away. Millisecond truncation is kept exactly as before so verdicts on a
    single-day log do not move."""
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU_TS.match(line.rstrip("\n"))
        if not m:
            continue
        if not WU_FAIL.search(m.group(11)):
            continue
        if "DownloadSession" not in m.group(11) and "SendRequest" not in m.group(11):
            continue
        t = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)),
                     int(m.group(4)), int(m.group(5)), int(m.group(6)),
                     microsecond=int(m.group(7)[:3]) * 1000, tzinfo=tz)
        out.append((t, m.group(11)))
    return out


def wu_dates(path):
    """Every date the WU log carries, for --relay-date auto and for the loud message when it is
    ambiguous."""
    seen = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU_TS.match(line.rstrip("\n"))
        if m:
            d = "%s-%s-%s" % (m.group(1), m.group(2), m.group(3))
            if d not in seen:
                seen.append(d)
    return seen



HOUSEKEEPING = re.compile(r"^(POOL |CHAN |listen |PLAIN dead warm|PLAIN incomplete)")
# A relay line that actually reports a DOWNLOAD request's fate. A DENY (a different peer) and any POOL
# line are NOT an account for a WU download failure - crediting them was the proximity bug.
ACCOUNTS = re.compile(r"^(PLAIN tries=|PLAIN REFUSED|CLOSE reason=|CONN )")

def gap_check(relay, wufails, window=2.0):
    """A WU download failure is accounted for iff a relay line names the SAME download (URL token), or,
    for a failure whose line carries no token, a download-outcome line falls within +-window seconds.
    A DENY of another process or a POOL line never accounts for a download failure.

    The +-window arm compares ABSOLUTE INSTANTS. It used to compare times of day, so a relay line
    from another day at the same o'clock accounted for today's failure (gaps=0, exit 0) and a line
    2 s away across midnight did not. Both sides must be equally zone-aware; main() enforces that
    before calling, so a mismatch here would be a programming error, not bad input."""
    if relay and wufails and (relay[0][0].tzinfo is None) != (wufails[0][0].tzinfo is None):
        raise Undatable("relay and WU instants are not on the same timebase (one is zone-aware)")
    served_tokens = set()
    for _, x in relay:
        m = URLTOK.search(x)
        if m and ACCOUNTS.match(x):
            served_tokens.add(m.group(1).lower())
    outcomes = [(t, x) for t, x in relay if ACCOUNTS.match(x)]
    gaps = []
    for t, text in wufails:
        m = URLTOK.search(text)
        if m:
            if m.group(1).lower() not in served_tokens:
                gaps.append((t, text))           # this exact download has no served/refused relay line
        else:
            near = [x for (tt, x) in outcomes if abs((tt - t).total_seconds()) <= window]
            if not near:
                gaps.append((t, text))
    return gaps

# ---- judgment ---------------------------------------------------------------------------------
QUESTIONS = {
    "outcome": {
        "type": "choice",
        "instructions": ("This is one log line from an HTTP proxy relay that sits between the Windows Update client "
                         "on an offline guest and the update servers. Classify what happened to the CLIENT REQUEST "
                         "this line reports. The relay's rule: a sanctioned (allowlisted) request must be served; a "
                         "non-sanctioned one must be refused immediately and finally; nothing may be left in a state "
                         "the client would treat as a transient network failure."),
        "criteria": {
            "sanctioned-served": "the request was served: a response (200/PLAIN/CONN with bytes) was relayed to the client",
            "non-sanctioned-blocked": "the request or its process was denied immediately and finally: a 403, or a policy reset of a non-update process (DENY ...)",
            "sanctioned-not-served": "a request that should have been served was closed, reset, timed out, answered 5xx, or otherwise failed on the relay's side",
            "not-a-request": "pool/channel/statistics/startup housekeeping; no client request outcome is reported",
        },
    },
    "transient": {
        "type": "noul",
        "instructions": ("Would a Windows Update client receiving the outcome described by this line classify it as a "
                         "TRANSIENT network failure (connection reset/aborted/timeout/5xx) and retry or wait for the "
                         "network, rather than as a final answer (a served response or a definitive 403)?"),
        "criteria": {"true": "reset, abort, timeout, 502/503, or an unexplained close - the client retries or waits",
                     "false": "a served response, a 403, a policy reset of a process that is not the update client, or a line that reports no request outcome"},
    },
}

def stamp(t, dated):
    """How an instant is printed. With a real date (a correlation ran) the whole instant is shown;
    with the placeholder date only the time of day, which is byte-identical to the pre-2026-10-19
    output for the no---wu-log run - the only call shape that needs no new flag."""
    return t.isoformat(sep=" ") if dated else t.strftime("%H:%M:%S.%f")


def judge(key, relay, limit=None, sleep=0.0, dated=False):
    results = []
    lines = [(t, x) for t, x in relay if not HOUSEKEEPING.match(x)]
    if limit:
        lines = lines[:limit]
    for t, text in lines:
        r = ask(key, {"relay_log_line": text}, QUESTIONS)
        ch = (r.get("answers") or r).get("outcome", {})
        nl = (r.get("answers") or r).get("transient", {})
        results.append({"t": stamp(t, dated), "line": text, "outcome": ch.get("choice"), "confidence": ch.get("confidence"),
                        "probabilities": ch.get("probabilities"), "transient": nl.get("noul")})
        if sleep:
            time.sleep(sleep)
    return results

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--relay-log", required=True)
    ap.add_argument("--wu-log")
    ap.add_argument("--no-judge", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="judge at most N lines (cost bound)")
    ap.add_argument("--json")
    ap.add_argument("--relay-date", help="YYYY-MM-DD of the relay log's FIRST stamp. Required with "
                                         "--wu-log: the relay log carries no date, and it is not "
                                         "guessed from the WU log.")
    ap.add_argument("--relay-single-day", action="store_true",
                    help="declare that every stamp in the relay log is on --relay-date. Use it for "
                         "a capture whose stamps are not monotonic for a reason you know (a "
                         "truncated duplicate tail, a hand-assembled excerpt). The backward steps "
                         "are still counted and printed.")
    ap.add_argument("--relay-tz", help="zone of the relay log's stamps (Z, +03:00, -0500)")
    ap.add_argument("--wu-tz", help="zone of the WU log's stamps (Z, +03:00, -0500)")
    a = ap.parse_args()

    # ---- ONE TIMEBASE, ESTABLISHED BEFORE ANYTHING IS COMPARED ------------------------------
    # Every refusal below is exit 2 (INSTRUMENT), never a verdict. A judge that cannot put its two
    # sources on one timeline has not found "no violations"; it has found nothing.
    try:
        if (a.relay_tz is None) != (a.wu_tz is None):
            raise Undatable("--relay-tz and --wu-tz come as a pair: with only one, the two logs "
                            "cannot be put on one timeline. Give both, or neither (neither = one "
                            "shared clock, which is what the rig writes today).")
        rtz, wtz = parse_tz(a.relay_tz, "--relay-tz"), parse_tz(a.wu_tz, "--wu-tz")
        timebase = ("relay=%s wu=%s" % (a.relay_tz, a.wu_tz)) if rtz else "one-shared-clock"

        anchor, anchor_src, dates = None, None, []
        if a.wu_log:
            dates = wu_dates(a.wu_log)
            if a.relay_date is None:
                # NOT inferred from the WU log, deliberately. "The relay log is on the WU log's
                # date" is unfalsifiable from the data: a freshly pulled relay.log holds the
                # golden's whole history (3048 lines, several days), so a line from any earlier day
                # sits at the same o'clock and the inference would hand back a clean PASS. Missing
                # data fails here instead.
                raise Undatable(
                    "--wu-log correlates two sources, and the relay log carries NO date "
                    "(guest/qubes-updates-relay.cs logs HH:mm:ss.fff only), so the correlation has "
                    "no timebase. Pass --relay-date YYYY-MM-DD for the relay log's FIRST stamp%s."
                    % (" - the WU log covers %s, but the relay log's own date is not derivable "
                       "from that" % ", ".join(dates) if dates else ""))
        if a.relay_date is not None:
            if not ISO_DATE.match(a.relay_date):
                raise Undatable("--relay-date=%r is not YYYY-MM-DD" % a.relay_date)
            anchor, anchor_src = a.relay_date, "--relay-date"
        if anchor is None:
            # No cross-source correlation is asked for, so no date is load-bearing. Date the stamps
            # on a placeholder and SAY so, rather than fall back to a bare time of day.
            anchor, anchor_src = "1970-01-01", "placeholder (no --wu-log: nothing is correlated)"
        y, mo, d = (int(x) for x in anchor.split("-"))
        relay, backward = parse_relay(a.relay_log, datetime(y, mo, d).date(), rtz,
                                      a.relay_single_day)
        if a.relay_single_day:
            anchor_src += " +--relay-single-day"
    except (Undatable, ValueError) as e:
        print("INSTRUMENT: %s" % e); sys.exit(2)

    if not relay:
        print("INSTRUMENT: no relay lines parsed from", a.relay_log); sys.exit(2)
    report = {"relay_lines": len(relay), "gaps": [], "judged": [], "violations": [],
              "relay_date": anchor, "relay_date_source": anchor_src, "timebase": timebase,
              "relay_backward_steps": backward}
    if a.wu_log:
        try:
            wf = parse_wu_failures(a.wu_log, wtz)
            gaps = gap_check(relay, wf)
        except Undatable as e:
            print("INSTRUMENT: %s" % e); sys.exit(2)
        report["wu_failures"] = len(wf)
        report["wu_dates"] = dates
        report["gaps"] = [{"t": stamp(t, True), "wu": x[:160]} for t, x in gaps]
        for g in report["gaps"]:
            report["violations"].append("GAP: WU failure at %s has NO relay line for this download: %s" % (g["t"], g["wu"][:100]))
        report["distinct_failed_downloads"] = len({URLTOK.search(x[1]).group(1).lower() for x in wf if URLTOK.search(x[1])})
    if not a.no_judge:
        key = load_key()
        if not key:
            print("INSTRUMENT: no API key (TYPESAFE_API_KEY or %s)" % KEYFILE); sys.exit(2)
        judged = judge(key, relay, a.limit or None, dated=bool(a.wu_log))
        report["judged"] = judged
        for j in judged:
            low = (j.get("confidence") is not None and j["confidence"] < 0.6)
            if j["outcome"] == "sanctioned-not-served":
                report["violations"].append("NOT-SERVED %s: %s" % (j["t"], j["line"][:120]))
            elif j["outcome"] != "not-a-request" and (j.get("transient") or 0) >= 0.5:
                report["violations"].append("TRANSIENT-OUTCOME %s (p=%.2f): %s" % (j["t"], j["transient"], j["line"][:120]))
            elif low:
                report["violations"].append("UNCERTAIN %s (conf=%.2f, %s): %s" % (j["t"], j["confidence"], j["outcome"], j["line"][:120]))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1)
    # The leading fields keep their exact pre-2026-10-19 order and wording; the timebase is APPENDED,
    # because a field inserted in front blinds every position-anchored reader of this line.
    print("relay lines=%d judged=%d wu_failures=%s gaps=%d violations=%d relay_date=%s timebase=%s%s" % (
        report["relay_lines"], len(report["judged"]), report.get("wu_failures", "-"), len(report["gaps"]),
        len(report["violations"]), anchor, timebase,
        " relay_backward_steps=%d" % backward if backward else ""))
    # A declared one-day file whose stamps still step backward is an anomaly, announced rather than
    # absorbed: the rows after each step are not where they look, so the +-2 s arm around them is
    # weaker than it reads.
    if backward:
        print("  NOTE %d backward stamp step(s) in %s, dated anyway because --relay-single-day was "
              "given - the +-2 s arm around those lines is not trustworthy" % (backward, a.relay_log))
    for v in report["violations"][:40]:
        print("  VIOLATION", v)
    sys.exit(3 if report["violations"] else 0)

if __name__ == "__main__":
    main()
