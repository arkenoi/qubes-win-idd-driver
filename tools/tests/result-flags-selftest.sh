#!/bin/bash
# result-flags-selftest.sh - prove mgmt/harness/result-flags.py BEFORE a harness grades a cell on it.
#
# WHY. quick-upgrade.sh and matrix.sh now grade a cell FAIL when the installer's RESULT trailer
# carries an error-class detail flag (audit 2026-09-16, the systemic finding: ok:true was graded
# green while detail.idd_failed / pv_xenvif='failed rc=N' / gui_restored='FAILED: ...' sat unread).
# A checker that misses a flag re-creates that silent green; a checker that fires on a HEALTHY value
# is a false RED on every campaign, and a campaign costs the owner ~75 min of desktop photography.
# So both directions are exercised here, offline, on synthetic trailers: every error form the
# installer can write must FAIL, and every healthy form on record (35 real green trailers,
# 2026-09-05..14, incl. etwproxy_account='skipped:account-create-refused') must PASS.
#
# EXTRACTION IS BY MARKER, NOT BY sed-to-closing-brace. The table sits between FLAGS-BEGIN and
# FLAGS-END in the checker; this script refuses to run if either marker is missing.
#
# Per this project's rule, a check counts only once it has been seen to FAIL on a build with the
# defect deliberately re-introduced:
#   RESULTFLAGS_DEFECT=1  - blank the flag table (= the original bug: nothing reads detail.*)
#                           -> every error-flag case passes through -> THIS TEST MUST FAIL (exit 1)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

SRC=mgmt/harness/result-flags.py
INSTALLER=packaging/setup/Install-QwtImproved.ps1
T=$(mktemp -d "${TMPDIR:-/tmp}/rflags.XXXXXX"); trap 'rm -rf "$T"' EXIT
CHK="$T/result-flags.py"

grep -q '# ---- FLAGS-BEGIN' "$SRC" && grep -q '# ---- FLAGS-END' "$SRC" \
  || { echo "FATAL: FLAGS-BEGIN/END markers missing from $SRC - cannot locate the table"; exit 2; }
case "${RESULTFLAGS_DEFECT:-}" in
  1)  awk '/# ---- FLAGS-BEGIN/{print; print "ERROR_FLAGS = []"; skip=1; next}
           /# ---- FLAGS-END/{skip=0}
           !skip' "$SRC" > "$CHK"
      echo "DEFECT KNOB: RESULTFLAGS_DEFECT=1 - the flag table is BLANK (the original bug); this run must FAIL" ;;
  '') cp "$SRC" "$CHK" ;;
  *)  echo "FATAL: unknown RESULTFLAGS_DEFECT '$RESULTFLAGS_DEFECT'"; exit 2 ;;
esac
python3 -m py_compile "$CHK" || { echo "FATAL: $CHK does not compile"; exit 2; }

pass=0; fail=0
# expect <label> <want-rc> <must-appear-in-last-line|-> <trailer line>...   (several lines -> stdin)
expect(){
  local label=$1 want=$2 needle=$3; shift 3
  local out rc
  if [ $# -eq 1 ]; then out=$(python3 "$CHK" "$1" 2>&1); rc=$?
  else out=$(printf '%s\n' "$@" | python3 "$CHK" - 2>&1); rc=$?; fi
  local last; last=$(printf '%s\n' "$out" | tail -1)
  if [ "$rc" -ne "$want" ]; then
    fail=$((fail+1)); echo "FAIL  $label -> rc=$rc, wanted $want  [$last]"
  elif [ "$needle" != '-' ] && ! printf '%s' "$last" | grep -qF -- "$needle"; then
    fail=$((fail+1)); echo "FAIL  $label -> rc=$rc but the summary line lacks '$needle'  [$last]"
  else
    pass=$((pass+1)); echo "PASS  $label -> rc=$rc  [${last:0:110}]"
  fi
}
# A stage-2 trailer built from ONLY the healthy forms on record, with one detail field replaced.
# Every value here is verbatim from a real green trailer (scratchpad corpus, 2026-09-05..14).
GREEN2='"addlocal":"PvDriversCore,Core,Gui,PvDriversNetwork,PvDriversDisk,MoveUsers","agent_hash_verified":true,"app_hwaccel":"changed=47 failed=0","appmenu_alias":"present","appmenu_scripts":"placed=2","autologon":"armed","bin_dir":"C:\\Program Files\\Qubes Tools\\bin","bind_dirs":"installed","certs_installed":9,"etwproxy_account":"provisioned","existing_qwt":[],"features_installed":{"PvDriversCore":3,"Core":3,"Gui":3,"PvDriversNetwork":3,"PvDriversDisk":3,"MoveUsers":3},"gui_quiesced_for_stage2":true,"idd_bound":"4.3.29.522","idd_driver":"activated: device up (ROOT\\DISPLAY\\0000), VGA adapter disabled (PCI\\VEN_1234&DEV_1111, code 22 read back)","idd_recovery":"if the guest has no usable display after the reboot, run over qrexec: Enable-PnpDevice","idd_vga_instance_id":"PCI\\VEN_1234&DEV_1111&SUBSYS_11001AF4&REV_02\\3&267A616A&0&18","inbox_disk_rearm":"done","installed_gui_agent_sha256":"06b1310a","leftover_sweep":{"removed":[],"absent":["gui-agent.exe","gui-watchdog.exe"],"stuck":[]},"leftovers_targeted":["gui-agent.exe","gui-watchdog.exe"],"msiexec_rc":3010,"net_reapply_task":"not-needed (stock applier retired; QubesPvNic owns event 10000)","package_version":"4.3.18+agent.05ff51c3be32","payload_files_verified":84,"pv_boot_disk":false,"pv_xencons":"installed","pv_xenvif":"installed","pvnic_latch":"armed","pvnic_prime":"seeded","qrexec_bins":"placed=5","quiet_desktop":"changed=45 failed=0","quiet_desktop_guard":"rc=0","reboot_audit":"changed=4 failed=0","rpc_overlay":"rpc handler scripts: 7/7; qrexec service definitions: 14/14","service_recovery":{"QdbDaemon":"armed","QrexecAgent":"armed"},"session_lock":"changed=19 failed=0","start_menu_shortcut":"not-installed-by-design","uac_prompt_on_secure_desktop":0,"updater_agent":"deployed","vc_redist_rc":0,"xenbus_autoreboot_final":0,"xenbus_monitor":"disabled","xenbus_monitor_final":"Disabled/Stopped"'
GREEN1='"autologon":"armed","certs_installed":9,"hiberboot":0,"next":"reboot, then stage 2 installs QWT","package_version":"4.3.18+agent.05ff51c3be32","payload_files_verified":84,"xenbus_monitor":"disabled"'
stage2(){ printf '=== RESULT === {"stage":"stage2-install","ok":true,"reboot_needed":true,"error":null,"detail":{%s}}' "$1"; }
stage1(){ printf '=== RESULT === {"stage":"stage1-prepare","ok":true,"reboot_needed":true,"error":null,"detail":{%s}}' "$1"; }

echo "==== green forms must PASS (false-RED guard) ===="
expect 'real-shaped stage-2 trailer, all healthy'            0 'no error-class flags' "$(stage2 "$GREEN2")"
expect 'real-shaped stage-1 trailer'                          0 'no error-class flags' "$(stage1 "$GREEN1")"
expect 'stage-1 + stage-2 on stdin, both healthy'             0 '2 trailers judged'    "$(stage1 "$GREEN1")" "$(stage2 "$GREEN2")"
expect 'bare JSON object (no banner) accepted'                0 'no error-class flags' "{\"stage\":\"stage2-install\",\"ok\":true,\"detail\":{$GREEN2}}"
# healthy values that LOOK alarming and occur on green runs - each must stay informational
while IFS='|' read -r key val; do
  [ -n "$key" ] || continue
  expect "informational: $key=$val" 0 'no error-class flags' "$(stage2 "$GREEN2,\"$key\":$val")"
done <<'EOF'
etwproxy_account|"skipped:account-create-refused"
etwproxy_account|"not in payload"
autologon|"skipped"
autologon|"not in payload"
net_reapply_task|"registered (stock applier kept)"
same_version_addlocal_retry|3010
same_version_addlocal_retry|0
msiexec_1618_retries|2
vc_redist_rc|1638
uninstall_rc|{"{4A1F}":1605,"{4A20}":3010}
relocate_dir_disarmed|false
pv_xenvif|"not shipped"
pv_xencons|"not shipped"
private_disk_gate|"READY t=0s checks=1 events=0"
private_disk_gate|"READY-SERIAL-UNKNOWN t=3s checks=2 events=0"
private_disk_gate|"READY-Q-PRESENT t=0s checks=1 events=0"
pnp_settle|"not-a-known-form"
inbox_disk_rearm|"not shipped"
app_hwaccel|"skipped"
app_hwaccel|"not in payload"
updater_agent|"skipped"
bind_dirs|"not-in-payload"
qrexec_bins|"not-in-payload"
pvnic_prime|"not in payload"
pvnic_prime|"seeded-indeterminate-class"
idd_driver|"skipped (/noidd)"
emulated_storage_rearmed|true
upgrade_mode|"in-place-msi-major-upgrade"
pv_boot_disk|"UNKNOWN"
swept_binaries_restored|["gui-agent.exe"]
EOF

echo "==== every error form must FAIL and be NAMED ===="
expect 'ok:false, no flags (the Fail path)'                   1 'ok:false' '=== RESULT === {"stage":"stage2-install","ok":false,"error":"msiexec failed with 1603","detail":{}}'
expect 'ok missing entirely'                                  1 'ok:false' '=== RESULT === {"stage":"stage2-install","detail":{}}'
expect 'ok is the STRING "true", not a boolean'               1 'ok:false' '=== RESULT === {"stage":"stage2-install","ok":"true","detail":{}}'
expect 'stage-1 clean, stage-2 flagged (judge ALL trailers)'  1 'stage2-install:gui_restored=' "$(stage1 "$GREEN1")" "$(stage2 "$GREEN2,\"gui_restored\":\"FAILED: watchdog started, gui-agent.exe not running after 30 s\"")"
expect 'stage-1 flagged, stage-2 clean (not only the last)'   1 'stage1-prepare:pnp_settle=' "$(stage1 "$GREEN1,\"pnp_settle\":\"unavailable: x\"")" "$(stage2 "$GREEN2")"
expect 'flagged + an unparseable sibling: error wins'         1 'idd_failed=' "$(stage2 "$GREEN2,\"idd_failed\":true")" '=== RESULT === {"stage":"stage2-install","ok":tr'
# one case per (key, error form) the installer can write - the file:line for each is in the checker
while IFS='|' read -r key val; do
  [ -n "$key" ] || continue
  expect "error flag: $key=$val" 1 "$key=" "$(stage2 "$GREEN2,\"$key\":$val")"
done <<'EOF'
idd_failed|true
idd_driver|"FAILED (on Basic Display Adapter): IDD activation failed: device never appeared"
idd_vga_disable_pending|true
idd_gui_reappeared|"gui-watchdog,gui-agent"
idd_bound|"unreadable"
idd_bound|"unreadable-after-rebind"
gui_quiesce_failed|"gui-agent,wgcbroker"
gui_restored|"FAILED: watchdog started, gui-agent.exe not running after 30 s"
gui_restored|"FAILED: Cannot start service QubesGuiWatchdog"
pv_xenvif|"failed rc=1"
pv_xencons|"failed rc=1"
pvnic_prime_failed|true
pvnic_prime|"FAILED: exit '1'; no MARKJSON trailer"
pvnic_prime|"error: x"
pvnic_latch|"not-armed: prime_ok=False task_present=True"
pvnic_latch|"unconfirmed:"
pvnic_latch|"error: x"
net_reapply_task|"failed rc=1"
pnp_settle|"timeout rc=258"
pnp_settle|"unavailable: Unable to find type [QwtCfgMgr]"
private_disk_gate|"WARN MISNUMBERED (NoMoveUsers) t=1s checks=1 events=0"
private_disk_gate|"WARN NOT-READY-deadline (NoMoveUsers) t=120s checks=24 events=0"
private_disk_gate|"FAIL NOT-READY t=120s checks=24 events=0"
inbox_disk_rearm|"incomplete: atapi=Start:3"
inbox_disk_rearm|"failed: x"
leftover_sweep|{"removed":[],"absent":[],"stuck":["gui-agent.exe"]}
xenbus_monitor_survivors|[1234]
hiberboot|1
uninstall_rc|{"{4A1F}":1603}
vc_redist_rc|1
msiexec_rc|1603
same_version_addlocal_retry|1603
features_installed|{"Core":3,"Gui":2}
features_installed|{"Core":3,"Gui":-1}
agent_hash_verified|false
swept_binaries_lost|["gui-agent.exe: locked"]
shutdown_rc|1
relocate_dir_disarmed|true
relocate_dir_disarmed|"failed: x"
bind_dirs|"installed-no-private-volume"
bind_dirs|"error: x"
rpc_overlay_failed|"qubes.GetAppmenus"
qrexec_bins|"placed=2 FAILED=qrexec-wrapper.exe"
qrexec_bins|"target-missing"
appmenu_alias|"service-file-not-found"
appmenu_alias|"error"
app_hwaccel|"changed=40 failed=3"
app_hwaccel|"ran, no result trailer"
app_hwaccel|"error: x"
session_lock|"changed=1 failed=1"
session_lock|"error: x"
reboot_audit|"changed=0 failed=4"
reboot_audit|"ran, no result trailer"
quiet_desktop|"ran, no result trailer"
quiet_desktop|"changed=45 failed=2"
quiet_desktop_guard|"rc=1"
quiet_desktop_guard|"error: x"
updater_agent|"incomplete: returned without the completion line"
updater_agent|"error: x"
etwproxy_account|"error: x"
service_recovery|{"QdbDaemon":"armed","QrexecAgent":"failed: sc failure=1 failureflag=0"}
autologon|"not-armed:bad-credentials"
autologon|"error: x"
autologon|"unverified"
autologon|"verify: no result trailer"
autologon|"verify-error: x"
EOF

echo "==== missing / unparseable stays the caller's business (rc 2, never a verdict) ===="
expect 'truncated JSON'                                       2 'NOT judged' '=== RESULT === {"stage":"stage2-install","ok":tr'
expect 'not JSON at all'                                      2 'NOT judged' '=== RESULT === changed=0 warnings=0'
expect 'empty stdin'                                          2 'NOT judged' ''
expect 'clean trailer + an unparseable sibling is NOT green'  2 'UNPARSEABLE' "$(stage2 "$GREEN2")" '=== RESULT === {"stage":"stage2-install","ok":tr'
out=$(python3 "$CHK" 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass=$((pass+1)); echo "PASS  no arguments -> rc=3 usage"; else fail=$((fail+1)); echo "FAIL  no arguments -> rc=$rc, wanted 3"; fi

echo "==== drift: the classification and the installer name the SAME keys ===="
# [A-Za-z0-9_] on purpose - the audit's grep used [A-Za-z_] and silently missed sha256 / stage2 /
# 1618 keys. Every key the installer writes must be classified (error or informational), and every
# classified key must still exist in the installer; either gap is a stale table.
grep -o '\.detail\.[A-Za-z0-9_]* *=' "$INSTALLER" | sed 's/\.detail\.//; s/ *=$//' | sort -u > "$T/inst"
python3 "$CHK" --list-keys | cut -f2 | sort -u > "$T/cls"
unclassified=$(comm -23 "$T/inst" "$T/cls" | tr '\n' ' ')
stale=$(comm -13 "$T/inst" "$T/cls" | tr '\n' ' ')
if [ -z "$unclassified" ] && [ -z "$stale" ]; then
  pass=$((pass+1)); echo "PASS  drift: $(wc -l < "$T/inst") installer detail keys, all classified, none stale"
else
  fail=$((fail+1)); echo "FAIL  drift: unclassified in the checker [${unclassified}] / classified but gone from the installer [${stale}]"
fi
nerr=$(python3 "$CHK" --list-keys | grep -c '^error')
if [ "$nerr" -ge 30 ]; then pass=$((pass+1)); echo "PASS  drift: $nerr error-class keys in the table"
else fail=$((fail+1)); echo "FAIL  drift: only $nerr error-class keys in the table - the audit named more than 30 error forms"; fi

echo
echo "result-flags-selftest: $pass passed, $fail failed$( [ "${RESULTFLAGS_DEFECT:-}" = 1 ] && echo '  (RESULTFLAGS_DEFECT=1: a FAIL here is the proof that the check can fail)')"
[ "$fail" -eq 0 ]
