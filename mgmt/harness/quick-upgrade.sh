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
#        SKEW_CLOCK_HOURS=<n>  TEST INJECTION: push the guest clock n hours back right before
#                              the launch, to exercise the installer's clock refusal. 0 = off.
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

# --stage-to-c: run install.cmd from a COPY on C: instead of from the disc. It is the single
# variable of mgmt/harness/stall-ab.sh, which tests the ranked stall hypothesis (Jev 2026-09-22,
# `medium-pulled-from-reader` 0.56): that the installer's own medium is pulled from under it while
# the PV storage path is replaced. The disc stays attached in both arms - only WHO READS IT changes.
STAGE_TO_C=0
_args=(); for _a in "$@"; do case "$_a" in --stage-to-c) STAGE_TO_C=1 ;; *) _args+=("$_a") ;; esac; done
set -- ${_args+"${_args[@]}"}
PKG="${1:?usage: quick-upgrade.sh <release-iso-or-setup-tree> [subject] [os] [--stage-to-c]}"
OS="${3:?usage: $0 <iso> <subject> <win10|win11> - name the OS family; it selects the golden and there is no default target}"
SUBJECT="${2:-$OS-up}"
GOLDEN="$OS-qwt"
HOLDER=win-idd-mgmt
DEADLINE="${DEADLINE:-1500}"
GLOG='C:\qwt-improved-install.log'
AGENT_PATH='C:\Program Files\Qubes Tools\bin\gui-agent.exe'
# $OS only names the golden ($OS-qwt) and the default subject ($OS-up). The real gate is
# downstream and is strictly stronger than a name whitelist: the golden must EXIST, be
# Halted, and pass golden.sh verify. The old `win10|win11` whitelist therefore blocked
# perfectly good goldens for no safety gain - measured 2026-09-20, when it refused
# win11de-qwt (the sealed German 25H2 golden, which verifies intact) and so left the one
# environment a registered field report must be re-tested on with no upgrade path at all.
case "$OS" in win[0-9]*) ;; *) echo "FATAL: os must look like win<version> (got '$OS'); the golden \"$OS-qwt\" must exist and pass its seal check"; exit 3 ;; esac

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
# TIMEZONE. Without it libvirt's clock offset defaults to utc, so the emulated RTC holds TRUE UTC
# while Windows (RealTimeIsUniversal unset, as every image here is) reads it as LOCAL - and the
# guest computes a UTC behind real UTC by its own timezone offset. Measured 2026-09-25: the German
# subject sat 2 h behind, the CI-minted xenvif catalog was therefore not-yet-valid (0x800B0101),
# and drvinst blocked for 25 minutes. The golden it was cloned from had timezone=localtime all
# along; this create path copied the VOLUMES and not the features, so the subject differed from
# its own golden in exactly the variable that decides the failure.
qvm-features "$SUBJECT" timezone "$(qvm-features "$GOLDEN" timezone 2>/dev/null || echo localtime)"
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
# A START THAT FAILED IS NOT A DARK BOOT. Measured 2026-09-20: qvm-start returned
# "libxenlight failed to create new domain" into cdboot.out immediately, and because nothing
# read that file the session watcher below went on reporting "dark #1 ... dark #2 ... screen=
# NOWINDOW" for 190 s and would have burned its full 900 s deadline before saying anything
# useful. The error was sitting in the harness's own evidence directory the whole time.
# Surface it the moment it appears; the domain is not coming up and waiting cannot help.
for _i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if grep -qiE 'Start failed|failed to create new domain|Domain .* already (running|exists)' "$OUT/cdboot.out" 2>/dev/null; then
    sed 's/^/    /' "$OUT/cdboot.out" | head -5 | tee -a "$R"
    finish 1 "TERMINAL: qvm-start refused to create the domain - this is a HOST-side failure, not a dark boot (see $OUT/cdboot.out)"
  fi
  [ "$(qstate_of "$SUBJECT")" = Halted ] || break   # it came up; hand over to the session watcher
done
CD_BOOTED=1
sleep 8
w_session "$SUBJECT" 900 "cdboot" "$OUT" log
case $? in
  1) finish 1 "TERMINAL: clone reached a terminal state before any session (see $OUT/cdboot*.png; start log $OUT/cdboot.out)" ;;
  2) finish 2 "DEADLINE: clone gave no session within 900 s (start log $OUT/cdboot.out)" ;;
esac

# CLOCK, BEFORE ANYTHING IS INSTALLED. Windows with RealTimeIsUniversal unset reads the hardware
# clock as LOCAL time, so guest_UTC = RTC_content - guest_TZ_offset. What the RTC holds depends on
# the qube's `timezone` feature, and the branches have opposite signs (both measured 2026-09-25):
# localtime -> RTC is dom0 local -> dom0_off - guest_off; UNSET -> RTC is true UTC -> -guest_off.
# Only the UNSET branch puts a guest BEHIND real UTC, which is what makes a CI-minted catalog
# not-yet-valid. Measured that day on the German 25H2 subject (guest +2, feature unset): 2 h
# behind, the xenvif catalog rejected as NOT YET VALID (setupapi.dev.log, 0x800B0101), drvinst at
# 0.125 s of CPU until this harness's 1500 s deadline fired.
#
# THE ROOT CAUSE WAS THIS SCRIPT: the create path above set only `os Windows` and cloned the
# VOLUMES, so the subject never inherited the golden's timezone=localtime and differed from its
# own golden in exactly the variable that decides the failure. That is fixed at the create path;
# this sync stays as the belt, because a right clock is cheap to assert and a wrong one costs 25
# silent minutes. An earlier version of this comment stated the UNSET branch as the whole
# mechanism, which is wrong - a guest with timezone=localtime is AHEAD and cannot trip it.
# It stayed invisible for six weeks because the English images pin TimeZone=UTC, where guest_off
# is 0 and no branch can put the guest behind its own certificates.
#
# qtest synctime has existed since 2026-08-11 with "call this after every VM start" in its own
# comment and had NO callers. This is the caller. The installer now also refuses a package its
# clock says is not yet valid, so a skew here fails fast and named instead of hanging - but the
# harness should not be handing it a broken clock in the first place.
if QTEST_VM="$SUBJECT" "$HERE/tools/qtest" synctime >/dev/null 2>&1; then
  log "guest clock synced to this qube before install (see findings/issues.md: 0x800B0101 skew)"
else
  log "WARNING: could not sync the guest clock - a driver catalog may be refused as not-yet-valid" 
fi

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

if [ "$STAGE_TO_C" = 1 ]; then
  # The tree goes to C: and install.cmd is run from THERE. Asserted, not assumed: a partial copy
  # would make this arm fail for a reason that has nothing to do with the hypothesis.
  grun "cmd /c rmdir /s /q C:\\qwtstage 2>nul & mkdir C:\\qwtstage & xcopy /e /i /y $RELDISC\\* C:\\qwtstage\\" 300 >/dev/null
  _n=$(grun 'cmd /c dir /s /b C:\qwtstage | find /c ":"' 60 | grep -ao '[0-9]\+' | tail -1)
  _have=$(grun 'cmd /c if exist C:\qwtstage\install.cmd echo STAGED' 60 | grep -ao STAGED | head -1)
  [ "$_have" = STAGED ] || finish 1 "TERMINAL: --stage-to-c copied no install.cmd to C:\qwtstage (files seen: ${_n:-0})"
  log "staged to C:\qwtstage (${_n:-?} files) - install.cmd will run from C:, the disc stays attached but unread"
  RELDISC='C:\qwtstage'
fi

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
# RETRY WHILE THE GUEST IS EXECUTING. A silent guest is not a dead one: on 2026-09-14 this line
# got 'no answer' and killed the run as TERMINAL while the guest measured cpu_time +66935 / 20 s -
# busy, mid-upgrade - and that took BOTH feature tests down with it (crop-before-map then reported
# "no gui-agent log" against a guest whose upgrade had been abandoned). Same defect as the install
# watcher's 300 s rule, fixed in eef3c5b: a timeout is not a failure until cpu_time is FLAT.
if [ "$seen" != PRESENT ]; then
  for _mtry in 1 2 3 4 5 6; do
    if w_cpu_moving "$SUBJECT" 15; then
      say "  run marker: no answer yet, but the guest IS EXECUTING (cpu_time moving) - retry $_mtry/6"
    else
      say "  run marker: no answer and cpu_time FLAT - the guest is not executing"
      break
    fi
    grun "cmd /c echo $E2E_MARK >> $GLOG & echo MARKED" 60 >/dev/null
    seen=$(grun "cmd /c findstr /c:\"$E2E_MARK\" $GLOG >nul 2>&1 && echo PRESENT || echo ABSENT" 60 | _shell_echo_strip | grep -ao 'PRESENT\|ABSENT' | tail -1)
    [ "$seen" = PRESENT ] && { say "  run marker: written on retry $_mtry"; break; }
  done
fi
[ "$seen" = PRESENT ] || finish 1 "TERMINAL: could not write the run marker into $GLOG (got '${seen:-no answer}') - this run could not be told apart from the golden's own install"
# Seed the LOCAL cumulative tail with the marker: the installer emits ~120 lines, so the marker
# scrolls out of every 15-line sample and would never reach the tail on its own - the slice
# below then finds nothing and the RESULT exit is unreachable (measured twice in matrix.sh).
echo "$E2E_MARK" >> "$OUT/install.tail"
log "run marker $E2E_MARK"
# No /reboot: the installer then ends with "No reboot from here" and THIS script owns both cold
# boots (deterministic, and the RESULT trailer is on disk before anything restarts).
# ARM THE MODULE-BASE RECORDER FIRST. Measured 2026-09-22: this harness stalled mid-install
# (qrexec dead 358 s, two vCPUs spinning), dom0's debug-keys capture DID produce guest RIPs - and
# they were UNRESOLVABLE, because Windows re-randomises module bases every boot and no table had
# been recorded for THAT boot. matrix.sh has armed this before every install since 2026-09-10;
# this harness never did, and it is where the stall actually recurs. A raw RIP nobody can resolve
# is the same as no capture at all.
# THE ENTRY CONFIGURATION, captured before the install touches anything. A machine-built matrix
# over all 35 surviving run logs could not tell the stalled run from the 33 clean ones - every
# recorded field was constant (Jev: corpus_can_discriminate 0.08, necessary_candidate=
# nothing-in-this-corpus 0.85, what_to_record=guest-config-snapshot 1.00). Without this, the next
# occurrence is as incomparable as the last one. Non-fatal: a snapshot that fails is logged, not
# treated as a reason to abandon the run.
# STALL_REPRO=1 marks a pass whose purpose is to reproduce a recorded failure. Such a pass is
# gated: if the candidate differs from the reference on a dimension the reference actually
# recorded, it is ABORTED rather than spent (owner, 2026-09-22 - 49 attempts were spent without
# anyone checking). The gate also records how faithful the pass can claim to be at all.
if [ "${STALL_REPRO:-0}" = 1 ]; then
  if ./mgmt/harness/stall-repro-gate.sh "$SUBJECT" "$OUT" "${STALL_REF:-mgmt/reference/stall-20260922.json}" "${STALL_REPRO_INVOKED_BY:-a bare quick-upgrade, not through any feature test}" \
       "$(printf '{"golden":"%s","entry_qwt":"%s","entry_agent":"%s","package":"%s","read_from":"%s","cd_boot":true,"subject":"%s"}' \
          "$GOLDEN" "${ENTRY_VERS:-unknown}" "${ENTRY_SHA:0:12}" "${PV:-unknown}" "$RELDISC" "$SUBJECT")" >>"$OUT/stall-gate.log" 2>&1; then
    log "stall-repro gate: PASS MAY RUN - $(cat "$OUT/REPRO-FIDELITY.txt" 2>/dev/null)"
  else
    grc=$?
    log "stall-repro gate REFUSED (rc=$grc): $(tail -2 "$OUT/stall-gate.log" | tr '\n' ' ')"
    finish 3 "REFUSED: this pass is not the reference situation - correct it instead of spending the run (see $OUT/stall-gate.log)"
  fi
fi

./tools/guest-config-snapshot.sh "$SUBJECT" "$OUT" entry >>"$OUT/snapshot.log" 2>&1 \
  && log "entry guest-config snapshot: $OUT/guest-config-entry.txt" \
  || log "WARNING: entry guest-config snapshot failed - see $OUT/snapshot.log (the run continues)"

if VM="$SUBJECT" OUT="$OUT/modbases" ./mgmt/harness/arm-module-bases.sh >>"$OUT/armlog.txt" 2>&1; then
  log "module-base recorder armed BEFORE the install (a stall's RIP will resolve to driver+offset)"
else
  log "WARNING: module-base recorder NOT armed - a stall here would leave a raw, unresolvable RIP"
fi
# THIS LINE USED TO LIE. It printed "install.cmd launched" unconditionally, so a run where the
# guest stopped answering DURING the launch call read as a run where the installer was working -
# which is exactly how the 2026-09-22 stall was mis-framed all day as a PV-driver-replacement hang,
# and how 16 A/B runs and 33 aging cycles came to test a premise the evidence never supported.
# The launch call's own outcome is now stated, because "the call returned" and "the call timed out"
# are different facts about different failures.
# ---- DELIBERATE CLOCK SKEW (test injection, OFF by default) -------------------------------
# SKEW_CLOCK_HOURS=<n> pushes the guest's clock n hours BACKWARDS immediately before the launch,
# to exercise the installer's refusal path on purpose. It exists because the sync above means the
# healthy path will never reach that refusal again: a guard that is only ever run on the good path
# is a guard nobody has seen work (Jev, 2026-09-25: deploy the clock gate, but
# "build-and-deploy-but-force-the-refusal", 0.92).
#
# It is an INJECTION and it is switchable, per the experimenter rule: 0/unset runs the control.
# The guest's own clock is read before and after, so the injection is timestamped by the same
# clock the code under test consults - a previous campaign was voided by an injection timestamped
# on the wrong clock and fired before the code under test even started.
if [ "${SKEW_CLOCK_HOURS:-0}" != "0" ]; then
  _before=$(grun "powershell -NoProfile -Command \"[DateTime]::UtcNow.ToString('o')\"" 60 | tr -d '\r' | grep -aoE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | tail -1)
  grun "powershell -NoProfile -Command \"Set-Date (Get-Date).AddHours(-${SKEW_CLOCK_HOURS})\"" 60 >/dev/null
  _after=$(grun "powershell -NoProfile -Command \"[DateTime]::UtcNow.ToString('o')\"" 60 | tr -d '\r' | grep -aoE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | tail -1)
  if [ -z "$_before" ] || [ -z "$_after" ] || [ "$_before" = "$_after" ]; then
    finish 3 "REFUSED: SKEW_CLOCK_HOURS=$SKEW_CLOCK_HOURS was requested but the guest clock did not move (before='$_before' after='$_after') - the cell would have measured the HEALTHY path and called it the skewed one"
  fi
  log "INJECTED clock skew -${SKEW_CLOCK_HOURS}h: guest UTC $_before -> $_after (this cell tests the REFUSAL path)"
  echo "SKEW_INJECTED hours=$SKEW_CLOCK_HOURS before=$_before after=$_after" > "$OUT/clock-skew-injection.txt"
fi

_lt0=$(date +%s)
grun "cmd /c start \"\" /min $RELDISC\\install.cmd /auto /autologon:qubes" 60 >/dev/null
_lrc=$?
_lel=$(( $(date +%s) - _lt0 ))
if [ "$_lrc" = 0 ]; then
  log "install.cmd /auto launch call RETURNED in ${_lel}s from $RELDISC - the guest was answering when it did (deadline ${DEADLINE}s, stall ${STALL_SECS}s)"
else
  log "install.cmd /auto launch call DID NOT RETURN (rc=$_lrc after ${_lel}s) from $RELDISC - the guest stopped answering DURING the launch; NOTHING about whether the installer ran is inferable from here (deadline ${DEADLINE}s, stall ${STALL_SECS}s)"
fi

# Exits: RESULT (trailer after the marker) | HALTED (guest rebooted itself) | RECOVERY (terminal)
# | STALLED (no new log lines for STALL_SECS while alive, OR qrexec unanswering for STALL_SECS)
# | DEADLINE.
# There is deliberately NO "QUIET" exit (audit 2026-09-08, finding at the old line 373). It used
# to read "qrexec gone + CPU < 15 for 3 reads" as "the install finished" and went straight into
# the cold boots. That state is indistinguishable from an installer parked on a modal inside
# msiexec (driver-trust prompt, a reboot prompt that slipped the suppressor, a PnP dialog): CPU
# idle, qrexec down, nobody clicking - Install-QwtImproved.ps1 documents exactly that case
# (27.9 min idle on a 'Windows Security' prompt). Rebooting there is the mid-install restart the
# installer spends hundreds of lines avoiding, the post-boot grading then blames the instrument
# (no RESULT trailer -> INVALID-INSTRUMENT) and the dialog - the evidence - is gone. Measured on
# this rig (11/11 upgrade runs, 2026-09-06..08): qrexec drops for ~60 s while the MSI replaces
# the agent and COMES BACK on its own, and the RESULT trailer is then read over it - so the
# positive-evidence exit is the real completion path and QUIET never fired. CPU is now logged
# only; a guest that stays unreachable for STALL_SECS is a STALL with the guest LEFT RUNNING.
phase=""; t0=$(date +%s); last=-1; lastchange=$t0; lastalive=$t0; quiet=0; shots=0
while :; do
  sleep 20
  el=$(( $(date +%s) - t0 ))
  st=$(w_state "$SUBJECT")
  if [ "$st" = Halted ]; then log "  t+${el}s guest HALTED (rebooted itself)"; phase=HALTED; break; fi
  if w_alive "$SUBJECT"; then
    quiet=0; lastalive=$(date +%s)
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
      # A QUIET LOG IS NOT A DEAD GUEST. Gating is sound on THIS branch and only here: it runs
      # under w_alive, so the guest ANSWERS qrexec and "executing" genuinely means working - a
      # spin-wedged guest answers nothing (see the unreachable branch below, which must NOT gate).
      # Without this, a long silent MSI phase is reported as a wedge. DEADLINE still bounds the
      # loop, so resetting the stall clock cannot hang here.
      cs=$(w_cpu_state "$SUBJECT" 20)
      case "${cs%% *}" in
        FLAT)
          log "  STALLED - $n log lines unchanged for ${STALL_SECS}s AND cpu_time FLAT over the sample, guest alive, screen=$(w_screen "$SUBJECT" stall "$OUT")"
          phase=STALLED; break ;;
        MOVING)
          log "  t+${el}s $n log lines unchanged for ${STALL_SECS}s, qrexec answers and cpu_time ADVANCED ${cs#* } - working, not stalled; clock reset"
          lastchange=$(date +%s) ;;
        *)
          # Not a measurement. Must not manufacture a stall, must not be logged as one either.
          log "  t+${el}s $n log lines unchanged for ${STALL_SECS}s; qrexec answers but cpu_time UNREADABLE - not proven stopped, so not called a stall; clock reset"
          lastchange=$(date +%s) ;;
      esac
    fi
    grun "cmd /c powershell -NoProfile -Command \"if(Test-Path C:\\qwt-install.log){Get-Content C:\\qwt-install.log -Tail 40}\"" 90 > "$OUT/msi.log.new" || true
    [ -s "$OUT/msi.log.new" ] && mv -f "$OUT/msi.log.new" "$OUT/msi.log" || rm -f "$OUT/msi.log.new"
  else
    # NULL-separated stats stream: newline the separators or values run together (3 -> "31").
    cpu=$(printf '' | timeout 10 qrexec-client-vm "$SUBJECT" admin.vm.Stats 2>/dev/null | tr '\0' '\n' \
          | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print 9999; else print m}')
    if [ "${cpu:-9999}" -lt 15 ] 2>/dev/null; then quiet=$((quiet+1)); else quiet=0; fi
    unreach=$(( $(date +%s) - lastalive ))
    # cpu/quiet are LOGGING AIDS ONLY - never an exit (see the block comment above the loop).
    log "  t+${el}s no qrexec for ${unreach}s (cause UNKNOWN - this sampler cannot see why) cpu=${cpu} quiet=$quiet"
    # The stall clock for an unreachable guest runs from the last qrexec ANSWER, not from the
    # last log-line change, so it cannot fire on the MSI's ~60 s silent window (STALL_SECS is
    # 300 by default); the same rule w_install applies for matrix.sh. A guest that answers
    # nothing for that long is left RUNNING as evidence - the modal, if that is what it is, is
    # still on its screen and its msiexec log tail is still in $OUT/msi.log.
    if [ "$unreach" -ge "$STALL_SECS" ]; then
      sc=$(w_screen "$SUBJECT" "unreachable-stall" "$OUT")
      # RECOVERY first: that screen is terminal however much CPU the guest burns behind it.
      [ "$sc" = RECOVERY ] && { log "  RECOVERY screen after ${unreach}s unreachable"; phase=RECOVERY; break; }
      # cpu_time CLASSIFIES this stall; it must never SUPPRESS it. The first version of this block
      # reset the clock whenever cpu_time moved, which is INVERTED against the defect it was meant
      # to help with: issues.md P1 records "AT LEAST ONE vCPU BURNING 88-101% OF A CORE sustained"
      # as the 8/8 invariant across every captured wedge. A spinning vCPU moves domain cpu_time, so
      # every known specimen would have been logged "not a stall" and run to DEADLINE (1500 s)
      # instead of being called at STALL_SECS (300 s). Caught in review before it met a real wedge.
      #
      # The reachable branch above may gate, because there the guest ANSWERS qrexec so "executing"
      # means working. HERE it answers nothing, and dead qrexec + burning CPU IS the fingerprint.
      # (cpu_usage_raw, read above, cannot help either way: it comes back EMPTY on this rig, which
      # is why it is a logging aid only.)
      cs=$(w_cpu_state "$SUBJECT" 20)
      case "${cs%% *}" in
        FLAT)   log "  STALLED (FROZEN) - qrexec unanswering ${unreach}s AND cpu_time FLAT over the sample: the domain is NOT EXECUTING (cpu=${cpu} quiet=$quiet), screen=$sc" ;;
        MOVING) log "  STALLED (SPINNING) - qrexec unanswering ${unreach}s while cpu_time ADVANCED ${cs#* } over the sample: dead qrexec + burning CPU is the issues.md P1 fingerprint (cpu=${cpu} quiet=$quiet), screen=$sc" ;;
        *)      log "  STALLED - qrexec unanswering ${unreach}s; cpu_time UNREADABLE, so executing-or-not is UNMEASURED (cpu=${cpu} quiet=$quiet), screen=$sc" ;;
      esac
      # CAPTURE IT NOW, while the guest is still up and before anything reclones it. On
      # 2026-09-23 a wedge caught inside an acceptance campaign survived only because a human
      # stopped the campaign within minutes; an unattended run has no such human. Only on the
      # SPIN fingerprint - a frozen domain has nothing to image, and an image is ~8.6 GB.
      if [ "${cs%% *}" = MOVING ]; then
        log "  capturing the specimen automatically (dom0 forensics, then a memory image)"
        timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$SUBJECT" </dev/null \
          > "$OUT/forensics.tar" 2>"$OUT/forensics.err" \
          && log "    forensics -> $OUT/forensics.tar" \
          || log "    WARNING: dom0 forensics capture failed - see $OUT/forensics.err"
        if bash mgmt/harness/fetch-wedge-core.sh "$SUBJECT" "$OUT/guest.core" >>"$OUT/core.log" 2>&1; then
          log "    memory image -> $OUT/guest.core"
          log "    name the code: tools/core-module-list.py $OUT/guest.core --contains 0x<rip>"
        else
          log "    memory image NOT taken (see $OUT/core.log) - the forensics above still stand"
        fi
      fi
      phase=STALLED; break
    fi
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
  RECOVERY) finish 1 "TERMINAL: guest went to the recovery screen during the install - LEFT AS IS (evidence in $OUT)" ;;
  STALLED)  finish 1 "TERMINAL: install STALLED (no progress or no qrexec answer for ${STALL_SECS}s) - guest LEFT RUNNING as evidence ($OUT); NOT rebooted: a parked modal would look exactly like this" ;;
  DEADLINE) finish 2 "DEADLINE: ${DEADLINE}s with no install conclusion - guest LEFT RUNNING as evidence ($OUT)" ;;
esac

# Only when the install actually concluded with a RESULT is there a complete log to keep.
if [ "$phase" = RESULT ]; then
  # PRESERVE THE MSI VERBOSE LOG, WHOLE. The installer already runs msiexec with /l*v! to
  # C:\qwt-install.log; this harness kept only a 40-line TAIL, so no run here contains a single
  # DIFXAPP line - measured 2026-09-22 across 18 runs. That turned a comparison against matrix's
  # upgrade cells (where the DIFx "uninstall phase required a reboot" warning appears in 2 of 2)
  # into MISSING DATA rather than a difference. Same fetch matrix.sh uses: encoded (escaped quotes
  # inside -Command fail silently) and boundary-marked, so a truncated transfer is detectable and
  # "no log" is distinguishable from broken quoting.
  _msips=$(printf '%s\n' \
    "\$ErrorActionPreference='Stop'" \
    "if (Test-Path 'C:/qwt-install.log') {" \
    "  Write-Host 'MSIB64BEGIN'" \
    "  Write-Host ([Convert]::ToBase64String([IO.File]::ReadAllBytes('C:/qwt-install.log')))" \
    "  Write-Host 'MSIB64END'" \
    "} else { Write-Host 'MSIB64ABSENT' }")
  _b64=$(printf '%s' "$_msips" | python3 -c "import sys,base64;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
  QTEST_VM=$SUBJECT timeout -k 5 300 ./tools/qtest run \
      "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $_b64" \
      2>/dev/null | tr -d '\r\0' > "$OUT/msi-b64.tmp"
  if grep -qa MSIB64END "$OUT/msi-b64.tmp" 2>/dev/null \
     && sed -n '/MSIB64BEGIN/,/MSIB64END/p' "$OUT/msi-b64.tmp" | grep -av 'MSIB64' | tr -d '\n' \
        | base64 -d > "$OUT/msi-verbose.log" 2>/dev/null \
     && [ -s "$OUT/msi-verbose.log" ]; then
    rm -f "$OUT/msi-b64.tmp"
    log "MSI verbose log preserved ($(wc -c <"$OUT/msi-verbose.log") bytes, $(grep -ac DIFXAPP "$OUT/msi-verbose.log") DIFXAPP lines)"
    if grep -qa "uninstall phase of this upgrade required a reboot" "$OUT/msi-verbose.log"; then
      log "  DIFx: the uninstall phase REQUIRED A REBOOT and the install phase continued anyway"
    fi
  elif grep -qa MSIB64ABSENT "$OUT/msi-b64.tmp" 2>/dev/null; then
    rm -f "$OUT/msi-b64.tmp"
    log "no MSI verbose log on the guest (C:\\qwt-install.log absent) - the guest ANSWERED, so this is not a transport failure"
  else
    log "WARNING: could not fetch the MSI verbose log - kept $OUT/msi-b64.tmp for inspection"
  fi
fi

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
  # ok AND THE ERROR-CLASS DETAIL FLAGS, through the one shared checker. '"ok":true' alone graded a
  # guest with a failed IDD activation, a failed xenvif upgrade or a dead gui-agent GREEN: the
  # installer records those in detail.* (idd_failed, pv_xenvif='failed rc=N', gui_restored='FAILED:
  # ...') and nothing here read them (audit 2026-09-16, the systemic finding). EVERY trailer after
  # the run marker is judged, not only the last - on the two-stage path the last one is stage-2's
  # but a stage-1 flag would otherwise be invisible. The flag list lives in result-flags.py only.
  rf=$(grep -a '^=== RESULT === {' "$OUT/final.cur" | python3 "$HERE/mgmt/harness/result-flags.py" - 2>&1); rrc=$?
  case $rrc in
    0) ok "installer RESULT: ok:true and no error-class detail flags ($(echo "$rf" | grep -c '^\[') trailer(s) judged)" ;;
    1) no "installer RESULT is NOT green - $(echo "$rf" | tail -1)" ;;
    2) # The trailer exists but its JSON does not parse. Mandated carve-out (2026-09-16): a
       # missing/unparseable RESULT keeps today's grading - the field greps below - and says so.
       log "result-flags.py could NOT judge the RESULT ($(echo "$rf" | tail -1)) - grading ok by the field grep as before"
       echo "$j" | grep -qa '"ok":true' && ok "installer reports ok:true (field grep; flags NOT judged)" || no "installer reports ok:false - $(echo "$j" | grep -ao '"error":"[^"]*"' | head -1)" ;;
    *) no "result-flags.py failed (rc=$rrc: $(echo "$rf" | tail -1)) - INVALID-INSTRUMENT, the RESULT was not judged" ;;
  esac
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
