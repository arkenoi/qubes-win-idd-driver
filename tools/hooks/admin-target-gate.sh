#!/bin/bash
# admin-target-gate.sh - Claude Code PreToolUse hook (matcher: Bash).
#
# THE RULE: never issue an Admin API call that has NO POLICY RULE AND NEVER WILL. Such a call does
# not merely fail here - it writes a line into the OWNER'S dom0 log:
#
#   qrexec: admin.vm.tag.List: win-idd-mgmt -> dom0: denied: no matching rule found
#   qrexec: admin.vm.tag.List: win-idd-mgmt -> win-idd-mgmt: denied: no matching rule found
#
# Owner, 2026-10-07, pasting fourteen of those from his journal: "why you keep that strange policy
# fuckery for months, requesting actions that were never available" / "adminVM capabilities you keep
# silently invoking to wrong targets, every fucking day" / "this! you do it very day!"
#
# WHAT ACTUALLY PRODUCES THEM, measured against his timestamps rather than guessed:
#   * `qvm-ls --raw-data --fields NAME,TAGS` - the TAGS field fans admin.vm.tag.List out over EVERY
#     qube, so each run denies once for dom0 and once for win-idd-mgmt. His 18:23 and 18:24 pairs
#     are two runs of exactly that, by me.
#   * `qvm-tags dom0` / `qvm-tags win-idd-mgmt` - asking directly. His 18:28 cluster, also me.
# Of the 31 qubes on this host, exactly two are not ours: dom0 and win-idd-mgmt. Everything else is
# a testbed subject. NO script in tools/, mgmt/ or .claude/ requests the TAGS field - every one of
# these lines came from a human-typed exploratory command, which is why months of harness review
# never found it and why it repeats daily.
#
# THIS GATE MAKES NO ADMIN CALL OF ITS OWN. That is the whole point: the first version of it checked
# each target with `qvm-tags <target>`, which would have logged a fresh denial for every untagged
# target it examined - industrialising the noise it exists to stop. It is pure text analysis.
#
# What it refuses:
#   1. an Admin verb naming dom0 or win-idd-mgmt as its QUBE ARGUMENT (qvm-ls itself targets dom0
#      and is permitted - it takes no qube argument, so it is untouched);
#   2. a --fields list containing TAGS, because that one word is the fan-out.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block.
# Self-test: tools/tests/admin-target-gate-selftest.sh. ADMIN_TARGET_GATE_DEFECT=1 restores the
# original state (nothing enforces) and the self-test must then FAIL.
set -u
if [ "${ADMIN_TARGET_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:admin-target-gate
input=$(cat)
python3 - "$input" <<'PY'
import json, re, shlex, sys

try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)                      # never block on a parse problem of our own
cmd = str((hook.get('tool_input') or {}).get('command') or '')
if not cmd:
    sys.exit(0)

# Not ours, and no rule exists for them. Naming one of these as a qube argument is a denial.
NOT_OURS = {'dom0', 'win-idd-mgmt'}
# Verbs that take a QUBE as a positional argument. qvm-ls and qvm-pool are absent on purpose: they
# target dom0 as a service destination, which IS permitted, and take no qube argument.
VERBS = (
    'qvm-tags', 'qvm-prefs', 'qvm-features', 'qvm-remove', 'qvm-kill', 'qvm-shutdown',
    'qvm-start', 'qvm-run', 'qvm-volume', 'qvm-device', 'qvm-firewall', 'qvm-clone',
    'qvm-pause', 'qvm-unpause', 'qvm-check', 'qvm-appmenus', 'qvm-sync-appmenus',
    'qvm-copy-to-vm', 'qvm-move-to-vm', 'qvm-backup-restore', 'qvm-service',
)
SUBWORDS = {
    'block', 'usb', 'pci', 'mic', 'attach', 'detach', 'assign', 'unassign', 'list', 'info',
    'add', 'del', 'reset', 'set', 'get', 'policy', 'resize', 'import', 'revert', 'extend',
    'clone', 'config', 'on', 'off', 'true', 'false',
}
problems = []

# ---- 1. a --fields list that asks for TAGS ------------------------------------------------------
for m in re.finditer(r'--fields[= ]+([A-Za-z0-9_,]+)', cmd):
    if 'TAGS' in m.group(1).upper().split(','):
        problems.append(
            "`--fields %s` includes TAGS, which fans admin.vm.tag.List out over EVERY qube - one "
            "'denied: no matching rule found' in the owner's dom0 log per qube that is not ours, "
            "every run. Ask for the fields you need (NAME, STATE, CLASS, NETVM ...) and never TAGS."
            % m.group(1))

# ---- 2. an Admin verb anywhere, and a name that is not ours anywhere ----------------------------
# WHOLE-COMMAND, not per-segment, and deliberately conservative. A per-segment version let the exact
# command that produced the owner's 18:28 cluster straight through:
#   for v in win11r-gz win-idd-mgmt dom0; do qvm-tags "$v"; done
# splits into a `for` with the names and no verb, and a body with the verb and no names. Loops,
# xargs and command substitution all separate the two, so the only safe reading is the whole text.
# Over-refusing costs a rephrase; under-refusing costs a line in the owner's journal.
verbs = [v for v in VERBS if re.search(r'(^|[\s;&|(`$])' + re.escape(v) + r'(\s|$)', cmd)]
if verbs:
    try:
        words = shlex.split(cmd, comments=True)
    except ValueError:
        words = re.split(r'[\s;&|()`"\']+', cmd)
    for w in words:
        w = w.strip('"\'')
        if w in NOT_OURS:
            problems.append(
                "names `%s` as the qube argument of %s. There is no policy rule for it and there "
                "will not be one: the call is DENIED and logged in the owner's dom0 journal. Of the "
                "31 qubes here, dom0 and win-idd-mgmt are the two that are not ours." % (w, verbs[0]))
            break

if problems:
    sys.stderr.write("BLOCKED by tools/hooks/admin-target-gate.sh: this command would be DENIED by "
                     "dom0 policy and would log that denial in the owner's journal.\n")
    for p in problems:
        sys.stderr.write("  - %s\n" % p)
    sys.stderr.write(
        "A denied Admin call is not a free probe. It costs nothing here and leaves a line there, and "
        "the owner reads that log. Fourteen of them on 2026-10-07 were all mine, from exploratory\n"
        "commands typed by hand. If you need to know what is ours: `qvm-ls --raw-data --fields NAME` "
        "is permitted, and every name there except dom0 and win-idd-mgmt is a testbed subject.\n")
    sys.exit(2)
sys.exit(0)
PY
