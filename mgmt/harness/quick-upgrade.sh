#!/bin/bash
# quick-upgrade.sh - FAST package validation via an in-place MSI MajorUpgrade over a QWT-carrying
# golden, delivered the way the field gets it: the RELEASE ISO presented as a CD at boot, and
# install.cmd run FROM THE DISC. Use for one-off "does this package upgrade cleanly" checks; the
# full acceptance protocol still installs clean from win{10,11}-base (mgmt/harness/matrix.sh).
#
#   quick-upgrade.sh <release-iso-or-setup-tree> [subject] [os]
#     <release-iso-or-setup-tree>  qwt-improved-setup.iso (the published artifact), or a setup
#                                  tree with install.cmd + MANIFEST.json + msi/installer.msi at
#                                  its root - a tree is wrapped into an ISO here with the same
#                                  packaging/make-iso.sh CI uses, so the guest still sees a disc
#     [subject]                    churn guest to build (default: <os>-up); RECREATED every run
#     [os]                         win10 | win11 (default: win11)
#   env: RELEASE_COMMIT=<sha>  pin Gate-0 (default: the MANIFEST's own driver_repo_commit)
#        DEADLINE=<s>          install-phase budget (default 1500)
#        QU_OUT=<dir>          evidence root (default $HOME/qwt-quick-upgrade)
#
# WHY THIS IS NOT prime-run.sh ANY MORE (2026-09-06, proven on the rig). The first version of
# this script called prime-run.sh with <os>-qwt as the base. prime-run's install mechanism is
# the ONE-SHOT QubesPrime SYSTEM hook that fires install.cmd on the FIRST LOGON of a PRISTINE
# guest. A golden that was itself built by prime-run has already consumed that hook, so a clone
# of it never re-fires it: install.cmd never ran, the clone kept the golden's binaries, and
# "upgrading" a 4.3.17 golden with a 4.3.18 package left gui-agent = 77c4d69 (the golden's) with
# the install RESULT logging package_version 4.3.17. prime-run is for PRISTINE bases only; it
# cannot upgrade anything.
#
# THE ONE RULE (matrix.sh header): our code enters a guest ONLY from the release package. The
# banned pattern is push_payload (qtest push a tree + run install.cmd from the pushed copy). The
# sanctioned OVER-EXISTING channel - matrix.sh's upgrade/reinstall cells - is the release ISO as
# a CD at boot (qvm-start --cdrom=win-idd-mgmt:<loop>) and <CD>:\install.cmd over qrexec. That
# is exactly what this script does, with the same Gate-0 on the disc (tools/assert-payload.sh),
# the same locate-by-content + provenance check on the disc AS THE GUEST SEES IT, and the same
# run marker so nothing from the golden's own install can be graded as this run's.
#
# THE ORDERING RULE (why the golden is N-1). A MajorUpgrade fires only when the package's
# ProductVersion is STRICTLY GREATER than the installed one. If it is not, install.cmd falls to
# uninstall-first, which is PV-disk gated and REFUSED on a PV-booted guest - i.e. not an upgrade
# and not quick. So an equal-or-older package is refused here, before any guest is touched.
# Refresh the golden whenever the dev line bumps: mgmt/harness/seal-qwt-golden.sh <os> <N-1 tree>.
#
# THE TWO BOOTS. findings/install.md: after an in-place MajorUpgrade the FIRST boot runs on the
# emulated disk and xenvbd re-binds on the SECOND; the running gui-agent.exe swap may also pend
# to a reboot. Grading after one boot grades a half-settled guest, so this script performs two
# real cold boots (shutdown -> start, never a live restart) before it reads anything.
#
# VERIFY = the upgrade actually took, judged on the guest AFTER the second boot, never on a log:
#   1. installed C:\Program Files\Qubes Tools\bin\gui-agent.exe sha256 == the disc's
#      reference/gui-agent.exe (full 64 hex, hashed on the guest NOW), and != the entry hash;
#   2. exactly ONE QWT product registered and its DisplayVersion core == package_version core
#      (a lingering second product means the MajorUpgrade did not remove the old one);
#   3. the installer's own RESULT (sliced after this run's marker): ok:true,
#      upgrade_mode:in-place-msi-major-upgrade, installed_gui_agent_sha256 == the reference;
#   4. gui-agent.exe is running.
# Any miss is a loud FAIL with the subject LEFT RUNNING as evidence (H3.5).
#
# Exits: 0 = upgraded and verified; 1 = TERMINAL/FAIL (verify failed, guest died, clone/boot
# failure - guest left as evidence); 2 = DEADLINE; 3 = REFUSED preconditions (nothing touched).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

PKG="${1:?usage: quick-upgrade.sh <release-iso-or-setup-tree> [subject] [os]}"
OS="${3:-win11}"
SUBJECT="${2:-$OS-up}"
GOLDEN="$OS-qwt"
HOLDER=win-idd-mgmt
DEADLINE="${DEADLINE:-1500}"
GLOG='C:\qwt-improved-install.log'
AGENT_PATH='C:\Program Files\Qubes Tools\bin\gui-agent.exe'
case "$OS" in win10|win11) ;; *) echo "FATAL: os must be win10 or win11 (got '$OS')"; exit 3 ;; esac

OUT="${QU_OUT:-$HOME/qwt-quick-upgrade}/$SUBJECT-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
R="$OUT/quick-upgrade.log"; : > "$R"
log(){ echo "$(date -u +%H:%M:%S) quick-upgrade[$SUBJECT]: $*" | tee -a "$R"; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); log "PASS  $*"; }
no(){ FAIL=$((FAIL+1)); log "FAIL  $*"; }

# --- lifecycle: per-guest lock + orphan-free teardown (run-lib.sh, same as prime-run) -------
source mgmt/harness/vmlock.sh
source mgmt/harness/run-lib.sh
vm_lock "$SUBJECT"
job_init quick-upgrade
job_on_abort(){
  mkdir -p mgmt/fixtures
  printf '{"vm":"%s","aborted_utc":"%s","via":"%s","note":"killed mid-upgrade - CONTAMINATED, never grade or reuse; re-run quick-upgrade to recreate from the golden"}\n' \
      "$SUBJECT" "$(date -u +%FT%TZ)" "$1" > "mgmt/fixtures/$SUBJECT.aborted"
  log "ABORTED ($1): $SUBJECT is CONTAMINATED - marker mgmt/fixtures/$SUBJECT.aborted written; best-effort shutdown"
  qvm-shutdown "$SUBJECT" >/dev/null 2>&1
}
# Wait primitives with failure modes (w_state/w_alive/w_session/w_halt/w_screen) - REUSED, not
# rewritten. They call ./tools/qtest relative to the repo root, which is the cwd here.
source mgmt/harness/e2e-wait.sh

grun(){ QTEST_VM=$SUBJECT timeout -k 5 "${2:-60}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
vercore(){ printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
ver_gt(){ [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }
qstate_of(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$1" '$1==v{print $2}'; }

# The release loop is set up HERE and torn down HERE. It must never be deleted while a guest
# may still hold the CD: the CD is a start-time attach and drops at the guest's first shutdown,
# so the loop is released only once the subject has halted at least once after the CD boot.
LOOP=""; LOOP_MINE=0; CD_BOOTED=0; HALTED_SINCE_CD=0
release_loop(){
  [ "$LOOP_MINE" = 1 ] && [ -n "$LOOP" ] || return 0
  if [ "$CD_BOOTED" = 1 ] && [ "$HALTED_SINCE_CD" = 0 ]; then
    log "  release loop /dev/$LOOP LEFT IN PLACE - the subject may still hold the CD (it has not halted since the CD boot)"
    log "  free it once the guest is down:  udisksctl loop-delete -b /dev/$LOOP"
    return 0
  fi
  udisksctl loop-delete -b "/dev/$LOOP" >/dev/null 2>&1 && log "  release loop /dev/$LOOP deleted" \
    || log "  WARNING: could not delete /dev/$LOOP - free it by hand: udisksctl loop-delete -b /dev/$LOOP"
}
finish(){ # $1=rc $2=message  - every exit goes through here and says which exit it took
  local rc=$1; shift
  release_loop
  log "$*"
  log "summary: $PASS passed, $FAIL failed; evidence in $OUT"
  exit "$rc"
}

# =============================================================================================
# 0. THE PACKAGE -> A DISC, gated (Gate-0) before any guest is touched
# =============================================================================================
ISO=""
if [ -f "$PKG" ]; then
  ISO="$PKG"
  log "package: ISO $ISO"
elif [ -d "$PKG" ]; then
  for f in install.cmd MANIFEST.json SHA256SUMS.txt msi/installer.msi; do
    [ -f "$PKG/$f" ] || finish 3 "REFUSED: setup tree '$PKG' has no $f - not a release setup tree"
  done
  # A tree is wrapped with the SAME script CI uses for the published qwt-improved-iso artifact,
  # so the guest sees the same disc shape (autorun.inf staged into a copy, sums untouched). The
  # ISO lands in the evidence dir: the loop device backs it for the whole run, so it must not be
  # a temp file that disappears.
  tv=$(python3 -c "import json;print(json.load(open('$PKG/MANIFEST.json')).get('package_version',''))" 2>/dev/null)
  ISO="$OUT/qwt-improved-setup-${tv:-unknown}.iso"
  log "package: setup tree $PKG -> wrapping into $ISO (packaging/make-iso.sh, as CI does)"
  ./packaging/make-iso.sh "$PKG" "$ISO" >"$OUT/make-iso.out" 2>&1 \
    || finish 3 "REFUSED: make-iso failed - $(tail -3 "$OUT/make-iso.out" | tr '\n' ' ')"
else
  finish 3 "REFUSED: '$PKG' is neither an ISO file nor a setup tree"
fi
[ -s "$ISO" ] || finish 3 "REFUSED: $ISO is missing or empty"

# Loop-set up read-only via udisksctl (root-free on this rig; findings/install.md) and require
# the backing file to be the intended one and not "(deleted)", or the guest reads a stale disc.
dev=$(udisksctl loop-setup -r -f "$ISO" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
[ -n "$dev" ] || finish 3 "REFUSED: udisksctl loop-setup failed for $ISO"
LOOP=${dev#/dev/}; LOOP_MINE=1
backing=$(losetup -l 2>/dev/null | awk -v d="/dev/$LOOP" '$1==d{print $6}')
[ -n "$backing" ] || finish 3 "REFUSED: /dev/$LOOP is not an active loop device"
case "$backing" in *'(deleted)'*) finish 3 "REFUSED: /dev/$LOOP backing file is DELETED";; esac
log "release ISO on /dev/$LOOP backed by $backing"

# GATE-0 ON THE DISC ITSELF: mount locally, assert-payload (sums + provenance commit + installer
# bytes), read the package facts FROM THE DISC (never from a tree that may differ), unmount.
mnt=$(udisksctl mount --block-device "/dev/$LOOP" 2>/dev/null | sed -n 's/^Mounted .* at //p' | sed 's/\.$//')
[ -n "$mnt" ] || mnt=$(findmnt -no TARGET "/dev/$LOOP" 2>/dev/null | head -1)
[ -n "$mnt" ] || finish 3 "REFUSED: could not mount /dev/$LOOP to verify the disc"
if [ -z "${RELEASE_COMMIT:-}" ]; then
  RELEASE_COMMIT=$(python3 -c "import json;print((json.load(open('$mnt/MANIFEST.json')).get('source') or {}).get('driver_repo_commit') or '')" 2>/dev/null)
  [ -n "$RELEASE_COMMIT" ] && log "RELEASE_COMMIT from the disc MANIFEST: ${RELEASE_COMMIT:0:12} (self-consistency; pass RELEASE_COMMIT=<sha> to pin externally)" \
                           || log "WARNING: RELEASE_COMMIT unset and the MANIFEST names no commit - gating against HEAD"
fi
RELEASE_REF="${RELEASE_COMMIT:-HEAD}"
RELEASE_SHA=$(git rev-parse "$RELEASE_REF" 2>/dev/null)
[ -n "$RELEASE_SHA" ] || { udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1; finish 3 "REFUSED: cannot resolve RELEASE_COMMIT='$RELEASE_REF' in this repo"; }
if ./tools/assert-payload.sh "$mnt" "$RELEASE_REF" >"$OUT/iso-gate0.out" 2>&1; then
  log "Gate-0 (disc): $(tail -1 "$OUT/iso-gate0.out")"
else
  tail -3 "$OUT/iso-gate0.out" | sed 's/^/    /' | tee -a "$R"
  udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1
  finish 3 "REFUSED: Gate-0 FAILED on the disc at /dev/$LOOP"
fi
PV=$(python3 -c "import json;print(json.load(open('$mnt/MANIFEST.json'))['package_version'])" 2>/dev/null)
PVCORE=$(vercore "$PV")
[ -n "$PVCORE" ] || { udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1; finish 3 "REFUSED: disc MANIFEST has no parsable package_version (got '$PV')"; }
# The reference agent binary and its manifest hash must both exist and AGREE (matrix.sh's
# ASHA/MSHA rule): the hash check below is the whole point, and an empty expectation would
# match any build.
[ -s "$mnt/reference/gui-agent.exe" ] || { udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1; finish 3 "REFUSED: disc has no reference/gui-agent.exe - the agent-hash verify would be vacuous"; }
ASHA=$(sha256sum "$mnt/reference/gui-agent.exe" | cut -d' ' -f1)
MSHA=$(python3 -c "import json;print((json.load(open('$mnt/MANIFEST.json')).get('reference_binaries') or {}).get('gui-agent.exe',''))" 2>/dev/null | tr 'A-F' 'a-f')
[ -n "$ASHA" ] && [ "$ASHA" = "$MSHA" ] || { udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1; finish 3 "REFUSED: reference/gui-agent.exe sha ($ASHA) disagrees with MANIFEST reference_binaries ($MSHA)"; }
cp "$mnt/MANIFEST.json" "$OUT/MANIFEST.json" 2>/dev/null
udisksctl unmount --block-device "/dev/$LOOP" >/dev/null 2>&1
findmnt -no TARGET "/dev/$LOOP" >/dev/null 2>&1 && log "  WARNING: /dev/$LOOP still mounted locally after unmount - the attach is read-only, but investigate"
log "package: version $PV (core $PVCORE), agent ${ASHA:0:12}, commit ${RELEASE_SHA:0:12}"

# =============================================================================================
# 1. THE GOLDEN: exists, Halted, sealed and untouched, and strictly OLDER than the package
# =============================================================================================
gstate=$(qstate_of "$GOLDEN")
if [ -z "$gstate" ]; then
  log "golden '$GOLDEN' does not exist. Build it once from the N-1 RELEASE setup tree with:"
  log "  mgmt/harness/seal-qwt-golden.sh $OS <release-N-1-setup-dir>"
  finish 3 "REFUSED: no golden $GOLDEN"
fi
[ "$gstate" = Halted ] || finish 3 "REFUSED: golden '$GOLDEN' is $gstate, must be Halted (it is a clone source, never run it)"
./mgmt/golden.sh verify "$GOLDEN" >"$OUT/golden-verify.out" 2>&1 \
  || { tail -3 "$OUT/golden-verify.out" | sed 's/^/    /' | tee -a "$R"; finish 3 "REFUSED: $GOLDEN failed its seal check (golden.sh verify) - rebuild/re-seal it"; }
log "golden $GOLDEN: $(tail -1 "$OUT/golden-verify.out")"
goldver=$(python3 -c "import json;print(json.load(open('mgmt/fixtures/$GOLDEN.json')).get('sealed_version',''))" 2>/dev/null)
GOLDCORE=$(vercore "$goldver")
if [ -n "$GOLDCORE" ]; then
  ver_gt "$PVCORE" "$GOLDCORE" \
    || finish 3 "REFUSED: package $PVCORE is not strictly newer than golden $GOLDEN's sealed $GOLDCORE - install.cmd would take uninstall-first (PV-disk gated, refused on a PV-booted guest), not a MajorUpgrade. Use a newer package, or re-seal an older golden."
  log "ordering: package $PVCORE > golden $GOLDCORE - in-place MajorUpgrade expected"
else
  log "WARNING: mgmt/fixtures/$GOLDEN.json records no sealed_version - ordering unchecked; the entry-version probe below is the only guard"
fi

# H3.6 - one Windows guest at a time. The SUBJECT is excluded: it is about to be killed and
# recreated, so a leftover from a previous run must not block this one. Everything else refuses.
running=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null \
          | awk -F'|' -v me="$SUBJECT" '$2!="Halted" && $1!=me && $1 ~ /^(win(10|11)|prime-)/ {print $1}' | tr '\n' ' ')
[ -z "${running// /}" ] || finish 3 "REFUSED: these are not Halted: $running"

# =============================================================================================
# 2. THE SUBJECT: self-clean, then create -> TAG -> clone volumes (prime-run's order: a single
#    qvm-clone copies volumes before the tag exists and tag-based policy refuses the call)
# =============================================================================================
sstate=$(qstate_of "$SUBJECT")
if [ -n "$sstate" ]; then
  if [ "$sstate" != Halted ]; then
    # A kill is permitted exactly here: the state is about to be discarded (the volumes are
    # replaced by the clone below), so nothing that matters can be corrupted by it.
    log "leftover $SUBJECT is $sstate - killing it (it is being discarded, not reused)"
    qvm-kill "$SUBJECT" >/dev/null 2>&1
    w_halt "$SUBJECT" 120 "kill-$SUBJECT" log >/dev/null 2>&1 || finish 1 "TERMINAL: leftover $SUBJECT would not halt after qvm-kill"
  fi
  qvm-remove -f "$SUBJECT" >/dev/null 2>&1 || finish 1 "TERMINAL: could not remove leftover $SUBJECT"
  log "leftover $SUBJECT removed"
fi
log "recreating $SUBJECT from $GOLDEN"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$SUBJECT" \
  || finish 1 "TERMINAL: could not create $SUBJECT"
qvm-tags "$SUBJECT" add win-idd-testbed || finish 1 "TERMINAL: could not tag $SUBJECT"
qvm-features "$SUBJECT" os Windows
for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$SUBJECT" "${p%%:*}" "${p##*:}"; done
qvm-prefs "$SUBJECT" netvm '' 2>/dev/null
cerr=$(python3 - "$GOLDEN" "$SUBJECT" 2>&1 <<'PY'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PY
) || finish 1 "TERMINAL: volume clone failed: $(echo "$cerr" | tail -1 | cut -c1-200)"
log "cloned $GOLDEN -> $SUBJECT"
rm -f "mgmt/fixtures/$SUBJECT.aborted" "mgmt/fixtures/$SUBJECT.json"

# =============================================================================================
# 3. BOOT WITH THE DISC (start-time attach - the rig's proven ISO path; live block attach gets
#    "empty response from qubesd" here, see matrix.sh boot_with_release_iso)
# =============================================================================================
log "booting $SUBJECT with the release ISO as CD (qvm-start --cdrom=$HOLDER:$LOOP)"
timeout -k 10 150 qvm-start "$SUBJECT" --cdrom="$HOLDER:$LOOP" >"$OUT/cdboot.out" 2>&1 & disown
CD_BOOTED=1
sleep 8
w_session "$SUBJECT" 900 "cdboot" "$OUT" log
case $? in
  1) finish 1 "TERMINAL: clone reached a terminal state before any session (see $OUT/cdboot*.png; start log $OUT/cdboot.out)" ;;
  2) finish 2 "DEADLINE: clone gave no session within 900 s (start log $OUT/cdboot.out)" ;;
esac

# ENTRY PRECONDITIONS, asserted on the SAME signals the verify uses (experimenter 5b), so that
# "it changed" is decidable afterwards. Missing data fails - never reads as "absent".
qwt_probe(){ # -> "QWTPRODUCTS=<n> QWTVERS=<v1,v2>" (MSI product registrations, the installer's
  # own upgrade-vs-clean signal; the ITL Version key is NOT that signal - matrix.sh qwt_products)
  local a out
  for a in 1 2 3 4 5; do
    out=$(grun "powershell -NoProfile -Command \"\$v=@(); foreach(\$k in @('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*','HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')){foreach(\$p in Get-ItemProperty \$k -ErrorAction SilentlyContinue){if(\$p.DisplayName -like '*Qubes Windows Tools*'){\$v+=[string]\$p.DisplayVersion}}}; Write-Host ('QWTPRODUCTS='+\$v.Count+' QWTVERS='+(\$v -join ','))\"" 60 \
          | grep -aoE 'QWTPRODUCTS=[0-9]+ QWTVERS=[0-9.,]*' | tail -1)
    [ -n "$out" ] && { echo "$out"; return 0; }
    [ "$a" -lt 5 ] && sleep 15
  done
  return 1
}
agent_sha(){ # -> installed gui-agent.exe sha256 (lowercase, 64 hex), hashed ON THE GUEST now
  local a out
  for a in 1 2 3; do
    out=$(grun "cmd /c certutil -hashfile \"$AGENT_PATH\" SHA256" 60 | tr -d ' ' | grep -aoiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    [ -n "$out" ] && { echo "$out"; return 0; }
    [ "$a" -lt 3 ] && sleep 10
  done
  return 1
}
entry=$(qwt_probe) || finish 1 "TERMINAL: INVALID-INSTRUMENT - could not read the QWT product registrations at entry"
ENTRY_N=${entry#QWTPRODUCTS=}; ENTRY_N=${ENTRY_N%% *}; ENTRY_VERS=${entry#*QWTVERS=}
[ "$ENTRY_N" -ge 1 ] 2>/dev/null || finish 1 "TERMINAL: INVALID-PRECONDITION - $SUBJECT carries NO installed QWT (QWTPRODUCTS=$ENTRY_N); $GOLDEN is not a QWT golden"
ENTRY_SHA=$(agent_sha) || finish 1 "TERMINAL: INVALID-INSTRUMENT - could not hash $AGENT_PATH at entry"
log "entry: QWT products=$ENTRY_N versions=$ENTRY_VERS agent=${ENTRY_SHA:0:12}"
# The exact defect this rewrite exists for: with the old prime-run path the "upgraded" guest kept
# the golden's binary. If the golden ALREADY carries the package's agent, nothing this run does
# can be told apart from doing nothing - refuse rather than report a vacuous PASS.
[ "$ENTRY_SHA" != "$ASHA" ] || finish 3 "REFUSED: INVALID-PRECONDITION - $GOLDEN already carries the package's gui-agent (${ASHA:0:12}); an upgrade from it would be unmeasurable"
for v in ${ENTRY_VERS//,/ }; do
  ver_gt "$PVCORE" "$(vercore "$v")" || finish 3 "REFUSED: INVALID-PRECONDITION - entry carries QWT $v, not strictly older than package $PVCORE (would be uninstall-first, not an upgrade)"
done

# LOCATE THE DISC BY CONTENT, never by an assumed letter, and check its provenance AS THE GUEST
# SEES IT - a plausible stale medium has voided a cell before (matrix.sh locate_release_disc).
RELDISC=
for a in 1 2 3 4 5 6; do
  sleep 5
  d=$(grun 'cmd /c for %d in (D E F G H I J K L M N) do @if exist %d:\install.cmd if exist %d:\MANIFEST.json echo RELDISC=%d:' 60 \
      | grep -ao 'RELDISC=[D-N]:' | head -1 | cut -d= -f2)
  [ -n "$d" ] && { RELDISC=$d; break; }
done
[ -n "$RELDISC" ] || finish 1 "TERMINAL: no drive carries install.cmd + MANIFEST.json - the CD did not reach the guest (start log: $OUT/cdboot.out)"
got=$(grun "cmd /c type $RELDISC\\MANIFEST.json" 60 | grep -a 'driver_repo_commit' | grep -ao '[0-9a-f]\{40\}' | head -1)
[ "${got:0:12}" = "${RELEASE_SHA:0:12}" ] || finish 1 "TERMINAL: disc at $RELDISC was built from '${got:-unreadable}', expected ${RELEASE_SHA:0:12} - refusing to install from it"
ok "release disc verified at $RELDISC (driver_repo_commit ${got:0:12})"

# =============================================================================================
# 4. INSTALL FROM THE DISC, and wait for it with three exits
# =============================================================================================
# RUN MARKER, not deletion: the guest log cannot be reliably deleted (boot tasks append to it),
# so a unique marker is appended and ONLY what follows it is graded (matrix.sh run_install).
E2E_MARK="E2EMARK-$(date -u +%Y%m%d%H%M%S)-$$"
grun "cmd /c echo $E2E_MARK >> $GLOG & del /f /q C:\\qwt-install.log 2>nul & echo MARKED" 60 >/dev/null
# SELF-MATCH-SAFE: `qtest run` echoes the prompt line WITH THE COMMAND ON IT, and that line
# contains both PRESENT and ABSENT - a bare `grep | head -1` reads PRESENT off the echo every
# time and can never fail. Strip the echo first, then take the guest's own answer.
seen=$(grun "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT" 60 | _shell_echo_strip | grep -ao 'PRESENT\|ABSENT' | tail -1)
[ "$seen" = PRESENT ] || finish 1 "TERMINAL: could not write the run marker into $GLOG (got '${seen:-no answer}') - this run could not be told apart from the golden's own install"
# Seed the LOCAL cumulative tail with the marker: the installer emits ~120 lines, so the marker
# scrolls out of every 15-line sample and would never reach the tail on its own - the slice
# below then finds nothing and the RESULT exit is unreachable (measured twice in matrix.sh).
echo "$E2E_MARK" >> "$OUT/install.tail"
log "run marker $E2E_MARK"
# No /reboot: the installer then ends with "No reboot from here" and THIS script owns both cold
# boots (deterministic, and the RESULT trailer is on disk before anything restarts).
grun "cmd /c start \"\" /min $RELDISC\\install.cmd /auto /autologon:qubes" 60 >/dev/null
log "install.cmd /auto launched from $RELDISC - waiting (deadline ${DEADLINE}s, stall ${STALL_SECS}s)"

# Exits: RESULT (trailer after the marker) | HALTED (guest rebooted itself) | QUIET (qrexec gone
# - the MSI replaces the agent - and CPU quiet 3 reads in a row, i.e. the install finished) |
# RECOVERY (terminal) | STALLED (no new log lines for STALL_SECS while alive) | DEADLINE.
phase=""; t0=$(date +%s); last=-1; lastchange=$t0; quiet=0; shots=0
while :; do
  sleep 20
  el=$(( $(date +%s) - t0 ))
  st=$(w_state "$SUBJECT")
  if [ "$st" = Halted ]; then log "  t+${el}s guest HALTED (rebooted itself)"; phase=HALTED; break; fi
  if w_alive "$SUBJECT"; then
    quiet=0
    n=$(grun "cmd /c powershell -NoProfile -Command \"if(Test-Path '$GLOG'){(Get-Content '$GLOG').Count}else{0}\"" 90 | grep -aE '^[0-9]+$' | head -1)
    n=${n:-0}
    if [ "$n" -ne "$last" ]; then
      last=$n; lastchange=$(date +%s)
      grun "cmd /c powershell -NoProfile -Command \"if(Test-Path '$GLOG'){Get-Content '$GLOG' -Tail 15}\"" 60 \
        | grep -aE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^=== RESULT ===|^E2EMARK-' >> "$OUT/install.tail" || true
      awk '!seen[$0]++' "$OUT/install.tail" > "$OUT/install.log.tmp" && mv -f "$OUT/install.log.tmp" "$OUT/install.log"
      log "  t+${el}s $n log lines | $(tail -1 "$OUT/install.log" 2>/dev/null | cut -c1-110)"
      if sed -n "/$E2E_MARK/,\$p" "$OUT/install.log" | grep -qa '^=== RESULT === {'; then phase=RESULT; break; fi
    elif [ $(( $(date +%s) - lastchange )) -ge "$STALL_SECS" ]; then
      log "  STALLED - $n log lines unchanged for ${STALL_SECS}s, guest alive, screen=$(w_screen "$SUBJECT" stall "$OUT")"
      phase=STALLED; break
    fi
    grun "cmd /c powershell -NoProfile -Command \"if(Test-Path C:\\qwt-install.log){Get-Content C:\\qwt-install.log -Tail 40}\"" 90 > "$OUT/msi.log.new" || true
    [ -s "$OUT/msi.log.new" ] && mv -f "$OUT/msi.log.new" "$OUT/msi.log" || rm -f "$OUT/msi.log.new"
  else
    # NULL-separated stats stream: newline the separators or values run together (3 -> "31").
    cpu=$(printf '' | timeout 10 qrexec-client-vm "$SUBJECT" admin.vm.Stats 2>/dev/null | tr '\0' '\n' \
          | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print 9999; else print m}')
    if [ "${cpu:-9999}" -lt 15 ] 2>/dev/null; then quiet=$((quiet+1)); else quiet=0; fi
    log "  t+${el}s no qrexec (agent being replaced?) cpu=${cpu} quiet=$quiet"
    # No stall exit here: an unreachable guest is judged by CPU (QUIET), by its screen each
    # minute (RECOVERY) and by the deadline - the log-count clock stopped when qrexec went, so
    # a stall test on it would fire on the MSI's silent window rather than on a real hang.
    if [ "$quiet" -ge 3 ] && [ "$el" -ge 180 ]; then phase=QUIET; break; fi
  fi
  if [ $(( el / 60 )) -gt "$shots" ]; then
    shots=$(( el / 60 ))
    sc=$(w_screen "$SUBJECT" "install-t$el" "$OUT")
    [ "$sc" = RECOVERY ] && { log "  TERMINAL - recovery screen ($OUT/install-t$el.png)"; phase=RECOVERY; break; }
  fi
  [ "$el" -ge "$DEADLINE" ] && { phase=DEADLINE; break; }
done
case "$phase" in
  RESULT)   log "install wrote its RESULT trailer at t+${el}s" ;;
  HALTED)   log "guest halted during the install - its log is read after the boots below" ;;
  QUIET)    log "qrexec gone and CPU quiet - the install has finished working; grading after the boots below" ;;
  RECOVERY) finish 1 "TERMINAL: guest went to the recovery screen during the install - LEFT AS IS (evidence in $OUT)" ;;
  STALLED)  finish 1 "TERMINAL: install STALLED (no progress for ${STALL_SECS}s) - guest LEFT RUNNING as evidence ($OUT)" ;;
  DEADLINE) finish 2 "DEADLINE: ${DEADLINE}s with no install conclusion - guest LEFT RUNNING as evidence ($OUT)" ;;
esac

# =============================================================================================
# 5. TWO REAL COLD BOOTS - boot #1 runs on the emulated disk, boot #2 re-binds xenvbd
#    (findings/install.md); a pending file swap also lands on #1. Never a live restart.
# =============================================================================================
coldboot(){ # $1=n
  local n=$1
  if [ "$(w_state "$SUBJECT")" != Halted ]; then
    qvm-shutdown "$SUBJECT" >/dev/null 2>&1
    if ! w_halt "$SUBJECT" 420 "boot$n-halt" log; then
      log "  guest ignored ACPI shutdown for 420 s (screen=$(w_screen "$SUBJECT" "boot$n-stuck" "$OUT")) - killing as the last resort"
      qvm-kill "$SUBJECT" >/dev/null 2>&1
      w_halt "$SUBJECT" 120 "boot$n-kill" log >/dev/null 2>&1 || finish 1 "TERMINAL: $SUBJECT would not halt for cold boot #$n"
    fi
  fi
  HALTED_SINCE_CD=1
  # Fire-and-poll (qvm-start blocks until qrexec connects, which on a dead guest is silence for
  # the whole qrexec_timeout). No --cdrom: the disc is done with.
  timeout -k 10 150 qvm-start "$SUBJECT" >"$OUT/boot$n.out" 2>&1 & disown
  sleep 8
  w_session "$SUBJECT" 900 "boot$n" "$OUT" log
  case $? in
    1) finish 1 "TERMINAL: cold boot #$n reached a terminal state (BRICKED after upgrade?) - LEFT AS IS, see $OUT/boot$n*.png" ;;
    2) finish 2 "DEADLINE: cold boot #$n gave no session in 900 s - guest LEFT AS IS ($OUT)" ;;
  esac
  log "cold boot #$n: session up"
}
coldboot 1
coldboot 2

# =============================================================================================
# 6. VERIFY - on the guest, after the second boot. Missing data fails.
# =============================================================================================
# The CD is a start-time attach and dropped at boot #1's shutdown; the detach verb is exercised
# best-effort like matrix.sh detach_release_iso (block `list` is policy-refused, so it cannot be
# checked - a refusal here is harmless and says so).
qvm-device block detach "$SUBJECT" "$HOLDER:$LOOP" >/dev/null 2>&1 \
  && log "release ISO detached" || log "release ISO detach refused/no-op (the start-time attach dropped at the first shutdown)"

# (a) installer's own RESULT, sliced after THIS run's marker, from the FULL log
grun "cmd /c type \"$GLOG\"" 120 | _shell_echo_strip > "$OUT/final.log"
if grep -qa "$E2E_MARK" "$OUT/final.log"; then sed -n "/$E2E_MARK/,\$p" "$OUT/final.log" > "$OUT/final.cur"; else : > "$OUT/final.cur"; fi
j=$(grep -a '^=== RESULT === {' "$OUT/final.cur" | tail -1)
if [ -z "$j" ]; then
  no "no installer RESULT trailer after the run marker - INVALID-INSTRUMENT (the install never concluded, or the log was not readable)"
else
  log "RESULT: $(echo "$j" | cut -c1-300)"
  echo "$j" | grep -qa '"ok":true' && ok "installer reports ok:true" || no "installer reports ok:false - $(echo "$j" | grep -ao '"error":"[^"]*"' | head -1)"
  um=$(echo "$j" | grep -ao '"upgrade_mode":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ "$um" = in-place-msi-major-upgrade ] && ok "installer branch = $um" || no "installer branch = '${um:-none}', expected in-place-msi-major-upgrade (INVALID-PRECONDITION if uninstall-first/reinstall)"
  rpv=$(echo "$j" | grep -ao '"package_version":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$rpv" ]; then
    [ "$(vercore "$rpv")" = "$PVCORE" ] && ok "RESULT package_version $rpv is the package under test" \
      || no "RESULT package_version is '$rpv', expected $PVCORE - the installer that ran was NOT this package's"
  else
    log "  (RESULT carries no package_version field - version judged by DisplayVersion below)"
  fi
  echo "$j" | grep -qa "\"installed_gui_agent_sha256\":\"$ASHA\"" && ok "RESULT installed_gui_agent_sha256 == reference ${ASHA:0:12}" \
    || no "RESULT installed_gui_agent_sha256 != reference ${ASHA:0:12} ($(echo "$j" | grep -ao '"installed_gui_agent_sha256":"[^"]*"' | head -1))"
fi

# (b) THE LOAD-BEARING CHECK: the binary on disk NOW (after two boots) is the package's
now_sha=$(agent_sha)
if [ -z "$now_sha" ]; then
  no "could not hash $AGENT_PATH after the upgrade - INVALID-INSTRUMENT (agent missing?)"
elif [ "$now_sha" = "$ASHA" ]; then
  ok "installed gui-agent.exe == package reference/gui-agent.exe ($ASHA)"
else
  no "installed gui-agent.exe is $now_sha, package reference is $ASHA - WRONGBUILD (entry was $ENTRY_SHA$([ "$now_sha" = "$ENTRY_SHA" ] && echo ' - UNCHANGED, the install did not deliver the agent'))"
fi

# (c) DisplayVersion bumped, and the old product is gone
after=$(qwt_probe)
if [ -z "$after" ]; then
  no "could not read the QWT product registrations after the upgrade - INVALID-INSTRUMENT"
else
  AFTER_N=${after#QWTPRODUCTS=}; AFTER_N=${AFTER_N%% *}; AFTER_VERS=${after#*QWTVERS=}
  log "after: QWT products=$AFTER_N versions=$AFTER_VERS (entry: $ENTRY_N / $ENTRY_VERS)"
  [ "$AFTER_N" = 1 ] && ok "exactly one QWT product registered" || no "$AFTER_N QWT products registered after a MajorUpgrade (old product not removed, or none)"
  [ "$(vercore "$AFTER_VERS")" = "$PVCORE" ] && ok "DisplayVersion $AFTER_VERS == package $PVCORE" || no "DisplayVersion is '$AFTER_VERS', expected $PVCORE (entry was $ENTRY_VERS)"
fi

# (d) the upgraded agent is actually running (installed-but-dead is the classic silent failure)
if grun 'cmd /c tasklist /fi "imagename eq gui-agent.exe" /nh' 60 | _shell_echo_strip | grep -qa 'gui-agent\.exe'; then
  ok "gui-agent.exe is running"
else
  no "gui-agent.exe is NOT running after boot #2"
fi

# Evidence: the guest's windows as dom0 sees them (the pixels are the judge for anything beyond
# this script's claims), the MSI log tail, the sliced install log - all already in $OUT.
QTEST_VM=$SUBJECT timeout -k 5 90 ./tools/qtest shot "$OUT/screen.tar" >/dev/null 2>&1 \
  && tar -xf "$OUT/screen.tar" -C "$OUT" 2>/dev/null
grun 'cmd /c powershell -NoProfile -Command "if(Test-Path C:\qwt-install.log){Get-Content C:\qwt-install.log -Tail 60}"' 90 > "$OUT/msi-final.log" 2>/dev/null

if [ "$FAIL" -eq 0 ]; then
  # Fixture receipt (golden.sh fixture re-checks the base's seal later), same shape prime-run writes.
  mkdir -p mgmt/fixtures
  python3 - "$SUBJECT" "$GOLDEN" "$OUT" "$PV" "$ASHA" > "mgmt/fixtures/$SUBJECT.json" <<'PY'
import json, os, subprocess, sys
vm, base, out, pv, asha = sys.argv[1:6]
seal = f"mgmt/goldens/{base}.json"
print(json.dumps({
    "vm": vm, "base": base,
    "base_sealed_utc": json.load(open(seal))["sealed_utc"] if os.path.exists(seal) else None,
    "job": "quick-upgrade", "flags": [], "package_version": pv, "gui_agent_sha256": asha,
    "evidence": os.path.basename(out),
    "built_utc": subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], capture_output=True, text=True).stdout.strip(),
}, indent=2, sort_keys=True))
PY
  finish 0 "OK: $SUBJECT upgraded $ENTRY_VERS -> $PV from the release disc and verified (agent ${ASHA:0:12}); guest left RUNNING, fixture record mgmt/fixtures/$SUBJECT.json"
fi
finish 1 "FAIL: the upgrade did NOT verify ($FAIL check(s) failed) - $SUBJECT LEFT RUNNING as evidence; read $OUT/quick-upgrade.log, final.cur, msi-final.log and the PNGs"
