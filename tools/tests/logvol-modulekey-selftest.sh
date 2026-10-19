#!/usr/bin/env bash
# logvol-modulekey-selftest.sh - THE PREMISE THE RACE-FREE BIND RESTS ON, asserted.
#
# The harness binds the log volume by writing LogDir into the PER-MODULE keys, not the root,
# because the root is a value the product's installer deliberately forces with `reg add /f` once
# per stage. That is correct product behaviour and must not change: the MSI has two components
# racing to write LogDir under one condition, so a deterministic pre-seed is what stops the winner
# being arbitrary, and it is also what migrates a legacy root-volume path onto Q:.
#
# MEASURED 2026-10-19 on win11de-tup - the bind worked and was then undone:
#   05:00:56 bind -> Z:\qwt-logs\win11de-tup (copied=83)   05:00:58-05:01:48 28 wrapper logs on the stick
#   05:02:00 installer: "seeded gui-agent registry defaults (... LogDir)"
#   05:02:05 wrapper logs back in Q:\Qubes Logs, and never on the stick again
# A direct read then showed LogDir='Q:\Qubes Logs', no per-module key, and no wrapper log under
# Z:\qwt-logs\win11de-tup. Jev: logdir_was_rewritten established 0.96, the volume exonerated 0.76,
# and the mechanism the harness used to blame (a removable volume enumerating too late) refuted 0.96.
#
# SO THE BIND MUST NOT DEPEND ON WRITE ORDER (owner: "no fucking races in the product.
# determenistic paths only"). It depends instead on a precedence fixed in C: windows-utils reads
# LogDir module-key-first and only falls back to the root. THIS SUITE ASSERTS THAT PREMISE, so if
# upstream ever changes it the bind fails loudly here instead of silently losing the logs again.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

LOGC=upstream/ro/qubes-windows-utils/src/log.c
# upstream/ro IS GITIGNORED (.gitignore:27), so the vendored source is local working material
# and NOT in the repo. A check that reads it would pass here and be unrunnable from a clean
# checkout, which is decoration. So the two upstream premises are verified when the material is
# present and reported INCONCLUSIVE (rc=2) when it is not - never as a pass.
LOGC="${LOGVOL_MK_LOGC:-upstream/ro/qubes-windows-utils/src/log.c}"
CFGC="${LOGVOL_MK_CFGC:-upstream/ro/qubes-windows-utils/src/config.c}"
inconclusive=0

# 1+2. THE UPSTREAM PREMISE: the log path is read WITH THE MODULE NAME, and the config layer tries
# the module key BEFORE the root. Together these are what make the bind deterministic instead of a
# race against the installer's root seed.
if [ -r "$LOGC" ] && [ -r "$CFGC" ]; then
  if command grep -qa 'CfgReadString(logName, LOG_CONFIG_PATH_VALUE' "$LOGC"; then
    ok "log.c reads LogDir with the MODULE name, so a module key can override the root"
  else no "log.c no longer passes the module name to the LogDir read - the per-module bind is now inert" \
          "$(command grep -na 'LOG_CONFIG_PATH_VALUE' "$LOGC" | head -2)"; fi
  if command grep -qa 'Try to open module-specific key' "$CFGC" && command grep -qa 'value not found, try the root key' "$CFGC"; then
    ok "config.c opens the module key first and only falls back to the root"
  else no "config.c's module-first fallback is gone or renamed - precedence is no longer fixed in code" \
          "checked $CFGC"; fi
else
  inconclusive=1
  printf '  INCONCLUSIVE  the upstream premise cannot be verified from this checkout\n'
  printf '     -> %s\n' "upstream/ro is gitignored (.gitignore:27) and ${LOGC} / ${CFGC} are not readable here."
  printf '     -> %s\n' "The bind's determinism RESTS on that premise, so it must not read as a pass."
  printf '     -> %s\n' "To make it verifiable from the repo: assert the module-first read in a TRACKED patch under patches/, or vendor the two functions."
fi

# 3. THE PRODUCT MUST STAY THE ONLY WRITER OF THE ROOT, AND NEVER WRITE A MODULE KEY.
#    If the installer ever started writing per-module LogDir, the bind would be racing again.
n=$(command grep -rniE 'Qubes Tools\\\\[A-Za-z-]+.*LogDir|LogDir.*Qubes Tools\\\\[A-Za-z-]+' --include='*.ps1' --include='*.wxs' packaging/ guest/ 2>/dev/null | command grep -avc '^$' || true)
if [ "${n:-0}" -eq 0 ]; then
  ok "no product file writes a per-module LogDir - the two keys have one writer each"
else no "product code now writes a per-module LogDir ($n site(s)) - the bind is racing again" \
        "$(command grep -rniE 'Qubes Tools\\\\[A-Za-z-]+.*LogDir' --include='*.ps1' packaging/ guest/ 2>/dev/null | head -2)"; fi

# 4. the installer's deterministic root seed is STILL THERE - this fix must not have removed it
if command grep -qa "@('LogDir', 'REG_SZ', 'Q:\\\\Qubes Logs')" packaging/setup/Install-QwtImproved.ps1; then
  ok "the installer still seeds the ROOT LogDir deterministically (the MSI race stays closed)"
else no "the installer's deterministic LogDir seed is gone - the MSI's two racing components decide again" \
        "$(command grep -na 'LogDir' packaging/setup/Install-QwtImproved.ps1 | head -3)"; fi

# 5. the binder writes the module keys, records which, and undoes exactly those
B=mgmt/harness/logvol-bind.ps1
for probe in "Set-ModuleLogDir" "LogDirModulesPreLogvol" "modules="; do
  if command grep -qa "$probe" "$B"; then ok "binder carries '$probe'"
  else no "binder is missing '$probe' - the module layer or its receipt/undo is incomplete" "grep '$probe' $B"; fi
done

echo
echo "logvol-modulekey-selftest: $pass passed, $fail failed$([ "$inconclusive" = 1 ] && echo ', 1 INCONCLUSIVE')"
[ "$fail" = 0 ] || exit 1
[ "$inconclusive" = 0 ] || exit 2
