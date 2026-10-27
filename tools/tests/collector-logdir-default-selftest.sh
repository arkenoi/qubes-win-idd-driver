#!/bin/bash
# THE COLLECTOR MUST LOOK WHERE THE PRODUCT WOULD HAVE WRITTEN - every candidate dir, not the first.
# run: tools/tests/collector-logdir-default-selftest.sh
# pass: exit 0
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
PW="$("$(dirname "$0")/pwsh-path.sh" || true)"
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

# ---- THE UNION: one `return` was the blindness ---------------------------------------------------
# Get-LswLogDir returns the FIRST hit. A module resolves its LogDir ONCE at its own LogInit, and the
# harness MOVES that value underneath it (bind / clear / restore), so the directory the registry
# names at collection time can be one no module in the capture ever wrote to. MEASURED on run
# 39880114972: win11-upgrade graded Q:\Qubes Logs while 27 QWTBIRTH lines sat on the bound volume
# (SWEEPGRADESTHEDEFAULTDIRNOTTHEBOUNDVOLUME), and win10-clean's unpark boot - which ran with LogDir
# CLEARED - has no record in the capture at all (PARKBOOTAGENTINVISIBLETOTHESWEEP).
# SOURCE ASSERTIONS SKIP COMMENTS: this file's own prose names the function, and a check that
# matched its own explanation would pass over a collector that never calls it.
CODE=$(command grep -av '^[[:space:]]*#' "$C")
if printf '%s' "$CODE" | command grep -qa 'foreach ($d in (Get-LswLogDirCandidates))'; then
  ok "the file set ITERATES the candidate directories (not just the first hit)"
else
  no "nothing iterates Get-LswLogDirCandidates - the union is prose only"
fi
# THE WINDOW MUST COVER THE LOOP BODY, not a guess at its length. -A12 was enough when the body was
# four lines; the window drop accounting (LSW DROPPED, 2026-10-25) made it 15, and this leg went red
# on a collector that adds to $cands perfectly well - a position-anchored check broken by an
# insertion above its target, not a defect in the code it was aimed at.
if printf '%s' "$CODE" | command grep -a -A24 'foreach ($d in (Get-LswLogDirCandidates))' | command grep -qa '$cands.Add($f)'; then
  ok "files found in a non-primary candidate are ADDED to the collected set"
else
  no "the candidate loop does not add to \$cands - it would report and collect nothing"
fi
# the primary receipt must not move: the analyzer (log-sweep.py: body.startswith("LOGDIR ")) and
# three selftests parse it, and a renamed or reordered field blinds every one of them.
if printf '%s' "$CODE" | command grep -qa 'LOGDIR pathb64=.*exists='; then
  ok "the primary LSW LOGDIR receipt is still emitted with its original shape"
else
  no "the LSW LOGDIR receipt changed shape - every consumer of it is now blind"
fi

if [ -n "$PW" ]; then
  uout=$("$PW" -NoProfile -Command '
    $c = "'"$C"'"
    $src = Get-Content -Raw $c
    $m = [regex]::Match($src, "(?s)function Get-LswLogDirCandidates \{.*?\n\}")
    if (-not $m.Success) { "EXTRACT fail"; exit 0 }
    Invoke-Expression $m.Value
    $T = Join-Path ([IO.Path]::GetTempPath()) ("lswu" + [guid]::NewGuid().ToString("N").Substring(0,8))
    $env:SystemDrive = $T
    # no Windows registry here, so the registry-derived entries are simply absent: what must still
    # hold is that the STATIC candidates are all returned, deduplicated, and that it does not stop
    # at one.
    $cand = @(Get-LswLogDirCandidates)
    "COUNT " + $cand.Count
    if ($cand -contains (Join-Path $T "Qubes Logs")) { "DEFAULT yes" } else { "DEFAULT no" }
    if ($cand -contains "Q:\Qubes Logs") { "QDRIVE yes" } else { "QDRIVE no" }
    $dups = ($cand | Group-Object | Where-Object { $_.Count -gt 1 }).Count
    "DUPS " + $dups
    Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
  ' 2>&1)
  printf '%s' "$uout" | command grep -qa '^EXTRACT fail' \
    && no "Get-LswLogDirCandidates could not be extracted - the collector has no candidate set" \
    || true
  n=$(printf '%s' "$uout" | command sed -n 's/^COUNT //p' | head -1)
  [ "${n:-0}" -ge 3 ] \
    && ok "functional: the candidate set returns $n directories, not one" \
    || no "functional: the candidate set returned ${n:-none} - a single return is the defect"
  printf '%s' "$uout" | command grep -qa '^DEFAULT yes' \
    && ok "functional: log.c's own default is among the candidates" \
    || no "functional: the product default is NOT a candidate ($(printf '%s' "$uout" | command grep -a '^DEFAULT'))"
  printf '%s' "$uout" | command grep -qa '^QDRIVE yes' \
    && ok "functional: the Q: log directory is among the candidates" \
    || no "functional: Q:\Qubes Logs is not a candidate"
  [ "$(printf '%s' "$uout" | command sed -n 's/^DUPS //p' | head -1)" = 0 ] \
    && ok "functional: the candidate set is deduplicated (one bind can name a dir twice)" \
    || no "functional: the candidate set holds duplicates - files would be collected twice"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed$( [ "$INCONCLUSIVE" -gt 0 ] && printf ', %s INCONCLUSIVE' "$INCONCLUSIVE" )"
# AN INCONCLUSIVE READ IS NOT A PASS. It exits 2, which the offline runner counts RED - the same
# contract loginit-banner-debug and logvol-modulekey already use for this input.
[ "$FAIL" -eq 0 ] || exit 1
[ "$INCONCLUSIVE" -eq 0 ] || exit 2
