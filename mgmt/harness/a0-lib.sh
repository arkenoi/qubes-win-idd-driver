# mgmt/harness/a0-lib.sh — toast-bridge acceptance INSTRUMENTS, shared verbatim between
# a0-toast-bridge.sh (the full P1-P8 acceptance) and a0-selftest.sh (the instrument-validation
# floor). ONE copy on purpose: the floor exists to validate EXACTLY the code the full harness
# runs, so these must never fork into drifting copies (the constant-10 blog_len bug corrupted a
# whole Opus run precisely because nothing cheap exercised the real helper first).
#
# CALLER CONTRACT — source this from the REPO ROOT, AFTER all of the following exist:
#   $VM        subject qube name (helpers pin QTEST_VM=$VM per call)
#   $OUT       evidence dir, created+writable (geom dumps and .ids baselines land here)
#   $R         results log path (fire_* instrument warnings ride log() into it)
#   log()      timestamped logger that tees into $R (harness-defined)
#   qrun()     from .claude/skills/win-guest-e2e/e2e-lib.sh — source that FIRST (it also
#              requires QTEST_VM exported; there is deliberately no default target)
#   cwd        repo root: helpers call ./tools/qtest, ./tools/qtest-geom, guest/*.ps1
#   guest lock the caller MUST already hold the per-VM guest lock (source mgmt/harness/vmlock.sh;
#              vm_lock "$VM") BEFORE sourcing this. A sourced instrument library never takes
#              vm_lock itself — that lock (lint RULE 15) is the ENTRY script's responsibility, and
#              both a0-toast-bridge.sh and a0-selftest.sh take it before they source this file.
# Used only by the FULL harness's phase code, NOT by anything in this file: verdict(),
# cap() (e2e-lib), and the e2e-wait.sh waits — the floor defines/sources its own.
#
# Defines constants PSAUMID CTLAUMID QT BLOG HBF INCOMING TOASTRE and functions raspush
# consent_ensure geom ors blog_len blog_since fwd_count fwd_attempts fwd_selftest path_state
# hb_fresh hb_state fire_raw fire_info fire_info_p fire_ctl showbanner dismiss_toasts
# new_or_window snap_or.
# blog_len returns NONZERO on hard failure — callers must handle that status, never default
# the count to 0.
#
# Everything below the guard is MOVED VERBATIM from a0-toast-bridge.sh (2026-09-05 extraction);
# the comments carry the audit history of each instrument bug and stay with the code they fixed.

for _a0v in VM OUT R; do
  [ -n "${!_a0v:-}" ] || { echo "FATAL a0-lib.sh: \$$_a0v must be set before sourcing" >&2; exit 2; }
done
unset _a0v
declare -F log  >/dev/null || { echo "FATAL a0-lib.sh: log() must be defined before sourcing" >&2; exit 2; }
declare -F qrun >/dev/null || { echo "FATAL a0-lib.sh: qrun() missing - source .claude/skills/win-guest-e2e/e2e-lib.sh first" >&2; exit 2; }

PSAUMID='{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
CTLAUMID='Microsoft.Windows.Explorer'
QT='C:\Program Files\Qubes Tools\bin'
BLOG='C:\ProgramData\qubes-toast-bridge\bridge.log'
HBF='C:\ProgramData\qubes-toast-bridge\heartbeat'

# Run a pushed script IN THE INTERACTIVE USER SESSION (listener + HKCU are session-bound).
# NEVER pass -Command with nested quotes through qtest - each hop re-splits and strips them
# (measured during the win10-app residue cleanup); -Script + -ArgsB64 survives every hop.
INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
raspush(){ # $1=repo script path, $2=args string (may be empty), $3=tag
  # Push run-as-user.ps1 TOO, not just the target script. The harness invokes
  # `powershell -File $INCOMING\run-as-user.ps1 -Script $INCOMING\<target>`, so run-as-user.ps1
  # MUST be present at $INCOMING. On a FRESH PRIME QubesIncoming is empty and nothing else pushes
  # it, so powershell fell to its interactive banner and every fire silently no-op'd - misread as
  # "cold-session timing" for five runs (2026-09-04). qtest push deletes-then-copies, so pushing
  # both every call is idempotent and cheap.
  QTEST_VM=$VM timeout -k 8 60 ./tools/qtest push guest/run-as-user.ps1 "$1" >/dev/null 2>&1
  local base b64
  base=$(basename "$1")
  b64=$(printf '%s' "$2" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  qrun "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INCOMING\\run-as-user.ps1\" -Tag $3 -Script \"$INCOMING\\$base\" ${b64:+-ArgsB64 $b64}"
}

# Set the UserNotificationListener consent value IN THE USER SESSION and VERIFY it landed -
# bounded retry-with-verify. WHY (rig 2026-09-06, the P6 cascade): ONE raspush of
# a0-consent.ps1 can silently no-op - run-as-user's task-start race (fixed at the source in
# run-as-user.ps1 the same day: the wait loop broke on LastTaskResult=267011 "has not yet run"
# and read a not-yet-written output file) plus the genuinely transient class (a momentary
# no-Active-session miss, a qtest push/qrexec hiccup) - returning output with NO CONSENT-NOW
# line. The one-shot callers then diverged: P6a correctly went INSTRUMENT, but P6b's
# Allow-restore DISCARDED its output entirely, so a no-op'd Deny left the bridge connected and
# P6b waited 32 real minutes for a reconnect that could never happen. a0-consent.ps1 is
# idempotent (set + registry readback), so re-attempting is safe and the echoed readback IS
# the verification. A retry that saves the attempt is still an ANOMALY and is logged loudly
# (fallbacks-are-anomalies); per-attempt raw output is kept in $OUT/consent-<tag>.txt so a
# recurrence can be classified (deterministic relay bug vs transient) instead of re-guessed.
# Sets CONSENT_LAST to the last observed CONSENT-NOW=... (empty if none was ever read).
# Returns 0 iff CONSENT-NOW=<value> was read back. NOTE: a0-selftest.sh defines its own local
# one-shot consent_set AFTER sourcing this lib (S10 tests the raw roundtrip, no retries) -
# hence the distinct name; do not rename either into the other.
consent_ensure(){ # $1=Allow|Deny $2=evidence tag (per-phase, e.g. a0x1)
  local want="$1" tag="$2" try out
  CONSENT_LAST=""
  for try in 1 2 3; do
    out=$(raspush guest/a0-consent.ps1 "-Value $want" "${tag}t${try}$RANDOM" 2>&1 | tr -d '\r')
    printf '=== attempt %s want=%s %s ===\n%s\n' "$try" "$want" "$(date -u +%H:%M:%S)" "$out" >> "$OUT/consent-$tag.txt"
    CONSENT_LAST=$(printf '%s' "$out" | grep -aoE 'CONSENT-NOW=[^ ]+' | tail -1)
    if [ "$CONSENT_LAST" = "CONSENT-NOW=$want" ]; then
      [ "$try" -gt 1 ] && log "ANOMALY consent_ensure: $want landed only on attempt $try/3 - the run-as-user no-op flake fired (raw attempts in consent-$tag.txt); diagnose if it recurs"
      return 0
    fi
    log "consent_ensure: attempt $try/3 for $want did not verify (read '${CONSENT_LAST:-nothing}'; relay: $(printf '%s' "$out" | grep -aoE 'RUNASUSER (error|lastresult)=[^ ]*' | tail -1))"
    [ "$try" -lt 3 ] && sleep 8
  done
  return 1
}

geom(){ QTEST_VM=$VM timeout -k 8 200 ./tools/qtest-geom 2>/dev/null; }
# override-redirect toast/banner window lines (id x y w h override_redirect mapped name).
# Accept mapped=0 too: a Windows toast BANNER window auto-collapses (unmaps) a few seconds after it
# pops, but the window OBJECT lingers in the list. Requiring mapped=1 (the old `&& $7==1`) made P6a
# false-fail "toast lost" when the fail-open banner HAD appeared and then unmapped before geom
# sampled. Safe: a SUPPRESSED toast creates no banner window at all, and persistent shell lurkers
# are in the pre-fire baseline (new_or_window diffs new-vs-baseline), so any-mapped never false-adds.
ors(){ awk '$6==1' ; }

# Echo the bridge.log line count via -EncodedCommand, and NOTHING else. The old
# `cmd /c "type ...|find /c /v """` idiom was doubly broken (audit 2026-09-05): (1) qrun echoes
# the cmd banner "Microsoft Windows [Version 10.0.19045...]", so `grep -aoE '[0-9]+' | head -1`
# matched the banner's "10" and blog_len returned a CONSTANT 10 for the whole run - every
# blog_since offset was `Skip 10`, so early phases saw nothing (P4a false-FAIL: SENT id=15 hidden)
# and later ones saw a stale tail (P7 false-PASS, P8 false-FAIL); (2) the \" escaping delivered a
# literal \" to cmd, so the find count never even ran. Fix mirrors path_state: -EncodedCommand (no
# banner/self-match, no cmd backslash mangling), output anchored to a whole-line integer. Retries a
# transient cold-boot read; returns NONZERO on hard failure - callers MUST NOT default to 0.
blog_len(){
  local i n ps b64
  ps="if (Test-Path -LiteralPath '$BLOG') { (@(Get-Content -LiteralPath '$BLOG')).Count } else { 0 }"
  b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  for i in 1 2 3; do
    n=$(qrun "powershell -NoProfile -EncodedCommand $b64" | tr -d '\r' | grep -aoxE '[0-9]+' | head -1)
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
    sleep 2
  done
  return 1
}
blog_since(){ # $1 = old line count
  qrun "powershell -NoProfile -Command \"if (Test-Path '$BLOG') { Get-Content '$BLOG' | Select-Object -Skip $1 }\""
}

# --- delivered-toast detectors (audit 2026-09-05, the dropped-SENT false-FAILs) --------------
# WHY NOT `grep "SENT id=.*OK"`: BLog opens bridge.log share-READ-only and SILENTLY DROPS a
# line when two writers collide (qtb_shared.h BLog: CreateFileW(FILE_APPEND_DATA,
# FILE_SHARE_READ) -> INVALID_HANDLE_VALUE -> return). The 5133293 shadow worker writes its
# CLASSIFY line from a second thread at exactly toast-processing time, so the SENT line
# adjacent to it is the usual casualty (2026-09-05 run: ids 15/20/22 had FWD_RTT ok=1 AND a
# dom0 Dismissed-callback for their bubble, but no SENT line -> P4a/P6b/P7 false-FAILed on
# SENT-only greps). The authoritative delivery marker is `FWD_RTT guest_id=N ... ok=1`:
# ForwardText logs it ONLY after the dom0 qubes.Notifications server's ack frame for that seq
# (notifhost.cpp ReaderThread tag=0 -> g_awaitOk=1), i.e. dom0 accepted and id-assigned the
# notification. SENT is the human-readable record of the same event. Counting the DISTINCT id
# union of BOTH lines survives a single-line drop in either direction and stays correct after
# the BLog share-mode fix. All patterns are ANCHORED at the HH:MM:SS line start so guest-
# controlled toast TITLES embedded in SENT lines can never forge a match.
fwd_count(){ # $1 = FILE holding a bridge.log window -> echoes the number of DISTINCT toasts
             # PROVEN delivered to dom0 in that window (per-id forwards, deduped across the
             # FWD_RTT/SENT pair, plus the item counts of acked coalesced batches)
  local f="$1" n c
  n=$( { sed -n 's/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] FWD_RTT guest_id=\([1-9][0-9]*\) seq=[0-9][0-9]* ms=[0-9][0-9]* ok=1\r*$/\1/p' "$f"
         sed -n "s/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] SENT id=\([0-9][0-9]*\) .*: OK\r*\$/\1/p" "$f"
       } | sort -un | wc -l )
  # coalesced batches (guest_id=0) carry no per-id lines; only an ACKED batch counts (the old
  # `SENT coalesced x[0-9]+` grep counted FAILed batches as delivered - latent overcount).
  # Summed with awk, NOT `paste|bc`: bc is NOT INSTALLED on this rig, so the old harness's
  # coalesced sum was silently always empty (caught by fwd_selftest 2026-09-05).
  c=$( sed -n 's/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] SENT coalesced x\([0-9][0-9]*\): OK\r*$/\1/p' "$f" | awk '{s+=$1} END{print s+0}' )
  echo $(( ${n:-0} + ${c:-0} ))
}
fwd_attempts(){ # $1 = FILE; counts lines evidencing ANY dom0-forward ATTEMPT (SENT any
                # outcome, FWD_RTT any ok=) - for the must-be-ZERO negative assertions
                # (P4b control / P6a consent-revoked / P8 legacy-off). An attempted-but-
                # rejected forward there is just as much a leak as an acked one.
  grep -caE '^[0-9]{2}:[0-9]{2}:[0-9]{2} (SENT |FWD_RTT )' "$1" || true
}
# Seen-to-fail proof (autonomy rule 5), pure text, no VM contact: fwd_count must count the
# dropped-SENT shape (FWD_RTT ok=1, no SENT - THE 2026-09-05 regression), dedupe the pair,
# take only ACKED coalesced batches, and read 0 on a genuinely undelivered window; fwd_attempts
# must fire on any attempt and stay 0 on a forward-free window with embedded forgeries.
fwd_selftest(){
  local d="$OUT/fwd-selftest"; mkdir -p "$d"
  printf '%s\r\n' \
    '22:25:59 FWD_RTT guest_id=15 seq=2 ms=9 ok=1' \
    "22:34:39 SENT id=21 app='Windows PowerShell' title='A0T burst 1': OK" \
    '22:34:39 FWD_RTT guest_id=21 seq=3 ms=17 ok=1' \
    '22:36:00 FWD_RTT guest_id=0 seq=4 ms=3 ok=1' \
    '22:36:00 SENT coalesced x3: OK' > "$d/delivered.txt"
  printf '%s\r\n' \
    '22:26:00 FWD_RTT guest_id=17 seq=9 ms=15000 ok=-2' \
    '22:26:00 send seq=9: ack timeout' \
    "22:26:15 SENT id=17 app='x' title='y': FAIL (unseen, retried)" \
    '22:26:30 SENT coalesced x4: FAIL (unseen, retried)' \
    "22:26:45 SENT id=88 app='x' title='FWD_RTT guest_id=999 seq=1 ms=1 ok=1': FAIL (unseen, retried)" > "$d/undelivered.txt"
  printf '%s\r\n' \
    '22:28:04 skip id=16 aumid=Microsoft.Windows.Explorer (window path)' \
    '22:29:00 skip id=99 aumid=Evil SENT id=77 t: OK' \
    '22:25:12 connected (server version 1.0)' \
    '22:25:44 Dismissed id=2 reason=1 (not user-dismissed - guest record kept)' > "$d/clean.txt"
  local a b c au ac
  a=$(fwd_count "$d/delivered.txt"); b=$(fwd_count "$d/undelivered.txt"); c=$(fwd_count "$d/clean.txt")
  au=$(fwd_attempts "$d/undelivered.txt"); ac=$(fwd_attempts "$d/clean.txt")
  if [ "$a" = 5 ] && [ "$b" = 0 ] && [ "$c" = 0 ] && [ "${au:-0}" -ge 1 ] && [ "${ac:-0}" = 0 ]; then
    return 0
  fi
  log "INSTRUMENT fwd_selftest MISMATCH: delivered=$a (want 5) undelivered=$b (want 0) clean=$c (want 0) attempts-undelivered=$au (want >=1) attempts-clean=$ac (want 0)"
  return 1
}

# --- heartbeat / file-presence probe (SELF-MATCH-SAFE) --------------------------------------
# The old `cmd /c "if exist ... echo YESHB else echo NOHB"` idiom SELF-MATCHED: qtest run echoes
# the command line, which literally contains both markers, so a grep for them always hit the echo,
# not the result (the P2/P3/P6/P8 heartbeat false-fail, 2026-09-04). Fix: run Test-Path via a
# base64 -EncodedCommand, so the command line the console echoes is an opaque base64 blob and the
# markers HBPRESENT/HBABSENT appear ONLY in the actual output. Prints PRESENT or ABSENT.
path_state(){ # $1 = guest path
  local ps b64
  ps="if (Test-Path -LiteralPath '$1') { 'HBPRESENT' } else { 'HBABSENT' }"
  b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  qrun "powershell -NoProfile -EncodedCommand $b64" | grep -aoE 'HBPRESENT|HBABSENT' | tail -1 \
    | sed 's/HBPRESENT/PRESENT/; s/HBABSENT/ABSENT/'
}
# hb_fresh: PRESENT only if the file exists AND its mtime is within $2 seconds. The bridge rewrites
# the heartbeat every loop (~2s), so a running bridge is always fresh; a file left by a PRIOR boot
# is stale. Test-Path alone (the old hb_state) read a STALE heartbeat as "bridge running" - the P8
# hbseen=1 false-fail on a cold boot where legacy-toasts correctly kept the bridge OFF (proven: no
# notifhost console window in that boot's geom). Same base64/-EncodedCommand idiom as path_state so
# the echoed command line can't self-match the markers.
hb_fresh(){ # $1=guest path, $2=max age seconds (default 45)
  local max="${2:-45}" ps b64
  ps="if (Test-Path -LiteralPath '$1') { if ((((Get-Date)-(Get-Item -LiteralPath '$1').LastWriteTime).TotalSeconds) -le $max) { 'HBFRESH' } else { 'HBSTALE' } } else { 'HBGONE' }"
  b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  qrun "powershell -NoProfile -EncodedCommand $b64" | grep -aoE 'HBFRESH|HBSTALE|HBGONE' | tail -1 \
    | sed 's/HBFRESH/PRESENT/; s/HBSTALE/ABSENT/; s/HBGONE/ABSENT/'
}
hb_state(){ hb_fresh "$HBF" 45; }   # PRESENT = heartbeat exists AND fresh (bridge actually running now)

# Fire a toast and CONFIRM it actually fired. fire-demo-toast.ps1 prints a `FIRED ...` line via
# run-as-user; the FIRST run-as-user call right after a COLD boot can silently no-op (Task
# Scheduler / interactive session not yet ready) - it returns no FIRED line and no toast shows
# (measured 2026-09-04: this defeated P2 three times while the DETECTION was fine). So verify the
# FIRED line and retry; the P1d warm-up primes the path so the first TIMED fire is reliable.
fire_raw(){ # $1=extra args to fire-demo-toast.ps1, $2=tag-prefix; echoes output, returns 0 once FIRED seen
  local out i
  for i in 1 2 3 4; do
    out=$(raspush guest/fire-demo-toast.ps1 "$1" "$2$i")
    printf '%s\n' "$out"
    printf '%s' "$out" | grep -qa 'FIRED' && return 0
    sleep 8
  done
  return 1
}
# Every phase call site pipes these to /dev/null and (historically) ignored the exit status, so a
# SILENT NO-OP fire flowed into the detector as "nothing happened" and was misattributed to the
# bridge - P6a graded an UNFIRED toast as "FAIL-CLOSED DEFECT" (audit 2026-09-05). The wrappers now
# LOG loudly on a fire that never confirmed FIRED; `log` writes to results.log via `tee -a "$R"`, so
# the warning survives the call site's `>/dev/null` and lands right before the phase verdict. They
# still return the fire_raw status (0/1) so a caller that wants to gate/skip can check it.
fire_info(){ fire_raw "-Title '$1'" "a0i$RANDOM" || { log "INSTRUMENT: fire_info '$1' never confirmed FIRED after retries - a FAIL below is an instrument miss, NOT bridge behaviour"; return 1; }; }
# PERSISTENT informational toast (scenario=reminder) for WINDOW-PATH detection: the rig's
# whole-desktop capture (geom) is ~59s/call, so a transient ~5s toast is gone before any snapshot
# aligns and its o-r window is never caught. Use fire_info_p where the check is "an o-r window
# mapped" (geom); use fire_info where the check is the bridge.log delivery ack, fwd_count (fast, no window needed).
fire_info_p(){ fire_raw "-Persistent -Title '$1'" "a0p$RANDOM" || { log "INSTRUMENT: fire_info_p '$1' never confirmed FIRED after retries - a FAIL below is an instrument miss, NOT bridge behaviour"; return 1; }; }
fire_ctl(){ fire_raw "-RealChoice -Aumid $CTLAUMID -Title '$1'" "a0c$RANDOM" || { log "INSTRUMENT: fire_ctl '$1' never confirmed FIRED after retries - a FAIL below is an instrument miss, NOT bridge behaviour"; return 1; }; }
# Read the CURRENT ShowBanner state for the PS test AUMID (absent|0|1) - read-only introspection,
# the deciding signal the previous run lacked. P4a: did the warmup earn suppression (=0), making the
# no-banner CORRECT and isolating the forward as the only failure? P8: is a LEFTOVER ShowBanner=0
# from a prior bridge suppressing the legacy toast with no bridge left to restore it (=0, a REAL
# product bug) or did the toast simply take the window path / not fire (=absent)?
showbanner(){ raspush guest/a0-showbanner.ps1 "" "a0sb$RANDOM" | tr -d '\r' | grep -aoE 'SHOWBANNER-NOW=[^ ]+' | tail -1; }
# Clear persistent test toasts from the Notification Center so they do not outlive the phase and
# pollute the next baseline (dismiss-toast.ps1 clears by AppId; default = the PS test AUMID).
dismiss_toasts(){ # $1 = AUMID (optional; default PS test AUMID)
  raspush guest/dismiss-toast.ps1 "${1:+-AppId '$1'}" "a0z$RANDOM" >/dev/null 2>&1
}

# poll for a NEW mapped o-r window vs a baseline id set, name matching $2; returns 0 found
new_or_window(){ # $1=baseline-file $2=name-regex $3=tries(2s each) $4=save-as
  local i cur
  for i in $(seq 1 "$3"); do
    geom > "$OUT/$4.txt"
    cur=$(ors < "$OUT/$4.txt" | grep -iaE "$2" | awk '{print $1}' | sort)
    if [ -n "$cur" ] && ! diff <(echo "$cur") <(sort "$1" | comm -12 - <(echo "$cur")) >/dev/null 2>&1; then
      comm -23 <(echo "$cur") <(sort "$1") | grep -q . && return 0
    fi
    sleep 2
  done
  return 1
}
snap_or(){ # $1=name-regex $2=save-as ; prints matching ids to stdout
  geom > "$OUT/$2.txt"; ors < "$OUT/$2.txt" | grep -iaE "$1" | awk '{print $1}' | sort
}

# The real toast BANNER window title on Win10 is "New notification" (measured in P6a geom). Keep
# only banner-specific tokens; CoreWindow/ShellExperienceHost/ToastHost were speculative and, now
# that ors accepts mapped=0, broad enough to risk matching an unmapped shell lurker.
TOASTRE='notification|demo toast|A0T|toast'
# NO dom0-bubble regex: qtest-geom only lists windows carrying _QUBES_VMNAME == the subject VM,
# so a dom0-native bubble is invisible to it by construction. The old DOMRE also overlapped
# TOASTRE (guest banners are titled "New notification"), so it could only ever match a stray
# GUEST toast - dom0 delivery is proven by the protocol ack instead (see the P2 detector block).
