#!/bin/bash
# golden-boot-gate.sh - Claude Code PreToolUse hook (matcher: Bash|Workflow|Agent).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE: a sealed golden is CLONED, never STARTED. It has been
# written in mgmt/golden.sh since 2026-08-30 ("a golden is SEALED, and after sealing it is CLONED,
# never started, never logged into, never 'just checked'") and printed after every seal, and on
# 2026-10-11 all four pristine bases were started anyway.
#
# WHY A BOOT IS THE LOSS. Qubes cuts a volume revision on every clean shutdown and keeps only
# `revisions_to_keep` of them - 2 here, because the pool sits at ~90% and cannot afford more. So
# TWO shutdowns age the originally sealed revision out, and at that point the golden's sealed state
# is gone for good. That is not theory: on 2026-10-11 win10-base lost both revisions its 2026-08-30
# seal recorded and had to be rebuilt from vendor media, while win11-base, win11r-base and
# win11de-base were caught one shutdown short and were restored by `qvm-volume revert` on
# 2026-10-12. The recovery window is two shutdowns wide and nothing used to warn about it.
#
# NARROW BY DESIGN, so it cannot be argued around and cannot block the sanctioned paths:
#   * only verbs that actually START or OVERWRITE a guest trip it - qvm-start, qvm-run (it
#     auto-starts), qtest start/run/push/pushrun, and reprovision-usb.sh (which rebuilds a guest
#     in place). Everything that READS a golden passes: golden.sh verify/seal/list, qvm-volume
#     info, qvm-ls, qvm-prefs, grep.
#   * CLONING FROM a golden is the whole point of having one, so the harnesses that clone -
#     quick-upgrade.sh, clone-guest.sh, prime-selftest.sh, matrix.sh - are NOT start verbs here
#     even though the golden's name is their first argument. They start the CLONE, not the golden.
#   * the name must be a sealed golden: mgmt/goldens/<name>.json must exist. An unsealed qube is
#     not this gate's business.
#   * a deliberate rebuild is allowed and VISIBLE: GOLDEN_UNSEAL=<vm> permits that one vm. It has
#     to name the guest, so it cannot be left lying around as a blanket opt-out, and it shows up in
#     the transcript next to the command it authorised.
#
# SECOND RULE, SAME PARSER: a SPENT SPECIMEN is not started by hand either. When a cell fails and
# leaves its subject as it stands (matrix.sh's H3.5 path), mgmt/harness/specimen-lib.sh writes
# scratchpad/specimens/<vm>.spent, and a start verb aimed at that name is blocked. On 2026-10-14 I
# started win10-acc by hand to read its logs, minutes after the campaign had deliberately preserved
# it, with the owner watching: "starting WHAT THE FUCK to read the logs, we agreed to move the logs
# off to stick". The logs never needed the guest - logvol_pull reads the secondary log volume as an
# image file in THIS qube, with mtools, while the guest runs, wedges or sits Halted - and that boot
# could not have worked anyway, because the ISO cell had left a `--required` claim on a released
# loop device. Authorise one guest with SPECIMEN_BOOT=<vm> when a boot really is the only route.
# It lives in this file, not a second hook, because the start-verb parser below is the hard part
# and two copies of one parser drift apart - which cost a whole acceptance cell earlier that day.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block (message handed back to the model).
# Self-test: tools/tests/golden-guard-selftest.sh and tools/tests/specimen-boot-gate-selftest.sh.
# GOLDEN_BOOT_GATE_DEFECT=1 re-introduces the original state (nothing enforces) and both self-tests
# must then FAIL.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${GOLDEN_BOOT_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:golden-boot-gate
input=$(cat)
GOLDEN_UNSEAL="${GOLDEN_UNSEAL:-}" SPECIMEN_BOOT="${SPECIMEN_BOOT:-}" python3 - "$input" <<'PY'
import glob, json, os, re, shlex, sys

try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)            # not our JSON - never block on a parse problem of our own

ti = hook.get('tool_input') or {}
tool = hook.get('tool_name', '')
if tool == 'Bash':
    cmd = ti.get('command', '') or ''
elif tool in ('Workflow', 'Agent'):
    cmd = str(ti.get('prompt') or ti.get('description') or '')
else:
    sys.exit(0)
if not cmd.strip():
    sys.exit(0)

GOLDENS = {os.path.basename(p)[:-5] for p in glob.glob('mgmt/goldens/*.json')}
# A spent specimen: the harness wrote this down when it chose to leave a guest as it stands.
SPEC_DIR = os.environ.get('SPECIMEN_DIR') or 'scratchpad/specimens'
SPECIMENS = {os.path.basename(p)[:-len('.spent')] for p in glob.glob(f'{SPEC_DIR}/*.spent')}
if not GOLDENS and not SPECIMENS:
    sys.exit(0)            # nothing sealed and nothing preserved - nothing to protect

def strip_prose(c):
    """A commit message or a heredoc body that TALKS about starting a golden is prose, not a
    launch. Same shape as serial-rig-gate.sh's guard, and for the same reason: this gate's own
    fix commit describes the commands it forbids."""
    c = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\s*$", " ", c, flags=re.S | re.M)
    c = re.sub(r"(?:^|\s)(?:-m|--message)(?:=|\s+)('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")",
               " ", c, flags=re.S)
    return c

def nl_to_sep(c):
    """An UNQUOTED newline ends a command exactly as `;` does; shlex would otherwise merge line 2
    into line 1's segment and let it inherit line 1's harmless command word."""
    out, q, esc = [], None, False
    for ch in c:
        if esc:
            out.append(ch); esc = False; continue
        if ch == '\\' and q != "'":
            out.append(ch); esc = True; continue
        if q:
            if ch == q:
                q = None
            out.append(ch); continue
        if ch in ('"', "'"):
            q = ch; out.append(ch); continue
        out.append(' ; ' if ch in '\r\n' else ch)
    return ''.join(out)

SEP = re.compile(r'^[|&;()<>]+$')

def segments(c):
    """Quote-aware split. A bare regex split is quote-BLIND and would end a segment on a `|`
    inside a grep pattern. Unbalanced quotes fall back to the whole line, which is the STRICT
    direction: it may block, it cannot silently allow."""
    try:
        lex = shlex.shlex(nl_to_sep(c), posix=False, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ''
        segs, cur = [], []
        for t in lex:
            if SEP.match(t):
                segs.append(cur); cur = []
            else:
                cur.append(t)
        segs.append(cur)
        return segs
    except ValueError:
        return [c.split()]

KW_PREFIX = {'if', 'elif', 'while', 'until', 'do', 'then', 'else', '!', 'time', '{', '}',
             'nohup', 'exec', 'source', '.', 'command', 'builtin', 'sudo', 'env', 'timeout'}
KW_DATA = {'for', 'select', 'case', 'in', 'esac', 'fi', 'done', 'local', 'declare', 'export',
           'readonly', 'return', 'exit', 'break', 'continue', 'shift', 'set', 'unset', 'trap'}
HELPFLAG = ('--help', '-h', '--version')

# The verbs that START or OVERWRITE. qtest is handled separately because its target is a
# subcommand/env away. Harnesses that CLONE from a golden are deliberately absent - see the header.
START = {'qvm-start', 'qvm-run', 'reprovision-usb.sh'}
QTEST_START = {'start', 'run', 'push', 'pushrun', 'kill', 'shutdown'}

unseal = os.environ.get('GOLDEN_UNSEAL', '').strip()
sboot = os.environ.get('SPECIMEN_BOOT', '').strip()
hits = []
shits = []

for toks in segments(strip_prose(cmd)):
    if not toks:
        continue
    i = 0
    env_here = {}
    while i < len(toks) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[i]):
        k, _, v = toks[i].partition('=')
        env_here[k] = v.strip('\'"')
        i += 1                                  # step over leading env assignments
    while i < len(toks) and toks[i] in KW_PREFIX:
        i += 1
    if i >= len(toks) or toks[i] in KW_DATA:
        continue
    name = os.path.basename(toks[i].strip('\'"'))
    rest = [t.strip('\'"') for t in toks[i + 1:]]
    if any(f in rest for f in HELPFLAG):
        continue                                # asking a verb for its usage runs nothing

    # Per-segment GOLDEN_UNSEAL=... counts, so the authorisation sits on the command it authorises.
    permit = env_here.get('GOLDEN_UNSEAL', unseal).strip()
    spermit = env_here.get('SPECIMEN_BOOT', sboot).strip()

    # The names this segment would START, before we know what they are. ONE parse, then membership
    # is tested against both protected sets - a second copy of the parser is what drifts.
    names = []
    if name in START:
        names = rest
    elif name == 'qtest' or name.endswith('/qtest'):
        if any(a in QTEST_START for a in rest):
            cand = env_here.get('QTEST_VM', os.environ.get('QTEST_VM', ''))
            names = ([cand] if cand else []) + rest

    target = next((a for a in names if a in GOLDENS), None)
    starget = next((a for a in names if a in SPECIMENS), None)

    if target and target != permit:
        hits.append((target, name))
    if starget and starget != spermit:
        shits.append((starget, name))

if not hits and not shits:
    sys.exit(0)

if not hits:
    tgt, verb = shits[0]
    f = f'{SPEC_DIR}/{tgt}.spent'
    rec = {}
    try:
        for ln in open(f):
            k, _, v = ln.strip().partition('=')
            rec[k] = v
    except Exception:
        pass
    sys.stderr.write(f"""BLOCKED by golden-boot-gate.sh: `{verb}` would START the spent specimen {tgt}.
A failed cell kept it as evidence, so it is not a machine any more. Marked {rec.get('marked_utc','?')}.
  why:   {rec.get('why','?')}
  where: {rec.get('where','?')}
Its QWT logs do not need it running - the secondary log volume is an image FILE in this qube:
  . mgmt/harness/logvol-lib.sh
  logvol_pull  $(logvol_image {tgt}) <outdir>      # mtools; guest running, wedged or Halted
  logvol_salvage $(logvol_image {tgt}) <outdir>    # raw-image scan for a tail mcopy will not reach
  mgmt/harness/collect-failure.sh {tgt} <outdir>   # that pull plus the rest of the evidence
A start also tends to FAIL here: an ISO cell leaves a `--required` claim on a loop device that is
later released, and the domain then cannot be created at all.
If a boot really is the only route, authorise that one guest:  SPECIMEN_BOOT={tgt} <your command>
""")
    sys.exit(2)

tgt, verb = hits[0]
seal = f'mgmt/goldens/{tgt}.json'
sealed_utc = '?'
try:
    sealed_utc = json.load(open(seal)).get('sealed_utc', '?')
except Exception:
    pass

sys.stderr.write(f"""BLOCKED by golden-boot-gate.sh: `{verb}` would START the sealed golden {tgt}.
A golden is CLONED, never started. Sealed {sealed_utc} ({seal}).
Qubes cuts a revision on every clean shutdown and keeps {2}; two shutdowns age the sealed
revision out and the golden's sealed state is gone. win10-base was lost exactly this way on
2026-10-11 and had to be rebuilt from vendor media.
  Work on a CLONE instead:  mgmt/clone-guest.sh {tgt} <subject>
  Short cycle:              mgmt/harness/quick-upgrade.sh {tgt} <subject>
  Prove the primer channel: mgmt/prime-selftest.sh {tgt}      (clones, then boots the clone)
If you really mean to rebuild this golden, authorise that one guest explicitly:
  GOLDEN_UNSEAL={tgt} <your command>
""")
sys.exit(2)
PY
