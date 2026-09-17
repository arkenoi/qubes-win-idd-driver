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

The API key is read from ~/.config/qwt-secrets/typesafe.key (owner-only file, outside the repo) or
from TYPESAFE_API_KEY. It is never printed. Usage:
  tools/relay-log-judge.py --relay-log <file> [--wu-log <file>] [--no-judge] [--json out.json]
  --no-judge runs only the code-level GAP check (no network, no key).
"""
import argparse, json, os, re, sys, time, urllib.request, urllib.error
from datetime import datetime, timedelta

API = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
KEYFILE = os.path.expanduser("~/.config/qwt-secrets/typesafe.key")

def load_key():
    k = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not k and os.path.exists(KEYFILE):
        with open(KEYFILE, "r", encoding="utf-8") as f:
            k = f.read().strip()
    return k

def ask(key, state, questions, retries=3):
    body = json.dumps({"state": state, "model": MODEL, "questions": questions}).encode()
    req = urllib.request.Request(API, data=body, method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            last = "HTTP %d %s" % (e.code, e.read()[:200].decode(errors="replace"))
            if e.code in (401, 403, 400):
                break
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
        time.sleep(1 + i)
    raise RuntimeError("TypeSafe call failed: " + str(last))

# ---- parsing ----------------------------------------------------------------------------------
RELAY_TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3})\s+(.*)$")
WU_TS = re.compile(r"^(\d{4})\.(\d\d)\.(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$")
WU_FAIL = re.compile(r"\*FAILED\* \[(80072EFE|80072EE7|80072EFD|80072EE2|80072F78|80072EF3)\]", re.I)
# The download's own identity: msdownload URLs end in <8+ digits>_<hex>. It is carried identically by
# the WU failure line and by the relay line that served or refused it, so it matches a failure to its
# relay outcome by CAUSATION - which request - not by timestamp proximity. Proximity credited an
# unrelated DENY a second away; the URL token cannot be fooled that way.
URLTOK = re.compile(r"/(?:others|[a-z])/[^ \]\"<]*?/(\d{6,}_[0-9a-f]{6,})", re.I)

def parse_relay(path):
    ev = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = RELAY_TS.match(line.rstrip("\n"))
        if not m:
            continue
        h, mi, s, ms, text = m.groups()
        t = timedelta(hours=int(h), minutes=int(mi), seconds=int(s), milliseconds=int(ms))
        ev.append((t, text))
    return ev

def parse_wu_failures(path):
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU_TS.match(line.rstrip("\n"))
        if not m:
            continue
        if not WU_FAIL.search(m.group(11)):
            continue
        if "DownloadSession" not in m.group(11) and "SendRequest" not in m.group(11):
            continue
        t = timedelta(hours=int(m.group(4)), minutes=int(m.group(5)), seconds=int(m.group(6)),
                      milliseconds=int(m.group(7)[:3]))
        out.append((t, m.group(11)))
    return out

HOUSEKEEPING = re.compile(r"^(POOL |CHAN |listen |PLAIN dead warm|PLAIN incomplete)")
# A relay line that actually reports a DOWNLOAD request's fate. A DENY (a different peer) and any POOL
# line are NOT an account for a WU download failure - crediting them was the proximity bug.
ACCOUNTS = re.compile(r"^(PLAIN tries=|PLAIN REFUSED|CLOSE reason=|CONN )")

def gap_check(relay, wufails, window=2.0):
    """A WU download failure is accounted for iff a relay line names the SAME download (URL token), or,
    for a failure whose line carries no token, a download-outcome line falls within +-window seconds.
    A DENY of another process or a POOL line never accounts for a download failure."""
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

def judge(key, relay, limit=None, sleep=0.0):
    results = []
    lines = [(t, x) for t, x in relay if not HOUSEKEEPING.match(x)]
    if limit:
        lines = lines[:limit]
    for t, text in lines:
        r = ask(key, {"relay_log_line": text}, QUESTIONS)
        ch = (r.get("answers") or r).get("outcome", {})
        nl = (r.get("answers") or r).get("transient", {})
        results.append({"t": str(t), "line": text, "outcome": ch.get("choice"), "confidence": ch.get("confidence"),
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
    a = ap.parse_args()
    relay = parse_relay(a.relay_log)
    if not relay:
        print("INSTRUMENT: no relay lines parsed from", a.relay_log); sys.exit(2)
    report = {"relay_lines": len(relay), "gaps": [], "judged": [], "violations": []}
    if a.wu_log:
        wf = parse_wu_failures(a.wu_log)
        gaps = gap_check(relay, wf)
        report["wu_failures"] = len(wf)
        report["gaps"] = [{"t": str(t), "wu": x[:160]} for t, x in gaps]
        for g in report["gaps"]:
            report["violations"].append("GAP: WU failure at %s has NO relay line for this download: %s" % (g["t"], g["wu"][:100]))
        report["distinct_failed_downloads"] = len({URLTOK.search(x[1]).group(1).lower() for x in wf if URLTOK.search(x[1])})
    if not a.no_judge:
        key = load_key()
        if not key:
            print("INSTRUMENT: no API key (TYPESAFE_API_KEY or %s)" % KEYFILE); sys.exit(2)
        judged = judge(key, relay, a.limit or None)
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
    print("relay lines=%d judged=%d wu_failures=%s gaps=%d violations=%d" % (
        report["relay_lines"], len(report["judged"]), report.get("wu_failures", "-"), len(report["gaps"]), len(report["violations"])))
    for v in report["violations"][:40]:
        print("  VIOLATION", v)
    sys.exit(3 if report["violations"] else 0)

if __name__ == "__main__":
    main()
