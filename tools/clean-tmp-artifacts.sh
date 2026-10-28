#!/bin/bash
# Reclaims disk under /home/user/tmp (run-offline-suites.sh's TMPDIR) by removing ONLY aged
# fixtures whose on-disk name traces to a literal mktemp/mkdtemp prefix in a committed test's own
# source line - never a bare unknown name, a rel43x / qwt-improved-setup tree, a live attempt-id
# memo, or anything a live process still has open. Dry run by default; tools/clean-tmp-artifacts.sh
# [--apply] [--min-age-days=N].
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DEFAULT="/home/user/tmp"

APPLY=0
MIN_AGE_DAYS="${CLEAN_TMP_MIN_AGE_DAYS:-1}"
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --min-age-days=*) MIN_AGE_DAYS="${a#*=}" ;;
    -h|--help)
      echo "usage: $0 [--apply] [--min-age-days=N]  (dry run unless --apply is given)"
      exit 0 ;;
    *) echo "REFUSE: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

# RULE 7 (Jev): a bad TMPDIR must not aim this at a real tree - resolve what the caller's TMPDIR
# actually points at and refuse unless it IS /home/user/tmp, byte for byte.
TARGET_IN="${TMPDIR:-$TARGET_DEFAULT}"
TARGET="$(realpath -m -- "$TARGET_IN" 2>/dev/null)" || { echo "REFUSE: cannot resolve TMPDIR='$TARGET_IN'" >&2; exit 2; }
EXPECT="$(realpath -m -- "$TARGET_DEFAULT")"
if [ "$TARGET" != "$EXPECT" ]; then
  echo "REFUSE: TMPDIR resolves to '$TARGET' - this sweeper only ever touches '$EXPECT'" >&2
  exit 2
fi
[ -d "$TARGET" ] || { echo "REFUSE: '$TARGET' does not exist"; exit 2; }

# Our own bookkeeping must live OUTSIDE the tree we are about to judge and clean - a scratch file
# written INTO $TARGET would be a tree we just measured ourselves into.
SELFTMP="$(mktemp -d /tmp/clean-tmp-artifacts.XXXXXX)" || { echo "REFUSE: cannot create scratch dir under /tmp" >&2; exit 2; }
trap 'rm -rf "$SELFTMP"' EXIT

# ---------------------------------------------------------------------------------------------
# RULE 1 (Jev 0.82): refuse to run at all while an offline suite run looks live. Read /proc
# directly - this project bans pkill outright and "pgrep -f" cannot answer "is it alive" (it only
# ever answers "did something match", and the matcher carries the text it searches for). One walk
# of /proc also builds the busy-path list RULE 5 needs later, so it is done once, here.
BUSY="$SELFTMP/busy-paths"
: > "$BUSY"
offline_running=0
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
  case "$cmd" in *run-offline-suites.sh*) offline_running=1 ;; esac
  cw="$(readlink -- "$p/cwd" 2>/dev/null)" && [ -n "$cw" ] && printf '%s\n' "$cw" >> "$BUSY"
  for fd in "$p"/fd/*; do
    [ -e "$fd" ] || continue
    tgt="$(readlink -- "$fd" 2>/dev/null)" && [ -n "$tgt" ] && printf '%s\n' "$tgt" >> "$BUSY"
  done
done

busy_under_target=0
while IFS= read -r b; do
  case "$b" in "$TARGET"|"$TARGET"/*) busy_under_target=1; break ;; esac
done < "$BUSY"
if [ "$offline_running" = 1 ] || [ "$busy_under_target" = 1 ]; then
  echo "REFUSE: an offline suite run looks live (run-offline-suites.sh in /proc, and/or a process holds a cwd/fd under $TARGET) - not touching fixtures while a run owns them" >&2
  exit 3
fi

# ---------------------------------------------------------------------------------------------
# ATTRIBUTION TABLE, derived live from the source tree instead of frozen into this file - a
# hand-copied list rots the moment a suite's prefix changes, same failure shape as every other
# "census scoped to a pattern" this project has been burned by. Each line found here IS the command
# output that attributes the shape; nothing below is asserted without it.
ATTR="$SELFTMP/attributed.tsv"
: > "$ATTR"

# bash: mktemp templates anchored at $TMPDIR, prefix is everything before the literal X-run (mktemp
# replaces each X with one random alnum char; this project's own templates always use >=6 of them).
while IFS=: read -r file line prefix; do
  [ -n "$prefix" ] || continue
  printf '%s\t%s:%s\n' "$prefix" "$file" "$line" >> "$ATTR"
done < <(grep -rnoP 'mktemp(\s+-d)?\s+"\$\{?TMPDIR(:-/tmp)?\}?/\K[A-Za-z0-9._-]+?(?=X{6,}(\.[A-Za-z0-9]+)?")' \
  "$ROOT/tools" "$ROOT/mgmt" --include=*.sh 2>/dev/null)

# python: tempfile.mkdtemp(prefix="...") - same idea, mkdtemp appends its own random suffix.
while IFS=: read -r file line prefix; do
  [ -n "$prefix" ] || continue
  printf '%s\t%s:%s\n' "$prefix" "$file" "$line" >> "$ATTR"
done < <(grep -rnoP "mkdtemp\(prefix=[\"']\K[A-Za-z0-9_.-]+(?=[\"'])" \
  "$ROOT/tools" "$ROOT/mgmt" --include=*.py 2>/dev/null)

# powershell: 'prefix-' + [Guid]::NewGuid(...).Substring(...) feeding Join-Path(GetTempPath()).
while IFS=: read -r file line prefix; do
  [ -n "$prefix" ] || continue
  printf '%s\t%s:%s\n' "$prefix" "$file" "$line" >> "$ATTR"
done < <(grep -rnoP "'\K[A-Za-z0-9_-]+-(?='\s*\+\s*\[?[Gg]uid)" \
  "$ROOT/tools" "$ROOT/mgmt" --include=*.ps1 2>/dev/null)

if [ ! -s "$ATTR" ]; then
  echo "REFUSE: attribution scan found zero producers - that means the scan broke, not that nothing is attributable" >&2
  exit 2
fi

# Longest prefix first, so e.g. "relay-close-selftest-" is tried (and credited) before the shorter
# "relay-" another test in the same file also uses - PCRE alternation takes the first alternative
# that matches, not the longest, so ORDER is what makes this correct.
sort -u "$ATTR" | awk -F'\t' '{print length($1)"\t"$0}' | sort -t$'\t' -k1,1rn | cut -f2- > "$SELFTMP/attr-sorted.tsv"

# Build one combined anchored alternation. '.' is the only regex metachar any of these prefixes
# contain (used as a separator instead of '-' by a few suites) - escape it so it means a literal dot.
awk -F'\t' '{gsub(/\./,"\\.",$1); print $1}' "$SELFTMP/attr-sorted.tsv" | paste -sd'|' - > "$SELFTMP/alt.txt"
ALT="$(cat "$SELFTMP/alt.txt")"

shape_producer() {
  # shape_producer <prefix> - the first (most specific) producer recorded for this exact prefix.
  awk -F'\t' -v p="$1" '$1==p{print $2; exit}' "$SELFTMP/attr-sorted.tsv"
}

# ---------------------------------------------------------------------------------------------
# CANDIDATES: every top-level entry in $TARGET older than the threshold. -mtime +N is find's own
# "more than roughly (N+1)*24h old" - approximate by design, the point is a floor, not a stopwatch.
mapfile -t CAND < <(find "$TARGET" -mindepth 1 -maxdepth 1 -mtime "+$MIN_AGE_DAYS" -printf '%f\n' 2>/dev/null)

declare -A SHAPE_COUNT SHAPE_BYTES SHAPE_PRODUCER
TOTAL_COUNT=0
TOTAL_BYTES=0
declare -a TO_REMOVE=()

# Pass 1 (bash only, no subprocess per entry): peel off the never-touch names and the pid-keyed
# attempt memos, and collect everything else into ONE file for a single batched regex pass below -
# one process compiling the alternation once beats one process per candidate by two orders of
# magnitude on a tree this size (measured: ~8000 candidates, 18ms/grep-call ~= 2.5 minutes just for
# that loop; batched, the whole match pass is sub-second).
PLAIN_NAMES="$SELFTMP/plain-names"
: > "$PLAIN_NAMES"
declare -A ATTEMPT_SHAPE=()   # name -> 1, for the pid-keyed special case
for name in "${CAND[@]}"; do
  case "$name" in
    rel431|rel432) continue ;;
    *qwt-improved-setup*) continue ;;
  esac
  if [[ "$name" =~ ^qwt-attempt-([0-9]+)\.id$ ]]; then
    pid="${BASH_REMATCH[1]}"
    [ -e "/proc/$pid" ] && continue    # RULE 4: a live pid's memo is refused regardless of age
    ATTEMPT_SHAPE["$name"]=1
    continue
  fi
  printf '%s\n' "$name" >> "$PLAIN_NAMES"
done

# Pass 2: ONE grep over the whole candidate list. Output is "lineno:matched-prefix"; lineno maps
# straight back to PLAIN_NAMES because grep -n numbers input lines, not output matches.
declare -A LINE_MATCH=()
if [ -s "$PLAIN_NAMES" ]; then
  while IFS=: read -r lineno matched; do
    LINE_MATCH["$lineno"]="$matched"
  done < <(grep -noP "^(?:$ALT)" "$PLAIN_NAMES" 2>/dev/null)
fi

classify_and_record() {
  # classify_and_record <name> <shape> <producer> - RULE 3's recursive qwt-improved-setup guard,
  # RULE 5's busy check, the du -sb, and the bookkeeping: identical for both sources (attempt
  # memos and attributed-shape matches), so it is written once.
  local name="$1" shape="$2" producer="$3" path="$TARGET/$name" bytes held b
  if [ -d "$path" ] && find "$path" -iname '*qwt-improved-setup*' -print -quit 2>/dev/null | grep -q .; then
    return
  fi
  held=0
  while IFS= read -r b; do
    case "$b" in "$path"|"$path"/*) held=1; break ;; esac
  done < "$BUSY"
  [ "$held" = 1 ] && return

  bytes="$(du -sb -- "$path" 2>/dev/null | cut -f1)"
  bytes="${bytes:-0}"
  TO_REMOVE+=("$path")
  SHAPE_COUNT["$shape"]=$(( ${SHAPE_COUNT["$shape"]:-0} + 1 ))
  SHAPE_BYTES["$shape"]=$(( ${SHAPE_BYTES["$shape"]:-0} + bytes ))
  SHAPE_PRODUCER["$shape"]="$producer"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  TOTAL_BYTES=$(( TOTAL_BYTES + bytes ))
}

for name in "${!ATTEMPT_SHAPE[@]}"; do
  classify_and_record "$name" "qwt-attempt-<pid>.id (dead pid)" "mgmt/harness/primitives.sh:attempt_id (pid-keyed memo)"
done

lineno=0
while IFS= read -r name; do
  lineno=$(( lineno + 1 ))
  matched="${LINE_MATCH[$lineno]:-}"
  [ -n "$matched" ] || continue   # RULE 2: never a bare unknown name
  classify_and_record "$name" "${matched}*" "$(shape_producer "$matched")"
done < "$PLAIN_NAMES"

mode="DRY RUN"; [ "$APPLY" = 1 ] && mode="APPLY"
echo "=== clean-tmp-artifacts: $mode  target=$TARGET  min-age-days=$MIN_AGE_DAYS ==="
if [ "$TOTAL_COUNT" -eq 0 ]; then
  echo "nothing eligible: zero entries matched an attributed shape, older than threshold, unheld, and not an excluded tree"
else
  for shape in "${!SHAPE_COUNT[@]}"; do
    printf '%-40s count=%-6s bytes=%-12s producer=%s\n' "$shape" "${SHAPE_COUNT[$shape]}" "${SHAPE_BYTES[$shape]}" "${SHAPE_PRODUCER[$shape]}"
  done | sort
fi
echo "--- total: $TOTAL_COUNT entries, $TOTAL_BYTES bytes $( [ "$APPLY" = 1 ] && echo reclaimed || echo would-reclaim ) ---"

if [ "$APPLY" = 1 ] && [ "$TOTAL_COUNT" -gt 0 ]; then
  for path in "${TO_REMOVE[@]}"; do
    rm -rf -- "$path"
  done
  echo "removed $TOTAL_COUNT entries."
fi
