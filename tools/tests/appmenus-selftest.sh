#!/usr/bin/env bash
# appmenus-selftest.sh - what a freshly created Windows qube's application menu contains, decided
# OFFLINE. No guest, no registry, no COM.
#
# WHAT IT GUARDS. dom0 shows EVERYTHING the guest reports until somebody writes a whitelist, and a
# whitelist can only ever be a SUBSET of what was reported (qubesappmenus/receive.py never takes a
# default from the guest; a fresh AppVM inherits `menu-items` from its template or nothing at all).
# So whatever get-appmenus.ps1 prints IS the menu on a new qube. MEASURED 2026-10-07 on a clone of
# the win11de-qwt golden, that menu was 38 entries of which:
#   * 20 came from one folder, "Administrative Tools" - Registry Editor, services, Event Viewer,
#     iSCSI Initiator, ODBC Data Sources (32- and 64-bit), Print Management, dfrgui...
#   * "Microsoft Edge" appeared TWICE, once scanned and once as a built-in, because the dedup
#     compared ids (Microsoft_Edge vs edge) and never the name the user actually sees;
#   * names carried their folder as a prefix: "Windows PowerShell Windows PowerShell ISE",
#     "Accessories-System Tools Character Map", "Administrative Tools dfrgui".
#
# The three decisions are now PURE functions in the shipped script, and they are extracted from it
# here - not re-implemented - and driven over the measured Start Menu. Every check is also driven
# to FAIL with the fix reverted by a knob, because a check never seen to fail is decoration.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/core-agent/src/qubes-rpc-services/get-appmenus.ps1"
PATHS="$ROOT/tools/tests/appmenus-win11de-25h2.paths"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
OUT="${APPMENUS_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/appmenus-XXXXXX")}"
mkdir -p "$OUT"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ]   || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }
[ -f "$PATHS" ] || { echo "FAIL  $PATHS is missing - the measured Start Menu is the input (missing data fails)"; exit 2; }
[ -x "$PWSH" ]  || { echo "FAIL  no pwsh at $PWSH - the decisions cannot be exercised, so nothing is proven"; exit 2; }

# ---- extract the pure decisions and the built-in table out of the shipped script ---------------
extract(){ # $1 = destination
python3 - "$SRC" "$1" <<'PY'
import sys, re
s = open(sys.argv[1], encoding='utf-8').read()
out = []

# the exclusion list, verbatim (brace/paren counted, comments and all)
m = re.search(r'^\$script:ExcludedMenuFolders\s*=\s*@\(', s, re.M)
if not m: sys.exit("ExcludedMenuFolders not found")
d, j = 0, s.index('(', m.start())
for k in range(j, len(s)):
    if s[k] == '(': d += 1
    elif s[k] == ')':
        d -= 1
        if d == 0: break
out.append(s[m.start():k+1])

# the functions, brace-counted rather than regex-truncated (tools/probe-review.py's lesson)
for fn in ('Get-QwtSafeValue', 'Get-QwtIdKey', 'Get-QwtNameKey', 'Get-QwtMenuRelativePath',
           'Test-QwtMenuExcluded', 'Get-QwtMenuName', 'Test-QwtBuiltinRedundant'):
    m = re.search(r'^Function\s+' + fn + r'\b', s, re.M)
    if not m: sys.exit(fn + " not found")
    d, j = 0, s.index('{', m.end())
    for k in range(j, len(s)):
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: break
    out.append(s[m.start():k+1])

# the built-in table: ids and names only, so the fixture can never drift from what ships.
# Exact matching stays in code; the regex is the whole point here.
tbl = re.findall(r"@\{\s*id\s*=\s*'([^']+)'\s*;\s*name\s*=\s*'([^']+)'", s)
tbl += re.findall(r"\$builtins \+= @\{ id = '([^']+)'; name = '([^']+)'", s)
seen = set()
tbl = [t for t in tbl if not (t[0] in seen or seen.add(t[0]))]   # the two patterns both match Edge
if len(tbl) < 10: sys.exit("built-in table: found only %d entries" % len(tbl))
out.append('$script:Builtins = @(')
out += ["    @{ id = '%s'; name = '%s' }" % (i, n) for i, n in tbl]
out.append(')')
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY
}
extract "$OUT/fn.ps1" || { echo "FAIL  the decisions could not be extracted from $SRC"; exit 2; }
[ -s "$OUT/fn.ps1" ] || { echo "FAIL  extraction produced nothing"; exit 2; }

# ---- the driver: replay the measured Start Menu through the extracted decisions -----------------
# Emits one TAB-separated row per outcome: KEPT|EXCLUDED|BUILTIN|SKIPPED <id> <name>
cat > "$OUT/drive.ps1" <<'PS'
param([string]$Fn, [string]$Paths, [string]$Base = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs')
. $Fn
$emittedIds = @{}; $emittedNames = @{}
foreach ($line in (Get-Content -LiteralPath $Paths)) {
    $rel = $line.Trim()
    if (-not $rel -or $rel.StartsWith('#')) { continue }
    # the sweep hands ProcessLink a FULL path; go through the same relativiser the script uses.
    # Concatenated, not Join-Path: Join-Path is provider-aware and refuses a C: path off Windows.
    $full = $Base.TrimEnd('\') + '\' + $rel
    $r = Get-QwtMenuRelativePath $full $Base
    # EVERY shortcut is reported - what is excluded is only the RECOMMENDED default selection
    $rec = -not (Test-QwtMenuExcluded $r)
    # what Get-ChildItem's FileInfo.BaseName gives the real script. NOT
    # [IO.Path]::GetFileNameWithoutExtension: off Windows it does not treat '\' as a separator and
    # hands back the whole relative path, which silently turned this suite into a no-op.
    $base = (($r -split '[\\/]')[-1]) -replace '\.lnk$', ''
    $name = Get-QwtMenuName $r $base $emittedNames
    $id   = $r.Replace('.lnk', '').Replace(' ', '_').Replace('\', '-')
    $emittedIds[(Get-QwtIdKey $id)] = $true
    $emittedNames[(Get-QwtNameKey $name)] = $true
    # the label as dom0 receives it, which is what the user reads
    Write-Output "$(if ($rec) {'KEPT'} else {'NOTREC'})`t$id`t$(Get-QwtSafeValue $name)"
}
foreach ($b in $script:Builtins) {
    $why = Test-QwtBuiltinRedundant $b.id $b.name $emittedIds $emittedNames
    if ($why) { Write-Output "SKIPPED`t$($b.id)`t$($b.name)"; continue }
    $emittedIds[(Get-QwtIdKey $b.id)] = $true
    $emittedNames[(Get-QwtNameKey $b.name)] = $true
    Write-Output "BUILTIN`t$($b.id)`t$(Get-QwtSafeValue $b.name)"
}
PS

menu(){ "$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "${1:-$OUT/fn.ps1}" -Paths "$PATHS" 2>&1; }
M="$OUT/menu.txt"; menu > "$M"
grep -q 'KEPT' "$M" || { echo "FAIL  the driver produced no menu:"; cat "$M"; exit 2; }
# AVAILABLE = everything reported. RECOMMENDED = what a fresh qube should have enabled.
visible(){ awk -F'\t' '$1=="KEPT"||$1=="BUILTIN"||$1=="NOTREC"' "${1:-$M}"; }
recommended(){ awk -F'\t' '$1=="KEPT"||$1=="BUILTIN"' "${1:-$M}"; }

# ---- the checks --------------------------------------------------------------------------------
# 1. NOTHING IS DROPPED. All 28 shortcuts stay AVAILABLE - this is the check that exists because
#    an earlier version of the fix removed 20 of them from dom0's available list, so nobody could
#    tick them in Settings -> Applications ever again.
n_av=$(visible | wc -l)
n_fix=$(sed -e '/^#/d' -e '/^$/d' "$PATHS" | wc -l)
# n_fix shortcuts + 9 built-ins: ten are defined, and Edge's yields to the real "Microsoft Edge"
# shortcut. That is the ONE entry this change removes from the 38 the guest used to report, and it
# was a duplicate of another entry - not an application anybody could have wanted ticked twice.
if [ "$n_av" = $((n_fix + 9)) ] && [ "$(awk -F'\t' '$1=="EXCLUDED"' "$M" | wc -l)" = 0 ]; then
  ok "nothing_dropped: all $n_fix shortcuts plus 9 built-ins are AVAILABLE ($n_av entries); nothing is excluded from the report, and the only entry gone from the old 38 is the duplicate Edge"
else
  bad "nothing_dropped: available=$n_av expected=$((n_fix + 9)); excluded=$(awk -F'\t' '$1=="EXCLUDED"' "$M" | wc -l) (must be 0)"
fi

# 1b. the RECOMMENDATION is the narrow one, and it is what leaves the admin consoles out
n_rec=$(recommended | wc -l)
n_admin=$(sed -e '/^#/d' -e '/^$/d' "$PATHS" | grep -c '^Administrative Tools\\')
if [ "$n_admin" = 20 ] && [ "$n_rec" = 17 ] && ! recommended | grep -q 'Administrative'; then
  ok "recommendation_is_narrow: $n_rec of $n_av recommended; the 20 Administrative Tools entries stay AVAILABLE and are simply not in the suggested default"
else
  bad "recommendation_is_narrow: recommended=$n_rec of $n_av, admin-in-fixture=$n_admin, admin recommended: $(recommended | grep -c Administrative)"
fi

# 2. nothing else was filtered - every non-admin shortcut survived
missing=""
while IFS= read -r rel; do
  case "$rel" in ''|'#'*|'Administrative Tools\'*) continue;; esac
  nm="${rel##*\\}"; nm="${nm%.lnk}"   # basename(1) does not split on '\\'
  visible | cut -f3 | grep -qxF "$nm" || missing="$missing $nm"
done < "$PATHS"
[ -z "$missing" ] && ok "apps_available: every non-administrative shortcut is available" \
                   || bad "apps_available: missing -$missing"

# 3. names carry no folder prefix - the exact eight, as the user will read them
want_names=$'Microsoft Edge\nRemote Desktop Connection\nSteps Recorder\nWindows Media Player Legacy\nCharacter Map\nTask Manager\nWindows PowerShell ISE (x86)\nWindows PowerShell ISE'
got_names=$(awk -F'\t' '$1=="KEPT"{print $3}' "$M" | sort)   # the recommended shortcuts
if [ "$(printf '%s\n' "$want_names" | sort)" = "$got_names" ]; then
  ok "names_unmangled: all 8 scanned names are the shortcut's own, no folder prefix"
else
  bad "names_unmangled: expected/got differ:"; diff <(printf '%s\n' "$want_names" | sort) <(echo "$got_names") | sed 's/^/        /'
fi

# 4. no two menu entries read the same - this is what the user sees, so it is the real test
dupes=$(visible | cut -f3 | tr 'A-Z' 'a-z' | sort | uniq -d)
[ -z "$dupes" ] && ok "no_duplicate_names: every entry in the menu reads differently" \
                || bad "no_duplicate_names: duplicated labels: $(echo "$dupes" | tr '\n' ' ')"

# 5. the measured duplicate specifically: the built-in Edge yields to the real shortcut
edge_n=$(visible | cut -f3 | grep -cxF 'Microsoft Edge')
if [ "$edge_n" = 1 ] && grep -qP '^SKIPPED\tedge\t' "$M"; then
  ok "edge_deduped: 'Microsoft Edge' appears once; the built-in stepped aside for the shortcut"
else
  bad "edge_deduped: Microsoft Edge x$edge_n, built-in edge $(grep -cP '^(SKIPPED|BUILTIN)\tedge\t' "$M" >/dev/null && awk -F'\t' '$2=="edge"{print $1}' "$M")"
fi

# 6. ids stay unique - the folder prefix still lives there, which is what makes them unique
id_dupes=$(visible | cut -f2 | sort | uniq -d)
[ -z "$id_dupes" ] && ok "ids_unique: every desktop-entry id is distinct" \
                   || bad "ids_unique: duplicated ids: $(echo "$id_dupes" | tr '\n' ' ')"

# 7. dom0 ASSERTS this one: receive.py create_template() does `assert ' ' not in name` on the id,
#    and an AssertionError there takes the whole sync down.
if ! visible | cut -f2 | grep -q '[ ;%]'; then
  ok "ids_dom0_safe: no id contains a space, ';' or '%' (receive.py asserts on all three)"
else
  bad "ids_dom0_safe: ids dom0 would assert on: $(visible | cut -f2 | grep '[ ;%]' | tr '\n' ' ')"
fi

# 8. the menu a new qube gets: 8 real apps + 9 built-ins (edge yielded)
n_vis=$(visible | wc -l); n_rec=$(recommended | wc -l)
{ [ "$n_vis" = 37 ] && [ "$n_rec" = 17 ]; } \
  && ok "menu_size: 37 AVAILABLE (the old 38 less the duplicate Edge - nothing else taken from the user) and 17 RECOMMENDED for a fresh qube" \
  || bad "menu_size: available=$n_vis (expect 37) recommended=$n_rec (expect 17)"

# 9. the two fixed ids dom0's own launchers are wired to must survive the dedup
for id in qubes-run-terminal qubes-open-file-manager; do
  grep -qP "^BUILTIN\t$id\t" "$M" && ok "builtin_fixed_id: $id is reported" \
                                  || bad "builtin_fixed_id: $id is NOT reported - dom0's launcher has nothing to point at"
done

# 10. only DIRECTORY components exclude. A shortcut named "Administrative Tools.lnk" at the
#     Programs root is an application (Win11 ships "Windows Tools.lnk" exactly like that).
cat > "$OUT/edge-cases.paths" <<'EOF'
Administrative Tools.lnk
Deep\Administrative Tools\x.lnk
EOF
ec=$("$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "$OUT/fn.ps1" -Paths "$OUT/edge-cases.paths" 2>&1)
if echo "$ec" | grep -qP '^KEPT\tAdministrative_Tools\t' && echo "$ec" | grep -qP '^NOTREC\tDeep-Administrative_Tools-x\t'; then
  ok "file_own_name_never_excludes: only a DIRECTORY drops out of the recommendation; a file named 'Administrative Tools.lnk' is recommended, and both remain available"
else
  bad "file_own_name_never_excludes:"; echo "$ec" | sed 's/^/        /'
fi

# 11. the relativiser survives a base path with a trailing separator
rp=$("$PWSH" -NoProfile -Command ". '$OUT/fn.ps1'; Get-QwtMenuRelativePath 'C:\\M\\Programs\\A\\b.lnk' 'C:\\M\\Programs\\'" 2>&1)
[ "$rp" = 'A\b.lnk' ] && ok "relpath_trailing_sep: a base path ending in '\\' still relativises to 'A\\b.lnk'" \
                      || bad "relpath_trailing_sep: got '$rp', expected 'A\\b.lnk'"

# 12. a name collision still produces two distinguishable labels, not a silent duplicate
cat > "$OUT/collide.paths" <<'EOF'
One\Thing.lnk
Two\Thing.lnk
EOF
co=$("$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "$OUT/fn.ps1" -Paths "$OUT/collide.paths" 2>&1)
if echo "$co" | grep -qP '^KEPT\tOne-Thing\tThing$' && echo "$co" | grep -qP '^KEPT\tTwo-Thing\tTwo Thing$'; then
  ok "collision_disambiguated: the second 'Thing' falls back to 'Two Thing' rather than repeating"
else
  bad "collision_disambiguated:"; echo "$co" | sed 's/^/        /'
fi

# 13. INSTALLED APPLICATIONS STILL COME THROUGH, so they can be enabled in dom0. This is the
#     question the exclusion has to answer: dom0's whitelist can only ever contain what the guest
#     reported, so anything dropped here can never be switched on by anyone. The near misses are
#     the point - the match is on a WHOLE path component, so a vendor folder that merely contains
#     the word "Tools", or one whose name merely starts with "Administrative Tools", is an
#     application folder and stays.
cat > "$OUT/thirdparty.paths" <<'EOF'
Firefox.lnk
Mozilla Firefox\Firefox Private Browsing.lnk
LibreOffice 7.6\LibreOffice Writer.lnk
7-Zip\7-Zip File Manager.lnk
VideoLAN\VLC media player.lnk
Git\Git Bash.lnk
Python 3.12\IDLE (Python 3.12 64-bit).lnk
Microsoft Office Tools\Database Compare.lnk
VMware Tools\VMware Tools.lnk
Administrative Tools Pro\Dashboard.lnk
My Administrative Tools\Thing.lnk
Vendor\Administrative Toolsx\Thing.lnk
EOF
tp=$("$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "$OUT/fn.ps1" -Paths "$OUT/thirdparty.paths" 2>&1)
n_tp=$(echo "$tp" | awk -F'\t' '$1=="KEPT"' | wc -l)
n_want=$(grep -c '\.lnk$' "$OUT/thirdparty.paths")
if [ "$n_tp" = "$n_want" ] && ! echo "$tp" | grep -q '^EXCLUDED'; then
  ok "native_apps_reportable: all $n_want installed-application shortcuts are reported, near-miss folder names included"
else
  bad "native_apps_reportable: $n_tp of $n_want reported; dropped: $(echo "$tp" | awk -F'\t' '$1=="EXCLUDED"{print $3}' | tr '\n' ' ')"
fi

# 14. NON-ASCII NAMES. dom0 decodes each line as ASCII and drops the rest, so Emit-Entry strips it
#     first and a German "Zubeh<o-umlaut>r" arrives as "Zubehr". The collision check must therefore
#     compare what dom0 RECEIVES, not the raw string - otherwise two shortcuts emit one identical
#     label while the check sees two different ones. GWeck's guest is German; this is not an edge.
printf 'Zubeh\xc3\xb6r.lnk\nZubehr.lnk\nB\xc3\xbcro\\Dok\xc3\xbcment.lnk\n' > "$OUT/umlaut.paths"
um=$("$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "$OUT/fn.ps1" -Paths "$OUT/umlaut.paths" 2>&1)
um_dupes=$(echo "$um" | awk -F'\t' '$1=="KEPT"{print tolower($3)}' | sort | uniq -d)
n_um=$(echo "$um" | awk -F'\t' '$1=="KEPT"' | wc -l)
if [ -z "$um_dupes" ] && [ "$n_um" = 3 ] \
   && [ "$(echo "$um" | awk -F'\t' '$1=="KEPT"{print $3}' | grep -c '^Zubehr')" = 2 ]; then
  ok "ascii_stripped_names_dedup: 'Zubeh*r' and 'Zubehr' both arrive as Zubehr and are still told apart ($(echo "$um" | awk -F'\t' '$1=="KEPT"{printf "%s/",$3}'))"
else
  bad "ascii_stripped_names_dedup: duplicated labels '$(echo "$um_dupes" | tr '\n' ' ')' in:"; echo "$um" | sed 's/^/        /'
fi

# 15. the id key is the same whichever side inserts it - a scanned id and a built-in id are
#     looked up through one function, which they were not before.
kt=$("$PWSH" -NoProfile -Command ". '$OUT/fn.ps1'; \
  \$i=@{}; \$i[(Get-QwtIdKey 'Microsoft_Edge')]=\$true; \
  Write-Output (Test-QwtBuiltinRedundant 'microsoft edge' 'x' \$i @{}); \
  Write-Output (Test-QwtBuiltinRedundant 'cmd-admin' 'x' \$i @{})" 2>&1)
if [ "$(echo "$kt" | head -1)" = 'id' ] && [ -z "$(echo "$kt" | sed -n 2p)" ]; then
  ok "id_key_is_shared: an id inserted sanitised+lower-cased is found by the built-in check, and a different id is not"
else
  bad "id_key_is_shared: expected 'id' then empty, got: $(echo "$kt" | tr '\n' '/')"
fi

# ---- the knobs: each fix reverted, and the check it owns must FAIL ------------------------------
# A knob rewrites the EXTRACTED copy, so the shipped file is never touched.
knob(){ # $1 = name, $2 = sed program over fn.ps1, $3.. = checks that must break
  local name="$1" prog="$2"; shift 2
  cp "$OUT/fn.ps1" "$OUT/knob-$name.ps1"
  sed -i -e "$prog" "$OUT/knob-$name.ps1"
  if cmp -s "$OUT/fn.ps1" "$OUT/knob-$name.ps1"; then
    bad "knob $name: the injection changed nothing - the knob no longer matches the code it reverts"
    return
  fi
  local km="$OUT/menu-$name.txt"; menu "$OUT/knob-$name.ps1" > "$km"
  grep -q 'KEPT' "$km" || { bad "knob $name: the reverted copy produced no menu at all"; return; }
  local broke=0 detail=""
  for c in "$@"; do
    case "$c" in
      admin)  awk -F'\t' '$1=="KEPT"||$1=="BUILTIN"' "$km" | grep -q 'Administrative' && broke=1 || detail="$detail admin-still-unrecommended";;
      names)  awk -F'\t' '$1=="KEPT"{print $3}' "$km" | grep -q '^Windows PowerShell Windows PowerShell ISE$' && broke=1 || detail="$detail names-still-clean";;
      edge)   [ "$(awk -F'\t' '$1=="KEPT"||$1=="BUILTIN"' "$km" | cut -f3 | grep -cxF 'Microsoft Edge')" = 2 ] && broke=1 || detail="$detail edge-still-single";;
      umlaut) local u; u=$("$PWSH" -NoProfile -File "$OUT/drive.ps1" -Fn "$OUT/knob-$name.ps1" -Paths "$OUT/umlaut.paths" 2>&1)
              [ -n "$(echo "$u" | awk -F'\t' '$1=="KEPT"{print tolower($3)}' | sort | uniq -d)" ] && broke=1 || detail="$detail umlaut-still-deduped";;
    esac
  done
  [ "$broke" = 1 ] && ok "knob $name: with the fix reverted the defect is back - the check is load-bearing" \
                   || bad "knob $name: the defect did NOT come back ($detail) - the check proves nothing"
}

# revert 1: the recommendation stops leaving the administration folders out
knob noexclude "s/^    'Administrative Tools'.*/    'ZZ-no-such-folder'/" admin
# revert 2: the folder prefix goes back into the displayed name (upstream behaviour)
knob prefixname "s|^    foreach (\\\$c in \\\$candidates) {|    \\\$candidates = @(\\\$candidates[\\\$candidates.Count - 1])\\n    foreach (\\\$c in \\\$candidates) {|" names
# revert 3: the dedup consults ids only
knob idonly "/emittedNames -and \$emittedNames.ContainsKey/d" edge
# revert 4: the name key goes back to the RAW string instead of what dom0 receives
knob rawnamekey "s|^    return (Get-QwtSafeValue \$name).ToLowerInvariant()\$|    return \"\$name\".ToLowerInvariant()|" umlaut

echo
echo "appmenus-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
