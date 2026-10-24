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
        \$ast = [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$null, [ref]\$errs)
        if (\$errs -and \$errs.Count) {
            \$bad++
            Write-Output ('FAIL ' + \$_.FullName.Replace('$REPO/',''))
            \$errs | Select-Object -First 3 | ForEach-Object {
                Write-Output ('     line ' + \$_.Extent.StartLineNumber + ': ' + \$_.Message)
            }
        }
        # ---- TWO DEFECTS THAT PARSE CLEANLY AND THROW, OR SILENTLY LOSE A VALUE, AT RUNTIME ------
        # Added 2026-10-24 after both were found by hand on the same day, in the same file family:
        #  1. an -f format index with no argument behind it. guest/wgcbroker-peek.ps1's CROP line
        #     referenced index 10 while passing ten arguments, so every run threw
        #     'Error formatting a string: Index (zero based) must be ... less than the size of the
        #     argument list' - and the ONE diagnostic that tells a wrong crop from missing pixels,
        #     which ABI 26 was added to provide, printed NOTHING from the day valid= was added.
        #  2. a bare TYPE LITERAL as a command argument: an int cast written to the LEFT of the
        #     parentheses is passed as the argument itself and the value is gone - measured under
        #     pwsh 7.4.
        # NEITHER IS A SYNTAX ERROR, so the pass above cannot see them; both are structural, so the
        # PARSER answers them exactly - which is why this reads the AST and not a regex over text.
        # NOTE FOR THE NEXT EDITOR: this whole block is inside a BASH double-quoted string, so a
        # backtick or a dollar-paren in a COMMENT is executed by bash before pwsh sees it. The first
        # cut of this comment quoted the defect with backticks and bash answered
        # '-f: command not found'.
        if (\$ast) {
            # IT IS A STRING CONSTANT, NOT A TypeExpressionAst, and that is why the first cut of
            # this check reported nothing on a file that carried the defect. In ARGUMENT position
            # PowerShell parses a bare word as a string, so an int cast written to the left of the
            # parentheses arrives as StringConstantExpressionAst with the text of the cast -
            # introspected under pwsh 7.4 to be sure rather than assumed.
            # MATCHED AGAINST KNOWN TYPE NAMES, so a bracketed log tag written as a bare word - this
            # repo writes plenty of them - cannot be mistaken for a lost cast.
            \$tnames = 'int|int32|int64|long|uint32|uint64|short|byte|char|bool|boolean|string|double|single|float|decimal|datetime|timespan|guid|regex|version|array|hashtable|scriptblock|pscustomobject|psobject|xml|type|void|switch'
            foreach (\$c in \$ast.FindAll({ \$args[0] -is [System.Management.Automation.Language.CommandAst] }, \$true)) {
                foreach (\$e in \$c.CommandElements) {
                    if (\$e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        \$e.Extent.Text -match ('^\[(' + \$tnames + ')(\[\])?\]\$')) {
                        \$bad++
                        Write-Output ('FAIL ' + \$_.FullName.Replace('$REPO/','') + ' line ' + \$e.Extent.StartLineNumber + ': a bare type literal ' + \$e.Extent.Text + ' is passed AS AN ARGUMENT - the cast belongs inside the parentheses, or the value is lost')
                    }
                }
            }
            foreach (\$b in \$ast.FindAll({ \$args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] -and \$args[0].Operator -eq 'Format' }, \$true)) {
                \$idx = [regex]::Matches(\$b.Left.Extent.Text, '\{(\d+)') | ForEach-Object { [int]\$_.Groups[1].Value }
                # -f takes ONE argument or an array literal; anything else (a variable holding an
                # array, a splat) cannot be counted here and is left alone rather than guessed at.
                \$cnt = if (\$b.Right -is [System.Management.Automation.Language.ArrayLiteralAst]) { \$b.Right.Elements.Count } else { -1 }
                if (\$idx -and \$cnt -ge 0 -and ((\$idx | Measure-Object -Maximum).Maximum -ge \$cnt)) {
                    \$bad++
                    Write-Output ('FAIL ' + \$_.FullName.Replace('$REPO/','') + ' line ' + \$b.Extent.StartLineNumber + ': -f references {' + ((\$idx | Measure-Object -Maximum).Maximum) + '} but only ' + \$cnt + ' argument(s) are passed - this THROWS at runtime')
                }
            }
        }
    }
}
Write-Output ''
Write-Output (\"scanned=\$n failing=\$bad\")
if (\$bad -gt 0) { exit 1 } else { exit 0 }
"
