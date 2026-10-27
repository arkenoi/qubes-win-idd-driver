#!/usr/bin/env bash
# "the log volume could not be read" must mean it could not be read.
# run: tools/tests/qrexec-gap-witness-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/mgmt/harness/quick-upgrade.sh"
pass=0; fail=0
say(){ printf '%s\n' "$*"; }
ck(){ if [ "$2" = 0 ]; then pass=$((pass+1)); say "ok   $1"; else fail=$((fail+1)); say "FAIL $1"; [ -n "${3:-}" ] && say "       -> $3"; fi; }
[ -f "$SRC" ] || { say "FAIL  $SRC missing - nothing ran"; exit 2; }

# the shipped predicate, verbatim
REGION=$(awk '/# ---- QREXECGAPWITNESS-BEGIN/{f=1;next}/# ---- QREXECGAPWITNESS-END/{f=0}f' "$SRC")
[ -n "$REGION" ] || { say "FAIL  could not extract QREXECGAPWITNESS from $SRC"; exit 2; }
printf '%s' "$REGION" | grep -q 'lastknown=' || { say "FAIL  the extracted region does not assign lastknown"; exit 2; }

# the OLD form, as the control. Not hand-written from memory: it is the shipped region reduced to
# the single-newest-file behaviour it used to have.
CONTROL='lastknown=$(find "$OUT/logvol-live/files" -type f -name "*.log" -printf "%T@ %p\n" 2>/dev/null \
            | sort -rn | head -1 | cut -d" " -f2- \
            | xargs -r -d "\n" sh -c "grep -a . \"\$0\" 2>/dev/null | tail -1" 2>/dev/null | cut -c1-110 | tr -d "[]")'

T="$(mktemp -d "${TMPDIR:-/tmp}/gapwit.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# mk <dir> then a series of <age-rank>:<content> entries, newest first (rank 0 = newest)
mk(){ local d="$1"; shift; local i=0 spec name body
  rm -rf "$d"; mkdir -p "$d/logvol-live/files/qwt-logs/vm"
  for spec in "$@"; do
    body=${spec#*:}; name="$d/logvol-live/files/qwt-logs/vm/log$i.log"
    if [ "$body" = EMPTY ]; then : > "$name"; else printf '%s\n' "$body" > "$name"; fi
    # newest first: rank 0 gets the LATEST mtime. Epoch stamps, because
    # `touch -d "<date> -60 seconds"` is not a format GNU touch accepts - the first draft of this
    # suite used it, every touch failed, so the mtimes were all identical and "newest" was whatever
    # find happened to emit first. Three legs then graded the wrong file and read as product
    # failures. A fixture whose ordering does not hold tests nothing.
    touch -d "@$((1792000000 - i * 60))" "$name"
    i=$((i+1))
  done
}
run_pred(){ OUT="$1" bash -c "OUT=\"$1\"; $2; printf '%s' \"\$lastknown\"" 2>/dev/null; }

# ---- 1. THE CASE THAT BROKE IT: newest log empty, older ones have content ----------------------
mk "$T/a" "0:EMPTY" "1:20261022.115351.068 XcOpen: XenIface handle" "2:older line"
got=$(run_pred "$T/a" "$REGION")
ck 'the newest log being EMPTY no longer reads as "the volume could not be read"' \
   "$([ -n "$got" ] && echo 0 || echo 1)" "lastknown='$got'"
ck '...and the line it returns is the newest NON-EMPTY one' \
   "$(printf '%s' "$got" | grep -q 'XcOpen' && echo 0 || echo 1)" "lastknown='$got'"
# SEEN TO FAIL: the old form on the same tree
gotc=$(run_pred "$T/a" "$CONTROL")
ck 'SEEN TO FAIL: the OLD single-newest-file form returns nothing on that same tree' \
   "$([ -z "$gotc" ] && echo 0 || echo 1)" "the control returned '$gotc' - it would not have fired the defect"

# ---- 2. several fresh empty logs (the MSI restarts several services at once) --------------------
mk "$T/b" "0:EMPTY" "1:EMPTY" "2:EMPTY" "3:the surviving line" "4:older"
got=$(run_pred "$T/b" "$REGION")
ck 'three freshly created empty logs still yield the newest surviving line' \
   "$(printf '%s' "$got" | grep -q 'surviving' && echo 0 || echo 1)" "lastknown='$got'"

# ---- 3. a volume that genuinely yields nothing MUST still report nothing ------------------------
# The whole point of keeping it strict: the [ERROR] branch must remain reachable.
mk "$T/c" "0:EMPTY" "1:EMPTY"
got=$(run_pred "$T/c" "$REGION")
ck 'a volume whose logs are ALL empty still yields nothing, so the [ERROR] branch stays reachable' \
   "$([ -z "$got" ] && echo 0 || echo 1)" "lastknown='$got'"
rm -rf "$T/d"; mkdir -p "$T/d/logvol-live/files"
got=$(run_pred "$T/d" "$REGION")
ck 'a volume with no *.log at all yields nothing' "$([ -z "$got" ] && echo 0 || echo 1)" "lastknown='$got'"
rm -rf "$T/e"; mkdir -p "$T/e"
got=$(run_pred "$T/e" "$REGION")
ck 'a missing files/ dir yields nothing and does not error out' "$([ -z "$got" ] && echo 0 || echo 1)" "lastknown='$got'"

# ---- 4. the payload must not be able to forge a severity ---------------------------------------
# The harness line embeds this value. A guest line containing [ERROR] once made the HARNESS appear
# to declare an error that was the guest's; the shipped region strips the brackets for that reason,
# and sweep-gate's LEVELS regex needs a literal ']'.
mk "$T/f" "0:[ERROR] a guest-side error line"
got=$(run_pred "$T/f" "$REGION")
ck 'a guest line containing [ERROR] cannot forge a harness severity (brackets stripped)' \
   "$(printf '%s' "$got" | grep -q '\[ERROR\]' && echo 1 || echo 0)" "lastknown='$got'"
ck '...while its text is still carried, so the witness is not silently emptied' \
   "$(printf '%s' "$got" | grep -q 'guest-side error line' && echo 0 || echo 1)" "lastknown='$got'"

# ---- 5. the bound is deliberate and documented --------------------------------------------------
# It walks at most 10 files. If the newest 10 are all empty the witness is absent and the [ERROR]
# branch fires - stated here so the limit is a decision on record, not an accident.
set -- ; i=0
specs=""
while [ "$i" -lt 12 ]; do specs="$specs $i:EMPTY"; i=$((i+1)); done
mk "$T/g" $specs "12:deep line nobody reaches"
got=$(run_pred "$T/g" "$REGION")
ck 'the walk is bounded at 10 files: a line below that is NOT reported (deliberate)' \
   "$([ -z "$got" ] && echo 0 || echo 1)" "lastknown='$got'"

# ---- 6. the region is the shipped one ----------------------------------------------------------
ck 'the predicate under test came from quick-upgrade.sh, not from this file' \
   "$(grep -q 'QREXECGAPWITNESS-BEGIN' "$SRC" && echo 0 || echo 1)" 'the markers must exist in the harness'

say ''
say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
