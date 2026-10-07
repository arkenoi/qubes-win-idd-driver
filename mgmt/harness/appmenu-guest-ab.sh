#!/usr/bin/env bash
# appmenu-guest-ab.sh - the appmenu report, read FROM A GUEST, old script vs new, same boot.
#
# WHY A GUEST AT ALL. tools/tests/appmenus-selftest.sh drives the pure decisions offline over a
# measured Start Menu and that is where the branch coverage lives - but it cannot show that the
# whole script still RUNS on Windows PowerShell 5.1, still exits 0 (a non-zero exit loses dom0's
# entire application list), still emits well-formed lines, and that the exclusion fires against a
# real Start Menu rather than a text fixture. Jev, asked whether the offline replay was enough:
# guest_run_needed 0.78.
#
# HYPOTHESIS  the new script reports materially fewer entries than the installed one, with zero
#             "Administrative" entries, exactly one "Microsoft Edge", and no folder-prefixed names.
# CONTROL     the INSTALLED script, run first, on the same guest and the same boot. It carries the
#             defect, so the checks are seen to FAIL before they are seen to pass.
# VARIABLE    one file: get-appmenus.ps1. Nothing else is touched.
# INSTRUMENT  the service's own stdout, captured per run; counts and classification in code here,
#             never by eye. The pushed file is hashed against the local one before it is used.
# BUDGET      boot <= 8 min with three exits; two runs ~1 min each; teardown always.
#
# NOTHING OF THIS REACHES THE OWNER'S SCREEN, deliberately: the subject is created with guivm ''
# (headless - dom0 displays no window of it at all) and with service.notify-bridge 0, so the
# guest's notifications are not forwarded either. The owner has twice had a test guest's toasts
# land on his desktop; a text service does not need a GUI to be measured.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# Both guests are NAMED by the caller, never defaulted: a harness that picks its own target
# eventually picks the wrong one (lint rule L10).
GOLDEN="${GOLDEN:-}"
VM="${VM:-}"
[ -n "$GOLDEN" ] && [ -n "$VM" ] || {
    echo "usage: GOLDEN=<golden to clone> VM=<disposable subject> $0" >&2
    echo "       e.g. GOLDEN=win11de-qwt VM=win11de-amab $0" >&2
    exit 2
}
OUT="${OUT:-$HOME/qwt-appmenu/$(date -u +%m%d-%H%M)}"
SRC="$ROOT/core-agent/src/qubes-rpc-services/get-appmenus.ps1"
GUEST_PATH='C:\Program Files\Qubes Tools\qubes-rpc-services\get-appmenus.ps1'
mkdir -p "$OUT"
log(){ echo "$(date -u +%H:%M:%SZ) amab[$VM]: $*"; }

[ -f "$SRC" ] || { log "FAIL $SRC missing"; exit 2; }

source mgmt/harness/vmlock.sh
source mgmt/harness/shutdown-lib.sh
vm_lock "$VM" "appmenu-guest-ab.sh"

teardown(){
  local rc=$?
  log "teardown (rc=$rc)"
  qwt_shutdown "$VM" 300 >/dev/null 2>&1 || qvm-kill "$VM" >/dev/null 2>&1
  [ "${KEEP:-0}" = 1 ] || qvm-remove -f "$VM" >/dev/null 2>&1
  log "teardown done; results in $OUT"
}
trap teardown EXIT INT TERM

# ---- a disposable clone of the German golden, headless and silent -------------------------------
qwt_shutdown "$VM" 240 >/dev/null 2>&1 || true
qvm-remove -f "$VM" >/dev/null 2>&1 || true
log "cloning $GOLDEN -> $VM"
mgmt/clone-guest.sh "$GOLDEN" "$VM" >>"$OUT/clone.log" 2>&1 || { log "FAIL clone - see $OUT/clone.log"; exit 2; }
qvm-prefs "$VM" guivm '' || { log "FAIL could not make it headless - refusing to boot it"; exit 2; }
qvm-features "$VM" service.notify-bridge 0
log "headless (guivm '') and service.notify-bridge=0 - no window and no toast of this guest reaches dom0"

export QTEST_VM="$VM"
log "starting"
qvm-start "$VM" >>"$OUT/start.log" 2>&1 || { log "FAIL start - see $OUT/start.log"; exit 2; }

# ---- wait for a logged-on session: three exits, and it says which it took -----------------------
# dom0 calls this service as the qube's default user, so the reading is only faithful inside that
# user's session - SYSTEM has a different Start Menu.
deadline=$((SECONDS + 480)); exitby=""; last=""
while [ $SECONDS -lt $deadline ]; do
  st=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tail -1)
  if [ "$st" != "Running" ]; then exitby="terminal: state=$st"; break; fi
  who=$(tools/qtest run 'powershell -NoProfile -Command "(Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).Id"' 2>/dev/null | tr -d '\r' | command grep -oE '^[0-9]+$' | head -1)
  if [ -n "$who" ]; then exitby="session (explorer pid $who)"; break; fi
  [ "$last" = "$st" ] || log "  waiting: state=$st"
  last="$st"; sleep 15
done
[ -n "$exitby" ] || exitby="deadline (480 s)"
log "wait exit: $exitby"
case "$exitby" in session*) ;; *) log "FAIL no session - nothing measured (missing data fails)"; exit 2;; esac

# ---- run the report twice: installed script, then ours ------------------------------------------
report(){ # $1 = label
  tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$GUEST_PATH\"" > "$OUT/$1.raw" 2>&1
  # the stream carries cmd's banner; keep only service lines (memory: vmshell-stream-has-cmd-banner)
  tr -d '\r' < "$OUT/$1.raw" | command grep -E '^[A-Za-z0-9._-]+\.desktop:[A-Za-z]+=' > "$OUT/$1.lines" || true
  wc -l < "$OUT/$1.lines"
}

log "A: the INSTALLED script (the control - it carries the defect)"
n_a=$(report A)
log "   $n_a report lines"

log "pushing the script under test and verifying it is what landed"
tools/qtest push "$SRC" 'C:\Windows\Temp\get-appmenus.new.ps1' >>"$OUT/push.log" 2>&1 || { log "FAIL push"; exit 2; }
want=$(sha256sum "$SRC" | cut -d' ' -f1)
got=$(tools/qtest run 'powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 C:\Windows\Temp\get-appmenus.new.ps1).Hash"' 2>/dev/null | tr -d '\r' | command grep -oiE '^[0-9a-f]{64}$' | head -1)
if [ "$(echo "$got" | tr 'A-Z' 'a-z')" != "$want" ]; then
  log "FAIL the pushed file is not the file under test (want ${want:0:16}, got ${got:0:16}) - nothing proven"
  exit 2
fi
log "   hash matches: ${want:0:16}..."
tools/qtest run "powershell -NoProfile -Command \"Copy-Item -LiteralPath C:\\Windows\\Temp\\get-appmenus.new.ps1 -Destination '$GUEST_PATH' -Force; 'copied'\"" >>"$OUT/push.log" 2>&1
got2=$(tools/qtest run "powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 '$GUEST_PATH').Hash\"" 2>/dev/null | tr -d '\r' | command grep -oiE '^[0-9a-f]{64}$' | head -1)
[ "$(echo "$got2" | tr 'A-Z' 'a-z')" = "$want" ] || { log "FAIL the installed path still holds the old script"; exit 2; }
log "   the INSTALLED path now holds the script under test"

log "B: the script under test"
n_b=$(report B)
log "   $n_b report lines"

# ---- grade: every check is read on BOTH arms, so each is seen to fail on the control ------------
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
names(){ command grep -E ':Name=' "$OUT/$1.lines" | sed 's/.*:Name=//'; }
count(){ names "$1" | wc -l; }
echo
echo "--- the guest's own reading -------------------------------------------------"
printf 'entries:        control(A)=%s  under-test(B)=%s\n' "$(count A)" "$(count B)"
printf 'Administrative: control(A)=%s  under-test(B)=%s\n' "$(names A | command grep -c 'Administrative')" "$(names B | command grep -c 'Administrative')"
printf 'Microsoft Edge: control(A)=%s  under-test(B)=%s\n' "$(names A | command grep -cx 'Microsoft Edge')" "$(names B | command grep -cx 'Microsoft Edge')"
printf 'dup labels:     control(A)=%s  under-test(B)=%s\n' "$(names A | tr 'A-Z' 'a-z' | sort | uniq -d | wc -l)" "$(names B | tr 'A-Z' 'a-z' | sort | uniq -d | wc -l)"
echo

[ "$(count A)" -gt 0 ] && [ "$(count B)" -gt 0 ] || { bad "one arm produced no report at all - missing data"; }
# 1. the exclusion fires on a REAL Start Menu, and the control shows it did not before
if [ "$(names A | command grep -c 'Administrative')" -gt 0 ] && [ "$(names B | command grep -c 'Administrative')" = 0 ]; then
  ok "admin_excluded_on_guest: control reported $(names A | command grep -c 'Administrative') Administrative entries, the build under test reports 0"
else
  bad "admin_excluded_on_guest: control=$(names A | command grep -c 'Administrative') test=$(names B | command grep -c 'Administrative')"
fi
# 2. Edge once, having been twice
if [ "$(names A | command grep -cx 'Microsoft Edge')" -ge 2 ] && [ "$(names B | command grep -cx 'Microsoft Edge')" = 1 ]; then
  ok "edge_once_on_guest: control had $(names A | command grep -cx 'Microsoft Edge'), the build under test has 1"
else
  bad "edge_once_on_guest: control=$(names A | command grep -cx 'Microsoft Edge') test=$(names B | command grep -cx 'Microsoft Edge')"
fi
# 3. no folder-prefixed names, and the control had them
if [ "$(names A | command grep -c '^Windows PowerShell Windows PowerShell')" -gt 0 ] \
   && [ "$(names B | command grep -c '^Windows PowerShell Windows PowerShell')" = 0 ]; then
  ok "names_clean_on_guest: the control's \"Windows PowerShell Windows PowerShell ISE\" is gone"
else
  bad "names_clean_on_guest: control=$(names A | command grep -c '^Windows PowerShell Windows PowerShell') test=$(names B | command grep -c '^Windows PowerShell Windows PowerShell')"
fi
# 4. no two entries read the same
[ "$(names B | tr 'A-Z' 'a-z' | sort | uniq -d | wc -l)" = 0 ] \
  && ok "no_dup_labels_on_guest: every reported entry reads differently" \
  || bad "no_dup_labels_on_guest: $(names B | tr 'A-Z' 'a-z' | sort | uniq -d | tr '\n' ' ')"
# 5. the contract dom0 depends on: exit 0, and well-formed lines only
rc=$(tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$GUEST_PATH\" > nul 2>&1; echo RC=\$LASTEXITCODE" 2>/dev/null | tr -d '\r' | command grep -oE 'RC=[0-9-]+' | head -1)
[ "$rc" = "RC=0" ] && ok "exit_zero_on_guest: the service exits 0 ($rc) - a non-zero exit loses dom0's whole app list" \
                   || bad "exit_zero_on_guest: got '$rc'"
# 6. the fixed ids dom0's own launchers point at
for id in qubes-run-terminal qubes-open-file-manager; do
  command grep -q "^$id\.desktop:Name=" "$OUT/B.lines" && ok "fixed_id_on_guest: $id reported" \
                                                       || bad "fixed_id_on_guest: $id MISSING"
done
# 7. installed applications are still reported - the whole point of the question
echo "the entries the build under test reports:" > "$OUT/B.menu"
names B | sed 's/^/  /' >> "$OUT/B.menu"
cat "$OUT/B.menu"

echo
echo "appmenu-guest-ab: $pass passed, $fail failed   (raw: $OUT)"
[ "$fail" = 0 ] || exit 1
