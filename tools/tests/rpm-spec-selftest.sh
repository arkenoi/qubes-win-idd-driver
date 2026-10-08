#!/usr/bin/env bash
# rpm-spec-selftest.sh - the dom0 package's spec must PARSE, checked offline with the real parser.
#
# WHY. packaging/rpm/qubes-windows-tools-ng.spec was unbuildable from 122914e6 ("the RPM ships no
# scripts and runs nothing") until 2026-10-08: removing the dom0 scripts also deleted %description,
# %prep, %build, %install and %files, and left the %post banner's heredoc body at spec top level
# with no %post header above it. rpmbuild said `error: line 36: Unknown tag: cat <<'EOF'`, the rpm
# job failed every release run, and nothing caught it here because nothing parsed the spec outside
# CI - where it is the LAST job, after the ISO is already built and uploaded.
#
# This is the whole dom0 install path: the package puts the ISO at
# /usr/lib/qubes/qubes-windows-tools.iso, which is where qvm-create-windows-qube looks.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPEC="$ROOT/packaging/rpm/qubes-windows-tools-ng.spec"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SPEC" ] || { echo "FAIL  $SPEC is missing - nothing ran (missing data fails)"; exit 2; }
command -v rpmspec >/dev/null 2>&1 || { echo "FAIL  rpmspec is not installed, so the spec was NOT checked (missing data fails, never a skip)"; exit 2; }

# ---- 1. the real parser accepts it -------------------------------------------------------------
err=$(rpmspec --parse "$SPEC" 2>&1 >/dev/null)
if [ -z "$err" ]; then
  ok "parses: rpmspec --parse accepts the spec"
else
  bad "parses: $(printf '%s' "$err" | head -2 | tr '\n' ' ')"
fi

# ---- 2. every section a buildable package needs is present -------------------------------------
# The regression deleted five of these at once, so each is named rather than counted.
miss=""
for sec in description prep build install files changelog; do
  command grep -qE "^%$sec" "$SPEC" || miss="$miss [%$sec]"
done
[ -z "$miss" ] && ok "sections: %description %prep %build %install %files %changelog all present" \
               || bad "sections: missing$miss"

# ---- 3. the package installs the ISO where the Qubes tooling looks for it ----------------------
# qvm-create-windows-qube checks /usr/lib/qubes/qubes-windows-tools.iso by name; if %files stops
# listing it the RPM builds and installs NOTHING useful, which is worse than failing to build.
if command grep -qE '^%\{qwt_iso_dir\}/qubes-windows-tools\.iso' "$SPEC" \
   && command grep -qE '^%global qwt_iso_dir +%\{_prefix\}/lib/qubes' "$SPEC"; then
  ok "iso_path: %files lists the ISO at the path qvm-create-windows-qube looks for"
else
  bad "iso_path: the ISO is not listed at %{_prefix}/lib/qubes/qubes-windows-tools.iso"
fi

# ---- 4. it still ships no dom0 scripts ---------------------------------------------------------
# The commit that broke the spec was REMOVING those deliberately (two of three were executed by
# %post). Restoring the missing sections must not have brought them back.
if command grep -qE '^%\{_bindir\}/' "$SPEC"; then
  bad "no_dom0_scripts: %files lists something in %{_bindir} - this package runs nothing in dom0"
else
  ok "no_dom0_scripts: nothing is installed into %{_bindir}"
fi
# and %post must not execute anything either
# The banner's own text names qvm-features and qvm-prefs as advice for the administrator to run, so
# the heredoc BODY has to come out before looking for executable lines - otherwise the check reads
# printed advice as a command and can never pass.
postblk=$(sed -n '/^%post/,/^%changelog/p' "$SPEC" | sed "/^cat <<'EOF'/,/^EOF$/d")
if printf '%s' "$postblk" | command grep -qE '^\s*(%\{_bindir\}|/usr/bin/|qvm-|systemctl)'; then
  bad "post_runs_nothing: %post executes something - it is a notice only"
else
  ok "post_runs_nothing: %post only prints its notice"
fi

# ---- 4b. Conflicts WITH THE OFFICIAL PACKAGE -----------------------------------------------
# Both packages own /usr/lib/qubes/qubes-windows-tools.iso. Without a Conflicts, installing this
# one replaces a SIGNED vendor ISO with a TEST-SIGNED one, in dom0, silently. release-package.yml
# asserts it on the BUILT rpm with `rpm -qp --conflicts`; this asserts it on the SOURCE, so the
# absence is caught here in a second instead of forty minutes into a package build - which is
# exactly how it was caught (run 37745241513).
if rpmspec --parse "$SPEC" 2>/dev/null | command grep -qiE '^Conflicts:[[:space:]]*qubes-windows-tools[[:space:]]*$'; then
  ok "conflicts_declared: the spec refuses to co-install with the official qubes-windows-tools"
else
  bad "conflicts_declared: no Conflicts - installing this would silently replace a signed vendor ISO"
fi
# SEEN TO FAIL: the same check against a copy with the line removed.
nocon=$(mktemp "${TMPDIR:-/tmp}/spec-nocon-XXXXXX.spec")
command grep -v '^Conflicts:' "$SPEC" > "$nocon"
if rpmspec --parse "$nocon" 2>/dev/null | command grep -qiE '^Conflicts:[[:space:]]*qubes-windows-tools'; then
  bad "conflicts_seen_to_fail: the check passes a spec with no Conflicts line"
else
  ok "conflicts_seen_to_fail: the check rejects a spec with the line removed"
fi
rm -f "$nocon"

# ---- 5. THE CHECK MUST FAIL ON THE BROKEN REVISION ---------------------------------------------
# A check never seen to fail is decoration. Parse the revision that shipped the defect.
# Found by PARSING revisions, not by searching for a string: `git log -S` matches the commit that
# introduced the heredoc (inside a working %post) rather than the one that orphaned it.
broken=""; berr=""
for rev in $(cd "$ROOT" && git log --format=%H -20 -- packaging/rpm/qubes-windows-tools-ng.spec 2>/dev/null); do
  tmp=$(mktemp "${TMPDIR:-/tmp}/spec-rev-XXXXXX.spec")
  (cd "$ROOT" && git show "$rev:packaging/rpm/qubes-windows-tools-ng.spec") > "$tmp" 2>/dev/null
  e=$(rpmspec --parse "$tmp" 2>&1 >/dev/null)
  rm -f "$tmp"
  if [ -n "$e" ]; then broken="$rev"; berr="$e"; break; fi
done
if [ -z "$broken" ]; then
  bad "seen_to_fail: no revision in the last 20 fails to parse, so this check has never been seen to fail"
else
  ok "seen_to_fail: $(printf '%s' "$broken" | cut -c1-8) is rejected by the same parser ($(printf '%s' "$berr" | head -1))"
fi

echo
echo "rpm-spec-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
