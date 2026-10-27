#!/bin/bash
# classify-errors.sh - have JEV classify each unaccounted declared error, with the EMITTING CODE in
# evidence, instead of a model writing a plausible reason into the ledger.
#
#   tools/classify-errors.sh <sweep-gate output> [max]
#
# WHY. The first ledger was written in one batch by pattern-matching explanations onto 18 messages
# without reading the code that emits any of them. The largest entry was wrong: x102 "inverted DWM
# bounds - rejecting" was called correct-but-over-logged, while agent/gui-agent/main.c:1583 logs it
# at WARNING precisely because it is the NON-routine case and the window is REJECTED. Jev scored the
# hiding risk 0.65 for that batch. Deciding whether a logged condition is handled or is a defect is
# a classification, and this project's rule is that a classification belongs to Jev.
#
# Output is a ledger-shaped line per message that Jev classed HANDLED, each carrying the file:line
# the classification was made from. A DEFECT or an UNDECIDED message gets no line, so it keeps
# surfacing. Nothing here writes the ledger - a human pastes what they accept.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
SW="${1:?usage: $0 <sweep-gate output> [max]}"
MAX="${2:-8}"
[ -s "$SW" ] || { echo "classify: $SW is empty - nothing to classify" >&2; exit 2; }

RUB=$(mktemp); OUTD=$(mktemp -d); trap 'rm -rf "$RUB" "$OUTD"' EXIT
cat > "$RUB" <<'J'
{"questions":{"klass":{"type":"choice",
 "instructions":{"judge":"A Windows guest agent logged this line at Error or Warning. The emitting code is quoted. Decide what the line IS, from the code and not from how the message reads."},
 "criteria":{
  "handled":"the site detects a condition it is designed to detect and handles it - a retry, a documented default, a normal teardown, a deliberate rejection of input that cannot be used - so the line is a report, not a failure of the product",
  "defect":"the line reports the product failing to do its job, or a fallback firing, or state being lost; it must keep surfacing until fixed",
  "overlogged":"the condition is genuinely routine and handled, but logging it at Error/Warning is itself wrong - it belongs at Info or Debug, and the fix is the log level",
  "undecided":"the quoted code is not enough to tell"}}}}
J

n=0
grep -aE '^  UNACCOUNTED x[0-9]+' "$SW" | while IFS= read -r row; do
  [ "$n" -ge "$MAX" ] && break
  cnt=$(printf '%s' "$row" | sed -E 's/^  UNACCOUNTED x([0-9]+).*/\1/')
  msg=$(printf '%s' "$row" | sed -E 's/^  UNACCOUNTED x[0-9]+ +//')
  fn=${msg%%:*}
  # THE KEY IS THE LONGEST LITERAL RUN OF WORDS IN THE MESSAGE, taken from the message as logged.
  # Two earlier attempts failed on the same line: cutting at the first placeholder gave an EMPTY key
  # for "GetRealWindowRect: <HEX>: inverted DWM bounds ...", and dropping words shorter than four
  # characters built "GetRealWindowRect inverted bounds usable", which matches nothing because the
  # source says "inverted DWM bounds (%d,%d)... and no usable GetWindowRect". Both times the lookup
  # fell back to the function name, matched line 1, and Jev was handed a file header - answering
  # "undecided" about nothing, which is the worst outcome available: a judgement that looks real.
  key=$(KMSG="$msg" python3 - <<'PYK'
import os, re
m = os.environ["KMSG"]
m = re.sub(r'<[A-Z]+>', ' ', m)                      # placeholders the normaliser put in
m = re.sub(r'\([0-9N,\- ]*\)', ' ', m)               # (N,N)-(N,N) coordinate groups
# AND `N` IS A PLACEHOLDER TOO - it stands for a %d the emitter fills in, so any key containing
# one can never match the source. Six of 21 messages skipped on exactly that in run 38994277148:
# 'QGAVCHANFAIL vchan to domain N port N never opened', 'frame not processed after N ms',
# 'NOTIFBRIDGESYSKILL Windows killed the bridge pid N before announcing session end'. The split
# below has to happen AFTER this, or the run spans a hole and matches nothing.
m = re.sub(r'\bN\b', ' | ', m)
runs = [r.strip() for r in re.split(r'[^A-Za-z ]+|\s{2,}|\|', m)]
runs = [r for r in runs if len(r.split()) >= 2 and len(r) >= 12]
# EVERY CANDIDATE, LONGEST FIRST - not just the longest one. The longest run is not the most
# findable: for "QGAVCHANFAIL vchan to %s port %d never opened: xenstore node unreadable%s" the
# longest run spans the %s ("QGAVCHANFAIL vchan to domain") and matches nothing, while the
# emitter sits at qrexec-wrapper.c:1440 and "xenstore node unreadable" finds it at once. Taking
# only the longest reported that emitter as not present in this repository at all.
# AND A TAG IS A KEY, IN MESSAGE ORDER. The word-runs above split on everything that is not a
# letter or a space, which SHREDS this project's own log anchors: QGAFAULT-INIT becomes
# "QGAFAULT" + "INIT", two single words under the >=2-words/>=12-chars floor, so nothing survived
# and agent/gui-agent/faultinject.c:234 was reported as "vendored code this repository does not
# contain" - about a line this repo emits. These ALL-CAPS tags are deliberate grep anchors.
# Message ORDER, not longest-first: a message's LEADING tag is its anchor while later caps tokens
# are usually VALUES, and by length "QGA-FAULT-INJECTION" (from build=QGA-FAULT-INJECTION:on) beat
# the anchor and matched the marker constant at :27 - a confident verdict about a comment.
# Added LAST, so a real word-run still wins, and still matched LITERALLY in the tree, so this is
# not the function-name fallback the comments refuse: a tag absent from the tree still says EXTERNAL.
seen = []
for t in re.findall(r'[A-Z][A-Z0-9]{3,}(?:-[A-Z0-9]+)*', m):
    if len(t) >= 8 and t not in seen: seen.append(t)
print("\n".join(sorted(set(runs), key=len, reverse=True) + seen))
PYK
)
  # FIND THE EMITTER BY ITS MESSAGE, NOT BY ITS FUNCTION NAME. This took the FIRST file that merely
  # NAMED the function, which on a real run was the wrong file almost every time - capture.h for
  # CaptureThread, qrexec-wrapper.h for InitVchan, qga-exitcodes.h for WatchForEvents - and then
  # failed to find the message in it and skipped. MEASURED on run 38994277148: of 21 unaccounted
  # messages it could judge FOUR; searching by the message key instead locates 9 of the 13 whose
  # emitter is in this tree. That locator is why the ledger has carried "23 distinct declared error
  # messages that nobody has investigated" since 2026-10-14: the policy says a row needs Jev over
  # the emitting code, and the tool that was supposed to produce it could not find the code.
  src=""; ln=""
  if [ -n "$key" ]; then
    # .c and .cpp first: a header may carry the string in a comment while the emitter is the unit.
    # THE HARNESSES ARE EMITTERS TOO, and they are not vendored anywhere. This searched only
    # agent/ and core-agent/, so three bash/PowerShell lines in run 38994277148 - the MSI-log
    # warning, the clock warning and the REINSTALL=ALL feature warning - were reported as
    # "emitted by vendored code this repository does not carry", which is simply false about a
    # line written by mgmt/harness/matrix.sh. Saying that would have sent the reason into the
    # ledger as unknowable.
    # NOT THIS TOOL'S OWN SOURCE, AND NOT THE GATE'S BOOKKEEPING. Adding tools/ to the search made
    # this script match its OWN comments - which quote these very messages - and Jev was then asked
    # to classify the emitter of 'QGAVCHANFAIL ...' from classify-errors.sh:54. It answered
    # defect=0.72. A confident verdict about the wrong file is the worst output available here, and
    # it would have gone into the ledger as a receipt. Same self-match that the ledger verifier hit.
    while IFS= read -r _k; do
      [ -n "$_k" ] || continue
      for _pat in '*.c' '*.cpp' '*.h' '*.sh' '*.ps1' '*.py'; do
        src=$(grep -rln --exclude-dir=.git --exclude=error-ledger.txt --exclude=error-corpus.txt \
                --exclude=log-sweep-baseline.json --exclude='classify-errors.sh' \
                --exclude='sweep-gate*' --include="$_pat" \
                -F -- "$_k" agent core-agent guest mgmt/harness mgmt/prime-jobs 2>/dev/null | head -1)
        [ -n "$src" ] && break
      done
      if [ -n "$src" ]; then
        # THE EMITTING LINE, NOT THE FIRST MENTION. `head -1` took the first literal occurrence,
        # which for a tag key is often a COMMENT, and Jev then answers about prose - the
        # "judgement that looks real" the comments above refuse. Prefer an occurrence that is a
        # LOGGING CALL; fall back to the first mention only when none is. SKIP/EXTERNAL untouched.
        ln=$(grep -nF -- "$_k" "$src" 2>/dev/null |
               grep -E 'Log(Error|Warning|Info|Debug|Verbose)\(|printf|echo |say |log ' |
               head -1 | cut -d: -f1)
        [ -n "$ln" ] || ln=$(grep -nF -- "$_k" "$src" 2>/dev/null | head -1 | cut -d: -f1)
        key="$_k"; break
      fi
    done <<< "$key"
  fi
  # NO BLIND FALLBACK. This used to look up a file by FUNCTION NAME and then take the first log
  # call in it, and this file's own comment already records where that leads: "the lookup fell back
  # to the function name, matched line 1, and Jev was handed a file header - answering 'undecided'
  # about nothing, which is the worst outcome available: a judgement that looks real." Widening the
  # search brought it straight back - QioWriteBuffer and send_command_to_daemon were both judged
  # from mgmt/harness/matrix.sh:301, an unrelated line, at 0.86 and 0.93 handled. If the message
  # itself cannot be found, there is no evidence, and no evidence is reported as no evidence.
  # AND "NOT IN THIS TREE" IS AN ANSWER, NOT A GAP. windows-utils and the qrexec pipe server are
  # vendored elsewhere, so QioWriteBuffer, pipe_thread_client, send_command_to_daemon and
  # QpsDisconnectClientInternal genuinely cannot be read from here. Saying which of the two it is
  # matters: one is a tool failure to fix, the other is a disposition to write by hand.
  if [ -z "$ln" ]; then
    if [ -z "$src" ]; then
      echo "EXTERNAL x$cnt $fn - no file under agent/ core-agent/ guest/ mgmt/ tools/ carries this message or function, so it comes from vendored code this repository does not contain (windows-utils, the qrexec pipe server, libvchan). No Jev verdict is possible from here; the ledger row has to say that."
    else
      echo "SKIP x$cnt $fn - found $src but cannot locate the emitting line (key='$key'), so there is no evidence to judge"
    fi
    continue
  fi
  # A STAGED PAYLOAD IS NOT THE SOURCE OF TRUTH. mgmt/prime-jobs/*/setup/ holds a release
  # package's own installer, so a receipt that points there rots at the next package. It is still
  # the real emitting text, so it is used - and labelled, rather than quietly recorded as ours.
  _origin=""
  case "$src" in mgmt/prime-jobs/*) _origin=" [STAGED PAYLOAD - the packaged installer's own text, not a file this repo authors]" ;; esac
  st="$OUTD/state.txt"
  { echo "THE LOGGED LINE, seen $cnt time(s) across one campaign's guest logs:"
    echo "  $msg"
    echo
    echo "THE EMITTING CODE, $src around line $ln (comments included - they often state the intent):"
    sed -n "$((ln>20?ln-20:1)),$((ln+12))p" "$src"
  } > "$st"
  v=$(python3 tools/jev.py "$RUB" "$st" 2>&1 | tail -1)
  echo "x$cnt  $fn  ($src:$ln)$_origin  -> $v"
  n=$((n+1))
done
