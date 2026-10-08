#!/bin/bash
# toast-hold-test.sh - GUEST acceptance for the toast HOLD (docs/ADR-toasts.md 10): the P1 "first toast shows twice".
#
#   mgmt/harness/toast-hold-test.sh --run <release-package-run-id> --os <golden label, e.g. win11r> \
#        [--subject <vm>] [--toastfire <toastfire.exe>] [--skip-nonseamless] [--reuse-subject]
#
#   --run        a GREEN `release-package` workflow run: its qwt-improved-iso is what quick-upgrade installs, its
#                qwt-improved-setup tree supplies MANIFEST.json + reference/gui-agent.exe (the hash the installed
#                agent must carry). CANDIDATE: 37478561723 (fix/toast-hold 92c26294). CONTROL: 37230058013 (4.3.35,
#                no hold) - run the control FIRST (experimenter rule 4): on it scenario 1 MUST come out DOUBLE and
#                scenario 2 LOST, which is this harness's own validation step (every detector seen to FAIL with the
#                defect present) - and the verdict line says which package it graded.
#   --os         selects the golden <os>-qwt for quick-upgrade (win11r -> win11r-qwt, the retail 26300 golden the
#                owner designated). Win10: no win10-qwt golden exists today; quick-upgrade refuses, this exits 1.
#   --subject    the churn guest quick-upgrade RECREATES from the golden (default <os>-thold).
#   --toastfire  toastfire.exe to push (default: the `build` run of the same head sha, artifact gui-agent-package;
#                the release ISO does not carry it - build.yml "Collect package").
#   --skip-nonseamless   skip scenario 5 (the dom0 qubes.SetGuiMode round trip).
#   --reuse-subject      skip quick-upgrade when the subject already exists (iteration on this harness; the installed
#                        agent hash is STILL verified against the package, so a wrong subject is refused).
#   env: TH_OUT=<dir>   evidence root (default $HOME/qwt-toast-hold; outside the repo - captures and logs never enter
#                       a tracked path), TH_DL=<dir> artifact cache (default $TH_OUT/dl), TH_GAP_MS (default 700, the
#                       quick-succession gap), DEADLINE (quick-upgrade's install budget).
#
# ---- THE EXPERIMENT (the experimenter's five lines) --------------------------------------------------------------
#   HYPOTHESIS: on the hold package every fired toast grades OK-BRIDGED (forwarded to dom0, its banner NEVER mapped -
#     not even a MAP followed by an UNMAP) or OK-WINDOW (not forwarded, its banner mapped within 3.5 s of the agent's
#     first look at it); refuted by any DOUBLE, LOST or LATE-WINDOW row. On the pre-hold CONTROL package S0/S1a/S4
#     grade DOUBLE and S2 grades LOST - the defect as the owner saw it (Windows Security "Microsoft Defender summary"
#     doubled; an interactive toast of a suppressed app shown nowhere). A control that does NOT show that is a FAIL of
#     the detectors (DETECTOR UNPROVEN), never a pass of anything.
#   BASELINE:   the CONTROL run (4.3.35, release-package 37230058013) on the same golden with the same instruments -
#     run it before the candidate; its verdict line reads "role=CONTROL ... -> PASS (the defect reproduced ...)".
#   VARIABLE:   the package under test - and nothing else: same golden (win11r-qwt), same quick-upgrade path, same
#     cold boot, same knobs (ProtoTrace on, service.notify-bridge on, one allowlisted toastfire AUMID), same toastfire,
#     same scenario list and gaps, on both sides.
#   INSTRUMENT: the guest's own logs, joined on the guest's clock and on per-toast identity: the agent log (QGATOASTHOLD /
#     QGATOASTHOLDLATE / QGATOASTPREEMPT / QGAHELDDEFER / QGAPROTO CREATE+MAP / "Unmapping window"), bridge.log (HOLD id=
#     verdict= t=<hash> / SENT / FWD_RTT ok=1 / skip), toastfire's FIRED lines stamped by guest/toast-hold-fire.ps1 with
#     the guest clock, a clock PROBE (charmap's CREATE ties the agent log's clock to the bridge's), and a banner-visibility
#     probe (user32 on the HWND the agent logged). Validated BEFORE any verdict: toast-hold-grade.py --selftest (synthetic
#     fixtures for every class incl. the flash and the pre-emption, the truncated transfer, the usage-error FIRED trap),
#     toastfire --print-xml (data) vs a bogus flag (no FIRED), the clock probe's CREATE, and the CONTROL run above.
#     If a run fails mid-way the evidence dir holds every wrapper output, every wait log and (from the pull) both logs.
#   BUDGET:     ~35-45 min per package: artifact download 1-3 min; quick-upgrade 15-25 min (its own DEADLINE, default
#     1500 s install phase + two cold boots); arm + one cold boot 3-5 min (w_usersession 900 s); preflight 2 min (bridge
#     heartbeat 180 s, connected 120 s, active session 600 s); scenarios 8-10 min (per toast: settle 90 s, banner cycle
#     25 s, banner gone 30 s; mode switch 90 s each way); pull + grade 1-2 min. TERMINAL: a guest deaf to qrexec, a
#     recovery screen (w_usersession), the bridge heartbeat gone, the agent log replaced mid-run, a mode switch that
#     never registers. Exits: 0 PASS, 1 FAIL / refused / missing data, 2 a structural wait hit its DEADLINE.
#
# ---- RULES THIS FILE FOLLOWS (CLAUDE.md, .claude/skills/rig-cycle, .claude/skills/experimenter, tools/lint-harness.py)
#   * quick-upgrade over the golden for a feature test (never a clean install); vm_lock on the subject before anything
#     touches it (re-entrant: quick-upgrade takes the same lock as a child); job_init's teardown owns the EXIT trap.
#   * every wait has three exits and logs which it took; no fixed sleep stands in for an observable condition (the banner's
#     life is observed through the visibility probe, the bridge's listing through its own lines, the reboot through
#     g_reboot_proven's boot identity, never assumed).
#   * no window is ever identified by its caption (owner 2026-10-01): the banner is the HWND the agent itself logged
#     (QGAHELDDEFER class=Windows.UI.Core.CoreWindow / QGATOASTHOLD hwnd=), toasts by AUMID and by their title HASH.
#   * the guest's output is DATA: every marker the harness greps for (THC, THF, FIRED method=) is produced by the guest
#     and never passed on the command line (the a0-lib self-match lesson); patterns travel base64-encoded.
#   * missing data FAILS: a toast that never FIRED, a bridge that never listed it, a pull whose counts/sha disagree, a
#     clock probe without its CREATE - each is INSTRUMENT (ungraded, exit 1), never an OK.
#   * the artefact under test is verified installed: certutil sha256 of the installed gui-agent.exe == the package
#     MANIFEST's reference_binaries, read AFTER the arming cold boot, before the first fire.
#   * nothing here lands in the repo: evidence under $TH_OUT (outside the tree), scenario titles are opaque slugs.
# NEEDS LogLevel >= 4 (DEBUG). The QGAHELDDEFER / QGASLICEMAP line(s) this harness grades on are routine
# per-window detail and moved to DEBUG on 2026-10-08 (owner: "ok for debug but not for regular
# operation"), so a run at the shipped LogLevel 3 will find nothing and must not read that as a
# clean result. Raise it first with guest/set-loglevel.ps1 4 (it restarts the agent through the
# service that owns it and proves the turnover) and put it back afterwards.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

RID=""; OS=""; SUBJECT=""; TFEXE="${TOASTFIRE:-}"; SKIP_NS=0; REUSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RID="${2:-}"; shift 2 ;;
    --os) OS="${2:-}"; shift 2 ;;
    --subject) SUBJECT="${2:-}"; shift 2 ;;
    --toastfire) TFEXE="${2:-}"; shift 2 ;;
    --skip-nonseamless) SKIP_NS=1; shift ;;
    --reuse-subject) REUSE=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$RID" ] || { echo "usage: $0 --run <release-package-run-id> --os <label> [...]  (--run is required)" >&2; exit 1; }
[ -n "$OS" ] || { echo "usage: $0 --run <id> --os <label>  (--os names the golden <os>-qwt; there is no default target)" >&2; exit 1; }
case "$RID" in ''|*[!0-9]*) echo "--run must be a numeric GitHub run id (got '$RID')" >&2; exit 1 ;; esac
case "$OS" in win[0-9]*) ;; *) echo "--os must look like win<version>[r|de] (got '$OS'): it names the golden ${OS}-qwt" >&2; exit 1 ;; esac
SUBJECT="${SUBJECT:-${OS}-thold}"
VM="$SUBJECT"
GAP_MS="${TH_GAP_MS:-700}"

TH_ROOT="${TH_OUT:-$HOME/qwt-toast-hold}"
DL="${TH_DL:-$TH_ROOT/dl}/$RID"
OUT="$TH_ROOT/$VM-$RID-$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT/fires" "$OUT/waits"
R="$OUT/results.log"; : > "$R"
RUNID=$(printf '%06x' $(( (RANDOM << 15 | RANDOM) & 0xffffff )))
log(){ echo "[$(date -u +%H:%M:%S)] toast-hold[$VM]: $*" | tee -a "$R"; }
verdict(){ log "VERDICT $1: $2"; echo "$1|$2" >> "$OUT/verdicts.txt"; }
GRADER="mgmt/harness/toast-hold-grade.py"

# AUMIDs the stimulus uses (tools/toastfire/README.md: registration methods and their default AUMIDs).
AUMID_A='QubesToastfire.StartShortcut'          # the classifier-routed app under test (scenarios 1-3)
AUMID_W='QubesToastfire.Warmup'                 # a second start-shortcut app: the fire-path warm-up, graded like S1a
AUMID_C='QubesToastfire.ComActivator'           # the ALLOWLISTED app (NotifyBridgeAllow, scenario 4)
AUMID_SYS='Windows.SystemToast.SecurityAndMaintenance'   # the bridge's one WINDOW-ONLY app (notifhost.cpp WINDOW_ONLY):
                                                # an informational toast under it is a SHORT-LIVED window-path banner,
                                                # which the in-place swap scenario needs (toastfire's own window-path
                                                # classes are persistent reminders). Fired with --method bare on the
                                                # system-registered AUMID; if the shell shows no banner for it the row
                                                # grades NO-BANNER (ungraded), never a false FAIL.
QT='C:\Program Files\Qubes Tools\bin'
GAKEY='HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'

# ---- lifecycle: lock FIRST, then the teardown owner, then the libraries (a0-lib needs VM OUT R log qrun) ----------
export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
source mgmt/harness/run-lib.sh; job_init toast-hold-test
source mgmt/harness/verdict-lib.sh
source .claude/skills/win-guest-e2e/e2e-lib.sh      # qrun/_q (rc + stderr kept), w_* helpers' dependency
source mgmt/harness/e2e-wait.sh                       # w_usersession w_alive w_state g_reboot_proven
source mgmt/harness/shutdown-lib.sh                   # qwt_shutdown (asks and polls, never kills)
source mgmt/harness/a0-lib.sh                         # raspush blog_len hb_state dismiss_toasts (INCOMING re-pointed below)

finish(){ # $1=rc $2...=message; every exit says which exit it took (the EXIT trap tears the tree down)
  local rc=$1; shift
  log "$*"
  log "evidence: $OUT"
  exit "$rc"
}
b64(){ printf '%s' "$1" | base64 -w0; }

# ---- 0. the package: a green release-package run -> ISO (installed) + setup tree (MANIFEST, reference hash) ------
log "=== toast-hold acceptance: run=$RID os=$OS subject=$VM out=$OUT runid=$RUNID ==="
WF=$(gh run view "$RID" --json workflowName --jq .workflowName 2>/dev/null)
CONCL=$(gh run view "$RID" --json conclusion --jq .conclusion 2>/dev/null)
HEAD=$(gh run view "$RID" --json headSha --jq .headSha 2>/dev/null)
log "run $RID: workflow='$WF' conclusion='$CONCL' head=${HEAD:0:12}"
case "$WF" in *release-package*) ;; *) finish 1 "REFUSED: run $RID is workflow '${WF:-unreadable}', not release-package (only that workflow builds the installable ISO)";; esac
[ "$CONCL" = success ] || finish 1 "REFUSED: run $RID concluded '${CONCL:-unknown}' - a package from a non-green run is not under test"
mkdir -p "$DL"
if [ ! -s "$(ls "$DL"/qwt-improved-iso/*.iso 2>/dev/null | head -1)" ]; then
  log "downloading qwt-improved-iso"
  gh run download "$RID" -n qwt-improved-iso -D "$DL/qwt-improved-iso" >"$OUT/gh-download-iso.out" 2>&1 \
    || finish 1 "REFUSED: could not download qwt-improved-iso from run $RID ($(tail -1 "$OUT/gh-download-iso.out"))"
fi
if [ ! -f "$DL/qwt-improved-setup/MANIFEST.json" ]; then
  log "downloading qwt-improved-setup"
  gh run download "$RID" -n qwt-improved-setup -D "$DL/qwt-improved-setup" >"$OUT/gh-download-setup.out" 2>&1 \
    || finish 1 "REFUSED: could not download qwt-improved-setup from run $RID ($(tail -1 "$OUT/gh-download-setup.out"))"
fi
ISO=$(ls "$DL"/qwt-improved-iso/*.iso 2>/dev/null | head -1)
SETUP="$DL/qwt-improved-setup"
[ -s "$ISO" ] || finish 1 "REFUSED: no ISO under $DL/qwt-improved-iso"
[ -s "$SETUP/reference/gui-agent.exe" ] || finish 1 "REFUSED: $SETUP has no reference/gui-agent.exe - the installed-agent verify would be vacuous"
read -r PV SHA REF_AGENT REF_NOTIF <<<"$(python3 - "$SETUP/MANIFEST.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
rb = m.get("reference_binaries") or {}
print(m.get("package_version", "?"), (m.get("source") or {}).get("driver_repo_commit", "?"),
      (rb.get("gui-agent.exe") or "-").lower(), (rb.get("notifhost.exe") or "-").lower())
PY
)"
[ -n "$PV" ] && [ "$PV" != "?" ] || finish 1 "REFUSED: $SETUP/MANIFEST.json has no package_version"
[ "$REF_AGENT" != "-" ] && [ ${#REF_AGENT} -eq 64 ] || finish 1 "REFUSED: MANIFEST reference_binaries carries no gui-agent.exe sha256"
ISO_SHA=$(python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get('source') or {}).get('driver_repo_commit','?'))" "$DL/qwt-improved-iso/MANIFEST.json" 2>/dev/null)
[ "$ISO_SHA" = "$SHA" ] || finish 1 "REFUSED: the ISO artifact's MANIFEST names commit ${ISO_SHA:0:12}, the setup tree's ${SHA:0:12} - two different packages in one download dir"
[ "${SHA:0:12}" = "${HEAD:0:12}" ] || log "WARNING: MANIFEST driver_repo_commit ${SHA:0:12} != run head ${HEAD:0:12} (recorded; the MANIFEST is the package's own word)"
REF_ON_DISK=$(sha256sum "$SETUP/reference/gui-agent.exe" | cut -d' ' -f1)
[ "$REF_ON_DISK" = "$REF_AGENT" ] || finish 1 "REFUSED: reference/gui-agent.exe ($REF_ON_DISK) disagrees with MANIFEST reference_binaries ($REF_AGENT)"
# Does THIS package carry the hold? Decided from the reference binary's bytes (the log token the hold's Init writes
# is in the image as UTF-16, MSVC concatenating the narrow and wide literals), not from the version: control and
# candidate both read 4.3.35, and only driver_repo_commit tells them apart (memory: rig-package-validation-recipe 3b).
HOLD_BUILD=$(python3 - "$SETUP/reference/gui-agent.exe" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print(1 if (b"QGATOASTHOLD".decode().encode("utf-16-le") in d or b"QGATOASTHOLD" in d) else 0)
PY
)
ROLE=$([ "$HOLD_BUILD" = 1 ] && echo CANDIDATE || echo CONTROL)
log "package: $PV commit=${SHA:0:12} reference gui-agent=${REF_AGENT:0:12} hold_build=$HOLD_BUILD -> this run grades the $ROLE"

# toastfire: ships in the `build` workflow's gui-agent-package, not in the ISO (build.yml "Collect package")
if [ -z "$TFEXE" ]; then
  TFEXE=$(find "$SETUP" "$DL" -iname 'toastfire.exe' 2>/dev/null | head -1)
fi
if [ -z "$TFEXE" ]; then
  BID=$(gh run list -w build -c "$HEAD" --json databaseId,conclusion -L 10 --jq '[.[]|select(.conclusion=="success")][0].databaseId' 2>/dev/null)
  [ -n "$BID" ] && [ "$BID" != null ] || finish 1 "REFUSED: no green 'build' run for ${HEAD:0:12} to take toastfire.exe from - pass --toastfire <exe> (gui-agent-package artifact)"
  log "downloading gui-agent-package from build run $BID (toastfire.exe)"
  gh run download "$BID" -n gui-agent-package -D "$DL/gui-agent-package" >"$OUT/gh-download-agentpkg.out" 2>&1 \
    || finish 1 "REFUSED: could not download gui-agent-package from build run $BID"
  TFEXE=$(find "$DL/gui-agent-package" -iname 'toastfire.exe' | head -1)
fi
[ -n "$TFEXE" ] && [ -s "$TFEXE" ] || finish 1 "REFUSED: toastfire.exe not found (and no --toastfire given)"
log "toastfire: $TFEXE ($(sha256sum "$TFEXE" | cut -c1-12))"

# the grader must prove itself on synthetic evidence before it grades anything (experimenter rule 3)
if ! python3 "$GRADER" --selftest > "$OUT/grader-selftest.txt" 2>&1; then
  finish 1 "INSTRUMENT: toast-hold-grade.py --selftest FAILED - see $OUT/grader-selftest.txt; nothing was graded"
fi
log "grader self-test: $(tail -1 "$OUT/grader-selftest.txt")"

python3 - "$OUT/meta.json" "$RID" "$PV" "$SHA" "$HOLD_BUILD" "$VM" "$OS" "$AUMID_A" "$AUMID_W" "$AUMID_C" "$AUMID_SYS" "$RUNID" <<'PY'
import json, sys, datetime
p, rid, pv, sha, hb, vm, os_, a, w, c, s, runid = sys.argv[1:]
json.dump({"run_id": rid, "package_version": pv, "driver_repo_commit": sha, "hold_build": int(hb), "subject": vm, "os": os_,
           "aumids": {"A": a, "W": w, "C": c, "SYS": s}, "runid": runid,
           "started_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}, open(p, "w"), indent=2)
PY

# ---- 1. the subject: quick-upgrade over the golden (minutes; the clean-install path is NOT under test) -------------
if [ "$REUSE" = 1 ] && qvm-check --quiet "$VM" 2>/dev/null; then
  log "--reuse-subject: $VM exists, quick-upgrade skipped (the installed agent is still verified below)"
  if [ "$(w_state "$VM")" = Halted ]; then
    timeout -k 8 90 ./tools/qtest start >/dev/null 2>&1
    w_usersession "$VM" 900 reuse-session "$OUT" log; rc=$?
    case $rc in 0) ;; 1) finish 1 "TERMINAL: $VM reached a terminal state before a user session";; *) finish 2 "DEADLINE: no user session on $VM within 900 s";; esac
  fi
else
  log "quick-upgrade: $ISO over ${OS}-qwt -> $VM (its log: $OUT/quick-upgrade/)"
  QU_OUT="$OUT/quick-upgrade" rl_fg mgmt/harness/quick-upgrade.sh "$ISO" "$VM" "$OS" > "$OUT/quick-upgrade.out" 2>&1
  rc=$?
  log "quick-upgrade rc=$rc: $(tail -2 "$OUT/quick-upgrade.out" | tr '\n' ' ' | cut -c1-300)"
  case $rc in
    0) ;;
    2) finish 2 "DEADLINE: quick-upgrade hit its deadline - $VM left as it stands (see $OUT/quick-upgrade.out)" ;;
    3) finish 1 "REFUSED by quick-upgrade (preconditions) - see $OUT/quick-upgrade.out" ;;
    *) finish 1 "FAIL: quick-upgrade did not verify the upgrade (rc=$rc) - the package did not install; see $OUT/quick-upgrade.out" ;;
  esac
  QU_MAN=$(ls -d "$OUT"/quick-upgrade/"$VM"-*/MANIFEST.json 2>/dev/null | tail -1)
  if [ -n "$QU_MAN" ]; then
    QSHA=$(python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get('source') or {}).get('driver_repo_commit','?'))" "$QU_MAN")
    [ "$QSHA" = "$SHA" ] || finish 1 "FAIL: the disc quick-upgrade installed from names commit ${QSHA:0:12}, this run's package is ${SHA:0:12}"
  fi
fi

# ---- 2. ARM the instruments, then ONE cold boot (every gate is read once at agent start: ADR-toasts 7) -----------
# ProtoTrace=1: QGAPROTO MAP lines are gated on it (send.c SendWindowMap, perf.h "ProtoTrace"); the hold's own lines are
# always on. NotifyBridgeAllow=[AUMID_C]: scenario 4's allowlisted app. service.notify-bridge=1: the bridge gate (off on
# an as-installed golden - a0-toast-bridge.sh P2/P3). Same knobs on control and candidate.
log "arming: ProtoTrace=1, NotifyBridgeAllow=[$AUMID_C], service.notify-bridge=1"
qvm-features "$VM" service.notify-bridge 1 || finish 1 "FAIL: qvm-features $VM service.notify-bridge 1 failed"
qrun "reg add \"$GAKEY\" /v ProtoTrace /t REG_DWORD /d 1 /f" >/dev/null
qrun "reg add \"$GAKEY\" /v NotifyBridgeAllow /t REG_MULTI_SZ /d \"$AUMID_C\" /f" >/dev/null
rq=$(qrun "reg query \"$GAKEY\" /v ProtoTrace" | tr -d '\r'; qrun "reg query \"$GAKEY\" /v NotifyBridgeAllow" | tr -d '\r')
printf '%s\n' "$rq" > "$OUT/arm-regquery.txt"
printf '%s' "$rq" | grep -qaE 'ProtoTrace\s+REG_DWORD\s+0x1' || finish 1 "INSTRUMENT: ProtoTrace did not read back as 0x1 ($OUT/arm-regquery.txt)"
printf '%s' "$rq" | grep -qa "$AUMID_C" || finish 1 "INSTRUMENT: NotifyBridgeAllow did not read back $AUMID_C ($OUT/arm-regquery.txt)"
BMARK0=$(blog_len) || finish 1 "INSTRUMENT: could not read the bridge.log line count before the arming reboot (never defaulted to 0)"
log "bridge.log before the arming reboot: $BMARK0 lines (this run's slice starts there)"
if ! reb=$(g_reboot_proven "$VM" armboot 2>"$OUT/armboot.err"); then
  if grep -qa 'no qrexec within' "$OUT/armboot.err"; then finish 2 "DEADLINE: arming cold boot - $(cat "$OUT/armboot.err")"; fi
  finish 1 "TERMINAL: arming cold boot not proven - $(cat "$OUT/armboot.err")"
fi
log "arming cold boot proven: boot id $reb"
w_usersession "$VM" 900 armboot "$OUT" log; rc=$?
case $rc in 0) ;; 1) finish 1 "TERMINAL: $VM reached a terminal state after the arming reboot";; *) finish 2 "DEADLINE: no user session within 900 s of the arming reboot";; esac

# ---- 3. the artefact under test IS installed and running ---------------------------------------------------------
have=$(qrun "certutil -hashfile \"$QT\\gui-agent.exe\" SHA256" | tr -d '\r' | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
[ "$have" = "$REF_AGENT" ] || finish 1 "FAIL: installed gui-agent.exe is '${have:-unreadable}', the package reference is $REF_AGENT - WRONG BUILD under test"
if [ "$REF_NOTIF" != "-" ]; then
  haven=$(qrun "certutil -hashfile \"$QT\\notifhost.exe\" SHA256" | tr -d '\r' | grep -aiE '^[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
  [ "$haven" = "$REF_NOTIF" ] || finish 1 "FAIL: installed notifhost.exe is '${haven:-unreadable}', the package reference is $REF_NOTIF"
fi
qrun 'cmd /c tasklist /fi "imagename eq gui-agent.exe" /nh' | _shell_echo_strip | grep -qa 'gui-agent\.exe' || finish 1 "FAIL: gui-agent.exe is not running after the arming reboot"
verdict IDENTITY "PASS installed gui-agent.exe == reference ${REF_AGENT:0:12}$([ "$REF_NOTIF" != - ] && echo ", notifhost.exe == reference ${REF_NOTIF:0:12}"), agent running"

# ---- 4. the guest-side instruments: push, locate, probe -----------------------------------------------------------
QTEST_VM=$VM timeout -k 8 180 ./tools/qtest push "$TFEXE" guest/toast-hold-collect.ps1 guest/toast-hold-fire.ps1 guest/run-as-user.ps1 >"$OUT/push.out" 2>&1 \
  || finish 1 "INSTRUMENT: qtest push of the helpers failed ($(tail -1 "$OUT/push.out"))"
where=$(QTEST_VM=$VM timeout -k 8 150 ./tools/qtest pushrun guest/toast-hold-collect.ps1 -Mode where 2>/dev/null | tr -d '\r' | grep -a '^THC ')
printf '%s\n' "$where" > "$OUT/where.txt"
INCOMING=$(printf '%s\n' "$where" | sed -n 's/^THC where=\(.*\)$/\1/p' | head -1)
[ -n "$INCOMING" ] || finish 1 "INSTRUMENT: the collector did not report its directory (pushrun yielded nothing - no user session for Filecopy?)"
export QTEST_INCOMING="$INCOMING"            # the dir every later -File call and raspush uses (a0-lib's INCOMING re-pointed)
ALOG=$(printf '%s\n' "$where" | sed -n 's/^THC logdir=.* agentlog=\([^ ]*\) agentlines=.*/\1/p' | head -1)
[ -n "$ALOG" ] || finish 1 "INSTRUMENT: no gui-agent-*.log in the guest's LogDir ($where)"
log "collector at $INCOMING; agent log $ALOG; $(printf '%s\n' "$where" | grep -a '^THC now=')"

thc(){ # $1=timeout $2...=collector args -> the THC lines only
  local to=$1; shift
  _q "$to" ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INCOMING\\toast-hold-collect.ps1\" -AgentLog $ALOG $*" | grep -a '^THC '
}
agent_grep(){ thc 90 -Mode agentgrep -Skip "$1" -PatternB64 "$(b64 "$2")" | sed -n 's/^THC L|//p'; }
bridge_grep(){ thc 90 -Mode bridgegrep -BridgeSkip "$1" -PatternB64 "$(b64 "$2")" | sed -n 's/^THC L|//p'; }
counts(){ thc 60 -Mode count | sed -n 's/^THC count //p' | head -1; }   # agentlog= agentlines= bridgelines= now=
amark(){ counts | sed -n 's/.*agentlines=\([0-9]*\).*/\1/p'; }
bmark(){ counts | sed -n 's/.*bridgelines=\([0-9]*\).*/\1/p'; }
HOLD_IPC_FAIL_RE='HOLD verdict event .* not opened|HOLD a bare --hold needs|HOLD section .* (not opened|not mapped|carries no valid header)'

# the bridge on this boot: heartbeat fresh, connected, armed with the allowlist, and (hold build) records live
hb=""; t0=$SECONDS
while :; do
  [ "$(hb_state)" = PRESENT ] && { hb=1; break; }
  [ $((SECONDS - t0)) -ge 180 ] && break
  w_alive "$VM" || { log "bridge heartbeat wait: TERMINAL - the guest stopped answering qrexec"; finish 1 "TERMINAL: guest deaf while waiting for the bridge heartbeat"; }
  sleep 5
done
[ -n "$hb" ] || finish 1 "FAIL: no fresh bridge heartbeat within 180 s of the user session (gate on, agent running) - the bridge did not start"
conn=""; t0=$SECONDS
while :; do
  bridge_grep "$BMARK0" 'connected \(server version' | grep -qa . && { conn=1; break; }
  [ $((SECONDS - t0)) -ge 120 ] && break
  sleep 5
done
[ -n "$conn" ] || finish 1 "FAIL: the bridge never logged 'connected (server version' within 120 s - nothing can be forwarded (dom0 policy? relay?)"
armed=$(bridge_grep "$BMARK0" 'BRIDGE armed allow=' | tail -1)
printf '%s' "$armed" | grep -qa "$AUMID_C" || verdict ALLOWLIST "INSTRUMENT the bridge armed without $AUMID_C ($armed) - scenario 4 cannot be graded as allowlisted"
gate=$(agent_grep 0 'QGATOASTHOLD gate|QGATOASTHOLD INERT' | head -3)
printf '%s\n' "$gate" > "$OUT/gate.txt"
if [ "$HOLD_BUILD" = 1 ]; then
  printf '%s' "$gate" | grep -qa 'gate: ACTIVE' || finish 1 "FAIL: hold build but the agent did not log 'QGATOASTHOLD gate: ACTIVE' ($(printf '%s' "$gate" | head -c 200)) - every bridged toast shows twice; precondition failed"
  bridge_grep "$BMARK0" 'HOLD records live' | grep -qa . || finish 1 "FAIL: hold build but the bridge never logged 'HOLD records live' - mixed install (old notifhost?)"
  # the bridge derives the section and verdict-event names from its --alive name (bare --hold, 2026-10-06): a failed open
  # of either is its own line - the section one is also caught above, the event one only here
  hfail=$(bridge_grep "$BMARK0" "$HOLD_IPC_FAIL_RE" | head -2)
  [ -z "$hfail" ] || finish 1 "FAIL: hold build but the bridge could not open its hold IPC: $(printf '%s' "$hfail" | head -c 240)"
else
  [ -z "$gate" ] || finish 1 "FAIL: the package was classified pre-hold but the agent logs QGATOASTHOLD ($(printf '%s' "$gate" | head -c 120)) - the build discriminator lied"
fi
verdict BRIDGE-UP "PASS heartbeat fresh, connected, $(printf '%s' "$armed" | sed 's/.*BRIDGE armed/armed/' | head -c 120)$([ "$HOLD_BUILD" = 1 ] && echo ', gate ACTIVE, records live')"

# the fire path needs an ACTIVE interactive session (run-as-user refuses without one; a0 P1d) - poll it, bounded
act=""; t0=$SECONDS
while :; do
  qu=$(qrun 'query user' 2>&1 | tr -d '\r')
  printf '%s' "$qu" | grep -qE '[[:space:]]Active([[:space:]]|$)' && { act=1; break; }
  [ "$(w_state "$VM")" = Halted ] && finish 1 "TERMINAL: the guest HALTED while waiting for an Active session"
  [ $((SECONDS - t0)) -ge 600 ] && break
  sleep 15
done
[ -n "$act" ] || finish 2 "DEADLINE: no Active interactive session within 600 s (last query user: $(printf '%s' "$qu" | tr '\n' '|' | head -c 200))"

# ---- 5. instrument proofs on the live guest ----------------------------------------------------------------------
# (a) the clock probe: charmap's CREATE ties the agent clock to the guest clock and proves ProtoTrace is on
thc 90 -Mode sync > "$OUT/sync.txt"
grep -qa 'THC sync t_start=.* t_seen=.* hwnd=0x' "$OUT/sync.txt" || finish 1 "INSTRUMENT: the clock probe found no charmap window ($(cat "$OUT/sync.txt" | head -c 200))"
PROBE_HWND=$(sed -n 's/.*hwnd=0x\([0-9a-fA-F]*\).*/\1/p' "$OUT/sync.txt" | head -1)
probe_create=""; t0=$SECONDS
while :; do
  agent_grep 0 "QGAPROTO,msg=CREATE,hwnd=0x$PROBE_HWND" | grep -qa . && { probe_create=1; break; }
  [ $((SECONDS - t0)) -ge 40 ] && break
  sleep 4
done
[ -n "$probe_create" ] || finish 1 "INSTRUMENT: no QGAPROTO CREATE for the probe window 0x$PROBE_HWND within 40 s - ProtoTrace is not on (or $ALOG is not the live log); MAP lines could never be seen"
log "clock probe: CREATE for 0x$PROBE_HWND present; $(grep -a 'THC sync' "$OUT/sync.txt" | tr '\n' ' ' | head -c 220)"

# (b) toastfire in the USER session: --print-xml yields payload_sha256 (data), a bogus flag yields NO 'FIRED method='
# (the detector can fail - toastfire's usage text contains the bare word FIRED, which is why the key is 'FIRED method=').
thf(){ # $1=tag $2=tokens -> wrapper output (USEROUT block included), \r stripped
  raspush guest/toast-hold-fire.ps1 "$2" "$1" 2>&1 | tr -d '\r'
}
tfx=$(thf "tfx$RUNID" "XML:--class+informational+--title+THT-$RUNID-probe BOGUS")
printf '%s\n' "$tfx" > "$OUT/toastfire-proof.txt"
printf '%s' "$tfx" | grep -qa 'payload_sha256=' || finish 1 "INSTRUMENT: toastfire --print-xml produced no payload_sha256 in the user session ($OUT/toastfire-proof.txt: $(printf '%s' "$tfx" | grep -a 'RUNASUSER\|THF' | head -2 | tr '\n' ' '))"
printf '%s' "$tfx" | grep -qa 'FIRED method=' && finish 1 "INSTRUMENT: the FIRED detector matched a print-xml/usage-error run - it cannot fail; aborting"
# (c) registrations: three apps (A, W: start-shortcut; C: com-activator) - idempotent, hermetic
reg=$(thf "treg$RUNID" "REG:start-shortcut REG:start-shortcut:$AUMID_W REG:com-activator")
printf '%s\n' "$reg" > "$OUT/toastfire-register.txt"
[ "$(printf '%s' "$reg" | grep -ac 'REGISTERED method=')" -ge 3 ] || finish 1 "INSTRUMENT: toastfire registration did not confirm 3 apps ($OUT/toastfire-register.txt)"
verdict INSTRUMENTS "PASS clock probe CREATE seen, toastfire print-xml data + bogus-flag silence, 3 AUMIDs registered"

# ---- 6. scenario machinery ---------------------------------------------------------------------------------------
BANNER_SEEN=0
# fire_steps <labels csv> <mode> <token template with @SLUGn@/@TAGn@> -> 0 all fired, 1 instrument (partial/terminal)
fire_steps(){
  local labels=$1 mode=$2 tpl=$3 attempt toks i out rec k
  local -a LBL; IFS=, read -ra LBL <<<"$labels"
  for attempt in 1 2 3; do
    toks=$tpl
    for i in "${!LBL[@]}"; do
      toks=${toks//@SLUG$((i+1))@/THT-$RUNID-${LBL[$i]}-t$attempt}
      toks=${toks//@TAG$((i+1))@/${LBL[$i]}-t$attempt}
    done
    out=$(thf "thf$RUNID$attempt$RANDOM" "$toks")
    printf '%s\n' "$out" > "$OUT/fires/${LBL[0]}-try$attempt.txt"
    if ! printf '%s' "$out" | grep -qa 'USEROUT_BEGIN'; then
      log "fire ${LBL[*]} attempt $attempt: no child output ($(printf '%s' "$out" | grep -a 'RUNASUSER' | head -1 | cut -c1-120)) - retrying"
      [ "$attempt" -lt 3 ] && sleep 8
      continue
    fi
    rec=$(printf '%s\n' "$out" | python3 "$GRADER" --record-fire --out "$OUT" --labels "$labels" --mode "$mode" --attempt "$attempt" 2>>"$R")
    log "fire ${LBL[*]} attempt $attempt: $rec"
    k=$(printf '%s' "$rec" | sed -n 's/^RECORDED fired=\([0-9]*\).*/\1/p')
    if [ "${k:-0}" -eq "${#LBL[@]}" ]; then
      [ "$attempt" -gt 1 ] && log "ANOMALY: ${LBL[*]} fired only on attempt $attempt (earlier attempts produced no FIRED; check STRAY in the grade)"
      return 0
    fi
    if [ "${k:-0}" -gt 0 ]; then
      log "fire ${LBL[*]}: PARTIAL ($k of ${#LBL[@]} FIRED) - recorded what fired, NOT retrying (a retry would add toasts)"
      return 1
    fi
    if printf '%s' "$out" | grep -qa 'THF step=.* rc='; then
      log "fire ${LBL[*]} attempt $attempt: toastfire ran and reported no FIRED ($(printf '%s' "$out" | grep -a '^ERROR' | head -1 | cut -c1-120)) - terminal for this stimulus"
      return 1
    fi
    [ "$attempt" -lt 3 ] && sleep 8
  done
  return 1
}
# wait_settled <n> <bridge mark> <deadline s>: the bridge listed and SETTLED n of this run's toasts past the mark
# (SENT ... title='THT-...' | skip id= aumid=QubesToastfire.*/the system AUMID | GIVE UP id=). 0 done / 1 terminal / 2 deadline
wait_settled(){
  local n=$1 bm=$2 dl=$3 t0=$SECONDS c
  while :; do
    c=$(bridge_grep "$bm" "SENT id=[0-9]+ app='[^']*' title='THT-|skip id=[0-9]+ aumid=(QubesToastfire\.|Windows\.SystemToast\.SecurityAndMaintenance)|GIVE UP id=" | grep -ac .)
    [ "${c:-0}" -ge "$n" ] && { log "  settled: $c bridge decision line(s) for this run's toasts at t+$((SECONDS - t0))s"; return 0; }
    [ $((SECONDS - t0)) -ge "$dl" ] && { log "  settle wait: DEADLINE ${dl}s with $c of $n settled"; return 2; }
    [ "$(hb_state)" = PRESENT ] || { log "  settle wait: TERMINAL - the bridge heartbeat is gone"; return 1; }
    sleep 4
  done
}
# wait_banner_cycle <deadline s>: the shell's banner window became VISIBLE in the guest and then not (one banner's
# life), using the HWNDs the agent itself logged. 0 cycled / 3 visible and STUCK (a reminder toast - dismiss it) /
# 2 never visible (no banner was shown: the expected shape for a suppressed-banner toast on the control) / 1 terminal.
# Sets BANNER_SEEN=1 if a banner was ever seen visible.
wait_banner_cycle(){
  local dl=$1 t0=$SECONDS seen=0 v
  BANNER_SEEN=0
  while :; do
    v=$(thc 60 -Mode bannervis | sed -n 's/.*visible=\([0-9]*\).*/\1/p' | head -1)
    [ -z "$v" ] && { w_alive "$VM" || { log "  banner wait: TERMINAL - guest deaf"; return 1; }; }
    if [ "${v:-0}" -gt 0 ]; then seen=1; BANNER_SEEN=1
    elif [ "$seen" = 1 ]; then log "  banner cycled (seen, then gone) at t+$((SECONDS - t0))s"; return 0; fi
    if [ $((SECONDS - t0)) -ge "$dl" ]; then
      if [ "$seen" = 1 ]; then log "  banner STILL visible at ${dl}s (a persistent toast)"; return 3; fi
      log "  no banner became visible within ${dl}s"; return 2
    fi
    sleep 2
  done
}
wait_banner_gone(){ # <deadline s>: 0 none visible / 1 terminal / 2 deadline
  local dl=$1 t0=$SECONDS v
  while :; do
    v=$(thc 60 -Mode bannervis | sed -n 's/.*visible=\([0-9]*\).*/\1/p' | head -1)
    [ -z "$v" ] && { w_alive "$VM" || { log "  banner-gone wait: TERMINAL - guest deaf"; return 1; }; }
    [ "${v:-0}" -eq 0 ] && return 0
    [ $((SECONDS - t0)) -ge "$dl" ] && { log "  banner-gone wait: DEADLINE ${dl}s, still visible"; return 2; }
    sleep 3
  done
}
record_wait(){ # <labels csv> <settled rc> <cycle rc>
  python3 - "$OUT/waits.jsonl" "$1" "$2" "$3" "$BANNER_SEEN" <<'PY'
import json, sys
p, labels, s, c, seen = sys.argv[1:]
open(p, "a").write(json.dumps({"labels": labels.split(","), "settled_rc": int(s), "cycle_rc": int(c), "guest_banner_seen": seen == "1"}) + "\n")
PY
}
# scenario <labels csv> <mode> <aumids to dismiss csv> <token template>
scenario(){
  local labels=$1 mode=$2 dism=$3 tpl=$4 n bm src crc a
  n=$(awk -F, '{print NF}' <<<"$labels")
  bm=$(bmark); [ -n "$bm" ] || { verdict "$labels" "INSTRUMENT could not read the bridge.log line count before firing"; return; }
  log "--- $labels ($mode): firing $n toast(s)"
  if ! fire_steps "$labels" "$mode" "$tpl"; then
    verdict "${labels%%,*}-STIM" "INSTRUMENT the stimulus for $labels did not fully fire (see $OUT/fires/) - rows graded on whatever fired"
  fi
  wait_settled "$n" "$bm" 90; src=$?
  wait_banner_cycle 25; crc=$?
  record_wait "$labels" "$src" "$crc"
  IFS=, read -ra DA <<<"$dism"
  for a in "${DA[@]}"; do dismiss_toasts "$a"; done
  wait_banner_gone 30 || log "  banner still visible after dismissing $dism (recorded; the grade reads the logs)"
}
FA="--fire+--method+start-shortcut+--class"
FW="--fire+--method+start-shortcut+--aumid+$AUMID_W+--class"
FC="--fire+--method+com-activator+--class"
FS="--fire+--method+bare+--aumid+$AUMID_SYS+--class"

# ---- 7. the scenarios ---------------------------------------------------------------------------------------------
AMARK0=$(amark); BMARK1=$(bmark)
log "scenarios start: agent log $ALOG at line $AMARK0, bridge.log at line $BMARK1"
# S0  the warm-up = the first toast of a classifier-routed app after the bridge started (graded like S1a)
scenario "S0"    seamless "$AUMID_W"            "FIRE:$FW+informational+--title+@SLUG1@+--tag+@TAG1@"
# S1  THE OWNER'S CASE: first informational toast of the (not allowlisted) app, then a second one
scenario "S1a"   seamless "$AUMID_A"            "FIRE:$FA+informational+--title+@SLUG1@+--tag+@TAG1@"
scenario "S1b"   seamless "$AUMID_A"            "FIRE:$FA+informational+--title+@SLUG1@+--tag+@TAG1@"
# S2  a real-choice (interactive, reminder) toast from the same app: must be OK-WINDOW; the old ShowBanner=0 made it LOST
scenario "S2"    seamless "$AUMID_A"            "FIRE:$FA+realchoice+--title+@SLUG1@+--tag+@TAG1@"
# S3  quick succession: bridged then window-path (in-place swap after the suppression), and window-path then bridged
#     (the pre-emption must unmap the shown banner BEFORE the bridged content paints into it)
scenario "S3i-1,S3i-2"   seamless "$AUMID_A,$AUMID_SYS" "FIRE:$FA+informational+--title+@SLUG1@+--tag+@TAG1@ GAP:$GAP_MS FIRE:$FS+informational+--title+@SLUG2@+--tag+@TAG2@"
scenario "S3ii-1,S3ii-2" seamless "$AUMID_SYS,$AUMID_A" "FIRE:$FS+informational+--title+@SLUG1@+--tag+@TAG1@ GAP:$GAP_MS FIRE:$FA+informational+--title+@SLUG2@+--tag+@TAG2@"
# S3iii window-path then window-path in the shared banner window: the hold unmaps the shown banner when the second toast arrives
#     in place and maps it again for that toast - the re-map dom0 needs the buffer re-announced for (REMAP-DUMP, 2026-10-06)
scenario "S3iii-1,S3iii-2" seamless "$AUMID_SYS,$AUMID_SYS" "FIRE:$FS+informational+--title+@SLUG1@+--tag+@TAG1@ GAP:$GAP_MS FIRE:$FS+informational+--title+@SLUG2@+--tag+@TAG2@"
# S4  an ALLOWLISTED app's first toast (NotifyBridgeAllow): bridge at listing, no classifier wait
scenario "S4"    seamless "$AUMID_C"            "FIRE:$FC+informational+--title+@SLUG1@+--tag+@TAG1@"

# S5  NON-SEAMLESS: dom0's qubes.SetGuiMode (policy: dom0/12-install-policy-tagged.sh allows this qube on tagged
#     guests); the agent publishes Seamless=0 and the bridge forwards nothing - every toast is the guest's own banner
#     inside the desktop window. Observed through the agent's "Seamless mode changed to N" and the bridge's "MODE ..."
#     lines, never assumed. Last, so its risks cannot contaminate S0-S4.
switch_mode(){ # <FULLSCREEN|SEAMLESS> <want seamless 0|1> -> 0 observed / 1 terminal / 2 deadline
  local word=$1 want=$2 am t0=$SECONDS rc
  am=$(amark)
  printf '%s' "$word" | timeout 60 qrexec-client-vm "$VM" qubes.SetGuiMode >"$OUT/setguimode-$word.out" 2>&1; rc=$?
  log "  qubes.SetGuiMode $word sent (rc=$rc; the mode change below is the evidence)"
  while :; do
    # The agent's own line is the switch: it publishes the mode into the hold section's header at that moment. The bridge reads
    # the header only while it LISTS a notification, so its "MODE ..." line comes with the next toast, not with the switch
    # (run 37499041570, 2026-10-06: the agent switched at 20:22:43, the bridge wrote nothing, and a wait that required the bridge
    # line timed out with S5 never exercised). The bridge's side is graded on the S5a toast itself (its non-seamless skip).
    if agent_grep "$am" "Seamless mode changed to $want" | grep -qa .; then
      log "  mode $word observed (agent) at t+$((SECONDS - t0))s"; return 0
    fi
    [ $((SECONDS - t0)) -ge 90 ] && { log "  mode $word: DEADLINE 90 s - not observed"; return 2; }
    w_alive "$VM" || { log "  mode $word: TERMINAL - guest deaf"; return 1; }
    sleep 5
  done
}
if [ "$SKIP_NS" = 1 ]; then
  verdict S5 "INFO not exercised by request (--skip-nonseamless): S5a/S5c carry no verdict in this run"
else
  if switch_mode FULLSCREEN 0; then
    scenario "S5a" nonseamless "$AUMID_A" "FIRE:$FA+informational+--title+@SLUG1@+--tag+@TAG1@"
    if switch_mode SEAMLESS 1; then
      scenario "S5c" seamless "$AUMID_A" "FIRE:$FA+informational+--title+@SLUG1@+--tag+@TAG1@"
    else
      verdict S5 "FAIL the guest did not return to seamless mode after qubes.SetGuiMode SEAMLESS (the agent never logged it) - left as it stands"
    fi
  else
    verdict S5 "INSTRUMENT the switch to non-seamless was not observed (qubes.SetGuiMode FULLSCREEN; see $OUT/setguimode-FULLSCREEN.out) - scenario 5 not exercised"
    switch_mode SEAMLESS 1 >/dev/null 2>&1 || log "  WARNING: SEAMLESS restore after the unobserved switch was not observed either - check the guest's mode"
  fi
fi

# ---- 8. pull both logs (counts + sha verified), grade, aggregate -------------------------------------------------
final=$(counts)
ALOG_FINAL=$(printf '%s' "$final" | sed -n 's/.*agentlog=\([^ ]*\).*/\1/p')
newest=$(thc 60 -Mode where | sed -n 's/^THC logdir=.* agentlog=\([^ ]*\) agentlines=.*/\1/p' | head -1)
python3 - "$OUT/meta.json" "$ALOG" "${newest:-$ALOG_FINAL}" "$BMARK0" "$AMARK0" <<'PY'
import json, sys
p, alog, newest, bm, am = sys.argv[1:]
m = json.load(open(p)); m.update({"agent_log": alog, "agent_log_final": newest, "bridge_mark0": int(bm or 0), "agent_mark0": int(am or 0)})
json.dump(m, open(p, "w"), indent=2)
PY
pulled=""
for attempt in 1 2; do
  thc 170 -Mode pull -BridgeSkip "$BMARK0" > "$OUT/pull.txt"
  if python3 "$GRADER" --decode-pull "$OUT/pull.txt" --out "$OUT" > "$OUT/pull-decode.txt" 2>&1; then pulled=1; break; fi
  log "pull attempt $attempt did not verify: $(tr '\n' ';' < "$OUT/pull-decode.txt" | cut -c1-200)"
done
[ -n "$pulled" ] || finish 1 "INSTRUMENT: the log pull never verified (counts/sha) - no evidence to grade ($OUT/pull-decode.txt)"
log "pulled: $(tr '\n' ';' < "$OUT/pull-decode.txt" | cut -c1-200)"

python3 "$GRADER" --grade --out "$OUT" > "$OUT/grade.txt" 2>&1; grc=$?
grep -a '^GRADED|' "$OUT/grade.txt" | sed 's/^GRADED|/GRADED: /' | tee -a "$R"
grep -a -E '^(S[0-9][a-z0-9-]*|CLOCK|HOLD-GATE|HOLD-IPC|BRIDGE|BRIDGE-RESTART|BRIDGE-DOWN|IDENT-FAILOPEN|STRAY|AGENT-LOG|DETECTORS)\|' "$OUT/grade.txt" | sed 's/^/  /' | tee -a "$R" >/dev/null

# cleanup of the guest's user-side residue (never fatal; the subject is disposable anyway)
thf "tunreg$RUNID" "UNREG:start-shortcut UNREG:start-shortcut:$AUMID_W UNREG:com-activator" > "$OUT/toastfire-unregister.txt" 2>&1
for a in "$AUMID_A" "$AUMID_W" "$AUMID_C" "$AUMID_SYS"; do dismiss_toasts "$a"; done

verdict_aggregate "$OUT/verdicts.txt" '^GRADED$'; agg=$?
verdict_done_line "subject=$VM package=$PV commit=${SHA:0:12} role=$ROLE evidence=$OUT" | tee -a "$R"
if [ "$agg" -eq 0 ] && [ "$grc" -eq 0 ]; then
  qwt_shutdown "$VM" 300 >/dev/null 2>&1 && log "subject $VM shut down cleanly" || log "subject $VM did not halt within 300 s - left running"
  finish 0 "PASS ($ROLE): $(grep -a '^GRADED|' "$OUT/grade.txt" | sed 's/.*-> //')"
fi
finish 1 "NOT PASSED ($ROLE): verdicts status=$VS_STATUS grader rc=$grc - $VM LEFT RUNNING as evidence; read $OUT/grade.txt, $OUT/agent.log, $OUT/bridge.log, $OUT/fires/"
