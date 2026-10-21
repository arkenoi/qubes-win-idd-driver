#!/bin/bash
# THE COLLECTOR MUST LOOK WHERE THE PRODUCT WOULD HAVE WRITTEN.
#
# upstream/ro/qubes-windows-utils/src/log.c:236-253 with log.h:59: when LogInit is given no
# directory it builds "<system drive>\Qubes Logs" - LOG_DEFAULT_DIR is L"Qubes Logs", with the space
# - and CREATES it. That path was absent from Get-LswLogDir entirely, which checked the registry,
# then Q:\Qubes Logs, then C:\Program Files\Qubes Tools\log. So a guest whose registry carries no
# LogDir at all wrote its logs to C:\Qubes Logs and the collector reported exists=0: a blind sweep
# over a guest that was logging perfectly well.
#
# WHAT THIS DOES NOT FIX, stated because the appvm blindness looks like the same bug and is not:
# when the registry DOES name a path and CreateDirectory fails on it - the inherited
# Z:\qwt-logs\<churn> on a volume not mounted at agent start - log.c calls LogStart(NULL) and jumps
# to its fallback label, which is stderr only. No file is written anywhere, so no collector change
# can recover those logs. That one needs the LogDir to be valid before the agent starts.
#
# The collector is PowerShell and runs on the guest for every sweep, so a syntax error here blinds
# every cell. The parse check is the first assertion and runs whenever a pwsh is available.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0; INCONCLUSIVE=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
C="$ROOT/mgmt/harness/log-sweep-collect.ps1"

# ---- source-level assertions, which run everywhere -------------------------------------------
# The product's default, spelled as the product spells it. Keyed on the PATH, not on wording.
if command grep -aq "Join-Path \$env:SystemDrive 'Qubes Logs'" "$C"; then
  ok "Get-LswLogDir considers <system drive>\\Qubes Logs, the product's own default"
else
  no "the collector does not look at the product default (log.c:238 + log.h:59 LOG_DEFAULT_DIR)"
fi
# and it must come AFTER the registry, because a configured LogDir is what the product honours first
reg=$(command grep -an 'Invisible Things Lab' "$C" | head -1 | cut -d: -f1)
def=$(command grep -an "Join-Path \$env:SystemDrive 'Qubes Logs'" "$C" | head -1 | cut -d: -f1)
if [ -n "$reg" ] && [ -n "$def" ] && [ "$reg" -lt "$def" ]; then
  ok "the registry is consulted before the default, mirroring log.c's own order"
else
  no "resolution order is wrong: registry at line ${reg:-?}, default at line ${def:-?}"
fi
# the spelling matters - LOG_DEFAULT_DIR has a SPACE. "QubesLogs" would be a path nothing writes.
if command grep -aq 'QubesLogs' "$C"; then
  no "the collector spells it QubesLogs; LOG_DEFAULT_DIR is \"Qubes Logs\", with a space"
else
  ok "it is spelled \"Qubes Logs\" with the space, as log.h:59 defines it"
fi
# and the claim about log.c must still be true of the shipped source.
# ABSENCE IS NOT A CHANGE. upstream/ro is gitignored, so a clean checkout has no log.h - and this
# read reported "LOG_DEFAULT_DIR changed" there, which is a claim about upstream made from a missing
# file. In CI that was one of four reds that pass on the dev qube. Missing input is INCONCLUSIVE and
# says so; test.yml now materialises the pinned mirror, so the real read happens there too.
LOGH="${COLLECTOR_LOGH:-$ROOT/upstream/ro/qubes-windows-utils/include/log.h}"   # override: this suite only
if [ ! -f "$LOGH" ]; then
  echo "INCONCLUSIVE: $LOGH absent (upstream/ro is gitignored) - the premise about log.h was NOT checked"
  INCONCLUSIVE=$((${INCONCLUSIVE:-0} + 1))
elif command grep -aq 'define LOG_DEFAULT_DIR L"Qubes Logs"' "$LOGH"; then
  ok "log.h:59 still defines LOG_DEFAULT_DIR as \"Qubes Logs\" (the premise holds)"
else
  no "LOG_DEFAULT_DIR changed - this suite's premise no longer holds, re-read log.h"
fi

# ---- functional, when a pwsh exists ------------------------------------------------------------
PW=""
for p in /home/user/pwsh74/pwsh /home/user/bin/pwsh7/pwsh /home/user/pwsh/pwsh "$(command -v pwsh 2>/dev/null)"; do
  [ -n "$p" ] && [ -x "$p" ] && { PW="$p"; break; }
done
if [ -z "$PW" ]; then
  echo "note no pwsh on this host - the parse check and the functional test did not run"
else
  # THE PATH IS INTERPOLATED, NOT PASSED AS $args. Under -Command, $args is not populated the way
  # it is under -File, so ParseFile($args[0]) parsed $null and reported one error - a test failing
  # for its own reason and blaming the file it was checking.
  out=$("$PW" -NoProfile -Command '
    $c = "'"$C"'"
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($c, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { "PARSE " + $errs.Count; exit 0 } else { "PARSE 0" }
    $src = Get-Content -Raw $c
    $m = [regex]::Match($src, "(?s)function Get-LswLogDir \{.*?\n\}")
    if (-not $m.Success) { "EXTRACT fail"; exit 0 }
    Invoke-Expression $m.Value
    $T = Join-Path ([IO.Path]::GetTempPath()) ("lsw" + [guid]::NewGuid().ToString("N").Substring(0,8))
    $env:SystemDrive = $T
    $def = Join-Path $T "Qubes Logs"
    New-Item -ItemType Directory -Force -Path $def | Out-Null
    if ((Get-LswLogDir) -eq $def) { "FOUND yes" } else { "FOUND no" }
    Remove-Item -Recurse -Force $def
    if ((Get-LswLogDir) -ne $def) { "FALLTHROUGH yes" } else { "FALLTHROUGH no" }
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
  ' 2>&1)
  case "$(printf '%s' "$out" | command grep -a '^PARSE' | head -1)" in
    "PARSE 0") ok "log-sweep-collect.ps1 parses clean (it runs on the guest for every sweep)" ;;
    *)         no "the collector does NOT parse: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" ;;
  esac
  printf '%s' "$out" | command grep -qa '^FOUND yes' \
    && ok "functional: the product default is resolved when it exists" \
    || no "functional: the default was not resolved ($(printf '%s' "$out" | command grep -a '^FOUND'))"
  printf '%s' "$out" | command grep -qa '^FALLTHROUGH yes' \
    && ok "functional: an absent default falls through instead of being claimed" \
    || no "functional: an absent default was claimed anyway"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed$( [ "$INCONCLUSIVE" -gt 0 ] && printf ', %s INCONCLUSIVE' "$INCONCLUSIVE" )"
# AN INCONCLUSIVE READ IS NOT A PASS. It exits 2, which the offline runner counts RED - the same
# contract loginit-banner-debug and logvol-modulekey already use for this input.
[ "$FAIL" -eq 0 ] || exit 1
[ "$INCONCLUSIVE" -eq 0 ] || exit 2
