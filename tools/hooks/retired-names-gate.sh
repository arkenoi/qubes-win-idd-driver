#!/bin/bash
# retired-names-gate.sh - Claude Code PreToolUse hook (matcher: Edit|Write|MultiEdit).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE: a retired or parked line (tools/hooks/retired-names.txt)
# may not be written into the record - CLAUDE.md, findings/, FINDINGS.md, docs/, the memory dir -
# unless the same edit says RETIRED (recording that it is retired) or REOPENED-BY-OWNER (the owner
# reopened it in writing). Owner, 2026-09-17, after the xenbus patch - parked 8376f69, reverted
# f7c16ce - was re-derived as a "finding" for the third time: "You marked it dead like 2 times
# already", "CLAUDE.md is utterly useless and is never actually followed". A memory note is
# background context; this is the structural rule.
#
# stdin: the hook JSON ({"tool_name": ..., "tool_input": {...}}). Exit 0 = allow, 2 = block.
# Self-test: tools/tests/retired-names-gate-selftest.sh. RETIRED_GATE_DEFECT=1 re-introduces the
# original state (nothing enforces) and the self-test must then FAIL.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${RETIRED_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:retired-gate
input=$(cat)
python3 - "$input" <<'PY'
import json, os, re, sys
try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)  # not our JSON - never block on a parse problem of our own
ti = hook.get('tool_input') or {}
path = str(ti.get('file_path') or ti.get('path') or '')
if not path:
    sys.exit(0)
# .claude/skills/ IS part of the record: on 2026-10-07 a claim CLAUDE.md had retracted twelve days
# earlier was still sitting, verbatim, in .claude/skills/rig-capabilities/SKILL.md - the very file
# CLAUDE.md names as the antidote to that class of mistake - and in mgmt/CLAUDE.md and
# docs/ACCEPTANCE-PROTOCOL.md. A correction applied to one copy is not a correction.
guarded = re.compile(r'(^|/)(CLAUDE\.md|CLAUDE\.local\.md|FINDINGS\.md)$|(^|/)(findings|docs)/|/memory/'
                     r'|/\.claude/skills/')
if not guarded.search(path):
    sys.exit(0)
parts = []
for k in ('content', 'new_string'):
    if ti.get(k): parts.append(str(ti[k]))
for e in ti.get('edits') or []:
    if isinstance(e, dict) and e.get('new_string'): parts.append(str(e['new_string']))
text = '\n'.join(parts)
if not text:
    sys.exit(0)
if re.search(r'\bRETIRED\b|\bREOPENED-BY-OWNER\b|\bRETRACTED\b', text):
    sys.exit(0)
names = []
try:
    for line in open('tools/hooks/retired-names.txt', encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#'):
            names.append(line)
except Exception:
    sys.exit(0)
for pat in names:
    m = re.search(pat, text, re.I)
    if m:
        sys.stderr.write(
            f"BLOCKED by tools/hooks/retired-names-gate.sh: this edit to {path} names a RETIRED/PARKED line "
            f"(pattern {pat!r}, matched {m.group(0)!r}) and carries neither RETIRED nor REOPENED-BY-OWNER. "
            f"Read CLAUDE.md 'RETIRED AND PARKED LINES' and `git log --oneline -S<name> -- .` first. If you are "
            f"recording that it is retired, say RETIRED in the edit (or RETRACTED for a withdrawn claim); if the owner reopened it, quote "
            f"them and say REOPENED-BY-OWNER. Otherwise this is the dead end being re-derived - stop.\n")
        sys.exit(2)
sys.exit(0)
PY
