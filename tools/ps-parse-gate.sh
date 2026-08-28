#!/bin/bash
# Parse-check every PowerShell file that can reach a guest — from the DEV QUBE, before it ships.
#
# WHY, when guest/ps-syntax-check.ps1 already exists: that one takes a single -Dir, does not
# recurse, and defaults to its own folder. So it covers guest/ and has never covered
# packaging/setup/Install-QwtImproved.ps1 — the installer itself, the thing whose failure is the
# entire subject of the current work. 0af6620 was a shipped parse error; the lesson recorded then
# was "catch that class in seconds", and this is where seconds are available: here, before a push,
# rather than in-guest after a deploy.
#
# Exit 0 iff every file parses. Intended for a deploy script or CI to gate on.
#
# LIMIT, stated because it matters: this parses with the pwsh available in this qube (7.x). Guests
# run Windows PowerShell 5.1, whose grammar is a SUBSET in a few places — notably an inline
# `if (...) {...} else {...}` used as a hashtable value parses here and can fail there. A pass is
# therefore necessary, not sufficient. It catches outright syntax errors, which is the class that
# has actually shipped.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh74/pwsh}"
command -v "$PWSH" >/dev/null 2>&1 || PWSH="$(command -v pwsh 2>/dev/null)"
if [ -z "${PWSH:-}" ] || ! command -v "$PWSH" >/dev/null 2>&1; then
	echo "ps-parse-gate: no pwsh found (set PWSH=/path/to/pwsh)" >&2
	exit 3   # distinct from a parse failure: we did not check, so do not read this as a pass
fi

DIRS=("${@:-guest packaging mgmt tools}")

"$PWSH" -NoProfile -Command "
\$ErrorActionPreference = 'Continue'
\$dirs = '${DIRS[*]}'.Split(' ') | Where-Object { \$_ }
\$bad = 0; \$n = 0
foreach (\$d in \$dirs) {
    \$p = Join-Path '$REPO' \$d
    if (-not (Test-Path \$p)) { continue }
    Get-ChildItem -Recurse -LiteralPath \$p -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
        \$n++
        \$errs = \$null
        [void][System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$null, [ref]\$errs)
        if (\$errs -and \$errs.Count) {
            \$bad++
            Write-Output ('FAIL ' + \$_.FullName.Replace('$REPO/',''))
            \$errs | Select-Object -First 3 | ForEach-Object {
                Write-Output ('     line ' + \$_.Extent.StartLineNumber + ': ' + \$_.Message)
            }
        }
    }
}
Write-Output ''
Write-Output (\"scanned=\$n failing=\$bad\")
if (\$bad -gt 0) { exit 1 } else { exit 0 }
"
