#!/bin/bash
# GATE REMAINDER - the six suites tools/release-acceptance.sh does not cover, and the receipt merge
# that makes a FULL gate reachable at all.
#
# WHY THIS EXISTS, MEASURED 2026-10-08. `tools/release-acceptance.sh` writes
# scratchpad/gate-coverage-<head>.json naming package-verify, its cells, and the three feature tests
# - twelve suites. `tools/gate-scope.py required` asks for EIGHTEEN whenever the diff touches an
# unmapped path, which is most releases. A twelve-suite receipt was fed to `gate-scope.py check` and
# refused, correctly, naming the six with no producer:
#     failproof-gates  failproof-faultinject  gate-preflight  p3a-etw-gate  toast-hold-test  log-sweep
# So the sanctioned path could not produce a receipt that satisfies its own floor. This runs those
# six and MERGES the ones that PASSED into the same receipt.
#
# IT DOES NOT CUT THE RELEASE and it never writes a suite it did not see pass: a receipt is a record,
# not an intention (docs/ADR-acceptance.md section 4).
#
# Usage:
#   tools/gate-remainder.sh --run <release-package-run-id> --vm10 <win10 subject>
#                           --vm11 <win11 subject> --os11 <label, golden is <label>-qwt>
#                           [--fi-run <qwt-full-fault-injection-run>] [--dry]
#
# The three targets are REQUIRED - there are no default targets here (lint L10).
#
# --dry resolves every variable and prints every command without touching a guest. Run it first.
. "$(dirname "$0")/../mgmt/harness/shutdown-lib.sh" 2>/dev/null || true
# settle() shuts guests down between suites, so it needs the per-guest lock (lint L2).
. "$(dirname "$0")/../mgmt/harness/vmlock.sh" 2>/dev/null || true
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RUN=""; FIRUN=""; DRY=0
# NO DEFAULT TARGETS (tools/lint-harness.py L10, and the rule that made matrix.sh refuse an unset
# B10): a default target is wrong in almost every run, and a harness that guesses one churns a
# guest the caller did not mean. Name them with --vm10/--vm11/--os11 or be refused below.
VM10=""; VM11=""; OS11=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)    RUN="${2:-}"; shift 2 ;;
    --fi-run) FIRUN="${2:-}"; shift 2 ;;
    --vm10)   VM10="${2:-}"; shift 2 ;;
    --vm11)   VM11="${2:-}"; shift 2 ;;
    --os11)   OS11="${2:-}"; shift 2 ;;
    --dry)    DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ]  || { echo "ERROR: --run <release-package-run-id> is required" >&2; exit 2; }
[ -n "$VM10" ] || { echo "ERROR: --vm10 <win10 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$VM11" ] || { echo "ERROR: --vm11 <win11 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$OS11" ] || { echo "ERROR: --os11 <label, the golden is <label>-qwt> is required - there is no default target" >&2; exit 2; }

HEAD=$(git rev-parse HEAD) || exit 2
HEAD12=$(printf '%s' "$HEAD" | cut -c1-12)
COVFILE="scratchpad/gate-coverage-$HEAD12.json"
OUTDIR="$HOME/qwt-accept/remainder-$HEAD12"
WORK="$OUTDIR/work"
DL="$OUTDIR/dl"
SETUP="$DL/qwt-improved-setup"
LOG="$OUTDIR/remainder.log"
# /tmp IS RAM ON THIS QUBE (1 GB tmpfs) - a full one gets a long run OOM-killed mid-suite.
export TMPDIR="${TMPDIR:-$HOME/tmp}"

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
run_it() {           # run_it <label> <cmd...>  - never `cmd | tee`, which reports TEE's status
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then echo "INTEND[dry] $label: $*" | tee -a "$LOG"; return 0; fi
  say "--- $label"
  "$@" >>"$WORK/$label.out" 2>&1
  local rc=$?
  if [ "$rc" = 0 ]; then say "PASS  $label"; else say "FAIL  $label (exit $rc) - see $WORK/$label.out"; fi
  return $rc
}

mkdir -p "$OUTDIR" "$WORK" "$DL" || exit 2
say "=== gate remainder for run $RUN at HEAD $HEAD12 (dry=$DRY) ==="

# ---- what the diff actually requires, and which of it is still missing -------------------------
BASE=$(git describe --tags --abbrev=0 --match 'v4.3.*' 2>/dev/null || echo "")
[ -n "$BASE" ] || { say "ERROR: no v4.3.* tag to diff against"; exit 2; }
say "range: $BASE..$HEAD12"
REQ=$(python3 tools/gate-scope.py required "$BASE..$HEAD" 2>/dev/null \
        | sed -n 's/^    \([a-z0-9][a-z0-9-]*\) .*/\1/p' | sort -u)
[ -n "$REQ" ] || { say "ERROR: gate-scope named no suites - refusing to guess"; exit 2; }
say "gate-scope requires: $(echo $REQ | tr '\n' ' ')"

# ---- the artifacts the suites consume ----------------------------------------------------------
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] download: gh run download $RUN -n qwt-improved-setup -D $SETUP"
else
  if [ ! -s "$SETUP/install.cmd" ]; then
    rm -rf "$SETUP"
    say "downloading qwt-improved-setup from run $RUN"
    gh run download "$RUN" -n qwt-improved-setup -D "$SETUP" >>"$LOG" 2>&1 \
      || { say "ERROR: could not download the setup tree"; exit 2; }
  fi
  [ -s "$SETUP/install.cmd" ] || { say "ERROR: $SETUP/install.cmd missing"; exit 2; }
fi

# ---- the suites, each named exactly as gate-scope names it --------------------------------------
# Only a suite that RAN and PASSED is recorded. A suite gate-scope does not require is skipped and
# is never recorded either.
PASSED=""; FAILED=""; SKIPPED=""

# SETTLE THE RIG BETWEEN SUITES. Measured 2026-10-09, first non-dry run: toast-hold-test was
# REFUSED because win11-acc was still Running from the suites before it ("REFUSED: these are not
# Halted: win11-acc") - quick-upgrade refuses while any win1* guest is up, by design, and nothing
# here put the previous subject down. tools/release-acceptance.sh already settles before each
# feature test for exactly this reason; the remainder did not.
settle() {            # settle <vm-to-leave-alone>
  local keep="${1:-}" v st
  [ "$DRY" = 1 ] && { echo "INTEND[dry] settle: halt other win1* subjects (keeping ${keep:-none})" | tee -a "$LOG"; return 0; }
  for v in "$VM10" "$VM11" "${OS11}-p3a" "${OS11}-thold"; do
    [ -n "$v" ] || continue
    [ "$v" = "$keep" ] && continue
    st=$(QTEST_VM="$v" tools/qtest state 2>/dev/null | command grep -ao 'power_state=[A-Za-z]*' | head -1)
    [ "$st" = "power_state=Halted" ] && continue
    [ -n "$st" ] || continue                      # no such qube: nothing to settle
    say "    settling: $v is ${st#power_state=} - requesting shutdown"
    # UNDER THE PER-GUEST LOCK (lint L2). This runs BETWEEN suites, so no lock is held and nothing
    # is nested; taking it means a shutdown here can never land underneath another job's boot.
    if vm_lock "$v"; then
      qwt_shutdown "$v" 600 >>"$LOG" 2>&1 || say "    WARN $v did not halt cleanly"
      vm_unlock
    else
      say "    WARN could not lock $v to settle it - leaving it alone"
    fi
  done
}
need() { echo "$REQ" | tr ' ' '\n' | grep -qx "$1"; }

# THE ARTEFACT UNDER TEST MUST BE THE ONE INSTALLED (the evidence rule: running binary hash vs the
# manifest). MEASURED 2026-10-09, and it invalidated a whole gate run: gate-preflight and log-sweep
# grade $VM11 AS IT IS - neither installs anything - and at HEAD fe4337174ba8 that guest was still
# carrying agent 4.3.32.612 while the candidate package was 4.3.36+agent.eb24cb5115ba. The proof is
# in the sweep's own archived logs: every "LogInit: Module version" line reads 4.3.32.612, in a file
# named gui-agent-20261009-190318-3824.log (the pre-4.3.33 name format), and the two keyed-mutex
# ACCESS_LOST error lines the sweep reported as KNOWN-DEFECT PRESENT were written by THAT agent -
# a build predating the fix for them, whose guard (status != DXGI_ERROR_ACCESS_LOST && ...) is
# present in eb24cb5115ba and therefore could not have written them. So the gate spent a full run
# grading a binary that was never the candidate, and reported a fixed defect as present.
# REFUSE rather than install: the subject is prepared by the campaign, and silently upgrading it
# here would hide which step failed to prepare it.
assert_candidate() {  # assert_candidate <vm> - rc 0 = the guest runs the candidate agent
  local v="$1" ref want got
  [ "$DRY" = 1 ] && { echo "INTEND[dry] assert_candidate: $v runs the package's reference gui-agent" | tee -a "$LOG"; return 0; }
  ref=$(find "$SETUP" -iname 'gui-agent.exe' 2>/dev/null | head -1)
  [ -n "$ref" ] || { say "    REFUSING: no reference gui-agent.exe in $SETUP - cannot say what the candidate is"; return 2; }
  want=$(sha256sum "$ref" | cut -d' ' -f1)
  # -EncodedCommand, not -Command with escaped quotes: that form FAILS SILENTLY here (lint L5),
  # and a silent failure in this probe would read as "no gui-agent running" and refuse a good guest.
  local b64
  b64=$(printf '%s' '$p=@(Get-Process -Name gui-agent -ErrorAction SilentlyContinue)
if ($p.Count -gt 0) { Write-Output ("RUNSHA " + (Get-FileHash -LiteralPath $p[0].Path -Algorithm SHA256).Hash) }
else { Write-Output "RUNSHA none" }' | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  # QTEST_BIN is overridable ONLY so both arms of this check are provable off-rig, the same reason
  # mgmt/harness/gate-preflight.sh exposes it. A check whose accept path has never been seen to
  # accept is half a check.
  got=$(QTEST_VM="$v" timeout 240 "${QTEST_BIN:-tools/qtest}" run "cmd /c powershell -NoProfile -EncodedCommand $b64" \
          2>/dev/null | tr -d '\r' | command grep -aoE 'RUNSHA [0-9A-Za-z]+' | head -1 | awk '{print tolower($2)}')
  if [ -z "$got" ] || [ "$got" = none ]; then
    say "    REFUSING: no gui-agent is running on $v, so nothing can be graded on it"
    return 2
  fi
  if [ "$got" != "$want" ]; then
    say "    REFUSING: $v runs gui-agent ${got:0:16} but the candidate is ${want:0:16}"
    say "              ($ref). The subject was never upgraded to the package under test, so any"
    say "              verdict from it would be about another build - which is how a run at"
    say "              fe4337174ba8 reported a FIXED keyed-mutex defect as present."
    return 2
  fi
  say "    $v runs the candidate agent ${got:0:16}"
  return 0
}
note() { if [ "$1" = 0 ]; then PASSED="$PASSED $2"; else FAILED="$FAILED $2"; fi; }

# THE SWEEP'S WINDOW IS THIS RUN, NOT TWELVE HOURS OF HISTORY. This said '12 hours ago', which on a
# rig whose guests are reinstalled all day means a window covering OTHER RUNS, OLDER BUILDS and the
# install-era boots - and the sweep would report their lines as this run's findings. Measured
# 2026-10-09: an install-era boot writes early-boot vchan transients (XcStoreRead 0x5,
# libxenvchan_client_init ... ring-ref 0x5, at ~21 s uptime, upstream code, resolved on retry) that a
# normal boot of a provisioned guest does NOT write - zero error lines on two swept guests - so a
# window that reaches back into an install carries them and a window over this run does not. The
# suites below all run after this point, and log-sweep runs last on purpose, so this is the right
# start for it.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# THE SUBJECT MUST BE UP AND ANSWERING BEFORE A SUITE JUDGES IT. Measured 2026-10-09:
# gate-preflight ran first, right after the campaign, and its own log says "liveness probe 1/3:
# guest did not answer" and then printed NO WDSTART line at all - so the watchdog check had nothing
# to read and the suite graded INVALID-INSTRUMENT. The guest was still settling from the campaign.
# settle() halts the OTHER guests; this makes the named one ready, which is the other half.
ready() {             # ready <vm>
  local v="$1" st i
  [ -n "$v" ] || return 0
  [ "$DRY" = 1 ] && { echo "INTEND[dry] ready: $v up and answering qrexec" | tee -a "$LOG"; return 0; }
  st=$(QTEST_VM="$v" tools/qtest state 2>/dev/null | command grep -ao 'power_state=[A-Za-z]*' | head -1)
  [ -n "$st" ] || { say "    ready: no qube named $v"; return 1; }
  if [ "$st" != "power_state=Running" ]; then
    say "    ready: $v is ${st#power_state=} - starting it"
    if vm_lock "$v"; then timeout 300 qvm-start "$v" >>"$LOG" 2>&1 || true; vm_unlock; fi
  fi
  # qrexec IS NOT THE PRECONDITION THESE SUITES NEED. Measured 2026-10-09 in this script's own log:
  # "ready: win11-acc answers qrexec" at 16:03:19, and gate-preflight FATALed 14 s later because it
  # could not push its restart helper (guest sha256 'none'). The same push by hand a moment later
  # landed with an exact sha match. qrexec answers as SYSTEM early in a boot; a FILE COPY needs the
  # receiver in a logged-on session, which comes later - so proving qrexec and then handing the
  # guest to a suite whose first act is a push proves the wrong thing, and the suite grades the gap
  # as INVALID-INSTRUMENT. Prove the copy itself.
  # `qtest push` already deletes the name on the guest before copying (tools/qtest:152), so a
  # repeated probe does not need a delete of its own - measured here, three pushes of the same
  # name in a row all returned 0. Do not add one back on the theory that the receiver refuses to
  # overwrite: it does refuse, and qtest is where that is handled.
  local pushed=0 probe
  probe="$WORK/ready-probe-$v.txt"
  printf 'READYPROBE %s\n' "$v" > "$probe" 2>/dev/null
  for i in $(seq 1 42); do
    if QTEST_VM="$v" timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then
      [ "$pushed" = 0 ] && { say "    ready: $v answers qrexec - now proving a file copy"; pushed=1; }
      if QTEST_VM="$v" timeout 90 tools/qtest push "$probe" >>"$LOG" 2>&1; then
        say "    ready: $v takes a file push (the receiver session is up)"; rm -f "$probe"
        # AND ITS CLOCK, BEFORE ANY SUITE READS IT. No in-guest time setting survives a reboot (the
        # domain is destroyed), so these guests come up ~3 h ahead. log-sweep REFUSES a collection
        # whose guest clock is skewed from the host's - measured in this gate's own run, rc=3
        # "clockskew ... the guest's clock is +10837 s from the host's at collection time" - so the
        # sweep produced NO verdict and the receipt stayed empty. qtest synctime pushes this qube's
        # clock in to ~0.3 s and is documented as the call to make after every VM start.
        QTEST_VM="$v" timeout 120 tools/qtest synctime >>"$LOG" 2>&1 \
          || say "    WARN could not push the clock into $v - a sweep may refuse on skew"
        return 0
      fi
    fi
    sleep 10
  done
  rm -f "$probe"
  # SAY WHICH EXIT FIRED. These are different failures and lead to different work: no qrexec at all
  # is a dead/unbooted guest, while qrexec-without-a-push is the session gap this probe exists for.
  if [ "$pushed" = 1 ]; then
    say "    WARN $v answers qrexec but never took a file push in 7 min - the suite will grade that"
  else
    say "    WARN $v never answered qrexec in 7 min - the suite will grade that itself"
  fi
  return 1
}

if need gate-preflight; then
  settle "$VM11"; ready "$VM11"
  if ! assert_candidate "$VM11"; then
    say "FAIL  gate-preflight (subject is not the candidate)"; FAILED="$FAILED gate-preflight"
  else
  # <vm> <hex-bits>: the preflight bit-mask the suite documents; 0 exercises the no-fault path.
  run_it gate-preflight bash mgmt/harness/gate-preflight.sh "$VM11" 0; note $? gate-preflight
  fi
else SKIPPED="$SKIPPED gate-preflight"; fi

if need p3a-etw-gate; then
  # toastfire.exe comes from the `build` workflow, NOT from release-package: it is a TEST helper
  # that fires toasts and has no business shipping inside the product. p3a-etw-gate looks for it in
  # the setup tree and then accepts a TOASTFIRE= override; on the first non-dry run it found neither
  # and died "FATAL toastfire.exe not in <setup>". So the gate fetches it from the build run at this
  # same HEAD and passes it explicitly.
  TF="${TOASTFIRE:-}"
  if [ -z "$TF" ]; then
    TFDIR="$DL/toastfire"
    if [ "$DRY" = 1 ]; then
      say "INTEND[dry] download toastfire from the build run at HEAD ${HEAD:0:12}"
    else
      BRUN=$(gh run list -w build -L 20 --json databaseId,headSha,conclusion \
               -q "[.[]|select(.conclusion==\"success\" and (.headSha|startswith(\"${HEAD:0:12}\")))][0].databaseId" 2>/dev/null)
      if [ -n "$BRUN" ] && [ "$BRUN" != "null" ]; then
        # ARTIFACT `gui-agent-package`, NOT `toastfire`. This asked for -n toastfire, which is not an
        # artifact that run publishes (it has idd-driver-package, gui-agent-package and
        # qwt-improved-package), so the download failed, `|| true` swallowed it and the find came
        # back empty - reported as "no toastfire.exe for HEAD", i.e. a missing helper rather than a
        # wrong name. mgmt/harness/toast-hold-test.sh already had it right and fetched the same exe
        # from gui-agent-package in the same run, which is how the two disagreed in one log.
        [ -d "$TFDIR" ] || gh run download "$BRUN" -n gui-agent-package -D "$TFDIR" >>"$LOG" 2>&1 || true
        TF=$(find "$TFDIR" -iname 'toastfire.exe' 2>/dev/null | head -1)
      fi
      [ -n "$TF" ] && say "    toastfire from build run $BRUN: $TF" \
                   || say "    WARN no toastfire.exe for HEAD ${HEAD:0:12} - p3a-etw-gate will refuse, as it should"
    fi
  fi
  settle "${OS11}-p3a"
  TOASTFIRE="$TF" run_it p3a-etw-gate bash mgmt/harness/p3a-etw-gate.sh "$SETUP" "${OS11}-p3a" "${OS11}-qwt"
  note $? p3a-etw-gate
else SKIPPED="$SKIPPED p3a-etw-gate"; fi

if need toast-hold-test; then
  settle "${OS11}-thold"
  run_it toast-hold-test bash mgmt/harness/toast-hold-test.sh --run "$RUN" --os "$OS11"; thrc=$?
  # ONE RETRY, DRIVEN BY THE REFUSAL'S OWN TEXT. quick-upgrade refuses while ANY win1* guest is up,
  # and settle() above only knows the guests THIS gate names. Measured 2026-10-09: it refused with
  # "REFUSED: these are not Halted: win11r-up" - a leftover from other work on the rig, which no
  # static list here could have predicted. Rather than enumerate every qube (forbidden: that fires
  # an admin call at each one, dom0 and this qube included), take the names out of the refusal,
  # settle those, and retry once. A refusal naming nothing, or a second failure, is graded as before.
  # The rc is captured in thrc: `note $?` after an `if` would read the BLOCK's status, not the suite's.
  if [ "$DRY" = 0 ] && [ "$thrc" != 0 ]; then
    stuck=$(command grep -aoE 'these are not Halted:[^"]*' "$WORK/toast-hold-test.out" 2>/dev/null \
              | head -1 | sed 's/these are not Halted://')
    if [ -n "${stuck// /}" ]; then
      say "    toast-hold-test was refused over guests it does not own:${stuck} - settling them by name"
      for v in $stuck; do
        if vm_lock "$v"; then qwt_shutdown "$v" 600 >>"$LOG" 2>&1 || say "    WARN $v did not halt cleanly"; vm_unlock
        else say "    WARN could not lock $v to settle it"; fi
      done
      run_it toast-hold-test bash mgmt/harness/toast-hold-test.sh --run "$RUN" --os "$OS11"; thrc=$?
    fi
  fi
  note "$thrc" toast-hold-test
else SKIPPED="$SKIPPED toast-hold-test"; fi

if need log-sweep; then
  settle "$VM11"; ready "$VM11"
  if ! assert_candidate "$VM11"; then
    say "FAIL  log-sweep (subject is not the candidate)"; FAILED="$FAILED log-sweep"
  else
  # LAST, deliberately: it reads what every suite above wrote into the guest's logs.
  run_it log-sweep bash mgmt/harness/log-sweep.sh "$VM11" "$SINCE" "$WORK/log-sweep"
  note $? log-sweep
  fi
else SKIPPED="$SKIPPED log-sweep"; fi

# --------------------------------------------------------------- the fault-injection suites, LAST
# ORDER IS DELIBERATE. These two need an INSTALLED injector build, and installing it replaces the
# release binaries on the subject - so everything that grades the RELEASE runs first and these run
# at the end. Before 2026-10-09 they ran third and refused outright, because nothing installed
# anything: the qwt-full artifact is not an installable tree. release-package.yml now accepts
# fault_injection, so --fi-run names a run whose qwt-improved-setup carries the injector and goes
# in through the ordinary install path. cut-release.sh refuses to publish such a package.
fi_installed=0
if need failproof-gates || need failproof-faultinject; then
  if [ -z "$FIRUN" ]; then
    say "SKIP  failproof-gates/failproof-faultinject: no --fi-run. Dispatch release-package with"
    say "      -f fault_injection=true and pass its run id; an ordinary package cannot inject a"
    say "      fault and recording a pass from one would be vacuous."
  else
    FISETUP="$DL/fi-setup/qwt-improved-setup"
    if [ "$DRY" = 1 ]; then
      say "INTEND[dry] download: gh run download $FIRUN -n qwt-improved-setup -D $FISETUP"
      say "INTEND[dry] install the injector tree on $VM11 via quick-upgrade"
      fi_installed=1
    else
      [ -s "$FISETUP/install.cmd" ] || gh run download "$FIRUN" -n qwt-improved-setup -D "$FISETUP" >>"$LOG" 2>&1 || true
      if [ ! -s "$FISETUP/install.cmd" ]; then
        say "ERROR: run $FIRUN has no installable qwt-improved-setup - was it dispatched on"
        say "       release-package with -f fault_injection=true? (qwt-full alone is not installable)"
      elif ! python3 - "$FISETUP/reference/gui-agent.exe" <<'FIMARK'
import sys
b=open(sys.argv[1],'rb').read(); m=b'QGA-FAULT-INJECTION:on'
sys.exit(0 if (b.count(m)+b.count(m.decode().encode('utf-16-le'))) else 1)
FIMARK
      then
        say "ERROR: run $FIRUN's agent does NOT carry the injector marker - it is an ordinary"
        say "       package, so both suites would come back green for the wrong reason."
      else
        settle "$VM11"
        say "--- installing the injector tree on $VM11 (its agent carries QGA-FAULT-INJECTION:on)"
        if QU_OUT="$WORK/fi-install" bash mgmt/harness/quick-upgrade.sh "$FISETUP" "$VM11" "$OS11" \
             >>"$WORK/fi-install.out" 2>&1; then
          say "    injector build installed"; fi_installed=1
        else
          say "    FAIL could not install the injector tree - see $WORK/fi-install.out"
        fi
      fi
    fi
  fi
fi

if need failproof-gates && [ "$fi_installed" = 1 ]; then
  run_it failproof-gates bash mgmt/harness/failproof-gates.sh "$VM11" "$WORK/failproof-gates"
  note $? failproof-gates
else SKIPPED="$SKIPPED failproof-gates"; fi

if need failproof-faultinject && [ "$fi_installed" = 1 ]; then
  # No download here: this suite reads nothing from a directory (it has zero references to FI_DIR).
  # Its prerequisite is the INSTALLED injector build, which the step above put on the subject, and
  # it verifies that itself from the running agent's QGAFAULT-INIT banner before grading anything.
  run_it failproof-faultinject bash mgmt/harness/failproof-faultinject.sh "$VM11" "$WORK/failproof-faultinject"
  note $? failproof-faultinject
else SKIPPED="$SKIPPED failproof-faultinject"; fi


say "passed:$PASSED"
say "failed:$FAILED"
say "skipped:$SKIPPED"

# ---- merge into the receipt the release-cut gate reads -----------------------------------------
# Only PASSED suites are added, and an existing receipt is never shrunk: this is a merge, so the
# cells recorded by release-acceptance.sh survive.
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] merge into $COVFILE:$PASSED"
else
  python3 - "$COVFILE" "$RUN" "$HEAD12" "$PASSED" <<'PYMERGE'
import json, os, sys
out, run, head, passed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
rec = {}
if os.path.exists(out):
    try:
        rec = json.load(open(out, encoding="utf-8"))
    except ValueError:
        rec = {}
suites = sorted(set(rec.get("suites") or []) | set(passed))
rec["suites"] = suites
rec.setdefault("package_run", run)
rec.setdefault("built_from", head)
rec["note"] = ("merged by tools/gate-remainder.sh; names only suites seen to pass. "
               + (rec.get("note") or ""))[:400]
json.dump(rec, open(out, "w"), indent=1)
print("receipt now names %d suite(s): %s" % (len(suites), " ".join(suites)))
PYMERGE
  say "--- does the receipt now satisfy the gate?"
  python3 tools/gate-scope.py check "$COVFILE" "$BASE..$HEAD" 2>&1 | tee -a "$LOG"
  CHK=${PIPESTATUS[0]}
  if [ "$CHK" = 0 ]; then say "GATE SATISFIED for $HEAD12"; else say "GATE NOT YET SATISFIED (exit $CHK)"; fi
fi

[ -z "$FAILED" ] || exit 1
exit 0
