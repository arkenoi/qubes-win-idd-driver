#!/usr/bin/env python3
"""msg-audit.py - every error/warning message we emit, measured in code, judged by Jev, ranked for rewrite.

WHY THIS IS A SCRIPT. Owner, 2026-10-09: "your error messages are terrible in style: way too many
words", and again 2026-10-10 on a dom0 toast: "i do not like this text, too much prose. fix all error
message so they are short and informative." There are ~583 error/warning emitters across the agent,
notifhost, the core-agent fork, the watchdog and the guest scripts. Enumerating them, measuring them
and ranking them are deterministic, so they are here and not in an agent - the standing prohibition
(.claude/skills/jev-classifier) forbids a model any step a script can produce, after two measured
failures that cost 1.5M and 1.8M tokens. Only the REWRITE needs a model.

THE RULE BEING APPLIED, in his words and with his accepted exemplar:
    "one short clause for the condition, one for the consequence, then the facts. No causal claims the
     code did not establish, no reassurance, no repo paths, no explanation of the test."
    accepted:  QGAVCHANFAIL vchan to dom0 port 513 never opened: xenstore node unreadable
               (0x5 = absent or denied); request dropped. 4/4 records: | <record> | <record>
               -> 125 characters of diagnosis, then the facts.

WHAT IS MEASURED HERE (no judgment): the prose length of each message up to its first fact, the
sentence and clause count, and the presence of the four things he named - reassurance, unestablished
causal claims, repo paths, and explanation. Those are string tests, so they are code.
WHAT JEV DECIDES: whether a message is too wordy for its level, what should come out, and whether the
rewrite still says what the reader needs. A length over the threshold is a CANDIDATE, never a verdict:
a long line that is all facts is fine, and a short line can still be prose.

TRIAGE BY STAKES, per the classifier skill: dom0-FACING texts (what the owner actually reads on his
screen) get a per-message pass; ERROR/WARNING log lines get a pass only when the measurement flags
them; everything else is counted and left alone. That is the difference between ~580 judgments and a
few dozen.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()

# ---- the corpus, by stakes ----------------------------------------------------------------------
# dom0-facing first: these are the texts a human reads on his screen, and they are the ones he
# objected to twice. The rest are log lines, read when something is being diagnosed.
DOM0_FACING = [
    "agent/include/notifytexts.h",      # the agent's own dom0 notifications
    "agent/include/deathevent.h",       # the Event Log records the death reporter turns into toasts
    "guest/qwt-report-death.ps1",       # the death reporter: header, consequence, cause, technical
    "guest/qwt-notify-error.ps1",       # the route
]
LOG_LINES = [
    "agent/gui-agent", "agent/watchdog", "tools/notifhost", "tools/wgcbroker",
    "core-agent/src", "guest",
]

# ---- extraction ---------------------------------------------------------------------------------
# A C call's text can be several adjacent literals across lines; the compiler concatenates them and so
# do we. Anything else would measure a fragment and rank it as short.
C_CALL = re.compile(r"\b(LogError|LogWarning|LogInfo|LogDebug|BLog|LogOnce|win_perror2?|PlatLog)\s*\(")
PS_CALL = re.compile(r"(Write-QwtDeathLog\s+'(?:ERROR|WARN)'|Write-Error|Write-Warning|Write-QwtLog\s+'(?:ERROR|WARN)')")
LITERAL = re.compile(r"L?\"((?:[^\"\\]|\\.)*)\"")
PS_LITERAL = re.compile(r"(?:\"((?:[^\"\\`]|\\.|`.)*)\"|'((?:[^']|'')*)')")

LEVEL_OF = {"LogError": "E", "win_perror": "E", "win_perror2": "E", "LogWarning": "W",
            "LogOnce": "W", "BLog": "B", "PlatLog": "P", "LogInfo": "I", "LogDebug": "D"}


def c_messages(path):
    """(line, func, text) for every logging call in a C/C++ file, literals concatenated."""
    src = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for m in C_CALL.finditer(src):
        func = m.group(1)
        # take the call's argument text up to a balanced close paren, bounded so a malformed file
        # cannot run to EOF
        i, depth, end = m.end(), 1, None
        while i < len(src) and i < m.end() + 4000:
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        if end is None:
            continue
        args = src[m.end():end]
        parts = [lit.group(1) for lit in LITERAL.finditer(args)]
        if not parts:
            continue
        text = "".join(parts)
        out.append((src.count("\n", 0, m.start()) + 1, func, text))
    return out


def ps_messages(path):
    """(line, kind, text) for PowerShell error/warning emissions and notice texts."""
    out = []
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        m = PS_CALL.search(line)
        if not m:
            continue
        lit = PS_LITERAL.search(line[m.end():])
        if not lit:
            continue
        out.append((n, m.group(1).split()[0], lit.group(1) or lit.group(2) or ""))
    return out


def ps_notice_texts(path):
    """The death reporter's own notice strings: header/next/cause builders return them."""
    out = []
    src = open(path, encoding="utf-8", errors="replace").read()
    for n, line in enumerate(src.split("\n"), 1):
        if re.search(r"^\s*(return|\$\w+\s*=)\s*[\"'].{40,}", line) and (
                "Cause:" in line or "Evidence:" in line or " it " in line or "Windows" in line):
            lit = PS_LITERAL.search(line)
            if lit:
                out.append((n, "notice", lit.group(1) or lit.group(2) or ""))
    return out


def h_texts(path):
    """notifytexts.h / deathevent.h: the literals themselves are the message."""
    out = []
    src = open(path, encoding="utf-8", errors="replace").read()
    for n, line in enumerate(src.split("\n"), 1):
        if line.lstrip().startswith("//"):
            continue
        parts = [m.group(1) for m in LITERAL.finditer(line)]
        joined = "".join(parts)
        if len(joined) >= 40:
            out.append((n, "text", joined))
    return out


def collect():
    items = []
    for rel in DOM0_FACING:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            continue
        if rel.endswith(".h"):
            got = h_texts(p)
        elif rel.endswith(".ps1"):
            got = ps_messages(p) + ps_notice_texts(p)
        else:
            got = c_messages(p)
        for line, kind, text in got:
            items.append({"file": rel, "line": line, "kind": kind, "text": text, "stakes": "dom0"})
    seen = {(i["file"], i["line"]) for i in items}
    for base in LOG_LINES:
        d = os.path.join(ROOT, base)
        if not os.path.isdir(d):
            continue
        for dirpath, _, names in os.walk(d):
            for nm in sorted(names):
                if not nm.endswith((".c", ".cpp", ".h", ".ps1")):
                    continue
                p = os.path.join(dirpath, nm)
                rel = os.path.relpath(p, ROOT)
                got = ps_messages(p) if nm.endswith(".ps1") else c_messages(p)
                for line, kind, text in got:
                    if (rel, line) in seen:
                        continue
                    items.append({"file": rel, "line": line, "kind": kind, "text": text, "stakes": "log"})
    return items


# ---- measurement, all deterministic -------------------------------------------------------------
# The four things he named, as string tests. Each is a CANDIDATE signal, never a verdict: Jev decides.
REASSURANCE = re.compile(r"\b(nothing (on this guest )?is broken|not a (fault|failure) of its own|"
                         r"this is normal|no cause for|do not worry|is expected, not|harmless|benign)\b", re.I)
CAUSAL_HEDGE = re.compile(r"\b(probably|likely|almost certainly|presumably|suggests that|may indicate|"
                          r"appears to be|seems to)\b", re.I)
REPO_PATH = re.compile(r"\b(guest/|tools/|agent/|mgmt/|findings/|docs/|\.ps1\b|\.c:\d|\.cpp:\d)")
EXPLANATION = re.compile(r"\b(because|which means|so that|the reason|this is why|in other words|"
                         r"that is,|i\.e\.|note that|keep in mind)\b", re.I)
FACT_START = re.compile(r"(0x[0-9a-fA-F]|%[slduxSILH]|pid |PID |\d+ ms|: \||; [a-z_]+=)")


def measure(it):
    t = it["text"]
    it["len"] = len(t)
    m = FACT_START.search(t)
    it["prose_len"] = m.start() if m else len(t)      # characters before the first fact
    it["sentences"] = len([s for s in re.split(r"[.;]\s", t) if s.strip()])
    it["reassurance"] = bool(REASSURANCE.search(t))
    it["hedge"] = bool(CAUSAL_HEDGE.search(t))
    it["repo_path"] = bool(REPO_PATH.search(t))
    it["explanation"] = bool(EXPLANATION.search(t))
    it["flags"] = sum((it["reassurance"], it["hedge"], it["repo_path"], it["explanation"]))
    # The accepted exemplar is 125 characters of diagnosis. Over 130 before the first fact, or any
    # named-content flag, makes it a candidate for judgment - not a verdict.
    it["candidate"] = it["prose_len"] > 130 or it["flags"] > 0 or it["sentences"] > 2
    return it


# ---- the judgment, which is Jev's ---------------------------------------------------------------
# One call per batch. The RULE goes in the state ONCE, not per question (classifier skill: shared
# guidance travels once). Every question offers an "insufficient-evidence" option so a thin item can
# say so instead of being forced into a class.
RULE_STATE = """THE RULE, in the owner's words (2026-10-09, repeated 2026-10-10 about a dom0 toast:
"i do not like this text, too much prose. fix all error message so they are short and informative"):
    "one short clause for the condition, one for the consequence, then the facts. No causal claims the
     code did not establish, no reassurance, no repo paths, no explanation of the test."
HIS ACCEPTED EXEMPLAR, 125 characters of diagnosis and then the facts:
    QGAVCHANFAIL vchan to dom0 port 513 never opened: xenstore node unreadable (0x5 = absent or
    denied); request dropped. 4/4 records: | <record> | <record>
WHAT HE HAD REJECTED, 430 characters, with a causal hint, a reassurance and a repo path in it.
WHERE THE REMOVED MATERIAL GOES: the cause -> the register entry the line's tag resolves to; the
reassurance -> cut entirely (Jev scored assurance_warranted 0.29); the explanation of what a test
proves -> the source comment beside the string. It is never simply deleted.

WHAT IS ALREADY MEASURED FOR EACH ITEM BELOW, in code, so you do not have to estimate it: `prose` is
the characters before the first fact (a hex code, a format specifier, a pid, a count, a key=value);
`len` is the whole string; `sentences` counts clause separators; and the four flags are string tests
for the four things he named. A long string that is mostly FACTS is fine - judge the prose, not the
length. A `%s`/`%lu` is a fact the caller fills in, not prose.
LEVELS: E = error, W = warning, B/P = a bridge or platform line, I = info, D = debug. A dom0-FACING
item is read by a human on his screen; a log line is read when something is being diagnosed, so a log
line may carry more facts but no more prose.
"""

QUESTION = {"type": "choice",
            "instructions": {"judge": "Judge THIS message against the rule in `state`. Does it need "
                                      "changing, and if so what kind of change? Judge the prose, not "
                                      "the length: facts, format specifiers and record dumps are not "
                                      "prose. Do not ask for a rewrite you cannot justify from the rule."},
            "criteria": {
                "ok": "it already states the condition and the consequence and then the facts; leave it",
                "trim": "the right content, too many words - it needs cutting, no restructuring",
                "move-to-source": "it carries cause, reassurance, explanation or a repo path that belongs in the source comment or the register, not in every occurrence",
                "rewrite": "it does not state the condition and the consequence clearly at all and needs rewriting",
                "insufficient-evidence": "the item as shown cannot be judged (a fragment, or its meaning depends on code not shown)"}}


def judge(items, batch_size=10, out_dir="scratchpad/msg-audit"):
    """Batch the candidates to Jev. One call per batch; exit 2 aborts the run."""
    os.makedirs(os.path.join(ROOT, out_dir), exist_ok=True)
    cands = [i for i in items if i["candidate"]]
    # dom0-facing first: they are what he reads on screen
    cands.sort(key=lambda i: (0 if i["stakes"] == "dom0" else 1, -i["prose_len"]))
    verdicts, cost = {}, 0
    for b in range(0, len(cands), batch_size):
        chunk = cands[b:b + batch_size]
        state = [RULE_STATE, "THE ITEMS IN THIS BATCH:"]
        rubric = {"questions": {}}
        for n, it in enumerate(chunk, 1):
            key = "m%d" % n
            state.append("\n%s  [%s] %s:%d  level=%s  len=%d prose=%d sentences=%d%s\n    %s"
                         % (key, it["stakes"], it["file"], it["line"], LEVEL_OF.get(it["kind"], it["kind"]),
                            it["len"], it["prose_len"], it["sentences"],
                            "".join(" FLAG:" + f for f in ("reassurance", "hedge", "repo_path", "explanation") if it[f]),
                            it["text"]))
            q = json.loads(json.dumps(QUESTION))
            q["instructions"]["judge"] = "Item %s. " % key + q["instructions"]["judge"]
            rubric["questions"][key] = q
        sp = os.path.join(ROOT, out_dir, "state-%03d.txt" % b)
        rp = os.path.join(ROOT, out_dir, "rubric-%03d.json" % b)
        apath = os.path.join(ROOT, out_dir, "answers-%03d.json" % b)
        open(sp, "w", encoding="utf-8").write("\n".join(state))
        open(rp, "w", encoding="utf-8").write(json.dumps(rubric))
        r = subprocess.run([sys.executable, "tools/jev.py", rp, sp, "--out", apath],
                           cwd=ROOT, capture_output=True, text=True)
        if r.returncode == 2:
            print("FAIL jev.py exit 2 on batch %d - the instrument did not run; aborting" % b, file=sys.stderr)
            print(r.stderr[-600:], file=sys.stderr)
            return None, cost
        if r.returncode != 0:
            print("FAIL jev.py rc=%d on batch %d" % (r.returncode, b), file=sys.stderr)
            return None, cost
        ans = json.load(open(apath, encoding="utf-8"))
        cost += (ans.get("usage") or {}).get("input_tokens", 0)
        for n, it in enumerate(chunk, 1):
            a = (ans.get("answers") or {}).get("m%d" % n) or {}
            it["verdict"] = a.get("choice", "MISSING")
            it["confidence"] = a.get("confidence")
            it["dist"] = a.get("probabilities")
            verdicts[(it["file"], it["line"])] = it["verdict"]
        print("  batch %-4d %d item(s): %s" % (b, len(chunk),
              " ".join("%s=%s" % (k.split("/")[-1][:14] + ":" + str(v), verdicts[k]) for k, v in
                       [((i["file"], i["line"]), i["line"]) for i in chunk][:0]) or
              ", ".join("%s" % i["verdict"] for i in chunk)))
    return cands, cost


# ---- the re-ask, in code, with the fact that decides it -----------------------------------------
# The classifier skill: "Anything under the confidence floor gets one more call with wider context.
# Jev named this the thing most easily lost when a human assessor is replaced
# (worst_thing_lost = gap-closing-re-ask 0.64), so it is implemented, not described."
# For THIS corpus the closing fact is computable: `move-to-source` means the explanation belongs in the
# source comment - so whether a comment ALREADY carries it decides between "delete the words from the
# line" and "write them into the comment first". That is a string test, so it is here.
def context_of(it, before=8):
    """The comment block and code immediately above the call, which is where the prose would move."""
    p = os.path.join(ROOT, it["file"])
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return "", False
    lo = max(0, it["line"] - 1 - before)
    ctx = lines[lo:it["line"] - 1]
    commented = [l for l in ctx if l.lstrip().startswith(("//", "#", "*"))]
    return "\n".join(ctx), len(commented) >= 2


def reask(items, floor=0.55, batch_size=6, out_dir="scratchpad/msg-audit"):
    weak = [i for i in items if (i.get("confidence") or 1.0) < floor]
    if not weak:
        return 0, 0
    print("RE-ASK %d verdict(s) under %.2f, with the source context that decides move-to-source" % (len(weak), floor))
    moved, cost = 0, 0
    for b in range(0, len(weak), batch_size):
        chunk = weak[b:b + batch_size]
        state = [RULE_STATE,
                 "THIS IS A RE-ASK. Each item below was judged once on the message alone and came back "
                 "under the confidence floor, so the SOURCE AROUND THE CALL is included now. That context "
                 "is what decides `move-to-source`: if a comment there already carries the cause or the "
                 "explanation, the words in the message are redundant and come out; if nothing there "
                 "carries it, moving them means WRITING the comment, which is still the right place but is "
                 "more work than a trim. `comment_above` says whether two or more comment lines precede "
                 "the call.", "THE ITEMS:"]
        rubric = {"questions": {}}
        for n, it in enumerate(chunk, 1):
            key = "m%d" % n
            ctx, commented = context_of(it)
            state.append("\n%s  [%s] %s:%d level=%s len=%d prose=%d comment_above=%s\n  MESSAGE: %s\n  SOURCE ABOVE THE CALL:\n%s"
                         % (key, it["stakes"], it["file"], it["line"], LEVEL_OF.get(it["kind"], it["kind"]),
                            it["len"], it["prose_len"], commented, it["text"],
                            "\n".join("    " + l for l in ctx.split("\n")[-8:])))
            q = json.loads(json.dumps(QUESTION))
            q["instructions"]["judge"] = ("Item %s, re-asked with its source context. " % key) + q["instructions"]["judge"]
            rubric["questions"][key] = q
        sp = os.path.join(ROOT, out_dir, "reask-state-%03d.txt" % b)
        rp = os.path.join(ROOT, out_dir, "reask-rubric-%03d.json" % b)
        apath = os.path.join(ROOT, out_dir, "reask-answers-%03d.json" % b)
        open(sp, "w", encoding="utf-8").write("\n".join(state))
        open(rp, "w", encoding="utf-8").write(json.dumps(rubric))
        r = subprocess.run([sys.executable, "tools/jev.py", rp, sp, "--out", apath],
                           cwd=ROOT, capture_output=True, text=True)
        if r.returncode == 2:
            print("FAIL jev.py exit 2 on re-ask batch %d - aborting" % b, file=sys.stderr)
            return None, cost
        ans = json.load(open(apath, encoding="utf-8"))
        cost += (ans.get("usage") or {}).get("input_tokens", 0)
        for n, it in enumerate(chunk, 1):
            a = (ans.get("answers") or {}).get("m%d" % n) or {}
            new_v, new_c = a.get("choice", it["verdict"]), a.get("confidence")
            if new_v != it["verdict"] or (new_c or 0) != (it["confidence"] or 0):
                moved += 1
            it["verdict_first"], it["confidence_first"] = it["verdict"], it["confidence"]
            it["verdict"], it["confidence"], it["dist"] = new_v, new_c, a.get("probabilities")
            it["reasked"] = True
    return moved, cost


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("measure")
    p.add_argument("--out", default="scratchpad/msg-audit.json")
    p.add_argument("--top", type=int, default=25)
    pj = sub.add_parser("judge")
    pj.add_argument("--inp", default="scratchpad/msg-audit.json")
    pj.add_argument("--out", default="scratchpad/msg-audit-judged.json")
    pj.add_argument("--batch", type=int, default=10)
    a = ap.parse_args()

    if a.cmd == "judge":
        items = [measure(i) for i in json.load(open(os.path.join(ROOT, a.inp), encoding="utf-8"))]
        cands, cost = judge(items, a.batch)
        if cands is None:
            return 4
        with open(os.path.join(ROOT, a.out), "w", encoding="utf-8") as f:
            json.dump(cands, f, indent=1)
        moved, rcost = reask(cands)
        if moved is None:
            return 4
        cost += rcost
        by = {}
        for i in cands:
            by[i["verdict"]] = by.get(i["verdict"], 0) + 1
        still_weak = [i for i in cands if (i.get("confidence") or 1.0) < 0.55]
        print("RE-ASK moved or re-scored %d verdict(s); %d still under the floor and are reported as "
              "findings, not rounded up" % (moved, len(still_weak)))
        print("JUDGED %d candidate(s): %s" % (len(cands), ", ".join("%s=%d" % kv for kv in sorted(by.items()))))
        print("COST input_tokens=%d across %d batch(es)" % (cost, (len(cands) + a.batch - 1) // a.batch))
        print("wrote %s" % a.out)
        return 0

    items = [measure(i) for i in collect()]
    if not items:
        print("FAIL no messages extracted - the extractor matched nothing, which is a defect of this "
              "script, not an empty corpus", file=sys.stderr)
        return 3
    os.makedirs(os.path.dirname(os.path.join(ROOT, a.out)), exist_ok=True)
    with open(os.path.join(ROOT, a.out), "w", encoding="utf-8") as f:
        json.dump(items, f, indent=1)

    dom0 = [i for i in items if i["stakes"] == "dom0"]
    log = [i for i in items if i["stakes"] == "log"]
    cand = [i for i in items if i["candidate"]]
    print("MESSAGES %d total: %d dom0-facing, %d log lines" % (len(items), len(dom0), len(log)))
    print("CANDIDATES %d (prose>130 chars before the first fact, or a named-content flag, or >2 sentences)"
          % len(cand))
    for name, pred in (("reassurance", "reassurance"), ("causal hedge", "hedge"),
                       ("repo path", "repo_path"), ("explanation", "explanation")):
        print("  %-13s %d" % (name, sum(1 for i in items if i[pred])))
    print("LONGEST PROSE, top %d:" % a.top)
    for i in sorted(items, key=lambda x: -x["prose_len"])[:a.top]:
        print("  %4d chars  %-40s :%-5d %s" % (i["prose_len"], i["file"], i["line"], i["text"][:110]))
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
