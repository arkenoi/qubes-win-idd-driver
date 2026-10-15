#!/bin/bash
# dom0-callers-check.sh - does the START MENU caller get what dom0's parser needs, warm and COLD?
#
#   mgmt/harness/dom0-callers-check.sh <vm> [logfn]            # warm: the guest is Running
#   mgmt/harness/dom0-callers-check.sh --cold <vm> [logfn]     # cold: the guest is Halted
#
# WHY THIS EXISTS. The release goal has two clauses and the gate only measured the first:
# "next release passed acceptance test. qrexec behavior is aligned with dom0 callers: updaters and
# start menu, from cold qube as well." vmexec-channel-check.sh covers the UPDATER caller. Nothing
# covered the START MENU caller or the COLD case: grepping the matrix, the protocol and its runner
# for qubes.GetAppmenus finds only a check that the service FILE exists, and appmenu-guest-ab.sh -
# the one instrument that ever ran the service on a guest - is not called by the campaign at all.
# So the menu was last measured by hand on one German golden on 2026-10-07 and has been unmeasured
# by the gate ever since.
#
# WHAT DOM0 DOES WITH THE STREAM, which is what makes a bad line expensive: qubesappmenus'
# receive.py reads `<id>.desktop:<Key>=<Value>` lines, decodes each as ASCII, and **ignores what it
# cannot match IN SILENCE**. There is no error for a malformed line, a non-ASCII byte or an id with
# a space in it - the entry simply never appears in the menu. That silence is why this has to be
# asserted line by line rather than by eyeballing a sample: a stream that is 90% correct looks
# exactly like one that is 100% correct, from dom0 and from here.
#
# A REFUSAL IS NOT AN EMPTY STREAM, and an instrument that cannot tell them apart must not gate.
# Both arrive here as zero bytes of stdout. qrexec-client-vm writes a diagnosable message to STDERR
# on a policy denial, so the two streams are captured SEPARATELY and the verdict names which one
# happened. That distinction is the whole reason this can gate while vmexec-channel-check.sh still
# cannot.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

COLD=0
[ "${1:-}" = "--cold" ] && { COLD=1; shift; }
VM="${1:?usage: $0 [--cold] <vm> [logfn]}"
LG="${2:-echo}"
# A FUNCTION NAME IS NOT A COMMAND IN A CHILD PROCESS, and this cost two evidence files their
# contents. matrix.sh calls these checks with its own `say` as the log function - `say` is a shell
# FUNCTION, not exported, so in a child `bash script.sh` every log call died with
# "say: command not found". In vmexec-channel-check.sh that was SILENT: its verdict comes from
# $rc_all, computed independently, so it reported PASS while its evidence file contained nothing but
# those errors - in every campaign run since it was written. In dom0-callers-check.sh it was worse:
# the cell FAILED and the reason was unreadable. So the log target is validated here rather than
# trusted, and a caller that passes something unrunnable gets stdout instead of silence.
if ! command -v "$LG" >/dev/null 2>&1; then
  echo "  (log target '$LG' is not a command here - a shell function does not cross into a child process; using echo)"
  LG=echo
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/dom0callers.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
rc_all=0
bad(){ $LG "  CALLERS: [ERROR] $*"; rc_all=1; }
good(){ $LG "  CALLERS: $*"; }

# ---- THE STATE IS THE TEST CONDITION, so it is asserted, never assumed ------------------------
# "from cold qube as well" is a clause of the release goal, and a cold check that runs against an
# already-Running guest measures the warm path under a cold label. That substitution has its own
# entry in this project's history and the owner's words on it were explicit; so the precondition is
# a REFUSAL, not a warning. Equally, the warm check against a Halted guest would attribute a
# cold-start timeout to the service.
#
# DOM0CALLERS_STREAM=<file> replaces the qrexec call with that file, for the selftest only. It is
# announced on its own line and repeated in the verdict, because a gate that can be fed a fixture
# must say so in the log it is graded from - "a reproduction is never the source of truth". The
# selftest asserts matrix.sh never sets it.
FIXTURE="${DOM0CALLERS_STREAM:-}"
if [ -n "$FIXTURE" ]; then
  $LG "  CALLERS: FIXTURE MODE - stream read from '$FIXTURE', NOT measured on $VM"
fi

state=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
if [ -n "$FIXTURE" ]; then
  :   # no guest is involved, so there is no state to assert
elif [ "$COLD" -eq 1 ]; then
  [ "$state" = Halted ] || { $LG "  CALLERS: [ERROR] --cold needs $VM Halted and it is '$state' - refusing to label a warm call cold"; exit 2; }
else
  [ "$state" = Running ] || { $LG "  CALLERS: [ERROR] $VM is '$state', not Running - a cold start would be timed as service latency (use --cold)"; exit 2; }
fi

# ---- the call dom0 makes, verbatim ------------------------------------------------------------
# receive.py calls run_service('qubes.GetAppmenus') - lowercase m. Windows Tools has always shipped
# the definition as qubes.GetAppMenus, so the installer lays down the lowercase name too; calling
# the spelling dom0 uses is the point, not the one our tree happens to contain.
SVC=qubes.GetAppmenus
# THE OUTER BOUND COMES FROM THE QUBE, NOT FROM A NUMBER I LIKED. A cold call has to pay for the
# whole boot before the service is even reached, and this check's first version capped it at a flat
# 180s - which would have cut off a legitimate cold start and reported it as the defect it hunts, an
# empty stream. dom0's own caller gives up at qrexec_timeout, so that is the only bound that means
# anything here; the margin covers qrexec's own setup, and the floor covers a qube with a tiny value
# set for some other reason. This is a BOUND so the check cannot hang, never a fix for a slow path.
qt_pref=$(qvm-prefs "$VM" qrexec_timeout 2>/dev/null)
case "$qt_pref" in (*[!0-9]*|'') qt_pref=0 ;; esac
bound=$(( qt_pref + 60 )); [ "$bound" -lt 180 ] && bound=180
t0=$(date +%s)
if [ -n "$FIXTURE" ]; then
  cat "$FIXTURE" >"$T/out" 2>"$T/err"; call_rc=$?
else
  timeout -k 5 "$bound" qrexec-client-vm "$VM" "$SVC" </dev/null >"$T/out" 2>"$T/err"
  call_rc=$?
fi
elapsed=$(( $(date +%s) - t0 ))
bytes=$(wc -c <"$T/out")
mode=warm; [ "$COLD" -eq 1 ] && mode=cold

# ---- 0. refusal vs silence --------------------------------------------------------------------
if [ "$bytes" -eq 0 ]; then
  if [ "$call_rc" -ge 124 ] && [ -z "$FIXTURE" ]; then
    bad "$SVC did not finish inside ${bound}s (rc=$call_rc) - a HANG, which is not the same as an empty menu"
    $LG "  CALLERS: the bound came from this qube's qrexec_timeout (${qt_pref}s) + 60s, so dom0's caller had already given up"
  elif [ -s "$T/err" ]; then
    bad "$SVC returned NOTHING and stderr says: $(tr -d '\r' <"$T/err" | head -2 | tr '\n' ' ')"
    $LG "  CALLERS: that is a refusal or a transport failure, not an empty menu ($mode, rc=$call_rc, ${elapsed}s)"
  else
    bad "$SVC returned 0 bytes with a SILENT stderr ($mode, rc=$call_rc, ${elapsed}s) - dom0 would show an empty menu"
  fi
  $LG "  CALLERS: [ERROR] the start-menu caller is NOT aligned on $VM ($mode)"
  exit 1
fi
good "$SVC answered: $bytes bytes in ${elapsed}s ($mode, rc=$call_rc)"
cp "$T/out" "$T/stream"

# ---- THE COLD CLAUSE: the call itself had to bring the qube up --------------------------------
# dom0 calling a service on a Halted Windows qube is the shape the goal names. The qube must come
# up AND the agent must be serving by the time qrexec hands the call over - if the guest is still
# Halted here, something else answered, and if it took longer than the qube's own qrexec_timeout
# then dom0's caller would already have given up where this one waited.
if [ "$COLD" -eq 1 ] && [ -z "$FIXTURE" ]; then
  now=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null)
  [ "$now" = Running ] && good "the cold call started the qube (Halted -> $now)" \
    || bad "after a cold call $VM is '$now' - this stream did not come from a qube this call started"
  qt=$qt_pref
  if [ "$qt" -gt 0 ] && [ "$elapsed" -gt "$qt" ]; then
    bad "the cold call took ${elapsed}s against qrexec_timeout=${qt}s - dom0's caller gives up first"
  elif [ "$qt" -gt 0 ]; then
    good "cold answer in ${elapsed}s, inside qrexec_timeout=${qt}s"
  fi
fi

# ---- 1. THE CMD BANNER MUST NOT BE IN IT ------------------------------------------------------
# A capture of this very service through the VMShell path begins "Microsoft Windows [Version
# 10.0.26200.8037]" and an echoed command line (scratchpad/appmenus-win11de-measured.txt). Those
# lines are not `<id>.desktop:Key=Value`, so receive.py drops them silently - but their presence
# means something is wrapping the service in a shell that writes to the same stream, and the next
# thing it writes may land mid-entry.
if command grep -qa 'Microsoft Windows \[Version\|^C:\\\\Windows\\\\System32>' "$T/stream"; then
  bad "the stream carries cmd's banner - a shell is writing to dom0's parse channel"
fi

# ---- 2. EVERY LINE HAS TO PARSE ---------------------------------------------------------------
# Not "most": an unmatched line is an entry that silently never appears. Keys are the ones the
# shipped emitter writes (Name, Comment, Exec, Icon) within the set receive.py accepts at all.
python3 - "$T/stream" <<'PY' >"$T/verdict" 2>&1
import re, sys, collections

RAW = open(sys.argv[1], 'rb').read()
# dom0 DECODES EACH LINE AS ASCII AND DROPS THE REST, so the check has to see what dom0 sees, not a
# tolerant decode of what the guest sent. A German guest's "Zubehoer" arrives mangled; that is
# expected and handled. A non-ASCII byte in an ID is not.
lines = [l for l in RAW.split(b'\n')]
KEYS = ('Name', 'GenericName', 'Comment', 'StartupWMClass', 'Categories', 'Exec', 'Icon')
ENTRY = re.compile(rb'^([A-Za-z0-9._-]+)\.desktop:(' + b'|'.join(k.encode() for k in KEYS) + rb')=(.*)$')

unparsed, entries, names = [], collections.defaultdict(dict), collections.defaultdict(list)
for raw in lines:
    l = raw.rstrip(b'\r')
    if not l.strip():
        continue
    m = ENTRY.match(l)
    if not m:
        unparsed.append(l[:120].decode('ascii', 'replace'))
        continue
    ident, key, val = m.group(1).decode('ascii'), m.group(2).decode('ascii'), m.group(3)
    entries[ident][key] = val
    if key == 'Name':
        names[val].append(ident)

print("entries=%d" % len(entries))
print("unparsed=%d" % len(unparsed))
for u in unparsed[:5]:
    print("UNPARSED|%s" % u)

# An id with a space, ';' or '%' is refused by create_template(); non-ASCII cannot survive the
# decode. The regex above already constrains the id, so anything rejected shows up as unparsed -
# this reports it per-id so the message names the offender rather than a count.
print("noname=%s" % ",".join(sorted(i for i, kv in entries.items() if 'Name' not in kv))[:200])
dupes = {n: ids for n, ids in names.items() if len(ids) > 1}
print("duplabels=%d" % len(dupes))
for n, ids in list(dupes.items())[:5]:
    print("DUPE|%s|%s" % (n.decode('ascii', 'replace'), ",".join(ids)))
for fixed in ('qubes-run-terminal', 'qubes-open-file-manager'):
    print("fixed:%s=%s" % (fixed, "yes" if fixed in entries else "NO"))
PY

v(){ command grep -a "^$1=" "$T/verdict" | head -1 | cut -d= -f2-; }
ents=$(v entries); unp=$(v unparsed); dup=$(v duplabels); noname=$(v noname)
[ -n "$ents" ] || { bad "the parser produced no verdict: $(head -3 "$T/verdict" | tr '\n' ' ')"; exit 1; }

# A menu of two entries is the shape of the amputation the owner caught ("you silently dropped most
# of the apps and tell me that it is fine?"): 37 is what a clean Windows reports.
if [ "$ents" -ge 10 ]; then
  good "$ents entries parse as dom0 parses them"
else
  bad "only $ents entries - a clean Windows reports ~37; this is the amputation shape"
fi

if [ "$unp" -eq 0 ]; then
  good "every line matched - nothing is silently dropped by receive.py"
else
  bad "$unp line(s) do NOT parse, so those entries never appear and dom0 says nothing:"
  command grep -a '^UNPARSED|' "$T/verdict" | sed 's/^UNPARSED|/      /' | while IFS= read -r l; do $LG "$l"; done
fi

[ -z "$noname" ] && good "every entry carries a Name" || bad "entries with no Name (unusable to dom0): $noname"

if [ "$dup" -eq 0 ]; then
  good "no two entries read alike in the menu"
else
  bad "$dup duplicate label(s) - two menu rows a user cannot tell apart:"
  command grep -a '^DUPE|' "$T/verdict" | sed 's/^DUPE|/      /' | while IFS= read -r l; do $LG "$l"; done
fi

# The two launchers dom0 wires per qube key off FIXED ids. A Windows guest that omits them leaves
# dom0's own Terminal and File Manager rows pointing at nothing.
for fixed in qubes-run-terminal qubes-open-file-manager; do
  if [ "$(command grep -a "^fixed:$fixed=" "$T/verdict" | cut -d= -f2)" = yes ]; then
    good "dom0's fixed launcher '$fixed' is reported"
  else
    bad "dom0's fixed launcher '$fixed' is MISSING - that menu row points at nothing"
  fi
done

if [ "$rc_all" -eq 0 ]; then
  good "the start-menu caller is aligned on $VM ($mode, $ents entries, ${elapsed}s)${FIXTURE:+ - FIXTURE, not a guest measurement}"
else
  $LG "  CALLERS: [ERROR] the start-menu caller is NOT aligned on $VM ($mode)"
fi
exit "$rc_all"
