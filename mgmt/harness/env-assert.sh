#!/bin/bash
# env-assert.sh - assert, BY MEASUREMENT, that a guest IS a registered field reporter's environment.
#
# WHY THIS EXISTS (owner, 2026-09-16). A reproduction of GWeck's Windows Update failure ran for a
# day - and half the week's Fable budget - on a 24H2 RTM English image with a locale switch, while
# his environment (Windows 11 25H2, German Windows, TemplateVM, no 'user' account) was written in
# the forum thread and in this repo's own records. The subagent's result even said "NOT MATCHED:
# build 26100 (24H2) vs his 25H2" and the run was still reported as reproduced. Prose rules did not
# stop it and will not stop the next one. This script does: every asserted fact in
# mgmt/reporters/<reporter>.json is measured on the guest and on the qube, and ANY mismatch - or
# any fact that could not be measured - is a non-zero exit that a caller must stop on.
#
# Usage: mgmt/harness/env-assert.sh <vm> <reporter>      (reporter = basename of mgmt/reporters/<reporter>.json)
#   exit 0  every asserted fact matches (table printed as evidence)
#   exit 3  MISMATCH (table names each failing fact; the guest is NOT this reporter's environment)
#   exit 2  a fact could not be measured / spec missing / guest unreachable (missing data FAILS)
#
# The guest must be running with qrexec up. Guest facts are read as SYSTEM over qtest (one
# -EncodedCommand PowerShell), qube facts over the Admin API (qvm-ls / qvm-prefs).
#
# Offline self-test (tools/tests/env-assert-selftest.sh) feeds ENVASSERT_FAKE_FACTS=<file> with
# key=value lines in place of the live probes; ENVASSERT_DEFECT=1 re-introduces the original bug
# (a check that cannot fail) and the self-test must then FAIL.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: env-assert.sh <vm> <reporter>}"
REP="${2:?usage: env-assert.sh <vm> <reporter>}"
SPEC="mgmt/reporters/$REP.json"
[ -f "$SPEC" ] || { echo "ENVASSERT FATAL: no reporter spec at $SPEC" >&2; exit 2; }
# Serialise with every other job on this guest (mgmt/harness/vmlock.sh): a probe that reads a guest
# while another harness reboots it reports nonsense. Re-entrant when the calling job already holds it
# (QWT_VMLOCK_HELD); the offline self-test feeds fake facts and touches no guest, so it takes no lock.
if [ -z "${ENVASSERT_FAKE_FACTS:-}" ]; then source mgmt/harness/vmlock.sh; vm_lock "$VM"; fi

# ---- measurement -----------------------------------------------------------------------------
# One PowerShell, run as SYSTEM, printing key=value lines. Language-agnostic by construction:
# registry values and .NET culture objects, never localized command output.
read -r -d '' PS <<'PS1'
$ErrorActionPreference='Continue'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"display_version=$($cv.DisplayVersion)"
"current_build=$($cv.CurrentBuild)"
"ubr=$($cv.UBR)"
"ui_language=$([System.Globalization.CultureInfo]::InstalledUICulture.Name)"
"install_language=$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguage)"
"system_locale=$((Get-WinSystemLocale).Name)"
"accounts=$((Get-LocalUser | ForEach-Object Name) -join ';')"
"account_user_absent=$(if (Get-LocalUser -Name 'user' -ErrorAction SilentlyContinue) { 'false' } else { 'true' })"
$p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Qubes*' } | Select-Object -First 1
"qwt_version=$($p.DisplayVersion)"
"ENVASSERT-END=1"
PS1

FACTS=$(mktemp "${TMPDIR:-/tmp}/envassert.XXXXXX"); trap 'rm -f "$FACTS"' EXIT
if [ -n "${ENVASSERT_FAKE_FACTS:-}" ]; then
  cp "$ENVASSERT_FAKE_FACTS" "$FACTS"
else
  enc=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  QTEST_VM="$VM" timeout -k 5 150 ./tools/qtest run "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc" 2>/dev/null | tr -d '\r' > "$FACTS"
  grep -q '^ENVASSERT-END=1' "$FACTS" || { echo "ENVASSERT FATAL: guest probe on $VM did not complete (qrexec down, or the guest is not up)" >&2; exit 2; }
  q=$(qvm-ls --raw-data --fields NAME,CLASS,NETVM "$VM" 2>/dev/null | head -1)
  [ -n "$q" ] || { echo "ENVASSERT FATAL: qvm-ls has no row for $VM" >&2; exit 2; }
  cls=$(echo "$q" | cut -d'|' -f2); nv=$(echo "$q" | cut -d'|' -f3); [ "$nv" = "-" ] && nv=""
  du=$(qvm-prefs "$VM" default_user 2>/dev/null)
  { echo "qube_class=$cls"; echo "netvm=$nv"; echo "default_user=$du"; } >> "$FACTS"
fi

# ---- comparison ------------------------------------------------------------------------------
python3 - "$SPEC" "$FACTS" "$VM" "$REP" "${ENVASSERT_DEFECT:-}" <<'PY'
import json, sys
spec_p, facts_p, vm, rep, defect = sys.argv[1:6]
spec = json.load(open(spec_p, encoding='utf-8'))
facts = {}
for line in open(facts_p, encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    if '=' in line:
        k, v = line.split('=', 1); facts[k.strip()] = v.strip()
# derived facts
try:
    b = int(facts.get('current_build', '') or 0)
    facts['product'] = 'Windows 11' if b >= 22000 else ('Windows 10' if b >= 10240 else 'unknown')
except ValueError:
    facts['product'] = 'unknown'
facts['default_user_not_user'] = 'true' if facts.get('default_user', '') not in ('', 'user') else 'false'

rows, mismatch, missing = [], 0, 0
for key, ent in spec['environment'].items():
    want = str(ent['value']); assert_it = bool(ent.get('assert', True))
    got = facts.get(key)
    if not assert_it:
        rows.append((key, want, '(not asserted)', 'INFO')); continue
    if got is None or got == '':
        if key == 'netvm' and got == '':
            pass  # an empty netvm is a legitimate measured value
        else:
            rows.append((key, want, '<not measured>', 'MISSING')); missing += 1; continue
    # DEFECT KNOB - the original bug: a comparison that cannot fail.  # GUARD:envassert-compare
    ok = True if defect == '1' else (got.strip().lower() == want.strip().lower())
    rows.append((key, want, got, 'ok' if ok else 'MISMATCH'))
    if not ok: mismatch += 1

w = max(len(r[0]) for r in rows)
print(f"ENVASSERT {vm} vs reporter '{spec['reporter']}' ({spec_p})")
for k, want, got, st in rows:
    print(f"  {st:<9} {k:<{w}}  want={want!r}  got={got!r}")
extra = {k: facts[k] for k in ('ubr', 'install_language', 'system_locale', 'accounts', 'qwt_version', 'default_user') if k in facts}
print("  evidence " + " ".join(f"{k}={v}" for k, v in extra.items()))
if missing:
    print(f"ENVASSERT FAIL: {missing} fact(s) could not be measured - missing data fails"); sys.exit(2)
if mismatch:
    print(f"ENVASSERT MISMATCH: {vm} is NOT {spec['reporter']}'s environment ({mismatch} fact(s) differ) - do not run the reproduction on it"); sys.exit(3)
print(f"ENVASSERT OK: {vm} matches every asserted fact of {spec['reporter']}'s environment")
PY
