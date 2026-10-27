#!/bin/bash
# primitives.sh - the SIX sealed primitives, one definition each. Source this; do not re-implement.
#
#   source mgmt/harness/primitives.sh
#
# Each one WRAPS the committed tool that already does the work - it does not re-do it. The point is
# that there is ONE door, so a caller cannot reach the work by a second route that skips the gates:
#   fresh_cell_log    -> mgmt/harness/collect-failure.sh    (logvol first, sweep, snapshot, manifest)
#   query_diagnosis   -> tools/verdict-jev.py               (the semantic judge, fed from that package)
#   clock_correct     -> tools/qtest synctime + skew check  (the single clock entry point)
#   toolstack_accept  -> qvm-shutdown, recording ACCEPTANCE separately from the outcome
#   package_identity  -> sha256 of the staged binary vs the guest's
#   golden_recreate   -> mgmt/harness/golden_recreate.sh    (the only reseal path)
#
# THE ATTEMPT DISCIPLINE lives here too, because thirty copies of it is the defect it exists to stop:
# every artefact's first line is "ATTEMPT <run-id> <utc>", every path carries the run-id, a directory
# holding another run-id is a CONTAMINATED SUBJECT and the caller exits non-zero before any product
# work, and a run-exactly-once script writes COMPLETE-<run-id> and is idempotent.
#
# NO `set` LINE. This is a sourced library and every other one here (logvol-lib, shutdown-lib,
# vmlock, e2e-wait) leaves the caller's shell options alone; a library that silently turns on -u
# changes the behaviour of every script that sources it.

_P_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_p_say(){ printf '%s prim: %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }
_p_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_P_QTEST="${QTEST_BIN:-$_P_ROOT/tools/qtest}"
# The collector is overridable for the same reason QTEST is: a smoke script that calls it has to
# be drivable by a suite WITHOUT touching the rig. collect-failure.sh reaches dom0, and
# run-offline-suites.sh makes any rig call from an offline suite RED whatever its exit code.
# collect-failure.sh already carries QTEST_BIN / LOGSWEEP_BIN / WEDGE_CORE_BIN for this; the
# collector itself had no knob, so the suite driving the failure arms fired 9 real admin calls.
_P_COLLECT="${COLLECT_BIN:-$_P_ROOT/mgmt/harness/collect-failure.sh}"

# ---------------------------------------------------------------- the attempt discipline

# attempt_id - the run-id every artefact is scoped by. Derived ONCE per process, never per call, or
# two artefacts of the same run disagree about their own id.
attempt_id(){
  if [ -n "${RUN_ID:-}" ]; then printf '%s' "$RUN_ID"; return 0; fi
  # THE MEMO MUST SURVIVE A COMMAND SUBSTITUTION, which an exported variable cannot: `export` inside
  # $( ) never reaches the parent, so every $(primitive ...) that was first to ask in its own
  # subshell minted a fresh id. Only the UTC part differed, so two calls in the SAME SECOND agreed
  # and calls either side of a second boundary did not. Measured 2026-10-27 against win11-acc:
  # unusable_evidence refused after a SUCCESSFUL toolstack_accept, because the two had written
  # different ledgers (...170703Z... and ...170707Z...) - and the run before it had "passed" only
  # because both calls happened to land inside one second. A gate that depends on the clock ticking
  # is not a gate. $$ is the MAIN shell's pid and IS inherited by every subshell, so it keys a file
  # that all of them can see; `set -C` makes the first writer the only writer.
  local memo="${TMPDIR:-/tmp}/qwt-attempt-$$.id"
  if [ ! -s "$memo" ]; then
    ( set -C; printf '%s-%s\n' "$(_p_utc | tr -d ':-')" "$$" > "$memo" ) 2>/dev/null || true
  fi
  RUN_ID=$(cat "$memo" 2>/dev/null)
  [ -n "$RUN_ID" ] || RUN_ID="$(_p_utc | tr -d ':-')-$$"
  export RUN_ID
  printf '%s' "$RUN_ID"
}

# attempt_open <file> - truncate <file> and write its ATTEMPT line. NEVER append to a cell log: a
# campaign's artefacts used to accumulate across attempts, and then a FILE could not scope a RUN.
attempt_open(){
  local f="${1:?attempt_open <file>}"
  mkdir -p "$(dirname "$f")" || return 1
  printf 'ATTEMPT %s %s\n' "$(attempt_id)" "$(_p_utc)" > "$f"
}

# attempt_check <file> - refuse a file whose first line is not THIS attempt's. A consumer that reads
# a previous run's artefact and calls it a result is this project's most repeated failure.
attempt_check(){
  local f="${1:?attempt_check <file>}" first
  [ -r "$f" ] || { _p_say "[ERROR] no artefact at $f"; return 1; }
  first="$(head -1 "$f")"
  case "$first" in
    "ATTEMPT $(attempt_id) "*) return 0 ;;
    ATTEMPT*) _p_say "[ERROR] contaminated subject: $f carries '$first', this attempt is $(attempt_id)"; return 1 ;;
    *) _p_say "[ERROR] $f has no ATTEMPT line - it was not written by this discipline"; return 1 ;;
  esac
}

# attempt_dir <dir> - the clean-subject gate. Non-zero BEFORE any product work when <dir> already
# holds a different run-id.
attempt_dir(){
  local d="${1:?attempt_dir <dir>}" f other
  if [ -d "$d" ]; then
    for f in "$d"/ATTEMPT-*; do
      [ -e "$f" ] || continue
      other="${f##*/ATTEMPT-}"
      [ "$other" = "$(attempt_id)" ] && continue
      _p_say "[ERROR] contaminated subject: $d holds attempt $other, this attempt is $(attempt_id)"
      return 1
    done
  fi
  mkdir -p "$d" || return 1
  : > "$d/ATTEMPT-$(attempt_id)"
}

complete_once(){ [ -e "${1:?complete_once <dir>}/COMPLETE-$(attempt_id)" ]; }
complete_mark(){ : > "${1:?complete_mark <dir>}/COMPLETE-$(attempt_id)"; }

# ---------------------------------------------------------------- 1. fresh_cell_log

# fresh_cell_log <vm> <outdir> <since-utc> <logvol-img|none> <reason> [extra collect-failure args...]
#
# THE ONLY log collector. It is a run-id-scoped door onto collect-failure.sh, which reads the
# SECONDARY VOLUME FIRST on the host (so a wedged specimen is read while still wedged, nothing
# detached, nothing shut down), then sweeps, snapshots, and writes the manifest LAST.
#
# "Only the current cell's logs" is ENFORCED, not asserted: the package lands in a per-run-id
# directory, attempt_dir refuses a directory another attempt owns, and the manifest is what marks it
# collected. Prints the cell directory on stdout; the caller passes THAT to query_diagnosis and never
# globs for logs itself.
#
# Exit: 0 package complete; 1 package written WITH GAPS (each named in manifest.json gaps[]);
#       2 nothing was written. A gap is never silently a pass.
fresh_cell_log(){
  local vm="${1:?fresh_cell_log <vm> <outdir> <since> <logvol|none> <reason>}"
  local out="${2:?}" since="${3:?}" img="${4:?}" reason="${5:?}"
  shift 5
  local cell="$out/cell-$(attempt_id)" rc=0
  attempt_dir "$cell" || return 2
  if complete_once "$cell"; then printf '%s\n' "$cell"; return 0; fi
  attempt_open "$cell/cell.txt"
  printf 'vm %s\nsince %s\nlogvol %s\nreason %s\n' "$vm" "$since" "$img" "$reason" >> "$cell/cell.txt"
  "$_P_COLLECT" "$vm" "$cell/package" "$reason" \
      --since "$since" --logvol "$img" "$@" >> "$cell/collect.out" 2>&1 || rc=$?
  printf 'collect rc=%s\n' "$rc" >> "$cell/cell.txt"
  [ "$rc" -le 1 ] && complete_mark "$cell"
  printf '%s\n' "$cell"
  return "$rc"
}

# cell_package <cell-dir> - where fresh_cell_log put the package. The one place that knows the layout.
cell_package(){ printf '%s/package\n' "${1:?cell_package <cell-dir>}"; }

# ---------------------------------------------------------------- 2. query_diagnosis

# query_diagnosis <cell-dir> [--declare-error <regex> <why>]...
#
# Opens no log file of its own: it is handed a directory fresh_cell_log produced, refuses it unless
# the manifest exists (a run is COLLECTED only then) and the cell record is THIS attempt's, resolves
# the package's report/snapshot paths, and hands them to the committed judge.
#
# Exit: 0 nothing needs analysis; 1 the judge named items (read verdict.json items_needing_analysis);
#       2 THE INSTRUMENT DID NOT RUN - never a pass; 3 a --declare-error matched nothing, so the
#       declaration was false and the run fails.
query_diagnosis(){
  local cell="${1:?query_diagnosis <cell-dir> [--declare-error RE WHY]...}"; shift
  local pkg f; local -a sweeps=()
  pkg="$(cell_package "$cell")"
  attempt_check "$cell/cell.txt" || return 2
  [ -s "$pkg/manifest.json" ] \
    || { _p_say "[ERROR] no manifest at $pkg/manifest.json - the run was never COLLECTED, so there is nothing to diagnose"; return 2; }
  [ -s "$pkg/activity-snapshot.json" ] \
    || { _p_say "[ERROR] no activity-snapshot.json in $pkg - the judge's state would be blank"; return 2; }
  for f in "$pkg/sweep/report.json" "$pkg/sweep-offline/report.json"; do
    [ -s "$f" ] && sweeps+=(--sweep "$f")
  done
  [ ${#sweeps[@]} -gt 0 ] \
    || { _p_say "[ERROR] no sweep report in $pkg (neither live nor offline) - nothing was analysed"; return 2; }
  python3 "$_P_ROOT/tools/verdict-jev.py" "${sweeps[@]}" \
      --snapshot "$pkg/activity-snapshot.json" \
      --out "$cell/verdict.json" --label "cell-$(attempt_id)" "$@"
}

# ---------------------------------------------------------------- 3. clock_correct

# clock_correct <vm> [max-skew-seconds]
#
# The single synctime + skew-check entry point; every cell ENTRY path calls it. qtest synctime has
# existed since 2026-08-11 saying "call this after every VM start" and for a long time had no caller
# at all - a guest an hour behind refuses the payload's driver catalogs (0x800B0101) and takes the
# whole cell with it. The skew is then VERIFIED against a second clock, because synctime returning
# zero is not the same fact as the clock being right.
#
# Exit: 0 verified within bound; 1 out of bound; 2 UNMEASURED (which is not a pass).
clock_correct(){
  local vm="${1:?clock_correct <vm> [max-skew]}" bound="${2:-120}" hnow gutc skew
  QTEST_VM="$vm" "$_P_QTEST" synctime >/dev/null 2>&1 \
    || _p_say "[WARN] qtest synctime returned non-zero on $vm - verifying the clock regardless"
  hnow=$(date -u +%s)
  gutc=$(QTEST_VM="$vm" "$_P_QTEST" run \
           "powershell -NoProfile -Command \"[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')\"" 2>/dev/null \
         | tr -d '\r\0' | grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | head -1)
  if [ -z "$gutc" ]; then
    _p_say "[ERROR] INVALID-INSTRUMENT - could not read $vm's clock; skew UNMEASURED"
    printf 'CLOCKCORRECT vm=%s measured=0\n' "$vm"
    return 2
  fi
  skew=$(( $(date -u -d "$gutc" +%s) - hnow ))
  printf 'CLOCKCORRECT vm=%s guest=%s skew=%ss bound=%ss\n' "$vm" "$gutc" "$skew" "$bound"
  if [ "${skew#-}" -gt "$bound" ]; then
    _p_say "[ERROR] INVALID-INSTRUMENT - $vm's clock is ${skew}s from this host AFTER qtest synctime (guest says $gutc); the installer would refuse its driver catalogs as not-yet-valid"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- 4. toolstack_accept

# toolstack_accept <vm> [acpi]
#
# Records whether QUBESD ACCEPTED the request - a different fact from whether the guest then went
# down. A refused request and an ignored one look identical in a log that reports only the final
# state, and that is how "the guest will not shut down" has been reported for a request the toolstack
# never took.
#
# IT NEVER PASSES --wait. `qvm-shutdown --wait` defaults to --timeout 60 and DESTROYS the domain
# when that expires; tools/tests/wedge-gates-selftest.sh asserts that neither the wedge library nor
# release-acceptance.sh ever spells it, because a destroyed domain is a destroyed specimen. A bare
# qvm-shutdown IS the ACPI request: it returns at once, kills nothing, and is idempotent. Callers
# that need "did it actually halt" poll for it themselves (w_halt / shutdown-lib), which is what
# every existing call site already does.
#
# Exit: 0 the toolstack accepted the request; 1 it refused - the line carries rc and the detail.
# Every acceptance is also RECORDED to a run-id-scoped file, so a later verdict can cite what the
# toolstack did without re-issuing the request. Re-asking to find out would destroy a specimen that
# is still evidence.
toolstack_record(){ printf '%s\n' "${TOOLSTACK_RECORD:-${TMPDIR:-/tmp}/toolstack-$(attempt_id).txt}"; }

toolstack_accept(){
  local vm="${1:?toolstack_accept <vm> [acpi]}" req="${2:-acpi}" out rc line rec
  case "$req" in
    acpi) : ;;
    *) _p_say "[ERROR] toolstack_accept: '$req' is not a request this records. There is one: the bare ACPI request. A waiting form would need --wait, which destroys the domain"; return 2 ;;
  esac
  out=$(qvm-shutdown "$vm" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    line="TOOLSTACKACCEPT vm=$vm req=$req accepted=1 rc=0"
  else
    line="TOOLSTACKACCEPT vm=$vm req=$req accepted=0 rc=$rc detail=$(printf '%s' "$out" | tr -d '\r\n' | cut -c1-160)"
  fi
  rec="$(toolstack_record)"
  mkdir -p "$(dirname "$rec")" 2>/dev/null
  [ -s "$rec" ] || attempt_open "$rec"   # run-id-scoped, and truncated for a NEW run-id, never blind-appended across runs
  printf '%s\n' "$line" >> "$rec"
  printf '%s\n' "$line"
  [ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------- 5. package_identity

# package_identity <vm> <setup-root>
#
# Asserts the binary ON THE GUEST is the one this package built: sha256 of the setup tree's staged
# reference against the file the guest is running. A campaign can otherwise grade the wrong build for
# a whole run with every check green.
#
# Exit: 0 match; 1 MISMATCH (the wrong build is under test); 2 UNCHECKED (which is not a match).
package_identity(){
  local vm="${1:?package_identity <vm> <setup-root>}" setup="${2:?}" ref got
  if [ ! -s "$setup/reference/gui-agent.exe" ]; then
    _p_say "[ERROR] no reference binary at $setup/reference/gui-agent.exe - identity UNCHECKED"
    printf 'PACKAGEIDENTITY vm=%s checked=0\n' "$vm"; return 2
  fi
  ref=$(sha256sum "$setup/reference/gui-agent.exe" | awk '{print $1}')
  got=$(QTEST_VM="$vm" "$_P_QTEST" run \
          "powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe').Hash\"" 2>/dev/null \
        | tr -d '\r\0' | grep -aoE '[0-9A-Fa-f]{64}' | head -1)
  if [ -z "$got" ]; then
    _p_say "[ERROR] could not hash $vm's gui-agent.exe - identity UNCHECKED"
    printf 'PACKAGEIDENTITY vm=%s checked=0\n' "$vm"; return 2
  fi
  if [ "${got,,}" = "${ref,,}" ]; then
    printf 'PACKAGEIDENTITY vm=%s match=1 sha=%s\n' "$vm" "${ref:0:12}"; return 0
  fi
  printf 'PACKAGEIDENTITY vm=%s match=0 guest=%s reference=%s\n' "$vm" "${got:0:12}" "${ref:0:12}"
  _p_say "[ERROR] $vm runs ${got:0:12}, this package built ${ref:0:12} - the measurement would be of the wrong build"
  return 1
}

# ---------------------------------------------------------------- the unusable-guest evidence gate

# unusable_evidence <vm> <cell-dir> - call this BEFORE emitting any "no usable guest" / "qrexec
# silent" verdict. It REQUIRES two values to have been recorded already: the last qrexec packet type
# the guest handled (from the collected package's activity-snapshot.json, read on the HOST, so it
# survives a wedge) and a toolstack_accept result for this guest in this run. If either is missing
# the verdict is NOT entitled to be emitted: "qrexec silent" with no record of the last packet, and
# no record of whether the toolstack even took a request, is a guess wearing a verdict's clothes.
#
# IT DOES NOT ASK FOR THE SHUTDOWN ITSELF. Issuing ACPI to find out whether the toolstack would
# accept it destroys a specimen that is still evidence - and the specimen stays alive. The caller
# asks (wedge-gates-lib already does, as the LAST conjunct of the wedge definition) and this gate
# checks that the answer was written down. A gate that manufactures its own evidence is not a gate.
#
# Exit: 0 both values recorded (the caller may now emit its verdict); 1 incomplete evidence.
# qrexec_last_packet <vm> <dir> - the ONE reader of the last qrexec packet type. It takes it from a
# collected activity-snapshot.json (written host-side, so it survives a wedge), records it in
# <dir>/last-qrexec, and prints it: the packet type, 'none' when the snapshot recorded none, or
# 'unrecorded' when no snapshot exists. 'unrecorded' is not 'none' - one is a measurement, the other
# is the absence of one, and a verdict may not rest on the second.
qrexec_last_packet(){
  local vm="${1:?qrexec_last_packet <vm> <dir>}" d="${2:?}" snap="" c val=""
  for c in "$d/package/activity-snapshot.json" "$d/activity-snapshot.json"; do
    [ -s "$c" ] && { snap="$c"; break; }
  done
  if [ -n "$snap" ]; then
    val=$(python3 - "$snap" <<'PY' 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(""); raise SystemExit(0)
q = s.get("last_qrexec_pair") or {}
print(q.get("command") or q.get("cmdline") or ("none" if "last_qrexec_pair" in s else ""))
PY
)
  fi
  [ -n "$val" ] || val=unrecorded
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$val" > "$d/last-qrexec" 2>/dev/null
  printf '%s\n' "$val"
}

unusable_evidence(){
  local vm="${1:?unusable_evidence <vm> <cell-dir>}" cell="${2:?}" pair acc rec
  pair=$(qrexec_last_packet "$vm" "$cell")
  if [ "$pair" = unrecorded ]; then
    _p_say "[ERROR] incomplete evidence: no last qrexec packet type for $vm (no activity-snapshot was collected) - the unusable verdict is NOT emitted"
    return 1
  fi
  rec="$(toolstack_record)"
  acc=$(grep -a "^TOOLSTACKACCEPT vm=$vm " "$rec" 2>/dev/null | tail -1)
  if [ -z "$acc" ]; then
    _p_say "[ERROR] incomplete evidence: no toolstack_accept result recorded for $vm in $rec - ask (toolstack_accept $vm acpi) and record it before claiming the guest is unusable; the unusable verdict is NOT emitted"
    return 1
  fi
  printf 'UNUSABLEEVIDENCE vm=%s last_qrexec=%s %s\n' "$vm" "$pair" "$acc"
  return 0
}

# unusable_verdict <vm> <outdir> <since-utc> <logvol|none> <reason>
#
# The whole Step-15 sequence, in ONE place so the order cannot drift between call sites:
#   1. collect the package through fresh_cell_log - logs off the volume on the host, the liveness
#      probe, the wedge classification and, on a classified wedge, the memory image;
#   2. ONLY THEN ask ACPI through toolstack_accept, which records whether qubesd took it. This is
#      the last conjunct of the wedge definition and it is asked last for the same reason: until the
#      package exists, asking can destroy the thing being asked about;
#   3. check both values are recorded (unusable_evidence) and print the evidence line.
#
# Prints the evidence line on stdout when the caller is entitled to its verdict. Exit: 0 entitled;
# 1 INCOMPLETE EVIDENCE - the caller must say what is missing and must NOT call the guest unusable.
unusable_verdict(){
  local vm="${1:?unusable_verdict <vm> <outdir> <since> <logvol|none> <reason>}"
  local out="${2:?}" since="${3:?}" img="${4:?}" reason="${5:?}" cell
  cell=$(fresh_cell_log "$vm" "$out" "$since" "$img" "$reason") || true
  [ -n "$cell" ] || { _p_say "[ERROR] incomplete evidence: no package was collected for $vm"; return 1; }
  toolstack_accept "$vm" acpi >/dev/null 2>&1 || true
  unusable_evidence "$vm" "$cell"
}

# ---------------------------------------------------------------- 6. golden_recreate
# The sixth is a script, because it is a procedure with its own gates and must be quotable verbatim
# in a Jev state: mgmt/harness/golden_recreate.sh --golden <name> --base <pristine-base>
