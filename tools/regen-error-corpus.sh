#!/bin/bash
# regen-error-corpus.sh - produce the corpus lines for harness failure sites BY EXPANDING THE
# SOURCE'S OWN STRING LITERAL. The text a gate is measured against must come from the code under
# test, not from whoever is tuning the gate: hand-typing the expected line is how a gate is made to
# pass without being made to work. Run it and diff against mgmt/harness/error-corpus.txt.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
python3 - "$@" <<'PY'
import re, subprocess, sys
CORPUS="mgmt/harness/error-corpus.txt"
lines=[]
SITES = [
 ("LOGVOLBINDUPGRADE", "mgmt/harness/logvol-lib.sh",    "no LOGVOL-BIND line came back from"),
 # The COVERED case (the volume read succeeded) carries no level by design - it is expected, and the
 # stall clock is the detector (SWEEPWARNUNLEDGERABLE). It stays a site: with the level-based class
 # below it lands in BENIGN, which asserts it is NOT flagged, so re-adding a [WARN] fails precision.
 ("HARNESSLOGUNSWEPT", "mgmt/harness/quick-upgrade.sh", "no qrexec for ${unreach}s; the guest"),
 ("HARNESSGAPWITNESS", "mgmt/harness/quick-upgrade.sh", "qrexec-gap witness (log VOLUME"),
 ("HARNESSLOGUNSWEPT", "mgmt/harness/quick-upgrade.sh", "no qrexec for ${unreach}s - and the log volume"),
 ("DOM0SENDSPARKHANG", "mgmt/harness/quick-upgrade.sh", "DOM0SENDSUNREAD $1: no record of what dom0"),
 ("CELLFAILSUMMARY",   "mgmt/harness/quick-upgrade.sh", "summary: $PASS passed, $FAIL failed"),
 ("LOGVOLBINDWARN",    "mgmt/harness/matrix.sh",        "log-volume bind FAILED"),
 # A LEVEL AFTER A PREFIX, which this corpus must keep covering. LOGVOLBINDWARN used to be the
 # only MUST line of that shape ("win11-up: [WARN] ..."); it became a FATAL line at position
 # zero when the bind turned into a hard stop, which left every mid-line case to the stamped
 # guest lines and would let a position-anchored gate pass. This emitter is live and prefixed.
 # The log-volume PULL warning would have been the closer match, but its payload interpolates a
 # command substitution carrying its own quotes and the expander cannot evaluate it.
 ("WITNESSNOVERDICT",   "mgmt/harness/matrix.sh",       "render witness produced no verdict"),
 ("SEALEDVERSION",     "mgmt/harness/quick-upgrade.sh", "records no sealed_version"),
]
# python emitters: (tag, file, anchor, prelude, expression)
PYSITES = [
 ("VMEXECSHIMUNROUTED", "tools/replay-dom0-update.py", 'print(f"{\'[ERROR] \' if bad else \'\'}[{step}] rc={rc}{verdict}")',
  dict(step="cat log", rc=1, verdict="  <-- UNEXPECTED", bad=True)),
 ("WUFIRSTCONTACTSILENT", "tools/replay-dom0-update.py", 'print(f"{\'[ERROR] \' if bad else \'\'}[{step}] rc={rc}{verdict}")',
  dict(step="entrypoint", rc=1, verdict="", bad=True)),
]
PYSITES_OK = [
 ("VMEXECSHIMOK", "tools/replay-dom0-update.py", 'print(f"{\'[ERROR] \' if bad else \'\'}[{step}] rc={rc}{verdict}")',
  dict(step="cat log", rc=0, verdict="  <-- OK", bad=False)),
 ("ENTRYPOINTOK", "tools/replay-dom0-update.py", 'print(f"{\'[ERROR] \' if bad else \'\'}[{step}] rc={rc}{verdict}")',
  dict(step="entrypoint", rc=0, verdict="", bad=False)),
]
# values chosen to look like a real run; they are stand-ins for runtime state, not part of the test
PRELUDE = ('el=135; unreach=135; vm=win11-up; rc=124; PASS=3; FAIL=2; sends_rc=124; cpu=0; quiet=1; '
           'OUT=/home/user/qwt-quick-upgrade/win11de-fix-1; M=/home/user/m; GOLDEN=win11de-qwt; '
           'lastknown="Install failed 0x80070643"; c=win11-acc-b2; set -- win11de-fix win11-up; ')
bad = 0
for tag, path, anchor in SITES:
    # A COMMENT IS NOT AN EMITTER. The anchor used to be matched anywhere in the file, so when
    # matrix.sh's "[WARN] log-volume bind failed" became a FATAL "...bind FAILED", the stale anchor
    # stopped matching the emitter and matched the two COMMENTS that quote the old wording instead.
    # The regenerator then expanded a comment into a corpus entry with no level, filed it BENIGN,
    # and the gate was left asserting that a bind failure must NOT be flagged. Comment lines are
    # excluded, and a site whose anchor survives only in prose is a MISS, not a corpus entry.
    def _anchor_is_code(l):
        # The anchor must sit in CODE, not in a comment - and not only at the start of the line:
        # a trailing `# ... log-volume bind FAILED` on a live line would pass a startswith() test.
        # Walk to the anchor and refuse it if an unquoted # opened a comment before it.
        i = l.index(anchor)
        sq = dq = False
        for ch in l[:i]:
            if ch == "'" and not dq: sq = not sq
            elif ch == '"' and not sq: dq = not dq
            elif ch == '#' and not sq and not dq: return False
        return True
    all_hits = [l for l in open(path, encoding='utf-8') if anchor in l]
    src = [l for l in all_hits if _anchor_is_code(l)]
    if not src:
        where = " (it survives only in %d comment line(s))" % len(all_hits) if all_hits else ""
        print("REGEN-MISS %s: no live emitter for the anchor in %s%s" % (tag, path, where),
              file=sys.stderr); bad = 1; continue
    line = src[0]
    # the payload is the double-quoted argument that CONTAINS the anchor
    m = [q for q in re.findall(r'"((?:[^"\\]|\\.)*)"', line) if anchor.split('$')[0][:24] in q]
    if not m:
        print("REGEN-MISS %s: no quoted payload in %s" % (tag, path), file=sys.stderr); bad = 1; continue
    # include a `sev=` guard written immediately above the emitter, so the CONDITIONAL level is
    # exercised rather than expanded to empty - that mistake made this report a miss that was not one.
    idx = open(path, encoding='utf-8').read().splitlines().index(line.rstrip("\n"))
    guard = ""
    for prev in open(path, encoding='utf-8').read().splitlines()[max(0, idx-3):idx]:
        if re.match(r'\s*sev=', prev) or re.search(r'&&\s*sev=', prev): guard += prev.strip() + "; "
    out = subprocess.run(["bash", "-c", PRELUDE + guard + 'printf "%s" "' + m[0] + '"'],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        print("REGEN-MISS %s: literal would not expand (%s)" % (tag, out.stderr.strip()[:80]), file=sys.stderr); bad = 1; continue
    # THE CLASS COMES FROM THE EXPANDED LINE, NOT FROM THE SITE LIST. Every shell site here used to
    # be written MUST unconditionally, so demoting an emitter on purpose left the corpus demanding
    # that the gate still flag it - and the regenerator reported the deliberate change as a MISS.
    # The same rule the VERDICTGATE live site already uses: a line that DECLARES a level must be
    # surfaced (MUST), one that does not must not be (BENIGN). Searched anywhere in the line, not at
    # position zero: these payloads are indented, and LOGVOLBINDWARN carries its level mid-line
    # ("win11-up: [WARN] log-volume bind failed"), so a startswith() test would misfile it.
    _lvl = re.search(r'\[(?:ERROR|WARN|WARNING)\]|-[WE]\]', out.stdout)
    lines.append("%s\t%s\t%s" % ("MUST" if _lvl else "BENIGN", tag, out.stdout))

for tag, path, anchor, env in PYSITES:
    src = [l for l in open(path, encoding='utf-8') if anchor.split('[{step}]')[0][-28:] in l]
    if not src:
        print("REGEN-MISS %s: emitter gone from %s" % (tag, path), file=sys.stderr); bad = 1; continue
    expr = re.search(r'print\((f".*")\)\s*$', src[0].strip())
    if not expr:
        print("REGEN-MISS %s: no f-string in %s" % (tag, path), file=sys.stderr); bad = 1; continue
    lines.append("MUST\t%s\t%s" % (tag, eval(expr.group(1), {}, dict(env))))

for tag, path, anchor, env in PYSITES_OK:
    src = [l for l in open(path, encoding='utf-8') if anchor.split('[{step}]')[0][-28:] in l]
    expr = re.search(r'print\((f".*")\)\s*$', src[0].strip()) if src else None
    if not expr:
        print("REGEN-MISS %s: emitter gone from %s" % (tag, path), file=sys.stderr); bad = 1; continue
    lines.append("BENIGN\t%s\t%s" % (tag, eval(expr.group(1), {}, dict(env))))

# the harness success path too: the same summary line with nothing failed must stay unlabelled
out = subprocess.run(["bash","-c", PRELUDE + 'PASS=5; FAIL=0; sev=""; [ "${FAIL:-0}" -gt 0 ] && sev="[ERROR] "; '
                      'printf "%s" "${sev}summary: $PASS passed, $FAIL failed; evidence in $OUT"'],
                     capture_output=True, text=True)
lines.append("BENIGN\tCELLPASSSUMMARY\t%s" % out.stdout)

# LIVE SITES: the library is actually EXECUTED on a ledger and its real output captured. Stronger
# than expanding a literal, because it exercises the classifier that decides the severity.
import os, tempfile
def live(ledger_rows):
    fd, lf = tempfile.mkstemp(); os.write(fd, ledger_rows.encode()); os.close(fd)
    r = subprocess.run(["bash","-c","source mgmt/harness/verdict-lib.sh; verdict_aggregate '%s'" % lf],
                       capture_output=True, text=True)
    os.unlink(lf)
    return [l for l in r.stdout.splitlines() if l.strip()]
for l in live("cell-a|PASS all good\ncell-b|FAIL the product misbehaved\ncell-c|INSTRUMENT the rig broke\n"):
    lines.append(("MUST\tVERDICTGATE\t%s" if l.startswith(("[ERROR]","[WARN]")) else "BENIGN\tVERDICTGATE\t%s") % l)
# the CLEAN path of the same library must stay unlabelled, or the gate would fire on every green run
for l in live("cell-a|PASS all good\ncell-b|PASS also good\n"):
    lines.append("BENIGN\tVERDICTCLEAN\t%s" % l)

# matrix.sh's campaign summary: the two source lines are READ OUT of the file and executed for a
# failing, an ungraded-only and a clean campaign, so all three branches of one emitter are measured.
mx = open("mgmt/harness/matrix.sh", encoding="utf-8").read().splitlines()
gl = [l for l in mx if l.strip().startswith("_mx_sev=\"\";")]
sl = [l for l in mx if 'say "${_mx_sev}classes:' in l]
if gl and sl:
    body = gl[0].strip() + "; " + sl[0].strip().replace('say "', 'printf "%s\\n" "', 1)
    for F, I, verdict, tag in ((3, 1, "MUST", "MATRIXFAIL"), (1, 1, "MUST", "MATRIXUNGRADED"), (0, 0, "BENIGN", "MATRIXCLEAN")):
        r = subprocess.run(["bash", "-c", "FAIL=%d; INVALID=%d; %s" % (F, I, body)], capture_output=True, text=True)
        if r.stdout.strip(): lines.append("%s\t%s\t%s" % (verdict, tag, r.stdout.rstrip("\n")))
else:
    print("REGEN-MISS MATRIX: the campaign summary emitter moved", file=sys.stderr); bad = 1

# THE TWO no() VERDICT EMITTERS. Every failing check in a campaign and in a cell is reported through
# these, so they carry more of the coverage than any other line. The function DEFINITION is read out
# of the file and EXECUTED against a stub printer, so what lands in the corpus is what the real
# function prints - including the FAIL/INVALID split, whose two branches are both exercised.
for path, printer, calls in (
    ("mgmt/harness/matrix.sh", "say",
     [("MUST", "MATRIXCHECKFAIL", "the product wrote the wrong pixel"),
      ("MUST", "MATRIXCHECKINVALID", "INVALID-PRECONDITION the cell never ran")]),
    ("mgmt/harness/quick-upgrade.sh", "log",
     [("MUST", "CELLCHECKFAIL", "the upgrade did not keep the sealed version")]),
):
    fn = [l for l in open(path, encoding="utf-8").read().splitlines() if l.startswith("no(){")]
    if not fn:
        print("REGEN-MISS %s: no() moved" % path, file=sys.stderr); bad = 1; continue
    for verdict, tag, msg in calls:
        r = subprocess.run(["bash", "-c", "%s(){ echo \"$*\"; }; FAIL=0; INVALID=0; %s; no '%s'"
                            % (printer, fn[0], msg)], capture_output=True, text=True)
        if r.stdout.strip(): lines.append("%s\t%s\t%s" % (verdict, tag, r.stdout.rstrip("\n")))
        else: print("REGEN-MISS %s: no() produced nothing (%s)" % (tag, r.stderr.strip()[:70]), file=sys.stderr); bad = 1

BEG = "# >>> GENERATED by tools/regen-error-corpus.sh - do not edit by hand"
END = "# <<< GENERATED"
block = BEG + "\n" + "\n".join(lines) + "\n" + END + "\n"
if bad and "--write" in sys.argv:
    print("REFUSING to write: a site did not regenerate, and a partial corpus is a weaker gate", file=sys.stderr)
    sys.exit(2)
if "--write" in sys.argv:
    cur = open(CORPUS, encoding="utf-8").read()
    if BEG in cur and END in cur:
        cur = cur[:cur.index(BEG)] + block + cur[cur.index(END) + len(END) + 1:]
    else:
        cur = cur.rstrip("\n") + "\n\n" + block
    open(CORPUS, "w", encoding="utf-8").write(cur)
    print("wrote %d generated line(s) into %s" % (len(lines), CORPUS), file=sys.stderr)
else:
    sys.stdout.write(block)
sys.exit(bad)
PY
