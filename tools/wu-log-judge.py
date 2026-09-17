#!/usr/bin/env python3
"""wu-log-judge.py - did a Windows Update pass through our relay ever enter the transient/NLA-wait path?

    tools/wu-log-judge.py --wu-log DECODED.txt --from HH:MM:SS --to HH:MM:SS [--limit N] [--json out]

Input: the decoded Windows Update log (Get-WindowsUpdateLog; works offline on the guest in ~21 s) and
the wall-clock window of ONE update pass. Verdict (exit 0 PASS, 3 FAIL, 2 instrument):

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
from datetime import timedelta
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

def hms(s):
    h, m, sec = s.split(":")
    return timedelta(hours=int(h), minutes=int(m), seconds=int(sec))

def parse(path, t0, t1):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = WU.match(line.rstrip("\n"))
        if not m: continue
        t = timedelta(hours=int(m.group(4)), minutes=int(m.group(5)), seconds=int(m.group(6)), milliseconds=int(m.group(7)[:3]))
        if t < t0 or t > t1: continue
        rows.append({"t": t, "pid": m.group(8), "tid": m.group(9), "comp": m.group(10), "msg": m.group(11)})
    return rows

def episodes(rows, follow=6, span_ms=3000):
    eps = []
    for i, r in enumerate(rows):
        if not FAILHEAD.search(r["msg"]): continue
        if not (RESET.search(r["msg"]) or HTTPERR.search(r["msg"]) or "SendRequest" in r["msg"]): continue
        seq = [r["msg"]]
        for r2 in rows[i + 1:]:
            if r2["tid"] != r["tid"]: continue
            if (r2["t"] - r["t"]).total_seconds() * 1000 > span_ms or len(seq) > follow: break
            seq.append(r2["msg"])
        eps.append({"t": str(r["t"]), "tid": r["tid"], "lines": seq})
    return eps

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
    a = ap.parse_args()
    rows = parse(a.wu_log, hms(a.t0), hms(a.t1))
    if not rows:
        print("INSTRUMENT: no WU log rows in window %s-%s" % (a.t0, a.t1)); sys.exit(2)
    facts = {
        "rows": len(rows),
        "resets": sum(1 for r in rows if RESET.search(r["msg"]) and ("SendRequest" in r["msg"] or "DownloadSession" in r["msg"])),
        "transient": sum(1 for r in rows if TRANSIENT in r["msg"]),
        "http_errors": sum(1 for r in rows if HTTPERR.search(r["msg"])),
        "last_row": str(rows[-1]["t"]),
    }
    # "ended" means the LAST search started in the window reached its END - not merely that some
    # search did. The stalled run had two searches in one pass: the first ended, the second never did.
    starts = [i for i, r in enumerate(rows) if STARTED in r["msg"]]
    facts["searches"] = len(starts)
    facts["ended"] = bool(starts) and any(ENDED in r["msg"] for r in rows[starts[-1]:])
    eps = episodes(rows)
    facts["episodes"] = len(eps)
    fails, flags, graded = [], [], []
    if facts["resets"]: fails.append("RESETS: %d download failures were 80072EFE (reset by the relay side)" % facts["resets"])
    if facts["transient"]: fails.append("TRANSIENT: %d '%s' lines" % (facts["transient"], TRANSIENT[:40]))
    if not facts["ended"]: fails.append("NOT ENDED: the last of %d search(es) in the window never reached '%s'" % (facts["searches"], ENDED))
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
    report = {"facts": facts, "graded": graded, "fails": fails, "flags": flags}
    if a.json: json.dump(report, open(a.json, "w"), indent=1)
    print("facts: " + " ".join("%s=%s" % kv for kv in facts.items()))
    for f in fails: print("  FAIL", f)
    for f in flags: print("  FLAG", f)
    print("verdict: %s" % ("FAIL" if fails else "PASS"))
    sys.exit(3 if fails else 0)

if __name__ == "__main__":
    main()
