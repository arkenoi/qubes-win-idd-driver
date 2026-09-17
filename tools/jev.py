#!/usr/bin/env python3
"""jev.py - one TypeSafe (Jev, System One) judgment from the shell, for agents and harness scripts.

    tools/jev.py RUBRIC.json [STATE_FILE | -] [--json-state] [--out answers.json]

RUBRIC.json is the TypeSafe `questions` map (or {"questions": {...}}): each entry is a Noul (yes/no
-> probability), a Choice (option + distribution + confidence) or a Score (levels). STATE is the
thing to judge - text by default, parsed as JSON with --json-state; "-" reads stdin. Prints one line
per question and exits 0; exit 2 on any instrument error (no key, HTTP error, malformed rubric) so a
caller can never mistake "the judge did not run" for an answer.

WHAT TO SEND HERE (owner, 2026-09-18: "delegate to jev everything when feasible"): the SEMANTIC
judgments - "which known failure class does this console excerpt show", "did this client treat the
error as final or transient", "is this screen a desktop, a recovery prompt or an installer". Keep
exact matching, counting and timestamp joins in code; Jev's own guidance says the same. A judgment
that comes back with low confidence is a finding, not noise: under "no uncertainty anywhere" it
names what still has to be measured.

Key: ~/.config/qwt-secrets/typesafe.key or TYPESAFE_API_KEY. Never printed, never logged.
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

def ask(key, state, questions, retries=4):
    body = json.dumps({"state": state, "model": MODEL, "questions": questions}).encode()
    req = urllib.request.Request(API, data=body, method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            last = "HTTP %d %s" % (e.code, e.read()[:300].decode(errors="replace"))
            if e.code not in (429, 529): break
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
        time.sleep(2 ** i)
    raise RuntimeError("TypeSafe call failed: " + str(last))

def fmt(qid, a):
    t = a.get("type")
    if t == "noul":
        return "%s noul=%.2f" % (qid, a["noul"])
    if t == "choice":
        dist = " ".join("%s=%.2f" % (k, v) for k, v in sorted(a["probabilities"].items(), key=lambda kv: -kv[1]))
        return "%s choice=%s conf=%.2f [%s]" % (qid, a["choice"], a["confidence"], dist)
    if t == "score":
        return "%s score=%.2f conf=%.2f legend=%s" % (qid, a["score"], a["confidence"], json.dumps(a.get("legend")))
    return "%s %s" % (qid, json.dumps(a))

def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__); return 2
    rubric_path = argv[1]
    state_src = argv[2] if len(argv) > 2 and not argv[2].startswith("--") else "-"
    json_state = "--json-state" in argv
    out = None
    if "--out" in argv:
        out = argv[argv.index("--out") + 1]
    try:
        rub = json.load(open(rubric_path, encoding="utf-8"))
        questions = rub.get("questions", rub)
        raw = sys.stdin.read() if state_src == "-" else open(state_src, encoding="utf-8", errors="replace").read()
        state = json.loads(raw) if json_state else raw
        if not questions or not isinstance(questions, dict):
            print("INSTRUMENT: rubric has no questions map"); return 2
        key = load_key()
        if not key:
            print("INSTRUMENT: no API key (TYPESAFE_API_KEY or %s)" % KEYFILE); return 2
        r = ask(key, state, questions)
    except Exception as e:
        print("INSTRUMENT: %s" % e); return 2
    answers = r.get("answers", {})
    for qid in questions:
        if qid in answers:
            print(fmt(qid, answers[qid]))
        else:
            print("INSTRUMENT: no answer for %s" % qid); return 2
    if out:
        json.dump({"model": r.get("model"), "answers": answers, "usage": r.get("usage")}, open(out, "w"), indent=1)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
