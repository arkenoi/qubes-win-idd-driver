#!/usr/bin/env python3
"""relay-fix-judge.py - grade the update relay's DECISION TABLE against the owner's rule with TypeSafe.

The rule (owner, 2026-09-17): "a sanctioned path should work, a non-sanctioned path should be properly
blocked. no uncertainty anywhere." And: "hard fails immediately, not waits, not retries."

This is NOT a log classifier (structured relay lines need no model; see relay-log-judge.py, whose
decisive gap check is plain code). It grades the FIX LOGIC: every row of the relay's decision table
(guest/qubes-updates-relay.cs, file header "THE RELAY SERVES OR REFUSES") is posed to Jev as a rubric
judgment, with the measured Windows Update behaviour as state:

  outcome   Choice  {final-answer, transient-to-client, no-answer}  - what the CLIENT is left holding
  can_wait  Noul    would Windows Update, on a NIC-less guest where NLA always says "not connected",
                    treat this as a network transient and park waiting for a network event?

Plus the load-bearing premise, asked once: does a 403 Forbidden + Connection: close from the proxy
count to Windows Update as a final failure (no NLA wait)?

A row whose outcome is not the one the table intends, a row with can_wait >= 0.3, or any answer with
confidence < 0.7 is reported as a DESIGN FLAG - the rule forbids uncertainty, so an uncertain
judgment is itself the finding. Exit 0 = table clean, 3 = flags, 2 = instrument error.

A model's probability is NOT evidence of Windows Update's actual behaviour; that comes from the guest
run. This grades the design for internal consistency and surfaces what still needs measuring.
Key: ~/.config/qwt-secrets/typesafe.key or TYPESAFE_API_KEY, never printed.
"""
import json, os, sys, time, urllib.request, urllib.error

API = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
KEYFILE = os.path.expanduser("~/.config/qwt-secrets/typesafe.key")

def load_key():
    k = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not k and os.path.exists(KEYFILE):
        k = open(KEYFILE, encoding="utf-8").read().strip()
    return k

def ask(key, state, questions):
    body = json.dumps({"state": state, "model": MODEL, "questions": questions}).encode()
    req = urllib.request.Request(API, data=body, method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    last = None
    for i in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode())["answers"]
        except urllib.error.HTTPError as e:
            last = "HTTP %d %s" % (e.code, e.read()[:200].decode(errors="replace"))
            if e.code in (400, 401, 403, 422): break
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
        time.sleep(1 + i)
    raise RuntimeError("TypeSafe: " + str(last))

RULE = ("The relay sits at 127.0.0.1:8082 between the Windows Update client on a guest with NO network "
        "adapter and the update servers. Rule: a sanctioned request (allowlisted host, update process) "
        "must be SERVED; anything non-sanctioned must be refused immediately and finally; the relay must "
        "never leave the client holding a failure it would classify as a transient network error.")

MEASURED = ("Measured 2026-09-17 in the decoded Windows Update log: when the relay reset a download "
            "connection (WinHTTP 12030 / 80072EFE), the client logged 'A transient error was identified "
            "and the network is not connected. Reducing the total number of retries', then 'Will retry', "
            "and the synchronous search parked until the scheduler killed it two hours later. On this "
            "guest NLA always reports the network as NOT connected, so any transient classification waits "
            "for a network event that never comes.")

# The decision table exactly as the shipped code implements it (ff19d8d). `intended` is what the
# design claims the client ends up holding.
ROWS = [
    {"id": "served",
     "request_class": "sanctioned host, update process, a relay channel is available (warm or freshly opened)",
     "relay_response": "the upstream HTTP response is relayed in full; its header block is rewritten to say Connection: close; the socket is then closed",
     "intended": "final-answer"},
    {"id": "no-channel",
     "request_class": "sanctioned host, update process, but the relay cannot open a channel to the proxy qube (qrexec spawn or connect-back failed)",
     "relay_response": "HTTP/1.1 403 Forbidden, X-Qubes-Relay: no-channel, Content-Length: 0, Connection: close; then the socket is closed; a CLOSE line is logged",
     "intended": "final-answer"},
    {"id": "incomplete",
     "request_class": "sanctioned host, update process, but the upstream body arrived truncated on every retry",
     "relay_response": "HTTP/1.1 403 Forbidden, X-Qubes-Relay: incomplete, Content-Length: 0, Connection: close; logged as PLAIN REFUSED",
     "intended": "final-answer"},
    {"id": "bad-host",
     "request_class": "the request names a host that is not on the allowlist",
     "relay_response": "HTTP/1.1 403 Forbidden, Content-Length: 0, Connection: close; logged as DENY host=",
     "intended": "final-answer"},
    {"id": "bad-peer",
     "request_class": "the connecting process is not an update process (not wuauserv/BITS/DoSvc/cryptsvc/TrustedInstaller/the updater) - e.g. telemetry, Defender, a browser",
     "relay_response": "the connection is aborted with a TCP RST before any byte is read (SO_LINGER 0); nothing is written; logged as DENY <process> (repeats within 60 s counted and flushed)",
     # A non-update process is MEANT to see an unreachable proxy; it is not the update client, so the
     # can_wait question (about the update client parking) does not apply to this row.
     "intended": "transient-to-client", "wu_client": False},
    {"id": "read-first-empty",
     "request_class": "the client connected and then closed without sending a single byte (a speculative pre-connect)",
     "relay_response": "the socket is closed; logged as CLOSE reason=read-first-empty",
     "intended": "no-answer"},
    {"id": "stale-map-miss",
     "request_class": "the update service (wuauserv) started AFTER the relay built its service-to-pid map, and dials within the map's TTL",
     "relay_response": "the map treats a miss as unknown and re-enumerates the SCM before deciding, so the caller is recognised and SERVED; a miss is never answered from the stale map",
     "intended": "final-answer"},
]

def row_questions():
    return {
        "outcome": {
            "type": "choice",
            "instructions": {"judge": "What is the CLIENT (the Windows Update download library, via WinHTTP with proxy 127.0.0.1:8082) left holding after `row.relay_response`, for the request described in `row.request_class`?",
                             "rule": "`rule`", "measured": "`measured`"},
            "criteria": {
                "final-answer": "a definitive HTTP response (a relayed 200, or a 403) that the client records as the result and does not retry as a network problem",
                "transient-to-client": "a socket-level failure - reset, abort, close-before-response, timeout, or a 5xx - that the client classifies as a transient network error and retries or waits on",
                "no-answer": "no request was ever made or the client never expected an answer, so nothing is held",
            },
        },
        "can_wait": {
            "type": "noul",
            "instructions": {"judge": "Given `measured` (this guest's NLA always says the network is NOT connected), would the Windows Update client, after `row.relay_response`, classify the outcome as a transient network error and park waiting for a network event?",
                             "rule": "`rule`"},
            "criteria": {"true": "yes - the client sees a reset/abort/timeout/5xx, calls it transient, consults NLA, and waits",
                         "false": "no - the client holds a definitive answer (or made no request) and proceeds"},
        },
    }

PREMISE_Q = {
    "final_403": {
        "type": "noul",
        "instructions": {"judge": "The whole design relies on this: when the proxy answers a Windows Update download request with `HTTP/1.1 403 Forbidden` + `Connection: close` (empty body), does the Windows Update download library treat that as a FINAL failure for that file (an HTTP error it records and moves on from), rather than as a transient network error it retries and, on a NIC-less guest, parks on?",
                         "measured": "`measured`"},
        "criteria": {"true": "a 403 is an HTTP-level result: recorded as the file's error, no NLA consultation, no parking",
                     "false": "a 403 from the proxy is folded into the same transient/retry path as a reset"},
    },
    "rst_bad_peer_ok": {
        "type": "noul",
        "instructions": {"judge": "For a process that is NOT part of the update (telemetry, Defender, a browser) the relay aborts the connection with a TCP RST before reading a byte. Is that the correct treatment under `rule` - i.e. does a non-update process seeing an unreachable proxy satisfy 'blocked immediately and finally' without creating a transient that the UPDATE client would wait on?",
                         "rule": "`rule`"},
        "criteria": {"true": "yes - it is not the update client, so its transient is its own; the update path is unaffected",
                     "false": "no - the RST leaks into the update path or leaves something waiting"},
    },
}

def main():
    key = load_key()
    if not key:
        print("INSTRUMENT: no API key"); sys.exit(2)
    flags = []
    report = {"rows": [], "premise": None}
    for row in ROWS:
        a = ask(key, {"rule": RULE, "measured": MEASURED, "row": row}, row_questions())
        o, w = a["outcome"], a["can_wait"]
        rec = {"id": row["id"], "intended": row["intended"], "outcome": o["choice"], "confidence": o["confidence"],
               "probabilities": o["probabilities"], "can_wait": w["noul"]}
        report["rows"].append(rec)
        why = []
        if o["choice"] != row["intended"]: why.append("outcome=%s intended=%s" % (o["choice"], row["intended"]))
        if o["confidence"] < 0.7: why.append("confidence=%.2f" % o["confidence"])
        if w["noul"] >= 0.3 and row.get("wu_client", True): why.append("can_wait=%.2f" % w["noul"])
        line = "%-17s outcome=%-20s conf=%.2f can_wait=%.2f" % (row["id"], o["choice"], o["confidence"], w["noul"])
        if why:
            flags.append("%s: %s" % (row["id"], "; ".join(why))); line += "   <-- FLAG"
        print(line)
    p = ask(key, {"measured": MEASURED, "rule": RULE}, PREMISE_Q)
    report["premise"] = {k: v["noul"] for k, v in p.items()}
    print("premise: 403-is-final p=%.2f   rst-for-non-update-peer-is-correct p=%.2f" % (p["final_403"]["noul"], p["rst_bad_peer_ok"]["noul"]))
    if p["final_403"]["noul"] < 0.7: flags.append("PREMISE: 403-is-final only p=%.2f - must be measured on the guest before the fix is called verified" % p["final_403"]["noul"])
    if p["rst_bad_peer_ok"]["noul"] < 0.7: flags.append("PREMISE: RST for non-update peer p=%.2f" % p["rst_bad_peer_ok"]["noul"])
    out = os.environ.get("RELAYFIX_JSON")
    if out:
        json.dump(report, open(out, "w"), indent=1)
    print("flags=%d" % len(flags))
    for f in flags: print("  DESIGN FLAG", f)
    sys.exit(3 if flags else 0)

if __name__ == "__main__":
    main()
