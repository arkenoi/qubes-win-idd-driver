#!/usr/bin/env python3
"""prose-batch.py - write one INSTRUCTION file per rewrite batch, in code.

The rewrite is the only stage that needs a language model. Everything it is told - which files, which
brief, where to write, which hard constraints apply to that file class, and which specific rules must
survive - is computable, so it is computed here and handed over as a file. A prompt that retypes this
by hand is both expensive and a place to get a constraint wrong.
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "scratchpad", "prose-audit2")

CLASS_RULES = {
 "docs/ADR-": [
   "SECTION NUMBERS ARE STABLE. Never renumber, delete or reorder a numbered section. A dead decision",
   "KEEPS ITS NUMBER and takes Status REJECTED / SUPERSEDED by N / RETIRED / WITHDRAWN.",
   "Status and Decision are mandatory in every section. Keep each heading line verbatim, number included.",
   "docs/ADR-README.md is the format contract. Compress HARD *inside* sections.",
   "Keep the one-line pointer to docs/ADR-README.md if the file has one - it is how the contract is found.",
 ],
 "findings/": [
   "Every bullet under '## CURRENT STATE' must END with [verified YYYY-MM-DD] or contain UNVERIFIED",
   "(tools/lint-harness.py rule L8). Keep those tokens exactly.",
   "A FIELD-REPORTED entry may not be called closed by a release, nor moved out of this file, without",
   "the token REPORTER-CONFIRMED. Keep such status wording exactly as it stands.",
 ],
 ".claude/skills/": [
   "Keep the YAML frontmatter (name, description) BYTE-IDENTICAL - the description is what makes the",
   "skill load at the right moment. Keep every prohibition, command, flag and numbered rule.",
   "Where a rule is followed by the incident that produced it, compress the incident to the clause that",
   "makes the rule make sense, and keep any measured cost.",
 ],
 "CLAUDE.md": [
   "THIS FILE IS BINDING AND IS THE MOST SENSITIVE FILE IN THE REPO.",
   "NO RULE MAY BE LOST OR WEAKENED. You may ONLY shorten wording.",
   "Keep every command, path, flag, qube name, feature name, registry value, constant and table row,",
   "and keep every table intact - including the block-device capability table, every row of which exists",
   "because that capability was wrongly declared impossible.",
   "Never turn a MUST into a SHOULD, add an exception, soften a prohibition, or make an absolute",
   "statement conditional. Do not merge two rules if that makes either weaker or ambiguous.",
   "If you believe a rule is redundant: KEEP IT and say so in your report. Do not decide it.",
   "Shortening this file only slightly is the CORRECT outcome. Report the small number honestly.",
 ],
}

# Specific things that read like narrative but are load-bearing, or that a rewrite could silently
# invert. Keyed by file.
NOTES = {
 "CLAUDE.md": ["Where it corrects an earlier belief, the correction is load-bearing: keep the corrected",
               "rule AND that the earlier version was wrong, in one line - that is what stops the wrong",
               "version being re-derived."],
 "README.md": ["USER-FACING, and its feature table is a SPECIFICATION - the authority for what each",
               "feature does; where behaviour and this file disagree, this file wins and the code changes.",
               "Do not change the meaning of a feature row, rename a feature, or add/remove a control.",
               "There is exactly ONE control for guest-originated fullscreen. Invent no knobs or modes.",
               "59 of its 60 units are load-bearing: tighten sentences, cut nothing substantive."],
 "findings/rules.md": ["Its JOB is to hold the incident behind each binding rule in CLAUDE.md so a rule can be",
               "read short and its reason looked up. Do not strip it to nothing: compress each entry to the",
               "rule, the one clause that makes it make sense, and any measured cost. The RETIRED lines must",
               "still be findable as RETIRED - that is what stops them being reopened."],
 "docs/ADR-README.md": ["THIS IS THE FORMAT CONTRACT for every ADR here. Do not change or drop a status word,",
               "and do not relax that Status and Decision are mandatory or that section numbers are stable."],
 "docs/ADR-display.md": ["One rule is absolute: a monitor dom0 cannot see must never extend the desktop, because",
               "that enlarges the desktop bounding box and breaks seamless coordinates. A monitor to be",
               "ignored is made INACTIVE, not merely left uncaptured."],
 "docs/ADR-windows.md": ["Its section 4 (secure desktop by mode) and section 10 (autologon) are referenced by",
               "number from another ADR: keep both numbers and their meaning.",
               "TWO FULLSCREEN MODES MUST NEVER BE CONFLATED: the boot/logon/shutdown screen is refused",
               "unconditionally and governed by no feature; a borderless app window is governed by exactly one",
               "opt-in control. Preserve that distinction exactly."],
 "docs/ADR-uac.md": ["Several decisions are PROPOSED or explicitly NOT PROVEN (not compiled, never run on a",
               "guest). Keep every such qualifier - do not let a proposal read as shipped. Keep the rule that",
               "nothing of ours ever answers or activates a UAC prompt."],
 "docs/ADR-supervision.md": ["Keep: a component that was working and stops is a FAILURE, reported loudly, never",
               "quietly recovered from and never treated as a capability change; start-time capability is",
               "latched once and never re-read at runtime."],
 "docs/ADR-logging.md": ["One dated record looks like narrative but must survive in some form (you may shorten",
               "it): a decision chosen and then superseded the same day once two facts against it were",
               "supplied. It exists to show what a one-sided brief does."],
 "docs/ADR-acceptance.md": ["Carries the decision that REPLACED 'full acceptance before every release' with a gate",
               "SCOPED to what the diff touches, plus the floor that forces the full set anyway. Keep the",
               "scoping rule, the floor conditions and the named tool exactly - a release gate is enforced",
               "from this."],
 "findings/wedge.md": ["Must survive: forensics on this was STOPPED by the owner, and the PV drivers are",
               "explicitly NOT the cause. A reader must not come away thinking either question is open.",
               "Keep the named signature, the two shapes and how to tell them apart, and what is RULED OUT."],
 "findings/network.md": ["Keep the testing protocol precisely: a second boot is a FAILURE; traffic is asserted",
               "with a file transfer, never by pinging the gateway; templates must not carry a netvm while",
               "AppVMs exercising PV networking must."],
 "findings/updates.md": ["Keep: guest auto-update is OFF and dom0 drives every install; the relay answers a",
               "non-sanctioned request with a FINAL 403, never a transient answer and never a timeout.",
               "One Win10 22H2 matter is informational BY DESIGN - a Win10 22H2 guest reporting zero",
               "actionable updates with ESU items as information is CORRECT, and one KB is never chased.",
               "Do not rewrite that into a defect or a TODO."],
 "docs/ADR-updater.md": ["Same updater rules as findings/updates.md: dom0-owned installs, guest AU off, the",
               "relay's FINAL 403."],
 "findings/windowing.md": ["Its window classes, style flags, predicates, thresholds and geometry rules are the",
               "SPECIFICATION of a filter that ships. Keep every one, and keep the discriminators that tell",
               "one window kind from another."],
 "docs/BENCHMARKS.md": ["Keep every measured figure and the per-repetition values, and the rule that a verdict is",
               "reported only when the ranges are disjoint. Cut the commentary around them."],
 "docs/RESEARCH-kvm-guest-display-vs-qubes.md": ["One conclusion must survive: RDP-over-vchan was rejected."],
 "docs/RESEARCH-xenbus-store-wait.md": ["This concerns a line the owner has RETIRED. Keep that it is retired and",
               "that stock behaviour is the intended state. Do not write it as an open question or a lead."],
 "docs/BIND-DIRS.md": ["The owner has already decided this area. Keep the decision as stated; do not reopen it."],
 "DESIGN-gui-daemon-restart-survival.md": ["Names defects in components that are NOT ours and are candidates for",
               "an upstream report. Keep those descriptions precise, and keep any note that upstream",
               "submission needs the owner's approval of the exact text."],
 "docs/upstream-xen-pv-grant-revoke-spin.md": ["Describes a defect in a component that is NOT ours. Keep the",
               "technical description precise and keep that an upstream report needs the owner's approval."],
 "docs/upstream-xl-console-overflow.md": ["Describes a defect in a component that is NOT ours. Keep the technical",
               "description precise and keep that an upstream report needs the owner's approval."],
 "docs/ACCEPTANCE-PROTOCOL.md": ["Superseded by protocol/run.py as the authority; keep that pointer."],
}

RELEASE_NOTE_RULE = [
   "RELEASE NOTES ARE THE MOST COMPACTABLE FILES IN THIS CORPUS. A release note's lasting value is:",
   "what changed, what it fixed, any behaviour a user must know about, and any caveat still in force.",
   "Cut how it was tested that week, who ran what, per-run numbers, and the status tables of a campaign",
   "that finished long ago. Reduce each to a short dense note. Do NOT delete the file.",
]
FIELD_REPORT_RULE = [
   "THIS FILE CONCERNS A FIELD REPORT. A field-reported matter may NOT be described as closed or fixed",
   "without the token REPORTER-CONFIRMED. Keep every hedge about what is confirmed on the reporter's own",
   "environment exactly as written. PUBLIC repo: keep existing wording and add no personal detail about",
   "the reporter. This is a TEXT task - it does not reproduce anything and touches no guest.",
]

def rules_for(rel):
    out = []
    for k, v in CLASS_RULES.items():
        if rel == k or rel.startswith(k):
            out += v
    base = os.path.basename(rel)
    if base.startswith(("RELEASE-NOTES", "RELEASE-QUALIFICATION")):
        out += RELEASE_NOTE_RULE
    if "GWECK" in base.upper() or "REPORTS-forum" in base:
        out += FIELD_REPORT_RULE
    out += NOTES.get(rel, [])
    return out

def main():
    batches = json.load(open(os.path.join(OUT, "batches.json"), encoding="utf-8"))
    briefs = {b["file"]: b for b in json.load(open(os.path.join(OUT, "briefs.json"), encoding="utf-8"))}
    # fold the lone tiny batch into the previous one
    batches = [list(b) for b in batches if b]
    # `batches[-2] += batches.pop()` RESOLVES THE STORE INDEX AFTER THE POP, so it loaded the
    # second-to-last list, extended it, and stored the result over the THIRD-to-last - losing a whole
    # batch and duplicating another. Its own printout showed two batches with identical byte counts.
    if len(batches) > 1 and len(batches[-1]) == 1 and briefs[batches[-1][0]]["bytes"] < 3000:
        tail = batches.pop()
        batches[-1].extend(tail)
    made = []
    for i, files in enumerate(batches, 1):
        L = []
        L.append("REWRITE BATCH %02d - %d file(s), %s bytes of original prose"
                 % (i, len(files), format(sum(briefs[f]["bytes"] for f in files), ",")))
        L.append("=" * 96)
        L.append("")
        L.append("THE OWNER'S INSTRUCTION, VERBATIM:")
        L.append('  "I want it compacted to the point, rewritten in simple and comprehencible sentences,')
        L.append('   removing redundancies, rants, historical references, past mistakes, long-closed issues')
        L.append('   -- just useful guidelines and caveats to be saved."')
        L.append("")
        L.append("HOW TO WORK, PER FILE")
        L.append("  1. Read the file's BRIEF first. It already names every unit to cut, with line ranges,")
        L.append("     decided per unit by a judge. Do not re-derive the cut list and do not second-guess it,")
        L.append("     except where a hard constraint below forbids a cut - then keep the unit and say so.")
        L.append("  2. Read the original. Write the rewrite to the STAGED path. NEVER edit an original.")
        L.append("  3. CUT the listed units outright. The rules they sit around live in OTHER units and must")
        L.append("     survive. An empty cut list means removing content is NOT authorised - compact wording only.")
        L.append("  4. COMPACT everything else: same facts, fewer and simpler sentences, short declaratives.")
        L.append("     Drop 'I/we discovered', dates that date nothing, who was annoyed, how long it took, and")
        L.append("     score-keeping. KEEP every rule, caveat, number, path, command, log tag, constant, flag,")
        L.append("     API name, registry key, error code, defect discriminator and measured cost.")
        L.append("  5. A historical reference STAYS only if it changes what someone would do. A rejected option")
        L.append("     stays as ONE line naming it and why, if that stops it being re-proposed.")
        L.append("  6. Do not invent, do not generalise, do not add advice that was not there.")
        L.append("  7. Keep the markdown shape: headings, tables and fenced blocks stay.")
        L.append("")
        L.append("GENERAL CONSTRAINTS")
        L.append("  - This is a PUBLIC repo: add no capture, no per-run evidence, no personal detail.")
        L.append("  - TEXT ONLY. Do not run qvm-*, qtest, or anything under mgmt/ or protocol/. Do not start,")
        L.append("    stop or probe a guest: a rig campaign is running and a stray command would corrupt it.")
        L.append("")
        for f in files:
            b = briefs[f]
            L.append("-" * 96)
            L.append("FILE: %s   (%s bytes, %d units, %d unit(s) to cut%s)"
                     % (f, format(b["bytes"], ","), b["units"], b["cuts"],
                        ", HIGH STAKES" if b["high_stakes"] else ""))
            L.append("  BRIEF:  %s" % b["brief"])
            L.append("  WRITE:  scratchpad/prose-audit2/staged/%s" % f)
            r = rules_for(f)
            if r:
                L.append("  CONSTRAINTS:")
                for line in r:
                    L.append("    " + line)
        L.append("-" * 96)
        L.append("")
        L.append("REPORT BACK, facts only, one line per file: bytes before/after, what you cut, and for any")
        L.append("ADR a confirmation that every section number still exists unchanged. Then, separately: every")
        L.append("unit you were told to cut but kept and why, every rule you believed redundant but kept, and")
        L.append("anything you could not decide. Do not describe your effort.")
        p = os.path.join(OUT, "work", "batch-%02d.txt" % i)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write("\n".join(L) + "\n")
        made.append((i, len(files), sum(briefs[f]["bytes"] for f in files), os.path.relpath(p, ROOT)))
    for i, n, b, p in made:
        print("batch-%02d  %2d file(s)  %9s B  -> %s" % (i, n, format(b, ","), p))
    print("\n%d batch instruction file(s)" % len(made))
    return 0

if __name__ == "__main__":
    sys.exit(main())
