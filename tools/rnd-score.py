#!/usr/bin/env python3
"""Deterministic scorers for the protocol's "judgement" steps — mechanizes the judge out of the loop.

Each of these steps was kind:"judgement": in live mode run.py paused for an operator/LLM to read
the evidence and pick an answer token. But every one is a DETERMINISTIC decision tree over
structured output (measured integers/hashes/timestamps/TSV rows) — no discretion. A scorer here
computes the SAME answer token a correct judge would, from the SAME evidence files. run.py
auto-answers a judgement carrying a `scorer` field with this token (live AND selftest-dry),
mapping it to GREEN/RED/INVALID exactly as `apply_answer` maps an operator answer — so the 3-way
verdict and every V-rule are unchanged, only the human is removed.

Falsifiability is preserved and PROVEN by the scenarios: the selftest walks green + defect-*
dry with each scorer supplying the answer, and grades the result against each scenario's
recorded truth. Every scorer must therefore reproduce truth on green (GREEN) AND be SEEN to emit
RED/INVALID on its defect fixture:
    rnd5-verdict        defect-p4-map-unwitnessed        -> MAP_IN_AGENT_LOG / RED
    rnd3-synth-crop     defect-p4-caret-hash             -> SYNTH_NO_SYNTHPAINT / RED
    precondition-...    defect-precondition-mismatch     -> MISMATCH / RED
    net2-zero-reboot    defect-p2-second-boot            -> SECOND_BOOT / RED
    u1-scan-to-dom0     defect-p3-updates-u1-scan-failure-> SCAN_FAILED / RED
    u2-coldboot-class   defect-p3-updates-scan-suppressed-> BOOT_PASS_NEVER_RAN / INVALID
    p5-suite            defect-p5-sg-gate-leaked         -> GATE_LEAKED / RED
A wrong scorer makes the selftest deviate; it can never turn a defect green.

One token maps to N/A rather than GREEN/RED/INVALID: rnd5-verdict's START_HIDDEN_BY_DESIGN.
On a SHIPPED build Start is deliberately not presented in seamless (SeamlessStart=0; the
positive is graded in the suite's SG9 cell, and enabling SeamlessStart=1 in an acceptance
campaign is forbidden - p5-safeguards.json p5-sg9-devarm), so the shipped-correct state
(denial line present, zero maps by both witnesses) is BY DESIGN, never a defect and never a
broken instrument. run.py records it as a non-halting N/A row - not a PASS - and the campaign
continues; the RED branches are evaluated FIRST, so a real map still fails whatever the denial
line says.

Fail-closed doctrine (V3): missing data is the step's unusable-evidence token, NEVER a pass in
either direction; a measured contradiction (MISMATCH) outranks a merely-absent line; a token the
scorer cannot justify from the evidence is never emitted.

Usage:  rnd-score.py <scorer-name> <evidence-file> [<evidence-file> ...]
Prints exactly one line:  RND-ANSWER: <TOKEN>   (always exit 0; the token carries the verdict).
The TOKEN is one of the step's judgement.answers keys; run.py refuses any token outside the
step's closed set as INVALID-INSTRUMENT, so an unusable invocation can never turn into a verdict.
"""
import datetime
import json
import os
import re
import sys


def read_all(paths):
    text = ""
    for p in paths:
        try:
            text += open(p, encoding="utf-8", errors="replace").read() + "\n"
        except OSError:
            pass
    return text


def read_file(paths, basename):
    """Return the named evidence file's text, or None when absent/unreadable. Evidence is picked
    by BASENAME, not position, so a reordered evidence list cannot silently swap two files'
    roles; None fails closed at the caller (missing data is never approximated)."""
    for p in paths:
        if os.path.basename(p) == basename:
            try:
                return open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                return None
    return None


def counter(text, key):
    """The witness lines are 'KEY <int>' on their own line (rnd5-two-witness.txt)."""
    m = re.search(rf"^{re.escape(key)}\s+(\d+)\s*$", text, re.M)
    return int(m.group(1)) if m else None


# The shipped-spec denial (agent perf.h: SeamlessStart DWORD, default 0 - Start hidden in
# seamless). Matched only inside a '  D ' DISCRIM sample line, the collect step's own grep class.
RND5_DENIAL_RE = re.compile(
    r"^  D .*Start surface not presented in seamless mode \(SeamlessStart=0\)", re.M)


def score_rnd5(text):
    # Apply IN ORDER (p4-rnd5-verdict decision rule). Missing counter -> EVIDENCE_INCOMPLETE.
    shot = counter(text, "SHOT_MAPPED")
    ovr_total = counter(text, "OVRMAP_TOTAL")
    ovr_big = counter(text, "OVRMAP_BIG")
    disc = counter(text, "DISCRIM_HITS")
    shell = counter(text, "SHELL_SURFACES")
    if None in (shot, ovr_total, ovr_big, disc, shell):
        return "EVIDENCE_INCOMPLETE"
    if ovr_big != 0:
        return "MAP_IN_AGENT_LOG"     # agent log shows an o-r MAP at screen scale (shot is blind to it)
    if shot != 0:
        return "WINDOW_IN_SHOT"       # a managed window reached dom0
    if ovr_total == 0 and RND5_DENIAL_RE.search(text):
        # Shipped spec (p5-safeguards.json p5-sg9-devarm): Start is deliberately NOT presented
        # in seamless (SeamlessStart=0), so on a release subject this stimulus CANNOT be
        # established and the absence is BY DESIGN, not vacuous - the denial line is the proof,
        # and the positive (Start correctly hidden) is graded in the suite's SG9 cell. N/A,
        # non-halting. Ordered AFTER the two RED branches so it can never mask a real leak:
        # defect-p4-map-unwitnessed carries this exact denial line PLUS OVRMAP_BIG 1 and still
        # resolves MAP_IN_AGENT_LOG above; any ovr=1 MAP at all (OVRMAP_TOTAL != 0) also
        # forfeits this branch and falls through to the fail-closed logic below.
        return "START_HIDDEN_BY_DESIGN"
    if disc == 0 or shell == 0:
        return "STIMULUS_ABSENT"      # the Start stimulus was never established -> negative is vacuous
    return "NOMAP_BOTH_WITNESSES"     # nothing reached dom0, by both witnesses, stimulus proven (SeamlessStart=1 dev arm only)


def score_rnd3(text):
    # p4-rnd3-synth-crop: judge ONLY the SYNTH/SYNTHPAINT accounting + the owner-relative crop line;
    # IGNORE any whole-window hash (a caret blink moves it).
    crop = re.search(
        r"synth rect \(owner-relative\).*?crop\s+(\S+)\s*->\s*(\S+)", text)
    synth_m = re.search(r"SYNTH events=(\d+)", text)
    synth_n = int(synth_m.group(1)) if synth_m else 0
    no_paint = ("SYNTH but NEVER" in text) or ("accounted but never painted" in text)
    if crop:                                  # a SYNTHPAINT rect was reported
        if "does not intersect" in text:
            return "RECT_NOT_IN_CAPTURE"
        a, b = crop.group(1), crop.group(2)
        return "RECT_PAINTED_CHANGED" if a != b else "RECT_IDENTICAL"
    if synth_n > 0 and no_paint:
        return "SYNTH_NO_SYNTHPAINT"          # SYNTH logged but never a SYNTHPAINT
    if synth_n > 0:
        return "SYNTH_NO_SYNTHPAINT"          # SYNTH accounted, no paint rect at all
    return "EVIDENCE_INCOMPLETE"              # accounting/crop line absent entirely


def score_precondition(text):
    """s7-precondition-authority (campaign.json): P1.0's authority rule, mechanized.

    Evidence = $MATRIX_OUT/precondition-lines.txt, written by matrix.sh: one 'cell <LABEL>' entry
    per install cell, followed by that cell's '=== PRECONDITION ===' line (the installer's own
    report of the state it FOUND - real form is JSON with "installed_qwt_count"; the older
    fixtures use the QWTPRODUCTS=<n> shorthand, both are parsed). The decision is a closed table
    over the cell SELECTOR and the FOUND count - no discretion:

        clean / fresh / 1stage / 2stage  -> the installer must have found NO QWT (count == 0)
        reinstall / upgrade / seeded / stock -> it must have found one (count >= 1)
        appvm / grade                    -> no install ran; not this check's subject (skipped)

    Anything else fails closed: an unknown selector or a count-free line proves nothing, and a
    'no' that was never measured must never read as a pass (V3). MISMATCH outranks LINE_ABSENT -
    a measured contradiction is the stronger fact - and zero install entries is LINE_ABSENT, so a
    run that listed nothing can never vacuously ALL_MATCH."""
    entries = []
    cur = None
    for line in text.splitlines():
        m = re.match(r"^cell\s+(\S+)", line)
        if m:
            cur = {"label": m.group(1), "body": []}
            entries.append(cur)
        elif cur is not None:
            cur["body"].append(line)
    verdicts = []
    for e in entries:
        lbl = e["label"].lower()
        if "appvm" in lbl or lbl.endswith("-grade"):
            continue
        if any(k in lbl for k in ("reinstall", "upgrade", "seeded", "stock")):
            want_present = True
        elif any(k in lbl for k in ("clean", "fresh", "1stage", "2stage")):
            want_present = False
        else:
            verdicts.append("MISMATCH")       # unknown selector: identity not established
            continue
        body = "\n".join(e["body"])
        pm = re.search(r"=== PRECONDITION === (.+)", body)
        if not pm:
            verdicts.append("LINE_ABSENT")
            continue
        cm = (re.search(r'"installed_qwt_count"\s*:\s*(-?\d+)', pm.group(1))
              or re.search(r"QWTPRODUCTS=(-?\d+)", pm.group(1)))
        if not cm:
            verdicts.append("LINE_ABSENT")    # a line naming no count decides nothing
            continue
        n = int(cm.group(1))                  # installer error paths report -1: matches neither
        ok = (n >= 1) if want_present else (n == 0)
        verdicts.append("ALL_MATCH" if ok else "MISMATCH")
    if not verdicts:
        return "LINE_ABSENT"
    if "MISMATCH" in verdicts:
        return "MISMATCH"
    if "LINE_ABSENT" in verdicts:
        return "LINE_ABSENT"
    return "ALL_MATCH"


def score_net2_zero_reboot(paths):
    """p2-net2-zero-reboot (p2-network.json): 'a second boot is a FAIL, not a property'
    (owner 2026-08-29), mechanized.

    Evidence: net1-latch-readback.txt (pre-attach MARKJSON with the boot timestamp),
    net2-health.txt (=== HEALTH === JSON at the 120 s bind budget), net2-postboot.txt
    (post-attach MARKJSON). Decision, in the step's own order:
      1. Both boot stamps present and DIFFERENT -> SECOND_BOOT, however healthy the bind now
         looks (the defect fixture is exactly a perfect bind hiding a reboot; the measured
         contradiction outranks everything else - MISMATCH over ABSENT).
      2. Either boot stamp, the HEALTH JSON, or any named bind field missing -> EVIDENCE_INCOMPLETE.
      3. Stamps byte-identical but the bind not clean (PV NIC unbound, an emulated NIC still
         present, APIPA/no real IP, no default route on PV, or the failure marker) -> NOT_BOUND.
      4. Otherwise -> SAME_BOOT_BOUND."""
    pre = read_file(paths, "net1-latch-readback.txt")
    health = read_file(paths, "net2-health.txt")
    post = read_file(paths, "net2-postboot.txt")
    if pre is None or health is None or post is None:
        return "EVIDENCE_INCOMPLETE"
    bpre = re.search(r'"boot":\s*"([^"]+)"', pre)
    bpost = re.search(r'"boot":\s*"([^"]+)"', post)
    if not bpre or not bpost:
        return "EVIDENCE_INCOMPLETE"
    if bpre.group(1) != bpost.group(1):     # byte-compare, per the step: never parsed-and-rounded
        return "SECOND_BOOT"
    hm = re.search(r"=== HEALTH === (\{.*)", health)
    if not hm:
        return "EVIDENCE_INCOMPLETE"
    try:
        h = json.loads(hm.group(1).splitlines()[0])
    except ValueError:
        return "EVIDENCE_INCOMPLETE"
    checks = h.get("checks") or {}
    pv, ap = checks.get("pv_drivers_bound"), checks.get("pvnic_applier")
    if not isinstance(pv, dict) or not isinstance(ap, dict):
        return "EVIDENCE_INCOMPLETE"
    pve, ape = pv.get("evidence") or {}, ap.get("evidence") or {}
    needed = [("pass" in pv), ("emulated_nics_still_present" in pve), ("pass" in ap),
              ("pv_adapter_ips" in ape), ("apipa_present" in ape),
              ("default_route_on_pv" in ape), ("failure_marker_present" in ape)]
    if not all(needed):                     # a field never measured must never read as clean
        return "EVIDENCE_INCOMPLETE"
    ips = ape["pv_adapter_ips"]
    real_ip = isinstance(ips, list) and any(
        isinstance(i, str) and i and not i.startswith("169.254.") for i in ips)
    bound = (pv["pass"] is True and pve["emulated_nics_still_present"] == []
             and ap["pass"] is True and real_ip and ape["apipa_present"] == []
             and ape["default_route_on_pv"] is True
             and ape["failure_marker_present"] is False)
    return "SAME_BOOT_BOUND" if bound else "NOT_BOUND"


def _guest_local_dts(s):
    """Parse a GUEST_KICK_LOCAL payload ('%date% %time%', e.g. 'Tue 09/01/2026 18:12:43.71').
    The date order is locale-dependent (en-US MM/DD vs en-GB DD/MM), so EVERY valid reading is
    returned; the caller may use an ordering verdict only if all readings agree - an ambiguity
    that could flip the verdict is unusable evidence, never a coin toss (V3)."""
    m = re.search(r"(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})", s)
    if not m:
        return []
    a, b, y, hh, mm, ss = (int(x) for x in m.groups())
    out = []
    for mo, dd in {(a, b), (b, a)}:
        try:
            out.append(datetime.datetime(y, mo, dd, hh, mm, ss))
        except ValueError:
            pass
    return out


def _iso_dt(s):
    try:
        return datetime.datetime.fromisoformat(
            s.strip().replace("Z", "+00:00")).replace(tzinfo=None)
    except (ValueError, AttributeError):
        return None


def score_u1_scan(paths):
    """p3-u1-verdict (p3-updates.json): availability reached dom0 - judged from OUTPUT (status
    JSON + qvm-features + proxy slice), never log prose. The step's own decision tree:
      1. Any of the four files, or any END-MARKER witness (STATUSEOF/AGENTLOGEOF/GUEST_KICK_LOCAL+
         KICKED/FEATEOF/MARKER), missing -> EVIDENCE_INCOMPLETE.
      2. No JSON at all before STATUSEOF while the kick recorded KICKED -> NO_STATUS_WRITTEN
         (the product wrote nothing inside the declared settle against its <=3 min binding).
      3. phase error/scan-failed, or a non-null error string -> SCAN_FAILED, regardless of how
         healthy anything else looks (the 0x8024402C class, measured 4/4 on 2026-08-30).
      4. 'skipping this scheduled scan' in the agent-log slice, or done_ts PREDATING
         GUEST_KICK_LOCAL -> SCAN_SUPPRESSED_OR_STALE (rule 9: reading my own earlier answer).
      5. GREEN only when EVERY named condition holds: phase done, done_ts fresh, the
         'Sync-Revocation: 3/3 CTLs' line, count>0 with available[] populated, AND the
         dom0-observable half (a real qvm-features value, not an error). Any other residue fails
         closed as EVIDENCE_INCOMPLETE - the scorer never invents a fifth statement."""
    status = read_file(paths, "u1-status.txt")
    kick = read_file(paths, "u1-kick-utc.txt")
    feat = read_file(paths, "u1-feature.txt")
    proxy = read_file(paths, "u1-proxy-slice.txt")
    if None in (status, kick, feat, proxy):
        return "EVIDENCE_INCOMPLETE"
    if "STATUSEOF" not in status or "AGENTLOGEOF" not in status:
        return "EVIDENCE_INCOMPLETE"
    km = re.search(r"^GUEST_KICK_LOCAL\s+(.+)$", kick, re.M)
    if not km or not re.search(r"^KICKED\s*$", kick, re.M):
        return "EVIDENCE_INCOMPLETE"
    if "FEATEOF" not in feat:
        return "EVIDENCE_INCOMPLETE"
    if not re.search(r"^MARKER \S+", proxy, re.M):
        return "EVIDENCE_INCOMPLETE"
    body, _, rest = status.partition("STATUSEOF")
    agentlog = rest.split("AGENTLOGEOF")[0]
    if "{" not in body:
        return "NO_STATUS_WRITTEN"          # KICKED is proven above; the file simply is not there
    jm = re.search(r"\{.*\}", body, re.S)
    if not jm:
        return "EVIDENCE_INCOMPLETE"        # a brace with no closing: truncated, not absent
    try:
        st = json.loads(jm.group(0))
    except ValueError:
        return "EVIDENCE_INCOMPLETE"
    err = st.get("error")
    if st.get("phase") in ("error", "scan-failed") or (isinstance(err, str) and err.strip()):
        return "SCAN_FAILED"
    if "skipping this scheduled scan" in agentlog:
        return "SCAN_SUPPRESSED_OR_STALE"
    done_dt = _iso_dt(st.get("done_ts") or "")
    kick_dts = _guest_local_dts(km.group(1))
    if done_dt is None or not kick_dts:
        return "EVIDENCE_INCOMPLETE"
    orders = {done_dt >= k for k in kick_dts}
    if len(orders) != 1:
        return "EVIDENCE_INCOMPLETE"        # date-order ambiguity flips the verdict: unusable
    if not orders.pop():
        return "SCAN_SUPPRESSED_OR_STALE"   # done_ts predates the kick - the pass never ran fresh
    featval = feat.split("FEATEOF")[0].strip()
    feat_ok = bool(featval) and "no such feature" not in featval \
        and not featval.lower().startswith("qvm-features:")
    count, avail = st.get("count"), st.get("available")
    if (st.get("phase") == "done"
            and re.search(r"Sync-Revocation: 3/3 CTLs", agentlog)
            and isinstance(count, int) and count > 0
            and isinstance(avail, list) and len(avail) > 0
            and feat_ok):
        return "SCAN_DONE_TO_DOM0"
    return "EVIDENCE_INCOMPLETE"


def score_u2_coldboot(paths):
    """p3-u2-verdict (p3-updates.json): VM-class classification on a REAL cold boot, witnessed by
    what CHANGED. The counters in u2-coldboot.sh's own summary line are the authority; the '->'
    verdict arrows corroborate. Decision:
      1. A FATAL/REFUSING line or a '-> INVALID-INSTRUMENT' arrow -> HARNESS_DID_NOT_GRADE.
      2. No summary line, no '->' arrow at all, or no 'COLD BOOT PROVEN' -> HARNESS_DID_NOT_GRADE.
      3. class_lines == 0 -> BOOT_PASS_NEVER_RAN (grades the SCAN not having run - rule 9's
         suppression class - and says nothing about classification).
      4. FRESHNESS/DELTA GUARD: class_lines >= 1 must have been SEEN appearing - the poll series
         must start at 0 before any nonzero reading. A count that never read 0 on this boot can
         be stale log content from an earlier pass, and stale content must never pass ->
         HARNESS_DID_NOT_GRADE.
      5. class_correct=false -> CLASSIFIED_WRONG (the QdbDaemon startup race live), whatever the
         arrow says - a measured contradiction outranks prose.
      6. GREEN only with class_correct=true AND the exact '-> PASS: ... CORRECTLY' arrow AND
         '=== finished rc=0 ==='. Any residue fails closed as HARNESS_DID_NOT_GRADE."""
    t = read_file(paths, "u2-console.txt")
    if t is None:
        return "HARNESS_DID_NOT_GRADE"
    if re.search(r"\bFATAL\b|\bREFUSING\b", t) or "-> INVALID-INSTRUMENT" in t:
        return "HARNESS_DID_NOT_GRADE"
    sm = re.search(r"class_lines=(\d+) class_correct=(\w+)", t)
    if not sm or not re.search(r"-> (PASS|FAIL|INVALID)", t):
        return "HARNESS_DID_NOT_GRADE"
    if "COLD BOOT PROVEN" not in t:
        return "HARNESS_DID_NOT_GRADE"
    class_lines = int(sm.group(1))
    class_correct = sm.group(2).lower() == "true"
    if class_lines == 0:
        return "BOOT_PASS_NEVER_RAN"
    polls = [int(n) for n in
             re.findall(r"\+\d+s: 'VM class' lines in the updater log: (\d+)", t)]
    if not polls or polls[0] != 0:
        return "HARNESS_DID_NOT_GRADE"      # never seen at 0 on THIS boot: stale content possible
    if not class_correct:
        return "CLASSIFIED_WRONG"
    if ("-> PASS: the boot pass classified this TemplateVM CORRECTLY" in t
            and re.search(r"=== finished rc=0 ===", t)):
        return "CLASSIFIED_CORRECT_ON_COLD_BOOT"
    return "HARNESS_DID_NOT_GRADE"


def score_p5_suite(paths):
    """p5-suite-verdict (p5-safeguards.json): the four unattended SG cells, judged from the
    suite's OWN five-column TSV plus the transcript's precondition proofs - never log prose.
    Mirrors tools/campaign-verdict.sh's grammar (cell/check/verdict/detail[/evidence]) over
    cells SG4, SG2, SG3, SG9. Decision:
      1. verdicts.tsv absent/empty, or the console lacks '=== P5 finished rc=' ->
         EVIDENCE_MISSING (rule 14: an exit-0 whose TSV is absent or empty is a KILLED run).
      2. FAIL on SG4/SG2/SG9 -> GATE_LEAKED (a measured red outranks a missing row).
      3. Else FAIL on SG3 -> GATE_OVERFIRED (the safeguard eats UI it must keep).
      4. Any of the four with an INVALID-* verdict or no row at all -> CELLS_INVALID.
      5. GREEN only when all four rows are PASS/PASS-UNPROVEN AND the console carries its own
         precondition proofs ('containment PROVEN: guest' + 'capture path proven alive').
         A verdict outside that grammar, or unproven preconditions, fails closed as
         CELLS_INVALID - the cells were not validly graded green."""
    tsv = read_file(paths, "verdicts.tsv")
    con = read_file(paths, "p5-console.txt")
    if tsv is None or con is None or not tsv.strip():
        return "EVIDENCE_MISSING"
    if not re.search(r"=== P5 finished rc=", con):
        return "EVIDENCE_MISSING"
    cells = ("SG4", "SG2", "SG3", "SG9")
    rows = {}
    for line in tsv.splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0] in cells:
            rows.setdefault(f[0], []).append(f[2])
    def has(cell, pred):
        return any(pred(v) for v in rows.get(cell, []))
    if any(has(c, lambda v: v.startswith("FAIL")) for c in ("SG4", "SG2", "SG9")):
        return "GATE_LEAKED"
    if has("SG3", lambda v: v.startswith("FAIL")):
        return "GATE_OVERFIRED"
    if any(c not in rows for c in cells) or \
            any(has(c, lambda v: v.startswith("INVALID")) for c in cells):
        return "CELLS_INVALID"
    all_green = all(all(v in ("PASS", "PASS-UNPROVEN") for v in rows[c]) for c in cells)
    preconds = ("containment PROVEN: guest" in con) and ("capture path proven alive" in con)
    if all_green and preconds:
        return "ALL_FOUR_GRADED_GREEN"
    return "CELLS_INVALID"


# Text scorers get the concatenated evidence; path scorers pick their files by basename (they
# must tell two files' roles apart, which concatenation destroys).
SCORERS = {"rnd5-verdict": score_rnd5, "rnd3-synth-crop": score_rnd3,
           "precondition-authority": score_precondition}
PATH_SCORERS = {"net2-zero-reboot": score_net2_zero_reboot,
                "u1-scan-to-dom0": score_u1_scan,
                "u2-coldboot-class": score_u2_coldboot,
                "p5-suite": score_p5_suite}


def main(argv):
    if len(argv) < 3 or (argv[1] not in SCORERS and argv[1] not in PATH_SCORERS):
        print("RND-ANSWER: EVIDENCE_INCOMPLETE")   # unusable invocation -> INVALID, never a pass
        return 0
    if argv[1] in PATH_SCORERS:
        token = PATH_SCORERS[argv[1]](argv[2:])
    else:
        token = SCORERS[argv[1]](read_all(argv[2:]))
    print(f"RND-ANSWER: {token}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
