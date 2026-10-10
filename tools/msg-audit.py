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

USAGE
    tools/msg-audit.py measure [--out scratchpad/msg-audit.json] [--top N]
        extracts and measures the corpus, prints the counts and the longest prose, writes every item.
    tools/msg-audit.py judge [--inp scratchpad/msg-audit.json] [--out scratchpad/msg-audit-judged.json]
        sends the candidates to Jev, re-asks every verdict under FLOOR with its source context, and
        writes the FINAL verdicts. The file is written once, after the re-ask, by write_judged(), which
        refuses any item the re-ask never marked - so a dump placed before reask() fails loudly instead
        of writing first-pass verdicts (2026-10-10: it did, and 19 of 84 verdicts in the file disagreed
        with the printed summary). The printed summary is computed from the file read back, so the two
        cannot disagree. The corpus it consumed is frozen beside the output as <out>.before.json: that is
        verify's baseline, and a later `measure` to the default --out cannot replace it.
    tools/msg-audit.py verify [--inp ...] [--judged ...] [--reask-dir scratchpad/msg-audit]
                              [--window 10] [--files F ...]
        checks the WORKING TREE against the judged file, deterministically and offline (no Jev call);
        --inp is the before corpus, defaulting to <judged>.before.json, else scratchpad/msg-audit.json:
        (1) re-extracts and re-measures the corpus and prints the before/after counts - total, candidates,
            each named-content flag - so the improvement is a number;
        (2) for every `move-to-source` item, the distinctive words that LEFT the message (content words
            present before and absent after, minus stopwords and format specifiers) must appear in a
            comment within --window lines of the call: the knowledge moved, it did not vanish;
        (3) FAILS a changed leading tag, a changed format-specifier count or sequence, and a message that
            no longer exists at any line of its file; a `trim`/`rewrite`/`move-to-source` item that is
            unchanged is an unexecuted verdict and FAILS too;
        (4) FAILS a STALE judged file: a judged text that is not in the before corpus (was `measure`
            re-run after the edits?), or a verdict that disagrees with the saved re-ask answer for the
            same item, or a confidence under FLOOR with no re-ask on disk. verify never re-judges - a
            fresh Jev run is a new sample and a cost - so it says when its input is stale rather than
            grading the tree against verdicts that are not the final ones.
        An unreadable file is a failure, never a skip. Exit 0 = every check passed, 1 = a check failed,
        3 = an input is missing. --files limits the per-item rows to those files: a partial look, not
        the gate.
"""
import argparse
import json
import os
import re
import shutil
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


def extract_file(rel):
    """(line, kind, text) for ONE file, by the extractor collect() uses for it: the dom0-facing headers
    are literal tables, the dom0-facing .ps1 files add their notice builders, everything else is calls.
    verify() re-extracts a judged item's file through this, so it measures what measure() measured."""
    p = os.path.join(ROOT, rel)
    if rel in DOM0_FACING and rel.endswith(".h"):
        return h_texts(p)
    if rel.endswith(".ps1"):
        return ps_messages(p) + (ps_notice_texts(p) if rel in DOM0_FACING else [])
    return c_messages(p)


def collect():
    items = []
    for rel in DOM0_FACING:
        if not os.path.exists(os.path.join(ROOT, rel)):
            continue
        for line, kind, text in extract_file(rel):
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
                rel = os.path.relpath(os.path.join(dirpath, nm), ROOT)
                for line, kind, text in extract_file(rel):
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
# A path INTO THIS REPO is prose; a path the guest or dom0 actually uses is a fact. The first
# version matched "/qubes-tools/qrexec=1" - the qubesdb node dom0 reads - and drove a verdict on
# a line whose only sin was naming it (Jev, asked with the code fact: fact-keep-it 1.00). The
# lookbehind requires the segment to start a path, not sit inside one.
REPO_PATH = re.compile(r"(?<![\w/-])(guest/|tools/|agent/|mgmt/|findings/|docs/|\.ps1\b|\.c:\d|\.cpp:\d)")
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
    # HIS OWN REWRITES ARE 52 AND 62 CHARACTERS (2026-10-10, after he rejected a 32% cut as "too much
    # prose"). Over 70 before the first fact, more than one sentence, or any named-content flag makes it
    # a candidate for judgment - never a verdict.
    it["candidate"] = it["prose_len"] > 70 or it["flags"] > 0 or it["sentences"] > 1
    return it


# ---- the judgment, which is Jev's ---------------------------------------------------------------
# One call per batch. The RULE goes in the state ONCE, not per question (classifier skill: shared
# guidance travels once). Every question offers an "insufficient-evidence" option so a thin item can
# say so instead of being forced into a class.
RULE_STATE = """THE RULE, and the owner's OWN REWRITES as the yardstick. He read a pass that cut prose by
32% and said: "fuck too much prose ... do you see the point? when I ask you to 'reduce the prose', it is
how it is expected to work." Four examples, his words against ours:

  OURS (129 chars): QGAAUTOLOGON autologon NOT provisioned (DefaultUserName empty): no account to log
                    in as, dom0 is shown nothing until a human acts
  HIS  (62):        Autologon is OFF, seamless mode is inactive until user logs in

  OURS (127):       QGAWINEVTDEAD window event thread exiting while the agent keeps running: tracking
                    falls back to 0.5 Hz until the agent restarts
  HIS  (52):        Window event thread died unexpectedly, using fallback

  OURS (103):       QGAENDSESSION no lifecycle channel to the QubesGuiWatchdog service: the end is
                    allowed without a notice
  HIS:              "it is not english language at all"

  OURS (86):        MODE non-seamless - every toast takes the window path
  HIS:              "why it is even there"

WHAT THAT TEACHES, and it is the standard now:
 1. ABOUT 50-70 CHARACTERS of prose, not 130. His two rewrites are 62 and 52.
 2. PLAIN ENGLISH a human reads once: "died unexpectedly", "using fallback", "is OFF". Not
    "NOT provisioned", not "no lifecycle channel to the QubesGuiWatchdog service", not "the end is
    allowed without a notice". If a sentence only parses for someone who wrote the code, it fails.
 3. THE CONSEQUENCE IN USER TERMS, not in ours: "seamless mode is inactive until user logs in" - not
    "dom0 is shown nothing", not "tracking falls back to 0.5 Hz", not "per-window surfaces are
    withheld". A rate, an internal field name or a subsystem name is not a consequence.
 4. INTERNALS COME OUT unless the internal IS the fact being reported: DefaultUserName, 0.5 Hz,
    QGADESLICEDOWN-owns-this-condition, "the service sees 0x40010004" - out. A pid, a handle, an exit
    code, a count, a measured duration - in, after the prose.
 5. SOME LINES SHOULD NOT EXIST. His fourth example is an Info-level state dump; the answer is to
    DELETE it, not to shorten it. Ask of every line: would a human ever act on this, or look for it
    after a failure? If not, delete - the verdict is `delete`, not `trim`.
Facts, format specifiers and record dumps are NOT prose and are not counted: judge the words.
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
                "delete": "no human would ever act on this or look for it after a failure - the line should not exist (his fourth example)",
                "plain-english": "the words are jargon rather than English, or the consequence is stated in our terms instead of the user's - rewrite it the way he rewrote his two examples",
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
            it["reask"] = "pending"     # only reask() clears this, and write_judged() refuses it
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


FLOOR = 0.55    # a verdict under it is re-asked with source context; still under it afterwards = a finding


def reask(items, floor=FLOOR, batch_size=6, out_dir="scratchpad/msg-audit"):
    """Returns (items, cost) with every item marked `reask` = kept|reasked - the list write_judged()
    takes - or (None, cost) when a batch did not run, in which case nothing is written."""
    for i in items:
        i["reask"] = "kept"             # at or above the floor: the first-pass verdict stands
    weak = [i for i in items if (i.get("confidence") or 1.0) < floor]
    if not weak:
        return items, 0
    print("RE-ASK %d verdict(s) under %.2f, with the source context that decides move-to-source" % (len(weak), floor))
    cost = 0
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
            it["verdict_first"], it["confidence_first"] = it["verdict"], it["confidence"]
            it["verdict"], it["confidence"], it["dist"] = new_v, new_c, a.get("probabilities")
            it["reasked"] = True
            it["reask"] = "reasked"
    return items, cost


def write_judged(cands, path):
    """The ONE writer of the judged file. It takes the list reask() returns and refuses any item the
    re-ask never marked (`reask` is "pending" from the moment judge() assigns a verdict until reask()
    marks it kept|reasked), so a dump placed before the re-ask fails here instead of writing first-pass
    verdicts. It returns the file READ BACK, and summarize_judged() prints from that: the file and the
    summary are one object by construction, not by call order.
    2026-10-10: the dump preceded reask(); 19 of 84 verdicts in the file disagreed with the printed
    summary, and an agent's work list was built from the stale ones."""
    pending = [i for i in cands if i.get("reask") not in ("kept", "reasked")]
    if pending:
        raise RuntimeError("FAIL judged file NOT written: %d item(s) never reached the re-ask (e.g. %s:%d) - "
                           "a file of first-pass verdicts is the defect this writer refuses"
                           % (len(pending), pending[0]["file"], pending[0]["line"]))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cands, f, indent=1)
    return json.load(open(path, encoding="utf-8"))


def summarize_judged(written, cost, batch_size):
    """The judge summary, from the judged file as written - every number here is derivable from it."""
    by = {}
    for i in written:
        by[i["verdict"]] = by.get(i["verdict"], 0) + 1
    reasked = [i for i in written if i.get("reasked")]
    moved = sum(1 for i in reasked if i["verdict"] != i.get("verdict_first")
                or (i.get("confidence") or 0) != (i.get("confidence_first") or 0))
    still_weak = [i for i in written if (i.get("confidence") or 1.0) < FLOOR]
    print("RE-ASK %d of %d re-asked verdict(s) moved or re-scored; %d still under the floor and are reported "
          "as findings, not rounded up" % (moved, len(reasked), len(still_weak)))
    print("JUDGED %d candidate(s): %s" % (len(written), ", ".join("%s=%d" % kv for kv in sorted(by.items()))))
    print("COST input_tokens=%d across %d batch(es)" % (cost, (len(written) + batch_size - 1) // batch_size))


# ---- verify: the tree against the judged file, in code ------------------------------------------
# The classifier skill assigns diffing and matching to code. Whether a rewrite kept its tag, its format
# specifiers and its facts, and whether the words that left a message landed in a comment, are string
# tests - so they are here, and the stage never calls Jev. The task it checks: `move-to-source` means
# the cause/reassurance/explanation words come OUT of the message and GO INTO the source comment
# beside the call; the knowledge is moved, never deleted.
SPEC = re.compile(r"%(?:%|[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|I64|I32|I|z|j|t|w)?[diouxXeEfgGaAcspnS])")
WORD = re.compile(r"[a-z][a-z0-9_'-]*")
# STRUCTURAL NOUNS are listed separately from the grammar words, and the explanation lives OUT HERE.
# Measured 2026-10-10: the first version of this edit put its own comment INSIDE the triple-quoted
# string, so every word of the comment became a stopword - including "forced", which is why the check
# then reported that word as having left a message that still contained it. The words that carry no
# fact in a log line belong here; anything domain-bearing does not.
STOPWORDS = frozenset("""a an the and or but if then else of to in on at by for with from into onto as is are
was were be been being has have had do does did not no nor it its this that these those there here so than
too very can cannot could will would shall should may might must we us our ours you your he she they them
their his her who whom which what when where why how all any each few more most other some such only own
same up down out off over again further once now still yet ever never also just both either neither about
after before between during through while until above below per via am""".split())
STRUCTURAL = frozenset("path way thing point place part kind".split())
STOPWORDS = STOPWORDS | STRUCTURAL
FAIL_KINDS = ("stale", "disappeared", "tag", "specifiers", "unchanged", "no-word-left", "not-moved", "unreadable")


def specifiers(text):
    """The printf-style conversions of a format string, in order; %% is an escape, not a conversion."""
    return [m.group(0) for m in SPEC.finditer(text) if m.group(0) != "%%"]


def leading_tag(text):
    parts = text.split()
    return parts[0].rstrip(":") if parts else ""


def stem(w):
    """launched/launching/launches -> launch; teardown stays. Enough to match a word to its comment."""
    if w.endswith("'s"):
        w = w[:-2]
    for suf in ("ing", "ed", "es", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 3 and not (suf == "s" and w.endswith("ss")):
            return w[:-len(suf)]
    return w


def content_words(text):
    """{stem: word} for the lower-cased words of 3+ characters, minus stopwords and format specifiers.
    Keyed by stem so launched matches launching; the word is kept for printing."""
    out = {}
    for w in WORD.findall(SPEC.sub(" ", text).lower()):
        w = w.strip("'-")
        if len(w) >= 3 and w not in STOPWORDS:
            out.setdefault(stem(w), w)
    return out


def comment_text(lines, lo, hi, path):
    """The comment text in lines[lo:hi]: `//`, `/* */`, `#` and `<# #>` by file type, quote-aware so a
    marker inside a string literal is not a comment. Block comments carry across lines."""
    ps = path.endswith(".ps1")
    out, in_block = [], False
    for raw in lines[lo:hi]:
        i, n, q = 0, len(raw), None
        while i < n:
            c = raw[i]
            if in_block:
                end = raw.find("#>" if ps else "*/", i)
                if end < 0:
                    out.append(raw[i:])
                    break
                out.append(raw[i:end])
                in_block, i = False, end + 2
                continue
            if q:
                if c == ("`" if ps else "\\"):
                    i += 2
                    continue
                if c == q:
                    q = None
                i += 1
                continue
            if c in "\"'":
                q, i = c, i + 1
                continue
            if ps and raw.startswith("<#", i):
                in_block, i = True, i + 2
                continue
            if ps and c == "#":
                out.append(raw[i + 1:])
                break
            if not ps and raw.startswith("//", i):
                out.append(raw[i + 2:])
                break
            if not ps and raw.startswith("/*", i):
                in_block, i = True, i + 2
                continue
            i += 1
    return "\n".join(out)


def locate(judged, current):
    """Assign each judged item of one file to a message in the file's current extraction, so a line that
    moved is found and a message that vanished is told from one whose tag changed. Three passes, each
    claiming its match: unchanged text; same kind and leading tag (nearest line); same kind, same
    specifier sequence and >= 30% shared content words (the tag changed). Returns {id(item): (msg|None, how)}."""
    claimed, result = set(), {}

    def take(it, cands, how):
        # CONTENT FIRST, LINE ONLY TO BREAK A TIE. Nearest-line alone mis-assigns same-tag siblings:
        # measured 2026-10-10 on main.c, which carries FIVE QGAAUTOLOGON messages - after a rewrite
        # shortened one, the nearest-line pass claimed a sibling and the gate reported
        # "format-specifier count changed: 0 -> 2" about a message whose specifier count never changed.
        # A false FAIL from a gate is worse than no gate: it sends someone to fix working code.
        want = set(content_words(it["text"]))
        def score(k):
            got = set(content_words(current[k][2]))
            overlap = len(want & got) / max(1, len(want | got))
            return (-round(overlap, 3), abs(current[k][0] - it["line"]))
        k = min(cands, key=score)
        claimed.add(k)
        result[id(it)] = (current[k], how)

    for it in judged:
        c = [k for k, m in enumerate(current) if k not in claimed and m[1] == it["kind"] and m[2] == it["text"]]
        if c:
            take(it, c, "exact")
    for it in judged:
        if id(it) in result or not has_tag(it["text"]):
            continue
        tag = leading_tag(it["text"])
        c = [k for k, m in enumerate(current)
             if k not in claimed and m[1] == it["kind"] and leading_tag(m[2]) == tag]
        if c:
            take(it, c, "tag")
    for it in judged:
        if id(it) in result:
            continue
        spec, words = specifiers(it["text"]), set(content_words(it["text"]))
        c = []
        for k, m in enumerate(current):
            if k in claimed or m[1] != it["kind"] or specifiers(m[2]) != spec:
                continue
            w = set(content_words(m[2]))
            if words and w and len(words & w) / len(words | w) >= 0.3:
                c.append(k)
        if c:
            take(it, c, "fallback" if has_tag(it["text"]) else "similar")
        else:
            result[id(it)] = (None, "none")
    return result


def has_tag(text):
    """A PowerShell string that opens with an interpolation ("$ourLog; ...") has no leading tag to keep;
    it is matched by content and never failed for a 'tag change'."""
    return not leading_tag(text).startswith("$")


def reask_answers_on_disk(reask_dir):
    """(file, line) -> (choice, confidence) from the saved re-ask batches: an answer's key mN maps to its
    item through the header line reask() wrote into the state file. Returns (map, batches_read)."""
    out, nbatches = {}, 0
    d = os.path.join(ROOT, reask_dir)
    if not os.path.isdir(d):
        return out, 0
    hdr = re.compile(r"^(m\d+)\s+\[(?:dom0|log)\]\s+(\S+?):(\d+)\s+level=")
    for nm in sorted(os.listdir(d)):
        mm = re.match(r"reask-answers-(\d+)\.json$", nm)
        if not mm:
            continue
        sp = os.path.join(d, "reask-state-%s.txt" % mm.group(1))
        if not os.path.exists(sp):
            print("FAIL %s has no state file beside it - its answers cannot be mapped to items" % nm, file=sys.stderr)
            continue
        keys = {}
        for line in open(sp, encoding="utf-8"):
            h = hdr.match(line)
            if h:
                keys[h.group(1)] = (h.group(2), int(h.group(3)))
        ans = json.load(open(os.path.join(d, nm), encoding="utf-8")).get("answers") or {}
        for k, a in ans.items():
            if k in keys:
                out[keys[k]] = (a.get("choice"), a.get("confidence"))
        nbatches += 1
    return out, nbatches


def check_item(it, found, how, lines, path, window):
    """The per-item checks. Returns (fail_kinds, notes, after_item|None)."""
    fails, notes = [], []
    if found is None:
        fails.append(("disappeared", "no %s message with tag '%s' at any line of its file"
                      % (it["kind"], leading_tag(it["text"]))))
        return fails, notes, None
    line, kind, text = found
    after = measure({"file": it["file"], "line": line, "kind": kind, "text": text, "stakes": it["stakes"]})
    if how == "fallback":
        fails.append(("tag", "leading tag changed: '%s' -> '%s'" % (leading_tag(it["text"]), leading_tag(text))))
    elif how == "similar":
        notes.append("matched by content ('%s' is an interpolation, not a tag)" % leading_tag(it["text"]))
    sb, sa = specifiers(it["text"]), specifiers(text)
    if len(sb) != len(sa):
        fails.append(("specifiers", "format-specifier count changed: %d -> %d (%s -> %s)"
                      % (len(sb), len(sa), " ".join(sb) or "-", " ".join(sa) or "-")))
    elif sb != sa:
        fails.append(("specifiers", "format specifiers changed: %s -> %s" % (" ".join(sb), " ".join(sa))))
    changed = text != it["text"]
    verdict = it.get("verdict")
    if verdict == "move-to-source":
        if not changed:
            fails.append(("unchanged", "unchanged: nothing left the message (move-to-source not executed)"))
        else:
            before_w, after_w = content_words(it["text"]), content_words(text)
            left = {s: w for s, w in before_w.items() if s not in after_w}
            if not left:
                fails.append(("no-word-left", "changed, but no distinctive word left the message"))
            else:
                lo, hi = max(0, line - 1 - window), min(len(lines), line + window)
                cw = content_words(comment_text(lines, lo, hi, path))
                landed = sorted(w for s, w in left.items() if s in cw)
                lost = sorted(w for s, w in left.items() if s not in cw)
                if not landed:
                    fails.append(("not-moved", "left the message and landed in no comment within %d lines: %s"
                                  % (window, " ".join(lost))))
                else:
                    notes.append("moved: " + " ".join(landed))
                    if lost:
                        notes.append("cut: " + " ".join(lost))
    elif verdict in ("trim", "rewrite") and not changed:
        fails.append(("unchanged", "unchanged (%s not executed)" % verdict))
    if how == "tag" and line != it["line"]:
        notes.append("line %d -> %d" % (it["line"], line))
    return fails, notes, after


def judged_before_path(judged_path):
    """The before corpus frozen beside the judged file: <judged>.before.json. judge writes it from the exact
    --inp it consumed, so a later `measure` to the default --out cannot replace verify's baseline.
    (2026-10-10: one did, and verify reported every judged text stale until the pre-edit output was
    passed by hand.)"""
    return os.path.splitext(judged_path)[0] + ".before.json"


def verify(inp, judged_path, reask_dir, window, only_files):
    if inp is None:
        frozen = judged_before_path(judged_path)
        inp = frozen if os.path.exists(os.path.join(ROOT, frozen)) else "scratchpad/msg-audit.json"
    for p in (inp, judged_path):
        if not os.path.exists(os.path.join(ROOT, p)):
            print("FAIL %s missing - verify needs the measure output judge consumed (the before corpus) and "
                  "the judged file" % p, file=sys.stderr)
            return 3
    before = [measure(i) for i in json.load(open(os.path.join(ROOT, inp), encoding="utf-8"))]
    judged = json.load(open(os.path.join(ROOT, judged_path), encoding="utf-8"))
    if only_files:
        judged = [i for i in judged if i["file"] in only_files]
    after = [measure(i) for i in collect()]
    if not after:
        print("FAIL no messages extracted from the working tree - a defect of this script, not an empty corpus",
              file=sys.stderr)
        return 3
    print("MEASURED: %d message(s) re-extracted from the working tree against %d in %s (re-measured with the "
          "same tests); %d judged item(s) from %s%s; comments searched within %d lines of each call"
          % (len(after), len(before), inp, len(judged), judged_path,
             " limited to %d file(s)" % len(only_files) if only_files else "", window))

    # (1) the corpus, before and after, as numbers
    def counts(items):
        return [("messages", len(items)),
                ("  dom0-facing", sum(1 for i in items if i["stakes"] == "dom0")),
                ("  log lines", sum(1 for i in items if i["stakes"] == "log")),
                ("candidates", sum(1 for i in items if i["candidate"])),
                ("  reassurance", sum(1 for i in items if i["reassurance"])),
                ("  causal hedge", sum(1 for i in items if i["hedge"])),
                ("  repo path", sum(1 for i in items if i["repo_path"])),
                ("  explanation", sum(1 for i in items if i["explanation"])),
                ("  prose > 130", sum(1 for i in items if i["prose_len"] > 130)),
                ("  sentences > 2", sum(1 for i in items if i["sentences"] > 2))]
    print("CORPUS %-16s %7s %7s %6s" % ("", "before", "after", "delta"))
    for (name, b), (_, a) in zip(counts(before), counts(after)):
        print("       %-16s %7d %7d %+6d" % (name, b, a, a - b))

    # (4) is the judged file the final word? Stale input is a failure, not a baseline.
    stale = []
    by_key = {(i["file"], i["line"]): i["text"] for i in before}
    for it in judged:
        if by_key.get((it["file"], it["line"])) != it["text"]:
            stale.append("%s:%d judged text is not in the before corpus (was `measure` re-run after the edits? "
                         "pass the pre-edit output with --inp)" % (it["file"], it["line"]))
    answers, nbatches = reask_answers_on_disk(reask_dir)
    agree = 0
    for it in judged:
        key = (it["file"], it["line"])
        first = it.get("confidence_first", it.get("confidence"))
        if key in answers:
            if answers[key][0] != it.get("verdict"):
                stale.append("%s:%d verdict '%s' disagrees with the saved re-ask answer '%s' (judge wrote the file "
                             "before re-asking; re-run judge or merge the re-ask)" % (key + (it.get("verdict"), answers[key][0])))
            else:
                agree += 1
        elif first is not None and first < FLOOR:
            # the file's own `reasked` flag is not consulted: the receipt is the answer on disk
            stale.append("%s:%d first-pass confidence %.2f is under the floor %.2f and no re-ask answer for it is "
                         "on disk" % (key + (first, FLOOR)))
    print("STALENESS: %d re-ask batch(es) read from %s; %d judged verdict(s) match their saved re-ask answer, "
          "%d stale finding(s)" % (nbatches, reask_dir, agree, len(stale)))
    for s in stale:
        print("  FAIL stale: " + s)

    # (2)(3) per item, against the file as it is now
    rows, fails_by_kind, nfail = [], {k: 0 for k in FAIL_KINDS}, 0
    for f in sorted({i["file"] for i in judged}):
        in_file = [i for i in judged if i["file"] == f]
        path = os.path.join(ROOT, f)
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            current = extract_file(f)
        except OSError as e:
            for it in in_file:
                rows.append((it, [("unreadable", "file unreadable: %s" % e)], [], None))
            continue
        where = locate(in_file, current)
        for it in in_file:
            found, how = where[id(it)]
            fails, notes, aft = check_item(it, found, how, lines, path, window)
            rows.append((it, fails, notes, aft))
    print("ITEMS %d: status | verdict conf | file:line | prose b->a | cand b->a | flags b->a | note" % len(rows))
    for it, fails, notes, aft in sorted(rows, key=lambda r: (r[0]["file"], r[0]["line"])):
        b = measure(dict(it))
        status = "FAIL" if fails else "PASS"
        if fails:
            nfail += 1
            for k, _ in fails:
                fails_by_kind[k] += 1
        print("  %s %-21s %4s  %-46s %4d->%-4s %s->%s %d->%s  %s"
              % (status, it.get("verdict"), "%.2f" % it["confidence"] if it.get("confidence") is not None else "-",
                 "%s:%d" % (it["file"], it["line"]), b["prose_len"], "%d" % aft["prose_len"] if aft else "-",
                 "y" if b["candidate"] else "n", ("y" if aft["candidate"] else "n") if aft else "-",
                 b["flags"], "%d" % aft["flags"] if aft else "-",
                 "; ".join([m for _, m in fails] + notes)))
    for it, fails, _, _ in rows:
        for _, m in fails:
            print("FAIL %s:%d %s" % (it["file"], it["line"], m))
    if nfail or stale:
        print("FAIL %d of %d item(s) failed (%s)%s" % (
            nfail, len(rows), ", ".join("%s=%d" % kv for kv in fails_by_kind.items() if kv[1]),
            "; judged file STALE in %d place(s)" % len(stale) if stale else ""))
        return 1
    print("PASS %d item(s): every tag and specifier sequence kept, every move-to-source word found in a comment, "
          "judged file current" % len(rows))
    return 0


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
    pv = sub.add_parser("verify")
    pv.add_argument("--inp", default=None, help="the before corpus: the measure output judge consumed "
                    "(default: <judged>.before.json as judge froze it, else scratchpad/msg-audit.json)")
    pv.add_argument("--judged", default="scratchpad/msg-audit-judged.json")
    pv.add_argument("--reask-dir", default="scratchpad/msg-audit")
    pv.add_argument("--window", type=int, default=10, help="lines around the call searched for the moved words")
    pv.add_argument("--files", nargs="*", default=None, help="limit the per-item rows to these files (not the gate)")
    a = ap.parse_args()

    if a.cmd == "verify":
        return verify(a.inp, a.judged, a.reask_dir, a.window, set(a.files) if a.files else None)

    if a.cmd == "judge":
        items = [measure(i) for i in json.load(open(os.path.join(ROOT, a.inp), encoding="utf-8"))]
        cands, cost = judge(items, a.batch)
        if cands is None:
            return 4
        final, rcost = reask(cands)
        if final is None:
            print("FAIL judged file NOT written: the re-ask aborted, and a file of first-pass verdicts is the "
                  "defect write_judged() refuses; the per-batch answers are under scratchpad/msg-audit/", file=sys.stderr)
            return 4
        cost += rcost
        written = write_judged(final, os.path.join(ROOT, a.out))
        summarize_judged(written, cost, a.batch)
        before = judged_before_path(a.out)
        shutil.copyfile(os.path.join(ROOT, a.inp), os.path.join(ROOT, before))
        print("wrote %s and froze its before corpus as %s (verify's default --inp)" % (a.out, before))
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
    print("CANDIDATES %d (prose>70 chars before the first fact, or a named-content flag, or >1 sentence)"
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
