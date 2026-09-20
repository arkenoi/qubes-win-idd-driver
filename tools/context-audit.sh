#!/bin/bash
# context-audit.sh - what Claude Code loads into EVERY session of this project, what loads on
# demand, what is MECHANICALLY enforced, and which memory descriptions claim a result.
#
# Owner, 2026-09-17: "how do i audit directory contents for proper context handling to make sure
# important instructions are loaded in appropriate place and it does not get poisoned by failed
# 'experiment' data?" The three rules this measures against:
#   1. anything ALWAYS-ON (CLAUDE.md, the MEMORY.md index, skill descriptions) must be short,
#      current and imperative - it is in the system prompt before the first user message;
#   2. anything that records a RESULT (fixed / achieved / done / solved) must carry a dated
#      measurement in the same place, or it is a claim, and claims are how xenbus got re-derived;
#   3. anything that must HOLD must be a hook in .claude/settings.json - prose is walked past.
#
# Usage: tools/context-audit.sh [--strict]
#   --strict exits 1 when: always-on bytes exceed $ALWAYS_ON_MAX (default 24000), or a memory
#   of type project/goal whose description claims a result has no dated verified/measured/proven
#   line in its body, or a binding rule in CLAUDE.md (MUST/NEVER/ALWAYS in caps) names no hook.
# Self-test: CONTEXT_AUDIT_SELFTEST=1 runs the checks against a synthetic tree with three planted
# defects and must report all three (rc 1); if it reports none the audit is broken.
set -u
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")     # absolute, resolved BEFORE any cd
# RECURSION GUARD (2026-09-20). selftest() re-invokes $SELF; on 2026-09-18 the child inherited
# the exported CONTEXT_AUDIT_SELFTEST=1 and re-entered selftest(), forking without bound: 4818
# `git init`ed temp trees in the 1 GB tmpfs /tmp in 29 s, then the kernel OOM killer walked the
# user session and took this qube's X/gui-agent down with it. The child is now launched with
# `env -u CONTEXT_AUDIT_SELFTEST`; this depth counter is the backstop that makes the whole CLASS
# bounded even if some future caller re-exports it.
CONTEXT_AUDIT_DEPTH=$(( ${CONTEXT_AUDIT_DEPTH:-0} + 1 )); export CONTEXT_AUDIT_DEPTH
if [ "$CONTEXT_AUDIT_DEPTH" -gt 3 ]; then
  echo "context-audit: RECURSION DEPTH $CONTEXT_AUDIT_DEPTH - refusing to re-enter (see the guard note above)" >&2
  exit 2
fi
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2
MEM="${CLAUDE_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | sed 's#/#-#g')/memory}"
STRICT=0; [ "${1:-}" = "--strict" ] && STRICT=1
ALWAYS_ON_MAX="${ALWAYS_ON_MAX:-24000}"
fail=0

selftest(){
  local t; t=$(mktemp -d "${TMPDIR:-/tmp}/ctxaudit.XXXXXX") || exit 2
  trap 'rm -rf "$t"' EXIT INT TERM   # /tmp is RAM on this qube - never leak a tree here
  mkdir -p "$t/mem" "$t/.claude/skills/s1"
  ( cd "$t" && git init -q )   # so `git rev-parse --show-toplevel` lands in $t, not the real repo
  printf -- '---\nname: good\ndescription: a rule\nmetadata:\n  type: feedback\n---\nverified 2026-09-01: measured on win10-acc\n' > "$t/mem/good.md"
  printf -- '---\nname: bad\ndescription: bug FIXED and goal ACHIEVED\nmetadata:\n  type: project\n---\nno measurement here\n' > "$t/mem/bad.md"
  printf -- '---\nname: rule\ndescription: never edit a running script\nmetadata:\n  type: feedback\n---\na feedback rule, not a result\n' > "$t/mem/rule.md"
  printf -- '- [x](good.md)\n- [y](bad.md)\n- [z](rule.md)\n' > "$t/mem/MEMORY.md"
  printf -- '---\nname: s1\ndescription: d\n---\nbody\n' > "$t/.claude/skills/s1/SKILL.md"
  printf -- '# x\n- You MUST never do this (enforced by tools/hooks/x.sh)\n- You MUST always do that\n' > "$t/CLAUDE.md"
  printf -- '{"hooks":{}}\n' > "$t/.claude/settings.json"
  # CTXAUDIT_SELFTEST_DEFECT=1 re-introduces the 2026-09-18 defect (child inherits the knob) so
  # this check can be SEEN TO FAIL; the depth guard keeps that re-introduction bounded to 3 levels.
  local out rc
  if [ "${CTXAUDIT_SELFTEST_DEFECT:-}" = 1 ]; then
    out=$(cd "$t" && CLAUDE_MEMORY_DIR="$t/mem" ALWAYS_ON_MAX=10 bash "$SELF" --strict 2>&1); rc=$?
  else
    out=$(cd "$t" && env -u CONTEXT_AUDIT_SELFTEST CLAUDE_MEMORY_DIR="$t/mem" ALWAYS_ON_MAX=10 bash "$SELF" --strict 2>&1); rc=$?
  fi
  rm -rf "$t"
  local ok=1
  echo "$out" | grep -q 'UNMEASURED bad.md'          || { echo "SELFTEST FAIL: the unmeasured result-claim memory was not flagged"; ok=0; }
  echo "$out" | grep -q 'rule.md'                     && { echo "SELFTEST FAIL: a feedback rule ('running script') was wrongly flagged as a result claim"; ok=0; }
  echo "$out" | grep -q 'UNENFORCED.*always do that'  || { echo "SELFTEST FAIL: the hook-less binding rule was not flagged"; ok=0; }
  echo "$out" | grep -q 'OVER BUDGET'                 || { echo "SELFTEST FAIL: the always-on budget breach was not flagged"; ok=0; }
  [ "$rc" = 1 ]                                        || { echo "SELFTEST FAIL: --strict exited $rc on a tree with planted defects (want 1)"; ok=0; }
  [ "$ok" = 1 ] && { echo "SELFTEST PASS: planted defects flagged, feedback rule spared, rc=1"; exit 0; } || exit 1
}
[ "${CONTEXT_AUDIT_SELFTEST:-}" = "1" ] && selftest

echo "=== ALWAYS-ON: in the system prompt of EVERY session ==="
a=0
for f in CLAUDE.md CLAUDE.local.md "$HOME/.claude/CLAUDE.md" "$MEM/MEMORY.md"; do
  [ -f "$f" ] || continue
  b=$(wc -c < "$f"); a=$((a+b)); printf '  %-58s %6s lines %7s bytes\n' "$(echo "$f" | sed "s#$HOME#~#")" "$(wc -l < "$f")" "$b"
done
sd=0; n=0
for s in .claude/skills/*/SKILL.md; do [ -f "$s" ] || continue; n=$((n+1)); sd=$((sd+$(awk '/^description:/{print length($0); exit}' "$s"))); done
printf '  %-58s %6s items %7s bytes\n' "skill descriptions (always listed)" "$n" "$sd"; a=$((a+sd))
if [ "$a" -gt "$ALWAYS_ON_MAX" ]; then printf '  always-on total %s bytes: OVER BUDGET (max %s)\n' "$a" "$ALWAYS_ON_MAX"; fail=1; else printf '  always-on total %s bytes (budget %s) OK\n' "$a" "$ALWAYS_ON_MAX"; fi

echo "=== ON DEMAND (never in the prompt until read) ==="
[ -d "$MEM" ] && printf '  memory bodies: %s files, %s bytes\n' "$(ls "$MEM"/*.md 2>/dev/null | grep -vc MEMORY.md)" "$(cat "$MEM"/*.md 2>/dev/null | wc -c)"
printf '  skill bodies: %s bytes\n' "$(cat .claude/skills/*/SKILL.md 2>/dev/null | wc -c)"
printf '  findings/ + FINDINGS.md + docs/: %s bytes\n' "$(cat findings/*.md FINDINGS.md docs/*.md 2>/dev/null | wc -c)"

echo "=== MECHANICAL ENFORCEMENT (.claude/settings.json) ==="
python3 - <<'PY'
import json
try: s = json.load(open('.claude/settings.json'))
except Exception as e: print(f"  settings.json unreadable: {e}"); raise SystemExit
n = 0
for k, v in (s.get('hooks') or {}).items():
    for h in v:
        for c in h.get('hooks', []):
            n += 1; print(f"  {k}: matcher={h.get('matcher','*')!r} -> {c.get('command','')[:100]}")
p = s.get('permissions', {}) or {}
print(f"  hooks: {n}   permission rules: allow={len(p.get('allow',[]))} deny={len(p.get('deny',[]))}")
PY

echo "=== RESULT CLAIMS in project/goal memory descriptions without a dated measurement ==="
if [ -d "$MEM" ]; then
  for f in "$MEM"/*.md; do
    [ "$(basename "$f")" = MEMORY.md ] && continue
    grep -qiE '^description:.*(fixed|achieved|solved|complete|done|proven)' "$f" || continue
    # feedback/user memories are RULES, not results - do not hold them to a measurement
    grep -qiE '^\s*type:\s*(feedback|user)\b' "$f" && continue
    if grep -qiE '(verified|measured|proven)[^0-9]{0,40}20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$f"; then
      printf '  ok         %s\n' "$(basename "$f")"
    else
      printf '  UNMEASURED %s (modified %s)\n' "$(basename "$f")" "$(grep -m1 'modified:' "$f" | awk '{print substr($2,1,10)}')"; fail=1
    fi
  done
fi

echo "=== BINDING RULES in CLAUDE.md (MUST/NEVER/ALWAYS in caps) that name no hook or script ==="
u=0
while IFS= read -r line; do
  echo "$line" | grep -qE 'hooks?/|\.sh\b|\.py\b|githooks|settings\.json' && continue
  printf '  UNENFORCED %s\n' "$(echo "$line" | cut -c1-140)"; u=1
done < <(grep -nE '\b(MUST|NEVER|ALWAYS)\b' CLAUDE.md 2>/dev/null)
[ "$u" = 1 ] && fail=1

[ "$STRICT" = 1 ] && exit "$fail"
exit 0
