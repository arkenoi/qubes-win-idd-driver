#!/usr/bin/env python3
"""dom0-sends-ledger.py <vm> <sends.txt> <ledger.jsonl> - append what dom0 was told, on THIS side.

THE INVARIANT, owner 2026-10-10, in capitals: "IF I SEE SOMETHING IN DOM0, YOU ARE SUPPOSED TO SEE THE
SAME IN LOGS, WITH ONE HUNDRED FUCKING PERCENT CERTAINTY AND ZERO FUCKING GUESSWORK, ALWAYS... I SHOULD
NEVER FUCKING EVER READ FUCKING TOASTS TO YOU ALOUD!"

It was not met, and the reason is structural rather than an oversight: every sender of ours DOES log its
own send, but that log lives on the guest's PRIVATE volume - it dies with a disposable AppVM and needs
the guest booted to read. A search of this whole side found zero pulled logs carrying a send tag, so
every dom0 toast ever discussed here came from his eyes. The record has to live on this side, and it
has to be written by the harness rather than by someone remembering to ask.

One JSON line per send: when it was pulled, which guest, which file and line, which ROUTE, and the text.
Append-only, so a run can never erase an earlier one's record.
"""
import json
import re
import sys
import time

# the route a line names, in the order that identifies it most precisely: the agent's own
# "notification for <id>" record first, then the log tag, then the dom0 service it called
ROUTE_RE = [
    # notifyerr.c:266 is THE record of a send - "NOTIFYERR <component>.<id> sent to dom0 (#N this
    # boot)" - and its siblings at 216/239/173/286 are the records of a send REFUSED. The first
    # version of this file did not grep NOTIFYERR at all, which would have pulled a record with
    # every send line missing: the same blindness one layer down.
    re.compile(r"NOTIFYERR ([A-Za-z0-9_-]+\.[A-Za-z0-9._-]+) (?:sent to dom0|not sent)"),
    re.compile(r"QGAERRBOX ([A-Za-z0-9_-]+\.[A-Za-z0-9._-]+)"),
    # the notifhost one-shot route: "<TAG>: user notification sent (...)" with no NOTIFYERR line.
    # Missing this is how a QGASTARTDISMISS toast reached the owner and not the ledger (2026-10-11).
    re.compile(r"\b(QGA[A-Z]+): user notification sent"),
    re.compile(r"notification(?: \(generic\))? for ([a-z0-9.-]+)"),
    re.compile(r"\b(QGANOTIFSESSION|QGAWGCDEAF|QGABROKERMISSING|QGADESKSTUCK|QGAUACPENDING|"
               r"QGABROKERDIED|QGABROKERHUNG|QGAWGCRECREATE|QGAWGCITEMCLOSED)\b"),
    re.compile(r"\b(qubes\.NotifyUpdates|qubes\.NotifyTools|qubes\.Notifications)\b"),
    re.compile(r"\b(listener-init|listener-denied|broker-died|broker-missing|deslice-down|"
               r"capture-deaf[a-z-]*|session-changed|uac-pending|desktop-stuck)\b"),
]
WHERE_RE = re.compile(r"^\[([^:\]]+):(\d+)\]\s*(.*)$")
# the decision the error route returned, which says whether dom0 was actually told
DECISION_RE = re.compile(r"(user notification sent[^\n]{0,40})"
                         r"|\b(QERR_[A-Z_]+|SUPPRESSED_DUPLICATE|CAPPED|REJECT[A-Z_]*)\b"
                         r"|(sent to dom0 \(#\d+ this boot\))|(not sent[^.]*)")


def decision(text):
    """what actually happened to the notification, in the sender's own words."""
    m = DECISION_RE.search(text)
    if not m:
        return None
    for g in m.groups():
        if g:
            return g.strip()
    return m.group(0)


def classify(text):
    for rx in ROUTE_RE:
        m = rx.search(text)
        if m:
            return m.group(1)
    return None


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().split("\n")[0], file=sys.stderr)
        return 2
    vm, src, led = argv[1], argv[2], argv[3]
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    rows = []
    with open(src, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            m = WHERE_RE.match(line)
            where, lineno, text = (m.group(1), int(m.group(2)), m.group(3)) if m else ("?", 0, line)
            rows.append({"pulled_at": now, "vm": vm, "file": where, "line": lineno,
                         "route": classify(text), "decision": decision(text),
                         "text": text[:400]})
    with open(led, "a", encoding="utf-8") as out:          # APPEND-ONLY: a run never erases another's
        for r in rows:
            out.write(json.dumps(r, ensure_ascii=False) + "\n")
    named = len([r for r in rows if r["route"]])
    print("  ledger: +%d line(s) (%d with a named route) -> %s" % (len(rows), named, led))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
